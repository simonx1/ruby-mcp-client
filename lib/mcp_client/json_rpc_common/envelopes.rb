# frozen_string_literal: true

module MCPClient
  module JsonRpcCommon
    # Reading the members of a decoded JSON-RPC envelope. A host's JSON
    # middleware may hand the envelope over keyed by Symbol, and its members
    # are the peer's rather than the host's, so both spellings name the same
    # thing. Mixed into {MCPClient::JsonRpcCommon}; private there.
    module Envelopes
      private

      # Read a member of a decoded JSON-RPC envelope.
      #
      # The README offers Faraday's JSON middleware for reading a server's error
      # bodies, and that middleware decodes every response — under
      # `symbolize_names` the envelope arrives keyed by Symbol. The members are
      # the peer's, not the host's, so both spellings name the same thing: read
      # the wire spelling first and fall back to the Symbol one. Anything that
      # is no Hash is indexed as before, so a malformed envelope fails where it
      # always did.
      # @param response [Object] the decoded JSON-RPC envelope
      # @param name [String] the member's name in its wire spelling
      # @return [Object, nil] the member, or nil when the envelope carries none
      def envelope_member(response, name)
        return response[name] unless response.is_a?(Hash)
        return response[name] if response.key?(name)

        response[name.to_sym]
      end
    end
  end
end
