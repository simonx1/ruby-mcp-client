# frozen_string_literal: true

require 'zlib'
require_relative 'bounded_inflate'

module MCPClient
  module HttpTransportBase
    # Splits an SSE body into complete events as its bytes arrive. Line
    # terminators are CRLF, CR or LF (SSE "Parsing an event stream"): a CR
    # ends a line on its own, so an event it terminates is dispatched at
    # once, and the LF of a CRLF that arrives in the next chunk is skipped.
    # A gzip body (Streamable HTTP offers gzip on every request) is inflated
    # as it arrives. Only a body that starts like an event stream is scanned;
    # a JSON body never yields anything. Events are counted, terminated or
    # not dispatched, in the same order the completed body splits into them.
    class SseEventScanner
      # An event stream opens with a comment or a field — any field: one
      # the client does not know is ignored, not a reason to stop reading
      # (SSE "Parsing an event stream"). A body that opens a JSON value is
      # never an event stream.
      SSE_START = /\A(?::|[^\n:{\[]+:)/n
      BOM = "\xEF\xBB\xBF".b
      GZIP_MAGIC = "\x1F\x8B".b

      # @return [Integer] complete events seen so far
      attr_reader :count

      # @param max_inflated_bytes [Integer, nil] bound on a gzip body's expansion,
      #   beyond which the stream is no longer scanned
      def initialize(max_inflated_bytes: nil)
        @normalized = +''.b
        @head = +''.b
        @scanned = 0
        @after_cr = false
        @count = 0
        @sse = nil
        @inflater = nil
        @inflated = 0
        @max_inflated_bytes = max_inflated_bytes
      end

      # @param chunk [String] the bytes that just arrived
      # @yieldparam event [String] one complete event, LF-normalized, without its terminator
      # @return [void]
      def feed(chunk)
        return if @sse == false

        # Bytes, not characters: the body is peer-controlled and may not be
        # text at all.
        text = decoded(chunk.b)
        return if text.nil? || @sse == false

        text = text[1..] if @after_cr && text.start_with?("\n")
        @after_cr = text.end_with?("\r")
        @normalized << text.gsub(/\r\n|\r/, "\n")
        return unless scanning?

        while (index = @normalized.index("\n\n", @scanned))
          event = @normalized[@scanned...index]
          @scanned = index + 2
          @count += 1
          # Blank lines before an event's first field dispatch nothing (SSE
          # "Parsing an event stream"), so they are not part of the event.
          yield event.sub(/\A\n+/, '').force_encoding(Encoding::UTF_8)
        end
      end

      private

      # The chunk as text: inflated when the body turned out to be gzip,
      # which its first two bytes tell. Until they have arrived nothing can be
      # scanned.
      # @param chunk [String] the raw bytes
      # @return [String, nil] nil while the body's encoding is not known yet
      def decoded(chunk)
        return inflate(chunk) if @inflater
        return chunk if @head.frozen?

        @head << chunk
        return nil if @head.bytesize < GZIP_MAGIC.bytesize

        head = @head
        @head = ''.b.freeze
        return head unless head.start_with?(GZIP_MAGIC)

        @inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 32)
        inflate(head)
      end

      # @param bytes [String] gzip bytes as they arrived
      # @return [String, nil] the text they expand to; nil once the stream is unusable
      def inflate(bytes)
        text = BoundedInflate.inflate(@inflater, bytes, @max_inflated_bytes, @inflated)
        return stop_scanning if text.nil?

        @inflated += text.bytesize
        text
      rescue Zlib::Error
        stop_scanning
      end

      # @return [nil]
      def stop_scanning
        @sse = false
        @normalized.clear
        nil
      end

      # Whether the body is an event stream worth scanning, settled from its
      # first line after any leading blank lines: one that does not start like
      # an event stream (JSON, anything else) is never scanned and never
      # buffered here.
      #
      # The verdict waits for that first line to be decidable. A field name is
      # what says "event stream", and a name split across chunks ("x-igno" +
      # "re: 1\n") is not one yet: settling on its first bytes would answer
      # "not an event stream" for a stream that is one, and nothing on it —
      # a server's request awaiting its answer, a progress notification —
      # would ever be delivered. A JSON body is refused on its first byte,
      # since no field name may open with one.
      # @return [Boolean] false while too little has arrived to tell
      def scanning?
        return @sse unless @sse.nil?

        # The UTF-8 decode step of the SSE algorithm drops one leading BOM.
        @normalized.delete_prefix!(BOM) if @scanned.zero?
        content = @normalized.sub(/\A\n+/, '')
        return settle(false) if content.match?(/\A[{\[]/n)
        # A colon ends a field name; so does the line itself, since a line
        # with no colon is a field whose value is empty.
        return false unless content.match?(/[:\n]/n)

        settle(content.match?(SSE_START) || !content.match?(/\A[^\n]*:/n))
      end

      # @param verdict [Boolean] whether this body is an event stream
      # @return [Boolean] the verdict
      def settle(verdict)
        @sse = verdict
        @normalized.clear unless verdict
        verdict
      end
    end
  end
end
