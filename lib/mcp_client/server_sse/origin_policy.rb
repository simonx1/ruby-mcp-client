# frozen_string_literal: true

require 'uri'

module MCPClient
  class ServerSSE
    # Origin pinning for the legacy HTTP+SSE transport.
    #
    # Everything this transport sends carries the caller's configured headers
    # (Authorization, API keys, cookies), and callback responses carry
    # roots/sampling/elicitation data, so no request may leave the origin the
    # caller connected to — neither by a server-chosen endpoint URI nor by a
    # redirect.
    module OriginPolicy
      # @param base [URI::Generic] the SSE connection URL
      # @param other [URI::Generic] the URL to compare
      # @return [Boolean] whether both share scheme, host and port
      def same_origin?(base, other)
        base.scheme == other.scheme &&
          base.host&.downcase == other.host&.downcase &&
          base.port == other.port
      end

      # @param uri [URI::Generic]
      # @return [String] scheme://host:port of the URI
      def origin_of(uri)
        "#{uri.scheme}://#{uri.host}:#{uri.port}"
      end

      # Refuse to follow a redirect that leaves the SSE connection's origin.
      #
      # Pinning the endpoint event's origin is not sufficient on its own: a
      # same-origin endpoint can answer a POST with a 307/308 to another
      # origin, and faraday-follow_redirects replays the request there. It
      # strips only the literal Authorization header, so configured API-key
      # and other custom headers — plus the JSON-RPC body — would still reach
      # the foreign origin.
      #
      # Raises ConnectionError rather than TransportError because the server
      # has already received the original request; with_retry must not re-send
      # it.
      # @param _old_env [Faraday::Env] the redirecting response environment
      # @param new_env [Faraday::Env] environment of the request about to be replayed
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if the redirect changes origin
      def reject_cross_origin_redirect!(_old_env, new_env)
        base = URI.parse(@base_url)
        target = new_env.url
        return if same_origin?(base, target)

        message = "Refusing cross-origin redirect from #{origin_of(base)} to #{origin_of(target)}"
        @logger.error(message)
        raise MCPClient::Errors::ConnectionError, message
      end
    end
  end
end
