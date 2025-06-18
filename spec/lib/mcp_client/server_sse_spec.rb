# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

RSpec.describe MCPClient::ServerSSE do
  let(:base_url) { 'https://example.com/mcp' }
  let(:headers) { { 'Authorization' => 'Bearer token123' } }
  let(:server) { described_class.new(base_url: base_url, headers: headers) }

  describe 'disconnected server handling' do
    it 'correctly handles connection refused errors in send_jsonrpc_request' do
      # Setup
      URI.parse(base_url)
      server.instance_variable_set(:@rpc_endpoint, '/messages')

      # Simulate a connection refused error
      error_msg = 'Failed to open TCP connection to localhost:3000 (Connection refused)'
      connection_error = Faraday::ConnectionFailed.new(error_msg)
      allow_any_instance_of(Faraday::Connection).to receive(:post).and_raise(connection_error)

      # Should raise a ConnectionError
      expect do
        server.send(:send_jsonrpc_request, { id: 1, jsonrpc: '2.0', method: 'test' })
      end.to raise_error(MCPClient::Errors::ConnectionError, /Server connection lost/)
    end

    it 'propagates connection errors from call_tool' do
      # Setup - ensure the server appears initialized and connected
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)

      # Also disable reconnect attempts
      allow(server).to receive(:connect).and_return(true)

      # Simulate connection error in the send_jsonrpc_request method
      allow(server).to receive(:send_jsonrpc_request).and_raise(
        MCPClient::Errors::ConnectionError.new('Server connection lost: Connection refused')
      )

      # Should preserve the ConnectionError
      expect do
        server.call_tool('TestTool', {})
      end.to raise_error(MCPClient::Errors::ConnectionError, /Server connection lost/)
    end
  end
  let(:tool_data) do
    {
      'name' => 'test_tool',
      'description' => 'A test tool',
      'parameters' => {
        'type' => 'object',
        'required' => ['foo'],
        'properties' => {
          'foo' => { 'type' => 'string' }
        }
      }
    }
  end

  describe '#initialize' do
    it 'normalizes the base_url without a trailing slash' do
      expect(server.base_url).to eq('https://example.com/mcp')
    end

    it 'handles base_url that already has trailing slash' do
      server = described_class.new(base_url: 'https://example.com/mcp/')
      expect(server.base_url).to eq('https://example.com/mcp')
    end

    it 'initializes auth_error to nil' do
      expect(server.instance_variable_get(:@auth_error)).to be_nil
    end

    it 'sets default ping interval to 10 seconds' do
      expect(server.instance_variable_get(:@ping_interval)).to eq(10)
    end

    it 'sets default close_after to 25 seconds' do
      expect(server.instance_variable_get(:@close_after)).to eq(25)
    end

    it 'accepts custom ping interval' do
      custom_server = described_class.new(base_url: base_url, ping: 30)
      expect(custom_server.instance_variable_get(:@ping_interval)).to eq(30)
    end

    it 'calculates close_after based on ping value' do
      custom_server = described_class.new(base_url: base_url, ping: 20)
      expected_close_after = (20 * MCPClient::ServerSSE::CLOSE_AFTER_PING_RATIO).to_i
      expect(custom_server.instance_variable_get(:@close_after)).to eq(expected_close_after)
    end
  end

  describe '#connect' do
    it 'creates a Faraday connection for the given URL' do
      # Mock the thread creation to prevent actual connection attempts
      expect(Thread).to receive(:new).and_return(double('thread', alive?: true))

      # Stub the condition variable to simulate a successful connection
      allow_any_instance_of(MonitorMixin::ConditionVariable).to receive(:wait) do |_timeout, &block|
        server.instance_variable_set(:@connection_established, true)
        block.call
      end

      # Expect the activity monitor to be started
      expect(server).to receive(:start_activity_monitor)

      expect(server.connect).to eq true
    end

    it 'handles HTTPS URLs appropriately' do
      # Skip the actual connection creation by stubbing the thread creation
      allow(Thread).to receive(:new).and_return(double('thread', alive?: true))

      # Prevent the wait call from blocking
      allow_any_instance_of(MonitorMixin::ConditionVariable).to receive(:wait) do |_timeout, &block|
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
        block.call
      end

      # Allow activity monitor to be started
      allow(server).to receive(:start_activity_monitor)

      # Just verify that we can connect
      uri = URI.parse(server.base_url)
      expect(uri.scheme).to eq('https')
      expect(server.connect).to be true
    end

    it 'handles HTTP URLs appropriately' do
      http_server = described_class.new(base_url: 'http://example.com/mcp/')

      # Skip the actual connection creation by stubbing the thread creation
      allow(Thread).to receive(:new).and_return(double('thread', alive?: true))

      # Prevent the wait call from blocking
      allow_any_instance_of(MonitorMixin::ConditionVariable).to receive(:wait) do |_timeout, &block|
        http_server.instance_variable_set(:@connection_established, true)
        http_server.instance_variable_set(:@initialized, true)
        block.call
      end

      # Allow activity monitor to be started
      allow(http_server).to receive(:start_activity_monitor)

      # Just verify that we can connect
      uri = URI.parse(http_server.base_url)
      expect(uri.scheme).to eq('http')
      expect(http_server.connect).to be true
    end

    it 'raises ConnectionError on failure' do
      # Simulate a connection failure
      allow(Thread).to receive(:new).and_raise(StandardError.new('Connection failed'))

      expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Failed to connect/)
    end

    it 'preserves authorization error messages' do
      # Set an authorization error
      server.instance_variable_set(:@auth_error, 'Authorization failed: Invalid token')

      # Simulate a connection failure
      allow(Thread).to receive(:new).and_raise(StandardError.new('Connection failed'))

      # Should use the auth error message instead of the generic connection message
      expect do
        server.connect
      end.to raise_error(MCPClient::Errors::ConnectionError, 'Authorization failed: Invalid token')
    end

    it 'preserves authorization errors from ConnectionError exceptions' do
      # Simulate a connection failure with authorization error message
      allow(Thread).to receive(:new).and_raise(
        MCPClient::Errors::ConnectionError.new('Authorization failed: Unauthorized request')
      )

      # Should preserve the authorization error message
      expect do
        server.connect
      end.to raise_error(MCPClient::Errors::ConnectionError, 'Authorization failed: Unauthorized request')
    end

    it 'times out if connection is not established' do
      # Mock the thread with proper behavior
      thread_double = double('thread', alive?: true)
      allow(thread_double).to receive(:kill)
      allow(Thread).to receive(:new).and_return(thread_double)

      # Set a short timeout for the test
      server.instance_variable_set(:@read_timeout, 0.1)

      # Reset connection state
      server.instance_variable_set(:@connection_established, false)

      expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Timed out waiting/)
    end

    it 'waits with periodic checks until connection is established' do
      # Mock the thread creation to prevent actual connection attempts
      allow(Thread).to receive(:new).and_return(double('thread', alive?: true))

      # Set up a counter to track wait calls
      wait_count = 0

      # Stub the condition variable to set connection_established only after multiple waits
      allow_any_instance_of(MonitorMixin::ConditionVariable).to receive(:wait) do |_timeout, &block|
        wait_count += 1
        if wait_count >= 3
          server.instance_variable_set(:@connection_established, true)
          block.call
        else
          false
        end
      end

      expect(server.connect).to eq true
      expect(wait_count).to eq 3
    end
  end

  describe '#list_tools' do
    before do
      # Stub initialization to avoid real SSE connection
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end
      allow(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end
      allow(server).to receive(:cleanup)
      # Disable SSE transport for testing synchronous HTTP fallback
      server.instance_variable_set(:@use_sse, false)
      # Prevent RPC request from triggering SSE reconnect logic
      server.instance_variable_set(:@sse_connected, true)

      server.instance_variable_set(:@rpc_endpoint, '/rpc')

      # Stub the HTTP response for tools/list
      # The URL is constructed by parsing base_url and extracting scheme://host:port
      uri = URI.parse(base_url)
      rpc_url = "#{uri.scheme}://#{uri.host}:#{uri.port}/rpc"
      stub_request(:post, rpc_url)
        .to_return(
          status: 200,
          body: { result: { tools: [tool_data] } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'connects if not already connected' do
      # Reset initialized state
      server.instance_variable_set(:@initialized, false)
      server.instance_variable_set(:@connection_established, false)

      # Mock the connection
      expect(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end

      expect(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end

      # Makes sure tools are cached
      expect(server).to receive(:request_tools_list).and_return([tool_data])

      server.list_tools
    end

    it 'returns a list of Tool objects' do
      tools = server.list_tools
      expect(tools.length).to eq(1)
      expect(tools.first).to be_a(MCPClient::Tool)
      expect(tools.first.name).to eq('test_tool')
    end

    it 'caches the tools' do
      server.list_tools
      expect(server.tools).to be_an(Array)
      expect(server.tools.first).to be_a(MCPClient::Tool)
    end

    it 'raises ServerError on non-success response' do
      # Stub error response
      uri = URI.parse(base_url)
      rpc_url = "#{uri.scheme}://#{uri.host}:#{uri.port}/rpc"
      stub_request(:post, rpc_url)
        .to_return(
          status: 500,
          body: 'Server Error'
        )

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ServerError, /Server returned error/)
    end

    it 'raises TransportError on invalid JSON' do
      allow(server).to receive(:request_tools_list).and_raise(
        MCPClient::Errors::TransportError.new('Invalid JSON response from server: unexpected token')
      )

      expect { server.list_tools }.to raise_error(MCPClient::Errors::TransportError, /Invalid JSON response/)
    end

    it 'raises ToolCallError on other errors' do
      # Create standard error stub
      allow(server).to receive(:request_tools_list).and_raise(StandardError.new('Network failure'))
      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /Error listing tools/)
    end
  end

  describe '#call_tool' do
    let(:tool_name) { 'test_tool' }
    let(:parameters) { { foo: 'bar' } }
    let(:result) { { 'output' => 'success' } }

    before do
      # Stub initialization to avoid real SSE connection
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end
      allow(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end
      allow(server).to receive(:cleanup)
      # Disable SSE transport for testing synchronous HTTP fallback
      server.instance_variable_set(:@use_sse, false)

      server.instance_variable_set(:@rpc_endpoint, '/rpc')

      # Stub the HTTP response for tools/call
      # The URL is constructed by parsing base_url and extracting scheme://host:port
      uri = URI.parse(base_url)
      rpc_url = "#{uri.scheme}://#{uri.host}:#{uri.port}/rpc"
      stub_request(:post, rpc_url)
        .to_return(
          status: 200,
          body: { result: result }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'connects if not already connected' do
      # Reset connection state for this test
      server.instance_variable_set(:@connection_established, false)
      server.instance_variable_set(:@sse_connected, false)

      # Expect connect to be called
      expect(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@sse_connected, true)
      end

      # Set up for post-connection success
      allow(server).to receive(:send_jsonrpc_request).and_return(result)

      # Call the tool
      server.call_tool(tool_name, parameters)
    end

    it 'makes a POST request with the tool name and parameters' do
      # Ensure connection is established
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)

      response = server.call_tool(tool_name, parameters)
      expect(response).to eq(result)
    end

    it 'raises ToolCallError on non-success response' do
      # Stub error response
      uri = URI.parse(base_url)
      rpc_url = "#{uri.scheme}://#{uri.host}:#{uri.port}/rpc"
      stub_request(:post, rpc_url)
        .to_return(
          status: 500,
          body: 'Server Error'
        )

      # Setup to properly handle ServerError by wrapping it in ToolCallError
      allow(server).to receive(:post_json_rpc_request).and_raise(
        MCPClient::Errors::ServerError.new('Server returned error: 403 Forbidden')
      )

      # The call_tool method should wrap the ServerError in a ToolCallError
      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCPClient::Errors::ToolCallError, /Error calling tool/)
    end

    it 'raises TransportError on invalid JSON' do
      allow(server).to receive(:send_jsonrpc_request).and_raise(
        MCPClient::Errors::TransportError.new('Invalid JSON response from server: unexpected token')
      )

      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCPClient::Errors::TransportError, /Invalid JSON response/)
    end

    it 'raises ToolCallError on other errors' do
      # Directly raise during send_jsonrpc_request
      allow(server).to receive(:send_jsonrpc_request).and_raise(StandardError.new('Network failure'))
      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCPClient::Errors::ToolCallError, /Error calling tool/)
    end
  end

  describe '#cleanup' do
    it 'resets all connection state and threads' do
      # Set up initial state
      sse_thread = double('sse_thread', kill: nil)
      activity_thread = double('activity_thread', kill: nil)

      server.instance_variable_set(:@sse_thread, sse_thread)
      server.instance_variable_set(:@activity_timer_thread, activity_thread)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@tools, [double('tool')])
      server.instance_variable_set(:@initialized, true)

      # Expect both threads to be killed
      expect(sse_thread).to receive(:kill)
      expect(activity_thread).to receive(:kill)

      # Call cleanup and verify state
      server.cleanup

      expect(server.instance_variable_get(:@sse_thread)).to be_nil
      expect(server.instance_variable_get(:@activity_timer_thread)).to be_nil
      expect(server.instance_variable_get(:@connection_established)).to be false
      expect(server.instance_variable_get(:@sse_connected)).to be false
      expect(server.instance_variable_get(:@tools)).to be_nil
      expect(server.instance_variable_get(:@initialized)).to be false
    end

    it 'sets flags before closing threads' do
      # Create mock threads
      sse_thread = double('sse_thread')
      activity_thread = double('activity_thread')

      # Set up the server with mocks
      server.instance_variable_set(:@sse_thread, sse_thread)
      server.instance_variable_set(:@activity_timer_thread, activity_thread)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@initialized, true)

      # Allow thread kill operations
      allow(sse_thread).to receive(:kill)
      allow(activity_thread).to receive(:kill)

      # Call cleanup
      server.send(:cleanup)

      # Verify connections were closed and flags were reset
      expect(server.instance_variable_get(:@connection_established)).to be false
      expect(server.instance_variable_get(:@sse_connected)).to be false
      expect(server.instance_variable_get(:@initialized)).to be false
      expect(server.instance_variable_get(:@sse_thread)).to be_nil
      expect(server.instance_variable_get(:@activity_timer_thread)).to be_nil
    end

    it 'closes Faraday connections' do
      # Set up initial state with connections
      server.instance_variable_set(:@rpc_conn, double('rpc_conn'))
      server.instance_variable_set(:@sse_conn, double('sse_conn'))

      # Call cleanup
      server.cleanup

      # Verify connections were closed
      expect(server.instance_variable_get(:@rpc_conn)).to be_nil
      expect(server.instance_variable_get(:@sse_conn)).to be_nil
    end

    it 'preserves ping failure and reconnection metrics' do
      # Set up initial state
      server.instance_variable_set(:@consecutive_ping_failures, 2)
      server.instance_variable_set(:@reconnect_attempts, 1)

      # Call cleanup
      server.cleanup

      # Verify these values are preserved
      expect(server.instance_variable_get(:@consecutive_ping_failures)).to eq(2)
      expect(server.instance_variable_get(:@reconnect_attempts)).to eq(1)
    end
  end

  describe '#call_tool_streaming' do
    let(:tool_name) { 'test_tool' }
    let(:parameters) { { foo: 'bar' } }
    let(:result) { { 'output' => 'success' } }

    before do
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end

      allow(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end

      stub_request(:post, "#{base_url.sub(%r{/sse/?$}, '')}/messages")
        .with(
          headers: { 'Content-Type' => 'application/json' },
          body: %r{tools/call.*#{tool_name}}
        )
        .to_return(
          status: 200,
          body: { result: result }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'returns an enumerator that yields the result of call_tool' do
      expect(server).to receive(:call_tool).with(tool_name, parameters).and_return(result)

      enumerator = server.call_tool_streaming(tool_name, parameters)
      expect(enumerator).to be_a(Enumerator)

      results = enumerator.to_a
      expect(results.size).to eq(1)
      expect(results.first).to eq(result)
    end
  end

  describe '#ping' do
    it 'delegates to rpc_request and returns the result' do
      allow(server).to receive(:rpc_request).with('ping').and_return({})
      expect(server.ping).to eq({})
    end
  end

  describe '#start_activity_monitor' do
    before do
      # Mock activity monitor thread to prevent actual thread creation
      allow(Thread).to receive(:new).and_return(double('thread', alive?: true))
    end

    it 'creates activity monitor thread' do
      expect(Thread).to receive(:new).and_return(double('thread', alive?: true))
      server.send(:start_activity_monitor)
    end

    it 'does not create thread if already running' do
      # Set up an existing thread
      server.instance_variable_set(:@activity_timer_thread, double('thread', alive?: true))

      # Expect no new thread to be created
      expect(Thread).not_to receive(:new)
      server.send(:start_activity_monitor)
    end

    it 'initializes last_activity_time' do
      allow(Thread).to receive(:new).and_return(double('thread', alive?: true))

      # Track the current time before calling the method
      before_time = Time.now

      server.send(:start_activity_monitor)

      # The last_activity_time should be set to a time >= the before_time
      last_activity_time = server.instance_variable_get(:@last_activity_time)
      expect(last_activity_time).to be >= before_time
    end

    it 'initializes ping failure counters' do
      allow(Thread).to receive(:new).and_return(double('thread', alive?: true))

      server.send(:start_activity_monitor)

      expect(server.instance_variable_get(:@consecutive_ping_failures)).to eq(0)
      expect(server.instance_variable_get(:@max_ping_failures)).to eq(3)
      expect(server.instance_variable_get(:@reconnect_attempts)).to eq(0)
      expect(server.instance_variable_get(:@max_reconnect_attempts)).to eq(5)
    end

    it 'calculates close_after based on ping interval' do
      # Create a server with custom ping value
      custom_server = described_class.new(base_url: 'https://example.com', ping: 15)
      # The close_after should be calculated as ping * CLOSE_AFTER_PING_RATIO
      expected_close_after = (15 * MCPClient::ServerSSE::CLOSE_AFTER_PING_RATIO).to_i

      expect(custom_server.instance_variable_get(:@close_after)).to eq(expected_close_after)
    end

    context 'when ping fails' do
      let(:server) { described_class.new(base_url: base_url, headers: headers, ping: 1) }

      before do
        # Mock the activity monitor to prevent thread creation
        allow(server).to receive(:activity_monitor_loop)

        # Setup connection state
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@sse_connected, true)
        server.instance_variable_set(:@consecutive_ping_failures, 0)

        # Force a ping failure
        allow(server).to receive(:ping).and_raise(MCPClient::Errors::ToolCallError, 'Timeout waiting for SSE result')
      end

      it 'tracks consecutive ping failures' do
        # We need to skip start_activity_monitor and directly call attempt_ping
        # to test the failure tracking
        server.send(:attempt_ping)

        # Check that it incremented the failure counter
        expect(server.instance_variable_get(:@consecutive_ping_failures)).to eq(1)
      end
    end
  end

  describe 'automatic reconnection' do
    let(:server) { described_class.new(base_url: base_url, headers: headers, ping: 1) }

    it 'attempts to reconnect after ping failures' do
      # Setup the server
      server.instance_variable_set(:@consecutive_ping_failures, 3)
      server.instance_variable_set(:@reconnect_attempts, 0)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@max_ping_failures, 3)
      server.instance_variable_set(:@max_reconnect_attempts, 5)

      # Mock the cleanup and connect methods
      allow(server).to receive(:cleanup)
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:sleep) # Don't actually sleep

      # Directly run the reconnection method
      server.send(:attempt_reconnection)

      # It should have reset the reconnection attempts after success
      expect(server.instance_variable_get(:@reconnect_attempts)).to eq(0)
    end

    it 'resets ping failure counter after successful reconnection' do
      # Setup the server
      server.instance_variable_set(:@consecutive_ping_failures, 3)
      server.instance_variable_set(:@reconnect_attempts, 0)
      server.instance_variable_set(:@max_ping_failures, 3)
      server.instance_variable_set(:@max_reconnect_attempts, 5)

      # Mock the cleanup and connect methods
      allow(server).to receive(:cleanup)
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:sleep) # Don't actually sleep

      # Directly run the reconnection method
      server.send(:attempt_reconnection)

      # It should have reset the failure counter
      expect(server.instance_variable_get(:@consecutive_ping_failures)).to eq(0)
      # And reset the reconnect attempt counter
      expect(server.instance_variable_get(:@reconnect_attempts)).to eq(0)
    end
  end

  describe '#record_activity' do
    it 'updates last_activity_time' do
      # Track the current time before calling the method
      before_time = Time.now

      server.send(:record_activity)

      # The last_activity_time should be set to a time >= the before_time
      last_activity_time = server.instance_variable_get(:@last_activity_time)
      expect(last_activity_time).to be >= before_time
    end
  end

  describe 'activity monitoring' do
    context 'activity_monitor_loop' do
      let(:server) { described_class.new(base_url: base_url, headers: headers, ping: 1) }

      before do
        allow(server).to receive(:ping).and_return(true)
        allow(server).to receive(:attempt_ping).and_call_original
        allow(server).to receive(:cleanup).and_call_original

        # Initialize required instance variables
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@sse_connected, true)
        server.instance_variable_set(:@last_activity_time, Time.now)
        server.instance_variable_set(:@consecutive_ping_failures, 0)
        server.instance_variable_set(:@reconnect_attempts, 0)
        server.instance_variable_set(:@max_ping_failures, 3)
        server.instance_variable_set(:@max_reconnect_attempts, 5)
      end

      it 'sends pings when idle' do
        # Expect attempt_ping to be called, which will then call ping
        expect(server).to receive(:attempt_ping).at_least(:once)

        thread = Thread.new { server.send(:activity_monitor_loop) }
        sleep 1.2 # Allow time for at least one ping
        thread.kill
      end

      it 'checks for inactivity closure conditions' do
        # Setup for inactivity closure
        server.instance_variable_set(:@close_after, 1)
        server.instance_variable_set(:@last_activity_time, Time.now - 2)

        # Create a direct expectation for the checks to be made
        expect(server).to receive(:cleanup).at_least(:once)

        # Run only a portion of the activity_monitor functionality
        # Directly test the inactivity closure logic
        server.send(:activity_monitor_loop)
      end

      it 'checks connection and SSE status before processing' do
        # Setup that the connection is closed for this test
        server.instance_variable_set(:@connection_established, false)

        # Test that the method exits early and doesn't try to ping
        expect(server).not_to receive(:attempt_ping)

        # Directly call activity_monitor_loop
        server.send(:activity_monitor_loop)
      end

      it 'requires both connection and SSE to be active' do
        # Setup SSE as inactive for this test
        server.instance_variable_set(:@sse_connected, false)

        # Test that the method exits early and doesn't try to ping
        expect(server).not_to receive(:attempt_ping)

        # Directly call activity_monitor_loop
        server.send(:activity_monitor_loop)
      end

      it 'does not increment ping failures when connection is closed' do
        # Setup partially connected state
        server.instance_variable_set(:@connection_established, false)
        allow(server).to receive(:ping).and_raise('Ping error')

        # Should not increment failures when connection is already closed
        expect do
          server.send(:attempt_ping)
        end.not_to(change { server.instance_variable_get(:@consecutive_ping_failures) })
      end
    end

    it 'calculates close_after as a multiple of ping interval' do
      ping_value = 15
      server = described_class.new(base_url: 'https://example.com', ping: ping_value)

      expected_close_after = (ping_value * MCPClient::ServerSSE::CLOSE_AFTER_PING_RATIO).to_i
      actual_close_after = server.instance_variable_get(:@close_after)

      expect(actual_close_after).to eq(expected_close_after)
    end

    it 'initializes last_activity_time on startup' do
      before_time = Time.now
      server = described_class.new(base_url: 'https://example.com')

      # The last_activity_time should be initialized during construction
      last_activity_time = server.instance_variable_get(:@last_activity_time)
      expect(last_activity_time).to be >= before_time
    end

    it 'tracks activity when receiving SSE chunks' do
      server = described_class.new(base_url: 'https://example.com')

      # Set last_activity_time to the past
      old_time = Time.now - 10
      server.instance_variable_set(:@last_activity_time, old_time)

      # Process a message event
      event_chunk = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n"
      server.send(:process_sse_chunk, event_chunk)

      # Verify the last_activity_time was updated
      last_activity_time = server.instance_variable_get(:@last_activity_time)
      expect(last_activity_time).to be > old_time
    end

    it 'tracks activity when sending JSON-RPC requests' do
      # Setup the server with mocked HTTP responses
      server = described_class.new(base_url: 'https://example.com')

      # Disable SSE for this test
      server.instance_variable_set(:@use_sse, false)
      server.instance_variable_set(:@rpc_endpoint, '/rpc')
      server.instance_variable_set(:@connection_established, true)

      # Stub the HTTP response
      stub_request(:post, 'https://example.com/rpc')
        .to_return(
          status: 200,
          body: '{"result": {}}',
          headers: { 'Content-Type' => 'application/json' }
        )

      # Set last_activity_time to the past
      old_time = Time.now - 10
      server.instance_variable_set(:@last_activity_time, old_time)
      server.instance_variable_set(:@initialized, true)

      # Send a request
      request = { jsonrpc: '2.0', id: 1, method: 'test', params: {} }
      server.send(:send_jsonrpc_request, request)

      # Verify the last_activity_time was updated
      last_activity_time = server.instance_variable_get(:@last_activity_time)
      expect(last_activity_time).to be > old_time
    end
  end

  describe '#rpc_request' do
    before do
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@connection_established, true)
      end
      allow(server).to receive(:perform_initialize) do
        server.instance_variable_set(:@initialized, true)
      end
      allow(server).to receive(:cleanup)
      server.instance_variable_set(:@use_sse, false)

      server.instance_variable_set(:@rpc_endpoint, '/rpc')

      # Stub the HTTP response for test_method
      # The URL is constructed by parsing base_url and extracting scheme://host:port
      uri = URI.parse(base_url)
      rpc_url = "#{uri.scheme}://#{uri.host}:#{uri.port}/rpc"
      stub_request(:post, rpc_url)
        .to_return(
          status: 200,
          body: { result: { test: 'result' } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
    end

    it 'sends a JSON-RPC request with the given method and parameters' do
      result = server.rpc_request('test_method', { param: 'value' })
      expect(result).to eq({ 'test' => 'result' })
    end

    it 'retries transient errors' do
      server.instance_variable_set(:@max_retries, 2)
      server.instance_variable_set(:@retry_backoff, 0.01) # Speed up tests

      # Setup for error then success pattern
      call_count = 0
      allow(server).to receive(:send_jsonrpc_request) do
        call_count += 1
        raise MCPClient::Errors::TransportError, 'Network timeout' if call_count == 1

        # First call fails with a TransportError

        # Second call succeeds
        { 'success' => true }
      end

      # Should retry and eventually succeed
      result = server.rpc_request('test_method', { param: 'value' })
      expect(result).to eq({ 'success' => true })
      expect(call_count).to eq(2) # Verify it was called twice (one fail, one success)
    end

    it 'gives up after max retries' do
      server.instance_variable_set(:@max_retries, 1)
      server.instance_variable_set(:@retry_backoff, 0.01) # Speed up tests

      # Always raise a TransportError
      allow(server).to receive(:send_jsonrpc_request).and_raise(
        MCPClient::Errors::TransportError.new('Connection timed out')
      )

      # Should try max_retries (1) + 1 (original) = 2 times, then give up
      expect do
        server.rpc_request('test_method', { param: 'value' })
      end.to raise_error(MCPClient::Errors::TransportError, 'Connection timed out')
    end
  end

  describe '#rpc_notify' do
    before do
      server.instance_variable_set(:@session_id, 'test_session')
      # Skip initialization in the tests
      allow(server).to receive(:ensure_initialized).and_return(true)

      # Create a Faraday mock
      @mock_conn = instance_double(Faraday::Connection)
      allow(Faraday).to receive(:new).and_return(@mock_conn)

      # Set up message endpoint
      endpoint = '/messages?sessionId=test_session'
      server.instance_variable_set(:@rpc_endpoint, endpoint)

      # Create successful response mock
      @success_response = instance_double(Faraday::Response)
      allow(@success_response).to receive(:success?).and_return(true)
      allow(@success_response).to receive(:status).and_return(200)
      allow(@success_response).to receive(:reason_phrase).and_return('OK')

      # Create error response mock
      @error_response = instance_double(Faraday::Response)
      allow(@error_response).to receive(:success?).and_return(false)
      allow(@error_response).to receive(:status).and_return(500)
      allow(@error_response).to receive(:reason_phrase).and_return('Server Error')
    end

    it 'sends a JSON-RPC notification with the given method and parameters' do
      # Set up expectations for the post request
      expect(@mock_conn).to receive(:post) do |_endpoint, &block|
        request = double('request')
        headers = {}

        # Mock the headers hash
        expect(request).to receive(:headers).at_least(:once).and_return(headers)

        # Capture the request body
        expect(request).to receive(:body=) do |body_json|
          body = JSON.parse(body_json)
          expect(body['method']).to eq('test_notify')
          expect(body['params']).to eq({ 'param' => 'value' })
        end

        # Call the block with our request mock
        block.call(request)

        # Return success response
        @success_response
      end

      server.rpc_notify('test_notify', { param: 'value' })
    end

    it 'raises TransportError when response is not successful' do
      # Set up expectation for a failed request
      expect(@mock_conn).to receive(:post).and_return(@error_response)

      expect do
        server.rpc_notify('test_notify', { param: 'value' })
      end.to raise_error(MCPClient::Errors::TransportError, /Failed to send notification/)
    end

    it 'raises TransportError on network failures' do
      # Set up expectation for a network error
      expect(@mock_conn).to receive(:post).and_raise(Faraday::ConnectionFailed.new('Connection reset'))

      expect do
        server.rpc_notify('test_notify', { param: 'value' })
      end.to raise_error(MCPClient::Errors::TransportError, /Failed to send notification/)
    end
  end

  describe '#parse_sse_event' do
    it 'parses event data correctly' do
      event_data = "event: endpoint\ndata: /messages\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event).to be_a(Hash)
      expect(event[:event]).to eq('endpoint')
      expect(event[:data]).to eq('/messages')
    end

    it 'handles empty data in events' do
      event_data = "event: ping\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event).to be_a(Hash)
      expect(event[:event]).to eq('ping')
      expect(event[:data]).to eq('')
    end

    it 'skips comment lines' do
      event_data = ": This is a comment\nevent: message\ndata: actual data\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event[:event]).to eq('message')
      expect(event[:data]).to eq('actual data')
    end

    it 'returns nil for comment-only events' do
      event_data = ": keep-alive 1\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event).to be_nil
    end

    it 'handles multi-line data' do
      event_data = "event: message\ndata: line 1\ndata: line 2\n\n"
      event = server.send(:parse_sse_event, event_data)

      expect(event[:event]).to eq('message')
      expect(event[:data]).to eq("line 1\nline 2")
    end
  end

  describe '#process_sse_chunk' do
    it 'processes multiple events in a single chunk' do
      chunk = "event: endpoint\ndata: /messages\n\nevent: message\ndata: {\"id\":1}\n\n"

      # Expect parse_and_handle_sse_event to be called twice, once for each event
      expect(server).to receive(:parse_and_handle_sse_event).twice

      # Expect activity to be recorded
      expect(server).to receive(:record_activity)

      server.send(:process_sse_chunk, chunk)
    end

    it 'accumulates partial chunks' do
      # Send a partial chunk first
      partial_chunk = "event: endpoint\ndata: /messages"
      server.send(:process_sse_chunk, partial_chunk)

      # Complete the event with a second chunk
      completion_chunk = "\n\n"

      # Expect parse_and_handle_sse_event to be called once when the event is complete
      expect(server).to receive(:parse_and_handle_sse_event).once

      server.send(:process_sse_chunk, completion_chunk)
    end

    it 'detects direct JSON-RPC error responses with authorization errors' do
      # Authorization error in JSON-RPC format that isn't an SSE event
      error_response = '{
        "jsonrpc":"2.0",
        "error":{"code":-32000,"message":"Unauthorized: Invalid token"},
        "id":null
      }'

      # Should set auth_error and raise ConnectionError
      expect do
        server.send(:process_sse_chunk, error_response)
      end.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed/)

      # Check auth_error was set
      expect(server.instance_variable_get(:@auth_error)).to match(/Authorization failed/)
    end

    it 'ignores invalid JSON' do
      # Invalid JSON that looks like it might contain an error
      invalid_json = '{ "error": {'

      # Should not raise an error
      expect do
        server.send(:process_sse_chunk, invalid_json)
      end.not_to raise_error
    end
  end

  describe '#parse_and_handle_sse_event' do
    it 'handles endpoint events' do
      event_data = "event: endpoint\ndata: /messages\n\n"

      # Set initial state
      server.instance_variable_set(:@connection_established, false)

      server.send(:parse_and_handle_sse_event, event_data)

      # Verify the state changes
      expect(server.instance_variable_get(:@connection_established)).to eq(true)
      expect(server.instance_variable_get(:@rpc_endpoint)).to eq('/messages')
    end

    it 'handles empty message events' do
      event_data = "event: message\ndata: \n\n"

      # Should not raise an error
      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.not_to raise_error
    end

    it 'handles JSON-RPC notification messages' do
      notification = { method: 'test_notification', params: { foo: 'bar' } }
      event_data = "event: message\ndata: #{notification.to_json}\n\n"

      # Set up notification callback
      notification_received = false
      server.on_notification do |method, params|
        notification_received = true
        expect(method).to eq('test_notification')
        expect(params).to eq({ 'foo' => 'bar' })
      end

      server.send(:parse_and_handle_sse_event, event_data)
      expect(notification_received).to be true
    end

    it 'handles invalid JSON gracefully' do
      event_data = "event: message\ndata: {invalid json}\n\n"

      # Should log warning but not raise
      expect(server.instance_variable_get(:@logger)).to receive(:warn)

      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.not_to raise_error
    end

    it 'detects and handles authorization errors in message events' do
      # Create a JSON-RPC error response with authorization error
      error_data = {
        jsonrpc: '2.0',
        error: {
          code: -32_000,
          message: 'Unauthorized: Invalid API token'
        },
        id: 1
      }
      event_data = "event: message\ndata: #{error_data.to_json}\n\n"

      # Should set auth_error and raise ConnectionError
      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed/)

      # Check auth_error was set
      expect(server.instance_variable_get(:@auth_error)).to match(/Authorization failed/)
      expect(server.instance_variable_get(:@connection_established)).to be false
    end

    it 'detects authorization errors with specific error codes' do
      # Create a JSON-RPC error response with 401 error code
      error_data = {
        jsonrpc: '2.0',
        error: {
          code: 401,
          message: 'Authentication required'
        },
        id: 1
      }
      event_data = "event: message\ndata: #{error_data.to_json}\n\n"

      # Should set auth_error and raise ConnectionError
      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed/)

      # Check auth_error was set
      expect(server.instance_variable_get(:@auth_error)).to match(/Authorization failed: Authentication required/)
    end

    it 'handles regular error messages without raising ConnectionError' do
      # Create a JSON-RPC error response with a normal error
      error_data = {
        jsonrpc: '2.0',
        error: {
          code: -32_603,
          message: 'Internal server error'
        },
        id: 1
      }
      event_data = "event: message\ndata: #{error_data.to_json}\n\n"

      # Should log the error but not raise ConnectionError
      expect(server.instance_variable_get(:@logger)).to receive(:error).with(/Server error/)

      # Should not raise an error
      expect do
        server.send(:parse_and_handle_sse_event, event_data)
      end.not_to raise_error

      # Should not set auth_error
      expect(server.instance_variable_get(:@auth_error)).to be_nil
    end
  end

  describe '#send_jsonrpc_request' do
    it 'records activity when sending and receiving' do
      # Set up a minimal request
      request = { jsonrpc: '2.0', id: 1, method: 'test', params: {} }

      # Set up a fake RPC endpoint
      server.instance_variable_set(:@rpc_endpoint, '/rpc')
      server.instance_variable_set(:@use_sse, false)

      # Stub the HTTP response
      # The URL is constructed by parsing base_url and extracting scheme://host:port
      uri = URI.parse(base_url)
      rpc_url = "#{uri.scheme}://#{uri.host}:#{uri.port}/rpc"
      stub_request(:post, rpc_url)
        .to_return(
          status: 200,
          body: '{"result": {}}',
          headers: { 'Content-Type' => 'application/json' }
        )

      # Expect activity to be recorded twice - once for sending, once for receiving
      expect(server).to receive(:record_activity).exactly(2).times

      server.send(:send_jsonrpc_request, request)
    end
  end
end
