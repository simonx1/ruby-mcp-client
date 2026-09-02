# frozen_string_literal: true

module MCPClient
  module Auth
    # Every string an authorization server, a resource server or a browser
    # callback supplies passes through here before it reaches a log line or an
    # exception message.
    #
    # Those messages are not private: {MCPClient::Auth::BrowserOAuth} renders
    # the message of a failed flow on the page it serves to the browser, and
    # logs are read, forwarded and pasted. Peer-supplied bytes quoted verbatim
    # carry CR/LF into a log record (splitting it into attacker-chosen lines),
    # terminal escape sequences into a console, and unbounded response bodies
    # into both. And the message of a JSON::ParserError quotes the token it
    # choked on — "expected object key, got 'SECRET' at line 1 column 2" —
    # which puts a fragment of the very body that failed to parse into the
    # text.
    #
    # So: printable, bounded text for peer strings, and position without
    # content for a parse failure. The OAuth classes define these themselves
    # rather than reaching for {MCPClient::JsonRpcCommon}, which they do not
    # include: a rescue path that calls a helper its object does not have
    # raises NoMethodError out of the very request the rescue existed to keep
    # working.
    #
    # Every helper here is TOTAL: no input can raise out of it. Nothing about
    # a peer's bytes guarantees they are valid UTF-8 — a response body arrives
    # as whatever the socket carried, a callback parameter as whatever
    # `CGI.unescape` made of `%FF`, and a `JSON::ParserError` message quotes
    # the undecodable bytes it choked on — and `String#gsub`, `String#strip`
    # and `Regexp#match` all raise `ArgumentError: invalid byte sequence in
    # UTF-8` on them. A sanitizer that raises on the input it exists to
    # sanitize is worse than none: it turns a peer's `400` body, or an
    # `error_description=%FF`, into an exception out of the rescue path that
    # was meant to report it. Undecodable bytes are therefore replaced before
    # anything else looks at them.
    module PeerText
      # How much peer-supplied text a message may carry.
      PEER_TEXT_LIMIT = 200

      # What an undecodable byte becomes. ASCII, so the result is safe to
      # write to a log device of any encoding.
      UNDECODABLE_BYTE = '?'

      # What a helper reports when even the replacement could not be made
      # (an object whose #to_s raises, a string no encoding handler accepts).
      # A helper here never raises, so there is always something to say.
      UNREADABLE_TEXT = '(unreadable)'

      private

      # @param value [Object] peer-supplied text
      # @return [String, nil] printable, bounded text; nil unless a String was given
      def safe_error_text(value)
        return nil unless value.is_a?(String)

        printable_peer_text(value)
      end

      # The same, for a value that is not necessarily a String (a response
      # body, which Faraday may hand over as nil).
      # @param value [Object] a peer-supplied response body
      # @return [String] printable, bounded text, never nil
      def safe_body_text(value)
        return '' if value.nil?

        printable_peer_text(value.is_a?(String) ? value : value.to_s)
      rescue StandardError
        UNREADABLE_TEXT
      end

      # Peer bytes as text that can be logged, matched, sliced and rendered:
      # valid UTF-8 (undecodable bytes replaced), free of control characters,
      # and bounded.
      # @param text [String] peer-supplied bytes
      # @return [String]
      def printable_peer_text(text)
        decodable_text(text).gsub(/[[:cntrl:]]/, ' ')[0, PEER_TEXT_LIMIT].to_s
      rescue StandardError
        UNREADABLE_TEXT
      end

      # The same bytes as valid UTF-8. A string in another encoding (a binary
      # response body, a UTF-16 message) is read as UTF-8 and scrubbed rather
      # than transcoded: the point is text that cannot raise, not a faithful
      # rendering of a peer's mojibake.
      # @param text [String]
      # @return [String] valid UTF-8
      def decodable_text(text)
        utf8 = text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : utf8.scrub(UNDECODABLE_BYTE)
      rescue StandardError
        UNREADABLE_TEXT
      end

      # A log-safe description of a JSON parse failure: where it failed and
      # how much there was, never what it said.
      # @param error [JSON::ParserError] the parse failure
      # @param payload [Object, nil] the body that failed to parse
      # @return [String]
      def describe_parse_error(error, payload = nil)
        parts = ['malformed JSON']
        # The parser's own message quotes the bytes it choked on, so it is no
        # more decodable than the body was: it is made matchable first.
        location = decodable_text(error.message.to_s)[/at line \d+ column \d+/]
        parts << location if location
        parts << describe_body_size(payload) unless payload.nil?
        parts.join(', ')
      rescue StandardError
        'malformed JSON'
      end

      # @param body [Object, nil] a response body
      # @return [String] its size, never its content
      def describe_body_size(body)
        text = body.to_s
        text.empty? ? 'empty body' : "#{text.bytesize} byte body"
      rescue StandardError
        'body of unknown size'
      end
    end
  end
end
