# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, eighth review round: a hint recorded without its
# list never gates serving a previous list, HTTP+SSE binds results to the
# credentials of the POST that fetched them, a re-fetch that never recorded
# its credentials has no stale fallback, a malformed resources/read result
# is rejected, and a read's receipt time precedes its conversion.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 8' do
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

  def scripted_provider(tokens)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) do |req|
      token = tokens.size > 1 ? tokens.shift : tokens.first
      raise token if token.is_a?(Exception)

      req.headers['Authorization'] = "Bearer #{token}" if token
    end
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
  end

  def streamable(provider = nil, headers: {})
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                        oauth_provider: provider, headers: headers)
  end

  # Alice lists private tools; Bob's re-fetch records a fresh public hint
  # whose list cannot be converted. Nothing may serve Alice's list to Bob.
  def stub_failed_refetch
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

      lists += 1
      result = case lists
               when 1 then { 'tools' => [tool('admin-secret')], 'ttlMs' => 0, 'cacheScope' => 'private' }
               when 2 then { 'tools' => ['malformed'], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
               else { 'tools' => [tool('bob-tool')], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
               end
      json_response(body['id'], result)
    end
    -> { lists }
  end

  it 'never serves the previous list under a hint recorded without one' do
    lists = stub_failed_refetch
    server = streamable(scripted_provider(%w[alice alice bob]))

    expect(server.list_tools.map(&:name)).to eq(['admin-secret'])
    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError)
    expect(server.cache_fresh?(:tools)).to be(false)
    expect(server.list_tools.map(&:name)).to eq(['bob-tool'])
    expect(lists.call).to eq(3)
  ensure
    server&.cleanup
  end

  it 'does not let the client serve its own tool cache under a hint recorded without a list' do
    stub_failed_refetch
    server = streamable(scripted_provider(%w[alice alice bob]))
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: url }])

    expect(client.list_tools.map(&:name)).to eq(['admin-secret'])
    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError)
    expect(client.list_tools.map(&:name)).to eq(['bob-tool'])
  ensure
    server&.cleanup
  end

  it 'has no stale fallback for a re-fetch that never recorded its credentials' do
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

      lists += 1
      json_response(body['id'], { 'tools' => [tool('admin-secret')], 'ttlMs' => 0, 'cacheScope' => 'private' })
    end
    provider = scripted_provider(['alice'])
    server = streamable(provider)

    expect(server.list_tools.map(&:name)).to eq(['admin-secret'])
    # Bob's token is known to the probe, but applying it to the real
    # request fails before the request's headers are recorded.
    allow(provider).to receive(:apply_authorization) do |req|
      unless req.is_a?(MCPClient::HttpTransportBase::CacheSupport::HeaderProbe)
        raise MCPClient::Errors::ConnectionError, 'token endpoint unreachable'
      end

      req.headers['Authorization'] = 'Bearer bob'
    end
    expect { server.list_tools }.to raise_error(MCPClient::Errors::ConnectionError, /token endpoint/)
    expect(lists).to eq(1)
  ensure
    server&.cleanup
  end

  it 'dates a cached read from its receipt, not from the end of its conversion' do
    reads = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      result = if body['method'] == 'resources/read'
                 reads += 1
                 { 'contents' => [{ 'uri' => 'file:///a', 'text' => "read #{reads}" }], 'ttlMs' => 100 }
               else
                 discover_result
               end
      json_response(body['id'], result)
    end
    server = streamable
    clock = { now: 0.0 }
    allow(server).to receive(:monotonic_now) { clock[:now] }
    # Converting the contents takes longer than the TTL.
    allow(MCPClient::ResourceContent).to receive(:from_json).and_wrap_original do |original, *args|
      clock[:now] += 0.2
      original.call(*args)
    end

    expect(server.read_resource('file:///a').first.text).to eq('read 1')
    expect(server.cache_info(:read, 'file:///a')).to include(fresh: false)
    expect(server.read_resource('file:///a').first.text).to eq('read 2')
  ensure
    server&.cleanup
  end

  describe 'on HTTP+SSE' do
    let(:server) do
      MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', headers: { 'Authorization' => 'Bearer alice' })
    end

    before do
      allow(server).to receive(:ensure_initialized)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server.instance_variable_set(:@use_sse, false)
      server.instance_variable_set(:@rpc_endpoint, '/messages')
    end

    it 'binds a private result to the credentials of the POST that fetched it' do
      counts = Hash.new(0)
      stub_request(:post, 'https://example.com/messages').to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        result = case body['method']
                 when 'tools/list'
                   { 'tools' => [tool('mine')], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
                 when 'resources/read'
                   { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'secret' }], 'ttlMs' => 60_000,
                     'cacheScope' => 'private' }
                 end
        json_response(body['id'], result)
      end

      2.times { expect(server.list_tools.map(&:name)).to eq(['mine']) }
      2.times { expect(server.read_resource('file:///a').first.text).to eq('secret') }

      expect(counts).to eq('tools/list' => 1, 'resources/read' => 1)
    end

    # A modern server's result is already checked at the protocol level; a
    # legacy server's malformed read must not turn into an empty resource.
    it 'rejects a resources/read result that is not an object' do
      results = [[], 'text', 7]
      allow(server).to receive(:rpc_request).with('resources/read', anything) { results.shift }

      3.times do
        expect { server.read_resource('file:///a') }
          .to raise_error(MCPClient::Errors::TransportError, %r{resources/read})
      end
    end
  end
end
