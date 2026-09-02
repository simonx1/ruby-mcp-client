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
    module PeerText
      # How much peer-supplied text a message may carry.
      PEER_TEXT_LIMIT = 200

      private

      # @param value [Object] peer-supplied text
      # @return [String, nil] printable, bounded text; nil unless a String was given
      def safe_error_text(value)
        return nil unless value.is_a?(String)

        value.gsub(/[[:cntrl:]]/, ' ')[0, PEER_TEXT_LIMIT]
      end

      # The same, for a value that is not necessarily a String (a response
      # body, which Faraday may hand over as nil).
      # @param value [Object] a peer-supplied response body
      # @return [String] printable, bounded text, never nil
      def safe_body_text(value)
        safe_error_text(value.to_s).to_s
      end

      # A log-safe description of a JSON parse failure: where it failed and
      # how much there was, never what it said.
      # @param error [JSON::ParserError] the parse failure
      # @param payload [Object, nil] the body that failed to parse
      # @return [String]
      def describe_parse_error(error, payload = nil)
        parts = ['malformed JSON']
        location = error.message[/at line \d+ column \d+/]
        parts << location if location
        parts << describe_body_size(payload) unless payload.nil?
        parts.join(', ')
      end

      # @param body [Object, nil] a response body
      # @return [String] its size, never its content
      def describe_body_size(body)
        text = body.to_s
        text.empty? ? 'empty body' : "#{text.bytesize} byte body"
      end
    end
  end
end
