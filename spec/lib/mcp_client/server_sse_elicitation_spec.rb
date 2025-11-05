# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::ServerSSE, 'Elicitation (MCP 2025-06-18)' do
  let(:base_url) { 'https://example.com/mcp' }
  let(:headers) { { 'Authorization' => 'Bearer token123' } }
  let(:server) { described_class.new(base_url: base_url, headers: headers) }

  before do
    # Set up minimal initialized state
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@rpc_endpoint, '/messages')
  end

  describe '#on_elicitation_request' do
    it 'registers an elicitation callback' do
      callback = ->(_request_id, _params) { { 'action' => 'accept' } }
      server.on_elicitation_request(&callback)
      expect(server.instance_variable_get(:@elicitation_request_callback)).to eq(callback)
    end
  end

  describe '#handle_server_request' do
    let(:request_id) { 123 }
    let(:params) do
      {
        'message' => 'Enter your name:',
        'requestedSchema' => {
          'type' => 'object',
          'properties' => {
            'name' => { 'type' => 'string' }
          }
        }
      }
    end

    context 'when method is elicitation/create' do
      let(:message) do
        {
          'id' => request_id,
          'method' => 'elicitation/create',
          'params' => params
        }
      end

      it 'calls handle_elicitation_create' do
        expect(server).to receive(:handle_elicitation_create).with(request_id, params)
        server.handle_server_request(message)
      end
    end

    context 'when method is unknown' do
      let(:message) do
        {
          'id' => request_id,
          'method' => 'unknown/method',
          'params' => {}
        }
      end

      it 'sends error response for unknown method' do
        expect(server).to receive(:send_error_response).with(request_id, -32_601, 'Method not found: unknown/method')
        server.handle_server_request(message)
      end
    end

    context 'when an exception occurs' do
      let(:message) do
        {
          'id' => request_id,
          'method' => 'elicitation/create',
          'params' => params
        }
      end

      it 'sends error response for internal error' do
        allow(server).to receive(:handle_elicitation_create).and_raise(StandardError, 'Test error')
        expect(server).to receive(:send_error_response).with(request_id, -32_603, 'Internal error: Test error')
        server.handle_server_request(message)
      end
    end
  end

  describe '#handle_elicitation_create' do
    let(:request_id) { 123 }
    let(:params) do
      {
        'message' => 'Enter your name:',
        'requestedSchema' => {
          'type' => 'object',
          'properties' => {
            'name' => { 'type' => 'string' }
          }
        }
      }
    end

    context 'when no callback is registered' do
      it 'sends decline response' do
        expect(server).to receive(:send_elicitation_response).with(request_id, { 'action' => 'decline' })
        server.handle_elicitation_create(request_id, params)
      end

      it 'logs a warning' do
        allow(server).to receive(:send_elicitation_response)
        logger = server.instance_variable_get(:@logger)
        expect(logger).to receive(:warn).with('Received elicitation request but no callback registered, declining')
        server.handle_elicitation_create(request_id, params)
      end
    end

    context 'when callback is registered' do
      let(:callback_result) { { 'action' => 'accept', 'content' => { 'name' => 'John' } } }

      before do
        callback = ->(_req_id, _params) { callback_result }
        server.on_elicitation_request(&callback)
      end

      it 'calls the registered callback' do
        callback = lambda do |req_id, prms|
          expect(req_id).to eq(request_id)
          expect(prms).to eq(params)
          callback_result
        end
        server.on_elicitation_request(&callback)

        allow(server).to receive(:send_elicitation_response)
        server.handle_elicitation_create(request_id, params)
      end

      it 'sends the callback result as response' do
        expect(server).to receive(:send_elicitation_response).with(request_id, callback_result)
        server.handle_elicitation_create(request_id, params)
      end
    end
  end

  describe '#send_elicitation_response' do
    let(:request_id) { 123 }
    let(:result) { { 'action' => 'accept', 'content' => { 'name' => 'John' } } }

    before do
      # Ensure the server is initialized with an RPC endpoint
      server.instance_variable_set(:@rpc_endpoint, '/messages')
    end

    it 'calls ensure_initialized before sending' do
      expect(server).to receive(:ensure_initialized)
      allow(server).to receive(:post_jsonrpc_response)
      server.send_elicitation_response(request_id, result)
    end

    it 'sends JSON-RPC response via HTTP POST' do
      allow(server).to receive(:ensure_initialized)

      expected_response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'result' => result
      }

      expect(server).to receive(:post_jsonrpc_response).with(expected_response)
      server.send_elicitation_response(request_id, result)
    end
  end

  describe '#post_jsonrpc_response' do
    let(:response) { { 'jsonrpc' => '2.0', 'id' => 123, 'result' => { 'action' => 'accept' } } }

    context 'when RPC endpoint is not available' do
      before do
        server.instance_variable_set(:@rpc_endpoint, nil)
      end

      it 'logs error and returns early' do
        logger = server.instance_variable_get(:@logger)
        expect(logger).to receive(:error).with('Cannot send response: RPC endpoint not available')
        server.post_jsonrpc_response(response)
      end

      it 'does not attempt to make HTTP request' do
        allow(server.instance_variable_get(:@logger)).to receive(:error)
        expect_any_instance_of(Faraday::Connection).not_to receive(:post)
        server.post_jsonrpc_response(response)
      end
    end

    context 'when RPC endpoint is available' do
      before do
        server.instance_variable_set(:@rpc_endpoint, '/messages')
        server.instance_variable_set(:@base_url, 'https://example.com/mcp')
        server.instance_variable_set(:@headers, headers)
      end

      it 'creates HTTP connection using create_json_rpc_connection' do
        # Mock the connection creation
        mock_conn = instance_double(Faraday::Connection)
        allow(server).to receive(:create_json_rpc_connection).and_return(mock_conn)

        # Mock the POST request
        allow(mock_conn).to receive(:post) do |&block|
          req = double('request')
          allow(req).to receive(:url)
          allow(req).to receive(:headers).and_return({})
          allow(req).to receive(:body=)
          block.call(req)
        end

        server.post_jsonrpc_response(response)
        expect(server).to have_received(:create_json_rpc_connection).with('https://example.com:443')
      end

      it 'reuses existing connection' do
        # Set up existing connection
        mock_conn = instance_double(Faraday::Connection)
        server.instance_variable_set(:@rpc_conn, mock_conn)

        # Mock the POST request
        allow(mock_conn).to receive(:post) do |&block|
          req = double('request')
          allow(req).to receive(:url)
          allow(req).to receive(:headers).and_return({})
          allow(req).to receive(:body=)
          block.call(req)
        end

        server.post_jsonrpc_response(response)

        # Should not create new connection
        expect(server).not_to receive(:create_json_rpc_connection)
      end

      it 'sends POST request to RPC endpoint with headers' do
        mock_conn = instance_double(Faraday::Connection)
        server.instance_variable_set(:@rpc_conn, mock_conn)

        expect(mock_conn).to receive(:post) do |&block|
          req = double('request')
          req_headers = {}

          expect(req).to receive(:url).with('/messages')
          expect(req).to receive(:headers).at_least(:once).and_return(req_headers)
          expect(req).to receive(:body=).with(JSON.generate(response))

          block.call(req)

          # Verify headers were set
          expect(req_headers['Content-Type']).to eq('application/json')
          expect(req_headers['Authorization']).to eq('Bearer token123')
        end

        server.post_jsonrpc_response(response)
      end

      it 'logs successful response sending' do
        mock_conn = instance_double(Faraday::Connection)
        server.instance_variable_set(:@rpc_conn, mock_conn)

        allow(mock_conn).to receive(:post) do |&block|
          req = double('request')
          allow(req).to receive(:url)
          allow(req).to receive(:headers).and_return({})
          allow(req).to receive(:body=)
          block.call(req)
        end

        logger = server.instance_variable_get(:@logger)
        expect(logger).to receive(:debug).with(/Sent response via HTTP POST/)

        server.post_jsonrpc_response(response)
      end
    end
  end

  describe '#send_error_response' do
    let(:request_id) { 123 }
    let(:error_code) { -32_601 }
    let(:error_message) { 'Method not found' }

    before do
      server.instance_variable_set(:@rpc_endpoint, '/messages')
      allow(server).to receive(:ensure_initialized)
    end

    it 'sends JSON-RPC error response via HTTP POST' do
      expected_response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'error' => {
          'code' => error_code,
          'message' => error_message
        }
      }

      expect(server).to receive(:post_jsonrpc_response).with(expected_response)
      server.send_error_response(request_id, error_code, error_message)
    end
  end

  describe 'SSE parser integration with elicitation' do
    it 'detects server requests from SSE message events' do
      # Create an elicitation request message
      elicitation_request = {
        'id' => 456,
        'method' => 'elicitation/create',
        'params' => {
          'message' => 'Confirm action?',
          'requestedSchema' => {
            'type' => 'object',
            'properties' => {
              'confirmed' => { 'type' => 'boolean' }
            }
          }
        }
      }

      event_data = "event: message\ndata: #{elicitation_request.to_json}\n\n"

      # Expect the server to handle this as a server request
      expect(server).to receive(:handle_server_request).with(elicitation_request)

      server.send(:parse_and_handle_sse_event, event_data)
    end

    it 'distinguishes server requests from responses' do
      # Response (has id but no method) - should not trigger server request handler
      response = {
        'id' => 123,
        'result' => { 'success' => true }
      }

      event_data = "event: message\ndata: #{response.to_json}\n\n"

      # Should NOT call handle_server_request for responses
      expect(server).not_to receive(:handle_server_request)

      server.send(:parse_and_handle_sse_event, event_data)
    end

    it 'distinguishes server requests from notifications' do
      # Notification (has method but no id) - should not trigger server request handler
      notification = {
        'method' => 'notifications/test',
        'params' => { 'data' => 'value' }
      }

      event_data = "event: message\ndata: #{notification.to_json}\n\n"

      # Should NOT call handle_server_request for notifications
      expect(server).not_to receive(:handle_server_request)

      server.send(:parse_and_handle_sse_event, event_data)
    end
  end

  describe 'integration: full elicitation flow over SSE' do
    it 'handles complete request-response cycle via SSE + HTTP POST' do
      # Setup callback
      user_response = { 'action' => 'accept', 'content' => { 'name' => 'Alice' } }
      server.on_elicitation_request do |_req_id, params|
        expect(params['message']).to eq('Enter your name:')
        user_response
      end

      # Mock HTTP POST for response
      mock_conn = instance_double(Faraday::Connection)
      server.instance_variable_set(:@rpc_conn, mock_conn)

      posted_response = nil
      allow(mock_conn).to receive(:post) do |&block|
        req = double('request')
        allow(req).to receive(:url)
        allow(req).to receive(:headers).and_return({})
        expect(req).to receive(:body=) do |body|
          posted_response = JSON.parse(body)
        end
        block.call(req)
      end

      # Server sends elicitation request via SSE
      elicitation_request = {
        'id' => 456,
        'method' => 'elicitation/create',
        'params' => {
          'message' => 'Enter your name:',
          'requestedSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string' }
            }
          }
        }
      }

      event_data = "event: message\ndata: #{elicitation_request.to_json}\n\n"

      # Process the SSE event
      allow(server).to receive(:ensure_initialized)
      server.send(:parse_and_handle_sse_event, event_data)

      # Verify response was posted via HTTP
      expect(posted_response).not_to be_nil
      expect(posted_response['jsonrpc']).to eq('2.0')
      expect(posted_response['id']).to eq(456)
      expect(posted_response['result']).to eq(user_response)
    end
  end
end
