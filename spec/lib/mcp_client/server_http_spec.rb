# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'faraday'

RSpec.describe MCPClient::ServerHTTP do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }
  let(:headers) { { 'Authorization' => 'Bearer token123' } }
  let(:server) do
    described_class.new(
      base_url: base_url,
      endpoint: endpoint,
      headers: headers,
      read_timeout: 10,
      retries: 2,
      retry_backoff: 0.1,
      name: 'test-server',
      logger: Logger.new(StringIO.new)
    )
  end

  describe '#initialize' do
    it 'sets the base URL correctly' do
      expect(server.base_url).to eq(base_url)
    end

    it 'sets the endpoint correctly' do
      expect(server.endpoint).to eq(endpoint)
    end

    it 'strips trailing slashes from base URL' do
      server_with_slash = described_class.new(base_url: 'https://example.com/')
      expect(server_with_slash.base_url).to eq('https://example.com')
    end

    it 'sets default endpoint when not provided' do
      server_default = described_class.new(base_url: base_url)
      expect(server_default.endpoint).to eq('/rpc')
    end

    it 'extracts endpoint from base_url when path is provided' do
      server_with_path = described_class.new(base_url: 'https://example.com/mcp')
      expect(server_with_path.base_url).to eq('https://example.com')
      expect(server_with_path.endpoint).to eq('/mcp')
    end

    it 'uses HTTP protocol version for initialization' do
      # Mock the initialize request to verify protocol version
      init_request_body = nil
      stub_request(:post, "#{base_url}#{endpoint}")
        .with do |request|
          init_request_body = JSON.parse(request.body)
          init_request_body['method'] == 'initialize'
        end
        .to_return(
          status: 200,
          body: JSON.generate({
                                jsonrpc: '2.0',
                                id: 1,
                                result: {
                                  protocolVersion: MCPClient::PROTOCOL_VERSION,
                                  capabilities: {},
                                  serverInfo: { name: 'test-server', version: '1.0.0' }
                                }
                              }),
          headers: { 'Content-Type' => 'application/json' }
        )

      server.connect

      expect(init_request_body['params']['protocolVersion']).to eq(MCPClient::PROTOCOL_VERSION)
      expect(init_request_body['params']['protocolVersion']).to eq('2025-11-25')
    end

    it 'handles base_url with path and explicit endpoint' do
      server_explicit = described_class.new(
        base_url: 'https://example.com/api',
        endpoint: '/custom'
      )
      expect(server_explicit.base_url).to eq('https://example.com')
      expect(server_explicit.endpoint).to eq('/custom')
    end

    it 'merges custom headers with default headers' do
      actual_headers = server.instance_variable_get(:@headers)
      expect(actual_headers).to include('Content-Type' => 'application/json')
      expect(actual_headers).to include('Accept' => 'application/json')
      expect(actual_headers).to include('Authorization' => 'Bearer token123')
    end

    it 'sets default values correctly' do
      default_server = described_class.new(base_url: base_url)
      expect(default_server.instance_variable_get(:@read_timeout)).to eq(30)
      expect(default_server.instance_variable_get(:@max_retries)).to eq(3)
      expect(default_server.instance_variable_get(:@retry_backoff)).to eq(1)
    end
  end

  describe '#connect' do
    let(:initialize_response) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'test-server', version: '1.0.0' }
        }
      }
    end

    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(
          headers: {
            'Content-Type' => 'application/json',
            'Accept' => 'application/json',
            'Authorization' => 'Bearer token123'
          },
          body: hash_including(method: 'initialize')
        )
        .to_return(
          status: 200,
          body: initialize_response.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'successfully connects and initializes' do
      expect(server.connect).to be true
      expect(server.server_info).to eq({ 'name' => 'test-server', 'version' => '1.0.0' })
      expect(server.capabilities).to eq({ 'tools' => {} })
    end

    it 'sets connection state correctly' do
      server.connect
      expect(server.instance_variable_get(:@connection_established)).to be true
      expect(server.instance_variable_get(:@initialized)).to be true
    end

    it 'returns true if already connected' do
      server.instance_variable_set(:@connection_established, true)
      expect(server.connect).to be true
    end

    context 'when connection fails' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'raises ConnectionError' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Server connection lost.*Connection refused/
        )
      end

      it 'cleans up on failure' do
        expect(server).to receive(:cleanup)
        expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError)
      end
    end

    context 'when authentication fails' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 401, body: 'Unauthorized')
      end

      it 'raises ConnectionError with auth message' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Authorization failed: HTTP 401/
        )
      end
    end

    context 'when server returns error' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 500, body: 'Internal Server Error')
      end

      it 'raises ConnectionError' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Failed to connect to MCP server/
        )
      end
    end
  end

  describe '#list_tools' do
    let(:tools_response) do
      {
        jsonrpc: '2.0',
        id: 2,
        result: {
          tools: [
            {
              name: 'test_tool',
              description: 'A test tool',
              inputSchema: {
                type: 'object',
                properties: {
                  param: { type: 'string' }
                }
              }
            }
          ]
        }
      }
    end

    before do
      # Stub connection
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(
          body: hash_including(method: 'tools/list'),
          headers: { 'Content-Type' => 'application/json' }
        )
        .to_return(
          status: 200,
          body: tools_response.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'returns list of tools' do
      tools = server.list_tools
      expect(tools.size).to eq(1)
      expect(tools.first).to be_a(MCPClient::Tool)
      expect(tools.first.name).to eq('test_tool')
      expect(tools.first.description).to eq('A test tool')
    end

    it 'caches tools after first call' do
      server.list_tools
      server.list_tools
      expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}").once
    end

    context 'when not connected' do
      before do
        server.instance_variable_set(:@connection_established, false)
        allow(server).to receive(:connect) do
          server.instance_variable_set(:@connection_established, true)
          server.instance_variable_set(:@initialized, true)
        end
      end

      it 'attempts to connect first' do
        expect(server).to receive(:connect)
        server.list_tools
      end
    end

    context 'when server returns error' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: {
              jsonrpc: '2.0',
              id: 2,
              error: { code: -1, message: 'Tools not available' }
            }.to_json
          )
      end

      it 'raises ServerError' do
        expect { server.list_tools }.to raise_error(
          MCPClient::Errors::ServerError,
          'Tools not available'
        )
      end
    end

    context 'when response is invalid JSON' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 200, body: 'invalid json')
      end

      it 'raises TransportError' do
        expect { server.list_tools }.to raise_error(
          MCPClient::Errors::TransportError,
          /Invalid JSON response/
        )
      end
    end
  end

  describe '#call_tool' do
    let(:tool_name) { 'test_tool' }
    let(:parameters) { { param: 'value' } }
    let(:tool_response) do
      {
        jsonrpc: '2.0',
        id: 3,
        result: {
          content: [
            { type: 'text', text: 'Tool executed successfully' }
          ]
        }
      }
    end

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)

      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(
          status: 200,
          body: tool_response.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'calls tool with correct parameters' do
      result = server.call_tool(tool_name, parameters)
      expect(result).to eq({
                             'content' => [
                               { 'type' => 'text', 'text' => 'Tool executed successfully' }
                             ]
                           })
    end

    it 'sends correct JSON-RPC request' do
      server.call_tool(tool_name, parameters)
      expect(WebMock).to(have_requested(:post, "#{base_url}#{endpoint}")
        .with do |req|
          body = JSON.parse(req.body)
          body['method'] == 'tools/call' &&
            body['params']['name'] == tool_name &&
            body['params']['arguments'] == { 'param' => 'value' }
        end)
    end

    context 'when connection is lost' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_raise(Faraday::ConnectionFailed.new('Connection lost'))
      end

      it 'raises ConnectionError' do
        expect { server.call_tool(tool_name, parameters) }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Server connection lost/
        )
      end
    end

    context 'when server returns tool error' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: {
              jsonrpc: '2.0',
              id: 3,
              error: { code: -1, message: 'Tool not found' }
            }.to_json
          )
      end

      it 'raises ToolCallError' do
        expect { server.call_tool(tool_name, parameters) }.to raise_error(
          MCPClient::Errors::ToolCallError,
          /Error calling tool 'test_tool'/
        )
      end
    end
  end

  describe '#call_tool_streaming' do
    let(:tool_name) { 'test_tool' }
    let(:parameters) { { param: 'value' } }
    let(:result) { { content: [{ type: 'text', text: 'Result' }] } }

    before do
      allow(server).to receive(:call_tool).with(tool_name, parameters).and_return(result)
    end

    it 'returns an enumerator' do
      stream = server.call_tool_streaming(tool_name, parameters)
      expect(stream).to be_a(Enumerator)
    end

    it 'yields the tool call result' do
      stream = server.call_tool_streaming(tool_name, parameters)
      results = stream.to_a
      expect(results).to eq([result])
    end
  end

  describe '#rpc_request' do
    let(:method_name) { 'test_method' }
    let(:params) { { key: 'value' } }
    let(:response) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: { success: true }
      }
    end

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(
          body: hash_including(method: method_name, params: params)
        )
        .to_return(
          status: 200,
          body: response.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'sends JSON-RPC request and returns result' do
      result = server.rpc_request(method_name, params)
      expect(result).to eq({ 'success' => true })
    end
  end

  describe '#rpc_notify' do
    let(:method_name) { 'notification' }
    let(:params) { { event: 'test' } }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(
          body: hash_including(method: method_name, params: params)
        )
        .to_return(status: 200)
    end

    it 'sends notification without expecting response' do
      expect { server.rpc_notify(method_name, params) }.not_to raise_error
    end

    it 'sends request without id field' do
      server.rpc_notify(method_name, params)
      expect(WebMock).to(have_requested(:post, "#{base_url}#{endpoint}")
        .with do |req|
          body = JSON.parse(req.body)
          !body.key?('id') && body['method'] == method_name
        end)
    end
  end

  describe '#cleanup' do
    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@tools, [double('tool')])
    end

    it 'resets connection state' do
      server.cleanup
      expect(server.instance_variable_get(:@connection_established)).to be false
      expect(server.instance_variable_get(:@initialized)).to be false
    end

    it 'clears cached data' do
      server.cleanup
      expect(server.instance_variable_get(:@tools)).to be_nil
      expect(server.instance_variable_get(:@tools_data)).to be_nil
    end

    it 'clears HTTP connection' do
      server.instance_variable_set(:@http_conn, double('connection'))
      server.cleanup
      expect(server.instance_variable_get(:@http_conn)).to be_nil
    end
  end

  describe '#ping' do
    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including(method: 'ping'))
        .to_return(
          status: 200,
          body: { jsonrpc: '2.0', id: 1, result: 'pong' }.to_json
        )
    end

    it 'sends ping request' do
      result = server.ping
      expect(result).to eq('pong')
    end
  end

  describe 'error handling' do
    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
    end

    context 'when server returns HTTP error codes' do
      [400, 404, 500, 503].each do |status_code|
        it "handles #{status_code} status code" do
          stub_request(:post, "#{base_url}#{endpoint}")
            .to_return(status: status_code, body: 'Error')

          expect { server.rpc_request('test') }.to raise_error(
            MCPClient::Errors::ServerError,
            /HTTP #{status_code}/
          )
        end
      end
    end

    context 'when network timeouts occur' do
      it 'raises ConnectionError on timeout' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_timeout

        expect { server.rpc_request('test') }.to raise_error(
          MCPClient::Errors::ConnectionError
        )
      end
    end
  end

  describe 'session management' do
    describe '#terminate_session' do
      context 'when session ID is present' do
        before do
          server.instance_variable_set(:@session_id, 'test-session-123')
        end

        it 'sends HTTP DELETE request with session ID' do
          stub_request(:delete, "#{base_url}#{endpoint}")
            .with(headers: { 'Mcp-Session-Id' => 'test-session-123' })
            .to_return(status: 200, body: '')

          result = server.terminate_session
          expect(result).to be true
          expect(server.instance_variable_get(:@session_id)).to be_nil
        end

        it 'handles termination failure gracefully' do
          stub_request(:delete, "#{base_url}#{endpoint}")
            .to_return(status: 400, body: 'Bad Request')

          result = server.terminate_session
          expect(result).to be false
        end

        it 'clears session ID even on network errors' do
          stub_request(:delete, "#{base_url}#{endpoint}")
            .to_raise(Faraday::ConnectionFailed.new('Connection failed'))

          result = server.terminate_session
          expect(result).to be false
          expect(server.instance_variable_get(:@session_id)).to be_nil
        end
      end

      context 'when no session ID is present' do
        it 'returns true without making a request' do
          expect(server.terminate_session).to be true
          expect(WebMock).not_to have_requested(:delete, "#{base_url}#{endpoint}")
        end
      end
    end

    describe 'session ID capture and validation' do
      before do
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
      end

      it 'captures valid session ID from initialize response' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: { jsonrpc: '2.0', id: 1, result: {} }.to_json,
            headers: { 'Mcp-Session-Id' => 'valid-session-123' }
          )

        server.send(:perform_initialize)
        expect(server.instance_variable_get(:@session_id)).to eq('valid-session-123')
      end

      it 'rejects invalid session ID format' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: { jsonrpc: '2.0', id: 1, result: {} }.to_json,
            headers: { 'Mcp-Session-Id' => 'invalid@session!' }
          )

        server.send(:perform_initialize)
        expect(server.instance_variable_get(:@session_id)).to be_nil
      end

      it 'handles missing session ID gracefully' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: { jsonrpc: '2.0', id: 1, result: {} }.to_json,
            headers: {}
          )

        server.send(:perform_initialize)
        expect(server.instance_variable_get(:@session_id)).to be_nil
      end
    end

    describe 'session header injection' do
      before do
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
        server.instance_variable_set(:@session_id, 'active-session-456')
      end

      it 'includes session header in non-initialize requests' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            headers: { 'Mcp-Session-Id' => 'active-session-456' },
            body: hash_including(method: 'tools/list')
          )
          .to_return(
            status: 200,
            body: { jsonrpc: '2.0', id: 1, result: { tools: [] } }.to_json
          )

        server.send(:request_tools_list)
        expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}")
          .with(headers: { 'Mcp-Session-Id' => 'active-session-456' })
      end

      it 'does not include session header in initialize requests' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: { jsonrpc: '2.0', id: 1, result: {} }.to_json
          )

        server.send(:perform_initialize)
        expect(WebMock).to(have_requested(:post, "#{base_url}#{endpoint}")
          .with { |req| !req.headers.key?('Mcp-Session-Id') })
      end
    end

    describe 'cleanup with session termination' do
      before do
        server.instance_variable_set(:@session_id, 'cleanup-session-789')
      end

      it 'terminates session during cleanup' do
        stub_request(:delete, "#{base_url}#{endpoint}")
          .with(headers: { 'Mcp-Session-Id' => 'cleanup-session-789' })
          .to_return(status: 200, body: '')

        server.cleanup

        expect(WebMock).to have_requested(:delete, "#{base_url}#{endpoint}")
        expect(server.instance_variable_get(:@session_id)).to be_nil
      end
    end
  end

  describe 'security validation' do
    describe '#valid_session_id?' do
      valid_session_ids = [
        'abc123def456',
        'session_id_123',
        'sess-123-abc_def',
        'a1b2c3d4e5f6g7h8',
        '12345678' # minimum length
      ]

      invalid_session_ids = [
        '', # empty
        'short', # too short
        'x' * 200,           # too long
        'session@id',        # invalid characters
        'session id',        # spaces
        'session.id',        # dots
        'session/id',        # slashes
        'session%id'         # percent encoding
      ]

      valid_session_ids.each do |session_id|
        it "accepts valid session ID: '#{session_id}'" do
          expect(server.send(:valid_session_id?, session_id)).to be true
        end
      end

      invalid_session_ids.each do |session_id|
        it "rejects invalid session ID: '#{session_id.length > 20 ? "#{session_id[0..17]}..." : session_id}'" do
          expect(server.send(:valid_session_id?, session_id)).to be false
        end
      end

      it 'rejects non-string input' do
        expect(server.send(:valid_session_id?, nil)).to be false
        expect(server.send(:valid_session_id?, 123)).to be false
        expect(server.send(:valid_session_id?, [])).to be false
      end
    end

    describe '#valid_server_url?' do
      valid_urls = [
        'http://localhost:3000',
        'https://api.example.com',
        'http://127.0.0.1:8080',
        'https://subdomain.example.com/path'
      ]

      invalid_urls = [
        'ftp://example.com',    # invalid protocol
        'file:///path/to/file', # file protocol
        'javascript:alert(1)',  # javascript protocol
        'not-a-url',           # invalid format
        '',                    # empty
        'http://',             # incomplete
        'https://'             # incomplete
      ]

      valid_urls.each do |url|
        it "accepts valid URL: '#{url}'" do
          expect(server.send(:valid_server_url?, url)).to be true
        end
      end

      invalid_urls.each do |url|
        it "rejects invalid URL: '#{url}'" do
          expect(server.send(:valid_server_url?, url)).to be false
        end
      end

      it 'rejects non-string input' do
        expect(server.send(:valid_server_url?, nil)).to be false
        expect(server.send(:valid_server_url?, 123)).to be false
        expect(server.send(:valid_server_url?, [])).to be false
      end
    end

    describe 'URL validation during initialization' do
      it 'raises ArgumentError for invalid URL' do
        expect do
          described_class.new(base_url: 'ftp://invalid.com')
        end.to raise_error(ArgumentError, /Invalid or insecure server URL/)
      end

      it 'raises ArgumentError for malicious URL' do
        expect do
          described_class.new(base_url: 'javascript:alert(1)')
        end.to raise_error(ArgumentError, /Invalid or insecure server URL/)
      end
    end
  end
end
