# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twenty-sixth review round: the freshness probe
# refuses to run against any shared state that can vend a different value on
# a later call (a module or class holding state of its own, a frozen wrapper
# around a mutable member), and an empty client snapshot is only a hit when
# the servers backing it recorded a freshness hint of their own.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 26' do
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

  # Spends a one-time bearer from whatever holder it was built with; the
  # holder is the host's, so a freshly built copy of the middleware shares it.
  def nonce_middleware
    Class.new(Faraday::Middleware) do
      def initialize(app, vendor)
        super(app)
        @vendor = vendor
      end

      def on_request(env)
        return unless env.body.to_s.include?('"tools/list"')

        env.request_headers['Authorization'] = "Bearer #{@vendor.next_nonce}"
      end
    end
  end

  # A module that vends one-time bearers: shared rather than copied, and
  # holding state freezing the reference would not reach.
  def nonce_module
    Module.new do
      class << self
        attr_accessor :used
      end
      self.used = 0

      def self.next_nonce
        self.used += 1
        "nonce#{used}"
      end
    end
  end

  describe 'a probe against shared state that can vend a changing value' do
    it 'reports the unknown context instead of spending a module-held nonce' do
      stub_tools_by_bearer
      vendor = nonce_module
      server = streamable(faraday_config: ->(f) { f.use nonce_middleware, vendor })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools))
        .to eq(MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT)
      expect(vendor.used).to eq(1)
    end

    it 'never skips the one-time credential of the next real request' do
      bearers = stub_tools_by_bearer
      vendor = nonce_module
      server = streamable(faraday_config: ->(f) { f.use nonce_middleware, vendor })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(vendor.used).to eq(2)
    end

    it 'reports the unknown context for a frozen wrapper around a mutable holder' do
      bearers = stub_tools_by_bearer
      # Frozen, but every instance of it hands out the same mutable Hash:
      # the middleware's copy spends the very nonces the live stack does.
      box = Data.define(:counter).new(counter: { used: 0 }).freeze
      boxed = Class.new(Faraday::Middleware) do
        def initialize(app, box)
          super(app)
          @box = box
        end

        def on_request(env)
          return unless env.body.to_s.include?('"tools/list"')

          @box.counter[:used] += 1
          env.request_headers['Authorization'] = "Bearer nonce#{@box.counter[:used]}"
        end
      end
      server = streamable(faraday_config: ->(f) { f.use boxed, box })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools))
        .to eq(MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT)
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
    end

    it 'still serves a private entry alongside framework middleware that sets no credential' do
      bearers = stub_tools_by_bearer
      server = streamable(faraday_config: lambda { |f|
        f.request :authorization, 'Bearer', 'alice'
        f.response :logger, Logger.new(File::NULL)
        f.response :raise_error
      })

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(bearers).to eq(['alice'])
    end
  end

  describe 'an empty client snapshot from a server that recorded no hint' do
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

    def client_for(*servers)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(*servers)
      MCPClient::Client.new(mcp_server_configs: servers.map { { type: 'stdio', command: 'echo test' } })
    end

    it 'asks a legacy server again for an empty tool list' do
      server, calls = stdio_server('tools/list', { 'tools' => [] })
      client = client_for(server)

      expect(client.list_tools).to eq([])
      expect(client.list_tools).to eq([])
      expect(calls.call).to eq(2)
    end

    it 'asks a legacy server again for an empty prompt list' do
      server, calls = stdio_server('prompts/list', { 'prompts' => [] })
      client = client_for(server)

      expect(client.list_prompts).to eq([])
      expect(client.list_prompts).to eq([])
      expect(calls.call).to eq(2)
    end

    it 'asks a legacy server again for an empty resource list' do
      server, calls = stdio_server('resources/list', { 'resources' => [] })
      client = client_for(server)

      expect(client.list_resources['resources']).to eq([])
      expect(client.list_resources['resources']).to eq([])
      expect(calls.call).to eq(2)
    end

    it 'still serves an empty list a 2026 server put a positive ttlMs on' do
      server, calls = stdio_server('tools/list', { 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' })
      client = client_for(server)

      expect(client.list_tools).to eq([])
      expect(client.list_tools).to eq([])
      expect(calls.call).to eq(1)
    end

    it 'still serves a non-empty legacy list without asking again' do
      server, calls = stdio_server('tools/list', { 'tools' => [tool('legacy')] })
      client = client_for(server)

      expect(client.list_tools.map(&:name)).to eq(['legacy'])
      expect(client.list_tools.map(&:name)).to eq(['legacy'])
      expect(calls.call).to eq(1)
    end
  end
  describe 'a host request_meta callable a cache decision reads' do
    it 'is evaluated once for a decision and the request it leads to' do
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << body.dig('params', '_meta', 'nonce')
        json_response(body['id'],
                      body['method'] == 'tools/list' ? { 'tools' => [tool('t')], 'ttlMs' => 60_000 } : discover_result)
      end
      spent = 0
      server = streamable
      server.request_meta = lambda {
        spent += 1
        { 'nonce' => "n#{spent}" }
      }
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])

      client.list_tools
      client.list_tools

      # Every evaluation went out on the wire, in order and exactly once:
      # nothing was spent on a cache decision that sent nothing, and each
      # request carried the metadata its own decision was made on.
      expect(sent).to eq((1..spent).map { |i| "n#{i}" })
      expect(spent).to eq(3)
    end
  end

  describe 'a cached read invalidated while it is being served' do
    it 'fetches again instead of handing out the invalidated contents' do
      uri = 'file:///doc.txt'
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'resources/read'
          reads += 1
          json_response(body['id'],
                        { 'contents' => [{ 'uri' => uri, 'text' => "v#{reads}" }], 'ttlMs' => 60_000,
                          'cacheScope' => 'public' })
        else
          json_response(body['id'], discover_result)
        end
      end
      server = streamable
      expect(server.read_resource(uri).map(&:text)).to eq(['v1'])

      # The notification lands after the entry was looked up and before its
      # contents are handed out.
      original = server.method(:private_entry_for_current_context)
      armed = true
      allow(server).to receive(:private_entry_for_current_context) do |key|
        entry = original.call(key)
        if armed && entry
          armed = false
          server.send(:invalidate_read_cache, uri)
        end
        entry
      end

      expect(server.read_resource(uri).map(&:text)).to eq(['v2'])
      expect(reads).to eq(2)
    end
  end

  describe 'the fetch identities a transport keeps on the thread' do
    it 'leaves nothing behind for a discovery or a completed list' do
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        json_response(body['id'],
                      body['method'] == 'tools/list' ? { 'tools' => [tool('t')], 'ttlMs' => 60_000 } : discover_result)
      end
      server = streamable
      server.list_tools

      expect(Thread.current[server.send(:recorded_entries_key)]).to be_nil
    end
  end
end
