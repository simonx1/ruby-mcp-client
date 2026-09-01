# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # MCP 2026-07-28 caching support shared by the HTTP transports: serving
    # a stale list on transient re-fetch failures, and keeping privately
    # scoped cache entries within their authorization context.
    module CacheSupport
      # Thread-local marker meaning "this attempt has not applied its
      # headers yet": a failure before that point leaves the credentials of
      # the attempt unknown, so no private stale copy may be served for it.
      UNRECORDED_AUTHORIZATION = :unrecorded

      private

      # Re-fetch a list that has gone stale, or serve the stale copy when the
      # re-fetch fails for a transient reason ("Clients MAY serve stale
      # responses if errors occur during re-fetching").
      # @param kind [Symbol] the list kind (for the log line)
      # @param cached [MCPClient::CachedResult, nil] the entry captured before the re-fetch
      # @yield performs the fetch
      # @return [Object] the fresh value, or the captured entry's value on a transient failure
      def refetch_or_serve_stale(kind, cached)
        # The marker of the previous request on this thread must not stand
        # in for an attempt that fails before it applies its own headers.
        Thread.current[request_authorization_key] = UNRECORDED_AUTHORIZATION
        yield
      rescue MCPClient::Errors::TransientServerError, MCPClient::Errors::ConnectionError,
             MCPClient::Errors::TransportError => e
        # A revoked or insufficient authorization is not a transient failure:
        # serving the stale list would hide it from the host's auth flow. The
        # stale copy is judged against the credentials the failed request
        # went out with (they may have changed since the copy was made); an
        # attempt that never got that far has no private fallback.
        context = request_authorization_recorded? ? request_authorization_context : :unknown
        stale = stale_fallback_for(kind, cached, context: context)
        raise if stale.nil? || authorization_failure?(e)

        @logger.warn("Re-fetching #{kind} failed (#{e.class}); serving the stale cached list")
        stale
      end

      # Remember the Authorization header a request goes out with, on the
      # thread that sends it, so the result it brings back can be bound to
      # that context (MCP 2026-07-28 caching, cacheScope "private").
      # @param authorization [String, nil] the Authorization header of the request
      # @return [void]
      def note_request_authorization(authorization)
        Thread.current[request_authorization_key] = authorization_fingerprint(authorization)
      end

      # @return [String, nil] the Authorization header of the request this thread last sent
      def request_authorization_context
        context = Thread.current[request_authorization_key]
        context == UNRECORDED_AUTHORIZATION ? nil : context
      end

      # @return [Boolean] whether the current attempt on this thread applied its headers
      def request_authorization_recorded?
        Thread.current[request_authorization_key] != UNRECORDED_AUTHORIZATION
      end

      # @return [Symbol] the thread-local key of this transport's request authorization
      def request_authorization_key
        :"mcp_client_request_authorization_#{object_id}"
      end

      # @return [String, nil] the Authorization header the next request would carry
      def current_authorization_context
        # The probe starts from the configured headers, as a real request
        # does: a provider without a token leaves a static header in place.
        probe = HeaderProbe.new(@headers.to_h.dup)
        @oauth_provider&.apply_authorization(probe)
        headers = probe.headers
        # Faraday middleware installed by the host (faraday_config) may add
        # or replace the header after the request block ran: the probe runs
        # that stack too, without sending anything.
        headers = middleware_request_headers(headers) if @faraday_config
        authorization_fingerprint(headers['Authorization'] || headers['authorization'])
      end

      # Minimal request stand-in for asking the OAuth provider which
      # Authorization header it would apply.
      HeaderProbe = Struct.new(:headers)

      # Run the connection's request middleware over a request that is never
      # sent, and return the headers it would go out with.
      # @param headers [Hash] the headers before middleware
      # @return [Hash] the headers after middleware (the input on failure)
      def middleware_request_headers(headers)
        conn = http_connection
        request = conn.build_request(:post) { |req| headers.each { |k, v| req.headers[k] = v } }
        env = request.to_env(conn)
        terminal = ->(e) { Faraday::Response.new(e) }
        conn.builder.handlers.reverse.inject(terminal) { |app, handler| handler.build(app) }.call(env)
        env.request_headers
      rescue StandardError => e
        @logger.debug("Could not run the Faraday middleware to probe the Authorization header: #{e.class}")
        headers
      end

      # Remember the Authorization a request actually carried once it was
      # sent (middleware may have changed it after the request block).
      # @param response [Faraday::Response, nil]
      # @return [void]
      def note_sent_authorization(response)
        env = response.respond_to?(:env) ? response.env : nil
        return unless env.respond_to?(:request_headers) && env.request_headers

        note_request_authorization(env.request_headers['Authorization'] || env.request_headers['authorization'])
      end

      # @param error [Exception] a failure raised by the HTTP pipeline
      # @return [Boolean] whether it reports an authorization failure (401/403)
      def authorization_failure?(error)
        error.is_a?(MCPClient::Errors::InsufficientScopeError) ||
          (error.is_a?(MCPClient::Errors::ConnectionError) && error.message.start_with?('Authorization failed'))
      end
    end
  end
end
