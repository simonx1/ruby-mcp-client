# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, fourteenth review round: a cached result is bound
# to the effective parameters its request went out with (the host's
# request_meta included), and the freshness probe carries the same `_meta`
# a real request carries.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 14' do
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

  # A server whose private results vary by the vendor `tenant` metadata.
  def stub_tenant_server(counts)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      tenant = body.dig('params', '_meta', 'tenant')
      counts[body['method']] += 1
      case body['method']
      when 'tools/list'
        json_response(body['id'], { 'tools' => [tool("tool-#{tenant}")], 'ttlMs' => 60_000,
                                    'cacheScope' => 'private' })
      when 'resources/read'
        json_response(body['id'], { 'contents' => [{ 'uri' => 'file:///x', 'text' => "text-#{tenant}" }],
                                    'ttlMs' => 60_000, 'cacheScope' => 'private' })
      else json_response(body['id'], discover_result)
      end
    end
  end

  it 'does not serve a list cached under other effective parameters' do
    counts = Hash.new(0)
    stub_tenant_server(counts)
    server = streamable
    server.request_meta = { 'tenant' => 'a' }
    expect(server.list_tools.map(&:name)).to eq(['tool-a'])
    expect(server.list_tools.map(&:name)).to eq(['tool-a'])
    expect(counts['tools/list']).to eq(1)

    server.request_meta = { 'tenant' => 'b' }
    expect(server.list_tools.map(&:name)).to eq(['tool-b'])
    expect(counts['tools/list']).to eq(2)
  ensure
    server&.cleanup
  end

  it 'does not serve a read cached under other effective parameters' do
    counts = Hash.new(0)
    stub_tenant_server(counts)
    server = streamable
    server.request_meta = { 'tenant' => 'a' }
    expect(server.read_resource('file:///x').first.text).to eq('text-a')
    expect(server.read_resource('file:///x').first.text).to eq('text-a')
    expect(counts['resources/read']).to eq(1)

    server.request_meta = { 'tenant' => 'b' }
    expect(server.read_resource('file:///x').first.text).to eq('text-b')
    expect(counts['resources/read']).to eq(2)
  ensure
    server&.cleanup
  end

  it 'ignores per-request trace context and progress tokens when matching' do
    counts = Hash.new(0)
    stub_tenant_server(counts)
    server = streamable
    trace = 0
    server.request_meta = lambda {
      trace += 1
      { 'tenant' => 'a', 'traceparent' => "00-#{trace.to_s.rjust(32, '0')}-0000000000000001-01",
        'tracestate' => "t=#{trace}", 'progressToken' => trace }
    }

    expect(server.list_tools.map(&:name)).to eq(['tool-a'])
    expect(server.list_tools.map(&:name)).to eq(['tool-a'])
    expect(counts['tools/list']).to eq(1)
  ensure
    server&.cleanup
  end

  it 'does not offer a stale list cached under other effective parameters as a fallback' do
    calls = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        calls += 1
        if calls == 1
          json_response(body['id'], { 'tools' => [tool('tool-a')], 'ttlMs' => 0, 'cacheScope' => 'private' })
        else
          { status: 503, body: 'down' }
        end
      else
        json_response(body['id'], discover_result)
      end
    end
    server = streamable
    server.request_meta = { 'tenant' => 'a' }
    expect(server.list_tools.map(&:name)).to eq(['tool-a'])

    server.request_meta = { 'tenant' => 'b' }
    expect { server.list_tools }.to raise_error(MCPClient::Errors::MCPError)
  ensure
    server&.cleanup
  end

  describe 'the freshness probe' do
    # Host middleware that authenticates by the tenant in the request's _meta
    # and records the protocol version the body carries.
    def meta_aware_middleware
      Class.new(Faraday::Middleware) do
        def on_request(env)
          meta = JSON.parse(env.body.to_s).dig('params', '_meta') || {}
          env.request_headers['Authorization'] = "Bearer #{meta['tenant']}" if meta['tenant']
          version = meta['io.modelcontextprotocol/protocolVersion']
          env.request_headers['X-Probe-Version'] = version if version
        end
      end
    end

    it 'never runs middleware that authenticates by the request body' do
      counts = Hash.new(0)
      stub_tenant_server(counts)
      server = streamable(faraday_config: ->(f) { f.use meta_aware_middleware })
      server.request_meta = { 'tenant' => 'a' }
      expect(server.list_tools.map(&:name)).to eq(['tool-a'])

      # Whatever such middleware would choose is unknowable without sending,
      # so no private entry of it is ever served.
      expect(server.send(:current_authorization_context, :tools))
        .to eq(MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT)
      server.request_meta = { 'tenant' => 'b' }
      expect(server.list_tools.map(&:name)).to eq(['tool-b'])
      expect(counts['tools/list']).to eq(2)
    ensure
      server&.cleanup
    end

    it 'sees the credentials the next real request would carry' do
      counts = Hash.new(0)
      stub_tenant_server(counts)
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', 'a' })
      server.request_meta = { 'tenant' => 'a' }
      expect(server.list_tools.map(&:name)).to eq(['tool-a'])
      expect(server.send(:current_authorization_context, :tools)).to eq(server.send(:request_authorization_context))

      server.request_meta = { 'tenant' => 'b' }
      expect(server.list_tools.map(&:name)).to eq(['tool-b'])
      expect(counts['tools/list']).to eq(2)
    ensure
      server&.cleanup
    end
  end
end
