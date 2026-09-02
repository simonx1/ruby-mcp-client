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

      # Framework middleware that never puts an Authorization header on a
      # request, whatever it was configured with: the probe steps over it
      # instead of running it (some of it overrides `call` and could not be
      # run without sending anyway).
      PROBE_AUTHORIZATION_NEUTRAL_MIDDLEWARE = %w[
        Faraday::Retry::Middleware
        Faraday::Request::Retry
        Faraday::Request::Json
        Faraday::Request::UrlEncoded
        Faraday::Request::Multipart
        Faraday::Response::Logger
      ].freeze

      # The only middleware the probe runs: Faraday's own Authorization
      # middleware, whose header is a pure function of the arguments it was
      # installed with -- and only when those arguments are literal
      # configuration it can do nothing with but read
      # ({#probe_static_value?}). Host middleware is never run.
      PROBE_PURE_MIDDLEWARE = [Faraday::Request::Authorization].freeze

      # Configuration a middleware can only read: a literal, or a plain
      # container of literals. Anything else (a proc that vends a fresh
      # token, an object that answers `call`, a holder something else can
      # rotate) may hand a different credential to every request.
      PROBE_STATIC_CLASSES = [NilClass, TrueClass, FalseClass, Numeric, Symbol, String].freeze

      # How deep a container of configuration is looked into; beyond it the
      # configuration counts as something the probe cannot read.
      PROBE_STATIC_DEPTH = 4

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
          # add or replace the header after the request block ran. Host
          # middleware is never run to find out what it would put there --
          # running it spends whatever one-time credential it vends, and no
          # inspection can tell which middleware does that -- so the answer
          # is unknown for any stack that is not framework middleware the
          # transport can read off its own configuration.
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

      # The headers a request of this operation would go out with, once the
      # connection's middleware had its say -- without sending anything and
      # without running a single line of the host's own code.
      #
      # A `faraday_config` block may install middleware that vends a
      # credential of its own, and four review rounds of reflection could not
      # tell such middleware apart from an inert one: the rotating state can
      # sit in a constant, a global, a thread-local or the binding of a
      # method, none of which building a copy leaves behind. So the probe no
      # longer tries: it steps over framework middleware that sets no
      # Authorization header, runs framework middleware whose header is a
      # pure function of the literal configuration it was installed with
      # ({PROBE_PURE_MIDDLEWARE}), and answers nil -- an unknown context, in
      # which no private entry is served -- for anything else.
      # @param headers [Hash] the headers before middleware
      # @param method [String] the JSON-RPC method the probe models
      # @param params [Hash] its params
      # @return [Hash, nil] the headers after middleware, or nil when they cannot be determined
      def middleware_request_headers(headers, method = @probe_method || 'ping', params = {})
        conn = http_connection
        pure = []
        conn.builder.handlers.each do |handler|
          # The recorder is the probe's own, and middleware that sets no
          # Authorization header changes no answer here.
          next if handler.klass == AuthorizationRecorder
          next if PROBE_AUTHORIZATION_NEUTRAL_MIDDLEWARE.include?(handler.klass.name)
          next if probe_response_only_middleware?(handler.klass)
          return nil unless probe_pure_middleware?(handler)

          pure << handler
        end
        # Nothing on the stack can change the header: no request is modelled
        # at all, so the host's request_meta is not read for one either.
        return headers if pure.empty?

        env = probe_request_env(conn, headers, method, params)
        pure.each { |handler| handler.build(NOOP_APP).on_request(env) }
        env.request_headers
      rescue StandardError => e
        @logger.debug("Could not tell which Authorization header a request would carry: #{e.class}")
        nil
      end

      # The Faraday env of a request shaped like the real JSON-RPC POST of
      # the operation (endpoint, JSON body with its method and params),
      # which is never sent: the framework middleware the probe runs sees
      # the request a real one would.
      # @param conn [Faraday::Connection]
      # @param headers [Hash] the headers before middleware
      # @param method [String] the JSON-RPC method the probe models
      # @param params [Hash] its params
      # @return [Faraday::Env]
      def probe_request_env(conn, headers, method, params)
        request = conn.build_request(:post) do |req|
          req.url(@endpoint)
          headers.each { |k, v| req.headers[k] = v }
          req.headers['Content-Type'] = 'application/json'
          # The body a real request would carry, its effective `_meta`
          # included (host request_meta, protocol fields).
          probe = build_jsonrpc_request(method, params, 0, note: false)
          req.body = JSON.generate(probe)
          # The routing headers a real modern POST carries.
          modern_request_headers(probe).each { |k, v| req.headers[k] = v } if modern?
        end
        request.to_env(conn)
      end

      # Whether a middleware has no request phase at all, so nothing it does
      # can change what a request carries: Faraday's own `call` runs
      # `on_request` and then the response phase, which a probe that sends
      # nothing never reaches. This is the shape of the class, not a guess
      # about what its code does, and no host code runs to establish it.
      # @param klass [Class] a middleware class on the connection
      # @return [Boolean]
      def probe_response_only_middleware?(klass)
        return false if klass.method_defined?(:on_request) || klass.private_method_defined?(:on_request)

        klass.method_defined?(:call) && klass.instance_method(:call).owner == Faraday::Middleware
      end

      # Whether a handler installs framework middleware the probe may run:
      # one of {PROBE_PURE_MIDDLEWARE} (exactly, never a subclass of it),
      # configured without a block and with nothing but literal
      # configuration. Its constructor can then take nothing to spend and
      # its request hook can vend nothing but what it was handed.
      # @param handler [Faraday::RackBuilder::Handler]
      # @return [Boolean]
      def probe_pure_middleware?(handler)
        return false unless PROBE_PURE_MIDDLEWARE.include?(handler.klass)
        return false if handler.instance_variable_get(:@block)

        args = handler.instance_variable_get(:@args)
        kwargs = handler.instance_variable_get(:@kwargs) || {}
        return false unless args.is_a?(Array) && kwargs.is_a?(Hash)

        (args + kwargs.to_a.flatten(1)).all? { |arg| probe_static_value?(arg) }
      end

      # @param value [Object] an argument a middleware was installed with
      # @param depth [Integer]
      # @return [Boolean] whether it is configuration and nothing else
      def probe_static_value?(value, depth = 0)
        return true if PROBE_STATIC_CLASSES.any? { |klass| value.is_a?(klass) }
        return false unless value.is_a?(Hash) || value.is_a?(Array)
        return false unless depth < PROBE_STATIC_DEPTH

        members = value.is_a?(Hash) ? value.flat_map { |k, v| [k, v] } : value
        members.all? { |member| probe_static_value?(member, depth + 1) }
      end

      # Whether a fetch brought tool definitions other than the ones it
      # replaced. A first fetch replaces nothing, so it announces no change.
      # @param previous [Array<MCPClient::Tool>, nil] the list held before the fetch
      # @param tools [Array<MCPClient::Tool>] the freshly fetched list
      # @return [Boolean]
      def tool_definitions_changed?(previous, tools)
        return false if previous.nil?

        tool_definitions(previous) != tool_definitions(tools)
      end

      # @param tools [Array<MCPClient::Tool>]
      # @return [Array<Array>] what a caller of the list can act on
      def tool_definitions(tools)
        tools.map { |t| [t.name, t.description, t.schema, t.output_schema, t.annotations] }
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
