# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 protocol foundations, eighth review round: the 2025-11-25
# session-expiry rule is unconditional on an established legacy session (a
# modern server's -32601 answer never overrides it, because a modern session
# carries no session id to expire); a JSON-RPC envelope carrying neither a
# result nor an error member is malformed rather than a successful nil; and
# the discriminator is validated on the paths a caller actually reaches —
# ServerSSE's direct JSON responses and every page of a stdio list, not only
# the first.
RSpec.describe 'MCP 2026-07-28 protocol foundations — round 8' do
  describe 'the session-expiry rule of the era the session was negotiated under' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/rpc' }
    let(:method_not_found) { { 'code' => -32_601, 'message' => 'Method not found' } }

    def posted_methods
      WebMock::RequestRegistry.instance.requested_signatures.hash.keys
                              .map { |signature| JSON.parse(signature.body)['method'] }
    end

    # The old session answers `vendor/unknown` with a well-formed -32601
    # under HTTP 404; a fresh initialize is accepted and the replay answered.
    def serve_unknown_method_not_found
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          { status: 200, headers: { 'Content-Type' => 'application/json', 'Mcp-Session-Id' => 'session-fresh' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                              'serverInfo' => { 'name' => 's', 'version' => '1' } }) }
        when 'notifications/initialized'
          { status: 202, body: '' }
        else
          if request.headers['Mcp-Session-Id'] == 'session-abc'
            { status: 404, headers: { 'Content-Type' => 'application/json' },
              body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'error' => method_not_found) }
          else
            { status: 200, headers: { 'Content-Type' => 'application/json' },
              body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'answered' => true }) }
          end
        end
      end
    end

    def server_for(klass, era, **opts)
      server = klass.new(base_url: base_url, endpoint: endpoint, retries: 0, **opts)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, era)
      server.instance_variable_set(:@session_id, 'session-abc')
      server
    end

    [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
      [nil, ->(conn) { conn.response :raise_error }].each do |config|
        path = config ? "through a host's raise_error middleware" : 'on the response path'

        context "with #{klass} #{path}" do
          let(:options) { config ? { faraday_config: config } : {} }

          # 2025-11-25 session management: "When receiving HTTP 404 in response
          # to a request containing an Mcp-Session-Id, the client MUST start a
          # new session by sending a new InitializeRequest without a session
          # ID." The rule names the status and the session id, and takes no
          # exception for what the body carries: a server on the revision this
          # session negotiated answers an expired session, not the request.
          it 'restarts a negotiated 2025-11-25 session on a 404 however its body reads' do
            server = server_for(klass, '2025-11-25', **options)
            serve_unknown_method_not_found

            expect(server.rpc_request('vendor/unknown')).to eq({ 'answered' => true })
            expect(posted_methods).to eq(%w[vendor/unknown initialize notifications/initialized vendor/unknown])
            expect(server.instance_variable_get(:@session_id)).to eq('session-fresh')
          end

          # Off that session — an era never established, or a modern one whose
          # server assigned a session id it has no business assigning — the
          # 404 is MCP 2026-07-28's answer to this very request, and replaying
          # it after a fresh initialize would only ask the unknown method again.
          it 'answers a well-formed -32601 without a restart when no legacy session was negotiated' do
            server = server_for(klass, nil, **options)
            serve_unknown_method_not_found

            expect { server.rpc_request('vendor/unknown') }
              .to raise_error(MCPClient::Errors::MethodNotFoundError) { |e| expect(e.http_status).to eq(404) }
            expect(posted_methods).to eq(['vendor/unknown'])
            expect(server.instance_variable_get(:@session_id)).to eq('session-abc')
          end
        end
      end
    end
  end

  describe 'a JSON-RPC envelope that answers with neither a result nor an error' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 2, retries: 0) }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
    end

    # JSON-RPC 2.0 section 5: "Either the result member or error member MUST
    # be included". An envelope with neither answers nothing; taking its
    # absent result for a delivered nil turns a malformed response into a
    # successful call.
    def deliver(payload)
      allow(server).to receive(:post_json_rpc_request) do |request|
        body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => request['id'] }.merge(payload))
        server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
        nil
      end
    end

    it 'is invalid rather than a successful nil result' do
      deliver({})

      expect { server.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /neither a result nor an error/)
    end

    it 'leaves an explicit null result delivered as the answer it is' do
      deliver('result' => nil)

      expect(server.rpc_request('vendor/thing')).to be_nil
    end

    it 'still delivers an explicit false result' do
      deliver('result' => false)

      expect(server.rpc_request('vendor/thing')).to be(false)
    end
  end

  describe "ServerSSE's direct JSON responses, through the path a caller takes" do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 2, retries: 0) }

    # A ServerSSE whose endpoint answers the POST directly (no stream) takes
    # the parse_direct_response branch of send_jsonrpc_request. Reaching it
    # through rpc_request is what pins that the branch validates at all: a
    # test that calls the parser itself stays green when the branch stops
    # using it.
    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
      server.instance_variable_set(:@use_sse, false)
    end

    def answer_with(payload)
      stub_request(:post, 'https://example.com/messages')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: JSON.generate({ 'jsonrpc' => '2.0', 'id' => 1 }.merge(payload)))
    end

    it 'rejects an unknown discriminator' do
      answer_with('result' => { 'resultType' => 'weird' })

      expect { server.rpc_request('vendor/thing') }
        .to raise_error(MCPClient::Errors::InvalidResultError, /weird/)
    end

    it 'accepts a complete result' do
      answer_with('result' => { 'resultType' => 'complete', 'ok' => true })

      expect(server.rpc_request('vendor/thing')).to eq({ 'resultType' => 'complete', 'ok' => true })
    end

    it 'raises the typed error a modern server answers with' do
      answer_with('error' => { 'code' => -32_021, 'message' => 'Missing capability',
                               'data' => { 'requiredCapabilities' => { 'roots' => {} } } })

      expect { server.rpc_request('vendor/thing') }
        .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) { |e|
              expect(e.required_capabilities).to eq({ 'roots' => {} })
            }
    end
  end

  describe "a host's conn.response :json middleware, on the success path too" do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/rpc' }

    # The README offers this middleware for the error path; a host who adds it
    # decodes every body, so the success path meets a Hash where it used to
    # meet a String. Reading the already-decoded body is what makes the offer
    # good for the whole exchange rather than half of it.
    def server_with_json_middleware(klass)
      server = klass.new(base_url: base_url, endpoint: endpoint, retries: 0,
                         faraday_config: ->(conn) { conn.response :json })
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server
    end

    it 'answers a decoded 200 body on ServerHTTP' do
      server = server_with_json_middleware(MCPClient::ServerHTTP)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => JSON.parse(request.body)['id'],
                              'result' => { 'ok' => true }) }
      end

      expect(server.rpc_request('vendor/thing')).to eq({ 'ok' => true })
    end

    it 'still raises the typed error a decoded 4xx body carries on ServerHTTP' do
      server = server_with_json_middleware(MCPClient::ServerHTTP)
      stub_request(:post, "#{base_url}#{endpoint}").to_return(
        status: 400, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                            'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                         'data' => { 'supported' => ['2026-07-28'] } })
      )

      expect { server.rpc_request('vendor/thing') }
        .to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) { |e|
              expect(e.supported).to eq(['2026-07-28'])
            }
    end
  end

  describe 'every page of a stdio list, not only the first' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 2) }

    before do
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
    end

    # The page loop asks the server again for every cursor it is handed; a
    # discriminator checked only on the first answer lets everything after it
    # through, and the pages are concatenated into one list the caller cannot
    # tell apart.
    def answer_pages(kind, first, second)
      pages = [first, second]
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response) do
        { 'jsonrpc' => '2.0', 'id' => 1, 'result' => pages.shift }
      end
      kind
    end

    it 'rejects an unknown discriminator on the second prompts/list page' do
      answer_pages('prompts',
                   { 'prompts' => [{ 'name' => 'p1', 'description' => 'd' }], 'nextCursor' => 'page-2' },
                   { 'resultType' => 'weird', 'prompts' => [] })

      expect { server.list_prompts }.to raise_error(MCPClient::Errors::InvalidResultError, /weird/)
    end

    it 'rejects an unknown discriminator on the second tools/list page' do
      answer_pages('tools',
                   { 'tools' => [{ 'name' => 't1', 'description' => 'd', 'inputSchema' => {} }],
                     'nextCursor' => 'page-2' },
                   { 'resultType' => 'weird', 'tools' => [] })

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError, /weird/)
    end

    it 'returns both pages when every one of them is well formed' do
      answer_pages('prompts',
                   { 'prompts' => [{ 'name' => 'p1', 'description' => 'd' }], 'nextCursor' => 'page-2' },
                   { 'prompts' => [{ 'name' => 'p2', 'description' => 'd' }] })

      expect(server.list_prompts.map(&:name)).to eq(%w[p1 p2])
    end
  end
end
