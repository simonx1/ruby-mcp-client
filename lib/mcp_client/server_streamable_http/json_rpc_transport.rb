# frozen_string_literal: true

require_relative '../http_transport_base'

require 'zlib'
require 'stringio'

module MCPClient
  class ServerStreamableHTTP
    # JSON-RPC request/notification plumbing for Streamable HTTP transport
    # This transport uses HTTP POST requests but expects Server-Sent Event formatted responses
    module JsonRpcTransport
      include HttpTransportBase

      # Default ceiling on the expanded size of a gzip-encoded response body.
      # The peer controls the compression ratio, so without a bound a tiny
      # compressed response ("gzip bomb") could expand to an arbitrarily large
      # string and exhaust host memory before JSON parsing.
      #
      # Hosts that legitimately exchange very large payloads (e.g. base64
      # resource blobs or audio) can raise it per server with the
      # max_decompressed_body_bytes option, so that whether a response is
      # accepted does not depend on the server's choice to gzip it.
      MAX_DECOMPRESSED_BODY_BYTES = 64 * 1024 * 1024
      DECOMPRESS_CHUNK_BYTES = 64 * 1024

      private

      # Whether a server-supplied SSE event id may be retained as the
      # resumption cursor: non-empty, bounded, and safe to place in an HTTP
      # header. Shared by every SSE parsing path (GET events stream, POST
      # response stream, and resumed GET), since all three feed the same
      # Last-Event-ID header.
      # @param id [String, nil] the raw id field
      # @return [Boolean]
      def retainable_event_id?(id)
        return false if id.nil? || id.empty?

        if id.length > MAX_EVENT_ID_LENGTH
          @logger.warn("Ignoring oversized SSE event id (#{id.length} chars)")
          return false
        end

        return true if id.match?(EVENT_ID_PATTERN)

        @logger.warn('Ignoring SSE event id with characters illegal in a header value')
        false
      end

      # Log HTTP response for Streamable HTTP
      # @param response [Faraday::Response] the HTTP response
      def log_response(response)
        @logger.debug("Received Streamable HTTP response: #{response.status} (#{describe_body_size(response.body)})")
      end

      # Parse a Streamable HTTP JSON-RPC response (JSON or SSE format)
      # @param response [Faraday::Response] the HTTP response
      # @param request [Hash, nil] the originating JSON-RPC request, used to match the response by id
      # @return [Hash] the parsed result
      # @raise [MCPClient::Errors::TransportError] if parsing fails
      # @raise [MCPClient::Errors::ServerError] if the response contains an error
      def parse_response(response, request = nil)
        body = response.body
        content_type = response.headers['content-type'] || response.headers['Content-Type'] || ''
        content_encoding = response.headers['content-encoding'] || response.headers['Content-Encoding'] || ''

        body = decompress_gzip(body) if content_encoding.include?('gzip')

        # Determine response format based on Content-Type header per MCP 2025 spec
        data = if content_type.include?('text/event-stream')
                 # Parse SSE-formatted response for streaming. The body is
                 # not stripped: its final blank line is the last event's
                 # terminator, and without it that event was never dispatched.
                 parse_sse_response(body.to_s, request && request['id'], live_event_count(response))
               elsif body.is_a?(String)
                 # Parse regular JSON response (default for Streamable HTTP)
                 JSON.parse(body.strip)
               else
                 # A host's `conn.response :json` middleware decodes the body
                 # before it reaches here — the README offers that middleware
                 # for the error path, and it applies to every response — so an
                 # already-decoded object is taken as it is rather than parsed
                 # a second time. An event-stream body is not JSON and reaches
                 # the branch above as the text it was sent as.
                 body
               end

        process_jsonrpc_response(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{describe_parse_error(e)}"
      rescue Zlib::Error => e
        # Streamable HTTP always offers gzip, so a stream that stops before the
        # gzip footer arrives here rather than as a socket failure. No response
        # was delivered, which on a modern server means the in-flight request
        # is lost and MUST be re-issued with a new id. A body that is complete
        # but corrupt (bad CRC, bad deflate data) was not cut short: the
        # server answered, badly, and running the request again would not
        # make it answer better.
        unless modern? && truncated_gzip?(e)
          raise MCPClient::Errors::TransportError, "Invalid gzip response from server: #{e.message}"
        end

        # A stream cut after the deflate data — footer only — still delivered
        # its answer; a delivered answer settles the request, as on a socket
        # that died after the final event (re-issuing would run it again).
        delivered = delivered_before_truncation(response, request, e)
        return delivered unless delivered.nil?

        raise MCPClient::Errors::ResponseStreamClosedError,
              "Response stream closed before delivering the response: #{e.message}"
      end

      # The answer a gzip body that lost its footer delivered, parsed the
      # ordinary way; nil when the deflate data itself stopped short of it.
      # @param response [Faraday::Response] the response whose body failed to decode
      # @param request [Hash, nil] the originating JSON-RPC request
      # @param error [Zlib::Error] the decode failure
      # @return [Object, nil] the parsed result
      def delivered_before_truncation(response, request, error)
        return nil unless request.is_a?(Hash) && request.key?('id')

        body = inflate_delivered_gzip(response.body.to_s)
        return nil if body.nil? || body.empty?

        sse = sse_framed_body?(body)
        body = complete_sse_events(body) if sse
        return nil if body.empty? || !body_carries_response?(body, sse, request['id'])

        @logger.warn("Response stream ended after the response arrived (#{error.message}); " \
                     "keeping the delivered #{request['method']} response instead of re-issuing it")
        data = sse ? parse_sse_response(body, request['id'], live_event_count(response)) : JSON.parse(body.strip)
        process_jsonrpc_response(data)
      end

      # Every complete event of a response stream is handed over while the
      # body is still arriving, so a progress notification reaches the host
      # before the tool finishes — and before a timeout ends the stream —
      # and a legacy server's request on the stream is answered before the
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
      # callback is logged rather than allowed to abort the read of the
      # response it was interleaved with.
      # @param event [String] one complete, LF-normalized SSE event
      # @return [void]
      def dispatch_live_sse_event(event)
        events, = extract_sse_events("#{event}\n\n")
        events.each do |parsed|
          track_sse_event_id(parsed)
          message = sse_event_json_rpc_message(parsed)
          dispatch_server_message(message) if message.is_a?(Hash) && message['method']
        end
      rescue StandardError => e
        @logger.error("Error handling a message on the response stream: #{e.message}")
      end

      # How many of the events the completed body splits into were handed to
      # the stream listener while it arrived: the scanner counts every
      # terminated block, blank or comment-only ones included, so the same
      # split maps its count onto the events the body parser keeps.
      # @param sse_body [String] the text/event-stream body
      # @param live [Integer] blocks the scanner dispatched
      # @return [Integer] events among them the body parser would keep
      def live_message_events(sse_body, live)
        return 0 if live.zero?

        blocks = normalize_sse_newlines(sse_body).split("\n\n", -1)
        blocks.first(live).count { |block| block.lines.any? { |line| line.strip.start_with?('data:', 'id:') } }
      end

      # Whether a gzip failure means the body stopped before its end rather
      # than carrying bad data.
      # @param error [Zlib::Error] the decompression failure
      # @return [Boolean]
      def truncated_gzip?(error)
        error.is_a?(Zlib::GzipFile::NoFooter) || error.is_a?(Zlib::BufError) ||
          error.message.to_s.match?(/unexpected end|footer/i)
      end

      # Incrementally decompress a gzip response body, aborting once the
      # expanded output exceeds the configured ceiling.
      # @param body [String] the gzip-compressed response body
      # @return [String] the decompressed body
      # @raise [MCPClient::Errors::ResponseTooLargeError] if the expansion limit is exceeded
      def decompress_gzip(body)
        limit = max_decompressed_body_bytes
        reader = Zlib::GzipReader.new(StringIO.new(body))
        decompressed = +''
        while (chunk = reader.read(DECOMPRESS_CHUNK_BYTES))
          decompressed << chunk
          next unless decompressed.bytesize > limit

          # ResponseTooLargeError (not a plain TransportError) so with_retry
          # does not re-POST a request the server has already executed.
          raise MCPClient::Errors::ResponseTooLargeError,
                "Gzip response expanded beyond #{limit} bytes"
        end
        decompressed
      ensure
        reader&.close
      end

      # Configured ceiling for decompressed response bodies.
      # @return [Integer] positive byte limit
      def max_decompressed_body_bytes
        configured = defined?(@max_decompressed_body_bytes) ? @max_decompressed_body_bytes : nil
        configured || MAX_DECOMPRESSED_BODY_BYTES
      end

      # Parse a Server-Sent Event formatted response body.
      #
      # Per MCP 2025-11-25, the server MAY send JSON-RPC requests and
      # notifications on the POST response stream before the response, and MAY
      # send priming events carrying only an event id. Every interleaved server
      # message is dispatched exactly like on the GET events stream; the
      # JSON-RPC response matching the originating request id is returned.
      #
      # @param sse_body [String] the SSE formatted response body
      # @param request_id [Integer, String, nil] id of the originating request
      # @return [Hash] the parsed JSON-RPC response
      # @raise [MCPClient::Errors::TransportError] if no response is found
      def parse_sse_response(sse_body, request_id = nil, live = 0)
        events, retry_ms = extract_sse_events(sse_body)

        if events.empty?
          # An empty stream is a stream that closed before delivering the
          # response; on a modern server that means re-issue, not resume.
          if modern?
            raise MCPClient::Errors::ResponseStreamClosedError, 'SSE stream closed before delivering the response'
          end

          raise MCPClient::Errors::TransportError, 'No data found in SSE response'
        end

        responses, saw_invalid_json = route_sse_events(events, live_message_events(sse_body, live))
        matched = select_sse_response(responses, request_id)
        return matched if matched

        # Every event that reaches here is terminated: an unterminated final
        # event is dropped before parsing. So invalid JSON is not a break that
        # landed inside an event — the server processed the request and
        # answered, however badly, and re-issuing would run it a second time.
        if saw_invalid_json
          raise MCPClient::Errors::TransportError,
                'Invalid JSON response from server: SSE stream contained no valid JSON-RPC response'
        end

        # A stream that ended between events carries no answer at all: the
        # in-flight request was lost and takes the re-issue path (2026-07-28
        # changelog, major change 9).
        resume_or_fail(events, request_id, retry_ms)
      end

      # SEP-1699 polling pattern: the server MAY close the POST stream before
      # delivering the response. When a cursor was received, resume via HTTP
      # GET with Last-Event-ID instead of re-POSTing the (possibly
      # non-idempotent) request.
      # @param events [Array<Hash>] parsed SSE events
      # @param request_id [Integer, String, nil] id of the originating request
      # @param retry_ms [Integer, nil] retry directive received on THIS stream
      # @return [Hash] the replayed JSON-RPC response
      # @raise [MCPClient::Errors::ServerError] when resumption fails
      # @raise [MCPClient::Errors::TransportError] when no cursor was received
      def resume_or_fail(events, request_id, retry_ms = nil)
        # MCP 2026-07-28 removed SSE resumability: the in-flight request is
        # lost and must be re-issued as a new request (see rpc_request).
        if modern?
          raise MCPClient::Errors::ResponseStreamClosedError,
                'SSE stream closed before delivering the response'
        end

        # Only a validated id may become a cursor: it is sent back as a
        # Last-Event-ID header on the resumption GET.
        cursor = events.reverse.find { |e| retainable_event_id?(e[:id]) }&.dig(:id)
        if request_id && cursor
          # Resume with THIS stream's cursor and retry directive (both are
          # per-stream), not the shared @last_event_id / @sse_retry_ms which a
          # concurrent stream may have moved between parsing and resumption.
          resumed = resume_response_via_get(request_id, cursor, retry_ms)
          return resumed if resumed

          # Non-retryable: the request may already be executing server-side,
          # so a blind re-POST could run a non-idempotent operation twice.
          raise MCPClient::Errors::ServerError,
                'SSE stream closed before delivering the response and resumption via GET failed'
        end

        raise MCPClient::Errors::TransportError, 'No JSON-RPC response found in SSE response'
      end

      # Split an SSE body into events. An event without an explicit `event:`
      # field has the default type "message" per the SSE specification; events
      # carrying only an id (priming events) are kept so their id is tracked.
      # @param sse_body [String] the SSE formatted response body
      # @return [Array(Array<Hash>, Integer, nil)] parsed events and the last
      #   retry directive (ms) received on this stream, if any
      def extract_sse_events(sse_body)
        events = []
        retry_ms = nil
        current_event = { type: 'message', data_lines: [], id: nil }

        # SSE line terminators are CRLF, CR or LF; a server framing its events
        # with bare CR still delimits them, so normalize before splitting.
        normalize_sse_newlines(sse_body).lines.each do |line|
          line = line.strip

          if line.empty?
            # Empty line marks end of an event
            events << current_event.dup if sse_event_present?(current_event)
            current_event = { type: 'message', data_lines: [], id: nil }
          elsif line.start_with?('event:')
            current_event[:type] = line.sub(/^event:\s*/, '').strip
          elsif line.start_with?('data:')
            current_event[:data_lines] << line.sub(/^data:\s*/, '').strip
          elsif line.start_with?('id:')
            current_event[:id] = line.sub(/^id:\s*/, '').strip
          elsif line.start_with?('retry:')
            # SEP-1699: the client MUST respect the server's retry directive.
            # Track it locally for this stream's resumption; the shared ivar is
            # only a hint for the general events loop.
            raw = line.sub(/^retry:\s*/, '').strip
            if raw.match?(/\A\d+\z/)
              retry_ms = raw.to_i
              @sse_retry_ms = retry_ms
            end
          end
        end

        # An event is dispatched at its terminating blank line, so a body that
        # ends inside an event delivered nothing for it. On a modern server
        # the event is dropped — and a missing response re-issued — exactly
        # as when the socket cut it; a legacy server keeps the benefit of the
        # doubt this transport always gave it.
        if sse_event_present?(current_event)
          if modern?
            @logger.warn('Dropping an SSE event the response stream ended without terminating')
          else
            events << current_event
          end
        end
        [events, retry_ms]
      end

      # @param event [Hash] a parsed SSE event
      # @return [Boolean] whether the event carries any data or id
      def sse_event_present?(event)
        (event[:id] && !event[:id].empty?) || !event[:data_lines].empty?
      end

      # Track event ids for resumability, dispatch interleaved server messages
      # (requests, notifications, pings) and collect response candidates.
      # @param events [Array<Hash>] parsed SSE events
      # @param live [Integer] leading events already routed as they arrived
      # @return [Array(Array<Hash>, Boolean)] response candidates and whether invalid JSON was seen
      def route_sse_events(events, live = 0)
        responses = []
        saw_invalid_json = false

        events.each_with_index do |event, index|
          track_sse_event_id(event) if index >= live
          message = sse_event_json_rpc_message(event)
          saw_invalid_json = true if message == :invalid
          next unless message.is_a?(Hash)

          if message['method']
            dispatch_server_message(message) if index >= live
          else
            responses << message
          end
        end

        [responses, saw_invalid_json]
      end

      # The POST SSE stream is peer-controlled like the GET one, so its ids
      # get the same bound/charset check before being retained or echoed in
      # a Last-Event-ID header.
      # @param event [Hash] a parsed SSE event
      # @return [void]
      def track_sse_event_id(event)
        return unless event[:id] && !event[:id].empty? && !modern?

        @mutex.synchronize { @last_event_id = event[:id] } if retainable_event_id?(event[:id])
        @logger.debug("Tracking event ID for resumability: #{event[:id]}")
      end

      # @param event [Hash] a parsed SSE event
      # @return [Hash, Symbol, nil] its JSON-RPC message, :invalid, or nil for
      #   an event of another type or without an object payload
      def sse_event_json_rpc_message(event)
        return nil unless event[:type] == 'message'

        parse_sse_event_data(event[:data_lines].join("\n"))
      end

      # Parse the data payload of a single SSE event.
      # @param json_data [String] the joined data lines
      # @return [Hash, Symbol, nil] the parsed message, :invalid, or nil for empty/non-object data
      def parse_sse_event_data(json_data)
        return nil if json_data.empty?

        message = JSON.parse(json_data)
        return message if message.is_a?(Hash)

        # Type only: the value is peer-controlled payload and may carry tool
        # arguments, results or elicitation content.
        @logger.warn("Skipping non-object JSON-RPC message in SSE event (#{message.class})")
        nil
      rescue JSON::ParserError => e
        @logger.warn("Skipping invalid JSON in SSE event: #{describe_parse_error(e, json_data)}")
        :invalid
      end

      # Choose the JSON-RPC response answering the originating request.
      # @param responses [Array<Hash>] response candidates from the stream
      # @param request_id [Integer, String, nil] id of the originating request
      # @return [Hash, nil] the selected response, if any
      def select_sse_response(responses, request_id)
        matched = if request_id.nil?
                    responses.first
                  else
                    responses.find { |msg| msg['id'] == request_id || msg['id'].to_s == request_id.to_s }
                  end

        # A legacy server that echoes ids loosely — a string where an integer
        # went out, or an id an intermediary rewrote — gets the benefit of the
        # doubt when its stream carried exactly one response. A modern one
        # does not: no response to THIS request arrived, so the request was
        # lost and MCP 2026-07-28 says to re-issue it rather than complete it
        # with the answer to something else.
        if matched.nil? && responses.length == 1 && !modern?
          matched = responses.first
          @logger.warn(
            "SSE response id #{matched['id'].inspect} does not match request id #{request_id.inspect}; " \
            'accepting the only response on the stream'
          )
        end

        matched
      end
    end
  end
end
