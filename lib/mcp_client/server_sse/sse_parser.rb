# frozen_string_literal: true

require 'json'

module MCPClient
  class ServerSSE
    # === Wire-level SSE parsing & dispatch ===
    module SseParser
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

          return if process_error_in_message(data)
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

      # Process a JSON-RPC error() in the SSE stream.
      # @param data [Hash] the parsed JSON payload
      # @return [Boolean] true if we saw & handled an error
      def process_error_in_message(data)
        return unless data['error']

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

        @mutex.synchronize do
          @tools_data = data['result']['tools'] if data['result'] && data['result']['tools']

          @sse_results[data['id']] =
            if data['error']
              { 'isError' => true,
                'content' => [{ 'type' => 'text', 'text' => data['error'].to_json }] }
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

      # Handle the special "endpoint" control frame (for SSE handshake)
      # @param data [String] the raw endpoint payload
      def handle_endpoint_event(data)
        @mutex.synchronize do
          @rpc_endpoint = data
          @sse_connected = true
          @connection_established = true
          @connection_cv.broadcast
        end
      end
    end
  end
end
