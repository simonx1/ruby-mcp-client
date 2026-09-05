# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirty-fifth review round: what a result is bound to
# — the credentials its own request carried and the moment its response was
# received — is fixed by the innermost middleware on the connection, so a host
# `on_complete` that nests a request of its own, or simply takes its time,
# cannot rewrite either. A cursor the server rejects takes the pages cached
# under it with it on every transport, stdio included.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 35' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def error_response(id, code, message)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id,
                                       'error' => { 'code' => code, 'message' => message }),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  # A minimal OAuth provider: it writes whatever bearer it currently holds.
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

  describe 'a response phase that sends a request of its own' do
    # No request phase, so the freshness probe steps over it — but its
    # response phase rotates the credentials and sends a nested request on
    # this very thread, before the outer exchange has bound its own result.
    def nesting_middleware(state)
      Class.new(Faraday::Middleware) do
        define_method(:on_complete) do |env|
          request = begin
            JSON.parse(env.request_body.to_s)
          rescue StandardError
            nil
          end
          next unless request.is_a?(Hash) && request['method'] == 'resources/read'
          next unless request.dig('params', 'uri') == 'file:///secret'
          next if state[:nested]

          state[:nested] = true
          state[:token].value = 'bob'
          state[:server].read_resource('file:///public')
        end
      end
    end

    it 'does not bind a private read to the credentials of the request it nested' do
      reads = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'resources/read'
          bearer = request.headers['Authorization'].to_s.sub(/\ABearer /, '')
          uri = body.dig('params', 'uri')
          reads << [bearer, uri]
          json_response(body['id'],
                        { 'contents' => [{ 'uri' => uri, 'text' => "#{bearer}:#{uri}" }],
                          'ttlMs' => 60_000, 'cacheScope' => 'private' })
        else
          json_response(body['id'], discover_result)
        end
      end

      token = Struct.new(:value).new('alice')
      state = { token: token, server: nil, nested: false }
      klass = nesting_middleware(state)
      server = streamable(oauth_provider: provider_holding(token), faraday_config: ->(f) { f.use klass })
      state[:server] = server

      expect(server.read_resource('file:///secret').map(&:text)).to eq(['alice:file:///secret'])
      expect(state[:nested]).to be(true)

      # Bob holds the credentials now. Alice's private read is bound to
      # Alice, not to the nested request Bob sent from her response's
      # middleware, so it must not answer him ("MUST NOT be shared across
      # authorization contexts").
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['bob:file:///secret'])
      expect(reads).to eq([['alice', 'file:///secret'], ['bob', 'file:///public'], ['bob', 'file:///secret']])
    ensure
      server&.cleanup
    end
  end

  describe 'a response phase that takes its time' do
    # Advances the clock the transport reads, in the response phase, after
    # the bytes are in hand: freshness runs from receipt, not from the end
    # of the host middleware that ran on the way out.
    def slow_middleware(state)
      Class.new(Faraday::Middleware) do
        define_method(:on_complete) do |env|
          request = begin
            JSON.parse(env.request_body.to_s)
          rescue StandardError
            nil
          end
          next unless request.is_a?(Hash) && state[:methods].include?(request['method'])

          state[:clock] += state[:delay]
        end
      end
    end

    def stub_slow_server(counts, method, result)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        body['method'] == method ? json_response(body['id'], result) : json_response(body['id'], discover_result)
      end
    end

    it 'starts a read TTL at receipt, not after the response middleware ran' do
      counts = Hash.new(0)
      stub_slow_server(counts, 'resources/read',
                       { 'contents' => [{ 'uri' => 'file:///x', 'text' => 'x' }], 'ttlMs' => 1000 })
      state = { clock: 0.0, delay: 100.0, methods: ['resources/read'] }
      klass = slow_middleware(state)
      server = streamable(faraday_config: ->(f) { f.use klass })
      allow(server).to receive(:monotonic_now) { state[:clock] }

      expect(server.read_resource('file:///x').first.text).to eq('x')
      # The response was received at t=0 and its TTL ran out at t=1; the
      # middleware that ran afterwards took until t=100.
      expect(server.read_resource('file:///x').first.text).to eq('x')
      expect(counts['resources/read']).to eq(2)
    ensure
      server&.cleanup
    end

    it 'starts a list TTL at receipt, not after the response middleware ran' do
      counts = Hash.new(0)
      stub_slow_server(counts, 'tools/list',
                       { 'tools' => [{ 'name' => 'a', 'inputSchema' => { 'type' => 'object' } }], 'ttlMs' => 1000 })
      state = { clock: 0.0, delay: 100.0, methods: ['tools/list'] }
      klass = slow_middleware(state)
      server = streamable(faraday_config: ->(f) { f.use klass })
      allow(server).to receive(:monotonic_now) { state[:clock] }

      expect(server.list_tools.map(&:name)).to eq(['a'])
      expect(server.cache_fresh?(:tools)).to be(false)
      expect(server.list_tools.map(&:name)).to eq(['a'])
      expect(counts['tools/list']).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'a cursor the server no longer accepts' do
    it 'takes the pages cached under it with it when the restart then fails' do
      clock = [0.0]
      script = [
        { 'tools' => [tool('a')], 'nextCursor' => 'p2', 'ttlMs' => 60_000 },
        { 'tools' => [tool('b')], 'ttlMs' => 60_000 },
        { 'tools' => [tool('c')], 'nextCursor' => 'p2b', 'ttlMs' => 60_000 },
        :invalid_cursor,
        :unavailable
      ]
      cursors = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        cursors << body.dig('params', 'cursor')
        case (step = script.shift)
        when :invalid_cursor then error_response(body['id'], -32_602, 'Invalid cursor')
        when :unavailable then { status: 503, body: 'busy' }
        else json_response(body['id'], step)
        end
      end
      server = streamable
      allow(server).to receive(:monotonic_now) { clock[0] }

      expect(server.list_tools.map(&:name)).to eq(%w[a b])
      clock[0] = 100.0

      # The server rejected the cursor its own first replacement page issued:
      # the sequence those pages belong to is gone, so the aggregate cached
      # from the previous sequence must not be served when the restart then
      # fails transiently.
      expect { server.list_tools }.to raise_error(MCPClient::Errors::TransientServerError)
      expect(cursors).to eq([nil, 'p2', nil, 'p2b', nil])
      expect(server.cache_info(:tools)&.dig(:fresh)).not_to be(true)
    ensure
      server&.cleanup
    end

    it 'restarts a stdio tools list from the first page' do
      attempts = { 'tools/list' => 0 }
      cursors = []
      server, = stdio_server do |request|
        next { 'result' => discover_result } unless request['method'] == 'tools/list'

        cursor = request.dig('params', 'cursor') || request.dig(:params, :cursor)
        cursors << cursor
        next { 'error' => { 'code' => -32_602, 'message' => 'Invalid cursor' } } if cursor == 'dead'

        attempts['tools/list'] += 1
        if attempts['tools/list'] == 1
          { 'result' => { 'tools' => [tool('stale')], 'nextCursor' => 'dead' } }
        else
          { 'result' => { 'tools' => [tool('x'), tool('y')] } }
        end
      end

      expect(server.list_tools.map(&:name)).to eq(%w[x y])
      expect(cursors).to eq([nil, 'dead', nil])
    ensure
      server&.cleanup
    end

    it 'restarts a stdio prompts list from the first page' do
      attempts = { 'prompts/list' => 0 }
      cursors = []
      server, = stdio_server do |request|
        next { 'result' => discover_result } unless request['method'] == 'prompts/list'

        cursor = request.dig('params', 'cursor') || request.dig(:params, :cursor)
        cursors << cursor
        next { 'error' => { 'code' => -32_602, 'message' => 'Invalid cursor' } } if cursor == 'dead'

        attempts['prompts/list'] += 1
        if attempts['prompts/list'] == 1
          { 'result' => { 'prompts' => [{ 'name' => 'stale' }], 'nextCursor' => 'dead' } }
        else
          { 'result' => { 'prompts' => [{ 'name' => 'p1' }, { 'name' => 'p2' }] } }
        end
      end

      expect(server.list_prompts.map(&:name)).to eq(%w[p1 p2])
      expect(cursors).to eq([nil, 'dead', nil])
    ensure
      server&.cleanup
    end

    it 'raises a second rejection instead of restarting again' do
      cursors = []
      server, = stdio_server do |request|
        next { 'result' => discover_result } unless request['method'] == 'tools/list'

        cursor = request.dig('params', 'cursor') || request.dig(:params, :cursor)
        cursors << cursor
        next { 'error' => { 'code' => -32_602, 'message' => 'Invalid cursor' } } if cursor == 'dead'

        { 'result' => { 'tools' => [tool('a')], 'nextCursor' => 'dead' } }
      end

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError)
      expect(cursors).to eq([nil, 'dead', nil, 'dead'])
    ensure
      server&.cleanup
    end

    it 'does not restart a stdio list the server rejected the first page of' do
      cursors = []
      server, = stdio_server do |request|
        next { 'result' => discover_result } unless request['method'] == 'tools/list'

        cursors << (request.dig('params', 'cursor') || request.dig(:params, :cursor))
        { 'error' => { 'code' => -32_602, 'message' => 'Invalid params' } }
      end

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError)
      expect(cursors).to eq([nil])
    ensure
      server&.cleanup
    end
  end

  describe 'a modern result that names its own type' do
    # Every cacheable result as the 2026-07-28 specification writes it: with
    # the `resultType` discriminator the published examples carry, alongside
    # the freshness hint it is cached under.
    def complete_payloads
      { 'tools/list' => { 'tools' => [{ 'name' => 'a', 'inputSchema' => { 'type' => 'object' } }] },
        'prompts/list' => { 'prompts' => [{ 'name' => 'p' }] },
        'resources/list' => { 'resources' => [{ 'uri' => 'file:///r', 'name' => 'r' }] },
        'resources/templates/list' => { 'resourceTemplates' => [{ 'uriTemplate' => 'file:///{x}', 'name' => 'x' }] },
        'resources/read' => { 'contents' => [{ 'uri' => 'file:///r', 'text' => 'body' }] } }
    end

    def complete_result(method)
      complete_payloads[method]&.merge('resultType' => 'complete', 'ttlMs' => 60_000, 'cacheScope' => 'public')
    end

    def stub_complete_server(counts)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        result = complete_result(body['method'])
        json_response(body['id'], result || discover_result)
      end
    end

    it 'caches every list and read a modern server marks complete' do
      counts = Hash.new(0)
      stub_complete_server(counts)
      clock = [0.0]
      server = streamable
      allow(server).to receive(:monotonic_now) { clock[0] }

      expect(server.list_tools.map(&:name)).to eq(['a'])
      expect(server.list_prompts.map(&:name)).to eq(['p'])
      expect(server.list_resources['resources'].map(&:uri)).to eq(['file:///r'])
      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['x'])
      expect(server.read_resource('file:///r').map(&:text)).to eq(['body'])

      # The hint the complete result carried is the one they are served under.
      server.list_tools
      server.list_prompts
      server.list_resources
      server.list_resource_templates
      server.read_resource('file:///r')
      expect(counts.values_at('tools/list', 'prompts/list', 'resources/list', 'resources/templates/list',
                              'resources/read')).to eq([1, 1, 1, 1, 1])
      expect(server.cache_info(:tools)).to include(ttl_ms: 60_000, cache_scope: 'public', fresh: true)

      # ... and it runs out.
      clock[0] = 100.0
      expect(server.cache_fresh?(:tools)).to be(false)
      expect(server.list_tools.map(&:name)).to eq(['a'])
      expect(server.read_resource('file:///r').map(&:text)).to eq(['body'])
      expect(counts.values_at('tools/list', 'resources/read')).to eq([2, 2])
    ensure
      server&.cleanup
    end

    it 'caches a stdio list and read a modern server marks complete' do
      counts = Hash.new(0)
      server, = stdio_server do |request|
        counts[request['method']] += 1
        { 'result' => complete_result(request['method']) || discover_result }
      end
      clock = [0.0]
      allow(server).to receive(:monotonic_now) { clock[0] }

      expect(server.list_tools.map(&:name)).to eq(['a'])
      expect(server.list_prompts.map(&:name)).to eq(['p'])
      expect(server.read_resource('file:///r').map(&:text)).to eq(['body'])
      server.list_tools
      server.list_prompts
      server.read_resource('file:///r')
      expect(counts.values_at('tools/list', 'prompts/list', 'resources/read')).to eq([1, 1, 1])

      clock[0] = 100.0
      expect(server.list_tools.map(&:name)).to eq(['a'])
      expect(server.read_resource('file:///r').map(&:text)).to eq(['body'])
      expect(counts.values_at('tools/list', 'resources/read')).to eq([2, 2])
    ensure
      server&.cleanup
    end
  end

  describe 'the layer that answered a repeated list' do
    def stub_tools(counts)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        result = if body['method'] == 'tools/list'
                   { 'tools' => [{ 'name' => 'a', 'inputSchema' => { 'type' => 'object' } }],
                     'ttlMs' => 60_000, 'cacheScope' => 'public' }
                 else
                   discover_result
                 end
        json_response(body['id'], result)
      end
    end

    def counted(server)
      asked = 0
      allow(server).to receive(:list_tools).and_wrap_original do |original, *args, **kwargs|
        asked += 1
        original.call(*args, **kwargs)
      end
      [server, -> { asked }]
    end

    def client_for(server)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
    end

    it 'is the client cache, which does not reach the transport at all' do
      counts = Hash.new(0)
      stub_tools(counts)
      server, asked = counted(streamable)
      client = client_for(server)

      expect(client.list_tools.map(&:name)).to eq(['a'])
      expect(client.list_tools.map(&:name)).to eq(['a'])
      # Counting wire requests alone cannot tell the two caches apart: the
      # transport entry would have answered a second transport fetch just as
      # silently. The client cache is what makes it never happen.
      expect(asked.call).to eq(1)
      expect(counts['tools/list']).to eq(1)
    ensure
      server&.cleanup
    end

    it 'is the transport cache when the host reaches past the client' do
      counts = Hash.new(0)
      stub_tools(counts)
      server, asked = counted(streamable)
      client = client_for(server)

      expect(client.list_tools.map(&:name)).to eq(['a'])
      # Reaching the transport directly skips the client cache; the entry the
      # transport recorded answers without a request of its own. Both layers
      # look alike from the wire, which is why the example above counts the
      # transport calls instead.
      expect(server.list_tools.map(&:name)).to eq(['a'])
      expect(asked.call).to eq(2)
      expect(counts['tools/list']).to eq(1)
    ensure
      server&.cleanup
    end
  end

  describe 'an HTTP+SSE read bound to the credentials it was fetched with' do
    let(:rpc_url) { 'https://example.com/messages' }

    # A legacy HTTP+SSE server whose JSON-RPC responses come back on the POST
    # itself, so a read runs through the real request path — the one that
    # records which credentials it went out with.
    def sse_server
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse',
                                        headers: { 'Authorization' => 'Bearer alice' })
      allow(server).to receive(:ensure_initialized)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server.instance_variable_set(:@use_sse, false)
      server.instance_variable_set(:@rpc_endpoint, '/messages')
      server
    end

    it 'serves the private entry to the same credentials and refetches after they rotate' do
      bearers = []
      stub_request(:post, rpc_url).to_return do |request|
        body = JSON.parse(request.body)
        bearer = request.headers['Authorization'].to_s.sub(/\ABearer /, '')
        bearers << bearer
        { status: 200,
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                              'result' => { 'contents' => [{ 'uri' => 'file:///a', 'text' => "#{bearer}-data" }],
                                            'ttlMs' => 60_000, 'cacheScope' => 'private' }),
          headers: { 'Content-Type' => 'application/json' } }
      end
      server = sse_server

      expect(server.read_resource('file:///a').first.text).to eq('alice-data')
      # Alice again: the entry she filled is hers, and answers without a
      # second request. Without this the rotation below proves nothing.
      expect(server.read_resource('file:///a').first.text).to eq('alice-data')
      expect(bearers).to eq(['alice'])

      server.instance_variable_get(:@headers)['Authorization'] = 'Bearer bob'
      expect(server.read_resource('file:///a').first.text).to eq('bob-data')
      expect(bearers).to eq(%w[alice bob])
    ensure
      server&.cleanup
    end
  end

  describe 'a re-fetch the server refuses' do
    it 'does not serve the stale list when the credentials lost the scope for it' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        lists += 1
        if lists == 1
          json_response(body['id'], { 'tools' => [tool('old')], 'ttlMs' => 1_000, 'cacheScope' => 'public' })
        else
          { status: 403, body: '',
            headers: { 'WWW-Authenticate' => 'Bearer error="insufficient_scope", scope="tools:read"' } }
        end
      end
      clock = [0.0]
      server = streamable
      allow(server).to receive(:monotonic_now) { clock[0] }

      expect(server.list_tools.map(&:name)).to eq(['old'])
      clock[0] = 100.0
      # A lost scope is not a transient failure: serving the stale list would
      # hide it from the host's authorization flow.
      expect { server.list_tools }.to raise_error(MCPClient::Errors::InsufficientScopeError)
    ensure
      server&.cleanup
    end

    it 'maps a modern -32002 to ResourceNotFound after the cached copy expired' do
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        reads += 1
        if reads == 2
          error_response(body['id'], MCPClient::Errors::Codes::LEGACY_RESOURCE_NOT_FOUND, 'gone')
        else
          json_response(body['id'], { 'contents' => [{ 'uri' => 'file:///a', 'text' => "v#{reads}" }],
                                      'ttlMs' => 1_000 })
        end
      end
      clock = [0.0]
      server = streamable
      allow(server).to receive(:monotonic_now) { clock[0] }

      expect(server.read_resource('file:///a').map(&:text)).to eq(['v1'])
      clock[0] = 100.0
      # The historical code stays recognized on a 2026-07-28 server, and the
      # failure is never what the entry holds: the next read succeeds.
      expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceNotFound)
      expect(server.read_resource('file:///a').map(&:text)).to eq(['v3'])
      expect(server.cache_info(:read, 'file:///a')).to include(fresh: true)
    ensure
      server&.cleanup
    end
  end

  describe 'a read the server resumed through a request state alone' do
    it 'never caches the result the retry produced' do
      reads = 0
      states = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        reads += 1
        states << body.dig('params', 'requestState')
        if body['params'].key?('requestState')
          json_response(body['id'], { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'ready' }],
                                      'ttlMs' => 60_000, 'cacheScope' => 'public' })
        else
          # No inputRequests at all: the client simply waits and asks again
          # with the state the server handed it.
          json_response(body['id'], { 'resultType' => 'input_required', 'requestState' => "s#{reads}" })
        end
      end
      server = streamable
      allow(server).to receive(:sleep)

      expect(server.read_resource('file:///a').map(&:text)).to eq(['ready'])
      expect(states).to eq([nil, 's1'])
      # "Results produced by retrying a request through the multi round-trip
      # requests mechanism MUST NOT be cached", however the retry was carried.
      expect(server.cache_info(:read, 'file:///a')).to be_nil
      expect(server.read_resource('file:///a').map(&:text)).to eq(['ready'])
      expect(reads).to eq(4)
    ensure
      server&.cleanup
    end
  end

  # A stdio server whose responses come from `responder`, given the request
  # that was just written.
  def stdio_server(&responder)
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << JSON.parse(JSON.generate(req)) }
    allow(server).to receive(:wait_response) do |id, **_opts|
      { 'jsonrpc' => '2.0', 'id' => id }.merge(responder.call(sent.last))
    end
    [server, sent]
  end
end
