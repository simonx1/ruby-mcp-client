# frozen_string_literal: true

require_relative '../json_rpc_common'

module MCPClient
  class ServerStreamableHTTP
    # JSON-RPC request/notification plumbing for Streamable HTTP transport
    # This transport uses HTTP POST requests but expects Server-Sent Event formatted responses
    module JsonRpcTransport
      include JsonRpcCommon

      # Generic JSON-RPC request: send method with params and return result
      # @param method [String] JSON-RPC method name
      # @param params [Hash] parameters for the request
      # @return [Object] result from JSON-RPC response
      # @raise [MCPClient::Errors::ConnectionError] if connection is not active
      # @raise [MCPClient::Errors::ServerError] if server returns an error
      # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
      # @raise [MCPClient::Errors::ToolCallError] for other errors during request execution
      def rpc_request(method, params = {})
        ensure_connected

        with_retry do
          request_id = @mutex.synchronize { @request_id += 1 }
          request = build_jsonrpc_request(method, params, request_id)
          send_jsonrpc_request(request)
        end
      end

      # Send a JSON-RPC notification (no response expected)
      # @param method [String] JSON-RPC method name
      # @param params [Hash] parameters for the notification
      # @return [void]
      def rpc_notify(method, params = {})
        ensure_connected
        
        notif = build_jsonrpc_notification(method, params)
        
        begin
          send_http_request(notif)
        rescue MCPClient::Errors::ServerError, MCPClient::Errors::ConnectionError, Faraday::ConnectionFailed => e
          raise MCPClient::Errors::TransportError, "Failed to send notification: #{e.message}"
        end
      end

      private

      # Perform JSON-RPC initialize handshake with the MCP server
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if initialization fails
      def perform_initialize
        request_id = @mutex.synchronize { @request_id += 1 }
        json_rpc_request = build_jsonrpc_request('initialize', initialization_params, request_id)
        @logger.debug("Performing initialize RPC: #{json_rpc_request}")
        
        result = send_jsonrpc_request(json_rpc_request)
        return unless result.is_a?(Hash)

        @server_info = result['serverInfo'] if result.key?('serverInfo')
        @capabilities = result['capabilities'] if result.key?('capabilities')
      end

      # Send a JSON-RPC request to the server and wait for result
      # @param request [Hash] the JSON-RPC request
      # @return [Hash] the result of the request
      # @raise [MCPClient::Errors::ConnectionError] if connection fails
      # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
      # @raise [MCPClient::Errors::ToolCallError] for other errors during request execution
      def send_jsonrpc_request(request)
        @logger.debug("Sending JSON-RPC request: #{request.to_json}")

        begin
          response = send_http_request(request)
          parse_streamable_http_response(response)
        rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
          raise
        rescue JSON::ParserError => e
          raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
        rescue Errno::ECONNREFUSED => e
          raise MCPClient::Errors::ConnectionError, "Server connection lost: #{e.message}"
        rescue StandardError => e
          method_name = request[:method] || request['method']
          raise MCPClient::Errors::ToolCallError, "Error executing request '#{method_name}': #{e.message}"
        end
      end

      # Send an HTTP request to the server
      # @param request [Hash] the JSON-RPC request
      # @return [Faraday::Response] the HTTP response
      # @raise [MCPClient::Errors::ConnectionError] if connection fails
      def send_http_request(request)
        conn = get_http_connection
        
        begin
          response = conn.post(@endpoint) do |req|
            # Apply all headers including custom ones for Streamable HTTP
            @headers.each { |k, v| req.headers[k] = v }
            req.body = request.to_json
          end

          unless response.success?
            handle_http_error_response(response)
          end

          @logger.debug("Received Streamable HTTP response: #{response.status} #{response.body}")
          response
        rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
          error_status = e.response ? e.response[:status] : 'unknown'
          raise MCPClient::Errors::ConnectionError, "Authorization failed: HTTP #{error_status}"
        rescue Faraday::ConnectionFailed => e
          raise MCPClient::Errors::ConnectionError, "Server connection lost: #{e.message}"
        rescue Faraday::Error => e
          raise MCPClient::Errors::TransportError, "HTTP request failed: #{e.message}"
        end
      end

      # Handle HTTP error responses
      # @param response [Faraday::Response] the error response
      # @raise [MCPClient::Errors::ConnectionError] for auth errors
      # @raise [MCPClient::Errors::ServerError] for server errors
      def handle_http_error_response(response)
        case response.status
        when 401, 403
          raise MCPClient::Errors::ConnectionError, "Authorization failed: HTTP #{response.status} #{response.reason_phrase}"
        when 400..499
          raise MCPClient::Errors::ServerError, "Client error: HTTP #{response.status} #{response.reason_phrase}"
        when 500..599
          raise MCPClient::Errors::ServerError, "Server error: HTTP #{response.status} #{response.reason_phrase}"
        else
          raise MCPClient::Errors::TransportError, "HTTP error: #{response.status} #{response.reason_phrase}"
        end
      end

      # Get or create HTTP connection
      # @return [Faraday::Connection] the HTTP connection
      def get_http_connection
        @http_conn ||= create_http_connection
      end

      # Create a Faraday connection for HTTP requests
      # @return [Faraday::Connection] the configured connection
      def create_http_connection
        Faraday.new(url: @base_url) do |f|
          f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
          f.options.open_timeout = @read_timeout
          f.options.timeout = @read_timeout
          f.adapter Faraday.default_adapter
        end
      end

      # Parse a Streamable HTTP JSON-RPC response (in SSE format)
      # @param response [Faraday::Response] the HTTP response
      # @return [Hash] the parsed result
      # @raise [MCPClient::Errors::TransportError] if parsing fails
      # @raise [MCPClient::Errors::ServerError] if the response contains an error
      def parse_streamable_http_response(response)
        body = response.body.strip
        
        # Parse SSE-formatted response
        data = parse_sse_response(body)
        process_jsonrpc_response(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
      end

      # Parse Server-Sent Event formatted response
      # @param sse_body [String] the SSE formatted response body
      # @return [Hash] the parsed JSON data
      # @raise [MCPClient::Errors::TransportError] if no data found in SSE response
      def parse_sse_response(sse_body)
        # Extract JSON data from SSE format
        # SSE format: event: message\ndata: {...}\n\n
        data_line = sse_body.lines.find { |line| line.start_with?('data:') }
        
        if data_line
          json_data = data_line.sub(/^data:\s*/, '').strip
          JSON.parse(json_data)
        else
          raise MCPClient::Errors::TransportError, "No data found in SSE response"
        end
      end
    end
  end
end