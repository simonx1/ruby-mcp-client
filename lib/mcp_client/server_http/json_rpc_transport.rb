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
      # @param _request [Hash, nil] the originating JSON-RPC request (unused)
      # @return [Hash] the parsed result
      # @raise [MCPClient::Errors::TransportError] if parsing fails
      # @raise [MCPClient::Errors::ServerError] if the response contains an error
      # A host's `conn.response :json` middleware decodes the body before it
      # reaches here — the README offers that middleware for the error path,
      # and it applies to every response — so an already-decoded object is
      # taken as it is rather than parsed a second time.
      def parse_response(response, _request = nil)
        body = response.body
        data = body.is_a?(String) ? JSON.parse(body.strip) : body
        process_jsonrpc_response(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{describe_parse_error(e)}"
      end
    end
  end
end
