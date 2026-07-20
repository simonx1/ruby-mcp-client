# frozen_string_literal: true

require_relative '../json_rpc_common'

module MCPClient
  class ServerStdio
    # JSON-RPC request/notification plumbing for stdio transport
    module JsonRpcTransport
      include JsonRpcCommon

      # Ensure the server process is started and initialized (handshake)
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if initialization fails
      def ensure_initialized
        return if @initialized

        connect
        start_reader
        start_stderr_reader
        perform_initialize

        @initialized = true
      end

      # Handshake: send initialize request and initialized notification
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if initialization fails
      def perform_initialize
        # Initialize request
        init_id = next_id
        init_req = build_jsonrpc_request('initialize', initialization_params, init_id)
        send_request(init_req)
        res = wait_response(init_id)
        if (err = res['error'])
          raise MCPClient::Errors::ConnectionError, "Initialize failed: #{err['message']}"
        end

        # Store server info and capabilities
        result = res['result'] || {}
        @server_info = result['serverInfo']
        @capabilities = result['capabilities']

        # Send initialized notification
        notif = build_jsonrpc_notification('notifications/initialized', {})
        @stdin.puts(notif.to_json)
      end

      # Generate a new unique request ID and mark it as awaiting a response.
      # Registering the id before the request is sent lets the reader thread
      # distinguish expected responses from late/unsolicited ones.
      # @return [Integer] a unique request ID
      def next_id
        @mutex.synchronize do
          id = @next_id
          @next_id += 1
          @awaiting[id] = true
          id
        end
      end

      # Send a JSON-RPC request and return nothing
      # @param req [Hash] the JSON-RPC request
      # @return [void]
      # @raise [MCPClient::Errors::TransportError] on write errors
      def send_request(req)
        @logger.debug("Sending JSONRPC request: #{req.to_json}")
        @stdin.puts(req.to_json)
      rescue StandardError => e
        # A request that failed to send will never receive a response, so drop
        # its awaiting marker; otherwise a broken transport (e.g. the server
        # exited) would leak an entry per retry/attempt into @awaiting.
        @mutex.synchronize { @awaiting.delete(req['id']) } if req.is_a?(Hash) && req['id']
        raise MCPClient::Errors::TransportError, "Failed to send JSONRPC request: #{e.message}"
      end

      # Wait for a response with the given request ID
      # @param id [Integer] the request ID
      # @return [Hash] the JSON-RPC response message
      # @raise [MCPClient::Errors::TransportError] on timeout
      def wait_response(id, timeout: nil)
        deadline = Time.now + (timeout || @read_timeout)
        @mutex.synchronize do
          until @pending.key?(id)
            remaining = deadline - Time.now
            break if remaining <= 0

            @cond.wait(@mutex, remaining)
          end
          # Remove the response and the awaiting marker on both success and
          # timeout so neither @pending nor @awaiting accumulates entries.
          msg = @pending.delete(id)
          @awaiting.delete(id)
          raise MCPClient::Errors::RequestTimeoutError, "Timeout waiting for JSONRPC response id=#{id}" unless msg

          msg
        end
      end

      # Stream tool call fallback for stdio transport (yields single result)
      # @param tool_name [String] the name of the tool to call
      # @param parameters [Hash] the parameters to pass to the tool
      # @return [Enumerator] a stream containing a single result
      def call_tool_streaming(tool_name, parameters)
        Enumerator.new do |yielder|
          yielder << call_tool(tool_name, parameters)
        end
      end

      # Generic JSON-RPC request: send method with params and wait for result
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the request
      # @return [Object] result from JSON-RPC response
      # @raise [MCPClient::Errors::ServerError] if server returns an error
      # @raise [MCPClient::Errors::TransportError] on transport errors
      # @raise [MCPClient::Errors::ToolCallError] on tool call errors
      def rpc_request(method, params = {}, timeout: nil)
        ensure_initialized
        with_retry do
          req_id = next_id
          req = build_jsonrpc_request(method, params, req_id)
          send_request(req)
          begin
            res = wait_response(req_id, timeout: timeout)
          rescue MCPClient::Errors::RequestTimeoutError
            # MCP lifecycle: on timeout the sender SHOULD issue a cancellation
            # notification for the abandoned request and stop waiting.
            send_cancellation_notification(req_id) if cancellable_request?(method, params)
            raise
          end
          process_jsonrpc_response(res)
        end
      end

      # Best-effort notifications/cancelled for a request the client stopped
      # waiting on. Failures are swallowed: the transport may be the reason
      # the request timed out in the first place.
      # @param request_id [Integer] id of the abandoned request
      # @return [void]
      def send_cancellation_notification(request_id)
        notif = build_jsonrpc_notification('notifications/cancelled',
                                           { 'requestId' => request_id, 'reason' => 'Request timed out' })
        @stdin.puts(notif.to_json)
      rescue StandardError => e
        @logger.debug("Failed to send cancellation notification: #{e.message}")
      end

      # Send a JSON-RPC notification (no response expected)
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the notification
      # @return [void]
      def rpc_notify(method, params = {})
        ensure_initialized
        notif = build_jsonrpc_notification(method, params)
        @stdin.puts(notif.to_json)
      end
    end
  end
end
