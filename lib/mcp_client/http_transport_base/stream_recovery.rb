# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # What a response stream that broke leaves behind, and what to make of it.
    #
    # MCP 2026-07-28 has no resumption: "a broken response stream loses the
    # in-flight request; clients MUST re-issue it as a new request with a new
    # request ID". Faraday discards a partially read body and raises, so
    # without capturing the bytes as they arrive a break *after* the final
    # event is indistinguishable from one before it -- and re-issuing then
    # runs a completed call a second time.
    module StreamRecovery
      # Innermost Faraday middleware: streams the response body into a
      # per-request buffer so that
      #
      # 1. a socket failure mid-body still leaves the bytes that did arrive
      #    (Faraday discards a partially read body and raises), letting a
      #    response that was fully delivered settle its request instead of being
      #    re-issued and executed twice; and
      # 2. a deadline can be enforced while the body is arriving, which a socket
      #    timeout alone cannot do for a stream that keeps dripping keep-alives.
      #
      # It restores the buffer as the response body, and being the innermost
      # handler its on_complete runs before any user middleware (raise_error and
      # friends) looks at that body.
      class ResponseBodyCapture < Faraday::Middleware
        # @param env [Faraday::Env] the outgoing request environment
        # @return [void]
        def on_request(env)
          state = env.request&.context
          buffer = state && state[:mcp_body_buffer]
          return unless buffer

          # The retry middleware sits above this one and replays the whole inner
          # stack, so each attempt must start from an empty buffer (and from an
          # empty event scanner: the count of events dispatched while the body
          # arrived belongs to the attempt whose body is finally parsed).
          buffer.clear
          listener = state[:mcp_stream_listener]
          scanner = listener && SseEventScanner.new(max_inflated_bytes: state[:mcp_inflate_limit])
          state[:mcp_live_events] = 0
          # The adapter fills this same env in as it reads: its status is set
          # from the status line, so a salvaged answer can be rebuilt under the
          # status it really arrived with. The era rule reads a recognized
          # modern error only under the status it came with.
          state[:mcp_env] = env
          env.request.on_data = lambda do |chunk, _size, _env|
            # Before the chunk is kept, never after: bytes that arrive past the
            # deadline are not part of an answer this request may settle on, and
            # buffering them first would let the salvage hand back an answer the
            # caller had already stopped waiting for.
            deadline = state[:mcp_deadline]
            raise Faraday::TimeoutError, 'Request exceeded its deadline' if deadline && monotonic_now > deadline

            buffer << chunk.to_s
            # Only a streamed body can be measured against its Content-Length
            # here; a response the adapter hands over whole never reaches this.
            state[:mcp_streamed] = true

            next unless scanner

            # Every complete event is handed over as it arrives, so a server
            # request or a progress notification on the stream is acted on
            # while the response is still open (a server that waits for its
            # ping to be answered before sending the result would otherwise
            # deadlock against a client that answers only at EOF).
            scanner.feed(chunk.to_s) { |event| listener.call(event) }
            state[:mcp_live_events] = scanner.count
          end
        end

        # @param env [Faraday::Env] the completed request environment
        # @return [void]
        def on_complete(env)
          state = env.request&.context
          buffer = state && state[:mcp_body_buffer]
          env.body = buffer.dup if buffer && env.body.to_s.empty?
          state[:mcp_short_body] = short_body?(env, state, buffer) if state
        end

        private

        # Whether a streamed body stopped short of the length it promised.
        #
        # A Content-Length body that ends early does not raise: Net::HTTP hands
        # back what arrived as if it were whole, and only the promised length
        # says the exchange was cut. Read as a malformed body it would look like
        # a server that speaks bad JSON, and the request the stream took with it
        # would never be re-issued.
        # @param env [Faraday::Env] the completed request environment
        # @param state [Hash] the capture state
        # @param buffer [String, nil] the bytes this exchange streamed
        # @return [Boolean]
        def short_body?(env, state, buffer)
          return false unless buffer && state[:mcp_streamed]

          declared = env.response_headers && (env.response_headers['content-length'] ||
                                              env.response_headers['Content-Length'])
          return false if declared.nil? || !declared.to_s.match?(/\A\d+\z/)

          buffer.bytesize < declared.to_i
        end

        # @return [Float] a monotonic clock reading in seconds
        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # Translate a Faraday socket failure into the MCP error the caller must
      # act on.
      #
      # A response stream that dies mid-body is what a broken stream actually
      # looks like on the wire: Faraday raises rather than handing back a
      # truncated body, so it never reaches the SSE parser that recognises a
      # stream which closed *between* events. MCP 2026-07-28 has no resumption
      # — "a broken response stream loses the in-flight request; clients MUST
      # re-issue it as a new request with a new request ID" (changelog, major
      # change 9) — and the rule does not care where the break landed. Raising
      # ResponseStreamClosedError puts both breaks on the one re-issue path.
      #
      # A failure that never got the request out, and a notification (which has
      # no response to lose), stay a plain ConnectionError.
      # @param error [Faraday::ConnectionFailed, Faraday::SSLError] the socket failure
      # @param request [Hash] the JSON-RPC message that was being sent
      # @return [MCPClient::Errors::MCPError] the error to raise
      def connection_failure_error(error, request)
        if modern? && request.is_a?(Hash) && request.key?('id') && interrupted_exchange?(error)
          return MCPClient::Errors::ResponseStreamClosedError.new(
            "Response stream closed before delivering the response: #{error.message}"
          )
        end

        MCPClient::Errors::ConnectionError.new("Server connection lost: #{error.message}")
      end

      # Faraday wraps every socket failure in ConnectionFailed (or, for TLS, in
      # SSLError), whether the connection was never established or it broke with
      # a request in flight; only the wrapped exception distinguishes them.
      # @param error [Faraday::ConnectionFailed, Faraday::SSLError] the socket failure
      # @return [Boolean] true when the exchange had started when it broke
      def interrupted_exchange?(error)
        cause = (error.wrapped_exception if error.respond_to?(:wrapped_exception)) || error.cause
        return false if tls_handshake_failure?(cause)

        INTERRUPTED_EXCHANGE_ERRORS.any? { |klass| cause.is_a?(klass) }
      end

      # OpenSSL names the failing operation in its message. A handshake that
      # never completed ("SSL_connect ... certificate verify failed") means the
      # request never left this client, so there is nothing in flight to
      # replace; a body that dies mid-read ("SSL_read: unexpected eof while
      # reading") is a broken response stream like any other.
      # @param cause [Exception, nil] the exception Faraday wrapped
      # @return [Boolean] true when TLS failed before the request was sent
      def tls_handshake_failure?(cause)
        cause.is_a?(OpenSSL::SSL::SSLError) && cause.message.to_s.include?('SSL_connect')
      end

      # The response that did arrive before the socket died, when the stream
      # carried this request's complete answer.
      #
      # Faraday discards a partially read body and raises, so without the
      # streamed capture a break after the final SSE event is indistinguishable
      # from a break before it — and re-issuing there would run a tools/call the
      # server already executed a second time. MCP 2026-07-28's re-issue rule is
      # about an in-flight request that was *lost*; a delivered response settles
      # its request, however the socket ends afterwards.
      # A socket that stalls after the final event until the timeout is the
      # same case from the other direction: the answer arrived, the framing
      # after it did not.
      # @param partial_body [String, nil] the bytes captured before the failure
      # @param request [Hash] the JSON-RPC message that was being sent
      # @param error [Faraday::Error] the socket failure or timeout
      # @param capture [Hash, nil] the capture state of the failed exchange
      # @return [NormalizedResponse, nil] a response carrying the delivered answer
      def salvaged_response(partial_body, request, error, capture = nil)
        return nil unless modern? && request.is_a?(Hash) && request.key?('id')
        return nil unless error.is_a?(Faraday::TimeoutError) || interrupted_exchange?(error)

        body = partial_body.to_s
        body = inflate_delivered_gzip(body) if body.b.start_with?(SseEventScanner::GZIP_MAGIC)
        return nil if body.nil? || body.empty?

        sse = sse_framed_body?(body)
        # A truncated stream's last event has no terminating blank line, so it
        # was never dispatched (HTML SSE parsing rules) and must be dropped
        # before asking whether the answer arrived.
        body = complete_sse_events(body) if sse
        return nil if body.empty? || !body_carries_response?(body, sse, request['id'])

        @logger.warn("Response stream ended after the response arrived (#{error.message}); " \
                     "keeping the delivered #{request['method']} response instead of re-issuing it")
        NormalizedResponse.new(delivered_status(capture),
                               { 'content-type' => sse ? 'text/event-stream' : 'application/json' }, body,
                               capture)
      end

      # The status a salvaged answer arrived under. A well-formed -32022 in a
      # 400 body identifies a modern server and is retried with an advertised
      # version, while the same body under 200 is a permissive legacy echo:
      # rebuilding every salvaged answer as 200 would turn the first into the
      # second. The adapter fills the captured env in as it reads, so its status
      # is the status line this response really carried.
      # @param capture [Hash, nil] the capture state of the failed exchange
      # @return [Integer]
      def delivered_status(capture)
        (capture.is_a?(Hash) && capture[:mcp_env]&.status) || 200
      end

      # What a body that stopped short of its Content-Length settles: the
      # answer if it is all there anyway (the bytes that arrived carry this
      # request's response, and the rest was framing), otherwise the loss the
      # re-issue rule is written for.
      # @param request [Hash] the JSON-RPC message that was being sent
      # @param capture [Hash] the capture state of the exchange
      # @return [NormalizedResponse] the delivered answer
      # @raise [MCPClient::Errors::MCPError] when the response was lost
      def truncated_body_outcome(request, capture)
        error = Faraday::ConnectionFailed.new(EOFError.new('response body stopped short of its Content-Length'))
        salvaged = salvaged_response(capture[:mcp_body_buffer], request, error, capture)
        return settled_salvage(salvaged) if salvaged

        raise connection_failure_error(error, request)
      end

      # A salvaged answer read the way the unbroken path reads one: an error
      # status it arrived under still becomes the typed JSON-RPC error, so a
      # recognized modern error keeps the status the era rule needs. Returning
      # it unread would settle a 400 rejection as if it were a 200 result.
      # @param salvaged [NormalizedResponse] the response the salvage rebuilt
      # @return [NormalizedResponse] the same response, once it is an answer
      # @raise [MCPClient::Errors::MCPError] whatever its status and body say
      def settled_salvage(salvaged)
        handle_http_error_response(salvaged) unless (200..299).cover?(salvaged.status.to_i)
        salvaged
      end

      # Per the SSE specification a line is terminated by CRLF, CR or LF alone;
      # normalizing to LF lets one set of framing rules serve all three.
      # @param body [String] a response body
      # @return [String] the body with LF line terminators
      def normalize_sse_newlines(body)
        without_bom(body).gsub(/\r\n|\r/, "\n")
      end

      # The UTF-8 decode step of the SSE algorithm drops one leading byte-order
      # mark; the field it precedes must still be recognized.
      # @param body [String] a response body
      # @return [String]
      def without_bom(body)
        bom = body.encoding == Encoding::BINARY ? SseEventScanner::BOM : "\uFEFF".encode(body.encoding)
        body.start_with?(bom) ? body[bom.length..] : body
      rescue EncodingError
        body
      end

      # @param body [String] an LF-normalized SSE body
      # @return [Array<String>] the joined data payload of each event
      def sse_data_payloads(body)
        body.split("\n\n").filter_map do |event|
          lines = event.lines.map(&:chomp).select { |line| line.start_with?('data:') }
          next if lines.empty?

          lines.map { |line| line.sub(/\Adata:\s*/, '') }.join("\n")
        end
      end
    end
  end
end
