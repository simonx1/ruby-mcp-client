# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'zlib'
require 'stringio'

# MCP 2026-07-28 Streamable HTTP modern mode, fourth review round:
#
# - era detection follows the HTTP-status rule of "Backward Compatibility":
#   a recognized modern error settles the era only in a 400 body (plus the
#   404/-32601 pairing); the same body under 200 or 405 is a legacy answer;
# - an SSE event whose terminating blank line never arrived was never
#   dispatched, on a completed HTTP response exactly as on a broken socket;
# - a complete but corrupt gzip body is a bad response, not a broken stream;
# - once the server is known to be modern, a reconnect probe that fails
#   inconclusively is reported as what it was.
RSpec.describe 'MCP 2026-07-28 Streamable HTTP modern mode — round 4' do
  let(:url) { 'https://example.com/mcp' }

  def discover_result(versions: ['2026-07-28'])
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => { 'tools' => {} } }
  end

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def error_response(status, code, message, data = nil)
    error = { 'code' => code, 'message' => message }
    error['data'] = data if data
    { status: status, body: JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => error),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def sse_response(body)
    { status: 200, body: body, headers: { 'Content-Type' => 'text/event-stream' } }
  end

  def legacy_init_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } }
  end

  # Answer every POST from `responders` keyed by method, recording the bodies
  # and the request headers.
  def stub_posts(responders)
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { body: body, headers: request.headers }
      responder = responders.fetch(body['method']) { raise "unexpected method #{body['method']}" }
      responder.respond_to?(:call) ? responder.call(body) : json_response(body['id'], responder)
    end
    requests
  end

  def methods_sent(requests)
    requests.map { |r| r[:body]['method'] }
  end

  def legacy_handshake(extra = {})
    {
      'server/discover' => ->(_body) { { status: 404, body: '' } },
      'initialize' => ->(body) { json_response(body['id'], legacy_init_result) },
      'notifications/initialized' => ->(_body) { { status: 202, body: '' } },
      'tools/list' => { 'tools' => [] }
    }.merge(extra)
  end

  HTTP_TRANSPORTS = [MCPClient::ServerStreamableHTTP, MCPClient::ServerHTTP].freeze unless defined?(HTTP_TRANSPORTS)

  HTTP_TRANSPORTS.each do |klass|
    describe klass do
      let(:server) { klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

      before { stub_request(:get, url).to_return(status: 405, body: '') }
      after { server.cleanup }

      describe 'era detection by HTTP status' do
        # Streamable HTTP "Backward Compatibility" identifies the reserved
        # errors in a **400** response. A legacy endpoint that answers 200
        # with a body carrying one of those codes has not spoken 2026-07-28.
        it 'treats a 200 carrying a reserved modern error code as a legacy answer' do
          requests = stub_posts(legacy_handshake(
                                  'server/discover' => ->(_body) { error_response(200, -32_020, 'Header mismatch') }
                                ))

          server.connect

          expect(server.protocol_era).to eq(:legacy)
          expect(methods_sent(requests).first(2)).to eq(%w[server/discover initialize])
        end

        it 'treats a 405 carrying a well-formed -32022 as a legacy answer' do
          requests = stub_posts(legacy_handshake(
                                  'server/discover' => lambda do |_body|
                                    error_response(405, -32_022, 'Unsupported',
                                                   { 'supported' => ['2026-07-28'], 'requested' => '2026-07-28' })
                                  end
                                ))

          server.connect

          expect(server.protocol_era).to eq(:legacy)
          expect(methods_sent(requests).first(2)).to eq(%w[server/discover initialize])
        end

        it 'treats a 400 HeaderMismatch surfaced by raise_error middleware as a modern server' do
          server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                             faraday_config: ->(conn) { conn.response :raise_error })
          requests = stub_posts(legacy_handshake(
                                  'server/discover' => ->(_body) { error_response(400, -32_020, 'Header mismatch') }
                                ))

          expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Header mismatch/)
          # The verdict is cached: a second attempt never falls back either.
          expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Header mismatch/)
          expect(methods_sent(requests)).to eq(%w[server/discover server/discover])
        ensure
          server&.cleanup
        end

        # A typed error on an ordinary request after the era was settled still
        # reaches the caller as itself; only the era verdict is status-gated.
        it 'keeps a post-connect HeaderMismatch typed' do
          stub_posts(
            'server/discover' => ->(body) { json_response(body['id'], discover_result) },
            'tools/call' => ->(_body) { error_response(400, -32_020, 'Header mismatch') },
            'tools/list' => { 'tools' => [] }
          )
          server.connect

          expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::HeaderMismatchError)
        end
      end

      describe 'a completed response whose final SSE event is unterminated' do
        # The SSE processing model dispatches an event at its terminating
        # blank line; a file that ends inside an event discards it. A body
        # that ends that way delivered nothing, so on a modern server the
        # request was lost and is re-issued.
        it 're-issues a modern request once with a new id and accepts the properly framed replacement' do
          calls = 0
          requests = stub_posts(
            'server/discover' => ->(body) { json_response(body['id'], discover_result) },
            'tools/call' => lambda do |body|
              calls += 1
              payload = JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] })
              calls == 1 ? sse_response("data: #{payload}\n") : sse_response("data: #{payload}\n\n")
            end,
            'tools/list' => { 'tools' => [] }
          )
          server.connect

          expect(server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} })).to eq({ 'content' => [] })
          ids = requests.select { |r| r[:body]['method'] == 'tools/call' }.map { |r| r[:body]['id'] }
          expect(ids.size).to eq(2)
          expect(ids.uniq.size).to eq(2)
        end

        it 'surfaces the loss after exactly one re-issue when both bodies are unterminated' do
          requests = stub_posts(
            'server/discover' => ->(body) { json_response(body['id'], discover_result) },
            'tools/call' => lambda do |body|
              payload = JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] })
              sse_response("data: #{payload}\n")
            end,
            'tools/list' => { 'tools' => [] }
          )
          server.connect

          expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }) }
            .to raise_error(MCPClient::Errors::ResponseStreamClosedError)
          expect(requests.count { |r| r[:body]['method'] == 'tools/call' }).to eq(2)
        end
      end

      describe 'a reconnect probe after the server was found modern' do
        # The cached verdict stops the initialize fallback; it does not turn
        # a probe that never completed into "modern but incompatible".
        it 'reports a 5xx on the reconnect probe as the transient server error it was' do
          probes = 0
          requests = stub_posts(
            'server/discover' => lambda do |body|
              probes += 1
              probes == 1 ? json_response(body['id'], discover_result) : { status: 503, body: '' }
            end,
            'initialize' => ->(_body) { raise 'initialize must never be sent to a modern server' },
            'tools/list' => { 'tools' => [] }
          )
          server.connect
          server.cleanup

          expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /HTTP 503/) do |error|
            expect(error).not_to be_a(MCPClient::Errors::ModernServerError)
            expect(error.cause).to be_a(MCPClient::Errors::TransientServerError)
          end
          expect(methods_sent(requests)).not_to include('initialize')
          expect(methods_sent(requests).count('server/discover')).to eq(2)
        end

        it 'reports a timeout on the reconnect probe as a timeout' do
          probes = 0
          stub_posts(
            'server/discover' => lambda do |body|
              probes += 1
              raise Faraday::TimeoutError, 'execution expired' if probes > 1

              json_response(body['id'], discover_result)
            end,
            'tools/list' => { 'tools' => [] }
          )
          server.connect
          server.cleanup

          expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /timed out/) do |error|
            expect(error).not_to be_a(MCPClient::Errors::ModernServerError)
            expect(error.cause).to be_a(MCPClient::Errors::RequestTimeoutError)
          end
        end
      end

      describe 'request metadata on the wire' do
        it 'mirrors taskId into Mcp-Name for tasks/get, tasks/update and tasks/cancel' do
          requests = stub_posts(
            'server/discover' => ->(body) { json_response(body['id'], discover_result) },
            'tasks/get' => { 'taskId' => 'task-1', 'status' => 'working' },
            'tasks/update' => {},
            'tasks/cancel' => {},
            'tools/list' => { 'tools' => [] }
          )
          server.connect

          %w[tasks/get tasks/update tasks/cancel].each do |method|
            server.rpc_request(method, { 'taskId' => 'task-1' })
          end

          names = requests.select { |r| r[:body]['method'].start_with?('tasks/') }.map { |r| r[:headers]['Mcp-Name'] }
          expect(names).to eq(%w[task-1 task-1 task-1])
        end

        it 'Base64-encodes a resources/read URI that is not header-safe' do
          requests = stub_posts(
            'server/discover' => ->(body) { json_response(body['id'], discover_result) },
            'resources/read' => { 'contents' => [] },
            'tools/list' => { 'tools' => [] }
          )
          server.connect

          server.rpc_request('resources/read', { 'uri' => 'file:///données.txt' })

          read = requests.find { |r| r[:body]['method'] == 'resources/read' }
          expect(read[:headers]['Mcp-Name']).to eq("=?base64?#{Base64.strict_encode64('file:///données.txt')}?=")
        end

        # The header must match the version the body was built with, not the
        # transport's current version: another caller may switch versions
        # between body construction and header attachment.
        it 'takes MCP-Protocol-Version from the request body rather than the transport' do
          stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
          stub_posts('server/discover' => ->(body) { json_response(body['id'], discover_result) },
                     'tools/list' => { 'tools' => [] })
          server.connect
          request = server.send(:build_jsonrpc_request, 'tools/list', {}, 99)
          server.instance_variable_set(:@protocol_version, '2027-01-01')
          headers = server.send(:modern_request_headers, request)

          expect(request.dig('params', '_meta', 'io.modelcontextprotocol/protocolVersion')).to eq('2026-07-28')
          expect(headers['MCP-Protocol-Version']).to eq('2026-07-28')
        end
      end

      describe 'removed methods' do
        it 'rejects an invalid modern log level without a request' do
          requests = stub_posts('server/discover' => ->(body) { json_response(body['id'], discover_result) },
                                'tools/list' => { 'tools' => [] })
          server.connect

          expect { server.log_level = 'loud' }.to raise_error(ArgumentError)
          expect(methods_sent(requests)).to eq(['server/discover'])
        end

        it 'never POSTs notifications/initialized to a modern server' do
          requests = stub_posts('server/discover' => ->(body) { json_response(body['id'], discover_result) },
                                'tools/list' => { 'tools' => [] })
          server.connect

          server.rpc_notify('notifications/initialized', {})

          expect(methods_sent(requests)).to eq(['server/discover'])
        end
      end
    end
  end

  describe MCPClient::ServerStreamableHTTP do
    let(:server) { described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

    before { stub_request(:get, url).to_return(status: 405, body: '') }
    after { server.cleanup }

    def gzip(text)
      io = StringIO.new
      writer = Zlib::GzipWriter.new(io)
      writer.write(text)
      writer.close
      io.string
    end

    # A body Faraday read to completion is not a broken stream, however bad
    # its bytes: re-issuing would run the request again for a proxy's or
    # server's encoding bug. Only a body that stops before its footer was cut.
    it 'does not re-issue a request whose completed gzip body is corrupt' do
      payload = gzip(JSON.generate('jsonrpc' => '2.0', 'id' => 2, 'result' => { 'content' => [] }))
      corrupt = payload.dup.b
      corrupt[payload.bytesize / 2] = (corrupt.getbyte(payload.bytesize / 2) ^ 0xFF).chr
      requests = stub_posts(
        'server/discover' => ->(body) { json_response(body['id'], discover_result) },
        'tools/call' => lambda do |_body|
          { status: 200, body: corrupt,
            headers: { 'Content-Type' => 'application/json', 'Content-Encoding' => 'gzip' } }
        end,
        'tools/list' => { 'tools' => [] }
      )
      server.connect

      expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }) }
        .to raise_error(MCPClient::Errors::TransportError) do |error|
          expect(error).not_to be_a(MCPClient::Errors::ResponseStreamClosedError)
        end
      expect(requests.count { |r| r[:body]['method'] == 'tools/call' }).to eq(1)
    end

    it 'still accepts an unterminated final SSE event from a legacy server' do
      requests = stub_posts(legacy_handshake(
                              'tools/list' => lambda do |body|
                                payload = JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                                        'result' => { 'tools' => [] })
                                sse_response("data: #{payload}\n")
                              end
                            ))

      expect(server.list_tools).to eq([])
      expect(requests.count { |r| r[:body]['method'] == 'tools/list' }).to eq(1)
    end

    # Auto negotiation against a legacy server, end to end: discovery is
    # rejected, the session is established by initialize and then carried and
    # terminated like a 2025-11-25 session.
    it 'runs a legacy session through auto negotiation' do
      requests = stub_posts(legacy_handshake(
                              'initialize' => lambda do |body|
                                response = json_response(body['id'], legacy_init_result)
                                response.merge(headers: { 'Content-Type' => 'application/json',
                                                          'Mcp-Session-Id' => 'sess-1' })
                              end
                            ))
      deletes = stub_request(:delete, url).with(headers: { 'Mcp-Session-Id' => 'sess-1' }).to_return(status: 200)

      expect(server.list_tools).to eq([])
      server.cleanup

      expect(server.protocol_era).to eq(:legacy)
      expect(methods_sent(requests)).to eq(%w[server/discover initialize notifications/initialized tools/list])
      expect(requests.last[:headers]['Mcp-Session-Id']).to eq('sess-1')
      expect(deletes).to have_been_requested
    end
  end
end
