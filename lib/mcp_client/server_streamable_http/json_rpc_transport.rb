# frozen_string_literal: true

require_relative '../http_transport_base'

module MCPClient
  class ServerStreamableHTTP
    # JSON-RPC request/notification plumbing for Streamable HTTP transport
    # This transport uses HTTP POST requests but expects Server-Sent Event formatted responses
    module JsonRpcTransport
      include HttpTransportBase

      private

      # Log HTTP response for Streamable HTTP
      # @param response [Faraday::Response] the HTTP response
      def log_response(response)
        @logger.debug("Received Streamable HTTP response: #{response.status} #{response.body}")
      end

      # Parse a Streamable HTTP JSON-RPC response (JSON or SSE format)
      # @param response [Faraday::Response] the HTTP response
      # @return [Hash] the parsed result
      # @raise [MCPClient::Errors::TransportError] if parsing fails
      # @raise [MCPClient::Errors::ServerError] if the response contains an error
      def parse_response(response)
        body = response.body.strip
        content_type = response.headers['content-type'] || response.headers['Content-Type'] || ''

        # Determine response format based on Content-Type header per MCP 2025 spec
        data = if content_type.include?('text/event-stream')
                 # Parse SSE-formatted response for streaming
                 parse_sse_response(body)
               else
                 # Parse regular JSON response (default for Streamable HTTP)
                 JSON.parse(body)
               end

        process_jsonrpc_response(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
      end

      # Parse Server-Sent Event formatted response with event ID tracking
      # @param sse_body [String] the SSE formatted response body
      # @return [Hash] the parsed JSON data
      # @raise [MCPClient::Errors::TransportError] if no data found in SSE response
      def parse_sse_response(sse_body)
        # Extract JSON data and event ID from SSE format
        # SSE format: event: message\nid: 123\ndata: {...}\n\n
        data_lines = []
        event_id = nil

        sse_body.lines.each do |line|
          line = line.strip
          if line.start_with?('data:')
            data_lines << line.sub(/^data:\s*/, '').strip
          elsif line.start_with?('id:')
            event_id = line.sub(/^id:\s*/, '').strip
          end
        end

        raise MCPClient::Errors::TransportError, 'No data found in SSE response' if data_lines.empty?

        # Track the last event ID for resumability
        if event_id && !event_id.empty?
          @last_event_id = event_id
          @logger.debug("Tracking event ID for resumability: #{event_id}")
        end

        # Join multiline data fields according to SSE spec
        json_data = data_lines.join("\n")
        JSON.parse(json_data)
      end
    end
  end
end
