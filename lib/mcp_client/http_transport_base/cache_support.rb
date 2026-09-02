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
      PROBE_SAFE_SHARED_STATE = [Logger, Mutex].freeze

      # The only shared state the probe treats as unchangeable: values that
      # hold nothing beyond what {#probe_state_members} enumerates, so
      # freezing them really does close off every value they can hand out.
      # Anything else — a module or class (shared, never copied, and keeping
      # state freezing does not reach), a frozen wrapper such as a Data or a
      # custom object — may vend a different value on a later call.
      PROBE_IMMUTABLE_CLASSES = [NilClass, TrueClass, FalseClass, Numeric, Symbol, String, Regexp, Time,
                                 Hash, Array, Struct, Range].freeze

      # Class-level state Faraday itself keeps on every middleware class it
      # builds: the default options its own class API vends, memoized there
      # on first use. It belongs to the framework, is identical for a fresh
      # copy and for the instance Faraday calls, and no host request hook
      # rotates it, so the probe looks past it.
      PROBE_FRAMEWORK_CLASS_STATE = Faraday::Middleware.singleton_class.instance_methods(false)
                                                       .map { |name| :"@#{name}" }.freeze

      # Where {RubyVM::InstructionSequence#to_a} carries the kind of sequence
      # it serialized (`:method` for a `def`, `:block` for a `define_method`
      # body). A layout that no longer answers `:method` there leaves every
      # host middleware unrunnable, which is the safe way to be wrong.
      ISEQ_TYPE_INDEX = 9

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
      # the live stack must not be run at all (the probe would change it) --
      # state its class keeps or a block closed over included, neither of
      # which building a copy leaves behind; the answer is then unknown.
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
          # Middleware with no request hook cannot change what a request
          # carries: Faraday's own `call` runs `on_request` and then the
          # response phase, which a probe that sends nothing never reaches.
          # It is neither built nor compared (a response middleware may well
          # hold state the probe would refuse to stand in for).
          next unless handler.klass.method_defined?(:on_request)
          return nil unless probe_inert_middleware_class?(handler.klass)
          return nil unless probe_buildable_middleware?(handler)

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

        # Two containers that merely compare equal are the usual shape of a
        # Faraday middleware built with keyword arguments: `**opts` is a new
        # hash on every build, holding the very same vendor. They stand in
        # for one another only while nothing mutable is reachable through
        # both of them.
        one == other && probe_shares_no_mutable?(one, other)
      rescue StandardError
        false
      end

      # @param one [Object] the fresh copy's state
      # @param other [Object] the live instance's state
      # @return [Boolean] whether the only objects the two can both reach are
      #   ones the probe may share (immutable, or on the safe list)
      def probe_shares_no_mutable?(one, other)
        mine = probe_reachable_state(one)
        theirs = probe_reachable_state(other)
        return false if mine.nil? || theirs.nil?

        mine.each_key.all? { |object| !theirs.key?(object) || probe_safe_shared_state?(object) }
      end

      # Every object a value can hand out, itself included, keyed by identity.
      # State the probe may share is kept whole: what it holds cannot change,
      # or changing it changes no request. nil when the walk would go deeper
      # than {PROBE_IMMUTABLE_DEPTH}, where what is reachable is no longer
      # known and nothing may be assumed unshared.
      # @param value [Object]
      # @param depth [Integer]
      # @param seen [Hash] the objects already walked, compared by identity
      # @return [Hash, nil]
      def probe_reachable_state(value, depth = 0, seen = {}.compare_by_identity)
        return seen if seen.key?(value)

        seen[value] = true
        return seen if probe_safe_shared_state?(value)

        members = probe_state_members(value)
        return seen if members.empty?
        return nil unless depth < PROBE_IMMUTABLE_DEPTH

        members.each { |member| return nil unless probe_reachable_state(member, depth + 1, seen) }
        seen
      end

      # Whether a middleware class keeps no state of its own that running the
      # probe could disturb. Two instances of one class share that class, so
      # anything the class holds -- a class-level instance variable, a class
      # variable, a singleton method that can vend from either -- is state a
      # copy does not isolate: a request hook reaching it (`self.class.next_nonce`)
      # spends the very credential the next real request would have carried.
      # A hook built by `define_method` is the same hazard one level further
      # out: it keeps the binding it was defined in, which no comparison of
      # instances or of constructor arguments can reach. So the rule is
      # inverted for these: only a class whose own methods are all defined
      # with `def` (or in C, an attribute reader closing over nothing), and
      # which holds nothing at class level, may be run.
      # @param klass [Class] a middleware class on the connection
      # @return [Boolean]
      def probe_inert_middleware_class?(klass)
        probe_host_ancestors(klass).all? do |mod|
          (mod.instance_variables - PROBE_FRAMEWORK_CLASS_STATE).empty? && mod.class_variables(false).empty? &&
            mod.singleton_methods(false).empty? && probe_closure_free_module?(mod)
        end
      rescue StandardError
        false
      end

      # The classes and modules the host contributed to a middleware: what
      # Faraday::Middleware itself brings is the framework's own and carries
      # no host credential.
      # @param klass [Class]
      # @return [Array<Module>]
      def probe_host_ancestors(klass)
        klass.ancestors - Faraday::Middleware.ancestors
      end

      # @param mod [Module] a class or module the host contributed
      # @return [Boolean] whether every method it defines closes over nothing
      def probe_closure_free_module?(mod)
        (mod.instance_methods(false) + mod.private_instance_methods(false)).all? do |name|
          probe_closure_free_method?(mod.instance_method(name))
        end
      end

      # Whether a method was defined with `def` rather than from a block.
      # A block-bodied method (`define_method`) carries its defining binding;
      # a method with no instruction sequence at all is implemented in C (an
      # attribute accessor, say) and closes over nothing. Anything else --
      # including a Ruby whose instruction sequences cannot be inspected --
      # counts as a closure, so the probe gives up rather than guess.
      # @param method [UnboundMethod]
      # @return [Boolean]
      def probe_closure_free_method?(method)
        iseq = RubyVM::InstructionSequence.of(method)
        return true if iseq.nil?

        iseq.to_a[ISEQ_TYPE_INDEX] == :method
      rescue StandardError, NotImplementedError
        false
      end

      # Whether the probe may build a copy of a middleware at all. Building
      # runs the host's constructor, and a constructor that takes a one-time
      # credential from what it is handed spends it before any comparison can
      # reject the copy — the credential the next real request then never
      # presents. It can only consume what it is given, so a copy is built
      # only when every argument is state the probe may share, or a plain
      # container of such state (a container vends nothing of its own).
      # @param handler [Faraday::RackBuilder::Handler]
      # @return [Boolean]
      def probe_buildable_middleware?(handler)
        return false if handler.instance_variable_get(:@block)

        args = handler.instance_variable_get(:@args)
        kwargs = handler.instance_variable_get(:@kwargs) || {}
        return false unless args.is_a?(Array) && kwargs.is_a?(Hash)

        (args + kwargs.to_a.flatten(1)).all? { |arg| probe_inert_argument?(arg) }
      end

      # @param value [Object] an argument the handler would pass a fresh copy
      # @param depth [Integer]
      # @return [Boolean] whether it can hand a constructor nothing to spend
      def probe_inert_argument?(value, depth = 0)
        return true if probe_safe_shared_state?(value)
        return false unless value.is_a?(Hash) || value.is_a?(Array)
        return false unless depth < PROBE_IMMUTABLE_DEPTH

        probe_state_members(value).all? { |member| probe_inert_argument?(member, depth + 1) }
      end

      # @param value [Object] state the fresh and live middleware share
      # @return [Boolean] whether running the probe against it can change nothing
      def probe_safe_shared_state?(value)
        probe_immutable_state?(value) || PROBE_SAFE_SHARED_STATE.any? { |klass| value.is_a?(klass) }
      end

      # Whether a value can vend nothing but itself: it must be frozen, of a
      # kind whose whole state is enumerable here, and hold only such values
      # in turn (to a bounded depth — deeper than that it counts as mutable).
      # Being frozen is not enough on its own: a frozen wrapper still hands
      # out the mutable members it was built around, and a module or class
      # is shared rather than copied and keeps state of its own that no
      # freeze reaches.
      # @param value [Object]
      # @param depth [Integer]
      # @return [Boolean]
      def probe_immutable_state?(value, depth = 0)
        return false unless value.frozen?
        return false unless PROBE_IMMUTABLE_CLASSES.any? { |klass| value.is_a?(klass) }

        members = probe_state_members(value)
        return true if members.empty?
        return false unless depth < PROBE_IMMUTABLE_DEPTH

        members.all? { |member| probe_immutable_state?(member, depth + 1) }
      end

      # Everything a value holds: what it was built around as well as
      # whatever was set on it, since either can be handed out later.
      # @param value [Object]
      # @return [Array<Object>]
      def probe_state_members(value)
        held = value.instance_variables.map { |name| value.instance_variable_get(name) }
        case value
        when Hash then held + value.flat_map { |k, v| [k, v] }
        when Array, Struct then held + value.to_a
        when Range then held + [value.begin, value.end]
        else held
        end
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
