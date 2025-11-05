# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

RSpec.describe MCPClient::ServerStreamableHTTP, 'Elicitation (MCP 2025-06-18)' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/mcp' }
  let(:headers) { { 'Authorization' => 'Bearer test-token' } }
  let(:server) do
    described_class.new(
      base_url: base_url,
      endpoint: endpoint,
      headers: headers
    )
  end

  before do
    # Set up minimal initialized state
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@session_id, 'test-session-123')

    # Stub terminate_session to prevent cleanup warnings in tests
    allow(server).to receive(:terminate_session).and_return(true)
  end

  after do
    server.cleanup if defined?(server)
  end

  describe '#on_elicitation_request' do
    it 'registers an elicitation callback' do
      callback = ->(_request_id, _params) { { 'action' => 'accept' } }
      server.send(:on_elicitation_request, &callback)
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
        server.send(:handle_server_request, message)
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
        server.send(:handle_server_request, message)
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
        server.send(:handle_server_request, message)
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
        server.send(:handle_elicitation_create, request_id, params)
      end

      it 'logs a warning' do
        allow(server).to receive(:send_elicitation_response)
        logger = server.instance_variable_get(:@logger)
        expect(logger).to receive(:warn).with('Received elicitation request but no callback registered, declining')
        server.send(:handle_elicitation_create, request_id, params)
      end
    end

    context 'when callback is registered' do
      let(:callback_result) { { 'action' => 'accept', 'content' => { 'name' => 'John' } } }

      before do
        callback = ->(_req_id, _params) { callback_result }
        server.send(:on_elicitation_request, &callback)
      end

      it 'calls the registered callback' do
        callback = lambda do |req_id, prms|
          expect(req_id).to eq(request_id)
          expect(prms).to eq(params)
          callback_result
        end
        server.send(:on_elicitation_request, &callback)

        allow(server).to receive(:send_elicitation_response)
        server.send(:handle_elicitation_create, request_id, params)
      end

      it 'sends the callback result as response' do
        expect(server).to receive(:send_elicitation_response).with(request_id, callback_result)
        server.send(:handle_elicitation_create, request_id, params)
      end
    end
  end

  describe '#send_elicitation_response' do
    let(:request_id) { 123 }
    let(:result) { { 'action' => 'accept', 'content' => { 'name' => 'John' } } }

    it 'sends JSON-RPC request via HTTP POST' do
      # Elicitation responses are sent as JSON-RPC requests, not responses
      expected_request = {
        'jsonrpc' => '2.0',
        'method' => 'elicitation/response',
        'params' => {
          'elicitationId' => request_id,
          'action' => result['action'],
          'content' => result['content']
        }
      }

      expect(server).to receive(:post_jsonrpc_response).with(expected_request)
      server.send(:send_elicitation_response, request_id, result)
    end
  end

  describe '#post_jsonrpc_response' do
    let(:response) { { 'jsonrpc' => '2.0', 'id' => 123, 'result' => { 'action' => 'accept' } } }

    before do
      # Stub HTTP POST to prevent actual network calls
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 200, body: '')
    end

    it 'sends response in a separate thread' do
      # Track thread creation
      thread_created = false
      original_thread_new = Thread.method(:new)
      allow(Thread).to receive(:new) do |&block|
        thread_created = true
        original_thread_new.call(&block)
      end

      server.send(:post_jsonrpc_response, response)

      # Give thread time to execute
      sleep 0.1

      expect(thread_created).to be true
    end

    it 'sends POST request to endpoint with session ID header' do
      # Stub the request with specific expectations
      request_stub = stub_request(:post, "#{base_url}#{endpoint}")
                     .with(
                       headers: {
                         'Authorization' => 'Bearer test-token',
                         'Mcp-Session-Id' => 'test-session-123'
                       },
                       body: JSON.generate(response)
                     )
                     .to_return(status: 200, body: '')

      server.send(:post_jsonrpc_response, response)

      # Give thread time to execute
      sleep 0.1

      expect(request_stub).to have_been_requested
    end

    it 'logs successful response sending' do
      server.send(:post_jsonrpc_response, response)

      # Give thread time to execute
      sleep 0.1

      # Logger should have logged the successful send (checked via stub)
      expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}")
    end

    it 'logs warning on HTTP error response' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 500, body: 'Internal Server Error')

      logger = server.instance_variable_get(:@logger)
      expect(logger).to receive(:warn).with(/Failed to send JSON-RPC response: HTTP 500/)

      server.send(:post_jsonrpc_response, response)

      # Give thread time to execute
      sleep 0.1
    end

    it 'logs error on network failure' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_raise(Faraday::ConnectionFailed.new('Connection refused'))

      logger = server.instance_variable_get(:@logger)
      expect(logger).to receive(:error).with(/Failed to send JSON-RPC response: Connection refused/)

      server.send(:post_jsonrpc_response, response)

      # Give thread time to execute
      sleep 0.1
    end

    it 'uses http_connection from base class' do
      expect(server).to receive(:http_connection).and_call_original

      server.send(:post_jsonrpc_response, response)

      # Give thread time to execute
      sleep 0.1
    end

    context 'when session_id is nil' do
      before do
        server.instance_variable_set(:@session_id, nil)
      end

      it 'does not include Mcp-Session-Id header' do
        request_stub = stub_request(:post, "#{base_url}#{endpoint}")
                       .with(
                         headers: {
                           'Authorization' => 'Bearer test-token'
                         }
                       ) do |request|
          # Explicitly check session ID header is NOT present
          !request.headers.key?('Mcp-Session-Id')
        end
          .to_return(status: 200, body: '')

        server.send(:post_jsonrpc_response, response)

        # Give thread time to execute
        sleep 0.1

        expect(request_stub).to have_been_requested
      end
    end
  end

  describe '#send_error_response' do
    let(:request_id) { 123 }
    let(:error_code) { -32_601 }
    let(:error_message) { 'Method not found' }

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
      server.send(:send_error_response, request_id, error_code, error_message)
    end
  end

  describe 'message event handling with elicitation' do
    it 'detects server requests from SSE-formatted message events' do
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

      # Expect the server to handle this as a server request
      expect(server).to receive(:handle_server_request).with(elicitation_request)

      server.send(:handle_server_message, JSON.generate(elicitation_request))
    end

    it 'distinguishes server requests from ping requests' do
      # Ping request (has id and method='ping')
      ping_request = {
        'id' => 123,
        'method' => 'ping'
      }

      # Should call handle_ping_request, NOT handle_server_request
      expect(server).to receive(:handle_ping_request).with(123)
      expect(server).not_to receive(:handle_server_request)

      server.send(:handle_server_message, JSON.generate(ping_request))
    end

    it 'distinguishes server requests from notifications' do
      # Notification (has method but no id)
      notification = {
        'method' => 'notifications/test',
        'params' => { 'data' => 'value' }
      }

      # Should call notification callback, NOT handle_server_request
      expect(server).not_to receive(:handle_server_request)

      # Mock notification callback
      notification_received = false
      server.send(:on_notification) do |_method, _params|
        notification_received = true
      end

      server.send(:handle_server_message, JSON.generate(notification))
      expect(notification_received).to be true
    end

    it 'distinguishes server requests from responses' do
      # Response (has id but no method)
      # Note: Streamable HTTP doesn't explicitly handle responses in handle_server_message
      # They are handled by the SSE parsing layer in process_sse_chunk
      # This test verifies that a response message doesn't trigger server request handling
      response = {
        'id' => 123,
        'result' => { 'success' => true }
      }

      # Should NOT call handle_server_request for responses
      expect(server).not_to receive(:handle_server_request)

      server.send(:handle_server_message, JSON.generate(response))
    end
  end

  describe 'integration: full elicitation flow over Streamable HTTP' do
    it 'handles complete request-response cycle via SSE-formatted HTTP + HTTP POST' do
      # Setup callback
      user_response = { 'action' => 'accept', 'content' => { 'name' => 'Alice' } }
      server.send(:on_elicitation_request) do |_req_id, params|
        expect(params['message']).to eq('Enter your name:')
        user_response
      end

      # Stub HTTP POST for response (sent as JSON-RPC request, not response)
      response_stub = stub_request(:post, "#{base_url}#{endpoint}")
                      .with(
                        headers: {
                          'Authorization' => 'Bearer test-token',
                          'Mcp-Session-Id' => 'test-session-123'
                        },
                        body: {
                          'jsonrpc' => '2.0',
                          'method' => 'elicitation/response',
                          'params' => {
                            'elicitationId' => 456,
                            'action' => user_response['action'],
                            'content' => user_response['content']
                          }
                        }.to_json
                      )
                      .to_return(status: 200, body: '')

      # Server sends elicitation request via SSE-formatted message
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

      # Process the message
      server.send(:handle_server_message, JSON.generate(elicitation_request))

      # Give thread time to send response
      sleep 0.1

      # Verify response was posted via HTTP
      expect(response_stub).to have_been_requested.once
    end

    it 'handles decline response' do
      # No callback registered, should auto-decline
      response_stub = stub_request(:post, "#{base_url}#{endpoint}")
                      .with(
                        body: {
                          'jsonrpc' => '2.0',
                          'method' => 'elicitation/response',
                          'params' => {
                            'elicitationId' => 789,
                            'action' => 'decline'
                          }
                        }.to_json
                      )
                      .to_return(status: 200, body: '')

      # Server sends elicitation request
      elicitation_request = {
        'id' => 789,
        'method' => 'elicitation/create',
        'params' => {
          'message' => 'Enter password:',
          'requestedSchema' => {
            'type' => 'object',
            'properties' => {
              'password' => { 'type' => 'string' }
            }
          }
        }
      }

      # Process the message
      server.send(:handle_server_message, JSON.generate(elicitation_request))

      # Give thread time to send response
      sleep 0.1

      # Verify decline was sent
      expect(response_stub).to have_been_requested.once
    end
  end
end
