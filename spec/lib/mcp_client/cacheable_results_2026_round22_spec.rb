# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twenty-second review round: a client-level
# snapshot and a stale fallback never outlive a cleanup that raced them.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 22' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def streamable
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
  end

  def stub_server(counts, ttl_ms:, scope:, &during_list)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      if body['method'] == 'tools/list'
        override = during_list&.call(counts['tools/list'])
        override || json_response(body['id'], { 'tools' => [{ 'name' => "tool-#{counts['tools/list']}",
                                                              'inputSchema' => { 'type' => 'object' } }],
                                                'ttlMs' => ttl_ms, 'cacheScope' => scope })
      else
        json_response(body['id'], discover_result)
      end
    end
  end

  it 'does not serve a client snapshot when cleanup raced the freshness verdict' do
    counts = Hash.new(0)
    server = streamable
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
    stub_server(counts, ttl_ms: 60_000, scope: 'public')

    expect(client.list_tools.map(&:name)).to eq(['tool-1'])

    # cleanup lands between the verdict and the copy
    allow(client).to receive(:caches_fresh?).and_wrap_original do |original, *args|
      verdict = original.call(*args)
      server.cleanup
      verdict
    end

    expect(client.list_tools.map(&:name)).to eq(['tool-2'])
    expect(counts['tools/list']).to eq(2)
  end

  it 'clears the client caches on Client#cleanup' do
    counts = Hash.new(0)
    server = streamable
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
    stub_server(counts, ttl_ms: 60_000, scope: 'public')

    client.list_tools
    client.cleanup

    expect(client.tool_cache).to be_empty
    expect(client.list_tools.map(&:name)).to eq(['tool-2'])
  end

  it 'copies a very deep peer schema through the client cache without overflowing the stack' do
    # JSON parsing bounds what arrives over the wire; a schema built by the
    # host (or a future transport) reaches the cache copies all the same.
    server = streamable
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
    deep = { 'type' => 'object' }
    100_000.times { |i| deep = i.even? ? { 'properties' => { 'p' => deep } } : { 'items' => [deep] } }
    tool = MCPClient::Tool.new(name: 'deep', description: 'd', schema: deep, server: server)

    copies = nil
    expect { copies = client.send(:cached_copies, { 'deep' => tool }) }.not_to raise_error
    copied = copies.first.schema
    expect(copied).not_to equal(deep)
    # Walked iteratively too: comparing the documents whole would recurse.
    depth = 0
    node = copied
    while node.is_a?(Hash) || node.is_a?(Array)
      depth += 1
      node = node.is_a?(Hash) ? node.values.first : node.first
    end
    expect(depth).to be > 100_000
    expect(node).to eq('object')
  end

  it 'does not serve a stale list that cleanup forgot while the re-fetch was in flight' do
    counts = Hash.new(0)
    server = streamable
    stub_server(counts, ttl_ms: 0, scope: 'private') do |n|
      next nil unless n == 2

      server.cleanup
      { status: 503, body: '', headers: {} }
    end

    expect(server.list_tools.map(&:name)).to eq(['tool-1'])
    expect { server.list_tools }.to raise_error(MCPClient::Errors::MCPError)
  end
end
