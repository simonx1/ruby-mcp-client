# frozen_string_literal: true

require_relative '../json_rpc_common'

module MCPClient
  class ServerSSE
    # JSON-RPC request/notification plumbing for SSE transport
    module JsonRpcTransport
      include JsonRpcCommon

      # Generic JSON-RPC request: send method with params and return result
      # @param method [String] JSON-RPC method name
      # @param params [Hash] parameters for the request
      # @return [Object] result from JSON-RPC response
      # @raise [MCPClient::Errors::ConnectionError] if connection is not active or reconnect fails
      # @raise [MCPClient::Errors::ServerError] if server returns an error
      # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
      # @raise [MCPClient::Errors::ToolCallError] for other errors during request execution
      def rpc_request(method, params = {}, timeout: nil)
        ensure_initialized

        with_retry do
          request_id = @mutex.synchronize { @request_id += 1 }
          request = build_jsonrpc_request(method, params, request_id)
          begin
            send_jsonrpc_request(request, timeout: timeout)
          rescue MCPClient::Errors::RequestTimeoutError
            # MCP lifecycle: on timeout the sender SHOULD issue a cancellation
            # notification for the abandoned request and stop waiting.
            send_cancellation_notification(request_id) if cancellable_request?(method, params)
            raise
          end
        end
      end

      # Best-effort notifications/cancelled for a request the client stopped
      # waiting on. Failures are swallowed.
      # @param request_id [Integer] id of the abandoned request
      # @return [void]
      def send_cancellation_notification(request_id)
        notif = build_jsonrpc_notification('notifications/cancelled',
                                           { 'requestId' => request_id, 'reason' => 'Request timed out' })
        post_json_rpc_request(notif)
      rescue StandardError => e
        @logger.debug("Failed to send cancellation notification: #{e.message}")
      end

      # Send a JSON-RPC notification (no response expected)
      # @param method [String] JSON-RPC method name
      # @param params [Hash] parameters for the notification
      # @return [void]
      def rpc_notify(method, params = {})
        ensure_initialized
        notif = build_jsonrpc_notification(method, params)
        post_json_rpc_request(notif)
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::ConnectionError, Faraday::ConnectionFailed => e
        raise MCPClient::Errors::TransportError, "Failed to send notification: #{e.message}"
      end

      private

      # Ensure SSE initialization handshake has been performed.
      # Attempts to reconnect and reinitialize if the SSE connection is not active.
      #
      # @raise [MCPClient::Errors::ConnectionError] if reconnect or initialization fails
      def ensure_initialized
        if !@connection_established || !@sse_connected
          @logger.debug('Connection not active, attempting to reconnect before RPC request')
          cleanup
          connect
          perform_initialize
          @initialized = true
          return
        end

        return if @initialized

        perform_initialize
        @initialized = true
      end

      # Perform JSON-RPC initialize handshake with the MCP server
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if the initialize result is malformed
      def perform_initialize
        request_id = @mutex.synchronize { @request_id += 1 }
        json_rpc_request = build_jsonrpc_request('initialize', initialization_params, request_id)
        @logger.debug("Performing initialize RPC: #{json_rpc_request}")
        result = send_jsonrpc_request(json_rpc_request)
        unless result.is_a?(Hash)
          # A non-object initialize result means the handshake did not succeed.
          # Continuing would enter the Operation phase without ever sending the
          # mandatory notifications/initialized (MCP lifecycle "Initialization":
          # "After successful initialization, the client MUST send an
          # `initialized` notification"), so fail the connection instead.
          cleanup
          raise MCPClient::Errors::ConnectionError,
                "Invalid initialize response from server: expected an object, got #{result.inspect}"
        end

        # Disconnects if the server negotiated a version we cannot speak.
        @protocol_version = validate_protocol_version!(result)
        @server_info = result['serverInfo']
        @capabilities = result['capabilities']
        @instructions = result['instructions']

        # Send initialized notification to acknowledge completion of initialization
        initialized_notification = build_jsonrpc_notification('notifications/initialized', {})
        post_json_rpc_request(initialized_notification)

        # Small delay to ensure server processes the notification
        sleep(0.1)
      end

      # Send a JSON-RPC request to the server and wait for result
      # @param request [Hash] the JSON-RPC request
      # @return [Hash] the result of the request
      # @raise [MCPClient::Errors::ConnectionError] if connection fails
      # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
      # @raise [MCPClient::Errors::ToolCallError] for other errors during request execution
      def send_jsonrpc_request(request, timeout: nil)
        @logger.debug("Sending JSON-RPC request: #{request.to_json}")
        record_activity

        begin
          response = post_json_rpc_request(request)

          if @use_sse
            wait_for_sse_result(request, timeout: timeout)
          else
            parse_direct_response(response)
          end
        rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
          raise
        rescue JSON::ParserError => e
          raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
        rescue Errno::ECONNREFUSED => e
          raise MCPClient::Errors::ConnectionError, "Server connection lost: #{e.message}"
        rescue StandardError => e
          method_name = request['method']
          raise MCPClient::Errors::ToolCallError, "Error executing request '#{method_name}': #{e.message}"
        end
      end

      # Post a JSON-RPC request to the server
      # @param request [Hash] the JSON-RPC request
      # @return [Faraday::Response] the HTTP response
      # @raise [MCPClient::Errors::ConnectionError] if connection fails
      def post_json_rpc_request(request)
        uri = URI.parse(@base_url)
        base = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        rpc_ep = @mutex.synchronize { @rpc_endpoint }

        @rpc_conn ||= create_json_rpc_connection(base)

        begin
          response = send_http_request(@rpc_conn, rpc_ep, request)
          record_activity

          unless response.success?
            # 5xx failures are plausibly transient (retryable); 4xx and other
            # statuses are deterministic and raise a plain (non-retryable) error.
            error_class = (500..599).cover?(response.status) ? MCPClient::Errors::TransientServerError : MCPClient::Errors::ServerError
            raise error_class, "Server returned error: #{response.status} #{response.reason_phrase}"
          end

          response
        rescue Faraday::TimeoutError => e
          raise MCPClient::Errors::RequestTimeoutError, "Request timed out: #{e.message}"
        rescue Faraday::ConnectionFailed => e
          raise MCPClient::Errors::ConnectionError, "Server connection lost: #{e.message}"
        end
      end

      # Create a Faraday connection for JSON-RPC
      # @param base_url [String] the base URL for the connection
      # @return [Faraday::Connection] the configured connection
      def create_json_rpc_connection(base_url)
        Faraday.new(url: base_url) do |f|
          f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
          f.response :follow_redirects, limit: 3
          f.options.open_timeout = @read_timeout
          f.options.timeout = @read_timeout
          f.adapter Faraday.default_adapter
        end
      end

      # Send an HTTP request with the proper headers and body
      # @param conn [Faraday::Connection] the connection to use
      # @param endpoint [String] the endpoint to post to
      # @param request [Hash] the request data
      # @return [Faraday::Response] the HTTP response
      def send_http_request(conn, endpoint, request)
        response = conn.post(endpoint) do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['Accept'] = 'application/json'
          # MCP lifecycle "Version Negotiation": the client MUST include the
          # MCP-Protocol-Version header on all requests after the initialize
          # handshake. The guard naturally skips the initialize POST itself,
          # since the negotiated version is only known from its result.
          req.headers['Mcp-Protocol-Version'] = @protocol_version if @protocol_version
          (@headers.dup.tap do |h|
            h.delete('Accept')
            h.delete('Cache-Control')
          end).each { |k, v| req.headers[k] = v }
          req.body = request.to_json
        end

        msg = "Received JSON-RPC response: #{response.status}"
        msg += " #{response.body}" if response.respond_to?(:body)
        @logger.debug(msg)
        response
      end

      # Wait for an SSE result to arrive
      # @param request [Hash] the original JSON-RPC request
      # @return [Hash] the result data
      # @raise [MCPClient::Errors::ConnectionError, MCPClient::Errors::ToolCallError] on errors
      def wait_for_sse_result(request, timeout: nil)
        request_id = request['id']
        start_time = Time.now
        timeout ||= @read_timeout || 10

        ensure_sse_connection_active

        wait_for_result_with_timeout(request_id, start_time, timeout)
      end

      # Ensure the SSE connection is active, reconnect if needed
      def ensure_sse_connection_active
        return if connection_active?

        @logger.warn('SSE connection is not active, reconnecting before waiting for result')
        begin
          cleanup
          connect
        rescue MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::ConnectionError, "Failed to reconnect SSE for result: #{e.message}"
        end
      end

      # Wait for a result with timeout
      # @param request_id [Integer] the request ID to wait for
      # @param start_time [Time] when the wait started
      # @param timeout [Integer] the timeout in seconds
      # @return [Hash] the result when available
      # @raise [MCPClient::Errors::ConnectionError, MCPClient::Errors::ToolCallError] on errors
      def wait_for_result_with_timeout(request_id, start_time, timeout)
        loop do
          result = check_for_result(request_id)
          return result if result

          unless connection_active?
            raise MCPClient::Errors::ConnectionError,
                  'SSE connection lost while waiting for result'
          end

          time_elapsed = Time.now - start_time
          break if time_elapsed > timeout

          sleep 0.1
        end

        raise MCPClient::Errors::RequestTimeoutError, "Timeout waiting for SSE result for request #{request_id}"
      end

      # Check if a result is available for the given request ID
      # @param request_id [Integer] the request ID to check
      # @return [Hash, nil] the result if available, nil otherwise
      # @raise [MCPClient::Errors::ServerError] if the stored result is a JSON-RPC error response
      def check_for_result(request_id)
        result = nil
        @mutex.synchronize do
          result = @sse_results.delete(request_id) if @sse_results.key?(request_id)
        end

        if result
          record_activity
          # SseParser#process_response? stores JSON-RPC error responses under
          # the Symbol :error key; deliver them to the caller as ServerError
          # (MCP lifecycle "Error Handling") instead of timing out.
          raise_sse_error_response(result[:error]) if result.is_a?(Hash) && result.key?(:error)
          return result
        end

        nil
      end

      # Raise a ServerError for a JSON-RPC error response received over SSE,
      # mirroring JsonRpcCommon#process_jsonrpc_response for the other transports.
      # @param error [Hash, nil] the JSON-RPC error object ('code', 'message', 'data')
      # @raise [MCPClient::Errors::ServerError] always
      def raise_sse_error_response(error)
        error ||= {}
        message = error['message'] || 'Unknown server error'
        message = "#{message} (code #{error['code']})" if error['code']
        raise MCPClient::Errors::ServerError, message
      end

      # Parse a direct (non-SSE) JSON-RPC response
      # @param response [Faraday::Response] the HTTP response
      # @return [Hash] the parsed result
      # @raise [MCPClient::Errors::TransportError] if parsing fails
      # @raise [MCPClient::Errors::ServerError] if the response contains an error
      def parse_direct_response(response)
        data = JSON.parse(response.body)
        process_jsonrpc_response(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
      end
    end
  end
end
