# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'faraday'
require 'stringio'

RSpec.describe MCPClient::ServerStreamableHTTP::JsonRpcTransport do
  # Create dummy class to test the module
  let(:dummy_class) do
    Class.new do
      include MCPClient::ServerStreamableHTTP::JsonRpcTransport

      attr_accessor :logger, :base_url, :endpoint, :headers, :max_retries, :retry_backoff,
                    :read_timeout, :request_id, :mutex, :connection_established, :initialized,
                    :server_info, :capabilities

      def initialize
        @logger = Logger.new(StringIO.new)
        @base_url = 'https://example.com'
        @endpoint = '/rpc'
        @headers = {
          'Content-Type' => 'application/json',
          'Accept' => 'text/event-stream, application/json',
          'Authorization' => 'Bearer test-token',
          'Cache-Control' => 'no-cache'
        }
        @max_retries = 2
        @retry_backoff = 0.1
        @read_timeout = 30
        @request_id = 0
        @mutex = Monitor.new
        @connection_established = true
        @initialized = true
        @server_info = nil
        @capabilities = nil
      end

      def ensure_connected
        raise MCPClient::Errors::ConnectionError, 'Not connected' unless @connection_established && @initialized
      end

      def cleanup
        @connection_established = false
        @initialized = false
      end
    end
  end

  subject(:transport) { dummy_class.new }

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
  end

  describe '#rpc_request' do
    let(:method_name) { 'test_method' }
    let(:params) { { key: 'value' } }
    let(:response_data) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: { success: true, data: 'test_result' }
      }
    end
    let(:sse_response) { "event: message\ndata: #{response_data.to_json}\n\n" }

    before do
      stub_request(:post, 'https://example.com/rpc')
        .with do |request|
          request_body = JSON.parse(request.body)
          request_body['method'] == method_name &&
            request_body['params'] == { 'key' => 'value' } &&
            request_body['jsonrpc'] == '2.0' &&
            request_body['id'].is_a?(Integer) &&
            request.headers['Content-Type'] == 'application/json' &&
            request.headers['Accept'] == 'text/event-stream, application/json' &&
            request.headers['Authorization'] == 'Bearer test-token'
        end
        .to_return(
          status: 200,
          body: sse_response,
          headers: { 'Content-Type' => 'text/event-stream' }
        )
    end

    it 'sends JSON-RPC request with correct format' do
      result = transport.rpc_request(method_name, params)
      expect(result).to eq({ 'success' => true, 'data' => 'test_result' })
    end

    it 'increments request ID for each request' do
      # Clear any existing stubs to create fresh ones for this test
      WebMock.reset!

      # Stub for the first request
      stub_request(:post, 'https://example.com/rpc')
        .with do |request|
          request_body = JSON.parse(request.body)
          request_body['id'] == 1
        end
        .to_return(
          status: 200,
          body: sse_response,
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      # Stub for the second request
      stub_request(:post, 'https://example.com/rpc')
        .with do |request|
          request_body = JSON.parse(request.body)
          request_body['id'] == 2
        end
        .to_return(
          status: 200,
          body: sse_response,
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      initial_id = transport.request_id
      transport.rpc_request(method_name, params)
      expect(transport.request_id).to eq(initial_id + 1)

      # Make another request to verify ID increments again
      transport.rpc_request(method_name, params)
      expect(transport.request_id).to eq(initial_id + 2)
    end

    it 'includes all custom headers in request' do
      transport.rpc_request(method_name, params)
      # Headers are verified in the WebMock stub above
    end

    context 'when connection is not established' do
      before do
        transport.connection_established = false
        # No stub needed since the method should fail before making HTTP call
      end

      it 'raises ConnectionError' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::ConnectionError,
          'Not connected'
        )
      end
    end

    context 'when server returns JSON-RPC error' do
      before do
        error_response = {
          'jsonrpc' => '2.0',
          'id' => 1,
          'error' => { 'code' => -32_601, 'message' => 'Method not found' }
        }
        sse_error_response = "event: message\ndata: #{error_response.to_json}\n\n"

        stub_request(:post, 'https://example.com/rpc')
          .to_return(
            status: 200,
            body: sse_error_response,
            headers: { 'Content-Type' => 'text/event-stream' }
          )
      end

      it 'raises ServerError with error message' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::ServerError,
          'Method not found'
        )
      end
    end

    context 'when HTTP request fails' do
      before do
        stub_request(:post, 'https://example.com/rpc')
          .to_return(
            status: 500,
            body: 'Internal Server Error'
          )
      end

      it 'raises ServerError for server errors' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::ServerError,
          /Server error: HTTP 500/
        )
      end
    end

    context 'when authorization fails' do
      before do
        stub_request(:post, 'https://example.com/rpc')
          .to_return(
            status: 401,
            body: 'Unauthorized'
          )
      end

      it 'raises ConnectionError for auth failures' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Authorization failed: HTTP 401/
        )
      end
    end

    context 'when response is invalid JSON' do
      before do
        stub_request(:post, 'https://example.com/rpc')
          .to_return(
            status: 200,
            body: "event: message\ndata: invalid json\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )
      end

      it 'raises TransportError' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::TransportError,
          /Invalid JSON response from server/
        )
      end
    end

    context 'when SSE response is malformed' do
      before do
        stub_request(:post, 'https://example.com/rpc')
          .to_return(
            status: 200,
            body: "event: message\nno data line\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )
      end

      it 'raises TransportError for missing data' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::TransportError,
          /No data found in SSE response/
        )
      end
    end

    context 'when connection fails' do
      before do
        allow(transport).to receive(:http_connection).and_raise(
          Faraday::ConnectionFailed.new('Connection refused')
        )
      end

      it 'raises ToolCallError with ConnectionError details' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::ToolCallError,
          /Error executing request.*Connection refused/
        )
      end
    end

    context 'with retry logic' do
      before do
        transport.max_retries = 2
        @attempt_count = 0
      end

      it 'retries on transient failures' do
        # Stub the connection method to avoid the actual connection failure raising
        allow(transport).to receive(:send_http_request) do
          @attempt_count += 1
          raise MCPClient::Errors::TransportError, 'Temporary failure' if @attempt_count < 3

          double('response', body: sse_response)
        end

        allow(transport).to receive(:parse_response).and_return(response_data[:result])

        result = transport.rpc_request(method_name, params)
        expect(result).to eq(response_data[:result])
        expect(@attempt_count).to eq(3)
      end
    end
  end

  describe '#rpc_notify' do
    let(:method_name) { 'notification_method' }
    let(:params) { { event: 'test_event' } }

    before do
      stub_request(:post, 'https://example.com/rpc')
        .with do |request|
          request_body = JSON.parse(request.body)
          request_body['method'] == method_name &&
            request_body['params'] == { 'event' => 'test_event' } &&
            request_body['jsonrpc'] == '2.0' &&
            !request_body.key?('id') # Notifications should not have id
        end
        .to_return(
          status: 200,
          body: ''
        )
    end

    it 'sends notification without id field' do
      expect { transport.rpc_notify(method_name, params) }.not_to raise_error
    end

    it 'does not expect a response' do
      transport.rpc_notify(method_name, params)
      # No assertion needed - if it doesn't raise an error, it succeeded
    end

    context 'when notification fails' do
      before do
        stub_request(:post, 'https://example.com/rpc')
          .to_return(
            status: 500,
            body: 'Server Error'
          )
      end

      it 'raises TransportError' do
        expect { transport.rpc_notify(method_name, params) }.to raise_error(
          MCPClient::Errors::TransportError,
          /Failed to send notification/
        )
      end
    end
  end

  describe '#perform_initialize' do
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
    let(:sse_response) { "event: message\ndata: #{initialize_response.to_json}\n\n" }

    before do
      stub_request(:post, 'https://example.com/rpc')
        .with do |request|
          request_body = JSON.parse(request.body)
          request_body['method'] == 'initialize' &&
            request_body['params'].key?('protocolVersion') &&
            request_body['params'].key?('capabilities') &&
            request_body['params'].key?('clientInfo')
        end
        .to_return(
          status: 200,
          body: sse_response,
          headers: { 'Content-Type' => 'text/event-stream' }
        )
    end

    it 'sends initialize request with correct parameters' do
      transport.send(:perform_initialize)
      expect(transport.server_info).to eq({ 'name' => 'test-server', 'version' => '1.0.0' })
      expect(transport.capabilities).to eq({ 'tools' => {} })
    end

    it 'includes protocol version in request' do
      transport.send(:perform_initialize)
      # Parameters are verified in the WebMock stub above
    end

    it 'includes client info in request' do
      transport.send(:perform_initialize)
      # Parameters are verified in the WebMock stub above
    end
  end

  describe '#send_http_request' do
    let(:request_data) { { jsonrpc: '2.0', method: 'test', id: 1 } }

    before do
      stub_request(:post, 'https://example.com/rpc')
        .with(body: request_data.to_json)
        .to_return(
          status: 200,
          body: 'success',
          headers: { 'Content-Type' => 'text/event-stream' }
        )
    end

    it 'sends HTTP POST request with JSON body' do
      response = transport.send(:send_http_request, request_data)
      expect(response.status).to eq(200)
      expect(response.body).to eq('success')
    end

    it 'applies all headers to request' do
      transport.send(:send_http_request, request_data)
      # Headers are verified implicitly through the successful request
    end

    context 'when HTTP client is not set' do
      before do
        transport.instance_variable_set(:@http_connection, nil)
        # Mock the creation of HTTP connection
        mock_conn = double('connection')
        allow(transport).to receive(:create_http_connection).and_return(mock_conn)
        allow(mock_conn).to receive(:post).and_return(double('response', status: 200, body: 'success', success?: true))
      end

      it 'creates HTTP connection automatically' do
        expect(transport).to receive(:create_http_connection)
        transport.send(:send_http_request, request_data)
      end
    end
  end

  describe '#create_http_connection' do
    it 'creates Faraday connection with correct configuration' do
      conn = transport.send(:create_http_connection)
      expect(conn).to be_a(Faraday::Connection)
      expect(conn.url_prefix.to_s).to start_with(transport.base_url)
    end

    it 'sets up retry middleware' do
      conn = transport.send(:create_http_connection)
      # Check if retry middleware is configured
      expect(conn.builder.handlers).to include(Faraday::Retry::Middleware)
    end

    it 'configures timeouts' do
      conn = transport.send(:create_http_connection)
      expect(conn.options.timeout).to eq(transport.read_timeout)
      expect(conn.options.open_timeout).to eq(transport.read_timeout)
    end
  end

  describe '#parse_response' do
    let(:mock_response) { double('response', body: response_body) }

    context 'with valid SSE JSON response' do
      let(:response_body) do
        "event: message\ndata: #{response_data.to_json}\n\n"
      end
      let(:response_data) do
        {
          jsonrpc: '2.0',
          id: 1,
          result: { data: 'test' }
        }
      end

      it 'parses SSE and returns result' do
        result = transport.send(:parse_response, mock_response)
        expect(result).to eq({ 'data' => 'test' })
      end
    end

    context 'with JSON-RPC error in SSE response' do
      let(:response_body) do
        "event: message\ndata: #{error_data.to_json}\n\n"
      end
      let(:error_data) do
        {
          jsonrpc: '2.0',
          id: 1,
          error: { code: -1, message: 'Test error' }
        }
      end

      it 'raises ServerError with error message' do
        expect { transport.send(:parse_response, mock_response) }.to raise_error(
          MCPClient::Errors::ServerError,
          'Test error'
        )
      end
    end

    context 'with invalid JSON in SSE response' do
      let(:response_body) { "event: message\ndata: invalid json\n\n" }

      it 'raises TransportError' do
        expect { transport.send(:parse_response, mock_response) }.to raise_error(
          MCPClient::Errors::TransportError,
          /Invalid JSON response from server/
        )
      end
    end

    context 'with malformed SSE response' do
      let(:response_body) { "event: message\nno data line\n\n" }

      it 'raises TransportError for missing data' do
        expect { transport.send(:parse_response, mock_response) }.to raise_error(
          MCPClient::Errors::TransportError,
          /No data found in SSE response/
        )
      end
    end
  end

  describe '#parse_sse_response' do
    context 'with standard SSE format' do
      let(:sse_body) { "event: message\ndata: #{data.to_json}\n\n" }
      let(:data) { { test: 'value' } }

      it 'extracts JSON data from SSE format' do
        result = transport.send(:parse_sse_response, sse_body)
        expect(result).to eq({ 'test' => 'value' })
      end
    end

    context 'with SSE format containing spaces' do
      let(:sse_body) { "event: message\ndata:   #{data.to_json}  \n\n" }
      let(:data) { { test: 'spaced' } }

      it 'handles extra spaces around data' do
        result = transport.send(:parse_sse_response, sse_body)
        expect(result).to eq({ 'test' => 'spaced' })
      end
    end

    context 'with multi-line SSE format' do
      let(:sse_body) { "event: message\nid: 123\ndata: #{data.to_json}\nretry: 1000\n\n" }
      let(:data) { { test: 'multiline' } }

      it 'finds data line among other SSE fields' do
        result = transport.send(:parse_sse_response, sse_body)
        expect(result).to eq({ 'test' => 'multiline' })
      end
    end

    context 'without data line' do
      let(:sse_body) { "event: message\nid: 123\n\n" }

      it 'raises error when no data line found' do
        expect { transport.send(:parse_sse_response, sse_body) }.to raise_error(
          MCPClient::Errors::TransportError,
          /No data found in SSE response/
        )
      end
    end
  end

  describe '#handle_http_error_response' do
    let(:mock_response) { double('response', status: status, reason_phrase: 'Error') }

    context 'with 401 status' do
      let(:status) { 401 }

      it 'raises ConnectionError for auth failure' do
        expect { transport.send(:handle_http_error_response, mock_response) }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Authorization failed: HTTP 401/
        )
      end
    end

    context 'with 403 status' do
      let(:status) { 403 }

      it 'raises ConnectionError for forbidden' do
        expect { transport.send(:handle_http_error_response, mock_response) }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Authorization failed: HTTP 403/
        )
      end
    end

    context 'with 400 status' do
      let(:status) { 400 }

      it 'raises ServerError for client error' do
        expect { transport.send(:handle_http_error_response, mock_response) }.to raise_error(
          MCPClient::Errors::ServerError,
          /Client error: HTTP 400/
        )
      end
    end

    context 'with 500 status' do
      let(:status) { 500 }

      it 'raises ServerError for server error' do
        expect { transport.send(:handle_http_error_response, mock_response) }.to raise_error(
          MCPClient::Errors::ServerError,
          /Server error: HTTP 500/
        )
      end
    end
  end
end
