# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 Streamable HTTP modern mode, fifth review round:
#
# - a 404 whose -32601 error object is malformed (no string `message`)
#   identifies no modern server, exactly like a bare -3202x, and the
#   verdict is not cached either;
# - MCP-Protocol-Version on the wire matches the body it was built with,
#   however the transport's version moved in between;
# - concurrent requests rejected for their version each retry once;
# - a legacy session reached through auto negotiation still recovers from
#   session expiry; a comment keep-alive is never a notification.
RSpec.describe 'MCP 2026-07-28 Streamable HTTP modern mode — round 5' do
  let(:url) { 'https://example.com/mcp' }
  let(:json) { { 'Content-Type' => 'application/json' } }

  def discover_result(versions: ['2026-07-28'])
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => { 'tools' => {} } }
  end

  def json_response(id, result, headers = {})
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: json.merge(headers) }
  end

  def legacy_init_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } }
  end

  def stub_posts(responders)
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { body: body, headers: request.headers }
      responder = responders.fetch(body['method']) { raise "unexpected method #{body['method']}" }
      responder.respond_to?(:call) ? responder.call(body, request) : json_response(body['id'], responder)
    end
    requests
  end

  def methods_sent(requests)
    requests.map { |r| r[:body]['method'] }
  end

  ROUND5_TRANSPORTS = [MCPClient::ServerStreamableHTTP, MCPClient::ServerHTTP].freeze unless defined?(ROUND5_TRANSPORTS)

  ROUND5_TRANSPORTS.each do |klass|
    describe klass do
      let(:server) { klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

      before { stub_request(:get, url).to_return(status: 405, body: '') }

      describe 'a malformed 404 probe answer' do
        def malformed_not_found(error)
          { status: 404, body: JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => error), headers: json }
        end

        def legacy_after(probe, extra = {})
          {
            'server/discover' => ->(_body, _req) { probe },
            'initialize' => ->(body, _req) { json_response(body['id'], legacy_init_result) },
            'notifications/initialized' => ->(_body, _req) { { status: 202, body: '' } },
            'tools/list' => { 'tools' => [] }
          }.merge(extra)
        end

        [{ 'code' => -32_601 }, { 'code' => -32_601, 'message' => 42 }].each do |error|
          it "falls back to the handshake on a 404 whose -32601 error is #{error.inspect}" do
            requests = stub_posts(legacy_after(malformed_not_found(error)))

            server.connect

            expect(server.protocol_era).to eq(:legacy)
            expect(methods_sent(requests)).to start_with('server/discover', 'initialize')
          end
        end

        it 'does not cache the malformed answer as a modern verdict' do
          requests = stub_posts(legacy_after(malformed_not_found('code' => -32_601)))
          server.connect
          server.cleanup

          server.connect

          expect(server.protocol_era).to eq(:legacy)
          expect(methods_sent(requests).count('initialize')).to eq(2)
        end

        it 'falls back to the handshake when raise_error middleware surfaces the malformed 404' do
          server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                             faraday_config: ->(conn) { conn.response :raise_error })
          requests = stub_posts(legacy_after(malformed_not_found('code' => -32_601)))

          server.connect

          expect(server.protocol_era).to eq(:legacy)
          expect(methods_sent(requests)).to start_with('server/discover', 'initialize')
        end

        # Positive control: the well-formed pairing still identifies a modern
        # server without discovery support.
        it 'still takes a well-formed 404 + -32601 as a modern server' do
          requests = stub_posts(legacy_after(malformed_not_found('code' => -32_601, 'message' => 'Method not found')))

          server.connect

          expect(server.protocol_era).to eq(:modern)
          expect(methods_sent(requests)).to eq(['server/discover'])
        end
      end

      describe 'MCP-Protocol-Version on the wire' do
        # Another caller may move the transport's version between the moment a
        # request body is built and the moment its headers are attached; the
        # header must still be the one the body was built with.
        it 'matches the body it was built with even when the transport moved on in between' do
          stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
          requests = stub_posts('server/discover' => ->(body, _req) { json_response(body['id'], discover_result) },
                                'tools/list' => { 'tools' => [] })
          server.connect
          switched = false
          allow(server).to receive(:apply_request_headers).and_wrap_original do |original, req, request|
            unless switched
              switched = true
              server.instance_variable_set(:@protocol_version, '2027-01-01')
            end
            original.call(req, request)
          end

          server.rpc_request('tools/list', {})

          sent = requests.find { |r| r[:body]['method'] == 'tools/list' }
          expect(sent[:body].dig('params', '_meta', 'io.modelcontextprotocol/protocolVersion')).to eq('2026-07-28')
          expect(sent[:headers]['Mcp-Protocol-Version']).to eq('2026-07-28')
        end
      end

      describe 'concurrent version rejections' do
        it 'retries each rejected request once with the advertised version' do
          stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
          rejection = { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                        'data' => { 'supported' => ['2027-01-01'], 'requested' => '2026-07-28' } }
          # Both requests go out under the old version: the first one to be
          # answered waits for the second to arrive, so neither can be built
          # after the other's rejection already moved the transport on.
          arrivals = Queue.new
          requests = stub_posts(
            'server/discover' => ->(body, _req) { json_response(body['id'], discover_result) },
            'tools/list' => lambda do |body, _req|
              if body.dig('params', '_meta', 'io.modelcontextprotocol/protocolVersion') == '2026-07-28'
                arrivals << body['id']
                deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
                sleep 0.01 while arrivals.size < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
                { status: 400, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'error' => rejection),
                  headers: json }
              else
                json_response(body['id'], { 'tools' => [] })
              end
            end
          )
          server.connect

          results = Array.new(2) { Thread.new { server.rpc_request('tools/list', {}) } }.map(&:value)

          expect(results).to eq([{ 'tools' => [] }, { 'tools' => [] }])
          versions = requests.select { |r| r[:body]['method'] == 'tools/list' }
                             .map { |r| r[:body].dig('params', '_meta', 'io.modelcontextprotocol/protocolVersion') }
          expect(versions.count('2026-07-28')).to eq(2)
          expect(versions.count('2027-01-01')).to eq(2)
          expect(server.protocol_version).to eq('2027-01-01')
        end
      end

      describe 'a comment keep-alive on the response stream' do
        it 'is never dispatched as a notification' do
          notifications = []
          server.on_notification { |method, params| notifications << [method, params] }
          stub_posts(
            'server/discover' => ->(body, _req) { json_response(body['id'], discover_result) },
            'tools/list' => { 'tools' => [] },
            'tools/call' => lambda do |body, _req|
              result = JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] })
              { status: 200, body: ": keep-alive\n\nevent: message\ndata: #{result}\n\n",
                headers: { 'Content-Type' => 'text/event-stream' } }
            end
          )
          server.connect

          expect(server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} })).to eq({ 'content' => [] })
          expect(notifications).to be_empty
        end
      end
    end
  end

  describe 'a legacy session reached through auto negotiation' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

    before { stub_request(:get, url).to_return(status: 405, body: '') }

    # The 2025-11-25 session rules still apply to the session the fallback
    # established: a 404 on a request carrying its id means the session
    # expired, and a fresh initialize (without the id) recovers it.
    it 'recovers from session expiry with a fresh initialize' do
      sessions = %w[sess-1 sess-2]
      requests = stub_posts(
        'server/discover' => ->(_body, _req) { { status: 404, body: '' } },
        'initialize' => lambda { |body, _req|
          json_response(body['id'], legacy_init_result, 'Mcp-Session-Id' => sessions.shift)
        },
        'notifications/initialized' => ->(_body, _req) { { status: 202, body: '' } },
        'tools/list' => lambda do |body, req|
          if req.headers['Mcp-Session-Id'] == 'sess-1'
            { status: 404, body: '' }
          else
            json_response(body['id'], { 'tools' => [] })
          end
        end
      )
      server.connect

      expect(server.list_tools).to eq([])

      lists = requests.select { |r| r[:body]['method'] == 'tools/list' }
      expect(lists.map { |r| r[:headers]['Mcp-Session-Id'] }).to eq(%w[sess-1 sess-2])
      inits = requests.select { |r| r[:body]['method'] == 'initialize' }
      expect(inits.size).to eq(2)
      expect(inits.last[:headers]).not_to have_key('Mcp-Session-Id')
    end
  end
end
