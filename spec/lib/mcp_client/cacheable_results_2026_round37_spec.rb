# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirty-seventh review round: a re-fetch that fails
# is judged by the credentials its request actually carried, not by what a
# host's response phase left in the error; a connection whose stack was
# locked before the receipt recorder could be installed dates a public result
# conservatively; and the behaviour the earlier rounds named is pinned on the
# transports and paths they left out (a stale copy after a failed re-fetch on
# plain HTTP, the read error mapping on plain HTTP and stdio, a result that
# really arrives on the SSE stream, cursors on stdio, a negative ttlMs on the
# wire, field-level isolation of cached reads, MRTR reads beside plain reads).
RSpec.describe 'MCP 2026-07-28 cacheable results — round 37' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def error_response(id, code, message)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id,
                                       'error' => { 'code' => code, 'message' => message }),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def initialize_result(era)
    { 'protocolVersion' => era, 'capabilities' => { 'resources' => {}, 'tools' => {} },
      'serverInfo' => { 'name' => 'test', 'version' => '1.0' } }
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

  def bearer_of(request)
    request.headers['Authorization'].to_s.sub(/\ABearer /, '')
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

  # Response-only middleware: no request phase, so the freshness probe steps
  # over it, but it rewrites the very environment the request was sent from.
  def redacting_middleware
    Class.new(Faraday::Middleware) do
      def on_complete(env)
        env.request_headers.delete('Authorization')
      end
    end
  end

  # Drives a stubbed transport clock from a stdio-style script.
  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  describe 'a re-fetch that fails after a host response phase rewrote the request headers' do
    # Round 3 bound a private result to the credentials the recorder saw go
    # out. The failure path read them back out of the error instead, after
    # the host's response phase had them: a stack that redacts Authorization
    # before `raise_error` builds its exception made every failed re-fetch
    # look anonymous, and an anonymous caller's private stale copy answered
    # whoever held the credentials now ("MUST NOT be shared across
    # authorization contexts" — the stale fallback included).
    shared_examples 'a failed re-fetch judged by what it carried' do
      it 'does not serve the anonymous stale list to the credentials the failed request carried' do
        clock = { now: 1000.0 }
        bearers = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

          bearers << bearer_of(request)
          if bearers.size == 1
            json_response(body['id'],
                          { 'tools' => [tool('anonymous-tool')], 'ttlMs' => 1000, 'cacheScope' => 'private' })
          else
            { status: 503, body: '' }
          end
        end
        token = Struct.new(:value).new(nil)
        klass = redacting_middleware
        server = build_server(oauth_provider: provider_holding(token),
                              faraday_config: lambda { |f|
                                f.response :raise_error
                                f.use klass
                              })
        allow(server).to receive(:monotonic_now) { clock[:now] }

        expect(server.list_tools.map(&:name)).to eq(['anonymous-tool'])

        clock[:now] += 5
        token.value = 'alice'
        expect { server.list_tools }.to raise_error(MCPClient::Errors::TransientServerError)
        expect(bearers).to eq(['', 'alice'])
      ensure
        server&.cleanup
      end

      it 'still serves the stale list of the very credentials the failed request carried' do
        clock = { now: 1000.0 }
        bearers = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

          bearers << bearer_of(request)
          if bearers.size == 1
            json_response(body['id'], { 'tools' => [tool('alice-tool')], 'ttlMs' => 1000, 'cacheScope' => 'private' })
          else
            { status: 503, body: '' }
          end
        end
        token = Struct.new(:value).new('alice')
        klass = redacting_middleware
        server = build_server(oauth_provider: provider_holding(token),
                              faraday_config: lambda { |f|
                                f.response :raise_error
                                f.use klass
                              })
        allow(server).to receive(:monotonic_now) { clock[:now] }

        expect(server.list_tools.map(&:name)).to eq(['alice-tool'])

        clock[:now] += 5
        # Alice's own copy may answer her transient failure ("Clients MAY
        # serve stale responses if errors occur during re-fetching").
        expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
        expect(bearers).to eq(%w[alice alice])
      ensure
        server&.cleanup
      end
    end

    context 'on Streamable HTTP' do
      def build_server(**) = streamable(**)

      it_behaves_like 'a failed re-fetch judged by what it carried'
    end

    context 'on plain HTTP' do
      def build_server(**) = plain_http(**)

      it_behaves_like 'a failed re-fetch judged by what it carried'
    end
  end

  describe 'a connection locked before the receipt recorder could be installed' do
    # Nothing stamped the moment the bytes arrived, and the host's response
    # phase ran before the transport had the response: the only moment known
    # not to be later than receipt is the one the request was sent at.
    shared_examples 'a public result dated no later than its receipt' do
      it 'dates a public read from before the request rather than after the response phase' do
        clock = { now: 0.0 }
        reads = 0
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

          reads += 1
          json_response(body['id'], { 'contents' => [{ 'uri' => 'file:///a', 'text' => "v#{reads}" }],
                                      'ttlMs' => 1000, 'cacheScope' => 'public' })
        end
        slow = Class.new(Faraday::Middleware) do
          define_method(:on_complete) do |env|
            request = begin
              JSON.parse(env.request_body.to_s)
            rescue StandardError
              nil
            end
            clock[:now] += 100 if request.is_a?(Hash) && request['method'] == 'resources/read'
          end
        end
        config = lambda do |f|
          f.use slow
          # The host builds the stack itself; Faraday locks it, and the
          # recorder can no longer be installed.
          f.builder.app
        end
        server = build_server(faraday_config: config)
        allow(server).to receive(:monotonic_now) { clock[:now] }

        expect(server.read_resource('file:///a').map(&:text)).to eq(['v1'])
        info = server.cache_info(:read, 'file:///a')
        expect(info[:received_at]).to be <= 0.0
        expect(info[:fresh]).to be(false)

        # It expired at t=1; the response phase ended at t=100.
        expect(server.read_resource('file:///a').map(&:text)).to eq(['v2'])
        expect(reads).to eq(2)
      ensure
        server&.cleanup
      end
    end

    context 'on Streamable HTTP' do
      def build_server(**) = streamable(**)

      it_behaves_like 'a public result dated no later than its receipt'
    end

    context 'on plain HTTP' do
      def build_server(**) = plain_http(**)

      it_behaves_like 'a public result dated no later than its receipt'
    end
  end

  describe 'a cached read whose next fetch fails, on the other transports' do
    def stub_expiring_http_read(code, era)
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize' then json_response(body['id'], initialize_result(era))
        when 'notifications/initialized' then { status: 202, body: '' }
        when 'resources/read'
          reads += 1
          if reads == 2
            error_response(body['id'], code, 'gone')
          else
            json_response(body['id'],
                          { 'contents' => [{ 'uri' => 'file:///a', 'text' => "v#{reads}" }], 'ttlMs' => 20 })
          end
        else json_response(body['id'], discover_result)
        end
      end
      -> { reads }
    end

    def read_after_expiry(server)
      expect(server.read_resource('file:///a').map(&:text)).to eq(['v1'])
      # Served from the entry while it is fresh: no second request.
      expect(server.read_resource('file:///a').map(&:text)).to eq(['v1'])
      allow(server).to receive(:monotonic_now).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60)
    end

    shared_examples 'read errors that cache nothing' do
      it 'maps -32602 to ResourceNotFound on a modern server and caches nothing' do
        reads = stub_read(MCPClient::Errors::Codes::INVALID_PARAMS, '2026-07-28')
        server = build_server('2026-07-28')
        read_after_expiry(server)

        expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceNotFound)
        expect(server.read_resource('file:///a').map(&:text)).to eq(['v3'])
        expect(reads.call).to eq(3)
      ensure
        server&.cleanup
      end

      it 'maps -32002 to ResourceNotFound on a legacy server and caches nothing' do
        reads = stub_read(MCPClient::Errors::Codes::LEGACY_RESOURCE_NOT_FOUND, '2025-11-25')
        server = build_server('2025-11-25')
        read_after_expiry(server)

        expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceNotFound)
        expect(server.read_resource('file:///a').map(&:text)).to eq(['v3'])
        expect(reads.call).to eq(3)
      ensure
        server&.cleanup
      end

      it 'raises a -32603 from the re-fetch, caches nothing, and asks again next time' do
        reads = stub_read(MCPClient::Errors::Codes::INTERNAL_ERROR, '2026-07-28')
        server = build_server('2026-07-28')
        read_after_expiry(server)

        # Every transport reports a failed read the same way: wrapped, with
        # the server's message, never as a cached value.
        expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceReadError, /gone/)
        # The expired entry is still there, and still expired: nothing of
        # the failure was stored and nothing stale is served from it.
        expect(server.cache_info(:read, 'file:///a')).to include(fresh: false)
        expect(server.read_resource('file:///a').map(&:text)).to eq(['v3'])
        expect(reads.call).to eq(3)
      ensure
        server&.cleanup
      end

      it 'keeps -32602 a plain Invalid params on a legacy server' do
        reads = stub_read(MCPClient::Errors::Codes::INVALID_PARAMS, '2025-11-25')
        server = build_server('2025-11-25')
        read_after_expiry(server)

        expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceReadError)
        expect(server.read_resource('file:///a').map(&:text)).to eq(['v3'])
        expect(reads.call).to eq(3)
      ensure
        server&.cleanup
      end
    end

    context 'on plain HTTP' do
      def stub_read(code, era) = stub_expiring_http_read(code, era)

      def build_server(era) = era == '2026-07-28' ? plain_http : plain_http(protocol: :legacy)

      it_behaves_like 'read errors that cache nothing'
    end

    context 'on HTTP+SSE (POST -> SSE event -> result store -> waiter)' do
      def stub_read(code, era)
        @era = era
        @reads = 0
        @script = lambda do |request|
          raise "unexpected #{request['method']}" unless request['method'] == 'resources/read'

          @reads += 1
          if @reads == 2
            { 'error' => { 'code' => code, 'message' => 'gone' } }
          else
            { 'result' => { 'contents' => [{ 'uri' => 'file:///a', 'text' => "v#{@reads}" }], 'ttlMs' => 20 } }
          end
        end
        -> { @reads }
      end

      def build_server(era)
        server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0)
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@sse_connected, true)
        server.instance_variable_set(:@initialized, true)
        server.instance_variable_set(:@protocol_version, era)
        server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
        allow(server).to receive(:post_json_rpc_request) do |request|
          message = { 'jsonrpc' => '2.0', 'id' => request['id'] }.merge(@script.call(request))
          server.send(:parse_and_handle_sse_event, "event: message\ndata: #{JSON.generate(message)}\n\n")
          nil
        end
        server
      end

      it_behaves_like 'read errors that cache nothing'
    end

    context 'on stdio' do
      # The script is keyed by request, as the wire would be: the handshake
      # of the era, then one read at a time.
      def stub_read(code, era)
        @reads = 0
        @script = lambda do |request|
          case request['method']
          when 'initialize' then { 'result' => initialize_result(era) }
          when 'server/discover' then { 'result' => discover_result }
          when 'resources/read'
            @reads += 1
            if @reads == 2
              { 'error' => { 'code' => code, 'message' => 'gone' } }
            else
              { 'result' => { 'contents' => [{ 'uri' => 'file:///a', 'text' => "v#{@reads}" }], 'ttlMs' => 20 } }
            end
          else raise "unexpected #{request['method']}"
          end
        end
        -> { @reads }
      end

      def build_server(era)
        server = if era == '2026-07-28'
                   MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
                 else
                   MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, protocol: :legacy)
                 end
        script = @script
        script_stdio(server, Array.new(8) { script })
        server
      end

      it_behaves_like 'read errors that cache nothing'
    end
  end

  describe 'a result that arrives on the SSE stream' do
    let(:rpc_url) { 'https://example.com/messages' }

    # A legacy HTTP+SSE server: the POST is acknowledged with 202 and the
    # response comes back on the stream, through the parser that stamps its
    # arrival. Nothing of the request path is stubbed.
    def sse_server
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', retries: 0, read_timeout: 5)
      allow(server).to receive(:ensure_initialized)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.instance_variable_set(:@rpc_endpoint, '/messages')
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server
    end

    it 'dates the resources list from the arrival of its event, not from the end of the callbacks it triggered' do
      clock = { now: 0.0 }
      lists = 0
      server = sse_server
      allow(server).to receive(:monotonic_now) { clock[:now] }
      # A host callback that takes a while, run for a notification the very
      # chunk carried in front of the response.
      server.on_notification { |method, _params| clock[:now] += 5 if method == 'notifications/message' }
      feeders = []
      stub_request(:post, rpc_url).to_return do |request|
        body = JSON.parse(request.body)
        lists += 1
        chunk = +''
        chunk << "event: message\ndata: " \
                 "#{JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/message', 'params' => {})}\n\n"
        chunk << "event: message\ndata: #{JSON.generate(
          'jsonrpc' => '2.0', 'id' => body['id'],
          'result' => { 'resources' => [{ 'uri' => "file:///v#{lists}", 'name' => "v#{lists}" }],
                        'ttlMs' => 1000, 'cacheScope' => 'public' }
        )}\n\n"
        feeders << Thread.new { server.send(:process_sse_chunk, chunk) }
        { status: 202, body: '' }
      end

      expect(server.list_resources['resources'].map(&:name)).to eq(['v1'])
      feeders.each(&:join)
      # Received at t=0; the callback ran the clock to t=5 before the result
      # was handed to the caller. The entry expired at t=1.
      expect(server.cache_info(:resources)[:received_at]).to eq(0.0)
      expect(server.cache_info(:resources)[:fresh]).to be(false)
      expect(server.list_resources['resources'].map(&:name)).to eq(['v2'])
      feeders.each(&:join)
      expect(lists).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'a cursor that is part of the cache key, on stdio' do
    it 'is never answered from the page cached without one' do
      counts = Hash.new(0)
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      page = lambda do |request|
        next { 'result' => discover_result } unless request['method'] == 'resources/list'

        cursor = request.dig('params', 'cursor')
        counts[cursor] += 1
        if cursor
          { 'result' => { 'resources' => [{ 'uri' => 'file:///b', 'name' => 'b' }], 'ttlMs' => 60_000,
                          'cacheScope' => 'public' } }
        else
          { 'result' => { 'resources' => [{ 'uri' => 'file:///a', 'name' => 'a' }], 'nextCursor' => 'p2',
                          'ttlMs' => 60_000, 'cacheScope' => 'public' } }
        end
      end
      script_stdio(server, Array.new(4) { page })

      expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(counts[nil]).to eq(1)

      expect(server.list_resources(cursor: 'p2')['resources'].map(&:name)).to eq(['b'])
      expect(counts['p2']).to eq(1)
      expect(counts[nil]).to eq(1)
    end
  end

  describe 'a negative ttlMs on the wire' do
    it 'is treated as 0: the next call asks the server again' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        lists += 1
        json_response(body['id'], { 'tools' => [tool("t#{lists}")], 'ttlMs' => -5, 'cacheScope' => 'public' })
      end
      server = streamable

      expect(server.list_tools.map(&:name)).to eq(['t1'])
      expect(server.cache_info(:tools)[:ttl_ms]).to eq(0)
      expect(server.list_tools.map(&:name)).to eq(['t2'])
      expect(lists).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'the copies a cached read hands out' do
    it 'share no field with the cached contents' do
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        reads += 1
        json_response(body['id'],
                      { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'hello',
                                         'annotations' => { 'audience' => ['user'] },
                                         '_meta' => { 'tags' => ['x'] } }],
                        'ttlMs' => 60_000, 'cacheScope' => 'public' })
      end
      server = streamable

      first = server.read_resource('file:///a').first
      first.text << ' world'
      first.annotations['audience'] << 'assistant'
      first.meta['tags'] << 'y'
      first.uri << '?edited'

      again = server.read_resource('file:///a').first
      expect(reads).to eq(1)
      expect(again.text).to eq('hello')
      expect(again.annotations).to eq('audience' => ['user'])
      expect(again.meta).to eq('tags' => ['x'])
      expect(again.uri).to eq('file:///a')
    ensure
      server&.cleanup
    end
  end

  describe 'a read completed through a multi round-trip retry beside a plain one' do
    # The marker is per thread, and it is the read cache that consumes it:
    # the thread whose read went through the retry stores nothing, while the
    # thread whose read completed at once keeps its copy — whatever order the
    # two finish in.
    it 'caches the plain read and not the retried one' do
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 5)
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      allow(server).to receive(:sleep)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
      requests = {}
      lock = Mutex.new
      plain_done = Queue.new
      counts = Hash.new(0)
      allow(server).to receive(:send_request) { |req| lock.synchronize { requests[req['id']] = req } }
      allow(server).to receive(:wait_response) do |id, **_opts|
        request = lock.synchronize { requests.fetch(id) }
        uri = request.dig('params', 'uri')
        lock.synchronize { counts[uri] += 1 }
        result = if request['method'] == 'server/discover'
                   discover_result
                 elsif uri == 'file:///mrtr' && !request.dig('params', 'requestState')
                   { 'resultType' => 'input_required', 'requestState' => 's' }
                 else
                   # The retried read completes only once the plain read has
                   # been served and stored.
                   plain_done.pop if uri == 'file:///mrtr'
                   { 'contents' => [{ 'uri' => uri, 'text' => "#{uri}:#{counts[uri]}" }], 'ttlMs' => 60_000 }
                 end
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => result }
      end

      # Discovery happens once, before the two reads race.
      server.send(:ensure_initialized)
      retried = Thread.new { server.read_resource('file:///mrtr').first.text }
      plain = server.read_resource('file:///plain').first.text
      plain_done << true
      expect(retried.value).to eq('file:///mrtr:2')
      expect(plain).to eq('file:///plain:1')

      # The plain read is served from its entry; the retried one is asked for
      # again ("results produced by retrying a request through the multi
      # round-trip requests mechanism MUST NOT be cached").
      expect(server.read_resource('file:///plain').first.text).to eq('file:///plain:1')
      plain_done << true
      expect(server.read_resource('file:///mrtr').first.text).to eq('file:///mrtr:4')
      expect(counts).to eq(nil => 1, 'file:///mrtr' => 4, 'file:///plain' => 1)
    ensure
      server&.cleanup
    end
  end
end
