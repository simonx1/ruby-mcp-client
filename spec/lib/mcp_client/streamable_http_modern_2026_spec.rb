# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 Streamable HTTP (basic/transports/streamable-http):
# - no protocol-level session: no Mcp-Session-Id, no HTTP GET stream, no
#   DELETE, no Last-Event-ID resumability
# - every POST carries MCP-Protocol-Version (matching the body's _meta),
#   Mcp-Method and — for tools/call, resources/read, prompts/get — Mcp-Name,
#   Base64-sentinel encoded when the value is not header-safe
# - era detection: attempt a modern request first; a recognized modern
#   JSON-RPC error in a 400/404 body means modern, anything else falls back
#   to the initialize handshake
# - closing the response stream is the cancellation signal (no
#   notifications/cancelled); a broken stream loses the request and it is
#   re-issued with a new id
# - servers MUST NOT send JSON-RPC requests on response streams
HTTP_META_VERSION = 'io.modelcontextprotocol/protocolVersion'
HTTP_META_LOG_LEVEL = 'io.modelcontextprotocol/logLevel'

RSpec.describe 'MCP 2026-07-28 Streamable HTTP modern mode' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/mcp' }
  let(:url) { "#{base_url}#{endpoint}" }

  def discover_result(versions: ['2026-07-28'], capabilities: { 'tools' => {}, 'logging' => {} })
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => capabilities,
      '_meta' => { 'io.modelcontextprotocol/serverInfo' => { 'name' => 'modern', 'version' => '1' } },
      'ttlMs' => 0, 'cacheScope' => 'public' }
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

  def sse_body(*messages)
    messages.map { |m| "event: message\ndata: #{JSON.generate(m)}\n\n" }.join
  end

  # An SSE response stream that ends (with an event id) before any response.
  def truncated_stream
    "id: evt-1\n#{sse_body('jsonrpc' => '2.0', 'method' => 'notifications/progress', 'params' => {})}"
  end

  def legacy_init_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } }
  end

  # Answer each POST by JSON-RPC method, capturing the raw requests.
  def stub_modern_server(responders)
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers, body: body }
      # A modern tools/call fetches tools/list first (x-mcp-header extraction).
      responder = responders.fetch(body['method']) do
        body['method'] == 'tools/list' ? { 'tools' => [] } : raise("unexpected method #{body['method']}")
      end
      responder.respond_to?(:call) ? responder.call(body, request) : json_response(body['id'], responder)
    end
    requests
  end

  def stub_legacy_server(extra = {}, sse: true)
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers, body: body }
      case body['method']
      when 'server/discover'
        { status: 400, body: 'Bad Request: Server not initialized' }
      when 'initialize'
        if sse
          { status: 200, body: sse_body('jsonrpc' => '2.0', 'id' => body['id'], 'result' => legacy_init_result),
            headers: { 'Content-Type' => 'text/event-stream', 'Mcp-Session-Id' => 'sess-1' } }
        else
          json_response(body['id'], legacy_init_result).merge(headers: { 'Content-Type' => 'application/json',
                                                                         'Mcp-Session-Id' => 'sess-1' })
        end
      when 'notifications/initialized', 'notifications/cancelled'
        { status: 202, body: '' }
      else
        responder = extra.fetch(body['method']) { { 'tools' => [] } }
        json_response(body['id'], responder)
      end
    end
    stub_request(:get, url).to_return(status: 405, body: '')
    stub_request(:delete, url).to_return(status: 200, body: '')
    requests
  end

  describe MCPClient::ServerStreamableHTTP do
    let(:server) { described_class.new(base_url: base_url, endpoint: endpoint, retries: 0, read_timeout: 2) }

    after { server.cleanup }

    describe 'era detection' do
      it 'goes modern on a DiscoverResult and never opens a GET stream, initializes or terminates a session' do
        get_stub = stub_request(:get, url).to_return(status: 405, body: '')
        delete_stub = stub_request(:delete, url).to_return(status: 200, body: '')
        requests = stub_modern_server('server/discover' => discover_result, 'tools/list' => { 'tools' => [] })

        server.connect
        server.list_tools
        server.cleanup

        expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover tools/list])
        expect(server.protocol_era).to eq(:modern)
        expect(server.capabilities).to eq({ 'tools' => {}, 'logging' => {} })
        expect(server.server_info).to eq({ 'name' => 'modern', 'version' => '1' })
        expect(get_stub).not_to have_been_requested
        expect(delete_stub).not_to have_been_requested
      end

      it 'sends the required request headers and body metadata on the probe and every request' do
        requests = stub_modern_server('server/discover' => discover_result, 'tools/list' => { 'tools' => [] })

        server.list_tools

        requests.each do |r|
          expect(r[:headers]['Mcp-Protocol-Version']).to eq('2026-07-28')
          expect(r[:headers]['Mcp-Method']).to eq(r[:body]['method'])
          expect(r[:headers]['Accept']).to include('application/json').and include('text/event-stream')
          expect(r[:headers]).not_to have_key('Mcp-Session-Id')
          expect(r[:headers]).not_to have_key('Last-Event-Id')
          expect(r[:body]['params']['_meta'][HTTP_META_VERSION]).to eq('2026-07-28')
        end
      end

      it 'retries the probe with an advertised version after a 400 UnsupportedProtocolVersionError' do
        stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
        stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
        requests = stub_modern_server(
          'server/discover' => lambda do |body, _req|
            if body['params']['_meta'][HTTP_META_VERSION] == '2027-01-01'
              error_response(400, -32_022, 'Unsupported protocol version',
                             { 'supported' => ['2026-07-28'], 'requested' => '2027-01-01' })
            else
              json_response(body['id'], discover_result)
            end
          end
        )

        server.connect

        expect(requests.map { |r| r[:headers]['Mcp-Protocol-Version'] }).to eq(%w[2027-01-01 2026-07-28])
        expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover server/discover])
        expect(server.protocol_version).to eq('2026-07-28')
      end

      it 'treats a 400 HeaderMismatch as a modern server and does not fall back' do
        requests = stub_modern_server(
          'server/discover' => ->(_b, _r) { error_response(400, -32_020, 'Header mismatch') }
        )

        expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Header mismatch/)
        expect(requests.map { |r| r[:body]['method'] }).to eq(['server/discover'])
      end

      it 'falls back to initialize on a bare -32021 without the schema-mandated data (not a modern error)' do
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << body['method']
          case body['method']
          when 'server/discover' then error_response(400, -32_021, 'blocked')
          when 'initialize' then json_response(body['id'], legacy_init_result)
          else { status: 202, body: '' }
          end
        end
        stub_request(:get, url).to_return(status: 405, body: '')

        server.connect

        expect(requests).to eq(%w[server/discover initialize notifications/initialized])
        expect(server.protocol_era).to eq(:legacy)
      end

      it 'treats a 400 MissingRequiredClientCapability as a modern server and does not fall back' do
        requests = stub_modern_server(
          'server/discover' => lambda do |_b, _r|
            error_response(400, -32_021, 'Missing capability', { 'requiredCapabilities' => { 'elicitation' => {} } })
          end
        )

        expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Missing capability/)
        expect(requests.map { |r| r[:body]['method'] }).to eq(['server/discover'])
      end

      it 'treats a 404 with a -32601 body as a modern server lacking server/discover' do
        requests = stub_modern_server(
          'server/discover' => ->(_b, _r) { error_response(404, -32_601, 'Method not found') },
          'tools/list' => { 'tools' => [] }
        )

        server.list_tools

        expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover tools/list])
        expect(server.protocol_era).to eq(:modern)
        expect(server.capabilities).to eq({})
      end

      it 'falls back to the initialize handshake on a 400 without a modern error body' do
        requests = stub_legacy_server

        server.list_tools

        expect(requests.map { |r| r[:body]['method'] })
          .to eq(%w[server/discover initialize notifications/initialized tools/list])
        expect(server.protocol_era).to eq(:legacy)
        expect(server.protocol_version).to eq('2025-11-25')
        expect(requests.last[:headers]['Mcp-Session-Id']).to eq('sess-1')
        expect(requests.last[:headers]).not_to have_key('Mcp-Method')
        expect(requests.last[:body]['params']).not_to have_key('_meta')
      end

      it 'falls back to initialize on a 404 without a JSON-RPC body and on a 405' do
        [404, 405].each do |status|
          fresh = described_class.new(base_url: base_url, endpoint: endpoint, retries: 0)
          requests = []
          stub_request(:post, url).to_return do |request|
            body = JSON.parse(request.body)
            requests << body['method']
            case body['method']
            when 'server/discover' then { status: status, body: '' }
            when 'initialize'
              json_response(body['id'], legacy_init_result)
            else { status: 202, body: '' }
            end
          end
          stub_request(:get, url).to_return(status: 405, body: '')

          fresh.connect
          expect(requests).to eq(%w[server/discover initialize notifications/initialized])
          expect(fresh.protocol_era).to eq(:legacy)
          fresh.cleanup
        end
      end

      it 'falls back to initialize when a legacy server answers 200 with a non-modern JSON-RPC error' do
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << body['method']
          case body['method']
          when 'server/discover' then error_response(200, -32_601, 'Method not found')
          when 'initialize' then json_response(body['id'], legacy_init_result)
          else { status: 202, body: '' }
          end
        end
        stub_request(:get, url).to_return(status: 405, body: '')

        server.connect

        expect(requests).to eq(%w[server/discover initialize notifications/initialized])
        expect(server.protocol_era).to eq(:legacy)
      end

      it 'surfaces authorization failures on the probe instead of falling back' do
        requests = stub_modern_server('server/discover' => ->(_b, _r) { { status: 401, body: '' } })

        expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed/)
        expect(requests.size).to eq(1)
      end

      it 'surfaces a 5xx on the probe instead of falling back' do
        requests = stub_modern_server('server/discover' => ->(_b, _r) { { status: 503, body: '' } })

        expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /503/)
        expect(requests.size).to eq(1)
      end

      it 'skips the probe with protocol: :legacy' do
        server = described_class.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: :legacy)
        requests = stub_legacy_server

        server.connect

        expect(requests.map { |r| r[:body]['method'] }).to eq(%w[initialize notifications/initialized])
        server.cleanup
      end

      it 'refuses to fall back with protocol: :modern' do
        server = described_class.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: :modern)
        requests = stub_legacy_server

        expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /legacy|initialize/i)
        expect(requests.map { |r| r[:body]['method'] }).to eq(['server/discover'])
      end

      it 'caches the era: a later reconnect does not re-probe a known legacy server' do
        requests = stub_legacy_server

        server.connect
        server.cleanup
        server.connect

        expect(requests.map { |r| r[:body]['method'] }.count('server/discover')).to eq(1)
        expect(requests.map { |r| r[:body]['method'] }.count('initialize')).to eq(2)
      end
    end

    describe 'request metadata headers' do
      before { stub_request(:get, url).to_return(status: 405, body: '') }

      it 'mirrors params.name into Mcp-Name for tools/call and prompts/get, and params.uri for resources/read' do
        requests = stub_modern_server(
          'server/discover' => discover_result,
          'tools/call' => { 'content' => [] },
          'prompts/get' => { 'messages' => [] },
          'resources/read' => { 'contents' => [] }
        )

        server.call_tool('get_weather', { 'city' => 'Oslo' })
        server.get_prompt('greeting', {})
        server.read_resource('file:///projects/app/config.json')

        by_method = requests.to_h { |r| [r[:body]['method'], r[:headers]] }
        expect(by_method['tools/call']['Mcp-Name']).to eq('get_weather')
        expect(by_method['prompts/get']['Mcp-Name']).to eq('greeting')
        expect(by_method['resources/read']['Mcp-Name']).to eq('file:///projects/app/config.json')
        expect(by_method['server/discover']).not_to have_key('Mcp-Name')
      end

      it 'Base64-encodes an Mcp-Name that is not header-safe' do
        requests = stub_modern_server('server/discover' => discover_result, 'tools/call' => { 'content' => [] })

        server.call_tool('outil_été', {})
        server.call_tool(' padded ', {})
        server.call_tool('=?base64?literal?=', {})

        names = requests.select { |r| r[:body]['method'] == 'tools/call' }.map { |r| r[:headers]['Mcp-Name'] }
        expect(names[0]).to eq("=?base64?#{Base64.strict_encode64('outil_été')}?=")
        expect(names[1]).to eq("=?base64?#{Base64.strict_encode64(' padded ')}?=")
        expect(names[2]).to eq("=?base64?#{Base64.strict_encode64('=?base64?literal?=')}?=")
      end

      it 'keeps the MCP-Protocol-Version header equal to the body after an inline version switch' do
        stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
        stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
        requests = stub_modern_server(
          'server/discover' => discover_result(versions: ['2027-01-01']),
          'tools/list' => lambda do |body, _req|
            if body['params']['_meta'][HTTP_META_VERSION] == '2027-01-01'
              error_response(400, -32_022, 'Unsupported protocol version',
                             { 'supported' => ['2026-07-28'], 'requested' => '2027-01-01' })
            else
              json_response(body['id'], { 'tools' => [] })
            end
          end
        )

        server.list_tools

        lists = requests.select { |r| r[:body]['method'] == 'tools/list' }
        expect(lists.map { |r| r[:headers]['Mcp-Protocol-Version'] }).to eq(%w[2027-01-01 2026-07-28])
        expect(lists.map { |r| r[:body]['params']['_meta'][HTTP_META_VERSION] }).to eq(%w[2027-01-01 2026-07-28])
        expect(lists[0][:body]['id']).not_to eq(lists[1][:body]['id'])
      end
    end

    describe 'removed methods' do
      before { stub_request(:get, url).to_return(status: 405, body: '') }

      it 'maps ping to server/discover' do
        requests = stub_modern_server('server/discover' => discover_result)

        server.connect
        result = server.ping

        expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover server/discover])
        expect(result['supportedVersions']).to eq(['2026-07-28'])
      end

      it 'sets the log level per request instead of calling logging/setLevel' do
        requests = stub_modern_server('server/discover' => discover_result, 'tools/list' => { 'tools' => [] })

        server.log_level = 'warning'
        server.list_tools

        expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover tools/list])
        expect(requests.last[:body]['params']['_meta'][HTTP_META_LOG_LEVEL]).to eq('warning')
      end

      it 'does not send notifications/cancelled on a timeout: closing the stream is the cancellation' do
        requests = stub_modern_server(
          'server/discover' => discover_result,
          'tools/list' => ->(_b, _r) { raise Faraday::TimeoutError, 'execution expired' }
        )

        expect { server.list_tools }.to raise_error(MCPClient::Errors::RequestTimeoutError)
        expect(requests.map { |r| r[:body]['method'] }).not_to include('notifications/cancelled')
      end
    end

    describe 'response streams' do
      before { stub_request(:get, url).to_return(status: 405, body: '') }

      it 'delivers request-scoped notifications from the SSE response stream before the response' do
        notifications = []
        server.on_notification { |method, params| notifications << [method, params] }
        stub_modern_server(
          'server/discover' => discover_result,
          'tools/call' => lambda do |body, _req|
            { status: 200,
              body: sse_body({ 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
                               'params' => { 'progressToken' => 'p', 'progress' => 1 } },
                             { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] } }),
              headers: { 'Content-Type' => 'text/event-stream' } }
          end
        )

        result = server.call_tool('t', {})

        expect(result).to eq({ 'content' => [] })
        expect(notifications.map(&:first)).to eq(['notifications/progress'])
      end

      it 'ignores a server-initiated JSON-RPC request on a response stream instead of POSTing a reply' do
        requests = stub_modern_server(
          'server/discover' => discover_result,
          'tools/call' => lambda do |body, _req|
            { status: 200,
              body: sse_body({ 'jsonrpc' => '2.0', 'id' => 'srv-1', 'method' => 'elicitation/create',
                               'params' => { 'message' => 'x' } },
                             { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] } }),
              headers: { 'Content-Type' => 'text/event-stream' } }
          end
        )
        elicitation_calls = 0
        server.on_elicitation_request { |_id, _params| elicitation_calls += 1 }

        server.call_tool('t', {})
        sleep 0.05

        expect(elicitation_calls).to eq(0)
        expect(requests.none? { |r| r[:body]['id'] == 'srv-1' && r[:body].key?('result') }).to be(true)
      end

      it 'ignores SSE comment keep-alive lines' do
        stub_modern_server(
          'server/discover' => discover_result,
          'tools/list' => lambda do |body, _req|
            { status: 200,
              body: ":\r\n\r\n: keep-alive\n\n#{sse_body('jsonrpc' => '2.0', 'id' => body['id'],
                                                         'result' => { 'tools' => [] })}",
              headers: { 'Content-Type' => 'text/event-stream' } }
          end
        )

        expect(server.list_tools).to eq([])
      end

      it 're-issues an idempotent request with a new id when the stream closes without a response' do
        requests = stub_modern_server(
          'server/discover' => discover_result,
          'tools/list' => lambda do |body, _req|
            if requests.one? { |r| r[:body]['method'] == 'tools/list' }
              { status: 200, body: truncated_stream, headers: { 'Content-Type' => 'text/event-stream' } }
            else
              json_response(body['id'], { 'tools' => [] })
            end
          end
        )
        get_stub = stub_request(:get, url).to_return(status: 405, body: '')

        expect(server.list_tools).to eq([])

        lists = requests.select { |r| r[:body]['method'] == 'tools/list' }
        expect(lists.size).to eq(2)
        expect(lists[0][:body]['id']).not_to eq(lists[1][:body]['id'])
        expect(lists.map { |r| r[:headers]['Last-Event-Id'] }).to all(be_nil)
        expect(get_stub).not_to have_been_requested
      end

      # Changelog major change 9 states the re-issue rule with no exception
      # for tools/call, and this revision makes the broken stream itself the
      # cancellation signal the server MUST act on, so the replacement
      # request is what the protocol expects. It happens exactly once:
      # with_retry never retries a non-idempotent method.
      it 're-issues tools/call once when the stream closes without a response' do
        requests = stub_modern_server(
          'server/discover' => discover_result,
          'tools/call' => lambda do |_body, _req|
            { status: 200, body: truncated_stream, headers: { 'Content-Type' => 'text/event-stream' } }
          end
        )

        expect { server.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::MCPError, /stream closed before delivering the response/i)
        expect(requests.count { |r| r[:body]['method'] == 'tools/call' }).to eq(2)
        ids = requests.select { |r| r[:body]['method'] == 'tools/call' }.map { |r| r[:body]['id'] }
        expect(ids.uniq.size).to eq(2)
      end
    end
  end

  describe MCPClient::ServerHTTP do
    let(:server) { described_class.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    after { server.cleanup }

    it 'goes modern on a DiscoverResult with the required headers and no initialize' do
      requests = stub_modern_server('server/discover' => discover_result, 'tools/call' => { 'content' => [] })

      server.call_tool('echo', { 'x' => 1 })

      expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover tools/list tools/call])
      expect(server.protocol_era).to eq(:modern)
      expect(requests.last[:headers]['Mcp-Protocol-Version']).to eq('2026-07-28')
      expect(requests.last[:headers]['Mcp-Method']).to eq('tools/call')
      expect(requests.last[:headers]['Mcp-Name']).to eq('echo')
      expect(requests.last[:headers]).not_to have_key('Mcp-Session-Id')
      expect(requests.last[:body]['params']['_meta'][HTTP_META_VERSION]).to eq('2026-07-28')
    end

    it 'falls back to initialize for a legacy server' do
      requests = stub_legacy_server(sse: false)

      server.list_tools

      expect(requests.map { |r| r[:body]['method'] })
        .to eq(%w[server/discover initialize notifications/initialized tools/list])
      expect(server.protocol_era).to eq(:legacy)
    end

    it 'maps ping to server/discover and the log level to _meta' do
      requests = stub_modern_server('server/discover' => discover_result, 'tools/list' => { 'tools' => [] })

      server.connect
      server.ping
      server.log_level = 'error'
      server.list_tools

      expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover server/discover tools/list])
      expect(requests.last[:body]['params']['_meta'][HTTP_META_LOG_LEVEL]).to eq('error')
    end
  end

  describe 'configuration' do
    it 'accepts protocol and discover_timeout on the HTTP config builders and factory' do
      %i[http_config streamable_http_config].each do |builder|
        config = MCPClient.public_send(builder, base_url: 'https://example.com', protocol: :legacy, discover_timeout: 3)
        expect(config[:protocol]).to eq(:legacy)
        expect(config[:discover_timeout]).to eq(3)
        server = MCPClient::ServerFactory.create(config)
        expect(server.protocol_mode).to eq(:legacy)
        expect(server.discover_timeout).to eq(3)
      end
    end

    it 'defaults the HTTP protocol mode to :auto' do
      server = MCPClient::ServerFactory.create(MCPClient.streamable_http_config(base_url: 'https://example.com'))
      expect(server.protocol_mode).to eq(:auto)
    end

    it 'rejects an unknown protocol mode' do
      expect { MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', protocol: :nope) }
        .to raise_error(ArgumentError, /protocol/)
      expect { MCPClient::ServerHTTP.new(base_url: 'https://example.com', protocol: :nope) }
        .to raise_error(ArgumentError, /protocol/)
    end
  end

  describe 'header value encoding' do
    let(:transport) do
      Class.new do
        include MCPClient::JsonRpcCommon

        def initialize
          @logger = Logger.new(StringIO.new)
        end
      end.new
    end

    it 'passes plain visible-ASCII values through' do
      expect(transport.encode_header_value('us-west1')).to eq('us-west1')
      expect(transport.encode_header_value('a b')).to eq('a b')
      expect(transport.encode_header_value("a\tb")).to eq("a\tb")
    end

    it 'encodes values with non-ASCII, control characters or surrounding whitespace' do
      expect(transport.encode_header_value('Hello, 世界')).to eq('=?base64?SGVsbG8sIOS4lueVjA==?=')
      expect(transport.encode_header_value(' padded ')).to eq('=?base64?IHBhZGRlZCA=?=')
      expect(transport.encode_header_value("line1\nline2")).to eq('=?base64?bGluZTEKbGluZTI=?=')
      expect(transport.encode_header_value('')).to eq('=?base64??=')
    end

    it 'encodes a plain value that itself matches the sentinel pattern' do
      expect(transport.encode_header_value('=?base64?literal?=')).to eq('=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=')
    end

    it 'converts integers and booleans per the spec' do
      expect(transport.encode_header_value(42)).to eq('42')
      expect(transport.encode_header_value(-7)).to eq('-7')
      expect(transport.encode_header_value(true)).to eq('true')
      expect(transport.encode_header_value(false)).to eq('false')
    end
  end
end

# Review round 2 (codex): every server/discover answer is applied; removed
# notifications are suppressed once the era is negotiated; a bare -32022
# without data and a 2xx non-DiscoverResult are legacy answers; tasks/result
# routes on taskId too.
RSpec.describe 'MCP 2026-07-28 Streamable HTTP modern mode — review follow-ups' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/mcp' }
  let(:url) { "#{base_url}#{endpoint}" }
  let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

  after { server.cleanup }

  def discover_result(capabilities: { 'tools' => {} })
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => capabilities }
  end

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def legacy_init_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => {}, 'serverInfo' => { 'name' => 'l', 'version' => '1' } }
  end

  def stub(responders)
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers, body: body }
      responder = responders.fetch(body['method']) { { status: 202, body: '' } }
      responder.respond_to?(:call) ? responder.call(body, requests) : json_response(body['id'], responder)
    end
    stub_request(:get, url).to_return(status: 405, body: '')
    requests
  end

  it 'applies every server/discover answer, including the heartbeat' do
    stub('server/discover' => lambda do |body, requests|
      probes = requests.count { |r| r[:body]['method'] == 'server/discover' }
      caps = probes > 1 ? { 'tools' => {}, 'prompts' => {} } : { 'tools' => {} }
      json_response(body['id'], discover_result(capabilities: caps))
    end)

    server.connect
    server.ping

    expect(server.capabilities).to eq({ 'tools' => {}, 'prompts' => {} })
  end

  it 'validates a later server/discover answer' do
    stub('server/discover' => lambda do |body, requests|
      if requests.one? { |r| r[:body]['method'] == 'server/discover' }
        json_response(body['id'], discover_result)
      else
        json_response(body['id'], { 'resultType' => 'complete', 'capabilities' => {} })
      end
    end)

    server.connect
    expect { server.ping }.to raise_error(MCPClient::Errors::ConnectionError, /supportedVersions/)
  end

  it 'never sends notifications/roots/list_changed to a modern server, even when the notify negotiates the era' do
    requests = stub('server/discover' => discover_result)

    server.rpc_notify('notifications/roots/list_changed', {})

    expect(requests.map { |r| r[:body]['method'] }).to eq(['server/discover'])
  end

  it 'falls back to initialize on a bare -32022 without the schema-mandated data' do
    requests = stub(
      'server/discover' => lambda do |_b, _r|
        { status: 400, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => { 'code' => -32_022, 'message' => 'blocked' }) }
      end,
      'initialize' => legacy_init_result
    )

    server.connect

    expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover initialize notifications/initialized])
    expect(server.protocol_era).to eq(:legacy)
  end

  it 'falls back to initialize on a 2xx scalar or array result' do
    [[], 'ok', nil].each do |answer|
      fresh = MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0)
      requests = stub('server/discover' => answer, 'initialize' => legacy_init_result)

      fresh.connect

      expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover initialize notifications/initialized])
      expect(fresh.protocol_era).to eq(:legacy)
      fresh.cleanup
    end
  end

  it 'does not fall back when the retried probe fails after a well-formed -32022' do
    stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
    stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
    requests = stub(
      'server/discover' => lambda do |body, _r|
        if body['params']['_meta']['io.modelcontextprotocol/protocolVersion'] == '2027-01-01'
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_022, 'message' => 'Unsupported',
                                             'data' => { 'supported' => ['2026-07-28'],
                                                         'requested' => '2027-01-01' } }) }
        else
          { status: 500, body: '' }
        end
      end,
      'initialize' => legacy_init_result
    )

    expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError)
    expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover server/discover])
  end

  it 'routes tasks/result on taskId like the other task methods' do
    transport = Class.new do
      include MCPClient::JsonRpcCommon

      attr_accessor :protocol_version

      def initialize
        @logger = Logger.new(StringIO.new)
        @protocol_version = '2026-07-28'
      end
    end.new
    request = transport.build_jsonrpc_request('tasks/result', { 'taskId' => 'task-1' }, 1)
    expect(transport.modern_request_headers(request)['Mcp-Name']).to eq('task-1')
  end
