# frozen_string_literal: true

require_relative '../request_authorization'

module MCPClient
  module HttpTransportBase
    # MCP 2026-07-28 caching support shared by the HTTP transports: serving
    # a stale list on transient re-fetch failures, and keeping privately
    # scoped cache entries within their authorization context.
    module CacheSupport
      # The per-thread record of the Authorization a request went out with,
      # kept exactly as every other transport keeps it.
      include MCPClient::RequestAuthorization

      # Stand-in app for instantiating middleware whose request hook is run
      # without a request (the freshness probe).
      NOOP_APP = ->(_env) {}

      # Context that matches no cached entry: the credentials the next
      # request would carry cannot be determined without sending it.
      UNKNOWN_CONTEXT = :unknown

      # Framework middleware that never puts an Authorization header on a
      # request, whatever literal configuration it was installed with: the
      # probe steps over it instead of running it (some of it overrides
      # `call` and could not be run without sending anyway). A handler that
      # was also handed a host callback is unknown all the same
      # ({#probe_host_callback_free?} is checked first).
      #
      # `Faraday::FollowRedirects::Middleware` is on the list because the gem
      # itself depends on it and a host that installs it should keep its
      # private cache hits: it has no request phase, and the only header it
      # ever touches is the Authorization it *deletes* on a cross-host
      # redirect -- which can cost a hit, never leak one.
      PROBE_AUTHORIZATION_NEUTRAL_MIDDLEWARE = %w[
        Faraday::Retry::Middleware
        Faraday::Request::Retry
        Faraday::Request::Json
        Faraday::Request::UrlEncoded
        Faraday::Request::Multipart
        Faraday::Response::Json
        Faraday::Response::Logger
        Faraday::FollowRedirects::Middleware
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

      # Constructors that build a middleware instance and nothing else. A
      # class with a constructor of its own can give its instances an
      # `on_request` hook (`define_singleton_method`, an extended module),
      # which a test of the class would never see -- so a class-level
      # "no request phase" verdict only holds when Faraday's own constructor
      # is the one that builds the instance.
      PROBE_DEFAULT_INITIALIZE_OWNERS = [Faraday::Middleware, Object, Kernel, BasicObject].freeze

      # Faraday env keys the {AuthorizationRecorder} files one exchange's
      # record under. Both belong to that exchange and to no other, which a
      # thread-local cannot express: a request the host's response phase
      # nests inside this one runs on this very thread and would overwrite
      # whatever this exchange left there.
      SENT_AUTHORIZATION_KEY = :mcp_client_sent_authorization
      RESPONSE_RECEIVED_AT_KEY = :mcp_client_response_received_at

      # Innermost middleware on the JSON-RPC connection: it records the
      # Authorization a request carries once every host middleware
      # (faraday_config) has run, right before the adapter sends it, and the
      # moment the response came back, before any host `on_complete` had it.
      # A request that then times out or fails to connect still has a known
      # context, so the stale copy of that context may be served.
      class AuthorizationRecorder < Faraday::Middleware
        def initialize(app, transport)
          super(app)
          @transport = transport
        end

        def on_request(env)
          @transport.send(:note_request_authorization,
                          MCPClient::ResultCaching.authorization_header_value(env.request_headers))
          env[SENT_AUTHORIZATION_KEY] = @transport.send(:recorded_request_authorization)
        end

        # The bytes are in hand and nothing of the host's has run on them
        # yet: the TTL of whatever this response carries starts here (MCP
        # 2026-07-28 caching, "Freshness Calculation").
        def on_complete(env)
          env[RESPONSE_RECEIVED_AT_KEY] = @transport.send(:monotonic_now)
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
        base = probe_base_headers
        return UNKNOWN_CONTEXT if base.nil?

        probe = HeaderProbe.new(base)
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

      # The headers a request starts from, before the OAuth provider and
      # before any middleware: the transport's own configured headers, laid
      # over whatever the connection itself carries.
      #
      # A `faraday_config` block may set or mutate `conn.headers` — including
      # `Authorization` — and every request Faraday builds on that connection
      # starts from that table, so a probe that read only `@headers` would
      # answer "anonymous" for requests that go out with a bearer. Reading a
      # built connection's header table executes no middleware and runs no
      # host code: the block has already run (the same connection sends the
      # real requests), and the table is plain configuration.
      # @return [Faraday::Utils::Headers, nil] nil when the connection could
      #   carry an authorization the probe cannot see
      def probe_base_headers
        headers = faraday_headers(@headers)
        return headers unless @faraday_config

        # `@headers` wins over the connection's table, exactly as it does on
        # the wire ({#apply_request_headers} applies it per request).
        base = faraday_headers(http_connection.headers)
        headers.each { |key, value| base[key] = value }
        base
      rescue StandardError => e
        @logger.debug("Could not read the Authorization configured on the connection: #{e.class}")
        nil
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
          case probe_handler_class(handler)
          when :neutral then next
          when :pure then pure << handler
          else return nil
          end
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

      # What one handler on the connection is, as far as the probe can tell
      # without running a line of the host's code:
      #
      # * `:neutral` — it cannot change what a request carries: the probe's
      #   own recorder, framework middleware that never sets an Authorization
      #   header ({PROBE_AUTHORIZATION_NEUTRAL_MIDDLEWARE}) or middleware with
      #   no request phase at all;
      # * `:pure` — framework middleware whose header is a pure function of
      #   the literal configuration it was installed with, which the probe may
      #   therefore run ({PROBE_PURE_MIDDLEWARE});
      # * `:unknown` — anything else, including every handler carrying a
      #   callback the host supplied: Faraday hands it the mutable request
      #   env, and nothing about the middleware class it was given to says
      #   what the request would then carry, or contain.
      # @param handler [Faraday::RackBuilder::Handler]
      # @return [Symbol] :neutral, :pure or :unknown
      def probe_handler_class(handler)
        return :neutral if handler.klass == AuthorizationRecorder
        return :unknown unless probe_host_callback_free?(handler)
        return :neutral if PROBE_AUTHORIZATION_NEUTRAL_MIDDLEWARE.include?(handler.klass.name)
        return :neutral if probe_response_only_middleware?(handler.klass)

        probe_pure_middleware?(handler) ? :pure : :unknown
      end

      # Whether the JSON-RPC body this transport builds is the body the server
      # answers. A `faraday_config` block may install middleware that rewrites
      # it — a locale, a tenant, a nonce written into `params._meta` — and the
      # effective parameters a result is bound to would then describe a
      # request that was never sent.
      # @return [Boolean]
      def probe_request_body_faithful?
        return true unless @faraday_config

        http_connection.builder.handlers.all? { |handler| probe_body_neutral_handler?(handler) }
      rescue StandardError => e
        @logger.debug("Could not tell whether a request reaches the server as built: #{e.class}")
        false
      end

      # Whether one handler provably leaves the JSON-RPC body alone: the
      # probe's own recorder, framework middleware that touches no body
      # ({PROBE_AUTHORIZATION_NEUTRAL_MIDDLEWARE}), middleware with no request
      # phase at all, or {PROBE_PURE_MIDDLEWARE} — whose request hook writes
      # one header and never hands its configuration the env.
      #
      # What such a handler was configured with does not matter here, which is
      # where this parts company with the Authorization question: a credential
      # that rotates changes the header a request carries, never the
      # parameters the server answers. A handler carrying a host callback is
      # unknown all the same — Faraday hands it the mutable env, body included.
      # @param handler [Faraday::RackBuilder::Handler]
      # @return [Boolean]
      def probe_body_neutral_handler?(handler)
        return true if handler.klass == AuthorizationRecorder
        return true if PROBE_PURE_MIDDLEWARE.include?(handler.klass)
        return false unless probe_host_callback_free?(handler)

        PROBE_AUTHORIZATION_NEUTRAL_MIDDLEWARE.include?(handler.klass.name) ||
          probe_response_only_middleware?(handler.klass)
      end

      # The effective parameters the next request would carry, or
      # {MCPClient::RequestMetadata::OPAQUE_PARAMS} when host middleware may
      # rewrite its body: no fingerprint then describes the request the server
      # would answer, so no cached result is served for it — whatever its
      # `cacheScope`, since sharing across callers is not sharing across
      # result-affecting parameters (MCP 2026-07-28 server/utilities/caching).
      # @return [String, Symbol]
      def current_params_fingerprint
        probe_request_body_faithful? ? super : MCPClient::RequestMetadata::OPAQUE_PARAMS
      end

      # @return [String, Symbol, nil] the parameters of the request this
      #   thread last sent, opaque for the same reason
      def request_params_fingerprint
        probe_request_body_faithful? ? super : MCPClient::RequestMetadata::OPAQUE_PARAMS
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
        return false unless klass.method_defined?(:call) && klass.instance_method(:call).owner == Faraday::Middleware

        probe_default_construction?(klass)
      end

      # @param klass [Class] a middleware class on the connection
      # @return [Boolean] whether its instances come out of Faraday's own constructor
      def probe_default_construction?(klass)
        return false unless PROBE_DEFAULT_INITIALIZE_OWNERS.include?(klass.instance_method(:initialize).owner)

        klass.method(:new).owner == Class
      end

      # Whether a handler installs framework middleware the probe may run:
      # one of {PROBE_PURE_MIDDLEWARE} (exactly, never a subclass of it),
      # configured with nothing but literal configuration. Its constructor
      # can then take nothing to spend and its request hook can vend nothing
      # but what it was handed. This is stricter than
      # {#probe_host_callback_free?}: a holder something else can rotate is
      # nothing a middleware may *run*, but it is still a credential that
      # can differ from request to request.
      # @param handler [Faraday::RackBuilder::Handler]
      # @return [Boolean]
      def probe_pure_middleware?(handler)
        return false unless PROBE_PURE_MIDDLEWARE.include?(handler.klass)

        args = handler.instance_variable_get(:@args)
        kwargs = handler.instance_variable_get(:@kwargs) || {}
        return false unless args.is_a?(Array) && kwargs.is_a?(Hash)

        (args + kwargs.to_a.flatten(1)).all? { |arg| probe_static_value?(arg) }
      end

      # Whether a handler carries no host code of its own: no configuration
      # block, and no argument the middleware it was given to could call.
      #
      # A logger formatter, a redirect callback, a class the middleware
      # instantiates -- all of it is host code that the middleware hands the
      # mutable request env, and the middleware class it was given to says
      # nothing about what it will do with it. A handler that carries one is
      # an unknown context however inert its class looks; a logger *sink*,
      # which only ever receives strings, is configuration like any other.
      # @param handler [Faraday::RackBuilder::Handler]
      # @return [Boolean]
      def probe_host_callback_free?(handler)
        return false if handler.instance_variable_get(:@block)

        args = handler.instance_variable_get(:@args)
        kwargs = handler.instance_variable_get(:@kwargs) || {}
        return false unless args.is_a?(Array) && kwargs.is_a?(Hash)

        (args + kwargs.to_a.flatten(1)).none? { |arg| probe_host_callback?(arg) }
      end

      # @param value [Object] an argument a middleware was installed with
      # @param depth [Integer]
      # @return [Boolean] whether it is (or contains) code the middleware could run
      def probe_host_callback?(value, depth = 0)
        return true if value.is_a?(Proc) || value.is_a?(Method) || value.is_a?(Module) || value.respond_to?(:call)
        return false unless value.is_a?(Hash) || value.is_a?(Array)
        # Past the depth a container is looked into, what it holds is
        # unknown -- and unknown counts as host code.
        return true unless depth < PROBE_STATIC_DEPTH

        members = value.is_a?(Hash) ? value.flat_map { |k, v| [k, v] } : value
        members.any? { |member| probe_host_callback?(member, depth + 1) }
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
        # When the innermost middleware had the response, not when the host's
        # response phase was finished with it.
        received_at = response_receipt_time(response)
        # The credentials this exchange's own request went out with, as the
        # recorder filed them against it: a request the response phase nested
        # inside this one left its own on this thread.
        restore_recorded_request_authorization(response)
        # A connection that recorded nothing of its own still names the
        # credentials it sent in the response's environment.
        note_sent_authorization(response)
        # Taken before the parse: a notification callback may nest one too.
        sent_authorization = recorded_request_authorization
        begin
          result = parse_response(response, request)
        ensure
          # The outer request's own context, whatever a notification the
          # response carried did on this thread — and whether or not the
          # parse succeeded, so a failed re-fetch is judged by its own
          # credentials and parameters.
          restore_request_authorization(sent_authorization)
          note_request_params(request['params'])
        end
        note_response_received_at(received_at) if received_at && respond_to?(:note_response_received_at, true)
        result
      end

      # @param response [Faraday::Response, nil]
      # @return [Faraday::Env, nil] the environment the exchange ran in
      def response_env(response)
        env = response.respond_to?(:env) ? response.env : nil
        env.respond_to?(:[]) ? env : nil
      rescue StandardError
        nil
      end

      # The moment the response was received: what the {AuthorizationRecorder}
      # stamped on the way back in, before a host `on_complete` — which may
      # log, convert, retry or send a request of its own — had the response.
      # A connection carrying no recorder falls back to now.
      # @param response [Faraday::Response, nil]
      # @return [Float, nil]
      def response_receipt_time(response)
        stamped = response_env(response)&.[](RESPONSE_RECEIVED_AT_KEY)
        return stamped if stamped.is_a?(Numeric)

        monotonic_now if respond_to?(:monotonic_now, true)
      end

      # Put back what this exchange's own request was recorded with, over
      # anything a nested request left on this thread since.
      # @param response [Faraday::Response, nil]
      # @return [void]
      def restore_recorded_request_authorization(response)
        record = response_env(response)&.[](SENT_AUTHORIZATION_KEY)
        restore_request_authorization(record) unless record.nil?
      end

      # Remember the Authorization a request actually carried once it was
      # sent, for a connection that recorded none of its own.
      #
      # What binds the result is what the {AuthorizationRecorder} saw
      # immediately before the adapter sent the request. `response.env` is a
      # mutable structure the response phase may rewrite — a host `on_complete`
      # that redacts `Authorization` for logging, a redirect handler that
      # strips it — and reading it back afterwards would file an authenticated
      # result under the anonymous context, where the next anonymous request
      # would be served Alice's private data. So the env answers only when
      # nothing was recorded at all.
      # @param response [Faraday::Response, nil]
      # @return [void]
      def note_sent_authorization(response)
        return if request_authorization_recorded?

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
