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
      # @param body [String] the captured bytes
      # @return [String, nil] the expanded body; nil when it cannot be inflated
      #   (truncated inside the deflate stream, or over the bound)
      def inflate_delivered_gzip(body)
        inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 32)
        BoundedInflate.inflate(inflater, body, inflate_limit)
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
        context = if response.respond_to?(:env) && response.env.respond_to?(:request)
                    response.env.request&.context
                  elsif response.respond_to?(:context)
                    response.context
                  end
        context.is_a?(Hash) ? context[:mcp_live_events].to_i : 0
      end
    end
  end
end
