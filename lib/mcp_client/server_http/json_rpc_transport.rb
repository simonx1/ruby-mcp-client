# frozen_string_literal: true

require_relative '../http_transport_base'

module MCPClient
  class ServerHTTP
    # JSON-RPC request/notification plumbing for HTTP transport
    module JsonRpcTransport
      include HttpTransportBase

      private

      # Parse an HTTP JSON-RPC response
      # @param response [Faraday::Response] the HTTP response
      # @return [Hash] the parsed result
      # @raise [MCPClient::Errors::TransportError] if parsing fails
      # @raise [MCPClient::Errors::ServerError] if the response contains an error
      def parse_response(response)
        data = JSON.parse(response.body)
        process_jsonrpc_response(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
      end
    end
  end
end
