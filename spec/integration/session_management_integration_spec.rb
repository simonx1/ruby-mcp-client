# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

RSpec.describe 'Session Management Integration', type: :integration do
  include WebMock::API

  let(:base_url) { 'https://api.example.com' }
  let(:endpoint) { '/mcp' }
  let(:session_id) { 'session_abc123_def456' }
  let(:event_id) { 'event_789_xyz' }

  describe 'HTTP Transport Session Lifecycle' do
    let(:http_server) do
      MCPClient::ServerHTTP.new(
        base_url: base_url,
        endpoint: endpoint,
        headers: { 'Authorization' => 'Bearer test-token' }
      )
    end

    context 'complete session lifecycle' do
      it 'handles initialization, requests, and termination' do
        # Step 1: Initialize with session ID capture
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            body: hash_including(method: 'initialize'),
            headers: { 'Authorization' => 'Bearer test-token' }
          )
          .to_return(
            status: 200,
            body: {
              jsonrpc: '2.0',
              id: 1,
              result: {
                protocolVersion: '2024-11-05',
                capabilities: { tools: {} },
                serverInfo: { name: 'test-server', version: '1.0.0' }
              }
            }.to_json,
            headers: { 'Mcp-Session-Id' => session_id }
          )

        # Step 2: Tools list request with session header
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            body: hash_including(method: 'tools/list'),
            headers: {
              'Mcp-Session-Id' => session_id,
              'Authorization' => 'Bearer test-token'
            }
          )
          .to_return(
            status: 200,
            body: {
              jsonrpc: '2.0',
              id: 2,
              result: { tools: [] }
            }.to_json
          )

        # Step 3: Tool call with session header
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            body: hash_including(method: 'tools/call'),
            headers: {
              'Mcp-Session-Id' => session_id,
              'Authorization' => 'Bearer test-token'
            }
          )
          .to_return(
            status: 200,
            body: {
              jsonrpc: '2.0',
              id: 3,
              result: { content: [{ type: 'text', text: 'Success' }] }
            }.to_json
          )

        # Step 4: Session termination
        stub_request(:delete, "#{base_url}#{endpoint}")
          .with(
            headers: {
              'Mcp-Session-Id' => session_id,
              'Authorization' => 'Bearer test-token'
            }
          )
          .to_return(status: 200, body: '')

        # Execute the complete lifecycle
        expect(http_server.connect).to be true
        expect(http_server.instance_variable_get(:@session_id)).to eq(session_id)

        tools = http_server.list_tools
        expect(tools).to eq([])

        result = http_server.call_tool('test_tool', { param: 'value' })
        expect(result).to eq({ 'content' => [{ 'type' => 'text', 'text' => 'Success' }] })

        expect(http_server.terminate_session).to be true
        expect(http_server.instance_variable_get(:@session_id)).to be_nil

        # Verify all expected requests were made
        expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}").times(3)
        expect(WebMock).to have_requested(:delete, "#{base_url}#{endpoint}").once
      end

      it 'handles session-less operation for stateless servers' do
        # Initialize without session ID
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: {
              jsonrpc: '2.0',
              id: 1,
              result: { protocolVersion: '2024-11-05', capabilities: {}, serverInfo: {} }
            }.to_json,
            headers: {} # No session ID provided
          )

        # Tools list without session header
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            body: hash_including(method: 'tools/list'),
            headers: { 'Authorization' => 'Bearer test-token' }
          )
          .to_return(
            status: 200,
            body: { jsonrpc: '2.0', id: 2, result: { tools: [] } }.to_json
          )

        expect(http_server.connect).to be true
        expect(http_server.instance_variable_get(:@session_id)).to be_nil

        tools = http_server.list_tools
        expect(tools).to eq([])

        # Cleanup should not attempt termination
        http_server.cleanup
        expect(WebMock).not_to have_requested(:delete, "#{base_url}#{endpoint}")
      end

      it 'handles invalid session ID rejection' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: { jsonrpc: '2.0', id: 1, result: {} }.to_json,
            headers: { 'Mcp-Session-Id' => 'invalid@session!' } # Invalid format
          )

        expect(http_server.connect).to be true
        expect(http_server.instance_variable_get(:@session_id)).to be_nil
      end
    end

    context 'error scenarios' do
      it 'handles session termination failure gracefully' do
        http_server.instance_variable_set(:@session_id, session_id)

        stub_request(:delete, "#{base_url}#{endpoint}")
          .with(headers: { 'Mcp-Session-Id' => session_id })
          .to_return(status: 500, body: 'Internal Server Error')

        expect(http_server.terminate_session).to be false
        expect(http_server.instance_variable_get(:@session_id)).to be_nil
      end

      it 'clears session ID on termination network error' do
        http_server.instance_variable_set(:@session_id, session_id)

        stub_request(:delete, "#{base_url}#{endpoint}")
          .to_raise(Faraday::ConnectionFailed.new('Connection lost'))

        expect(http_server.terminate_session).to be false
        expect(http_server.instance_variable_get(:@session_id)).to be_nil
      end
    end
  end

  describe 'Streamable HTTP Transport Session and Resumability Lifecycle' do
    let(:streamable_server) do
      MCPClient::ServerStreamableHTTP.new(
        base_url: base_url,
        endpoint: endpoint,
        headers: { 'Authorization' => 'Bearer test-token' }
      )
    end

    context 'complete session and resumability lifecycle' do
      it 'handles session management and event ID tracking' do
        # Step 1: Initialize with session ID capture
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: "event: message\nid: #{event_id}-init\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
            headers: {
              'Mcp-Session-Id' => session_id,
              'Content-Type' => 'text/event-stream'
            }
          )

        # Step 2: Tools list with session and Last-Event-ID headers
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            body: hash_including(method: 'tools/list'),
            headers: {
              'Mcp-Session-Id' => session_id,
              'Last-Event-ID' => "#{event_id}-init"
            }
          )
          .to_return(
            status: 200,
            body: "event: message\nid: #{event_id}-tools\n" \
                  "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        # Step 3: Tool call with updated headers
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            body: hash_including(method: 'tools/call'),
            headers: {
              'Mcp-Session-Id' => session_id,
              'Last-Event-ID' => "#{event_id}-tools"
            }
          )
          .to_return(
            status: 200,
            body: "event: message\nid: #{event_id}-call\n" \
                  "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        # Step 4: Session termination
        stub_request(:delete, "#{base_url}#{endpoint}")
          .with(headers: { 'Mcp-Session-Id' => session_id })
          .to_return(status: 200, body: '')

        # Execute the complete lifecycle
        expect(streamable_server.connect).to be true
        expect(streamable_server.instance_variable_get(:@session_id)).to eq(session_id)
        expect(streamable_server.instance_variable_get(:@last_event_id)).to eq("#{event_id}-init")

        tools = streamable_server.list_tools
        expect(tools).to eq([])
        expect(streamable_server.instance_variable_get(:@last_event_id)).to eq("#{event_id}-tools")

        result = streamable_server.call_tool('test_tool', { param: 'value' })
        expect(result).to eq({ 'content' => [] })
        expect(streamable_server.instance_variable_get(:@last_event_id)).to eq("#{event_id}-call")

        expect(streamable_server.terminate_session).to be true
        expect(streamable_server.instance_variable_get(:@session_id)).to be_nil

        # Verify all expected requests were made with correct headers
        expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}").times(3)
        expect(WebMock).to have_requested(:delete, "#{base_url}#{endpoint}").once
      end

      it 'handles complex SSE responses with event tracking' do
        complex_sse_response = <<~SSE
          event: message
          id: complex-event-123
          retry: 1000
          data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}

        SSE

        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'tools/list'))
          .to_return(
            status: 200,
            body: complex_sse_response,
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        streamable_server.instance_variable_set(:@connection_established, true)
        streamable_server.instance_variable_set(:@initialized, true)

        result = streamable_server.send(:request_tools_list)
        expect(result).to eq([])
        expect(streamable_server.instance_variable_get(:@last_event_id)).to eq('complex-event-123')
      end

      it 'handles SSE responses without event IDs' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'tools/list'))
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        streamable_server.instance_variable_set(:@connection_established, true)
        streamable_server.instance_variable_set(:@initialized, true)

        result = streamable_server.send(:request_tools_list)
        expect(result).to eq([])
        expect(streamable_server.instance_variable_get(:@last_event_id)).to be_nil
      end

      it 'handles regular JSON responses correctly' do
        json_response = '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}'

        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: json_response,
            headers: { 'Content-Type' => 'application/json' }
          )

        streamable_server.instance_variable_set(:@connection_established, true)
        streamable_server.instance_variable_set(:@initialized, true)

        result = streamable_server.send(:request_tools_list)
        expect(result).to eq([])
        expect(streamable_server.instance_variable_get(:@last_event_id)).to be_nil # No event ID in JSON response
      end

      it 'handles SSE responses with event tracking' do
        sse_response = <<~SSE
          event: message
          id: sse-event-456
          data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}

        SSE

        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: sse_response,
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        streamable_server.instance_variable_set(:@connection_established, true)
        streamable_server.instance_variable_set(:@initialized, true)

        result = streamable_server.send(:request_tools_list)
        expect(result).to eq([])
        expect(streamable_server.instance_variable_get(:@last_event_id)).to eq('sse-event-456')
      end
    end

    context 'resumability scenarios' do
      it 'continues from last event ID after reconnection' do
        # Set up state as if we had a previous session
        streamable_server.instance_variable_set(:@session_id, session_id)
        streamable_server.instance_variable_set(:@last_event_id, 'previous-event-123')
        streamable_server.instance_variable_set(:@connection_established, true)
        streamable_server.instance_variable_set(:@initialized, true)

        # Server should replay from the last event ID
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            headers: {
              'Mcp-Session-Id' => session_id,
              'Last-Event-ID' => 'previous-event-123'
            }
          )
          .to_return(
            status: 200,
            body: "event: message\nid: resumed-event-124\n" \
                  "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        result = streamable_server.send(:request_tools_list)
        expect(result).to eq([])
        expect(streamable_server.instance_variable_get(:@last_event_id)).to eq('resumed-event-124')
      end
    end
  end

  describe 'Security Validation Integration' do
    context 'URL validation' do
      it 'prevents initialization with malicious URLs' do
        expect do
          MCPClient::ServerHTTP.new(base_url: 'javascript:alert(1)')
        end.to raise_error(ArgumentError, /Invalid or insecure server URL/)

        expect do
          MCPClient::ServerStreamableHTTP.new(base_url: 'ftp://malicious.com')
        end.to raise_error(ArgumentError, /Invalid or insecure server URL/)
      end
    end

    context 'session ID validation' do
      let(:http_server) { MCPClient::ServerHTTP.new(base_url: base_url) }

      before do
        http_server.instance_variable_set(:@connection_established, true)
        http_server.instance_variable_set(:@initialized, true)
      end

      it 'accepts only valid session ID formats' do
        # Valid format should be accepted
        stub_request(:post, "#{base_url}/rpc")
          .to_return(
            status: 200,
            body: { jsonrpc: '2.0', id: 1, result: {} }.to_json,
            headers: { 'Mcp-Session-Id' => 'valid_session-123_abc' }
          )

        http_server.send(:perform_initialize)
        expect(http_server.instance_variable_get(:@session_id)).to eq('valid_session-123_abc')

        # Invalid format should be rejected
        stub_request(:post, "#{base_url}/rpc")
          .to_return(
            status: 200,
            body: { jsonrpc: '2.0', id: 2, result: {} }.to_json,
            headers: { 'Mcp-Session-Id' => 'invalid@session!' }
          )

        http_server.send(:perform_initialize)
        expect(http_server.instance_variable_get(:@session_id)).to eq('valid_session-123_abc') # Unchanged
      end
    end
  end

  describe 'Error Recovery and Robustness' do
    let(:http_server) { MCPClient::ServerHTTP.new(base_url: base_url) }

    it 'maintains state consistency during partial failures' do
      http_server.instance_variable_set(:@session_id, session_id)

      # Termination fails, but session ID should still be cleared
      stub_request(:delete, "#{base_url}/rpc")
        .to_raise(Faraday::TimeoutError.new('Timeout'))

      expect(http_server.terminate_session).to be false
      expect(http_server.instance_variable_get(:@session_id)).to be_nil
    end

    it 'handles cleanup gracefully even with multiple errors' do
      http_server.instance_variable_set(:@session_id, session_id)

      # Even if termination fails, cleanup should complete
      stub_request(:delete, "#{base_url}/rpc")
        .to_return(status: 500, body: 'Server Error')

      expect { http_server.cleanup }.not_to raise_error
      expect(http_server.instance_variable_get(:@session_id)).to be_nil
      expect(http_server.instance_variable_get(:@connection_established)).to be false
    end
  end
end
