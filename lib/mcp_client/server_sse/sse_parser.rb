# frozen_string_literal: true

require 'json'
require 'uri'
require_relative 'origin_policy'

module MCPClient
  class ServerSSE
    # === Wire-level SSE parsing & dispatch ===
    module SseParser
      include OriginPolicy

      # Parse and handle a raw SSE event payload.
      # @param event_data [String] the raw event chunk
      def parse_and_handle_sse_event(event_data)
        event = parse_sse_event(event_data)
        return if event.nil?

        case event[:event]
        when 'endpoint'
          handle_endpoint_event(event[:data])
        when 'ping'
          # no-op
        when 'message'
          handle_message_event(event)
        end
      end

      # Handle a "message" SSE event (payload is JSON-RPC over SSE)
      # @param event [Hash] the parsed SSE event (with :data, :id, etc)
      def handle_message_event(event)
        return if event[:data].empty?

        begin
          data = JSON.parse(event[:data])

          return if process_error_in_message?(data)
          return if process_server_request?(data)
          return if process_notification?(data)

          process_response?(data)
        rescue MCPClient::Errors::ConnectionError
          raise
        rescue JSON::ParserError => e
          @logger.warn("Failed to parse JSON from event data: #{e.message}")
        rescue StandardError => e
          @logger.error("Error processing SSE event: #{e.message}")
        end
      end

      # Process a connection-level JSON-RPC error payload in the SSE stream.
      # Error RESPONSES (id-bearing) belong to a pending request and are
      # delivered to the waiting caller via process_response? instead, per the
      # MCP lifecycle "Error Handling" section (implementations SHOULD handle
      # error cases such as protocol version mismatch), so they must not be
      # swallowed here.
      # @param data [Hash] the parsed JSON payload
      # @return [Boolean] true if we saw & handled an id-less error
      def process_error_in_message?(data)
        return false unless data['error']
        return false if data['id']

        error_message = data['error']['message'] || 'Unknown server error'
        error_code    = data['error']['code']

        handle_sse_auth_error_message(error_message) if authorization_error?(error_message, error_code)

        @logger.error("Server error: #{error_message}")
        true
      end

      # Process a JSON-RPC request from server (has both id AND method)
      # @param data [Hash] the parsed JSON payload
      # @return [Boolean] true if we saw & handled a server request
      def process_server_request?(data)
        return false unless data['method'] && data.key?('id')

        handle_server_request(data)
        true
      end

      # Process a JSON-RPC notification (no id => notification)
      # @param data [Hash] the parsed JSON payload
      # @return [Boolean] true if we saw & handled a notification
      def process_notification?(data)
        return false unless data['method'] && !data.key?('id')

        @notification_callback&.call(data['method'], data['params'])
        true
      end

      # Process a JSON-RPC response (id => response)
      # @param data [Hash] the parsed JSON payload
      # @return [Boolean] true if we saw & handled a response
      def process_response?(data)
        return false unless data['id']

        # Deliver the response to the waiting caller via @sse_results only.
        # We intentionally do NOT write @tools_data here: request_tools_list is
        # the sole writer of that cache and sets it to the COMPLETE, fully
        # paginated list. Writing each page as it arrives would let a concurrent
        # list_tools observe a partial (page-1-only) cache mid-pagination.
        @mutex.synchronize do
          # The stream is peer-controlled: only ids some caller is actually
          # waiting on are stored. Without this check a server could stream
          # unsolicited responses with fresh ids and grow @sse_results without
          # bound for the lifetime of the client.
          unless @pending_request_ids.include?(data['id'])
            @logger.debug("Discarding unsolicited response id #{data['id'].inspect}")
            return true
          end

          @sse_results[data['id']] =
            if data['error']
              # JSON-RPC error response: store the error under a Symbol key
              # (JSON.parse only produces String keys, so this cannot collide
              # with a success result) for the waiter to raise ServerError.
              { error: data['error'] }
            else
              data['result']
            end
        end

        true
      end

      # Parse a raw SSE chunk into its :event, :data, :id fields
      # @param event_data [String] the raw SSE block
      # @return [Hash,nil] parsed fields or nil if it was pure comment/blank
      def parse_sse_event(event_data)
        event       = { event: 'message', data: '', id: nil }
        data_lines  = []
        has_content = false

        event_data.each_line do |line|
          line = line.chomp
          next if line.empty? # blank line
          next if line.start_with?(':') # SSE comment

          has_content = true
          if line.start_with?('event:')
            event[:event] = line[6..].strip
          elsif line.start_with?('data:')
            data_lines << line[5..].strip
          elsif line.start_with?('id:')
            event[:id] = line[3..].strip
          end
        end

        event[:data] = data_lines.join("\n")
        has_content ? event : nil
      end

      # Handle the special "endpoint" control frame (for SSE handshake).
      # The event data is a URI reference (MCP 2024-11-05 HTTP with SSE: the
      # server sends "an `endpoint` event containing a URI for the client to
      # use for sending messages") which must be resolved against the SSE
      # connection URL per RFC 3986 section 5.1.3, so relative endpoint URIs
      # POST to the URL the server actually designated.
      # @param data [String] the raw endpoint payload
      def handle_endpoint_event(data)
        endpoint = resolve_endpoint_uri(data)
        @mutex.synchronize do
          @rpc_endpoint = endpoint
          @sse_connected = true
          @connection_established = true
          @connection_cv.broadcast
        end
      end

      # Resolve an endpoint URI reference against the SSE connection URL.
      # The resolved endpoint MUST stay on the SSE connection's origin: the
      # event payload is server-controlled input, and honoring a cross-origin
      # target would redirect every JSON-RPC POST — including the configured
      # Authorization/API-key headers and callback response bodies — to a
      # server the caller never chose.
      # @param data [String] the endpoint event payload (absolute or relative URI)
      # @return [String] the absolute endpoint URL
      def resolve_endpoint_uri(data)
        endpoint = URI.join(@base_url, data)
        base = URI.parse(@base_url)
        unless same_origin?(base, endpoint)
          fail_endpoint_handshake!(
            "Cross-origin endpoint in SSE endpoint event: #{data.inspect} " \
            "does not match the connection origin #{origin_of(base)}"
          )
        end
        endpoint.to_s
      rescue URI::Error => e
        # The endpoint event is the handshake's core payload; an unresolvable
        # URI must fail the handshake rather than deferring a broken POST
        # target to the first request.
        @logger.error("Failed to resolve endpoint URI #{data.inspect} against #{@base_url}: #{e.message}")
        fail_endpoint_handshake!("Invalid endpoint URI in SSE endpoint event: #{data.inspect} (#{e.message})")
      end

      # Record the handshake failure cause and raise. The SSE worker thread
      # swallows this exception with a generic rescue, so also record the
      # failure (mirroring @auth_error) for the connect caller blocked in
      # wait_for_connection to surface promptly.
      # @param message [String] the failure description
      # @raise [MCPClient::Errors::TransportError] always
      def fail_endpoint_handshake!(message)
        @mutex.synchronize do
          @connection_error = message
          @connection_established = false
          @connection_cv.broadcast
        end
        raise MCPClient::Errors::TransportError, message
      end
    end
  end
end
