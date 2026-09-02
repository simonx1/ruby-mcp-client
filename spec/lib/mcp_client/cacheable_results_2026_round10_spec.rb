# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, tenth review round: raw list pages are never
# handed from one fetch to another, a request that fails before any response
# under Faraday middleware has an unknown authorization context, and SSE
# resource lists are dated from receipt.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 10' do
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

  describe 'raw list pages' do
    let(:seen) { [] }

    def stub_lists
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'].end_with?('/list')

        seen << [body['method'], request.headers['Authorization']]
        owner = request.headers['Authorization'].to_s.sub('Bearer ', '')
        result = case body['method']
                 when 'tools/list' then { 'tools' => [tool("#{owner}-tool")] }
                 when 'prompts/list' then { 'prompts' => [{ 'name' => "#{owner}-prompt" }] }
                 else { 'resources' => [{ 'uri' => "file:///#{owner}", 'name' => owner }] }
                 end
        json_response(body['id'], result.merge('ttlMs' => 0, 'cacheScope' => 'private'))
      end
    end

    it 'never answers a fetch under other credentials from a previous fetch (Streamable HTTP)' do
      stub_lists
      server = streamable(headers: { 'Authorization' => 'Bearer alice' })
      server.list_tools
      server.list_prompts
      server.list_resources
      seen.clear

      server.instance_variable_get(:@headers)['Authorization'] = 'Bearer bob'
      expect(server.send(:request_tools_list).map { |t| t['name'] }).to eq(['bob-tool'])
      expect(server.send(:request_prompts_list).map { |p| p['name'] }).to eq(['bob-prompt'])
      expect(server.send(:request_resources_list).map { |r| r['name'] }).to eq(['bob'])
      expect(seen.map(&:last).uniq).to eq(['Bearer bob'])
    ensure
      server&.cleanup
    end

    it 'never answers a fetch under other credentials from a previous fetch (HTTP)' do
      stub_lists
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                         headers: { 'Authorization' => 'Bearer alice' })
      server.list_tools
      seen.clear

      server.instance_variable_get(:@headers)['Authorization'] = 'Bearer bob'
      expect(server.send(:request_tools_list).map { |t| t['name'] }).to eq(['bob-tool'])
      expect(seen.map(&:last)).to eq(['Bearer bob'])
    ensure
      server&.cleanup
    end
  end

  describe 'a request that fails before any response under Faraday middleware' do
    let(:token) { { value: 'alice' } }

    it 'has no private stale fallback' do
      calls = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        calls += 1
        raise Faraday::ConnectionFailed, 'reset' if calls > 1

        json_response(body['id'], { 'tools' => [tool('alice-secret')], 'ttlMs' => 0, 'cacheScope' => 'private' })
      end
      # The configured header matches the entry's context; the middleware
      # rewrites it, so it alone decides the token the request carries.
      rewriting = Class.new(Faraday::Middleware) do
        def initialize(app, holder)
          super(app)
          @holder = holder
        end

        def on_request(env)
          env.request_headers['Authorization'] = "Bearer #{@holder[:value]}"
        end
      end
      current = token
      server = streamable(headers: { 'Authorization' => 'Bearer alice' },
                          faraday_config: ->(f) { f.use rewriting, current })
      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])

      token[:value] = 'bob'

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ConnectionError)
    ensure
      server&.cleanup
    end
  end

  describe 'Faraday middleware credentials' do
    let(:token) { { value: 'alice' } }
    let(:requests) { [] }

    def stub_private_tools(fail_after: nil)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        requests << request.headers['Authorization']
        raise Faraday::TimeoutError, 'slow' if fail_after && requests.size > fail_after

        json_response(body['id'], { 'tools' => [tool('alice-secret')], 'ttlMs' => fail_after ? 0 : 60_000,
                                    'cacheScope' => 'private' })
      end
    end

    it 'serves a fresh private list when the host also installs raise_error' do
      stub_private_tools
      current = token
      server = streamable(faraday_config: lambda { |f|
        f.request :authorization, 'Bearer', -> { current[:value] }
        f.response :raise_error
      })

      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])
      expect(server.cache_fresh?(:tools)).to be(true)
      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])
      expect(requests).to eq(['Bearer alice'])
    ensure
      server&.cleanup
    end

    it 'serves the stale private list to the middleware credentials when the re-fetch times out' do
      stub_private_tools(fail_after: 1)
      current = token
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', -> { current[:value] } })
      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])

      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])
      expect(requests).to eq(['Bearer alice', 'Bearer alice'])
    ensure
      server&.cleanup
    end
  end

  describe 'SSE resource lists' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', retries: 0) }

    before do
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      allow(server).to receive(:ensure_initialized)
    end

    it 'dates a resources list from receipt, not from the end of conversion' do
      allow(server).to receive(:rpc_request).and_return(
        { 'resources' => [{ 'uri' => 'file:///a', 'name' => 'a' }], 'ttlMs' => 40, 'cacheScope' => 'public' }
      )
      allow(MCPClient::Resource).to receive(:from_json).and_wrap_original do |m, *args, **kwargs|
        sleep 0.06
        m.call(*args, **kwargs)
      end

      server.list_resources

      expect(server.cache_info(:resources)[:fresh]).to be(false)
    end

    it 'dates a templates list from receipt, not from the end of conversion' do
      allow(server).to receive(:rpc_request).and_return(
        { 'resourceTemplates' => [{ 'uriTemplate' => 'file:///{p}', 'name' => 't' }], 'ttlMs' => 40,
          'cacheScope' => 'public' }
      )
      allow(MCPClient::ResourceTemplate).to receive(:from_json).and_wrap_original do |m, *args, **kwargs|
        sleep 0.06
        m.call(*args, **kwargs)
      end

      server.list_resource_templates

      expect(server.cache_info(:templates)[:fresh]).to be(false)
    end
  end
end
