# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twenty-seventh review round: the freshness probe
# neither builds nor runs middleware that can reach the live stack's mutable
# state (a fresh options hash around the very same vendor is not a stand-in),
# a list is copied out of the cache only while its entry is still the one the
# map holds, the probe models the request with the metadata held for the
# decision, stdio serves a still-fresh hinted list, and a TTL-driven tool
# refresh is announced to the client.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 27' do
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

  # Answers tools/list with a private list named after the bearer the
  # request carried, and records those bearers.
  def stub_tools_by_bearer
    bearers = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        bearer = request.headers['Authorization'].to_s.sub(/\ABearer /, '')
        bearers << bearer
        json_response(body['id'],
                      { 'tools' => [tool("#{bearer}-tool")], 'ttlMs' => 60_000, 'cacheScope' => 'private' })
      else
        json_response(body['id'], discover_result)
      end
    end
    bearers
  end

  # Vends one-time bearers and counts what it has spent.
  def nonce_vendor
    Class.new do
      attr_reader :used

      def initialize
        @used = 0
      end

      def next_nonce
        @used += 1
        "nonce#{@used}"
      end
    end.new
  end

  def unknown_context
    MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT
  end

  describe 'a probe against middleware that copies its options around a shared vendor' do
    # Faraday rebuilds middleware as `klass.new(app, **kwargs)`, so a `**opts`
    # parameter is a fresh hash on every build — holding the very same vendor.
    def kwargs_nonce_middleware
      Class.new(Faraday::Middleware) do
        def initialize(app, **opts)
          super(app)
          @opts = opts
        end

        def on_request(env)
          return unless env.body.to_s.include?('"tools/list"')

          env.request_headers['Authorization'] = "Bearer #{@opts[:vendor].next_nonce}"
        end
      end
    end

    it 'reports the unknown context instead of spending the shared vendor' do
      stub_tools_by_bearer
      vendor = nonce_vendor
      server = streamable(faraday_config: ->(f) { f.use kwargs_nonce_middleware, vendor: vendor })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(vendor.used).to eq(1)
    end

    it 'never skips the one-time credential of the next real request' do
      bearers = stub_tools_by_bearer
      vendor = nonce_vendor
      server = streamable(faraday_config: ->(f) { f.use kwargs_nonce_middleware, vendor: vendor })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(vendor.used).to eq(2)
    end

    it 'reads literal configuration but never a vendor of its own' do
      server = streamable
      vendor = nonce_vendor

      expect(server.send(:probe_static_value?, { token: 'abc' })).to be true
      expect(server.send(:probe_static_value?, [1, :two, 'three'])).to be true
      expect(server.send(:probe_static_value?, { vendor: vendor })).to be false
      expect(server.send(:probe_static_value?, -> { 'abc' })).to be false
    end
  end

  describe 'a probe against middleware whose constructor spends a credential' do
    def constructor_nonce_middleware
      Class.new(Faraday::Middleware) do
        def initialize(app, vendor)
          super(app)
          @nonce = vendor.next_nonce
        end

        def on_request(env)
          env.request_headers['Authorization'] = "Bearer #{@nonce}"
        end
      end
    end

    it 'never builds it, so the credential it would consume is not spent' do
      bearers = stub_tools_by_bearer
      vendor = nonce_vendor
      server = streamable(faraday_config: ->(f) { f.use constructor_nonce_middleware, vendor })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(vendor.used).to eq(1)
      expect(bearers).to eq(['nonce1'])
    end
  end

  describe 'a probe run for a decision that read the host request_meta' do
    # Picks the bearer out of the request body's own metadata, the way a host
    # middleware that authenticates by trace context would.
    def trace_middleware
      Class.new(Faraday::Middleware) do
        def on_request(env)
          meta = JSON.parse(env.body.to_s).dig('params', '_meta') || {}
          env.request_headers['Authorization'] = "Bearer #{meta['traceparent']}"
        rescue JSON::ParserError
          nil
        end
      end
    end

    it 'models the request with the metadata held for it, spending no extra evaluation' do
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << body.dig('params', '_meta', 'traceparent')
        json_response(body['id'],
                      if body['method'] == 'tools/list'
                        { 'tools' => [tool('t')], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
                      else
                        discover_result
                      end)
      end
      spent = 0
      server = streamable(faraday_config: ->(f) { f.use trace_middleware })
      server.request_meta = lambda {
        spent += 1
        { 'traceparent' => "t#{spent}" }
      }

      server.list_tools
      server.list_tools

      # Every evaluation of the host's callable went out on the wire: none was
      # spent on a probe that sends nothing.
      expect(sent).to eq((1..spent).map { |i| "t#{i}" })
    end
  end

  describe 'a list invalidated while it is being served' do
    it 'fetches again instead of copying the invalidated tool list' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'tools/list'
          lists += 1
          json_response(body['id'],
                        { 'tools' => [tool("t#{lists}")], 'ttlMs' => 60_000, 'cacheScope' => 'public' })
        else
          json_response(body['id'], discover_result)
        end
      end
      server = streamable
      expect(server.list_tools.map(&:name)).to eq(['t1'])

      # The notification lands after the entry was looked up and before its
      # list is handed out.
      original = server.method(:private_entry_for_current_context)
      armed = true
      allow(server).to receive(:private_entry_for_current_context) do |kind|
        entry = original.call(kind)
        if armed && kind == :tools && entry
          armed = false
          server.send(:invalidate_cache_for_notification, 'notifications/tools/list_changed')
        end
        entry
      end

      expect(server.list_tools.map(&:name)).to eq(['t2'])
      expect(lists).to eq(2)
    end
  end

  describe 'a stdio server that hinted how long its lists stay fresh' do
    def stdio_server(method, result)
      server = MCPClient::ServerStdio.new(command: 'echo test')
      allow(server).to receive(:ensure_initialized)
      calls = 0
      allow(server).to receive(:rpc_request) do |called, _params = {}, **_opts|
        raise "unexpected #{called}" unless called == method

        calls += 1
        result
      end
      [server, -> { calls }]
    end

    it 'serves a still-fresh tool list without asking again' do
      server, calls = stdio_server('tools/list', { 'tools' => [tool('t')], 'ttlMs' => 60_000,
                                                   'cacheScope' => 'public' })

      expect(server.list_tools.map(&:name)).to eq(['t'])
      expect(server.list_tools.map(&:name)).to eq(['t'])
      expect(calls.call).to eq(1)
    end

    it 'serves a still-fresh prompt list without asking again' do
      server, calls = stdio_server('prompts/list', { 'prompts' => [{ 'name' => 'p' }], 'ttlMs' => 60_000,
                                                     'cacheScope' => 'public' })

      expect(server.list_prompts.map(&:name)).to eq(['p'])
      expect(server.list_prompts.map(&:name)).to eq(['p'])
      expect(calls.call).to eq(1)
    end

    it 'serves a still-fresh resource list without asking again' do
      server, calls = stdio_server('resources/list',
                                   { 'resources' => [{ 'uri' => 'file:///a.txt', 'name' => 'a' }],
                                     'ttlMs' => 60_000, 'cacheScope' => 'public' })

      expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(calls.call).to eq(1)
    end

    it 'asks again once the hint has expired' do
      server, calls = stdio_server('tools/list', { 'tools' => [tool('t')], 'ttlMs' => 1, 'cacheScope' => 'public' })

      expect(server.list_tools.map(&:name)).to eq(['t'])
      allow(server).to(receive(:monotonic_now).and_wrap_original { |method| method.call + 3600 })
      expect(server.list_tools.map(&:name)).to eq(['t'])
      expect(calls.call).to eq(2)
    end
  end

  describe 'a tool list a TTL refresh replaced during a call' do
    it 'validates the result against the definitions the call was answered under' do
      version = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'tools/list'
          version += 1
          json_response(body['id'],
                        { 'tools' => [{ 'name' => 'greet', 'inputSchema' => { 'type' => 'object' },
                                        'outputSchema' => {
                                          'type' => 'object',
                                          'properties' => { "v#{version}" => { 'type' => 'string' } },
                                          'required' => ["v#{version}"]
                                        } }],
                          'ttlMs' => 60_000 })
        when 'tools/call'
          json_response(body['id'], { 'content' => [], 'structuredContent' => { "v#{version}" => 'ok' } })
        else
          json_response(body['id'], discover_result)
        end
      end
      server = streamable
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }],
        validate_structured_content: :strict
      )
      expect(client.list_tools.map(&:name)).to eq(['greet'])

      # The hint expires after the tool was resolved, so the transport
      # re-fetches the list while the call itself is being sent.
      expired = false
      allow(server).to(receive(:monotonic_now).and_wrap_original { |method| method.call + (expired ? 3600 : 0) })
      validate_params = client.method(:validate_params!)
      allow(client).to receive(:validate_params!) do |*args|
        expired = true
        validate_params.call(*args)
      end

      expect { client.call_tool('greet', {}) }.not_to raise_error
      expect(version).to eq(2)
    end
  end
end
