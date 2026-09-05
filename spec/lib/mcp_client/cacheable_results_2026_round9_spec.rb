# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, ninth review round: a list attaches only to the
# entry its own fetch recorded, a stale copy is judged by the entry that
# supplied it, and an Authorization header added by Faraday middleware is
# part of the cache context.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 9' do
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

  def entry_for(server, kind)
    server.send(:cache_entries_mutex).synchronize { server.send(:cache_entries)[kind] }
  end

  it 'attaches a list only to the entry its own fetch recorded' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    alice_recorded = Queue.new
    bob_recorded = Queue.new
    private_hint = { 'tools' => [tool('admin-secret')], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
    public_hint = { 'tools' => [tool('public')], 'ttlMs' => 60_000, 'cacheScope' => 'public' }

    alice = Thread.new do
      server.send(:note_request_authorization, 'Bearer alice')
      server.send(:record_paginated_cache_hint, :tools, [private_hint])
      alice_recorded << true
      bob_recorded.pop
      # Alice converts last: her private list must not land on Bob's entry.
      server.send(:attach_list_value, :tools, [:alice_secret_tools])
    end
    bob = Thread.new do
      alice_recorded.pop
      server.send(:note_request_authorization, 'Bearer bob')
      server.send(:record_paginated_cache_hint, :tools, [public_hint])
      bob_recorded << true
    end
    [alice, bob].each(&:join)

    entry = entry_for(server, :tools)
    expect(entry.cache_scope).to eq('public')
    expect(entry.value).to be_nil
    expect(server.cache_fresh?(:tools)).to be(false)
  end

  it 'still attaches a list to the entry its own fetch recorded' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:note_request_authorization, 'Bearer alice')
    server.send(:record_paginated_cache_hint, :tools, [{ 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'private' }])
    server.send(:attach_list_value, :tools, [:alice_tools])

    expect(entry_for(server, :tools).value).to eq([:alice_tools])
  end

  it 'judges a stale copy by the entry that supplied it, not by the entry installed meanwhile' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:note_request_authorization, 'Bearer alice')
    server.send(:record_cache_hint, :tools, { 'ttlMs' => 0, 'cacheScope' => 'private' }, [:alice_secret])
    stale = server.send(:stale_list_entry, :tools)
    served = nil

    expect do
      served = server.send(:refetch_or_serve_stale, :tools, stale) do
        # A concurrent request under Bob's credentials installs Bob's entry,
        # then Alice's re-fetch (now carrying Bob's token) fails.
        server.send(:note_request_authorization, 'Bearer bob')
        server.send(:record_cache_hint, :tools, { 'ttlMs' => 60_000, 'cacheScope' => 'private' }, [:bob_tools])
        raise MCPClient::Errors::TransientServerError, 'HTTP 503'
      end
    end.to raise_error(MCPClient::Errors::TransientServerError)
    expect(served).to be_nil
  end

  it 'serves a stale copy to the context that produced it' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:note_request_authorization, 'Bearer alice')
    server.send(:record_cache_hint, :tools, { 'ttlMs' => 0, 'cacheScope' => 'private' }, [:alice_tools])
    stale = server.send(:stale_list_entry, :tools)

    served = server.send(:refetch_or_serve_stale, :tools, stale) do
      server.send(:note_request_authorization, 'Bearer alice')
      raise MCPClient::Errors::TransientServerError, 'HTTP 503'
    end

    expect(served).to eq([:alice_tools])
  end

  it 'keeps only a bare fetch identity on the thread, never the entry or its list' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:record_paginated_cache_hint, :tools, [{ 'tools' => [], 'ttlMs' => 60_000 }])

    remembered = Thread.current[server.send(:recorded_entries_key)][:tools]
    expect(remembered).not_to be_a(MCPClient::CachedResult)
    expect(remembered.instance_variables).to be_empty
  end

  it 'makes a fetch invalidated in flight fetch again instead of handing back another list' do
    server = streamable
    server.instance_variable_set(:@tools, [:someone_elses_list])
    generation = server.send(:tools_generation)

    expect(server.send(:store_tools, [:mine], generation - 1)).to be_nil
  end

  it 'rejects a null resources/read result on stdio' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    allow(server).to receive(:ensure_initialized)
    allow(server).to receive(:rpc_request).and_return(nil)

    expect { server.read_resource('file:///x') }.to raise_error(MCPClient::Errors::TransportError, %r{resources/read})
  end

  describe 'Authorization added by Faraday middleware' do
    let(:token) { { value: 'alice' } }
    let(:seen) { [] }

    def stub_private_tools
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        seen << request.headers['Authorization']
        json_response(body['id'], { 'tools' => [tool("tool-#{seen.size}")], 'ttlMs' => 60_000,
                                    'cacheScope' => 'private' })
      end
    end

    def middleware_server
      current = token
      streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', -> { current[:value] } })
    end

    # A static credential the probe may model: a callable one is state the
    # probe refuses to run (it could vend a different value every call), so
    # its context reads as unknown and nothing private is served for it.
    def static_middleware_server
      streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', 'alice' })
    end

    it 'binds a private list to the token the middleware sent' do
      stub_private_tools
      server = static_middleware_server

      expect(server.list_tools.map(&:name)).to eq(['tool-1'])
      expect(server.list_tools.map(&:name)).to eq(['tool-1'])
      expect(seen).to eq(['Bearer alice'])
      expect(server.cache_info(:tools)[:fresh]).to be(true)
    ensure
      server&.cleanup
    end

    it 'does not serve a private list under a token the middleware changed' do
      stub_private_tools
      server = middleware_server
      server.list_tools

      token[:value] = 'bob'

      expect(server.cache_fresh?(:tools)).to be(false)
      expect(server.list_tools.map(&:name)).to eq(['tool-2'])
      expect(seen).to eq(['Bearer alice', 'Bearer bob'])
    ensure
      server&.cleanup
    end
  end
end
