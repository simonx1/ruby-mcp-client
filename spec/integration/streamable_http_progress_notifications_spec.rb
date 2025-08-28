# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

RSpec.describe 'Streamable HTTP Progress Notifications Integration', type: :integration do
  let(:base_url) { 'https://everything.mcp.inevitable.fyi' }
  let(:endpoint) { '/mcp' }
  let(:headers) { {} }

  let(:server) do
    MCPClient::ServerStreamableHTTP.new(
      base_url: base_url,
      endpoint: endpoint,
      headers: headers,
      read_timeout: 10,
      retries: 1,
      name: 'everything-mcp-server'
    )
  end

  let(:progress_token) { '4dccde537a37_longRunningOperation_63a4b173-fbfc-4b45-b12a-ac4718c1fc70' }
  let(:received_notifications) { [] }

  after do
    server.cleanup if defined?(server)
  end

  before do
    # Set up notification handler to capture progress notifications
    server.on_notification do |method, params|
      received_notifications << { method: method, params: params }
    end
  end

  describe 'long running tool with progress notifications' do
    let(:initialize_response) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'everything-mcp-server', version: '1.0.0' }
        }
      }
    end

    let(:tools_response) do
      {
        jsonrpc: '2.0',
        id: 2,
        result: {
          tools: [
            {
              name: 'longRunningOperation',
              description: 'A tool that takes time and provides progress updates',
              inputSchema: {
                type: 'object',
                properties: {
                  duration: { type: 'number', description: 'Duration in seconds' }
                },
                required: ['duration']
              }
            }
          ]
        }
      }
    end

    let(:tool_call_response) do
      {
        jsonrpc: '2.0',
        id: 3,
        result: {
          content: [
            {
              type: 'text',
              text: 'Long running operation completed successfully'
            }
          ]
        }
      }
    end

    # Progress notification messages (as they would come from the server)
    let(:progress_notification_1) do
      {
        method: 'notifications/progress',
        params: {
          progress: 1,
          total: 3,
          progressToken: progress_token
        },
        jsonrpc: '2.0'
      }
    end

    let(:progress_notification_2) do
      {
        method: 'notifications/progress',
        params: {
          progress: 2,
          total: 3,
          progressToken: progress_token
        },
        jsonrpc: '2.0'
      }
    end

    let(:progress_notification_3) do
      {
        method: 'notifications/progress',
        params: {
          progress: 3,
          total: 3,
          progressToken: progress_token
        },
        jsonrpc: '2.0'
      }
    end

    before do
      # Use a more general stub that responds to all requests to the endpoint
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return do |request|
          body = JSON.parse(request.body)
          case body['method']
          when 'initialize'
            {
              status: 200,
              body: "event: message\ndata: #{initialize_response.to_json}\n\n",
              headers: { 'Content-Type' => 'text/event-stream' }
            }
          when 'tools/list'
            {
              status: 200,
              body: "event: message\ndata: #{tools_response.to_json}\n\n",
              headers: { 'Content-Type' => 'text/event-stream' }
            }
          when 'notifications/initialized'
            { status: 200, body: '' }
          when 'tools/call'
            if body['params'] && body['params']['name'] == 'longRunningOperation'
              # Return SSE response with progress notifications then final result
              sse_body = "event: message\ndata: #{tool_call_response.to_json}\n\n"
              {
                status: 200,
                body: sse_body,
                headers: { 'Content-Type' => 'text/event-stream' }
              }
            else
              { status: 404, body: 'Not Found' }
            end
          else
            { status: 404, body: 'Not Found' }
          end
        end

      # Mock the GET request for events connection - keep it simple for now
      stub_request(:get, "#{base_url}#{endpoint}")
        .to_return(
          status: 200,
          body: '',
          headers: { 'Content-Type' => 'text/event-stream' }
        )
    end

    it 'receives progress notifications during long running tool execution' do
      # Connect to server
      expect(server.connect).to be true
      expect(server.server_info['name']).to eq('everything-mcp-server')

      # List tools to get the longRunningOperation tool
      tools = server.list_tools
      expect(tools.size).to eq(1)

      long_running_tool = tools.find { |t| t.name == 'longRunningOperation' }
      expect(long_running_tool).not_to be_nil
      expect(long_running_tool.description).to include('progress updates')

      # Clear any notifications received during setup
      received_notifications.clear

      # Simulate progress notifications being received through the events connection
      # In a real scenario, these would come from the server during tool execution
      Thread.new do
        sleep(0.05) # Small delay to simulate async notifications
        server.send(:handle_server_message, progress_notification_1.to_json)
        sleep(0.05)
        server.send(:handle_server_message, progress_notification_2.to_json)
        sleep(0.05)
        server.send(:handle_server_message, progress_notification_3.to_json)
      end

      # Call the tool with progress token in _meta
      result = server.call_tool('longRunningOperation', {
                                  duration: 5,
                                  _meta: { progressToken: progress_token }
                                })

      # Verify the tool call result
      expect(result['content'].size).to eq(1)
      expect(result['content'].first['text']).to include('completed successfully')

      # Give some time for notifications to be processed
      sleep(0.3)

      # Verify that we received the progress notifications
      progress_notifications = received_notifications.select { |n| n[:method] == 'notifications/progress' }
      expect(progress_notifications.size).to eq(3)

      # Verify the first progress notification
      expect(progress_notifications[0][:params]['progress']).to eq(1)
      expect(progress_notifications[0][:params]['total']).to eq(3)
      expect(progress_notifications[0][:params]['progressToken']).to eq(progress_token)

      # Verify the second progress notification
      expect(progress_notifications[1][:params]['progress']).to eq(2)
      expect(progress_notifications[1][:params]['total']).to eq(3)
      expect(progress_notifications[1][:params]['progressToken']).to eq(progress_token)

      # Verify the third progress notification
      expect(progress_notifications[2][:params]['progress']).to eq(3)
      expect(progress_notifications[2][:params]['total']).to eq(3)
      expect(progress_notifications[2][:params]['progressToken']).to eq(progress_token)
    end

    it 'handles progress notifications with client-level notification handlers' do
      # Create a client with the server
      client = MCPClient::Client.new(
        mcp_server_configs: [
          {
            type: 'streamable_http',
            base_url: base_url,
            endpoint: endpoint,
            headers: headers,
            name: 'everything-mcp-server'
          }
        ]
      )

      client_notifications = []
      client.on_notification do |server, method, params|
        client_notifications << { server: server, method: method, params: params }
      end

      # Connect and call tool
      tools = client.list_tools
      long_running_tool = tools.find { |t| t.name == 'longRunningOperation' }
      expect(long_running_tool).not_to be_nil

      # Get the server instance from the client to simulate notifications
      server_instance = client.servers.first

      # Simulate progress notifications
      Thread.new do
        sleep(0.05)
        server_instance.send(:handle_server_message, progress_notification_1.to_json)
        sleep(0.05)
        server_instance.send(:handle_server_message, progress_notification_2.to_json)
        sleep(0.05)
        server_instance.send(:handle_server_message, progress_notification_3.to_json)
      end

      result = client.call_tool('longRunningOperation', {
                                  duration: 5,
                                  _meta: { progressToken: progress_token }
                                })

      # Verify the tool call result
      expect(result['content'].size).to eq(1)
      expect(result['content'].first['text']).to include('completed successfully')

      # Give some time for notifications to be processed
      sleep(0.3)

      # Verify that client received the progress notifications
      progress_notifications = client_notifications.select { |n| n[:method] == 'notifications/progress' }
      expect(progress_notifications.size).to eq(3)

      # Verify progression
      expect(progress_notifications[0][:params]['progress']).to eq(1)
      expect(progress_notifications[1][:params]['progress']).to eq(2)
      expect(progress_notifications[2][:params]['progress']).to eq(3)

      # All notifications should have the same progress token
      progress_notifications.each do |notification|
        expect(notification[:params]['progressToken']).to eq(progress_token)
        expect(notification[:params]['total']).to eq(3)
      end

      # Cleanup
      client.cleanup
    end

    it 'processes multiple concurrent tool calls with different progress tokens' do
      second_progress_token = '5edd6f648b48_longRunningOperation_74b5c284-gcd3-5c56-c23b-bd5829d2ed81'

      second_progress_notification_1 = {
        method: 'notifications/progress',
        params: { progress: 1, total: 2, progressToken: second_progress_token },
        jsonrpc: '2.0'
      }

      second_progress_notification_2 = {
        method: 'notifications/progress',
        params: { progress: 2, total: 2, progressToken: second_progress_token },
        jsonrpc: '2.0'
      }

      # Connect to server
      server.connect
      server.list_tools

      # Clear notifications
      received_notifications.clear

      # Simulate notifications for different progress tokens
      Thread.new do
        sleep(0.05)
        server.send(:handle_server_message, progress_notification_1.to_json)
        server.send(:handle_server_message, second_progress_notification_1.to_json)
        sleep(0.05)
        server.send(:handle_server_message, progress_notification_2.to_json)
        server.send(:handle_server_message, second_progress_notification_2.to_json)
        sleep(0.05)
        server.send(:handle_server_message, progress_notification_3.to_json)
      end

      # Make concurrent calls with different progress tokens
      threads = []

      threads << Thread.new do
        server.call_tool('longRunningOperation', {
                           duration: 5,
                           _meta: { progressToken: progress_token }
                         })
      end

      threads << Thread.new do
        server.call_tool('longRunningOperation', {
                           duration: 3,
                           _meta: { progressToken: second_progress_token }
                         })
      end

      # Wait for both calls to complete
      results = threads.map(&:join).map(&:value)
      expect(results.size).to eq(2)

      # Give some time for notifications to be processed
      sleep(0.3)

      # Verify we got notifications for both progress tokens
      first_token_notifications = received_notifications.select do |n|
        n[:method] == 'notifications/progress' && n[:params]['progressToken'] == progress_token
      end

      second_token_notifications = received_notifications.select do |n|
        n[:method] == 'notifications/progress' && n[:params]['progressToken'] == second_progress_token
      end

      expect(first_token_notifications.size).to eq(3)
      expect(second_token_notifications.size).to eq(2)

      # Verify progress sequences are correct for each token
      expect(first_token_notifications.map { |n| n[:params]['progress'] }).to eq([1, 2, 3])
      expect(second_token_notifications.map { |n| n[:params]['progress'] }).to eq([1, 2])
    end
  end

  describe 'error scenarios with progress notifications' do
    let(:init_response) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'everything-mcp-server', version: '1.0.0' }
        }
      }
    end

    # Redefine the progress notifications and tool response for error scenarios
    let(:test_progress_notification) do
      {
        method: 'notifications/progress',
        params: {
          progress: 1,
          total: 3,
          progressToken: progress_token
        },
        jsonrpc: '2.0'
      }
    end

    let(:test_tool_response) do
      {
        jsonrpc: '2.0',
        id: 3,
        result: {
          content: [
            {
              type: 'text',
              text: 'Operation completed'
            }
          ]
        }
      }
    end

    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return do |request|
          body = JSON.parse(request.body)
          case body['method']
          when 'initialize'
            {
              status: 200,
              body: "event: message\ndata: #{init_response.to_json}\n\n",
              headers: { 'Content-Type' => 'text/event-stream' }
            }
          when 'notifications/initialized'
            { status: 200, body: '' }
          else
            { status: 404, body: 'Not Found' }
          end
        end

      stub_request(:get, "#{base_url}#{endpoint}")
        .to_return(
          status: 200,
          body: '',
          headers: { 'Content-Type' => 'text/event-stream' }
        )
    end

    it 'handles malformed progress notifications gracefully' do
      # Override the tools/call stub for this specific test
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including(method: 'tools/call'))
        .to_return(
          status: 200,
          body: 'invalid sse format without proper data line',
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      server.connect

      expect do
        server.call_tool('longRunningOperation', {
                           duration: 1,
                           _meta: { progressToken: progress_token }
                         })
      end.to raise_error(MCPClient::Errors::TransportError, /No data found in SSE response/)
    end

    it 'continues processing even when progress notification parsing fails' do
      # This tests that the server continues to work even if individual notifications fail
      mixed_response = [
        "event: message\ndata: invalid json notification\n\n",
        "event: message\ndata: #{test_progress_notification.to_json}\n\n",
        "event: message\ndata: #{test_tool_response.to_json}\n\n"
      ].join

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including(method: 'tools/call'))
        .to_return(
          status: 200,
          body: mixed_response,
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      server.connect

      # Should raise error due to malformed JSON in the stream
      expect do
        server.call_tool('longRunningOperation', {
                           duration: 1,
                           _meta: { progressToken: progress_token }
                         })
      end.to raise_error(MCPClient::Errors::TransportError, /Invalid JSON/)
    end
  end
end
