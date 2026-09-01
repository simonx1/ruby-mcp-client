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
      def parse_response(response, request = nil)
        body = response.body.strip
        headers = response.respond_to?(:headers) ? response.headers || {} : {}
        content_type = headers['content-type'] || headers['Content-Type'] || ''
        # MCP 2026-07-28 Streamable HTTP: the server answers with either a
        # single JSON object or an SSE stream scoped to the request; the
        # client MUST support both.
        data = if content_type.include?('text/event-stream')
                 response_from_sse(body, request && request['id'])
               else
                 JSON.parse(body)
               end
        process_jsonrpc_response(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{describe_parse_error(e)}"
      end

      # Pick the JSON-RPC response to the request out of an SSE-framed body,
      # forwarding request-scoped notifications (progress, log messages) to
      # the notification callback. Server-initiated requests are not
      # permitted on a 2026-07-28 response stream and are dropped.
      # @param sse_body [String] the text/event-stream body
      # @param request_id [Integer, String, nil] id of the originating request
      # @return [Hash] the JSON-RPC response
      # @raise [MCPClient::Errors::TransportError] when the stream carries no response
      def response_from_sse(sse_body, request_id)
        messages = sse_messages(sse_body)
        messages.select { |m| m['method'] }.each { |m| dispatch_sse_message(m) }
        responses = messages.reject { |m| m['method'] }
        matched = responses.find { |m| request_id.nil? || m['id'] == request_id || m['id'].to_s == request_id.to_s }
        matched ||= responses.first if responses.size == 1
        raise MCPClient::Errors::TransportError, 'No JSON-RPC response found in SSE response' unless matched

        matched
      end

      # @param sse_body [String] the text/event-stream body
      # @return [Array<Hash>] the JSON-RPC messages carried by its data lines
      def sse_messages(sse_body)
        sse_body.split(/\r?\n\r?\n/).filter_map do |event|
          data_lines = event.lines.map(&:chomp).select { |l| l.start_with?('data:') }
          next if data_lines.empty?

          parse_sse_message(data_lines.map { |l| l.sub(/\Adata:\s*/, '') }.join("\n"))
        end
      end

      # Route a non-response message: notifications go to the callback,
      # server-initiated requests are dropped.
      # @param message [Hash] a JSON-RPC request or notification
      # @return [void]
      def dispatch_sse_message(message)
        if message.key?('id')
          @logger.warn("Ignoring server-initiated request #{message['method']} on a response stream")
        else
          @notification_callback&.call(message['method'], message['params'])
        end
      end

      # @param json [String] one SSE event's data
      # @return [Hash, nil] the parsed JSON-RPC message, nil when unusable
      def parse_sse_message(json)
        message = JSON.parse(json)
        return message if message.is_a?(Hash)

        @logger.warn("Skipping non-object JSON-RPC message in SSE event (#{message.class})")
        nil
      rescue JSON::ParserError => e
        @logger.warn("Skipping invalid JSON in SSE event: #{describe_parse_error(e, json)}")
        nil
      end
    end
  end
end
