# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # Splits an SSE body into complete events as its bytes arrive. Line
    # terminators are CRLF, CR or LF (SSE "Parsing an event stream"), so a
    # trailing CR is held back until the next chunk shows whether an LF
    # follows it. Only a body that starts like an event stream is scanned; a
    # JSON body never yields anything. Events are counted, terminated or not
    # dispatched, in the same order the completed body splits into them.
    class SseEventScanner
      SSE_START = /\A\n*(?::|(?:data|event|id|retry):)/

      # @return [Integer] complete events seen so far
      attr_reader :count

      def initialize
        @normalized = +''.b
        @scanned = 0
        @held_cr = false
        @count = 0
        @sse = nil
      end

      # @param chunk [String] the bytes that just arrived
      # @yieldparam event [String] one complete event, LF-normalized, without its terminator
      # @return [void]
      def feed(chunk)
        return if @sse == false

        # Bytes, not characters: the body is peer-controlled and may not be
        # text at all (a gzip error body reaches here too).
        text = @held_cr ? "\r#{chunk.b}" : chunk.b
        @held_cr = text.end_with?("\r")
        text = text[0...-1] if @held_cr
        @normalized << text.gsub(/\r\n|\r/, "\n")
        return unless scanning?

        while (index = @normalized.index("\n\n", @scanned))
          event = @normalized[@scanned...index]
          @scanned = index + 2
          @count += 1
          yield event.force_encoding(Encoding::UTF_8)
        end
      end

      private

      # Whether the body is an event stream worth scanning, settled from its
      # first few bytes: one that does not start like an event stream (JSON,
      # gzip, anything else) is never scanned and never buffered here.
      # @return [Boolean] false while too little has arrived to tell
      def scanning?
        return @sse unless @sse.nil?
        return false unless @normalized.bytesize >= 6 || @normalized.include?("\n")

        @sse = @normalized.match?(SSE_START)
        @normalized.clear unless @sse
        @sse
      end
    end
  end
end