end

# Review round 2 (grok): the plain HTTP transport must advertise and accept
# both response content types (the client MUST support application/json
# and text/event-stream), and negotiation must be serialized.
RSpec.describe 'MCP 2026-07-28 modern mode — plain HTTP transport and concurrency' do
  let(:url) { 'https://example.com/mcp' }

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
  end

  def sse(*messages)
    messages.map { |m| "event: message\ndata: #{JSON.generate(m)}\n\n" }.join
  end

  it 'ServerHTTP sends Accept for both JSON and SSE and parses an SSE-framed DiscoverResult and tool result' do
    server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    notifications = []
    server.on_notification { |method, params| notifications << [method, params] }
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers, body: body }
      case body['method']
      when 'server/discover'
        { status: 200, body: sse('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result),
          headers: { 'Content-Type' => 'text/event-stream' } }
      when 'tools/call'
        { status: 200,
          body: sse({ 'jsonrpc' => '2.0', 'method' => 'notifications/progress', 'params' => { 'progress' => 1 } },
                    { 'jsonrpc' => '2.0', 'id' => 999, 'result' => { 'stale' => true } },
                    { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] } }),
          headers: { 'Content-Type' => 'text/event-stream' } }
      else
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'tools' => [] }),
          headers: { 'Content-Type' => 'application/json' } }
      end
    end

    expect(server.call_tool('t', {})).to eq({ 'content' => [] })
    expect(server.protocol_era).to eq(:modern)
    expect(requests.first[:headers]['Accept']).to include('application/json').and include('text/event-stream')
    # The whole payload, not just the method name: a dispatcher that dropped
    # params would still satisfy a name-only assertion.
    expect(notifications).to eq([['notifications/progress', { 'progress' => 1 }]])
    server.cleanup
  end

  it 'ServerHTTP re-issues once and then surfaces a stream that never carries the response' do
    server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'server/discover'
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result),
          headers: { 'Content-Type' => 'application/json' } }
      else
        lists += 1
        { status: 200, body: sse('jsonrpc' => '2.0', 'method' => 'notifications/progress', 'params' => {}),
          headers: { 'Content-Type' => 'text/event-stream' } }
      end
    end

    expect { server.list_tools }
      .to raise_error(MCPClient::Errors::ResponseStreamClosedError, /closed before delivering the response/)
    expect(lists).to eq(2)
    server.cleanup
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    it "#{klass} serializes concurrent first requests so the probe runs once" do
      server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      probes = 0
      mutex = Mutex.new
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'server/discover'
          mutex.synchronize { probes += 1 }
          sleep 0.05
          result = discover_result
        else
          result = { 'tools' => [] }
        end
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end
      stub_request(:get, url).to_return(status: 405, body: '')

      Array.new(4) { Thread.new { server.list_tools } }.each(&:join)

      expect(probes).to eq(1)
      expect(server.protocol_era).to eq(:modern)
      server.cleanup
    end

    it "#{klass} does not let a stale reconnect tear down a connection another caller just made" do
      server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      probes = 0
      mutex = Mutex.new
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        mutex.synchronize { probes += 1 } if body['method'] == 'server/discover'
        result = body['method'] == 'server/discover' ? discover_result : { 'tools' => [] }
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end
      stub_request(:get, url).to_return(status: 405, body: '')

      server.connect
      server.instance_variable_set(:@connection_established, false)

      # Hold the first caller between "the connection is down" and its
      # teardown, so the second caller can reconnect underneath it. Resuming
      # the first must not undo that reconnect and probe all over again.
      at_teardown = Queue.new
      resume = Queue.new
      first = true
      allow(server).to receive(:cleanup).and_wrap_original do |original|
        if first
          first = false
          at_teardown << :poised
          resume.pop
        end
        original.call
      end

      stale = Thread.new { server.list_tools }
      at_teardown.pop
      fresh = Thread.new { server.list_tools }
      sleep 0.1
      resume << :go
      [stale, fresh].each(&:join)

      expect(probes).to eq(2)
      expect(server.protocol_era).to eq(:modern)
      server.cleanup
    end
  end
