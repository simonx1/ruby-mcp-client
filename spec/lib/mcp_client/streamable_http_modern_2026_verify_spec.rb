# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'zlib'
require 'stringio'

# Verification follow-ups for MCP 2026-07-28 Streamable HTTP modern mode.
#
# Each example here pins a behaviour that a demonstrated defect got wrong:
#
# 1. The server/discover probe went through the same re-issue path as every
#    other request, and a failed exchange (broken response stream, HTTP 5xx
#    surfaced by raise_error middleware) never records a legacy verdict.
# 2. tools/call is re-issued with a new request id when its response stream
#    breaks, per changelog major change 9 (no exception for any method).
# 3. A break that lands *inside* an SSE event's JSON recovers exactly like a
#    break between events.
# 4. A modern verdict survives MCPClient.connect's transport detector.
# 5. The modern era verdict is cached, like the legacy one.
HTTP_TRANSPORTS = [MCPClient::ServerStreamableHTTP, MCPClient::ServerHTTP].freeze

RSpec.describe 'MCP 2026-07-28 Streamable HTTP modern mode — verification' do
  let(:url) { 'https://example.com/mcp' }

  def discover_result(versions: ['2026-07-28'])
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => { 'tools' => {} } }
  end

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def sse_response(body)
    { status: 200, body: body, headers: { 'Content-Type' => 'text/event-stream' } }
  end

  # A response stream carrying only a keep-alive comment before it closes:
  # the break landed between events.
  def keep_alive_only
    sse_response(": keep-alive\n\n")
  end

  # A response stream cut in the middle of an event's JSON payload: the same
  # loss, but the break landed inside an event.
  def truncated_event
    sse_response(%(event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"to))
  end

  # Record every POST and answer it from `responders` keyed by JSON-RPC method.
  #
  # `tools/list` answers with an empty list unless the example scripts it: a
  # branch stacked above this one derives Mcp-Param-* headers from the tool
  # list, so a tools/call there fetches it first. Nothing on this branch asks
  # for it, so the default is inert here and keeps these examples honest once
  # that behaviour exists.
  def stub_posts(responders)
    responders = { 'tools/list' => { 'tools' => [] } }.merge(responders)
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << body
      responder = responders.fetch(body['method']) { raise "unexpected method #{body['method']}" }
      responder.respond_to?(:call) ? responder.call(body, requests) : json_response(body['id'], responder)
    end
    requests
  end

  def methods_sent(requests)
    requests.map { |r| r['method'] }
  end

  # --- 1. The probe re-issues, and a failed exchange is never a legacy verdict.

  HTTP_TRANSPORTS.each do |klass|
    describe klass do
      let(:server) { klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

      after { server.cleanup }

      it 're-issues server/discover with a new id when the probe response stream closes empty' do
        probes = 0
        requests = stub_posts('server/discover' => lambda do |body, _reqs|
          probes += 1
          probes == 1 ? keep_alive_only : json_response(body['id'], discover_result)
        end)

        server.connect

        expect(server.protocol_era).to eq(:modern)
        expect(methods_sent(requests)).to eq(%w[server/discover server/discover])
        expect(requests[0]['id']).not_to eq(requests[1]['id'])
      end

      it 'does not settle on legacy when every probe loses its response stream' do
        attempts = 0
        requests = stub_posts(
          'server/discover' => lambda do |body, _reqs|
            attempts += 1
            attempts <= 2 ? keep_alive_only : json_response(body['id'], discover_result)
          end,
          'initialize' => ->(_body, _reqs) { raise 'initialize must not be sent after a lost response stream' }
        )

        expect { server.connect }.to raise_error(MCPClient::Errors::MCPError, /closed before delivering the response/)
        expect(methods_sent(requests)).to eq(%w[server/discover server/discover])

        # The failed exchange taught the client nothing about the era, so the
        # next connection probes again instead of assuming legacy.
        server.connect
        expect(server.protocol_era).to eq(:modern)
        expect(methods_sent(requests)).not_to include('initialize')
      end

      it 'does not settle on legacy when raise_error middleware surfaces a 5xx probe response' do
        server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                           faraday_config: ->(conn) { conn.response :raise_error })
        failing = true
        requests = stub_posts(
          'server/discover' => lambda do |body, _reqs|
            failing ? { status: 503, body: '' } : json_response(body['id'], discover_result)
          end,
          'initialize' => ->(_body, _reqs) { raise 'initialize must not be sent after an HTTP 503' }
        )

        expect { server.connect }.to raise_error(MCPClient::Errors::MCPError, /503/)
        expect(methods_sent(requests)).to eq(['server/discover'])

        failing = false
        server.connect
        expect(server.protocol_era).to eq(:modern)
        expect(methods_sent(requests)).not_to include('initialize')
        server.cleanup
      end

      # --- 2. tools/call is re-issued too (changelog major change 9).

      it 're-issues tools/call with a new request id when its response stream breaks' do
        calls = 0
        requests = stub_posts(
          'server/discover' => discover_result,
          'tools/call' => lambda do |body, _reqs|
            calls += 1
            calls == 1 ? keep_alive_only : json_response(body['id'], { 'content' => [] })
          end
        )

        expect(server.call_tool('t', {})).to eq({ 'content' => [] })

        tool_calls = requests.select { |r| r['method'] == 'tools/call' }
        expect(tool_calls.size).to eq(2)
        expect(tool_calls[0]['id']).not_to eq(tool_calls[1]['id'])
      end

      it 'surfaces a tools/call whose stream breaks twice after exactly one re-issue' do
        requests = stub_posts(
          'server/discover' => discover_result,
          'tools/call' => ->(_body, _reqs) { keep_alive_only }
        )

        expect { server.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::MCPError, /closed before delivering the response/)
        expect(requests.count { |r| r['method'] == 'tools/call' }).to eq(2)
      end

      it 'makes exactly one replacement request for a broken stream even with retries configured' do
        server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 3, retry_backoff: 0)
        requests = stub_posts(
          'server/discover' => discover_result,
          'tools/list' => ->(_body, _reqs) { keep_alive_only }
        )

        expect { server.list_tools }
          .to raise_error(MCPClient::Errors::MCPError, /closed before delivering the response/)

        # The spec asks for one new request, not for the generic retry
        # budget: an idempotent method must not multiply it by retries + 1.
        expect(requests.count { |r| r['method'] == 'tools/list' }).to eq(2)
        server.cleanup
      end

      # --- 3. A break inside an event recovers like a break between events.

      it 're-issues an idempotent request whose response stream was cut inside an SSE event' do
        lists = 0
        requests = stub_posts(
          'server/discover' => discover_result,
          'tools/list' => lambda do |body, _reqs|
            lists += 1
            lists == 1 ? truncated_event : json_response(body['id'], { 'tools' => [] })
          end
        )

        expect(server.list_tools).to eq([])
        expect(requests.count { |r| r['method'] == 'tools/list' }).to eq(2)
      end

      # The re-issue replaces the lost request; it does not start the clock
      # again. A caller that asked for one timeout would otherwise wait twice
      # it — the maximum timeout the spec asks for "regardless of progress"
      # is the one the probe's replacement already honours.
      it 'gives a re-issued request the time left on the original budget' do
        bounds = []
        recorder = Class.new(Faraday::Middleware) do
          define_method(:on_request) do |env|
            body = begin
              JSON.parse(env.body.to_s)
            rescue JSON::ParserError
              nil
            end
            bounds << env.request.context[:mcp_deadline] if body && body['method'] == 'tools/list'
          end
        end
        server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, read_timeout: 30,
                           faraday_config: ->(conn) { conn.builder.insert(0, recorder) })
        lists = 0
        stub_posts(
          'server/discover' => discover_result,
          'tools/list' => lambda do |body, _reqs|
            lists += 1
            lists == 1 ? truncated_event : json_response(body['id'], { 'tools' => [] })
          end
        )
        stub_request(:get, url).to_return(status: 405, body: '')

        expect(server.list_tools).to eq([])

        expect(bounds.size).to eq(2)
        expect(bounds.uniq.size).to eq(1)
        server.cleanup
      end

      # --- Discovery boundaries.

      it 'falls back to initialize when a 2xx probe answer is an object without supportedVersions' do
        requests = stub_posts(
          # A permissive legacy endpoint that answers any method with a result.
          'server/discover' => { 'tools' => [] },
          'initialize' => lambda do |body, _reqs|
            json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                        'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
          end,
          'notifications/initialized' => ->(_body, _reqs) { { status: 202, body: '' } },
          'tools/list' => { 'tools' => [] }
        )
        stub_request(:get, url).to_return(status: 405, body: '')

        server.connect

        expect(server.protocol_era).to eq(:legacy)
        expect(methods_sent(requests).first(2)).to eq(%w[server/discover initialize])
      end

      # `resultType` did not exist before 2026-07-28, so a result carrying one
      # could only have been written by a modern server — however unusable the
      # rest of it is. Falling back would open a handshake that revision
      # removed, on a server that has already answered as modern. The stdio
      # probe settles this the same way.
      it 'never falls back when a 2xx probe answer carries a resultType' do
        requests = stub_posts(
          'server/discover' => { 'resultType' => 'complete', 'capabilities' => { 'tools' => {} } },
          'initialize' => lambda do |body, _reqs|
            json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                        'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
          end
        )
        stub_request(:get, url).to_return(status: 405, body: '')

        expect { server.connect }.to raise_error(MCPClient::Errors::ModernServerError, /modern/)

        expect(methods_sent(requests)).to eq(%w[server/discover])
        expect(server.protocol_era).not_to eq(:legacy)
      end

      it 'never falls back when a 2xx probe answer carries an unrecognized resultType' do
        requests = stub_posts(
          'server/discover' => { 'resultType' => 'something_new', 'supportedVersions' => ['2026-07-28'] },
          'initialize' => lambda do |body, _reqs|
            json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                        'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
          end
        )
        stub_request(:get, url).to_return(status: 405, body: '')

        expect { server.connect }.to raise_error(MCPClient::Errors::ModernServerError, /modern/)

        expect(methods_sent(requests)).to eq(%w[server/discover])
      end

      # Configuration reaches the wire as both a socket timeout and an
      # overall deadline (the capture middleware's `mcp_deadline`): the probe
      # gets discover_timeout, every other request the transport's timeout.
      # The live-socket examples at the end of this file show the deadline
      # being enforced; this one shows which request gets which bound.
      it 'bounds the probe with discover_timeout and other requests with the transport timeout' do
        bounds = []
        recorder = Class.new(Faraday::Middleware) do
          define_method(:on_request) do |env|
            bounds << [env.request.timeout, env.request.context && env.request.context[:mcp_deadline]]
          end
        end
        server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                           read_timeout: 30, discover_timeout: 3,
                           faraday_config: ->(conn) { conn.builder.insert(0, recorder) })
        stub_posts('server/discover' => discover_result, 'tools/list' => { 'tools' => [] })
        stub_request(:get, url).to_return(status: 405, body: '')
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        server.list_tools

        probe_timeout, probe_deadline = bounds.first
        list_timeout, list_deadline = bounds.last
        # The probe's socket timeout is the time left on its deadline, so it
        # is a hair under discover_timeout by the time the request is built.
        expect(probe_timeout).to be_within(0.1).of(3)
        expect(probe_deadline - started).to be_within(0.5).of(3)
        # Clamped to what is left of the request's own budget, like the probe:
        # the socket timeout never outlives the deadline it shares with the
        # one replacement a lost stream is allowed.
        expect(list_timeout).to be_within(0.1).of(30)
        expect(list_deadline - started).to be_within(0.5).of(30)
        server.cleanup
      end

      it 'never falls back to initialize after a DiscoverResult with no mutual version' do
        requests = stub_posts(
          'server/discover' => { 'resultType' => 'complete', 'supportedVersions' => ['2099-01-01'] },
          'initialize' => ->(_body, _reqs) { raise 'initialize must not be sent to a modern server' }
        )

        # Discovery did not establish a usable version, but it did establish
        # the era: the server answered server/discover with a DiscoverResult.
        2.times do
          expect { server.connect }.to raise_error(MCPClient::Errors::ModernServerError, /2099-01-01/)
        end

        expect(methods_sent(requests)).to eq(%w[server/discover server/discover])
      end

      # SSE line terminators are CRLF, CR or LF (HTML spec, event stream
      # parsing). A parser that only knows LF sees one unsplittable line here,
      # finds no response, and re-issues a request the server already answered.
      it 'reads a response stream framed with bare CR line endings' do
        requests = stub_posts(
          'server/discover' => discover_result,
          'tools/call' => lambda do |body, _reqs|
            sse_response("event: message\rdata: #{JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                                                'result' => { 'content' => [] })}\r\r")
          end
        )

        expect(server.call_tool('t', {})).to eq({ 'content' => [] })
        expect(requests.count { |r| r['method'] == 'tools/call' }).to eq(1)
      end

      # A modern server that answers server/discover with 404 -32601 is
      # non-conforming but usable, and this transport tolerates it. It answers
      # the same way every time, so the second connection must be tolerated
      # exactly like the first rather than failing on the cached verdict.
      it 'tolerates a discovery 404 on a reconnect, not only on the first connect' do
        requests = stub_posts(
          'server/discover' => lambda do |body, _reqs|
            { status: 404, headers: { 'Content-Type' => 'application/json' },
              body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                  'error' => { 'code' => -32_601, 'message' => 'Method not found' }) }
          end,
          'initialize' => ->(_body, _reqs) { raise 'initialize must not be sent to a modern server' }
        )

        2.times do
          server.connect
          expect(server.protocol_era).to eq(:modern)
          server.cleanup
        end

        expect(methods_sent(requests)).to eq(%w[server/discover server/discover])
      end

      # 2025-11-25 has resumption and no re-issue rule: a POST stream that
      # ends without the response must not put a tools/call back on the wire.
      it 'never re-POSTs a legacy tools/call whose response stream ends empty' do
        requests = stub_posts(
          'server/discover' => ->(_body, _reqs) { { status: 400, body: 'Bad Request' } },
          'initialize' => lambda do |body, _reqs|
            json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                        'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
          end,
          'notifications/initialized' => ->(_body, _reqs) { { status: 202, body: '' } },
          'tools/call' => ->(_body, _reqs) { keep_alive_only }
        )
        stub_request(:get, url).to_return(status: 405, body: '')

        expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::MCPError)

        expect(server.protocol_era).to eq(:legacy)
        expect(requests.count { |r| r['method'] == 'tools/call' }).to eq(1)
      end

      # Every modern request MUST carry clientCapabilities in _meta, and
      # SHOULD carry clientInfo. Both are pinned on stdio; this asserts them on
      # the HTTP wire so dropping either from required_request_meta cannot pass
      # here, and that the header keeps matching the body.
      it 'carries clientCapabilities and clientInfo in _meta on every modern POST' do
        requests = []
        headers = []
        stub_request(:post, url).to_return do |request|
          headers << request.headers
          body = JSON.parse(request.body)
          requests << body
          result = body['method'] == 'server/discover' ? discover_result : { 'content' => [] }
          json_response(body['id'], result)
        end

        server.call_tool('t', {})

        metas = requests.map { |r| r.dig('params', '_meta') }
        expect(metas).to all(include('io.modelcontextprotocol/clientCapabilities'))
        expect(metas).to all(include('io.modelcontextprotocol/clientInfo'))
        expect(metas.last['io.modelcontextprotocol/clientInfo']).to include('name', 'version')
        expect(headers.last['Mcp-Protocol-Version'])
          .to eq(metas.last['io.modelcontextprotocol/protocolVersion'])
      end

      # Two calls recovering at the same time must not cross: each replacement
      # request carries its own arguments and each caller gets its own result.
      # The existing concurrency examples cover establishing the connection,
      # not simultaneous recovery.
      it 'recovers two concurrent broken streams without crossing their arguments' do
        broken = {}
        requests = []
        mutex = Mutex.new
        # Both first attempts are held until the other has arrived, so the
        # two broken exchanges — and the two recoveries — genuinely overlap
        # instead of running one after the other by scheduling luck.
        both_broken = ConditionVariable.new
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          mutex.synchronize { requests << body }
          next json_response(body['id'], discover_result) if body['method'] == 'server/discover'

          name = body.dig('params', 'name')
          first = mutex.synchronize do
            next false if broken[name]

            broken[name] = true
            both_broken.broadcast if broken.size == 2
            both_broken.wait(mutex, 2) while broken.size < 2
            true
          end
          first ? keep_alive_only : json_response(body['id'], { 'content' => [{ 'text' => name }] })
        end
        server.connect

        results = %w[alpha beta].map do |name|
          Thread.new { [name, server.call_tool(name, { 'arg' => name })] }
        end.to_h(&:value)

        expect(results).to eq('alpha' => { 'content' => [{ 'text' => 'alpha' }] },
                              'beta' => { 'content' => [{ 'text' => 'beta' }] })
        expect(broken.size).to eq(2)
        calls = requests.select { |r| r['method'] == 'tools/call' }
        expect(calls.size).to eq(4)
        expect(calls.map { |r| r['id'] }.uniq.size).to eq(4)
        %w[alpha beta].each do |name|
          sent = calls.select { |r| r.dig('params', 'name') == name }
          expect(sent.size).to eq(2)
          expect(sent.map { |r| r.dig('params', 'arguments') }).to all(eq({ 'arg' => name }))
        end
      end

      # --- 5. The modern verdict is cached like the legacy one.

      it 'never falls back to initialize once the server has been confirmed modern' do
        modern = true
        requests = stub_posts(
          'server/discover' => lambda do |body, _reqs|
            modern ? json_response(body['id'], discover_result) : { status: 400, body: 'Bad Request' }
          end,
          'initialize' => ->(_body, _reqs) { raise 'initialize must not be sent to a confirmed modern server' }
        )

        server.connect
        expect(server.protocol_era).to eq(:modern)
        server.cleanup

        modern = false
        expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /modern but incompatible/)
        expect(methods_sent(requests)).to eq(%w[server/discover server/discover])
      end
    end
  end

  # --- A gzip body that stops before its footer.

  describe "#{MCPClient::ServerStreamableHTTP} gzip bodies" do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

    after { server.cleanup }

    def gzip(payload)
      buffer = StringIO.new(+'', 'wb')
      writer = Zlib::GzipWriter.new(buffer)
      writer.write(payload)
      writer.close
      buffer.string
    end

    def gzip_response(body, truncate: 0)
      compressed = gzip(body)
      { status: 200, body: compressed[0, compressed.bytesize - truncate],
        headers: { 'Content-Type' => 'text/event-stream', 'Content-Encoding' => 'gzip' } }
    end

    # Streamable HTTP always offers gzip, so a stream cut inside the encoded
    # body surfaces as a decode failure rather than a socket failure. No
    # response was delivered either way, so the request is lost and MUST be
    # re-issued with a new id.
    it 're-issues a request whose gzip body stops before its footer' do
      calls = 0
      requests = stub_posts(
        'server/discover' => discover_result,
        'tools/call' => lambda do |body, _reqs|
          calls += 1
          event = "event: message\ndata: #{JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                                         'result' => { 'content' => [] })}\n\n"
          calls == 1 ? gzip_response(event, truncate: 12) : gzip_response(event)
        end
      )

      expect(server.call_tool('t', {})).to eq({ 'content' => [] })

      tool_calls = requests.select { |r| r['method'] == 'tools/call' }
      expect(tool_calls.size).to eq(2)
      expect(tool_calls[0]['id']).not_to eq(tool_calls[1]['id'])
    end
  end

  # --- protocol: :modern outranks the URL-suffix heuristic.

  describe 'MCPClient.connect on a /sse URL' do
    let(:sse_url) { 'https://example.com/sse' }

    # A path is not a protocol declaration. Selecting the legacy-only SSE
    # transport for protocol: :modern would drop the option and open a GET
    # stream instead of probing a perfectly good modern endpoint.
    it 'uses the modern Streamable HTTP transport when the caller asked for protocol: :modern' do
      post_stub = stub_request(:post, sse_url).to_return(
        status: 200,
        body: JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                            'result' => { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                          'capabilities' => { 'tools' => {} } }),
        headers: { 'Content-Type' => 'application/json' }
      )
      get_stub = stub_request(:get, sse_url).to_return(status: 200, body: '')

      client = MCPClient.connect(sse_url, retries: 0, protocol: :modern)

      expect(client.servers.first).to be_a(MCPClient::ServerStreamableHTTP)
      expect(client.servers.first.protocol_era).to eq(:modern)
      expect(post_stub).to have_been_requested.once
      expect(get_stub).not_to have_been_requested
      client.cleanup
    end
  end

  # --- The GET events stream is removed in modern mode.

  describe MCPClient::ServerStreamableHTTP do
    let(:server) { described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

    after { server.cleanup }

    # The existing "never opens a GET stream" example asserts only that the
    # GET stub went unrequested, which races the events thread: the thread is
    # spawned by connect but issues its GET asynchronously, so the assertion
    # can run first and pass even when the stream was opened. The thread
    # handle is set synchronously, so checking it settles the question.
    it 'starts no events thread and issues no GET for a modern server' do
      get_stub = stub_request(:get, url).to_return(status: 405, body: '')
      stub_posts('server/discover' => discover_result, 'tools/list' => { 'tools' => [] })

      server.connect
      server.list_tools

      expect(server.instance_variable_get(:@events_thread)).to be_nil
      expect(get_stub).not_to have_been_requested
    end

    it 'still opens the events stream for a legacy server' do
      get_stub = stub_request(:get, url).to_return(status: 405, body: '')
      stub_posts(
        'server/discover' => ->(_body, _reqs) { { status: 400, body: 'Bad Request' } },
        'initialize' => lambda do |body, _reqs|
          json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
        end,
        'notifications/initialized' => ->(_body, _reqs) { { status: 202, body: '' } }
      )

      server.connect

      expect(server.protocol_era).to eq(:legacy)
      # A non-nil thread proves nothing about the GET; wait for the request
      # itself, which the thread issues asynchronously.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      registry = WebMock::RequestRegistry.instance
      until registry.times_executed(get_stub.request_pattern).positive?
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.01
      end
      expect(get_stub).to have_been_requested
    end
  end

  # --- 4. A modern verdict survives the transport detector.

  describe 'MCPClient.connect on an ambiguous URL' do
    let(:ambiguous_url) { 'https://example.com/api' }

    it 'stops at the modern verdict instead of trying the legacy SSE transport' do
      post_stub = stub_request(:post, ambiguous_url).to_return(
        status: 400,
        body: JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                            'error' => { 'code' => -32_020, 'message' => 'Header mismatch' }),
        headers: { 'Content-Type' => 'application/json' }
      )
      get_stub = stub_request(:get, ambiguous_url).to_return(status: 200, body: '')

      expect { MCPClient.connect(ambiguous_url, retries: 0) }
        .to raise_error(MCPClient::Errors::ModernServerError, /modern but incompatible/)

      expect(post_stub).to have_been_requested.once
      expect(get_stub).not_to have_been_requested
    end

    it 'stops at a DiscoverResult that advertises no version this client speaks' do
      post_stub = stub_request(:post, ambiguous_url).to_return(
        status: 200,
        body: JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                            'result' => { 'resultType' => 'complete',
                                          'supportedVersions' => ['2099-01-01'] }),
        headers: { 'Content-Type' => 'application/json' }
      )
      get_stub = stub_request(:get, ambiguous_url).to_return(status: 200, body: '')

      # The server answered as a modern server; it just has no version in
      # common. The legacy transports cannot do better, and trying them
      # buries the actionable message in a "tried all transports" list.
      expect { MCPClient.connect(ambiguous_url, retries: 0) }
        .to raise_error(MCPClient::Errors::ModernServerError, /2099-01-01/)

      expect(post_stub).to have_been_requested.once
      expect(get_stub).not_to have_been_requested
    end

    it 'stops at a well-formed -32022 that advertises no version this client speaks' do
      post_stub = stub_request(:post, ambiguous_url).to_return(
        status: 400,
        body: JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                            'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                         'data' => { 'supported' => ['2099-01-01'],
                                                     'requested' => '2026-07-28' } }),
        headers: { 'Content-Type' => 'application/json' }
      )
      get_stub = stub_request(:get, ambiguous_url).to_return(status: 200, body: '')

      expect { MCPClient.connect(ambiguous_url, retries: 0) }
        .to raise_error(MCPClient::Errors::ModernServerError, /2099-01-01/)

      expect(post_stub).to have_been_requested.once
      expect(get_stub).not_to have_been_requested
    end

    it 'does not fall back to a legacy transport when the caller asked for protocol: :modern' do
      post_stub = stub_request(:post, ambiguous_url).to_return(status: 400, body: 'Bad Request')
      get_stub = stub_request(:get, ambiguous_url).to_return(status: 200, body: '')

      expect { MCPClient.connect(ambiguous_url, retries: 0, protocol: :modern) }
        .to raise_error(MCPClient::Errors::ConnectionError, /legacy server expecting the initialize handshake/)

      expect(post_stub).to have_been_requested.once
      expect(get_stub).not_to have_been_requested
    end
  end
