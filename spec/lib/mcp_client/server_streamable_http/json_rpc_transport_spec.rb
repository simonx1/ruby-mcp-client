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
                    :http_conn, :server_info, :capabilities

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
        @http_conn = nil
        @server_info = nil
        @capabilities = nil
      end

      def ensure_connected
        raise MCPClient::Errors::ConnectionError, 'Not connected' unless @connection_established && @initialized
      end

      def cleanup
        @connection_established = false
        @initialized = false
        @http_conn = nil
      end
    end
  end

  subject(:transport) { dummy_class.new }

  let(:faraday_stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:faraday_conn) do
    Faraday.new do |builder|
      builder.adapter :test, faraday_stubs
    end
  end

  before do
    WebMock.disable_net_connect!
    transport.http_conn = faraday_conn
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
      faraday_stubs.post('/rpc') do |env|
        request_body = JSON.parse(env.body)
        expect(request_body['method']).to eq(method_name)
        expect(request_body['params']).to eq({ 'key' => 'value' })
        expect(request_body['jsonrpc']).to eq('2.0')
        expect(request_body['id']).to be_a(Integer)

        # Verify headers
        expect(env.request_headers['Content-Type']).to eq('application/json')
        expect(env.request_headers['Accept']).to eq('text/event-stream, application/json')
        expect(env.request_headers['Authorization']).to eq('Bearer test-token')

        [200, { 'Content-Type' => 'text/event-stream' }, sse_response]
      end
    end

    it 'sends JSON-RPC request with correct format' do
      result = transport.rpc_request(method_name, params)
      expect(result).to eq({ 'success' => true, 'data' => 'test_result' })
    end

    it 'increments request ID for each request' do
      initial_id = transport.request_id
      transport.rpc_request(method_name, params)
      expect(transport.request_id).to eq(initial_id + 1)
    end

    it 'includes all custom headers in request' do
      transport.rpc_request(method_name, params)
      # Headers are verified in the faraday_stubs block above
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
      let(:error_faraday_stubs) { Faraday::Adapter::Test::Stubs.new }
      let(:error_faraday_conn) do
        Faraday.new do |builder|
          builder.adapter :test, error_faraday_stubs
        end
      end
      
      before do
        transport.http_conn = error_faraday_conn
        error_response = {
          'jsonrpc' => '2.0',
          'id' => 1,
          'error' => { 'code' => -32_601, 'message' => 'Method not found' }
        }
        sse_error_response = "event: message\ndata: #{error_response.to_json}\n\n"
        
        error_faraday_stubs.post('/rpc') do |_env|
          [200, { 'Content-Type' => 'text/event-stream' }, sse_error_response]
        end
      end

      it 'raises ServerError with error message' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::ServerError,
          'Method not found'
        )
      end
    end

    context 'when HTTP request fails' do
      let(:error_faraday_stubs) { Faraday::Adapter::Test::Stubs.new }
      let(:error_faraday_conn) do
        Faraday.new do |builder|
          builder.adapter :test, error_faraday_stubs
        end
      end
      
      before do
        transport.http_conn = error_faraday_conn
        error_faraday_stubs.post('/rpc') do |_env|
          [500, {}, 'Internal Server Error']
        end
      end

      it 'raises ServerError for server errors' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::ServerError,
          /Server error: HTTP 500/
        )
      end
    end

    context 'when authorization fails' do
      let(:auth_faraday_stubs) { Faraday::Adapter::Test::Stubs.new }
      let(:auth_faraday_conn) do
        Faraday.new do |builder|
          builder.adapter :test, auth_faraday_stubs
        end
      end
      
      before do
        transport.http_conn = auth_faraday_conn
        auth_faraday_stubs.post('/rpc') do |_env|
          [401, {}, 'Unauthorized']
        end
      end

      it 'raises ConnectionError for auth failures' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Authorization failed: HTTP 401/
        )
      end
    end

    context 'when response is invalid JSON' do
      let(:invalid_faraday_stubs) { Faraday::Adapter::Test::Stubs.new }
      let(:invalid_faraday_conn) do
        Faraday.new do |builder|
          builder.adapter :test, invalid_faraday_stubs
        end
      end
      
      before do
        transport.http_conn = invalid_faraday_conn
        invalid_faraday_stubs.post('/rpc') do |_env|
          [200, { 'Content-Type' => 'text/event-stream' }, "event: message\ndata: invalid json\n\n"]
        end
      end

      it 'raises TransportError' do
        expect { transport.rpc_request(method_name, params) }.to raise_error(
          MCPClient::Errors::TransportError,
          /Invalid JSON response from server/
        )
      end
    end

    context 'when SSE response is malformed' do
      let(:malformed_faraday_stubs) { Faraday::Adapter::Test::Stubs.new }
      let(:malformed_faraday_conn) do
        Faraday.new do |builder|
          builder.adapter :test, malformed_faraday_stubs
        end
      end
      
      before do
        transport.http_conn = malformed_faraday_conn
        malformed_faraday_stubs.post('/rpc') do |_env|
          [200, { 'Content-Type' => 'text/event-stream' }, "event: message\nno data line\n\n"]
        end
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
        allow(transport).to receive(:get_http_connection).and_raise(
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
          if @attempt_count < 3
            raise MCPClient::Errors::TransportError, 'Temporary failure'
          else
            double('response', body: sse_response)
          end
        end
        
        allow(transport).to receive(:parse_streamable_http_response).and_return(response_data[:result])

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
      faraday_stubs.post('/rpc') do |env|
        request_body = JSON.parse(env.body)
        expect(request_body['method']).to eq(method_name)
        expect(request_body['params']).to eq({ 'event' => 'test_event' })
        expect(request_body['jsonrpc']).to eq('2.0')
        expect(request_body).not_to have_key('id') # Notifications should not have id

        [200, {}, '']
      end
    end

    it 'sends notification without id field' do
      expect { transport.rpc_notify(method_name, params) }.not_to raise_error
    end

    it 'does not expect a response' do
      transport.rpc_notify(method_name, params)
      # No assertion needed - if it doesn't raise an error, it succeeded
    end

    context 'when notification fails' do
      let(:notify_faraday_stubs) { Faraday::Adapter::Test::Stubs.new }
      let(:notify_faraday_conn) do
        Faraday.new do |builder|
          builder.adapter :test, notify_faraday_stubs
        end
      end
      
      before do
        transport.http_conn = notify_faraday_conn
        notify_faraday_stubs.post('/rpc') do |_env|
          [500, {}, 'Server Error']
        end
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
      faraday_stubs.post('/rpc') do |env|
        request_body = JSON.parse(env.body)
        expect(request_body['method']).to eq('initialize')
        expect(request_body['params']).to have_key('protocolVersion')
        expect(request_body['params']).to have_key('capabilities')
        expect(request_body['params']).to have_key('clientInfo')

        [200, { 'Content-Type' => 'text/event-stream' }, sse_response]
      end
    end

    it 'sends initialize request with correct parameters' do
      transport.send(:perform_initialize)
      expect(transport.server_info).to eq({ 'name' => 'test-server', 'version' => '1.0.0' })
      expect(transport.capabilities).to eq({ 'tools' => {} })
    end

    it 'includes protocol version in request' do
      transport.send(:perform_initialize)
      # Parameters are verified in the faraday_stubs block above
    end

    it 'includes client info in request' do
      transport.send(:perform_initialize)
      # Parameters are verified in the faraday_stubs block above
    end
  end

  describe '#send_http_request' do
    let(:request_data) { { jsonrpc: '2.0', method: 'test', id: 1 } }

    before do
      faraday_stubs.post('/rpc') do |env|
        expect(env.body).to eq(request_data.to_json)
        [200, { 'Content-Type' => 'text/event-stream' }, 'success']
      end
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
        transport.http_conn = nil
        # Mock the creation of HTTP connection
        allow(transport).to receive(:create_http_connection).and_return(faraday_conn)
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

  describe '#parse_streamable_http_response' do
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
        result = transport.send(:parse_streamable_http_response, mock_response)
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
        expect { transport.send(:parse_streamable_http_response, mock_response) }.to raise_error(
          MCPClient::Errors::ServerError,
          'Test error'
        )
      end
    end

    context 'with invalid JSON in SSE response' do
      let(:response_body) { "event: message\ndata: invalid json\n\n" }

      it 'raises TransportError' do
        expect { transport.send(:parse_streamable_http_response, mock_response) }.to raise_error(
          MCPClient::Errors::TransportError,
          /Invalid JSON response from server/
        )
      end
    end

    context 'with malformed SSE response' do
      let(:response_body) { "event: message\nno data line\n\n" }

      it 'raises TransportError for missing data' do
        expect { transport.send(:parse_streamable_http_response, mock_response) }.to raise_error(
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