# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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

      it 'bounds the probe with discover_timeout and leaves other requests on the default timeout' do
        timeouts = []
        recorder = Class.new(Faraday::Middleware) do
          define_method(:on_request) { |env| timeouts << env.request.timeout }
        end
        server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                           read_timeout: 30, discover_timeout: 3,
                           faraday_config: ->(conn) { conn.builder.insert(0, recorder) })
        stub_posts('server/discover' => discover_result, 'tools/list' => { 'tools' => [] })
        stub_request(:get, url).to_return(status: 405, body: '')

        server.list_tools

        expect(timeouts.first).to eq(3)
        expect(timeouts.last).to eq(30)
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
      stub_request(:get, url).to_return(status: 405, body: '')
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
      expect(server.instance_variable_get(:@events_thread)).not_to be_nil
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

# A real HTTP server on 127.0.0.1 that can end a response *mid-stream*.
#
# The WebMock broken-stream fixtures above return a **completed** HTTP
# response whose SSE body happens to carry no result. That is not the failure
# the 2026-07-28 re-issue rule is about: an actual broken response stream is a
# socket that stops in the middle of the body, which Faraday surfaces as a
# connection failure rather than as a short body. This server produces exactly
# that — status line, SSE headers, one chunk, then close, with no terminating
# chunk — so the re-issue path is exercised against the error a real network
# failure raises.
class MidStreamCloseServer
  # Reply token: send SSE headers and one chunk, then close the socket.
  CLOSE_MID_STREAM = :close_mid_stream

  # @return [Integer] the ephemeral port the server listens on
  attr_reader :port

  # @yieldparam message [Hash] the JSON-RPC message the client POSTed
  # @yieldreturn [Hash, Symbol] a JSON-RPC reply, or CLOSE_MID_STREAM
  def initialize(&responder)
    @responder = responder
    @received = []
    @mutex = Mutex.new
    @listener = TCPServer.new('127.0.0.1', 0)
    @port = @listener.addr[1]
    @thread = Thread.new { accept_loop }
  end

  # @return [Array<Hash>] every JSON-RPC message received, in order
  def received
    @mutex.synchronize { @received.dup }
  end

  # @return [void]
  def stop
    @thread&.kill
    @listener.close unless @listener.closed?
  rescue IOError
    nil
  end

  private

  def accept_loop
    loop do
      client = @listener.accept
      begin
        serve(client)
      rescue StandardError
        nil
      ensure
        begin
          client.close
        rescue StandardError
          nil
        end
      end
    end
  rescue StandardError
    nil
  end

  def serve(client)
    return unless client.gets # the request line

    headers = read_headers(client)
    message = JSON.parse(client.read(headers['content-length'].to_i).to_s)
    @mutex.synchronize { @received << message }
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
    if reply == CLOSE_MID_STREAM
      chunk = ": keep-alive\n\n"
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" \
                   "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
      client.write(format("%<size>x\r\n%<chunk>s\r\n", size: chunk.bytesize, chunk: chunk))
    else
      body = JSON.generate(reply)
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end
    client.flush
  end
end

RSpec.describe 'MCP 2026-07-28 Streamable HTTP — a response stream that really breaks' do
  before do
    # The shared server/discover stub in spec_helper would intercept the probe
    # before it reached the local socket.
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  after do
    @server&.cleanup
    @fixture&.stop
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  def jsonrpc(message, result)
    { 'jsonrpc' => '2.0', 'id' => message['id'], 'result' => result }
  end

  def discovery
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {} } }
  end

  def start_server(&responder)
    @fixture = MidStreamCloseServer.new(&responder)
  end

  def transport(klass, **opts)
    @server = klass.new(base_url: "http://127.0.0.1:#{@fixture.port}", endpoint: '/mcp', retries: 0, **opts)
  end

  def methods_received
    @fixture.received.map { |r| r['method'] }
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

      it 'does not re-issue when the connection was never established' do
        start_server { |message| jsonrpc(message, discovery) }
        port = @fixture.port
        @fixture.stop
        server = klass.new(base_url: "http://127.0.0.1:#{port}", endpoint: '/mcp', retries: 0)

        expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError) do |error|
          expect(error).not_to be_a(MCPClient::Errors::ResponseStreamClosedError)
        end
      ensure
        server&.cleanup
      end
    end
  end
end
