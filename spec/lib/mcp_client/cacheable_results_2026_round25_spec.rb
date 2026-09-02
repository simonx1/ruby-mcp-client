# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twenty-fifth review round: the freshness probe
# leaves the request state of the connection alone (it starts from a detached
# copy of the header table, and gives up on middleware that shares mutable
# state with the live stack), and a completed list snapshot is served from
# the client cache even when every server's list is empty.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 25' do
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

  def oauth_provider(token)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) do |req|
      req.headers['Authorization'] = "Bearer #{token[:value]}" if token[:value]
    end
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
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

  describe 'the header table the probe starts from' do
    it 'is detached from the transport headers when they are a Faraday table' do
      # A host may hand the transport Faraday's own header table; the probe
      # lets the OAuth provider write into what it is given, so it must not
      # be given the very table every request is built from.
      token = { value: 'alice' }
      server = streamable(headers: Faraday::Utils::Headers.new('X-Tenant' => 'acme'),
                          oauth_provider: oauth_provider(token))

      expect(server.send(:current_authorization_context, :tools)).to eq(Digest::SHA256.hexdigest('Bearer alice'))

      # The provider has no token any more: nothing may be left over from
      # the probe that made the request look authorized.
      token[:value] = nil

      expect(server.send(:current_authorization_context, :tools)).to be_nil
      expect(server.instance_variable_get(:@headers)['Authorization']).to be_nil
    end

    it 'does not let a probe send the credentials of an earlier one' do
      bearers = stub_tools_by_bearer
      token = { value: 'alice' }
      server = streamable(headers: Faraday::Utils::Headers.new('X-Tenant' => 'acme'),
                          oauth_provider: oauth_provider(token))

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])

      token[:value] = nil

      # Without the provider's header the request goes out unauthorized;
      # the bearer of the probed context must not linger in @headers.
      server.list_tools
      expect(bearers).to eq(['alice', ''])
    end
  end

  describe 'host middleware that shares mutable state with the live stack' do
    # Spends a nonce on every tools/list it sends. The counter is the host's,
    # so a freshly built copy shares it: running the copy's request hook
    # would consume a credential no request ever carried.
    def nonce_middleware
      Class.new(Faraday::Middleware) do
        def initialize(app, counter)
          super(app)
          @counter = counter
        end

        def on_request(env)
          return unless env.body.to_s.include?('"tools/list"')

          @counter[:used] += 1
          env.request_headers['Authorization'] = "Bearer nonce#{@counter[:used]}"
        end
      end
    end

    # Reads a holder that cannot change: every instance of it answers alike,
    # and running the probe leaves nothing behind.
    def holder_middleware
      Class.new(Faraday::Middleware) do
        def initialize(app, holder)
          super(app)
          @holder = holder
        end

        def on_request(env)
          env.request_headers['Authorization'] = "Bearer #{@holder[:value]}"
        end
      end
    end

    it 'reports the unknown context instead of spending a shared nonce' do
      stub_tools_by_bearer
      counter = { used: 0 }
      server = streamable(faraday_config: ->(f) { f.use nonce_middleware, counter })
      server.list_tools

      expect(server.send(:current_authorization_context, :tools))
        .to eq(MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT)
      expect(counter[:used]).to eq(1)
    end

    it 'never skips a one-time credential of the next real request' do
      bearers = stub_tools_by_bearer
      counter = { used: 0 }
      server = streamable(faraday_config: ->(f) { f.use nonce_middleware, counter })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(counter[:used]).to eq(2)
    end

    it 'still serves a private entry when the shared state cannot change' do
      bearers = stub_tools_by_bearer
      holder = { value: 'alice' }.freeze
      server = streamable(faraday_config: ->(f) { f.use holder_middleware, holder })

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(bearers).to eq(['alice'])
    end
  end

  describe 'a client snapshot whose lists are all empty' do
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

    it 'serves an empty tool list without asking the server again' do
      server, calls = stdio_server('tools/list', { 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' })
      client = client_for(server)

      expect(client.list_tools).to eq([])
      expect(client.list_tools).to eq([])
      expect(calls.call).to eq(1)
    end

    it 'serves an empty prompt list without asking the server again' do
      server, calls = stdio_server('prompts/list', { 'prompts' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' })
      client = client_for(server)

      expect(client.list_prompts).to eq([])
      expect(client.list_prompts).to eq([])
      expect(calls.call).to eq(1)
    end

    it 'serves an empty resource list without asking the server again' do
      server, calls = stdio_server('resources/list', { 'resources' => [], 'ttlMs' => 60_000,
                                                       'cacheScope' => 'public' })
      client = client_for(server)

      expect(client.list_resources['resources']).to eq([])
      expect(client.list_resources['resources']).to eq([])
      expect(calls.call).to eq(1)
    end

    it 'asks again once the empty list has gone stale' do
      server, calls = stdio_server('tools/list', { 'tools' => [], 'ttlMs' => 0, 'cacheScope' => 'public' })
      client = client_for(server)

      client.list_tools
      client.list_tools

      expect(calls.call).to eq(2)
    end

    it 'does not serve a snapshot a server has no slice of' do
      first, = stdio_server('tools/list',
                            { 'tools' => [{ 'name' => 'early', 'inputSchema' => { 'type' => 'object' } }],
                              'ttlMs' => 60_000, 'cacheScope' => 'public' })
      second = MCPClient::ServerStdio.new(command: 'echo test')
      allow(second).to receive(:ensure_initialized)
      attempts = 0
      allow(second).to receive(:list_tools) do
        attempts += 1
        raise MCPClient::Errors::ConnectionError, 'server unreachable' if attempts == 1

        [MCPClient::Tool.new(name: 'late', description: 'l', schema: { 'type' => 'object' }, server: second)]
      end
      client = client_for(first, second)

      # The failed server never filled a slice: the snapshot is incomplete
      # however many tools the other server put in it.
      expect(client.list_tools.map(&:name)).to eq(['early'])
      expect(client.list_tools.map(&:name)).to eq(%w[early late])
    end
  end
end