end

# Review round 3 (codex): notifications carry the per-request _meta too (the
# MCP-Protocol-Version header must match the body); every response stream
# that ends without the response is re-issued, not only one that carried an
# event id; a DiscoverResult with no mutual version leaves no tentative
# version behind.
RSpec.describe 'MCP 2026-07-28 Streamable HTTP modern mode — round 3' do
  let(:url) { 'https://example.com/mcp' }

  def discover_result(versions: ['2026-07-28'])
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => { 'tools' => {} } }
  end

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  it 'sends the protocol version in a modern notification body, matching the header' do
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers, body: body }
      body['method'] == 'server/discover' ? json_response(body['id'], discover_result) : { status: 202, body: '' }
    end

    server.rpc_notify('com.example/custom', { 'x' => 1 })

    notification = requests.find { |r| r[:body]['method'] == 'com.example/custom' }
    expect(notification[:body]['params']['_meta']['io.modelcontextprotocol/protocolVersion']).to eq('2026-07-28')
    expect(notification[:headers]['Mcp-Protocol-Version']).to eq('2026-07-28')
    expect(notification[:body]['params']['x']).to eq(1)
    server.cleanup
  end

  [MCPClient::ServerStreamableHTTP, MCPClient::ServerHTTP].each do |klass|
    it "#{klass} re-issues an idempotent request whose SSE response stream ended empty" do
      server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'tools/list'
          lists += 1
          if lists == 1
            { status: 200, body: ": keep-alive\n\n", headers: { 'Content-Type' => 'text/event-stream' } }
          else
            json_response(body['id'], { 'tools' => [] })
          end
        end
      end

      expect(server.list_tools).to eq([])
      expect(lists).to eq(2)
      server.cleanup
    end
  end

  it 'leaves no tentative version behind when no advertised version is mutual' do
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      json_response(body['id'], discover_result(versions: ['2099-01-01']))
    end

    expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /2099-01-01/)
    expect(server.protocol_version).to be_nil
    expect(server.protocol_era).to be_nil
  end
