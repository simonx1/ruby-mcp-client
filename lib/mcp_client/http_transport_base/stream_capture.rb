# frozen_string_literal: true

require 'zlib'
require_relative 'bounded_inflate'

module MCPClient
  module HttpTransportBase
    # How one HTTP exchange is bounded and read as it arrives: the socket
    # timeout and overall deadline of a request, the listener that gets the
    # response stream's events while the body is still open, and the count
    # of events it already handled once the completed body is parsed.
    module StreamCapture
      private

      # The socket timeout and the overall deadline of one HTTP exchange.
      #
      # MCP 2026-07-28 cancellation/timeouts: implementations "SHOULD always
      # enforce a maximum timeout regardless of progress". Faraday's socket
      # timeout only bounds the gap between reads, which a stream of keep-alive
      # comments resets forever, so every request gets a deadline the capture
      # middleware checks as the body arrives. A caller-supplied deadline (the
      # probe and its re-issue share one) is honoured as the time left on it:
      # the socket timeout is clamped to it, so a silent server cannot stretch
      # the replacement out to a full timeout of its own.
      # @param timeout [Numeric, nil] per-request timeout override
      # @param deadline [Float, nil] monotonic instant the exchange must finish by
      # @return [Array(Numeric, Float)] the socket timeout and the deadline
      # @raise [MCPClient::Errors::RequestTimeoutError] when the deadline already passed
      def request_bounds(timeout, deadline)
        budget = timeout || @read_timeout
        return [budget, budget && (monotonic_now + budget)] unless deadline

        remaining = deadline - monotonic_now
        raise MCPClient::Errors::RequestTimeoutError, 'Request timed out: its deadline has passed' if remaining <= 0

        [budget ? [budget, remaining].min : remaining, deadline]
      end

      # Run one HTTP exchange under its deadline, whatever the socket does.
      #
      # Faraday's socket timeout bounds the gap between reads, and every read
      # restarts it: a server that sends an event late in the budget, or head
      # bytes forever, outlives the bound the caller asked for — the second
      # never even reaches the body callback that checks the deadline. MCP
      # 2026-07-28 cancellation/timeouts asks for a maximum timeout "regardless
      # of progress", so a watchdog ends the exchange at the deadline whatever
      # the socket is doing.
      #
      # Raising into the requesting thread is the only way to break its
      # blocking read from outside. The watchdog fires at most once, never
      # after the request settled, and is always torn down; if it loses the
      # race by the microseconds between the answer arriving and the request
      # being marked settled, the answer stands rather than the timeout.
      # @param deadline [Float, nil] monotonic instant the exchange must finish by
      # @return [Object] whatever the block returns
      # @raise [Faraday::TimeoutError] when the deadline passes first
      def with_request_watchdog(deadline)
        return yield unless deadline

        target = Thread.current
        lock = Mutex.new
        settled = false
        watchdog = Thread.new do
          remaining = deadline - monotonic_now
          sleep(remaining) if remaining.positive?
          lock.synchronize do
            target.raise(Faraday::TimeoutError, 'Request exceeded its deadline') unless settled
          end
        end

        begin
          answered = yield
          lock.synchronize { settled = true }
          answered
        rescue Faraday::TimeoutError
          raise if answered.nil?

          lock.synchronize { settled = true }
          answered
        ensure
          lock.synchronize { settled = true }
          watchdog.kill
        end
      end

      # A callback handed every complete SSE event of the response stream as
      # it arrives, or nil to read the stream only once it has ended. The base
      # transport parses completed bodies; ServerHTTP overrides this.
      # @param _request [Hash] the JSON-RPC message being sent
      # @return [Proc, nil]
      def response_stream_listener(_request)
        nil
      end

      # The bound on a gzip body's expansion, for the stream scanner and the
      # salvage of a delivered compressed answer (Streamable HTTP configures
      # one; plain HTTP never asks for gzip).
      # @return [Integer, nil]
      def inflate_limit
        respond_to?(:max_decompressed_body_bytes, true) ? max_decompressed_body_bytes : nil
      end

      # A response body that arrived gzip-encoded, inflated so the salvage
      # can tell whether the answer is in it. Streamable HTTP offers gzip on
      # every request, so a delivered answer is usually a delivered
      # *compressed* answer; treating those bytes as a lost stream would
      # re-issue a tools/call the server already ran.
      # An expansion the bound refuses is not a lost answer either: the
      # server ran the request and sent its result, and only this client's
      # ceiling stands in the way. Re-issuing there would run the request a
      # second time, so the caller is told the response was too large — the
      # same answer the ordinary (unbroken) path gives.
      # @param body [String] the captured bytes
      # @return [String, nil] the expanded body; nil when the deflate stream
      #   itself stopped short of what it needs to be read
      # @raise [MCPClient::Errors::ResponseTooLargeError] when the body expands
      #   past the configured bound
      def inflate_delivered_gzip(body)
        inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 32)
        text = BoundedInflate.inflate(inflater, body, inflate_limit)
        return text unless text.nil?

        raise MCPClient::Errors::ResponseTooLargeError,
              "Gzip response expanded beyond #{inflate_limit} bytes"
      rescue Zlib::Error
        nil
      ensure
        inflater&.close
      end

      # How many events of the response stream were already handed to the
      # stream listener while the body arrived (see ResponseBodyCapture).
      # @param response [Faraday::Response, NormalizedResponse] the completed response
      # @return [Integer]
      def live_event_count(response)
        capture_state(response)[:mcp_live_events].to_i
      end

      # The failure the stream listener raised while the body arrived, if
      # any: it could not abort the read (see ResponseBodyCapture), so the
      # transport raises it in place of the response it was interleaved with.
      # @param response [Faraday::Response, NormalizedResponse] the completed response
      # @return [StandardError, nil]
      def stream_listener_error(response)
        capture_state(response)[:mcp_stream_error]
      end

      # @param response [Faraday::Response, NormalizedResponse] a completed response
      # @return [Hash] the ResponseBodyCapture state of its exchange (empty when none)
      def capture_state(response)
        context = if response.respond_to?(:env) && response.env.respond_to?(:request)
                    response.env.request&.context
                  elsif response.respond_to?(:context)
                    response.context
                  end
        context.is_a?(Hash) ? context : {}
      end
    end
  end
end
