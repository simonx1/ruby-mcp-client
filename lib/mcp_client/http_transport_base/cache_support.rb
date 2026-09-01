# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # MCP 2026-07-28 caching support shared by the HTTP transports: serving
    # a stale list on transient re-fetch failures, and keeping privately
    # scoped cache entries within their authorization context.
    module CacheSupport
      private

      # Re-fetch a list that has gone stale, or serve the stale copy when the
      # re-fetch fails for a transient reason ("Clients MAY serve stale
      # responses if errors occur during re-fetching").
      # @param kind [Symbol] the list kind (for the log line)
      # @param stale [Object, nil] the stale cached value
      # @yield performs the fetch
      # @return [Object] the fresh value, or the stale one on a transient failure
      def refetch_or_serve_stale(kind, stale)
        yield
      rescue MCPClient::Errors::TransientServerError, MCPClient::Errors::ConnectionError,
             MCPClient::Errors::TransportError => e
        # A revoked or insufficient authorization is not a transient failure:
        # serving the stale list would hide it from the host's auth flow.
        raise if stale.nil? || authorization_failure?(e)

        @logger.warn("Re-fetching #{kind} failed (#{e.class}); serving the stale cached list")
        stale
      end

      # Notice a change of authorization context (a refreshed or different
      # access token): privately scoped cache entries belong to the previous
      # one and are dropped (MCP 2026-07-28 caching, cacheScope "private").
      # @param authorization [String, nil] the Authorization header about to be sent
      # @return [void]
      def track_authorization_context(authorization)
        previous = @mutex.synchronize do
          seen = @authorization_context
          @authorization_context = authorization
          seen
        end
        invalidate_private_cache if !previous.nil? && previous != authorization
      end

      # Re-check the authorization context without sending a request (before a
      # privately scoped cache entry is served): the credentials the next
      # request would carry decide whether the entry is still ours.
      # @return [void]
      def ensure_authorization_context!
        track_authorization_context(current_authorization_context)
      end

      # @return [String, nil] the Authorization header the next request would carry
      def current_authorization_context
        return @headers['Authorization'] || @headers['authorization'] unless @oauth_provider

        probe = HeaderProbe.new({})
        @oauth_provider.apply_authorization(probe)
        probe.headers['Authorization']
      end

      # Minimal request stand-in for asking the OAuth provider which
      # Authorization header it would apply.
      HeaderProbe = Struct.new(:headers)

      # @param error [Exception] a failure raised by the HTTP pipeline
      # @return [Boolean] whether it reports an authorization failure (401/403)
      def authorization_failure?(error)
        error.is_a?(MCPClient::Errors::InsufficientScopeError) ||
          (error.is_a?(MCPClient::Errors::ConnectionError) && error.message.start_with?('Authorization failed'))
      end
    end
  end
end
