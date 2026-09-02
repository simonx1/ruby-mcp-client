# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, eighteenth review round: a client-level cache slice
# is tied to the very transport entry it was filled from, an invalidation of
# one key does not discard another key's in-flight hint, and the client
# capabilities a request advertises are part of what a cached result is
# bound to.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 18' do
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

  def client_for(server)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
  end

  def rotate_token(server, token)
    server.instance_variable_get(:@headers)['Authorization'] = "Bearer #{token}"
  end

  # A server whose private tool list varies by the bearer token.
  def stub_token_server(counts, &on_list)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      if body['method'] == 'tools/list'
        on_list&.call
        who = request.headers['Authorization'].to_s.delete_prefix('Bearer ')
        json_response(body['id'], { 'tools' => [tool("tool-#{who}")], 'ttlMs' => 60_000,
                                    'cacheScope' => 'private' })
      else
        json_response(body['id'], discover_result)
      end
    end
  end

  it 'ties a client cache slice to the transport entry it was filled from' do
    counts = Hash.new(0)
    stub_token_server(counts)
    server = streamable(headers: { 'Authorization' => 'Bearer alice' })
    client = client_for(server)

    expect(client.list_tools.map(&:name)).to eq(['tool-alice'])

    # The transport list is refreshed on its own after the credentials
    # rotated: the transport now holds Bob's fresh private entry while the
    # client cache still holds Alice's slice.
    rotate_token(server, 'bob')
    expect(server.list_tools.map(&:name)).to eq(['tool-bob'])

    expect(client.list_tools.map(&:name)).to eq(['tool-bob'])
    expect(counts['tools/list']).to eq(2)
  end

  it 'keeps a client cache slice served from the entry it was filled from' do
    counts = Hash.new(0)
    stub_token_server(counts)
    server = streamable(headers: { 'Authorization' => 'Bearer alice' })
    client = client_for(server)

    expect(client.list_tools.map(&:name)).to eq(['tool-alice'])
    expect(client.list_tools.map(&:name)).to eq(['tool-alice'])
    expect(counts['tools/list']).to eq(1)
  end

  it 'does not discard a list hint because another key was invalidated in flight' do
    counts = Hash.new(0)
    server = streamable
    stub_token_server(counts) { server.send(:invalidate_read_cache, 'file:///unrelated') }

    server.list_tools

    expect(server.cache_info(:tools)).to include(fresh: true)
    server.list_tools
    expect(counts['tools/list']).to eq(1)
  end

  it 'still drops a list hint invalidated in flight for its own key' do
    counts = Hash.new(0)
    server = streamable
    stub_token_server(counts) { server.send(:invalidate_cache, :tools) }

    server.list_tools

    expect(server.cache_info(:tools)).to include(fresh: false)
    server.list_tools
    expect(counts['tools/list']).to eq(2)
  end

  it 'misses the client cache once the transport re-fetched after the TTL elapsed' do
    counts = Hash.new(0)
    versions = %w[v1 v2].cycle
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      if body['method'] == 'tools/list'
        json_response(body['id'], { 'tools' => [tool("tool-#{versions.next}")], 'ttlMs' => 80 })
      else
        json_response(body['id'], discover_result)
      end
    end
    server = streamable
    client = client_for(server)

    expect(client.list_tools.map(&:name)).to eq(['tool-v1'])
    sleep 0.12
    expect(server.list_tools.map(&:name)).to eq(['tool-v2'])

    expect(client.list_tools.map(&:name)).to eq(['tool-v2'])
    expect(counts['tools/list']).to eq(2)
  end

  it 'serves no public stale copy to a re-fetch that never built its request' do
    counts = Hash.new(0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      if body['method'] == 'tools/list'
        tenant = body.dig('params', '_meta', 'tenant')
        json_response(body['id'], { 'tools' => [tool("tool-#{tenant}")], 'ttlMs' => 0, 'cacheScope' => 'public' })
      else
        json_response(body['id'], discover_result)
      end
    end
    server = streamable
    server.request_meta = { 'tenant' => 'a' }
    expect(server.list_tools.map(&:name)).to eq(['tool-a'])

    server.request_meta = { 'tenant' => 'b' }
    lists = 0
    allow(server).to receive(:build_jsonrpc_request).and_wrap_original do |m, *args, **kw|
      raise MCPClient::Errors::ConnectionError, 'gone' if args[0] == 'tools/list' && (lists += 1) >= 1

      m.call(*args, **kw)
    end

    expect { server.list_tools }.to raise_error(MCPClient::Errors::ConnectionError)
  end

  it 'binds a cached result to the client capabilities the request advertised' do
    counts = Hash.new(0)
    stub_token_server(counts)
    server = streamable

    before = server.send(:current_params_fingerprint)
    server.list_tools
    server.declare_extension('io.example/feature')

    expect(server.send(:current_params_fingerprint)).not_to eq(before)
    server.list_tools
    expect(counts['tools/list']).to eq(2)
  end
end