end

# Review round 4 (codex): the plain HTTP transport's new SSE support must not
# swallow a legacy server's requests (2025-11-25 allows them on the response
# stream, and a ping MUST be answered promptly), and neither transport may
# complete a request with a response that answers a different one.
RSpec.describe 'MCP 2026-07-28 modern mode — SSE dispatch on a response stream' do
  let(:url) { 'https://example.com/mcp' }

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
  end

  def legacy_init_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } }
  end

  def sse(*messages)
    messages.map { |m| "event: message\ndata: #{JSON.generate(m)}\n\n" }.join
  end

  def sse_response(*messages)
    { status: 200, body: sse(*messages), headers: { 'Content-Type' => 'text/event-stream' } }
  end

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  # Answer POSTs from `responders` (keyed by JSON-RPC method) and record every
  # message the client sent — including any response it POSTs back to the
  # server, which carries no method at all.
  def stub_posts(responders)
    sent = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      sent << body
      responder = responders[body['method']]
      responder ? responder.call(body) : { status: 202, body: '' }
    end
    sent
  end

  def legacy_handshake(extra = {})
    {
      'server/discover' => ->(_body) { { status: 400, body: 'Bad Request' } },
      'initialize' => ->(body) { json_response(body['id'], legacy_init_result) }
    }.merge(extra)
  end

  describe MCPClient::ServerHTTP do
    let(:server) { described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

    after { server.cleanup }

    it 'answers a legacy server ping carried on an SSE response stream' do
      sent = stub_posts(legacy_handshake('tools/list' => lambda do |body|
        sse_response({ 'jsonrpc' => '2.0', 'id' => 'ping-1', 'method' => 'ping' },
                     { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'tools' => [] } })
      end))

      expect(server.list_tools).to eq([])

      # A server that pings and never hears back may abandon the session.
      pong = sent.find { |m| m['id'] == 'ping-1' }
      expect(pong).to include('jsonrpc' => '2.0', 'result' => {})
    end

    it 'answers a legacy server request it cannot serve with method not found' do
      sent = stub_posts(legacy_handshake('tools/list' => lambda do |body|
        sse_response({ 'jsonrpc' => '2.0', 'id' => 'req-1', 'method' => 'sampling/createMessage', 'params' => {} },
                     { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'tools' => [] } })
      end))

      expect(server.list_tools).to eq([])

      answer = sent.find { |m| m['id'] == 'req-1' }
      expect(answer.dig('error', 'code')).to eq(-32_601)
    end

    it 'drops a server-initiated request on a modern response stream without answering it' do
      sent = stub_posts(
        'server/discover' => ->(body) { json_response(body['id'], discover_result) },
        'tools/list' => lambda do |body|
          sse_response({ 'jsonrpc' => '2.0', 'id' => 'ping-1', 'method' => 'ping' },
                       { 'jsonrpc' => '2.0', 'id' => 'req-1', 'method' => 'com.example/unknown' },
                       { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'tools' => [] } })
        end
      )

      expect(server.list_tools).to eq([])

      # 2026-07-28: the server MUST NOT send independent requests on this
      # stream, and clients MUST NOT POST responses to it.
      expect(sent.map { |m| m['method'] }).to eq(%w[server/discover tools/list])
    end
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    describe klass do
      let(:server) { klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

      after { server.cleanup }

      it 'treats a stream carrying only another request\'s response as a lost stream' do
        lists = 0
        stub_posts(
          'server/discover' => ->(body) { json_response(body['id'], discover_result) },
          'tools/list' => lambda do |body|
            lists += 1
            if lists == 1
              sse_response('jsonrpc' => '2.0', 'id' => 999,
                           'result' => { 'tools' => [{ 'name' => 'stale', 'inputSchema' => {} }] })
            else
              json_response(body['id'], { 'tools' => [] })
            end
          end
        )

        # No response to this request arrived, so the stream was lost: the
        # request is re-issued rather than completed with a stale result.
        expect(server.list_tools).to eq([])
        expect(lists).to eq(2)
      end
    end
  end
end

# Review round 4 (codex): the "no protocol-level session" claim was only
# tested against servers that never offered one.
RSpec.describe 'MCP 2026-07-28 modern mode — a server that offers a session anyway' do
  let(:url) { 'https://example.com/mcp' }

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    it "#{klass} neither retains nor echoes an Mcp-Session-Id from a modern server" do
      server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << request.headers
        result = case body['method']
                 when 'server/discover' then discover_result
                 when 'tools/call' then { 'content' => [] }
                 # Bounded, so the call reuses the list instead of reading it
                 # again to derive its Mcp-Param-* headers: the three requests
                 # below are the session layer's, not the cache's.
                 else { 'tools' => [], 'ttlMs' => 60_000 }
                 end
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json', 'Mcp-Session-Id' => 'sess-modern' } }
      end
      delete_stub = stub_request(:delete, url).to_return(status: 200, body: '')

      server.list_tools
      server.call_tool('t', {})
      server.cleanup

      # 2026-07-28 removed the session layer: an assigned id must be ignored,
      # never echoed on a later request, and never DELETEd at teardown.
      expect(requests.size).to eq(3)
      expect(requests).to all(satisfy { |h| !h.key?('Mcp-Session-Id') })
      expect(server.instance_variable_get(:@session_id)).to be_nil
      expect(delete_stub).not_to have_been_requested
    end

    it "#{klass} suppresses the session header even if a session id is somehow held" do
      server = klass.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << request.headers
        result = body['method'] == 'server/discover' ? discover_result : { 'content' => [] }
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end

      server.connect
      # The subclasses return early from apply_request_headers when modern.
      # Nothing on a modern connection assigns a session id, so plant one to
      # exercise that guard rather than trusting it by inspection.
      server.instance_variable_set(:@session_id, 'sess-planted')

      server.call_tool('t', {})

      expect(requests.last).not_to have_key('Mcp-Session-Id')
      server.cleanup
    end
  end
end
