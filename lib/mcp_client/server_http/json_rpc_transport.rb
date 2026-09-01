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
      # @param request [Hash, nil] the originating JSON-RPC request
      # @return [Hash] the parsed result
      # @raise [MCPClient::Errors::TransportError] if parsing fails
      # @raise [MCPClient::Errors::ServerError] if the response contains an error
      # A host's `conn.response :json` middleware decodes the body before it
      # reaches here — the README offers that middleware for the error path,
      # and it applies to every response — so an already-decoded object is
      # taken as it is rather than parsed a second time. An event-stream body
      # is never decoded by that middleware, so it is still the raw text.
      def parse_response(response, request = nil)
        # Host code a stream listener reached raised while the body was still
        # arriving: that is this exchange's failure (already marked as a
        # nested exchange's, so no recovery acts on it), raised in place of
        # the response it was interleaved with — as it is when the completed
        # body is parsed.
        failure = stream_listener_error(response)
        raise failure if failure

        body = response.body
        headers = response.respond_to?(:headers) ? response.headers || {} : {}
        content_type = headers['content-type'] || headers['Content-Type'] || ''
        # MCP 2026-07-28 Streamable HTTP: the server answers with either a
        # single JSON object or an SSE stream scoped to the request; the
        # client MUST support both.
        data = if content_type.include?('text/event-stream')
                 # Not stripped: the blank line that terminates the final
                 # event is what makes it a delivered event at all.
                 response_from_sse(body.to_s, request && request['id'], live_event_count(response))
               elsif body.is_a?(String)
                 JSON.parse(body.strip)
               else
                 body
               end
        process_jsonrpc_response(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{describe_parse_error(e)}"
      end

      # Every complete event of a response stream is handed over while the
      # body is still arriving, so a legacy server's request on the stream
      # is answered — and a progress notification delivered — before the
      # server has to end the response. A notification has no response
      # stream worth reading incrementally.
      # @param request [Hash] the JSON-RPC message being sent
      # @return [Proc, nil]
      def response_stream_listener(request)
        return nil unless request.is_a?(Hash) && request.key?('id')

        ->(event) { dispatch_live_sse_event(event) }
      end

      # Act on one event as it arrives: requests and notifications are
      # routed now, responses wait for the completed body. A failing
      # callback is not allowed to abort the read of the response it was
      # interleaved with: the capture middleware holds it and parse_response
      # raises it once the body is in.
      # @param event [String] one complete, LF-normalized SSE event
      # @return [void]
      def dispatch_live_sse_event(event)
        message = sse_event_message(event)
        dispatch_sse_message(message) if message && message['method']
      end

      # Pick the JSON-RPC response to the request out of an SSE-framed body,
      # forwarding request-scoped notifications (progress, log messages) to
      # the notification callback — except the `live` leading events, which
      # were already routed as they arrived. Server-initiated requests are
      # not permitted on a 2026-07-28 response stream and are dropped.
      # @param sse_body [String] the text/event-stream body
      # @param request_id [Integer, String, nil] id of the originating request
      # @param live [Integer] events already dispatched while the body arrived
      # @return [Hash] the JSON-RPC response
      # @raise [MCPClient::Errors::TransportError] when the stream carries no response
      def response_from_sse(sse_body, request_id, live = 0)
        responses = []
        saw_invalid_json = false
        sse_events(sse_body).each_with_index do |event, index|
          message = sse_event_message(event)
          saw_invalid_json = true if message.nil? && event.lines.any? { |l| l.start_with?('data:') }
          next unless message

          if message['method']
            dispatch_sse_message(message) if index >= live
          else
            responses << message
          end
        end
        matched = responses.find { |m| request_id.nil? || m['id'] == request_id || m['id'].to_s == request_id.to_s }
        matched ||= tolerated_id_mismatch(responses, request_id)
        return matched if matched

        # Every event that reaches here is terminated, so a data line that did
        # not parse is a delivered (malformed) answer rather than a break
        # inside one: the server ran the request, and re-issuing would run it
        # again.
        if saw_invalid_json
          raise MCPClient::Errors::TransportError,
                'Invalid JSON response from server: SSE event carried no valid JSON-RPC message'
        end

        # The stream closed without the response: on a modern server the
        # request is lost and must be re-issued (see rpc_request).
        if modern?
          raise MCPClient::Errors::ResponseStreamClosedError, 'SSE stream closed before delivering the response'
        end

        raise MCPClient::Errors::TransportError, 'No JSON-RPC response found in SSE response'
      end

      # Split a response stream into events, in the order and count the
      # stream listener saw them.
      #
      # SSE line terminators are CRLF, CR or LF; a server framing its events
      # with bare CR still delimits them, so normalize before splitting. An
      # event is dispatched at its terminating blank line, so a body that
      # ends inside an event delivered nothing for it: on a modern server
      # that event is dropped (and a missing response re-issued). A legacy
      # server keeps the benefit of the doubt this transport always gave it.
      # @param sse_body [String] the text/event-stream body
      # @return [Array<String>] the events, without their terminators
      def sse_events(sse_body)
        normalized = modern? ? complete_sse_events(sse_body) : normalize_sse_newlines(sse_body)
        events = normalized.split("\n\n", -1)
        events.pop if events.last.to_s.empty?
        events
      end

      # @param event [String] one LF-normalized SSE event
      # @return [Hash, nil] the JSON-RPC message its data lines carry, if any
      def sse_event_message(event)
        data_lines = event.lines.map(&:chomp).select { |l| l.start_with?('data:') }
        return nil if data_lines.empty?

        parse_sse_message(data_lines.map { |l| l.sub(/\Adata:\s*/, '') }.join("\n"))
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
        # Host code reached from here -- a notification listener -- may issue a
        # request of its own while the response that carried this message is
        # still being parsed. That request is an exchange of its own, and the
        # call still waiting for this response must keep both its recorded
        # definition and its own failures (HttpTransportBase::RequestRecovery#dispatching_to_host).
        dispatching_to_host { dispatch_sse_message_now(message) }
      end

      # @param message [Hash] a JSON-RPC request or notification
      # @return [void]
      def dispatch_sse_message_now(message)
        unless message.key?('id')
          route_notification(message['method'], message['params'])
          return
        end

        # MCP 2026-07-28: "The server MUST NOT send independent JSON-RPC
        # requests on this stream" and clients MUST NOT POST responses to it,
        # so there is nothing to answer with. Judged by the ESTABLISHED era:
        # while the probe is in flight the version is only a proposal, and a
        # legacy server may be waiting for its ping on the probe's stream.
        if protocol_era == :modern
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
