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

      # Parse a Streamable HTTP JSON-RPC response (in SSE format)
      # @param response [Faraday::Response] the HTTP response
      # @return [Hash] the parsed result
      # @raise [MCPClient::Errors::TransportError] if parsing fails
      # @raise [MCPClient::Errors::ServerError] if the response contains an error
      def parse_response(response)
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

        raise MCPClient::Errors::TransportError, 'No data found in SSE response' unless data_line

        json_data = data_line.sub(/^data:\s*/, '').strip
        JSON.parse(json_data)
      end
    end
  end
end
