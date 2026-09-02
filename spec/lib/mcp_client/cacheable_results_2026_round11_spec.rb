# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, eleventh review round: the freshness probe sees
# the request shape the real POST has (endpoint, body) and gives up rather
# than guess when host middleware cannot be run faithfully; the read-cache
# epoch is taken after the session exists; an old epoch never overwrites a
# newer entry; the per-URI read cache is bounded and expires.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 11' do
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

  describe 'the freshness probe' do
    let(:requests) { [] }

    def stub_private_tools
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        owner = request.headers['Authorization'].to_s.sub('Bearer ', '')
        requests << owner
        json_response(body['id'], { 'tools' => [tool("#{owner}-tool")], 'ttlMs' => 60_000,
                                    'cacheScope' => 'private' })
      end
    end

    it 'sees the endpoint and body a real request carries' do
      stub_private_tools
      holder = { value: 'alice' }
      # Path-aware middleware: only requests to the endpoint get the token.
      path_aware = Class.new(Faraday::Middleware) do
        def initialize(app, holder)
          super(app)
          @holder = holder
        end

        def on_request(env)
          return unless env.url.path == '/mcp' && env.body.to_s.include?('"jsonrpc"')

          env.request_headers['Authorization'] = "Bearer #{@holder[:value]}"
        end
      end
      server = streamable(headers: { 'Authorization' => 'Bearer alice' },
                          faraday_config: ->(f) { f.use path_aware, holder })
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])

      holder[:value] = 'bob'

      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])
      expect(requests).to eq(%w[alice bob])
    ensure
      server&.cleanup
    end

    it 'treats the context as unknown when host middleware cannot be run without sending' do
      stub_private_tools
      opaque = Class.new(Faraday::Middleware) do
        def call(env)
          env.request_headers['Authorization'] = 'Bearer alice'
          @app.call(env)
        end
      end
      server = streamable(headers: { 'Authorization' => 'Bearer alice' }, faraday_config: ->(f) { f.use opaque })
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])

      expect(server.send(:current_authorization_context)).to eq(:unknown)
      # A private entry cannot be matched to an unknown context: re-fetch.
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(requests.size).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'the read-cache epoch on a fresh connection' do
    def stub_reads(reads)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'resources/read'
          reads << body['params']['uri']
          json_response(body['id'], { 'contents' => [{ 'uri' => body['params']['uri'], 'text' => 'hi' }],
                                      'ttlMs' => 60_000 })
        when 'resources/templates/list'
          json_response(body['id'], { 'resourceTemplates' => [], 'ttlMs' => 60_000 })
        else json_response(body['id'], {})
        end
      end
    end

    it 'caches the first read on a fresh plain HTTP transport' do
      reads = []
      stub_reads(reads)
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)

      server.read_resource('file:///a')
      server.read_resource('file:///a')

      expect(reads).to eq(['file:///a'])
      expect(server.cache_info(:read, 'file:///a')[:fresh]).to be(true)
    ensure
      server&.cleanup
    end

    it 'records a fresh templates hint on a fresh plain HTTP transport' do
      stub_reads([])
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)

      server.list_resource_templates

      expect(server.cache_info(:templates)[:fresh]).to be(true)
    ensure
      server&.cleanup
    end

    it 'caches the first read on a fresh Streamable HTTP transport' do
      reads = []
      stub_reads(reads)
      server = streamable

      server.read_resource('file:///a')
      server.read_resource('file:///a')

      expect(reads).to eq(['file:///a'])
    ensure
      server&.cleanup
    end
  end

  describe 'an old epoch completing after a newer entry' do
    let(:server) { streamable }

    it 'keeps the newer list entry' do
      server.record_cache_hint(:tools, { 'ttlMs' => 60_000, 'cacheScope' => 'public' }, ['old'],
                               epoch: server.cache_epoch)
      old_epoch = server.cache_epoch
      server.invalidate_cache(:tools)
      newer = server.record_cache_hint(:tools, { 'ttlMs' => 60_000, 'cacheScope' => 'public' }, ['new'],
                                       epoch: server.cache_epoch)

      late = server.record_cache_hint(:tools, { 'ttlMs' => 60_000, 'cacheScope' => 'public' }, ['late'],
                                      epoch: old_epoch)

      expect(server.cache_entries[:tools]).to equal(newer)
      expect(server.cache_fresh?(:tools)).to be(true)
      expect(late).not_to be_fresh(now: server.monotonic_now)
    end

    it 'keeps the newer paginated entry' do
      old_epoch = server.cache_epoch
      server.invalidate_cache(:prompts)
      newer = server.record_paginated_cache_hint(:prompts, [{ 'ttlMs' => 60_000, 'cacheScope' => 'public' }], ['new'],
                                                 epoch: server.cache_epoch)

      server.record_paginated_cache_hint(:prompts, [{ 'ttlMs' => 60_000, 'cacheScope' => 'public' }], ['late'],
                                         epoch: old_epoch)

      expect(server.cache_entries[:prompts]).to equal(newer)
    end
  end

  describe 'the per-URI read cache' do
    let(:reads) { [] }

    def stub_reads(ttl_for)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        uri = body['params']['uri']
        reads << uri
        result = { 'contents' => [{ 'uri' => uri, 'text' => 'x' * 10 }] }
        ttl = ttl_for.call(uri)
        result['ttlMs'] = ttl unless ttl.nil?
        json_response(body['id'], result)
      end
    end

    def read_keys(server)
      server.cache_entries.keys.grep(/\Aread:/)
    end

    it 'does not retain reads that are never fresh' do
      stub_reads(->(uri) { uri.end_with?('zero') ? 0 : nil })
      server = streamable
      server.read_resource('file:///zero')
      server.read_resource('file:///absent')

      expect(read_keys(server)).to be_empty
    ensure
      server&.cleanup
    end

    it 'is bounded and evicts the oldest reads first' do
      stub_reads(->(_uri) { 60_000 })
      server = streamable
      limit = MCPClient::ResultCaching::MAX_CACHED_READS
      (limit + 5).times { |i| server.read_resource("file:///r#{i}") }

      expect(read_keys(server).size).to eq(limit)
      expect(read_keys(server)).not_to include('read:file:///r0')
      expect(read_keys(server)).to include("read:file:///r#{limit + 4}")
    ensure
      server&.cleanup
    end

    it 'drops expired reads when a new one is stored' do
      stub_reads(->(uri) { uri.end_with?('short') ? 1 : 60_000 })
      server = streamable
      server.read_resource('file:///short')
      sleep 0.01
      server.read_resource('file:///long')

      expect(read_keys(server)).to eq(['read:file:///long'])
    ensure
      server&.cleanup
    end
  end
end
