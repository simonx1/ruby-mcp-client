# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirty-sixth review round: what a cached result is
# bound to is settled by the request that produced it, and by nothing that
# happens afterwards. Host metadata the caller goes on mutating, the
# `notifications/cancelled` sent for a request that was abandoned, a request a
# host `on_complete` nests inside a failing one, and a connection whose
# middleware stack was locked before the recorder could be installed all name
# a caller other than the one whose result is in hand.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 36' do
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

  def plain_http(**opts)
    MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  # A minimal OAuth provider writing whatever bearer it currently holds.
  def provider_holding(token)
    Class.new do
      def initialize(token)
        @token = token
      end

      def apply_authorization(request)
        request.headers['Authorization'] = "Bearer #{@token.value}" if @token.value
      end
    end.new(token)
  end

  def bearer_of(request)
    request.headers['Authorization'].to_s.sub(/\ABearer /, '')
  end

  describe 'host metadata rewritten while the request that carries it is in flight' do
    it 'binds a read to the tenant its own request went out with' do
      tenant = +'alice'
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        carried = body.dig('params', '_meta', 'example.com/tenant')
        sent << carried
        # The host rewrites, in place, the very string it handed the
        # transport — while this response is on its way back.
        tenant.replace('bob')
        json_response(body['id'],
                      { 'contents' => [{ 'uri' => 'file:///secret', 'text' => "#{carried}-secret" }],
                        'ttlMs' => 60_000, 'cacheScope' => 'private' })
      end

      server = streamable
      server.request_meta = { 'example.com/tenant' => tenant }
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['alice-secret'])
      expect(sent).to eq(['alice'])

      # The host asks as bob now. Alice's contents answer alice's tenant and
      # nobody else's: the entry describes the request that produced it, not
      # the metadata as it stands once the answer is in.
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['bob-secret'])
      expect(sent).to eq(%w[alice bob])
    ensure
      server&.cleanup
    end

    it 'binds a list to the nested metadata its own request went out with' do
      scope = { 'id' => 'alice' }
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        carried = body.dig('params', '_meta', 'example.com/scope', 'id')
        sent << carried
        # In place, in a container the host still holds a reference to.
        scope['id'] = 'bob'
        json_response(body['id'],
                      { 'tools' => [tool("#{carried}-tool")], 'ttlMs' => 60_000, 'cacheScope' => 'private' })
      end

      server = plain_http
      server.request_meta = { 'example.com/scope' => scope }
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])
      expect(sent).to eq(%w[alice bob])
    ensure
      server&.cleanup
    end
  end

  describe 'a request once it is built' do
    it 'carries a copy of the host metadata, so nothing the host still holds can change it' do
      tenant = +'alice'
      server = streamable
      server.request_meta = { 'example.com/tenant' => tenant }
      request = server.send(:build_jsonrpc_request, 'resources/read', { 'uri' => 'file:///a' }, 1)
      fingerprint = server.send(:request_params_fingerprint)

      tenant.replace('bob')

      # The body is generated when the request is sent, the fingerprint when
      # it is built: they describe the same request only because neither can
      # follow the host's own object.
      expect(request.dig('params', '_meta', 'example.com/tenant')).to eq('alice')
      expect(server.send(:params_fingerprint_of, request['params'])).to eq(fingerprint)
    ensure
      server&.cleanup
    end

    it 'is bound to the fingerprint taken when it was built, not to one taken from it afterwards' do
      server = streamable
      server.request_meta = { 'example.com/tenant' => 'alice' }
      request = server.send(:build_jsonrpc_request, 'tools/list', {}, 7)
      built = server.send(:request_params_fingerprint)
      response = instance_double(Faraday::Response, env: double('env', request_headers: {}))
      allow(server).to receive(:send_http_request).and_return(response)
      allow(server).to receive(:parse_response) do
        # Whatever reaches the request between its going out and its answer
        # being bound to it, the exchange is bound to what it sent.
        request['params']['_meta']['example.com/tenant'] = 'bob'
        { 'tools' => [] }
      end

      server.send(:exchange_jsonrpc, request)

      expect(server.send(:request_params_fingerprint)).to eq(built)
    ensure
      server&.cleanup
    end
  end

  describe 'a re-fetch that fails after the credentials moved on' do
    def legacy_initialize_result
      { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
        'serverInfo' => { 'name' => 'test', 'version' => '1.0' } }
    end

    it 'does not judge a timed-out re-fetch by the cancellation it sent afterwards' do
      token = Struct.new(:value).new('bob')
      seen = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        seen << [body['method'], bearer_of(request)]
        case body['method']
        when 'initialize' then json_response(body['id'], legacy_initialize_result)
        when 'tools/list'
          # Alice's re-fetch never answers; by the time the client gives up
          # on it the host holds bob's credentials again.
          if bearer_of(request) == 'alice'
            token.value = 'bob'
            raise Faraday::TimeoutError, 'execution expired'
          end

          json_response(body['id'], { 'tools' => [tool('bob-tool')], 'ttlMs' => 0, 'cacheScope' => 'private' })
        else { status: 202, body: '' }
        end
      end

      server = plain_http(protocol: :legacy, oauth_provider: provider_holding(token))
      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])

      token.value = 'alice'
      # The `notifications/cancelled` the client sends for the abandoned
      # request goes out with bob's credentials, on this very thread. It does
      # not make bob's private list alice's to serve ("MUST NOT be shared
      # across authorization contexts").
      expect { server.list_tools }.to raise_error(MCPClient::Errors::RequestTimeoutError)
      expect(seen).to include(['tools/list', 'alice'], ['notifications/cancelled', 'bob'])
    ensure
      server&.cleanup
    end

    it 'does not judge a failed exchange by a request its own response phase nested' do
      token = Struct.new(:value).new('bob')
      state = { server: nil, nested: false }
      nesting = Class.new(Faraday::Middleware) do
        define_method(:on_complete) do |env|
          request = begin
            JSON.parse(env.request_body.to_s)
          rescue StandardError
            nil
          end
          next unless request.is_a?(Hash) && request['method'] == 'tools/list'
          next if state[:nested] || token.value != 'alice'

          state[:nested] = true
          # The host rotates and sends a request of its own on this thread,
          # then the exchange it is nested in fails.
          token.value = 'bob'
          state[:server].read_resource('file:///public')
          # A failure the transport cannot salvage a delivered body from (a
          # stall after the response arrived would be the response).
          raise Faraday::SSLError, 'SSL_connect returned=1 errno=0 state=error: certificate verify failed'
        end
      end

      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'tools/list'
          json_response(body['id'],
                        { 'tools' => [tool("#{bearer_of(request)}-tool")], 'ttlMs' => 0, 'cacheScope' => 'private' })
        when 'resources/read'
          json_response(body['id'],
                        { 'contents' => [{ 'uri' => 'file:///public', 'text' => 'public' }], 'ttlMs' => 0 })
        else json_response(body['id'], discover_result)
        end
      end

      server = streamable(oauth_provider: provider_holding(token), faraday_config: ->(f) { f.use nesting })
      state[:server] = server
      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])

      token.value = 'alice'
      expect { server.list_tools }.to raise_error(MCPClient::Errors::ConnectionError)
      expect(state[:nested]).to be(true)
    ensure
      server&.cleanup
    end
  end

  describe 'a connection locked before the Authorization recorder could be installed' do
    it 'does not file an authenticated read under the anonymous context' do
      token = Struct.new(:value).new('alice')
      reads = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        bearer = bearer_of(request)
        reads << bearer
        json_response(body['id'],
                      { 'contents' => [{ 'uri' => 'file:///secret',
                                         'text' => "#{bearer.empty? ? 'anonymous' : bearer}-secret" }],
                        'ttlMs' => 60_000, 'cacheScope' => 'private' })
      end

      redacting = Class.new(Faraday::Middleware) do
        def on_complete(env)
          # A host that keeps credentials out of what it logs.
          env.request_headers.delete('Authorization')
        end
      end
      config = lambda do |f|
        f.use redacting
        # The host builds the stack itself; Faraday locks it, and the
        # recorder can no longer be installed.
        f.builder.app
      end

      server = streamable(oauth_provider: provider_holding(token), faraday_config: config)
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['alice-secret'])

      token.value = nil
      # Nothing on this connection recorded what alice's request went out
      # with, so nothing says her contents may answer an anonymous caller.
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['anonymous-secret'])
      expect(reads).to eq(['alice', ''])
    ensure
      server&.cleanup
    end
  end

  describe 'a resources/list page asked for by cursor' do
    def stub_resource_pages(counts)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/list'

        cursor = body.dig('params', 'cursor')
        counts[cursor] += 1
        result = if cursor
                   { 'resources' => [{ 'uri' => 'file:///b', 'name' => 'b' }], 'ttlMs' => 60_000,
                     'cacheScope' => 'public' }
                 else
                   { 'resources' => [{ 'uri' => 'file:///a', 'name' => 'a' }], 'nextCursor' => 'p2',
                     'ttlMs' => 60_000, 'cacheScope' => 'public' }
                 end
        json_response(body['id'], result)
      end
    end

    shared_examples 'a cursor that is part of the cache key' do
      it 'is never answered from the page cached without one' do
        counts = Hash.new(0)
        stub_resource_pages(counts)
        server = build_server

        expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
        # The first page is fresh, and a second no-cursor listing is served
        # from it without a request.
        expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
        expect(counts[nil]).to eq(1)

        # A cursor names a different position in the sequence, so it is a
        # different cache key: the spec's own example of parameters that
        # affect the result ("MUST NOT serve a cached response for a
        # different method or parameters").
        expect(server.list_resources(cursor: 'p2')['resources'].map(&:name)).to eq(['b'])
        expect(counts['p2']).to eq(1)
        expect(counts[nil]).to eq(1)
      ensure
        server&.cleanup
      end
    end

    context 'on Streamable HTTP' do
      def build_server = streamable

      it_behaves_like 'a cursor that is part of the cache key'
    end

    context 'on plain HTTP' do
      def build_server = plain_http

      it_behaves_like 'a cursor that is part of the cache key'
    end
  end

  describe 'a list whose pages disagree about their scope' do
    it 'is private as soon as one page is' do
      now = 1000.0
      pages = [{ 'ttlMs' => 60_000, 'cacheScope' => 'public' },
               { 'ttlMs' => 30_000, 'cacheScope' => 'private' }]
              .map { |result| MCPClient::CachedResult.from_result(result, nil, now: now) }

      combined = MCPClient::CachedResult.combine(pages, ['x'], now: now)

      # A server that mixes them breaks its own MUST; taking the first
      # page's scope would then share the private page across callers.
      expect(combined.cache_scope).to eq('private')
    end

    it 'is not served across authorization contexts, page 1 being public' do
      token = Struct.new(:value).new('alice')
      lists = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        bearer = bearer_of(request)
        cursor = body.dig('params', 'cursor')
        lists << [bearer, cursor]
        result = if cursor
                   { 'tools' => [tool("#{bearer}-private")], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
                 else
                   { 'tools' => [tool('shared')], 'nextCursor' => 'p2', 'ttlMs' => 60_000, 'cacheScope' => 'public' }
                 end
        json_response(body['id'], result)
      end

      server = streamable(oauth_provider: provider_holding(token))
      expect(server.list_tools.map(&:name)).to eq(%w[shared alice-private])
      expect(server.cache_info(:tools)[:cache_scope]).to eq('private')

      token.value = 'bob'
      expect(server.list_tools.map(&:name)).to eq(%w[shared bob-private])
      expect(lists).to eq([['alice', nil], %w[alice p2], ['bob', nil], %w[bob p2]])
    ensure
      server&.cleanup
    end
  end

  describe 'a resources/read whose re-fetch fails' do
    it 'raises rather than serving the stale contents, as lists may' do
      clock = { now: 1000.0 }
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        reads += 1
        next { status: 503, body: 'down' } if reads > 1

        json_response(body['id'],
                      { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'secret' }],
                        'ttlMs' => 1_000, 'cacheScope' => 'private' })
      end

      server = streamable
      allow(server).to receive(:monotonic_now) { clock[:now] }
      expect(server.read_resource('file:///a').map(&:text)).to eq(['secret'])

      clock[:now] += 2
      # "Clients MAY serve stale responses if errors occur during
      # re-fetching" — this client does so for lists and for nothing else.
      expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceReadError)
      expect(reads).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'a cached read handed to a caller' do
    it 'carries a copy of its binary contents, which the caller may change' do
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        reads += 1
        json_response(body['id'],
                      { 'contents' => [{ 'uri' => 'file:///a', 'mimeType' => 'image/png',
                                         'blob' => Base64.strict_encode64('original') }],
                        'ttlMs' => 60_000, 'cacheScope' => 'public' })
      end

      server = streamable
      first = server.read_resource('file:///a').first
      first.blob.replace(Base64.strict_encode64('rewritten'))

      # The next caller of the same cached read gets what the server sent,
      # not what the last one made of it.
      expect(server.read_resource('file:///a').first.content).to eq('original')
      expect(reads).to eq(1)
    ensure
      server&.cleanup
    end
  end

  describe 'a ttlMs that runs out with nobody asking' do
    it 'is not a poll interval: nothing is fetched until the next access' do
      clock = { now: 1000.0 }
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        lists += 1
        json_response(body['id'], { 'tools' => [tool("t#{lists}")], 'ttlMs' => 1_000, 'cacheScope' => 'public' })
      end

      server = streamable
      allow(server).to receive(:monotonic_now) { clock[:now] }
      expect(server.list_tools.map(&:name)).to eq(['t1'])

      clock[:now] += 5
      # Expiry alone fetches nothing ("clients SHOULD NOT treat ttlMs as a
      # polling interval"); the entry is simply stale when it is next read.
      expect(lists).to eq(1)
      expect(server.cache_info(:tools)[:fresh]).to be(false)

      expect(server.list_tools.map(&:name)).to eq(['t2'])
      expect(lists).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'the client cache above the transport' do
    def stub_lists(counts, tools:)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        result = case body['method']
                 when 'tools/list' then { 'tools' => tools, 'ttlMs' => 60_000, 'cacheScope' => 'public' }
                 when 'prompts/list'
                   { 'prompts' => [{ 'name' => 'p' }], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
                 when 'resources/list'
                   { 'resources' => [{ 'uri' => 'file:///a', 'name' => 'a' }], 'ttlMs' => 60_000,
                     'cacheScope' => 'public' }
                 else discover_result
                 end
        json_response(body['id'], result)
      end
    end

    # Counting wire requests cannot tell the two caches apart: the transport
    # entry would answer a second transport fetch just as silently. Counting
    # the transport calls is what makes a client hit observable.
    def counted(server, operation)
      asked = 0
      allow(server).to receive(operation).and_wrap_original do |original, *args, **kwargs|
        asked += 1
        original.call(*args, **kwargs)
      end
      -> { asked }
    end

    def client_for(server)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
    end

    it 'answers a second prompts listing without reaching the transport' do
      counts = Hash.new(0)
      stub_lists(counts, tools: [tool('a')])
      server = streamable
      asked = counted(server, :list_prompts)
      client = client_for(server)

      expect(client.list_prompts.map(&:name)).to eq(['p'])
      expect(client.list_prompts.map(&:name)).to eq(['p'])
      expect(asked.call).to eq(1)
      expect(counts['prompts/list']).to eq(1)
    ensure
      server&.cleanup
    end

    it 'answers a second resources listing without reaching the transport' do
      counts = Hash.new(0)
      stub_lists(counts, tools: [tool('a')])
      server = streamable
      asked = counted(server, :list_resources)
      client = client_for(server)

      expect(client.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(client.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(asked.call).to eq(1)
      expect(counts['resources/list']).to eq(1)
    ensure
      server&.cleanup
    end

    it 'answers a second listing of an empty, hinted list without reaching the transport' do
      counts = Hash.new(0)
      stub_lists(counts, tools: [])
      server = streamable
      asked = counted(server, :list_tools)
      client = client_for(server)

      # A server may list nothing, and its ttlMs says so for as long as it
      # holds: an empty snapshot is a hit like any other.
      expect(client.list_tools).to eq([])
      expect(client.list_tools).to eq([])
      expect(asked.call).to eq(1)
      expect(counts['tools/list']).to eq(1)
    ensure
      server&.cleanup
    end
  end
end
