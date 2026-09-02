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

      # Stand-in app for instantiating middleware whose request hook is run
      # without a request (the freshness probe).
      NOOP_APP = ->(_env) {}

      # Context that matches no cached entry: the credentials the next
      # request would carry cannot be determined without sending it.
      UNKNOWN_CONTEXT = :unknown

      # Middleware that overrides `call` outright (the retry middleware of the
      # default stack) but never touches the request headers, so the probe
      # may skip it.
      PROBE_TRANSPARENT_MIDDLEWARE = %w[Faraday::Retry::Middleware Faraday::Request::Retry].freeze

      # Collaborators a middleware may share with the live stack without the
      # probe changing what a later request sends: they carry no request
      # state of their own (a logger writes, a lock guards).
      PROBE_SAFE_SHARED_STATE = [Logger, Mutex, Module].freeze

      # How far into shared state its immutability is checked: a frozen
      # container may still hold mutable members, and beyond this depth the
      # state counts as mutable (so the context is unknown).
      PROBE_IMMUTABLE_DEPTH = 8

      # Last request middleware on the JSON-RPC connection: records the
      # Authorization a request carries once every host middleware
      # (faraday_config) has run, right before the adapter sends it. A
      # request that then times out or fails to connect still has a known
      # context, so the stale copy of that context may be served.
      class AuthorizationRecorder < Faraday::Middleware
        def initialize(app, transport)
          super(app)
          @transport = transport
        end

        def on_request(env)
          @transport.send(:note_request_authorization,
                          MCPClient::ResultCaching.authorization_header_value(env.request_headers))
        end
      end

      private

      # Append the {AuthorizationRecorder} after the host's middleware.
      # @param conn [Faraday::Connection]
      # @return [Faraday::Connection]
      def record_sent_authorization(conn)
        conn.builder.use(AuthorizationRecorder, self)
        conn
      rescue StandardError => e
        @logger.debug("Could not install the Authorization recorder middleware: #{e.class}")
        conn
      end

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
        note_request_params_pending
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

      # Forget the header recorded before middleware ran: until the request
      # is sent (or its error reports the headers) the attempt's context is
      # unknown, so no private stale copy can be served for it.
      # @return [void]
      def note_request_authorization_pending
        Thread.current[request_authorization_key] = UNRECORDED_AUTHORIZATION
      end

      # A request that failed before returning a response: Faraday errors
      # raised by its middleware keep the request headers, which name the
      # Authorization actually sent; otherwise the context stays unknown.
      # @param error [Exception]
      # @return [void]
      def note_failed_request_authorization(error)
        return unless @faraday_config

        response = error.respond_to?(:response) ? error.response : nil
        headers = response.is_a?(Hash) ? response.dig(:request, :headers) : nil
        return unless headers.respond_to?(:[])

        note_request_authorization(authorization_header_value(headers))
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

      # @param kind [Symbol, String, nil] the cache kind whose next request is modelled
      #   (:tools, :prompts, :resources, :templates, :discover or "read:<uri>")
      # @return [String, nil, Symbol] the Authorization header the next request of that
      #   operation would carry, or {UNKNOWN_CONTEXT} when host middleware makes that
      #   impossible to tell
      def current_authorization_context(kind = nil)
        # The probe starts from the configured headers, as a real request
        # does: a provider without a token leaves a static header in place.
        # They are held in Faraday's own case-insensitive table, so the
        # provider's `Authorization` replaces a header configured under any
        # other spelling instead of being read past by the lookup below.
        probe = HeaderProbe.new(faraday_headers(@headers))
        @oauth_provider&.apply_authorization(probe)
        headers = probe.headers
        if @faraday_config
          # Faraday middleware installed by the host (faraday_config) may
          # add or replace the header after the request block ran: the probe
          # runs that stack too, without sending anything — and gives up
          # rather than guess when it cannot run it faithfully.
          headers = middleware_request_headers(headers, *probe_request_for(kind))
          return UNKNOWN_CONTEXT if headers.nil?
        end
        authorization_fingerprint(authorization_header_value(headers))
      end

      # The JSON-RPC request the probe models for a cache kind: the very
      # operation whose cache is being checked, so middleware that chooses
      # credentials by method or body answers as it would for that request.
      # @param kind [Symbol, String, nil]
      # @return [Array(String, Hash)] method and params
      def probe_request_for(kind)
        case kind
        when :tools then ['tools/list', {}]
        when :prompts then ['prompts/list', {}]
        when :resources then ['resources/list', {}]
        when :templates then ['resources/templates/list', {}]
        when :discover then ['server/discover', {}]
        when /\Aread:(.+)\z/m then ['resources/read', { 'uri' => Regexp.last_match(1) }]
        else [@probe_method || 'ping', {}]
        end
      end

      # Minimal request stand-in for asking the OAuth provider which
      # Authorization header it would apply.
      HeaderProbe = Struct.new(:headers)

      # Run the request phase of the connection's middleware over a request
      # shaped like the real JSON-RPC POST of the operation (endpoint, JSON
      # body with its method and params) that is never sent, and return the
      # headers it would go out with. Only `on_request` hooks run: response
      # middleware (raise_error, a parser) never sees a response here, and
      # the recorder must not note the probe as a sent request. Middleware
      # that overrides `call` cannot be run without sending, middleware whose
      # own state has moved on since the connection was built cannot be stood
      # in for by a fresh copy, and middleware that shares mutable state with
      # the live stack must not be run at all (the probe would change it);
      # the answer is then unknown.
      # @param headers [Hash] the headers before middleware
      # @param method [String] the JSON-RPC method the probe models
      # @param params [Hash] its params
      # @return [Hash, nil] the headers after middleware, or nil when they cannot be determined
      def middleware_request_headers(headers, method = @probe_method || 'ping', params = {})
        conn = http_connection
        request = conn.build_request(:post) do |req|
          req.url(@endpoint)
          headers.each { |k, v| req.headers[k] = v }
          req.headers['Content-Type'] = 'application/json'
          # The body a real request would carry, its effective `_meta`
          # included (host request_meta, protocol fields), so middleware that
          # picks credentials by it answers as it would for the request.
          probe = build_jsonrpc_request(method, params, 0, note: false)
          req.body = JSON.generate(probe)
          # The routing headers a real modern POST carries, so middleware
          # that authenticates by them answers as it would for the request.
          modern_request_headers(probe).each { |k, v| req.headers[k] = v } if modern?
        end
        env = request.to_env(conn)
        live = live_middleware(conn)
        return nil if live.nil?

        conn.builder.handlers.each_with_index do |handler, index|
          # Middleware that is never run needs no stand-in: the recorder is
          # the probe's own, and the transparent ones leave headers alone.
          next if handler.klass == AuthorizationRecorder
          next if PROBE_TRANSPARENT_MIDDLEWARE.include?(handler.klass.name)
          return nil unless probe_runnable_middleware?(handler.klass)

          # A copy is run rather than the instance Faraday calls, so the
          # probe cannot disturb it — which is only faithful while the copy
          # still holds the same state.
          middleware = handler.build(NOOP_APP)
          return nil unless probe_stands_in_for?(middleware, live[index])

          middleware.on_request(env) if middleware.respond_to?(:on_request)
        end
        env.request_headers
      rescue StandardError => e
        @logger.debug("Could not run the Faraday middleware to probe the Authorization header: #{e.class}")
        nil
      end

      # The middleware instances Faraday actually calls, in the order of
      # `builder.handlers`. Building the stack is what the first request
      # does anyway, and it is the state of these instances — not of a fresh
      # copy — that decides what the next request sends.
      # @param conn [Faraday::Connection]
      # @return [Array<Faraday::Middleware>, nil] nil when the stack cannot be walked
      def live_middleware(conn)
        node = conn.builder.app
        instances = []
        while node.is_a?(Faraday::Middleware)
          instances << node
          node = node.app
        end
        instances.size == conn.builder.handlers.size ? instances : nil
      end

      # Whether a freshly built middleware answers as the instance Faraday
      # will call would. Middleware that keeps state of its own — a token
      # rotated per request, anything learned from an earlier response —
      # drifts from a fresh copy, and the copy would then keep predicting
      # credentials the real request has already moved past.
      # @param fresh [Faraday::Middleware] the instance the probe would run
      # @param live [Faraday::Middleware, nil] the instance Faraday calls
      # @return [Boolean]
      def probe_stands_in_for?(fresh, live)
        return false unless live.instance_of?(fresh.class)

        names = fresh.instance_variables | live.instance_variables
        names.all? do |name|
          # The app each instance wraps differs by construction (the probe
          # ends at NOOP_APP) and never decides a header.
          next true if name == :@app

          same_middleware_state?(fresh.instance_variable_get(name), live.instance_variable_get(name))
        end
      end

      # @return [Boolean] whether two middleware ivars hold indistinguishable state
      #   the probe may run against
      def same_middleware_state?(one, other)
        # State the host keeps outside the middleware (a holder both
        # instances point at) is not copied by building a fresh middleware:
        # running the copy's request hook would change the very state the
        # live instance uses — spending a nonce, advancing a one-time token
        # the next real request then never sends. Only shared state that
        # cannot change may be stood in for.
        return probe_safe_shared_state?(one) if one.equal?(other)

        one == other
      rescue StandardError
        false
      end

      # @param value [Object] state the fresh and live middleware share
      # @return [Boolean] whether running the probe against it can change nothing
      def probe_safe_shared_state?(value)
        probe_immutable_state?(value) || PROBE_SAFE_SHARED_STATE.any? { |klass| value.is_a?(klass) }
      end

      # Whether a value cannot be changed at all: a frozen container still
      # yields mutable members, so they are checked too (to a bounded depth —
      # deeper than that the state counts as mutable).
      # @param value [Object]
      # @param depth [Integer]
      # @return [Boolean]
      def probe_immutable_state?(value, depth = 0)
        return false unless value.frozen?

        case value
        when Hash
          depth < PROBE_IMMUTABLE_DEPTH &&
            value.all? { |k, v| probe_immutable_state?(k, depth + 1) && probe_immutable_state?(v, depth + 1) }
        when Array, Struct
          depth < PROBE_IMMUTABLE_DEPTH && value.to_a.all? { |item| probe_immutable_state?(item, depth + 1) }
        else
          true
        end
      end

      # @param klass [Class] a middleware class on the connection
      # @return [Boolean] whether its request phase can be run without sending (it relies on
      #   Faraday::Middleware#call, or is known not to touch the headers)
      def probe_runnable_middleware?(klass)
        return true if PROBE_TRANSPARENT_MIDDLEWARE.include?(klass.name)
        return false unless klass.method_defined?(:call)

        klass.instance_method(:call).owner == Faraday::Middleware
      end

      # Remember the Authorization a request actually carried once it was
      # sent (middleware may have changed it after the request block).
      # @param response [Faraday::Response, nil]
      # @return [void]
      # Send a JSON-RPC request and parse its response, keeping the result
      # bound to its own request: parsing an SSE-framed response dispatches
      # the notifications it carries, and a callback may send a nested
      # request on this thread, so the credentials, effective parameters and
      # receipt time (taken before parsing) of the outer request are re-noted
      # afterwards (MCP 2026-07-28 caching).
      # @param request [Hash] the JSON-RPC request
      # @return [Object] the parsed result
      def exchange_jsonrpc(request, timeout: nil, extra_headers: {})
        clear_response_received_at if respond_to?(:clear_response_received_at, true)
        response = send_http_request(request, timeout: timeout, extra_headers: extra_headers)
        received_at = monotonic_now if respond_to?(:monotonic_now, true)
        begin
          result = parse_response(response, request)
        ensure
          # The outer request's own context, whatever a notification the
          # response carried did on this thread — and whether or not the
          # parse succeeded, so a failed re-fetch is judged by its own
          # credentials and parameters.
          note_sent_authorization(response)
          note_request_params(request['params'])
        end
        note_response_received_at(received_at) if respond_to?(:note_response_received_at, true)
        result
      end

      def note_sent_authorization(response)
        env = response.respond_to?(:env) ? response.env : nil
        return unless env.respond_to?(:request_headers) && env.request_headers

        note_request_authorization(authorization_header_value(env.request_headers))
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