end

# A real HTTP (or HTTPS) server on 127.0.0.1 that can end a response
# *mid-stream*.
#
# The WebMock broken-stream fixtures above return a **completed** HTTP
# response whose SSE body happens to carry no result. That is not the failure
# the 2026-07-28 re-issue rule is about: an actual broken response stream is a
# socket that stops in the middle of the body, which Faraday surfaces as a
# connection failure rather than as a short body. This server produces exactly
# that — status line, SSE headers, one chunk, then close, with no terminating
# chunk — so the re-issue path is exercised against the error a real network
# failure raises.
#
# With `tls: true` it does the same over TLS, the transport production
# Streamable HTTP actually runs on: the socket is torn down under the TLS
# session (no close_notify), so Faraday raises SSLError rather than
# ConnectionFailed. Those two are siblings, not subclasses, so only the TLS
# fixture proves the re-issue path is reached from both.
class MidStreamCloseServer
  # Reply token: send SSE headers and one keep-alive chunk, then close the
  # socket — the response never arrived.
  CLOSE_MID_STREAM = :close_mid_stream
  # Reply token pair [DELIVER_THEN_CLOSE, reply]: send the complete final SSE
  # event, then close without the terminating chunk. The response *did*
  # arrive; only the framing after it is missing.
  DELIVER_THEN_CLOSE = :deliver_then_close
  # Reply token pair [DELIVER_UNTERMINATED, reply]: cut the socket before the
  # event's blank line, so the event was never dispatched even though the JSON
  # on its data line happens to be complete.
  DELIVER_UNTERMINATED = :deliver_unterminated
  # Reply token pair [DRIP_FOREVER, interval]: stream SSE keep-alive comments
  # forever, `interval` seconds apart. Below the client's socket timeout the
  # stream never goes idle and only an overall deadline can end the request;
  # above it the socket timeout fires and the client tears the stream down.
  DRIP_FOREVER = :drip_forever
  # Reply token triple [HTTP_STATUS, code, body]: a complete, plain response.
  HTTP_STATUS = :http_status
  # Reply token triple [DELAY, seconds, reply]: wait, then serve `reply`.
  DELAY = :delay
  # Reply token: send nothing at all and hold the socket open — the server
  # never answers.
  STALL = :stall
  # Reply token pair [DELIVER_THEN_STALL, reply]: send the complete final SSE
  # event, then hold the socket open without ever ending the response.
  DELIVER_THEN_STALL = :deliver_then_stall
  # Reply token quadruple [EVENT_THEN_WAIT, message, waiter, reply]: send
  # `message` as one complete SSE event, call `waiter` and, only if it
  # returns true, send `reply` as the final event and end the response
  # properly. A waiter that gives up ends the response without the reply.
  # `message` may also be the raw bytes of the event (a String), or several
  # raw chunks (an Array of Strings) written one at a time.
  EVENT_THEN_WAIT = :event_then_wait
  # Reply token pair [EVENT_THEN_STALL, message]: send `message` as one
  # complete SSE event, then hold the socket open without ever ending the
  # response.
  EVENT_THEN_STALL = :event_then_stall
  # Reply token pair [GZIP_THEN_CLOSE, reply]: the complete final SSE event,
  # gzip-encoded as the client's Accept-Encoding allows, then close without
  # the terminating chunk. The response *did* arrive, compressed.
  GZIP_THEN_CLOSE = :gzip_then_close
  # Reply token pair [GZIP_EVENTS_THEN_STALL, message]: `message` as complete
  # SSE events, gzip-encoded and flushed onto the wire, then the socket held
  # open without the deflate stream ever ending. Only a reader that inflates
  # the body as it arrives can see those events.
  GZIP_EVENTS_THEN_STALL = :gzip_events_then_stall
  # Reply token triple [STATUS_THEN_CLOSE, code, reply]: `reply` as one
  # complete SSE event under HTTP `code`, then close without the terminating
  # chunk. The answer arrived; the framing after it did not.
  STATUS_THEN_CLOSE = :status_then_close
  # Reply token pair [HEADER_DRIP, interval]: the status line, then a fresh
  # response header line every `interval` seconds and never the blank line
  # that ends the head. Every read succeeds, so a socket timeout alone never
  # fires and no body callback ever runs — only a bound on the whole exchange
  # can end it.
  HEADER_DRIP = :header_drip
  # Reply token quadruple [HEADER_DRIP_THEN, seconds, interval, reply]: drip
  # header lines for `seconds`, then answer with `reply`. The answer is real
  # but arrives after any deadline shorter than `seconds`.
  HEADER_DRIP_THEN = :header_drip_then
  # Reply token pair [SHORT_BODY, prefix]: a Content-Length that promises more
  # than `prefix`, then `prefix` and a close. Net::HTTP hands such a body back
  # normally, so nothing raises and only the length says it stopped short.
  SHORT_BODY = :short_body

  # A self-signed certificate for 127.0.0.1, built once for the whole file
  # because key generation is the expensive part.
  TLS_KEY = OpenSSL::PKey::RSA.new(2048)
  TLS_CERT = begin
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse('/CN=127.0.0.1')
    cert.issuer = cert.subject
    cert.public_key = TLS_KEY.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    factory = OpenSSL::X509::ExtensionFactory.new
    factory.subject_certificate = cert
    factory.issuer_certificate = cert
    cert.add_extension(factory.create_extension('subjectAltName', 'IP:127.0.0.1', false))
    cert.sign(TLS_KEY, OpenSSL::Digest.new('SHA256'))
    cert
  end

  # @return [Integer] the ephemeral port the server listens on
  attr_reader :port

  # @param tls [Boolean] whether to serve HTTPS with the self-signed certificate
  # @param stall_handshake_from [Integer, nil] the TCP connection (1-based)
  #   from which on the TLS handshake is never completed: the server accepts
  #   the socket and then does nothing with it
  # @yieldparam message [Hash] the JSON-RPC message the client POSTed
  # @yieldreturn [Hash, Symbol, Array] a JSON-RPC reply, or one of the reply tokens
  def initialize(tls: false, stall_handshake_from: nil, &responder)
    @responder = responder
    @tls = tls
    @stall_handshake_from = stall_handshake_from
    @received = []
    @received_headers = []
    @connections = 0
    @aborted = false
    @mutex = Mutex.new
    @listener = TCPServer.new('127.0.0.1', 0)
    @port = @listener.addr[1]
    @workers = []
    @thread = Thread.new { accept_loop }
  end

  # @return [Array<Hash>] every JSON-RPC message received, in order
  def received
    @mutex.synchronize { @received.dup }
  end

  # @return [Array<Hash>] the HTTP headers of each received request, in order
  def received_headers
    @mutex.synchronize { @received_headers.dup }
  end

  # Counted at TCP accept, before any TLS handshake, so a connection that
  # never completes still counts as an attempt.
  # @return [Integer] how many TCP connections the client opened
  def connections
    @mutex.synchronize { @connections }
  end

  # True once a DRIP_FOREVER response failed to write, i.e. the client tore
  # the response stream down. On modern Streamable HTTP that teardown *is* the
  # cancellation signal, so it is the only thing a timed-out request sends.
  # @return [Boolean]
  def stream_aborted?
    @mutex.synchronize { @aborted }
  end

  # @return [String] the base URL clients should use
  def base_url
    "#{@tls ? 'https' : 'http'}://127.0.0.1:#{@port}"
  end

  # @return [void]
  def stop
    @thread&.kill
    @mutex.synchronize { @workers.each(&:kill) }
    @listener.close unless @listener.closed?
  rescue IOError
    nil
  end

  private

  # Each connection is served on its own thread: a reply that waits for the
  # client's answer on a *second* connection (EVENT_THEN_WAIT) must not block
  # the accept loop that has to take that connection.
  def accept_loop
    loop do
      socket = @listener.accept
      @mutex.synchronize do
        @connections += 1
        @workers << Thread.new { handle(socket) }
      end
    end
  rescue StandardError
    nil
  end

  def handle(socket)
    client = nil
    sleep if @stall_handshake_from && connections >= @stall_handshake_from
    client = wrap(socket)
    serve(client)
  rescue StandardError
    nil
  ensure
    close_client(client || socket)
  end

  def wrap(socket)
    return socket unless @tls

    context = OpenSSL::SSL::SSLContext.new
    context.cert = TLS_CERT
    context.key = TLS_KEY
    ssl = OpenSSL::SSL::SSLSocket.new(socket, context)
    ssl.accept
    ssl
  end

  # A TLS socket is closed at the TCP layer so no close_notify is sent: an
  # orderly TLS shutdown would look to the client like a clean end of body.
  def close_client(client)
    client.is_a?(OpenSSL::SSL::SSLSocket) ? client.io.close : client.close
  rescue StandardError
    nil
  end

  def serve(client)
    request_line = client.gets
    return unless request_line

    headers = read_headers(client)
    # A legacy Streamable HTTP client opens the GET events stream after its
    # handshake; this fixture serves POST response streams only.
    return write_plain(client, 405, '') if request_line.start_with?('GET')

    message = JSON.parse(client.read(headers['content-length'].to_i).to_s)
    @mutex.synchronize do
      @received << message
      @received_headers << headers
    end
    write_reply(client, @responder.call(message))
  end

  def read_headers(client)
    headers = {}
    while (line = client.gets)
      line = line.strip
      break if line.empty?

      name, value = line.split(':', 2)
      headers[name.to_s.downcase] = value.to_s.strip
    end
    headers
  end

  def write_reply(client, reply)
    token, payload, extra = reply.is_a?(Array) ? reply : [reply, nil, nil]

    return client.flush if write_body_reply?(client, token, payload, extra)

    case token
    when GZIP_EVENTS_THEN_STALL
      write_gzip_events_open(client, sse_events_for(payload))
      sleep
    when DELIVER_UNTERMINATED then write_sse_chunk(client, "event: message\ndata: #{JSON.generate(payload)}\n")
    when DRIP_FOREVER then drip(client, payload || 0.02)
    when HTTP_STATUS then write_plain(client, payload, extra.to_s)
    when DELAY
      sleep payload
      return write_reply(client, extra)
    when STALL then sleep
    when HEADER_DRIP, HEADER_DRIP_THEN
      return write_header_drip_reply(client, reply)
    when DELIVER_THEN_STALL, EVENT_THEN_STALL
      write_sse_chunk(client, sse_events_for(payload))
      client.flush
      sleep
    when EVENT_THEN_WAIT then event_then_wait(client, *reply[1..])
    else write_plain(client, 200, JSON.generate(token))
    end
    client.flush
  end

  # The tokens that write a body and are done with the socket.
  # @return [Boolean] whether this token was one of them
  def write_body_reply?(client, token, payload, extra)
    case token
    when CLOSE_MID_STREAM then write_sse_chunk(client, ": keep-alive\n\n")
    when DELIVER_THEN_CLOSE then write_sse_chunk(client, sse_events_for(payload))
    when STATUS_THEN_CLOSE then write_json_chunk(client, JSON.generate(extra), status: payload)
    when SHORT_BODY then write_short_body(client, payload)
    when GZIP_THEN_CLOSE then write_gzip_chunk(client, sse_events_for(payload))
    else return false
    end
    true
  end

  # One complete event now, the reply only once `waiter` says the client has
  # done its part (answered a server request, observed a notification), and
  # a properly terminated response either way.
  def event_then_wait(client, message, waiter, reply)
    write_sse_head(client)
    Array(message.is_a?(Array) ? message : [message]).each_with_index do |part, index|
      sleep 0.05 if index.positive?
      chunk = part.is_a?(String) ? part : sse_events_for(part)
      client.write(format("%<size>x\r\n%<chunk>s\r\n", size: chunk.bytesize, chunk: chunk))
      client.flush
    end
    if waiter.call
      chunk = "event: message\ndata: #{JSON.generate(reply)}\n\n"
      client.write(format("%<size>x\r\n%<chunk>s\r\n", size: chunk.bytesize, chunk: chunk))
    end
    client.write("0\r\n\r\n")
  end

  # One or several complete, LF-framed SSE events.
  # @param payload [Hash, Array<Hash>] the JSON-RPC message(s) to frame
  # @return [String]
  def sse_events_for(payload)
    Array(payload.is_a?(Array) ? payload : [payload]).map { |m| "event: message\ndata: #{JSON.generate(m)}\n\n" }.join
  end

  # The chunk gzip-encoded, as one chunk and no terminating zero chunk.
  def write_gzip_chunk(client, chunk)
    compressed = StringIO.new.tap { |io| Zlib::GzipWriter.wrap(io) { |gz| gz.write(chunk) } }.string
    client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Encoding: gzip\r\n" \
                 "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
    client.write(format("%<size>x\r\n%<chunk>s\r\n", size: compressed.bytesize, chunk: compressed))
  end

  # The events gzip-encoded and sync-flushed as one chunk, with the deflate
  # stream left open (no footer, no terminating zero chunk).
  def write_gzip_events_open(client, chunk)
    io = StringIO.new
    gz = Zlib::GzipWriter.new(io)
    gz.write(chunk)
    gz.flush(Zlib::SYNC_FLUSH)
    compressed = io.string.dup
    client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Encoding: gzip\r\n" \
                 "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
    client.write(format("%<size>x\r\n%<chunk>s\r\n", size: compressed.bytesize, chunk: compressed))
    client.flush
  end

  def write_sse_head(client, status: 200)
    client.write("HTTP/1.1 #{status} OK\r\nContent-Type: text/event-stream\r\n" \
                 "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
  end

  # One chunk and no terminating zero chunk: the body stops mid-stream.
  def write_sse_chunk(client, chunk, status: 200)
    write_sse_head(client, status: status)
    client.write(format("%<size>x\r\n%<chunk>s\r\n", size: chunk.bytesize, chunk: chunk))
  end

  # A Content-Length that promises more than what follows, then a close.
  def write_short_body(client, prefix)
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{prefix.bytesize + 128}\r\nConnection: close\r\n\r\n")
    client.write(prefix)
  end

  # A JSON body under `status`, chunked, with no terminating zero chunk: the
  # answer arrived whole, the framing after it did not.
  def write_json_chunk(client, chunk, status: 200)
    client.write("HTTP/1.1 #{status} Bad Request\r\nContent-Type: application/json\r\n" \
                 "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
    client.write(format("%<size>x\r\n%<chunk>s\r\n", size: chunk.bytesize, chunk: chunk))
  end

  # The two tokens that hold the response head open, and what follows.
  # @return [void]
  def write_header_drip_reply(client, reply)
    token, payload, extra = reply.is_a?(Array) ? reply : [reply, nil, nil]
    return drip_headers(client, payload || 0.02) if token == HEADER_DRIP

    drip_headers(client, extra || 0.02, seconds: payload)
    write_reply(client, reply[3])
  end

  # Response header lines, forever or for `seconds`, and never the blank line
  # that would end the head.
  def drip_headers(client, interval, seconds: nil)
    client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n")
    stop = seconds && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds)
    pad = 0
    loop do
      break if stop && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= stop

      pad += 1
      client.write("X-Pad-#{pad}: keep-the-head-open\r\n")
      client.flush
      sleep interval
    end
  rescue StandardError
    @mutex.synchronize { @aborted = true }
    raise
  end

  def drip(client, interval)
    write_sse_head(client)
    chunk = ": keep-alive\n\n"
    loop do
      client.write(format("%<size>x\r\n%<chunk>s\r\n", size: chunk.bytesize, chunk: chunk))
      client.flush
      sleep interval
    end
  rescue StandardError
    @mutex.synchronize { @aborted = true }
    raise
  end

  def write_plain(client, status, body)
    client.write("HTTP/1.1 #{status} OK\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  end
end

RSpec.describe 'MCP 2026-07-28 Streamable HTTP — a response stream that really breaks' do
  before do
    # WebMock is turned off entirely rather than merely allowed to connect:
    # its Net::HTTP adapter reads the whole body before handing the response
    # to the streaming block, which would hide exactly the mid-body failures
    # (and the read-time deadline) these examples exist to exercise. Disabling
    # it also drops the shared server/discover stub from spec_helper, which
    # would otherwise intercept the probe before it reached the local socket.
    WebMock.disable!
  end

  after do
    @server&.cleanup
    @fixture&.stop
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  def jsonrpc(message, result)
    { 'jsonrpc' => '2.0', 'id' => message['id'], 'result' => result }
  end

  def discovery
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {} } }
  end

  def start_server(tls: false, **opts, &responder)
    @fixture = MidStreamCloseServer.new(tls: tls, **opts, &responder)
  end

  def transport(klass, **opts)
    # The fixture's certificate is self-signed, so verification is turned off
    # for the TLS runs; nothing else about the exchange changes.
    opts = { faraday_config: ->(conn) { conn.ssl[:verify] = false } }.merge(opts)
    @server = klass.new(base_url: @fixture.base_url, endpoint: '/mcp', retries: 0, **opts)
  end

  def methods_received
    @fixture.received.map { |r| r['method'] }
  end

  def legacy_init
    { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } }
  end

  # Poll for a condition; false once `limit` seconds passed without it.
  def settled_within?(limit = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    true
  end

  def elapsed_since(started)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  HTTP_TRANSPORTS.each do |klass|
    describe klass do
      it 're-issues tools/call with a new id when the socket ends mid-stream' do
        calls = 0
        start_server do |message|
          case message['method']
          when 'server/discover' then jsonrpc(message, discovery)
          when 'tools/call'
            calls += 1
            calls == 1 ? MidStreamCloseServer::CLOSE_MID_STREAM : jsonrpc(message, { 'content' => [] })
          else jsonrpc(message, { 'tools' => [] })
          end
        end

        expect(transport(klass).call_tool('t', {})).to eq({ 'content' => [] })

        tool_calls = @fixture.received.select { |r| r['method'] == 'tools/call' }
        expect(tool_calls.size).to eq(2)
        expect(tool_calls[0]['id']).not_to eq(tool_calls[1]['id'])
      end

      # The re-issued request must be the *same* operation: only the JSON-RPC
      # id may change. Sending the tool name with different (or no) arguments
      # would satisfy "one replacement POST" while calling something else.
      it 're-issues tools/call with the original arguments and mirrored headers' do
        calls = 0
        start_server do |message|
          case message['method']
          when 'server/discover' then jsonrpc(message, discovery)
          when 'tools/call'
            calls += 1
            calls == 1 ? MidStreamCloseServer::CLOSE_MID_STREAM : jsonrpc(message, { 'content' => [] })
          else jsonrpc(message, { 'tools' => [] })
          end
        end
        arguments = { 'amount' => 10, 'nested' => { 'currency' => 'EUR', 'lines' => [1, 2] } }

        expect(transport(klass).call_tool('charge', arguments)).to eq({ 'content' => [] })

        indexes = @fixture.received.each_index.select { |i| @fixture.received[i]['method'] == 'tools/call' }
        expect(indexes.size).to eq(2)
        first, second = indexes.map { |i| @fixture.received[i] }
        expect(second['id']).not_to eq(first['id'])
        expect(second['params']).to eq(first['params'])
        expect(second['params']).to include('name' => 'charge', 'arguments' => arguments)
        headers = indexes.map { |i| @fixture.received_headers[i] }
        expect(headers.map { |h| h['mcp-name'] }).to eq(%w[charge charge])
        expect(headers.map { |h| h['mcp-method'] }).to eq(%w[tools/call tools/call])
      end

      # Production Streamable HTTP is HTTPS: the net_http adapter turns a TLS
      # session that dies mid-body into Faraday::SSLError, a *sibling* of
      # ConnectionFailed. A classification that only names ConnectionFailed
      # never reaches the re-issue path here.
      it 're-issues tools/call when an HTTPS response stream dies mid-body' do
        calls = 0
        start_server(tls: true) do |message|
          case message['method']
          when 'server/discover' then jsonrpc(message, discovery)
          when 'tools/call'
            calls += 1
            calls == 1 ? MidStreamCloseServer::CLOSE_MID_STREAM : jsonrpc(message, { 'content' => [] })
          else jsonrpc(message, { 'tools' => [] })
          end
        end

        expect(transport(klass).call_tool('charge', { 'amount' => 10 })).to eq({ 'content' => [] })

        tool_calls = @fixture.received.select { |r| r['method'] == 'tools/call' }
        expect(tool_calls.size).to eq(2)
        expect(tool_calls[0]['id']).not_to eq(tool_calls[1]['id'])
        expect(tool_calls[1]['params']).to eq(tool_calls[0]['params'])
      end

      it 're-issues the server/discover probe when an HTTPS response stream dies mid-body' do
        probes = 0
        start_server(tls: true) do |message|
          case message['method']
          when 'server/discover'
            probes += 1
            probes == 1 ? MidStreamCloseServer::CLOSE_MID_STREAM : jsonrpc(message, discovery)
          when 'initialize' then raise 'initialize must not be sent after a lost response stream'
          else jsonrpc(message, { 'tools' => [] })
          end
        end

        transport(klass).connect

        expect(@server.protocol_era).to eq(:modern)
        expect(methods_received).to eq(%w[server/discover server/discover])
      end

      # The re-issue rule is about an in-flight request that was *lost*. A
      # response that was fully delivered settles its request, so a socket
      # that dies after the last event must not cause the tool to run twice.
      it 'keeps a delivered result when the socket dies after the final SSE event' do
        start_server do |message|
          case message['method']
          when 'server/discover' then jsonrpc(message, discovery)
          when 'tools/call'
            [MidStreamCloseServer::DELIVER_THEN_CLOSE, jsonrpc(message, { 'content' => [{ 'type' => 'text' }] })]
          else jsonrpc(message, { 'tools' => [] })
          end
        end

        expect(transport(klass).call_tool('charge', { 'amount' => 10 }))
          .to eq({ 'content' => [{ 'type' => 'text' }] })
        expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(1)
      end

      it 'keeps a delivered result when an HTTPS socket dies after the final SSE event' do
        start_server(tls: true) do |message|
          case message['method']
          when 'server/discover' then jsonrpc(message, discovery)
          when 'tools/call' then [MidStreamCloseServer::DELIVER_THEN_CLOSE, jsonrpc(message, { 'content' => [] })]
          else jsonrpc(message, { 'tools' => [] })
          end
        end

        expect(transport(klass).call_tool('charge', { 'amount' => 10 })).to eq({ 'content' => [] })
        expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(1)
      end

      it 'surfaces a delivered JSON-RPC error rather than re-issuing when the socket then dies' do
        start_server do |message|
          case message['method']
          when 'server/discover' then jsonrpc(message, discovery)
          when 'tools/call'
            [MidStreamCloseServer::DELIVER_THEN_CLOSE,
             { 'jsonrpc' => '2.0', 'id' => message['id'],
               'error' => { 'code' => -32_000, 'message' => 'card declined' } }]
          else jsonrpc(message, { 'tools' => [] })
          end
        end

        expect { transport(klass).call_tool('charge', { 'amount' => 10 }) }
          .to raise_error(MCPClient::Errors::MCPError, /card declined/)
        expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(1)
      end

      # An SSE event is only dispatched by its terminating blank line, so a
      # final event whose JSON happens to be complete but whose terminator
      # never arrived carries no delivered response.
      it 're-issues when the final SSE event was cut before its terminator' do
        calls = 0
        start_server do |message|
          case message['method']
          when 'server/discover' then jsonrpc(message, discovery)
          when 'tools/call'
            calls += 1
            if calls == 1
              [MidStreamCloseServer::DELIVER_UNTERMINATED, jsonrpc(message, { 'content' => [] })]
            else
              jsonrpc(message, { 'content' => [{ 'type' => 'text' }] })
            end
          else jsonrpc(message, { 'tools' => [] })
          end
        end

        expect(transport(klass).call_tool('charge', { 'amount' => 10 }))
          .to eq({ 'content' => [{ 'type' => 'text' }] })
        expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(2)
      end

      # A TLS handshake that never completes proves the request never left the
      # client, so there is nothing in flight to replace. Counting connections
      # (rather than the exception the failed connect returns) is what pins
      # that: a classifier that called every socket failure an interrupted
      # exchange would open a second one.
      it 'opens exactly one connection when the TLS handshake fails' do
        start_server(tls: true) { |message| jsonrpc(message, discovery) }
        # No faraday_config: the self-signed certificate fails verification.
        @server = klass.new(base_url: @fixture.base_url, endpoint: '/mcp', retries: 0)

        expect { @server.connect }.to raise_error(MCPClient::Errors::ConnectionError) do |error|
          expect(error).not_to be_a(MCPClient::Errors::ResponseStreamClosedError)
        end
        expect(@fixture.connections).to eq(1)
        expect(@fixture.received).to be_empty
      end

      # MCP 2026-07-28 cancellation/timeouts: implementations SHOULD enforce a
      # maximum timeout regardless of progress. Faraday's socket timeout only
      # measures the gap between reads, which a keep-alive drip resets forever.
      it 'bounds discovery with discover_timeout while the server keeps the stream alive' do
        start_server do |message|
          message['method'] == 'server/discover' ? MidStreamCloseServer::DRIP_FOREVER : jsonrpc(message, {})
        end
        server = transport(klass, discover_timeout: 0.2, read_timeout: 30)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Timeout.timeout(15) do
          expect { server.connect }.to raise_error(MCPClient::Errors::MCPError)
        end
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
      end

      # MCP 2026-07-28 makes closing the response stream the cancellation
      # signal, so a timed-out modern request must actually tear the socket
      # down and send nothing else. Injecting Faraday::TimeoutError from a
      # stub would only show the second half.
      it 'closes the response stream on timeout and sends no cancellation' do
        start_server do |message|
          if message['method'] == 'server/discover'
            jsonrpc(message, discovery)
          else
            # Slower than the client's socket timeout, so the read times out
            # and Faraday aborts the connection.
            [MidStreamCloseServer::DRIP_FOREVER, 0.5]
          end
        end
        server = transport(klass, read_timeout: 0.2)
        server.connect

        expect { server.rpc_request('tools/list', {}) }
          .to raise_error(MCPClient::Errors::RequestTimeoutError)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.05 until @fixture.stream_aborted? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        expect(@fixture.stream_aborted?).to be(true)
        expect(methods_received).not_to include('notifications/cancelled')
      end

      # A notification has no response to lose, so a broken socket is a plain
      # connection failure and never enters the re-issue path.
      it 'does not enter response-stream recovery for a notification' do
        start_server do |message|
          message['method'] == 'server/discover' ? jsonrpc(message, discovery) : MidStreamCloseServer::CLOSE_MID_STREAM
        end
        server = transport(klass)
        server.connect

        expect { server.rpc_notify('notifications/progress', { 'progressToken' => 'p', 'progress' => 1 }) }
          .to raise_error(MCPClient::Errors::TransportError) do |error|
            expect(error).not_to be_a(MCPClient::Errors::ResponseStreamClosedError)
          end
        expect(@fixture.received.count { |r| r['method'] == 'notifications/progress' }).to eq(1)
      end

      it 're-issues the server/discover probe when the socket ends mid-stream' do
        probes = 0
        start_server do |message|
          case message['method']
          when 'server/discover'
            probes += 1
            probes == 1 ? MidStreamCloseServer::CLOSE_MID_STREAM : jsonrpc(message, discovery)
          when 'initialize' then raise 'initialize must not be sent after a lost response stream'
          else jsonrpc(message, { 'tools' => [] })
          end
        end

        transport(klass).connect

        expect(@server.protocol_era).to eq(:modern)
        expect(methods_received).to eq(%w[server/discover server/discover])
      end

      it 'surfaces the loss after exactly one re-issue when the socket ends mid-stream twice' do
        start_server do |message|
          message['method'] == 'server/discover' ? jsonrpc(message, discovery) : MidStreamCloseServer::CLOSE_MID_STREAM
        end

        expect { transport(klass).call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ResponseStreamClosedError)
        expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(2)
      end

      it 'attempts exactly one request when the connection was never established' do
        start_server { |message| jsonrpc(message, discovery) }
        port = @fixture.port
        @fixture.stop
        attempts = 0
        counter = Class.new(Faraday::Middleware) do
          define_method(:on_request) { |_env| attempts += 1 }
        end
        server = klass.new(base_url: "http://127.0.0.1:#{port}", endpoint: '/mcp', retries: 0,
                           faraday_config: ->(conn) { conn.builder.insert(0, counter) })

        expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError) do |error|
          expect(error).not_to be_a(MCPClient::Errors::ResponseStreamClosedError)
        end
        # Counting what went on the wire, not merely inspecting the exception
        # connect returns: that exception is a ConnectionError either way, so
        # a classifier that treated every socket failure as an interrupted
        # exchange would slip past an assertion about it while quietly
        # putting a replacement request on the wire.
        expect(attempts).to eq(1)
      ensure
        server&.cleanup
      end

      # --- Round 4: every request is bounded, the probe's replacement shares
      # its deadline, and a delivered answer survives a stall.
      describe 'deadlines' do
        # MCP 2026-07-28 cancellation/timeouts: implementations SHOULD enforce a
        # maximum timeout regardless of progress — for every request, not only
        # the probe. Keep-alives faster than the socket timeout never let the
        # socket go idle, so only an overall deadline can end the call.
        it 'bounds an ordinary request with its own timeout while the server keeps the stream alive' do
          start_server do |message|
            message['method'] == 'server/discover' ? jsonrpc(message, discovery) : MidStreamCloseServer::DRIP_FOREVER
          end
          server = transport(klass, read_timeout: 30)
          server.connect

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Timeout.timeout(15) do
            expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 0.2) }
              .to raise_error(MCPClient::Errors::RequestTimeoutError)
          end
          expect(elapsed_since(started)).to be < 2
          settled_within? { @fixture.stream_aborted? }
          expect(@fixture.stream_aborted?).to be(true)
        end

        it 'bounds a later heartbeat with the transport timeout while the server keeps the stream alive' do
          probes = 0
          start_server do |message|
            probes += 1
            probes == 1 ? jsonrpc(message, discovery) : MidStreamCloseServer::DRIP_FOREVER
          end
          server = transport(klass, read_timeout: 0.2)
          server.connect

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Timeout.timeout(15) do
            expect { server.rpc_request('ping', {}) }.to raise_error(MCPClient::Errors::RequestTimeoutError)
          end
          expect(elapsed_since(started)).to be < 2
        end

        # One deadline covers the probe and its re-issue: the replacement gets
        # what is left of discover_timeout, not a fresh socket timeout.
        it 'gives the re-issued probe only the time left on the discovery deadline' do
          probes = 0
          start_server do |_message|
            probes += 1
            if probes == 1
              [MidStreamCloseServer::DELAY, 0.7, MidStreamCloseServer::CLOSE_MID_STREAM]
            else
              MidStreamCloseServer::STALL
            end
          end
          server = transport(klass, discover_timeout: 1.0, read_timeout: 30)

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Timeout.timeout(15) do
            expect { server.connect }.to raise_error(MCPClient::Errors::MCPError, /timed out/)
          end
          # A replacement on a fresh 1.0 s socket timeout would take ~1.7 s.
          expect(elapsed_since(started)).to be < 1.45
          expect(probes).to eq(2)
        end

        # MCP 2026-07-28 cancellation/timeouts: "SHOULD always enforce a
        # maximum timeout regardless of progress". A socket timeout bounds the
        # gap between reads, so a server that reads back the clock — an event
        # late in the budget, or head bytes forever — outlives it.
        it 'ends a request whose stream falls silent late in its budget, not a timeout later' do
          start_server do |message|
            if message['method'] == 'server/discover'
              jsonrpc(message, discovery)
            else
              [MidStreamCloseServer::DELAY, 0.6,
               [MidStreamCloseServer::EVENT_THEN_STALL,
                { 'jsonrpc' => '2.0', 'method' => 'notifications/progress', 'params' => {} }]]
            end
          end
          server = transport(klass, read_timeout: 30)
          server.connect

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Timeout.timeout(15) do
            expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 1.0) }
              .to raise_error(MCPClient::Errors::RequestTimeoutError)
          end
          # Bounded by the request's own timeout. Restarting the socket clock
          # on the 0.6 s event would end it at ~1.6 s instead.
          expect(elapsed_since(started)).to be < 1.35
        end

        it 'ends a request whose head never finishes, which no socket timeout would' do
          start_server do |message|
            if message['method'] == 'server/discover'
              jsonrpc(message, discovery)
            else
              [MidStreamCloseServer::HEADER_DRIP, 0.02]
            end
          end
          server = transport(klass, read_timeout: 30)
          server.connect

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Timeout.timeout(15) do
            expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 1.0) }
              .to raise_error(MCPClient::Errors::RequestTimeoutError)
          end
          # Every read succeeds, so the socket timeout never fires at all.
          expect(elapsed_since(started)).to be < 1.35
        end

        it 'refuses an answer that arrives after the deadline instead of settling on it' do
          start_server do |message|
            if message['method'] == 'server/discover'
              jsonrpc(message, discovery)
            else
              [MidStreamCloseServer::HEADER_DRIP_THEN, 1.4, 0.02,
               [MidStreamCloseServer::DELIVER_THEN_STALL, jsonrpc(message, { 'content' => [] })]]
            end
          end
          server = transport(klass, read_timeout: 30)
          server.connect

          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Timeout.timeout(15) do
            expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 1.0) }
              .to raise_error(MCPClient::Errors::RequestTimeoutError)
          end
          # Ended at the deadline, so the answer the server sent at 1.4 s was
          # never read — a request cannot settle on an answer it waited past
          # its own bound to receive.
          expect(elapsed_since(started)).to be < 1.35
          expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(1)
        end

        # The re-issue rule is about a request that was *lost*. A server that
        # delivered the whole final event and then stalled has answered; the
        # timeout tears the stream down but the delivered answer settles the
        # request instead of a replacement request running it again.
        it 'keeps a delivered result when the stream stalls after the final SSE event until the timeout' do
          start_server do |message|
            if message['method'] == 'server/discover'
              jsonrpc(message, discovery)
            else
              [MidStreamCloseServer::DELIVER_THEN_STALL, jsonrpc(message, { 'content' => [] })]
            end
          end
          server = transport(klass, read_timeout: 0.3)
          server.connect

          Timeout.timeout(15) do
            expect(server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} })).to eq({ 'content' => [] })
          end
          expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(1)
        end
      end
    end
  end

  describe "#{MCPClient::ServerHTTP} response streams read as they arrive" do
    # A 2025-11-25 server may send a request on the POST response stream and
    # wait for the answer before finishing the response — a receiver "MUST
    # respond promptly" to ping. Answering only once the stream has ended
    # would deadlock both sides; the WebMock examples in the main spec hand
    # the ping and the result over together and cannot show that.
    it 'answers a legacy server ping while the response stream is still open' do
      start_server do |message|
        case message['method']
        when 'server/discover' then [MidStreamCloseServer::HTTP_STATUS, 400, 'Bad Request']
        when 'initialize' then jsonrpc(message, legacy_init)
        when 'tools/list'
          waiter = -> { settled_within?(3) { @fixture.received.any? { |m| m['id'] == 'ping-1' } } }
          [MidStreamCloseServer::EVENT_THEN_WAIT, { 'jsonrpc' => '2.0', 'id' => 'ping-1', 'method' => 'ping' },
           waiter, jsonrpc(message, { 'tools' => [] })]
        else [MidStreamCloseServer::HTTP_STATUS, 202, '']
        end
      end
      server = transport(MCPClient::ServerHTTP, read_timeout: 5)

      Timeout.timeout(15) { expect(server.list_tools).to eq([]) }

      pong = @fixture.received.find { |m| m['id'] == 'ping-1' }
      expect(pong).to include('jsonrpc' => '2.0', 'result' => {})
    end

    it 'answers an unsupported legacy server request with method not found while the stream is open' do
      start_server do |message|
        case message['method']
        when 'server/discover' then [MidStreamCloseServer::HTTP_STATUS, 400, 'Bad Request']
        when 'initialize' then jsonrpc(message, legacy_init)
        when 'tools/list'
          waiter = -> { settled_within?(3) { @fixture.received.any? { |m| m['id'] == 'req-1' } } }
          [MidStreamCloseServer::EVENT_THEN_WAIT,
           { 'jsonrpc' => '2.0', 'id' => 'req-1', 'method' => 'sampling/createMessage', 'params' => {} },
           waiter, jsonrpc(message, { 'tools' => [] })]
        else [MidStreamCloseServer::HTTP_STATUS, 202, '']
        end
      end
      server = transport(MCPClient::ServerHTTP, read_timeout: 5)

      Timeout.timeout(15) { expect(server.list_tools).to eq([]) }

      answer = @fixture.received.find { |m| m['id'] == 'req-1' }
      expect(answer.dig('error', 'code')).to eq(-32_601)
    end

    # Progress and log notifications are only useful while the request is
    # running: a server that reports progress and then finishes the work
    # must see the callback fire before it sends the result.
    it 'delivers a request-scoped notification before the modern response stream ends' do
      seen = Queue.new
      start_server do |message|
        if message['method'] == 'server/discover'
          jsonrpc(message, discovery)
        else
          waiter = -> { settled_within?(3) { !seen.empty? } }
          [MidStreamCloseServer::EVENT_THEN_WAIT,
           { 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
             'params' => { 'progressToken' => 'p', 'progress' => 1 } },
           waiter, jsonrpc(message, { 'content' => [] })]
        end
      end
      server = transport(MCPClient::ServerHTTP, read_timeout: 5)
      server.on_notification { |method, _params| seen << method }

      Timeout.timeout(15) do
        expect(server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} })).to eq({ 'content' => [] })
      end
      # Dispatched exactly once: not again when the completed body is parsed.
      expect(seen.size).to eq(1)
    end
  end

  describe 'deadlines bound connection setup' do
    # A deadline that is only checked as body bytes arrive says nothing about
    # a connection that never gets that far: a server that accepts the TCP
    # connection and then stalls the TLS handshake would hold the request
    # for the transport's whole open timeout. The clamped socket timeout has
    # to bound the handshake too.
    it 'gives up on a stalled TLS handshake at the discovery deadline' do
      start_server(tls: true, stall_handshake_from: 1) { |message| jsonrpc(message, discovery) }
      server = transport(MCPClient::ServerHTTP, read_timeout: 5, discover_timeout: 0.2)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { server.connect }.to raise_error(MCPClient::Errors::MCPError)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    end

    [MCPClient::ServerStreamableHTTP, MCPClient::ServerHTTP].each do |klass|
      it "gives up on a stalled TLS handshake at a request's own timeout on #{klass}" do
        start_server(tls: true, stall_handshake_from: 2) { |message| jsonrpc(message, discovery) }
        server = transport(klass, read_timeout: 5)
        server.connect
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect { server.rpc_request('tools/list', {}, timeout: 0.2) }.to raise_error(MCPClient::Errors::MCPError)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      end
    end
  end

  describe "#{MCPClient::ServerHTTP} legacy pings under every SSE framing" do
    def legacy_ping_server(framing)
      start_server do |message|
        case message['method']
        when 'server/discover' then [MidStreamCloseServer::HTTP_STATUS, 400, 'Bad Request']
        when 'initialize' then jsonrpc(message, legacy_init)
        when 'tools/list'
          waiter = -> { settled_within?(3) { @fixture.received.any? { |m| m['id'] == 'ping-1' } } }
          [MidStreamCloseServer::EVENT_THEN_WAIT, framing, waiter, jsonrpc(message, { 'tools' => [] })]
        else [MidStreamCloseServer::HTTP_STATUS, 202, '']
        end
      end
    end

    let(:ping) { JSON.generate('jsonrpc' => '2.0', 'id' => 'ping-1', 'method' => 'ping') }

    # SSE line terminators are CRLF, CR or LF. A bare CR that ends an event's
    # blank line completes the event whatever byte follows it, so it must not
    # be held back waiting for one — the server is waiting for the pong.
    it 'answers a ping framed with bare CR while the stream is open' do
      legacy_ping_server("data: #{ping}\r\r")
      server = transport(MCPClient::ServerHTTP, read_timeout: 5)

      Timeout.timeout(15) { expect(server.list_tools).to eq([]) }

      expect(@fixture.received.find { |m| m['id'] == 'ping-1' }).to include('result' => {})
    end

    it 'answers a ping whose CRLF terminator is split across chunks, once' do
      legacy_ping_server(["data: #{ping}\r\n\r", "\n"])
      server = transport(MCPClient::ServerHTTP, read_timeout: 5)

      Timeout.timeout(15) { expect(server.list_tools).to eq([]) }

      expect(@fixture.received.count { |m| m['id'] == 'ping-1' }).to eq(1)
    end

    it 'still scans a stream whose first chunk is only a blank line' do
      legacy_ping_server(["\n", "data: #{ping}\n\n"])
      server = transport(MCPClient::ServerHTTP, read_timeout: 5)

      Timeout.timeout(15) { expect(server.list_tools).to eq([]) }

      expect(@fixture.received.find { |m| m['id'] == 'ping-1' }).to include('result' => {})
    end
  end

  [MCPClient::ServerStreamableHTTP, MCPClient::ServerHTTP].each do |klass|
    describe "#{klass} notifications on a stream that ends badly" do
      let(:progress) do
        { 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
          'params' => { 'progressToken' => 'p', 'progress' => 1 } }
      end

      # A notification handed over while the body arrived must not be handed
      # over again when the delivered response is salvaged from the capture.
      it 'delivers a notification exactly once when the socket dies after the final SSE event' do
        seen = Queue.new
        start_server do |message|
          if message['method'] == 'server/discover'
            jsonrpc(message, discovery)
          else
            [MidStreamCloseServer::DELIVER_THEN_CLOSE, [progress, jsonrpc(message, { 'content' => [] })]]
          end
        end
        server = transport(klass, read_timeout: 5)
        server.on_notification { |method, _params| seen << method }

        expect(server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} })).to eq({ 'content' => [] })
        expect(seen.size).to eq(1)
        expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(1)
      end

      it 'delivers a notification exactly once when the stream stalls after the final SSE event' do
        seen = Queue.new
        start_server do |message|
          if message['method'] == 'server/discover'
            jsonrpc(message, discovery)
          else
            [MidStreamCloseServer::DELIVER_THEN_STALL, [progress, jsonrpc(message, { 'content' => [] })]]
          end
        end
        server = transport(klass, read_timeout: 0.3)
        server.on_notification { |method, _params| seen << method }

        Timeout.timeout(15) do
          expect(server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} })).to eq({ 'content' => [] })
        end
        expect(seen.size).to eq(1)
      end
    end
  end

  describe "#{MCPClient::ServerStreamableHTTP} response streams read as they arrive" do
    it 'delivers a request-scoped notification before the modern response stream ends' do
      seen = Queue.new
      start_server do |message|
        if message['method'] == 'server/discover'
          jsonrpc(message, discovery)
        else
          waiter = -> { settled_within?(3) { !seen.empty? } }
          [MidStreamCloseServer::EVENT_THEN_WAIT,
           { 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
             'params' => { 'progressToken' => 'p', 'progress' => 1 } },
           waiter, jsonrpc(message, { 'content' => [] })]
        end
      end
      server = transport(MCPClient::ServerStreamableHTTP, read_timeout: 5)
      server.on_notification { |method, _params| seen << method }

      Timeout.timeout(15) do
        expect(server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} })).to eq({ 'content' => [] })
      end
      expect(seen.size).to eq(1)
    end

    # Progress that only reaches the host once the stream has ended is no
    # progress at all when the stream ends in a timeout.
    it 'delivers a notification before the request times out' do
      seen = Queue.new
      start_server do |message|
        if message['method'] == 'server/discover'
          jsonrpc(message, discovery)
        else
          [MidStreamCloseServer::EVENT_THEN_STALL,
           { 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
             'params' => { 'progressToken' => 'p', 'progress' => 1 } }]
        end
      end
      server = transport(MCPClient::ServerStreamableHTTP, read_timeout: 0.3)
      server.on_notification { |method, _params| seen << method }

      Timeout.timeout(15) do
        expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }) }
          .to raise_error(MCPClient::Errors::RequestTimeoutError)
      end
      expect(seen.size).to eq(1)
    end

    it 'answers a legacy server ping while the response stream is still open' do
      start_server do |message|
        case message['method']
        when 'server/discover' then [MidStreamCloseServer::HTTP_STATUS, 400, 'Bad Request']
        when 'initialize' then jsonrpc(message, legacy_init)
        when 'tools/list'
          waiter = -> { settled_within?(3) { @fixture.received.any? { |m| m['id'] == 'ping-1' } } }
          [MidStreamCloseServer::EVENT_THEN_WAIT, { 'jsonrpc' => '2.0', 'id' => 'ping-1', 'method' => 'ping' },
           waiter, jsonrpc(message, { 'tools' => [] })]
        else [MidStreamCloseServer::HTTP_STATUS, 202, '']
        end
      end
      server = transport(MCPClient::ServerStreamableHTTP, read_timeout: 5)

      Timeout.timeout(15) { expect(server.list_tools).to eq([]) }

      expect(@fixture.received.find { |m| m['id'] == 'ping-1' }).to include('jsonrpc' => '2.0', 'result' => {})
    end

    # Streamable HTTP offers gzip on every request, so a delivered answer is
    # usually a delivered *compressed* answer: the salvage must inflate it
    # before it can tell the response arrived, or a tools/call that did run
    # is re-issued and runs again.
    it 'keeps a delivered gzip result when the socket dies after the final SSE event' do
      start_server do |message|
        case message['method']
        when 'server/discover' then jsonrpc(message, discovery)
        when 'tools/call' then [MidStreamCloseServer::GZIP_THEN_CLOSE, jsonrpc(message, { 'content' => [] })]
        else jsonrpc(message, { 'tools' => [] })
        end
      end

      expect(transport(MCPClient::ServerStreamableHTTP).call_tool('charge',
                                                                  { 'amount' => 10 })).to eq({ 'content' => [] })
      expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(1)
    end

    # The era rule keys on the status a recognized modern error came under:
    # 400 + a well-formed -32022 identifies a modern server and is retried
    # with an advertised version, while the same body under 200 is a
    # permissive legacy echo. A salvage that rebuilt every delivered answer as
    # 200 turned the first into the second, and the client fell back to a
    # handshake against a server that had just answered as modern.
    it 'keeps the status a delivered error arrived under' do
      start_server do |message|
        case message['method']
        when 'server/discover'
          if @fixture.received.count { |m| m['method'] == 'server/discover' } > 1
            jsonrpc(message, discovery)
          else
            [MidStreamCloseServer::STATUS_THEN_CLOSE, 400,
             { 'jsonrpc' => '2.0', 'id' => message['id'],
               'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                            'data' => { 'supported' => ['2026-07-28'], 'requested' => '2026-07-28' } } }]
          end
        else jsonrpc(message, { 'tools' => [] })
        end
      end
      server = transport(MCPClient::ServerStreamableHTTP)

      Timeout.timeout(15) { expect(server.list_tools).to eq([]) }

      expect(methods_received).not_to include('initialize')
      expect(server.protocol_era).to eq(:modern)
    end

    # A Content-Length body that stops short is a lost response like any
    # other, but nothing raises: Net::HTTP hands the short body back as if it
    # were whole, and only the length it promised says otherwise. Read as a
    # parse failure it would surface as a plain transport error and the
    # request the stream took with it would never be re-issued.
    it 'reissues a request whose Content-Length body stopped short' do
      calls = 0
      start_server do |message|
        case message['method']
        when 'server/discover' then jsonrpc(message, discovery)
        when 'tools/call'
          calls += 1
          if calls == 1
            [MidStreamCloseServer::SHORT_BODY,
             %({"jsonrpc":"2.0","id":"#{message['id']}","result":{"content":)]
          else
            jsonrpc(message, { 'content' => [] })
          end
        else jsonrpc(message, { 'tools' => [] })
        end
      end
      server = transport(MCPClient::ServerStreamableHTTP)

      Timeout.timeout(15) { expect(server.call_tool('charge', {})).to eq({ 'content' => [] }) }

      calls = @fixture.received.select { |r| r['method'] == 'tools/call' }
      expect(calls.size).to eq(2)
      expect(calls.map { |r| r['id'] }.uniq.size).to eq(2)
    end

    # An answer this client refuses to expand is not an answer that was lost.
    # The re-issue rule is for an in-flight request the broken stream took
    # with it; here the server ran the tool and sent its result, and only the
    # local expansion bound stands in the way. Re-issuing would charge twice,
    # so the caller is told the response was too large instead.
    it 'refuses an oversized delivered gzip answer rather than running the tool again' do
      start_server do |message|
        case message['method']
        when 'server/discover' then jsonrpc(message, discovery)
        when 'tools/call'
          [MidStreamCloseServer::GZIP_THEN_CLOSE,
           jsonrpc(message, { 'content' => [{ 'type' => 'text', 'text' => 'x' * 4096 }] })]
        else jsonrpc(message, { 'tools' => [] })
        end
      end
      server = transport(MCPClient::ServerStreamableHTTP, max_decompressed_body_bytes: 1024)

      expect { server.call_tool('charge', { 'amount' => 10 }) }
        .to raise_error(MCPClient::Errors::ResponseTooLargeError)
      expect(@fixture.received.count { |r| r['method'] == 'tools/call' }).to eq(1)
    end
  end

  # --- Round 6: the era is unknown while the probe is in flight; unknown SSE
  # fields; compressed events read live.

  HTTP_TRANSPORTS.each do |klass|
    describe "#{klass} while the era is still unknown" do
      # A 2025-11-25 server may send a request on the POST stream of ANY
      # request it answers — the probe included — and wait for the answer.
      # The probe proposes 2026-07-28 but has not established it, so a ping
      # on that stream is answered as on any legacy stream; a modern server
      # never sends one, so nothing is lost by answering.
      it 'answers a legacy server ping on the probe stream before the era is known' do
        start_server do |message|
          case message['method']
          when 'server/discover'
            waiter = -> { settled_within?(3) { @fixture.received.any? { |m| m['id'] == 'ping-0' } } }
            [MidStreamCloseServer::EVENT_THEN_WAIT, { 'jsonrpc' => '2.0', 'id' => 'ping-0', 'method' => 'ping' },
             waiter, { 'jsonrpc' => '2.0', 'id' => message['id'],
                       'error' => { 'code' => -32_601, 'message' => 'Method not found' } }]
          when 'initialize' then jsonrpc(message, legacy_init)
          when 'tools/list' then jsonrpc(message, { 'tools' => [] })
          else [MidStreamCloseServer::HTTP_STATUS, 202, '']
          end
        end
        server = transport(klass, read_timeout: 5)

        Timeout.timeout(15) { expect(server.list_tools).to eq([]) }

        expect(@fixture.received.find { |m| m['id'] == 'ping-0' }).to include('jsonrpc' => '2.0', 'result' => {})
        expect(methods_received).to include('initialize')
      end
    end

    describe "#{klass} streams that open with an unknown SSE field" do
      # SSE "Parsing an event stream": a field the client does not know is
      # ignored, not a reason to stop reading; the ping behind it is still
      # answered while the stream is open.
      it 'answers a legacy server ping sent behind a field it does not know' do
        start_server do |message|
          case message['method']
          when 'server/discover' then [MidStreamCloseServer::HTTP_STATUS, 400, 'Bad Request']
          when 'initialize' then jsonrpc(message, legacy_init)
          when 'tools/list'
            waiter = -> { settled_within?(3) { @fixture.received.any? { |m| m['id'] == 'ping-1' } } }
            ping = JSON.generate('jsonrpc' => '2.0', 'id' => 'ping-1', 'method' => 'ping')
            [MidStreamCloseServer::EVENT_THEN_WAIT, "x-ignore: 1\ndata: #{ping}\n\n", waiter,
             jsonrpc(message, { 'tools' => [] })]
          else [MidStreamCloseServer::HTTP_STATUS, 202, '']
          end
        end
        server = transport(klass, read_timeout: 5)

        Timeout.timeout(15) { expect(server.list_tools).to eq([]) }

        expect(@fixture.received.find { |m| m['id'] == 'ping-1' }).to include('jsonrpc' => '2.0', 'result' => {})
      end
    end
  end

  describe "#{MCPClient::ServerStreamableHTTP} compressed response streams read as they arrive" do
    # Streamable HTTP offers gzip on every request, so a live stream is a
    # compressed stream: a progress notification inside a deflate stream
    # that never ends must still reach the host before the request's
    # deadline tears the stream down.
    it 'delivers a compressed progress notification before the stream is torn down' do
      progress = { 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
                   'params' => { 'progressToken' => 'p', 'progress' => 1 } }
      start_server do |message|
        case message['method']
        when 'server/discover' then jsonrpc(message, discovery)
        when 'tools/call' then [MidStreamCloseServer::GZIP_EVENTS_THEN_STALL, progress]
        else jsonrpc(message, { 'tools' => [] })
        end
      end
      seen = Queue.new
      server = transport(MCPClient::ServerStreamableHTTP, read_timeout: 0.5)
      server.on_notification { |method, _params| seen << method }

      Timeout.timeout(15) do
        expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }) }
          .to raise_error(MCPClient::Errors::RequestTimeoutError)
      end
      expect(seen.size).to eq(1)
      expect(seen.pop).to eq('notifications/progress')
    end

    # The bound belongs to the transport, not only to the reader that takes
    # one: a live stream must be given the configured ceiling, or a peer can
    # make this client allocate without limit while the body is still open.
    it 'reads a live compressed stream under the configured expansion bound' do
      bomb = { 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
               'params' => { 'progressToken' => 'p', 'progress' => 1, 'padding' => 'a' * (4 * 1024 * 1024) } }
      start_server do |message|
        case message['method']
        when 'server/discover' then jsonrpc(message, discovery)
        when 'tools/call' then [MidStreamCloseServer::GZIP_EVENTS_THEN_STALL, bomb]
        else jsonrpc(message, { 'tools' => [] })
        end
      end
      inflated = 0
      allow_any_instance_of(Zlib::Inflate).to receive(:inflate).and_wrap_original do |original, bytes, &block|
        if block
          original.call(bytes) { |piece| inflated += piece.bytesize and block.call(piece) }
        else
          original.call(bytes).tap { |text| inflated += text.bytesize }
        end
      end
      server = transport(MCPClient::ServerStreamableHTTP, read_timeout: 0.5, max_decompressed_body_bytes: 1024)

      Timeout.timeout(15) do
        expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }) }
          .to raise_error(MCPClient::Errors::MCPError)
      end

      expect(inflated).to be <= 1024 + (64 * 1024)
    end
  end
end
