# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'logger'

# MCP 2026-07-28 caching, thirtieth review round: the freshness probe reads the
# Authorization a `faraday_config` block configured on the connection itself,
# a handler that carries any host-supplied callback makes the context unknown,
# a cache lookup that aborts lets go of the metadata it held for the request it
# never made, a transport's cleanup drops every thread-local slot it owns, and
# `follow_redirects` — which the gem depends on and cannot set Authorization —
# is framework middleware the probe steps over.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 30' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def unknown_context
    MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT
  end

  def fingerprint(header)
    Digest::SHA256.hexdigest(header)
  end

  # Answers tools/list with a private list named after the bearer the request
  # carried, and records those bearers.
  def stub_tools_by_bearer
    bearers = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        bearers << request.headers['Authorization'].to_s.sub(/\ABearer /, '')
        json_response(body['id'],
                      { 'tools' => [tool("#{bearers.last}-tool")], 'ttlMs' => 60_000, 'cacheScope' => 'private' })
      else
        json_response(body['id'], discover_result)
      end
    end
    bearers
  end

  describe 'an Authorization the faraday_config block puts on the connection' do
    it 'is what the probe reports, not the anonymous context' do
      server = streamable(faraday_config: ->(f) { f.headers['Authorization'] = 'Bearer conn' })
      expect(server.send(:current_authorization_context, :tools)).to eq(fingerprint('Bearer conn'))
    ensure
      server&.cleanup
    end

    it 'loses to the transport\'s own configured header, as it does on the wire' do
      server = streamable(headers: { 'Authorization' => 'Bearer explicit' },
                          faraday_config: ->(f) { f.headers['Authorization'] = 'Bearer conn' })
      expect(server.send(:current_authorization_context, :tools)).to eq(fingerprint('Bearer explicit'))
    ensure
      server&.cleanup
    end

    it 'lets the private list it fetched be served again' do
      bearers = stub_tools_by_bearer
      server = streamable(faraday_config: ->(f) { f.headers['Authorization'] = 'Bearer conn' })

      expect(server.list_tools.map(&:name)).to eq(['conn-tool'])
      expect(server.list_tools.map(&:name)).to eq(['conn-tool'])

      expect(bearers).to eq(['conn'])
    ensure
      server&.cleanup
    end
  end

  describe 'a handler configured with a host-supplied callback' do
    # A logger formatter is host code that Faraday hands the mutable env.
    def bearer_formatter
      Class.new(Faraday::Logging::Formatter) do
        def request(env)
          env.request_headers['Authorization'] = 'Bearer formatter'
          super
        end
      end
    end

    # No `on_request` and no `call` of its own at class level: the hook is
    # installed on the instance, which no class-level test can see.
    def singleton_hook_middleware
      Class.new(Faraday::Middleware) do
        def initialize(app)
          super
          define_singleton_method(:on_request) do |env|
            env.request_headers['Authorization'] = 'Bearer singleton'
          end
        end
      end
    end

    # Genuinely without a request phase: no constructor, no `on_request`, and
    # Faraday's own `call`.
    def response_only_middleware
      Class.new(Faraday::Middleware) do
        def on_complete(env); end
      end
    end

    it 'makes the context unknown when a logger formatter is supplied' do
      formatter = bearer_formatter
      server = streamable(headers: { 'Authorization' => 'Bearer static' },
                          faraday_config: lambda { |f|
                            f.response :logger, Logger.new(IO::NULL), formatter: formatter
                          })
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
    ensure
      server&.cleanup
    end

    it 'makes the context unknown when the handler was given a block' do
      server = streamable(headers: { 'Authorization' => 'Bearer static' },
                          faraday_config: ->(f) { f.response(:logger) { |logger| logger.filter(/x/, 'y') } })
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
    ensure
      server&.cleanup
    end

    it 'makes the context unknown when a constructor of its own could install a hook' do
      klass = singleton_hook_middleware
      server = streamable(headers: { 'Authorization' => 'Bearer static' },
                          faraday_config: ->(f) { f.use klass })
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
    ensure
      server&.cleanup
    end

    it 'keeps the unknown context for a credential holder Faraday would only read' do
      # Not callable, so nothing Faraday runs — but its `to_s` is the
      # credential, and whoever holds it can change what that says.
      holder = Class.new do
        def to_s
          'rotating'
        end
      end.new
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', holder })
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
    ensure
      server&.cleanup
    end

    it 'serves the private list it never touches when the middleware really has no request phase' do
      klass = response_only_middleware
      bearers = stub_tools_by_bearer
      server = streamable(headers: { 'Authorization' => 'Bearer static' },
                          faraday_config: ->(f) { f.use klass })

      expect(server.list_tools.map(&:name)).to eq(['static-tool'])
      expect(server.list_tools.map(&:name)).to eq(['static-tool'])

      expect(bearers).to eq(['static'])
    ensure
      server&.cleanup
    end
  end

  describe 'a cache lookup whose authorization probe raises' do
    it 'lets go of the metadata it held for the request it never made' do
      baggage = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        baggage << body.dig('params', '_meta', 'baggage')
        json_response(body['id'],
                      if body['method'] == 'tools/list'
                        { 'tools' => [tool('t')], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
                      elsif body['method'] == 'prompts/list'
                        { 'prompts' => [] }
                      else
                        discover_result
                      end)
      end
      refusing = false
      provider_class = Class.new do
        def initialize(&block)
          @block = block
        end

        def apply_authorization(request)
          @block.call(request)
        end
      end
      provider = provider_class.new do |request|
        raise MCPClient::Errors::ConnectionError, 'token refresh failed' if refusing

        request.headers['Authorization'] = 'Bearer a'
      end

      tenant = 'a'
      server = streamable(oauth_provider: provider)
      server.request_meta = -> { { 'baggage' => "tenant=#{tenant}" } }
      server.list_tools

      refusing = true
      expect { server.list_tools }.to raise_error(MCPClient::Errors::ConnectionError)

      refusing = false
      tenant = 'b'
      server.list_prompts

      expect(baggage.last).to eq('tenant=b')
    ensure
      server&.cleanup
    end
  end

  describe 'a transport that is cleaned up' do
    it 'drops every thread-local slot it owns' do
      stub_tools_by_bearer
      server = streamable(headers: { 'Authorization' => 'Bearer static' })
      server.list_tools
      server.send(:mark_round_trip_result, true)
      server.send(:note_request_authorization, 'Bearer static')
      server.send(:note_request_params, { 'a' => 1 })
      Thread.current[server.send(:recorded_entries_key)] = { tools: Object.new }
      Thread.current[server.send(:served_entries_key)] = { tools: [Object.new, nil] }
      Thread.current[server.send(:response_received_key)] = 1.0

      keys = %i[request_authorization_key request_params_key round_trip_marker_key
                recorded_entries_key served_entries_key response_received_key]
      expect(keys.map { |key| Thread.current[server.send(key)] }).to all(be_truthy)

      server.cleanup

      expect(keys.map { |key| Thread.current[server.send(key)] }).to all(be_nil)
    end

    it 'leaves the credentials of a torn-down attempt unrecorded, not anonymous' do
      stub_tools_by_bearer
      server = streamable(headers: { 'Authorization' => 'Bearer static' })
      server.list_tools

      server.cleanup

      expect(server.send(:request_authorization_recorded?)).to be(false)
    end
  end

  describe 'the follow_redirects middleware the gem itself depends on' do
    it 'is stepped over, so a static bearer keeps its private cache hit' do
      bearers = stub_tools_by_bearer
      server = streamable(headers: { 'Authorization' => 'Bearer static' },
                          faraday_config: ->(f) { f.response :follow_redirects })

      expect(server.send(:current_authorization_context, :tools)).to eq(fingerprint('Bearer static'))
      expect(server.list_tools.map(&:name)).to eq(['static-tool'])
      expect(server.list_tools.map(&:name)).to eq(['static-tool'])

      expect(bearers).to eq(['static'])
    ensure
      server&.cleanup
    end

    it 'makes the context unknown once a redirect callback is supplied' do
      server = streamable(headers: { 'Authorization' => 'Bearer static' },
                          faraday_config: ->(f) { f.response :follow_redirects, callback: ->(_old, _new) {} })
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
    ensure
      server&.cleanup
    end
  end
end
