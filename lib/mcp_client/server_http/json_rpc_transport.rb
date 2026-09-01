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
        matched ||= tolerated_id_mismatch(responses, request_id)
        return matched if matched

        # The stream closed without the response: on a modern server the
        # request is lost and must be re-issued (see rpc_request).
        if modern?
          raise MCPClient::Errors::ResponseStreamClosedError, 'SSE stream closed before delivering the response'
        end

        raise MCPClient::Errors::TransportError, 'No JSON-RPC response found in SSE response'
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

      # The only response on a stream, when its id is not the one asked for.
      #
      # A legacy server that echoes ids loosely — a string where an integer
      # went out, or an id an intermediary rewrote — still gets the benefit of
      # the doubt. A modern one does not: no response to THIS request arrived,
      # so the request was lost and MCP 2026-07-28 says to re-issue it rather
      # than complete it with the answer to something else.
      # @param responses [Array<Hash>] the responses the stream carried
      # @param request_id [Integer, String, nil] id of the originating request
      # @return [Hash, nil] the response to accept, or nil to treat as lost
      def tolerated_id_mismatch(responses, request_id)
        return nil if modern? || responses.size != 1

        @logger.warn("SSE response id #{responses.first['id'].inspect} does not match request id " \
                     "#{request_id.inspect}; accepting the only response on the stream")
        responses.first
      end

      # Route a non-response message: notifications go to the callback, and a
      # server-initiated request is answered on a legacy stream and dropped on
      # a modern one.
      # @param message [Hash] a JSON-RPC request or notification
      # @return [void]
      def dispatch_sse_message(message)
        unless message.key?('id')
          invalidate_cache_for_notification(message['method'])
          @notification_callback&.call(message['method'], message['params'])
          return
        end

        # MCP 2026-07-28: "The server MUST NOT send independent JSON-RPC
        # requests on this stream" and clients MUST NOT POST responses to it,
        # so there is nothing to answer with.
        if modern?
          @logger.warn("Ignoring server-initiated request #{message['method']} on a response stream")
          return
        end

        answer_server_request(message)
      end

      # Answer a server-initiated request on a legacy (2025-11-25 and earlier)
      # response stream, where the server may send one and a receiver "MUST
      # respond promptly" to ping. This transport serves no other
      # server-initiated method — it has no elicitation, roots or sampling
      # callbacks — so those get the JSON-RPC method-not-found answer rather
      # than silence, which would leave the server waiting.
      # @param message [Hash] the server's JSON-RPC request
      # @return [void]
      def answer_server_request(message)
        send_http_request(server_request_answer(message))
      rescue StandardError => e
        @logger.error("Failed to answer server request #{message['method']}: #{e.message}")
      end

      # @param message [Hash] the server's JSON-RPC request
      # @return [Hash] the JSON-RPC response to POST back
      def server_request_answer(message)
        answer = { 'jsonrpc' => '2.0', 'id' => message['id'] }
        return answer.merge('result' => {}) if message['method'] == 'ping'

        @logger.warn("Answering unsupported server request #{message['method']} with method not found")
        answer.merge('error' => { 'code' => MCPClient::Errors::Codes::METHOD_NOT_FOUND,
                                  'message' => "Method not found: #{message['method']}" })
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
