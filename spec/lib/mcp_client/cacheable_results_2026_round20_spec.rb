# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twentieth review round: cache_info hands out
# detached values, per-URI invalidation generations are bounded, client
# identity is part of what a cached result is bound to, and a freshness
# callback that clears the client cache cannot deadlock.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 20' do
  let(:url) { 'https://example.com/mcp' }
  let(:uri) { 'file:///secret' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def stub_server(counts)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      case body['method']
      when 'resources/read'
        json_response(body['id'], { 'contents' => [{ 'uri' => uri, 'text' => 'top secret' }],
                                    'ttlMs' => 60_000, 'cacheScope' => 'private' })
      when 'tools/list'
        json_response(body['id'], { 'tools' => [{ 'name' => 'tool', 'inputSchema' => { 'type' => 'object' } }],
                                    'ttlMs' => 60_000 })
      else
        json_response(body['id'], discover_result)
      end
    end
  end

  it 'hands out cache_info values detached from the entry' do
    counts = Hash.new(0)
    stub_server(counts)
    server = streamable(headers: { 'Authorization' => 'Bearer alice' })
    server.read_resource(uri)

    scope = server.cache_info(:read, uri)[:cache_scope]
    scope.upcase! unless scope.frozen?
    expect(server.cache_info(:read, uri)[:cache_scope]).to eq('private')

    server.instance_variable_get(:@headers)['Authorization'] = 'Bearer bob'
    server.read_resource(uri)
    expect(counts['resources/read']).to eq(2)
  end

  it 'bounds the per-URI invalidation generations' do
    server = streamable

    2_000.times { |i| server.send(:invalidate_read_cache, "file:///r#{i}") }

    generations = server.instance_variable_get(:@cache_generations) || {}
    expect(generations.size).to be <= MCPClient::ResultCaching::MAX_READ_GENERATIONS + 1
  end

  it 'varies the parameters fingerprint with the client identity' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    before = server.send(:current_params_fingerprint)

    server.client_info = { name: 'other-host', version: '9.9' }
    after = server.send(:current_params_fingerprint)
    server.send_client_info = false
    without = server.send(:current_params_fingerprint)

    expect(after).not_to eq(before)
    expect(without).not_to eq(after)
  end

  it 'does not deadlock when a freshness callback clears the client cache' do
    counts = Hash.new(0)
    stub_server(counts)
    server = streamable
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
    client.list_tools
    server.request_meta = lambda {
      client.clear_cache
      {}
    }

    expect { client.list_tools }.not_to raise_error
    expect(client.list_tools.map(&:name)).to eq(['tool'])
  end
end
