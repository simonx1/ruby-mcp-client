# frozen_string_literal: true

require 'json'
require 'zlib'
require 'stringio'
require_relative 'header_params'
require_relative 'json_rpc_common/envelopes'
require_relative 'json_rpc_common/error_bodies'
require_relative 'json_rpc_common/input_waits'
require_relative 'subscription_support'
require_relative 'input_round_trips'
require_relative 'result_caching'

module MCPClient
  # Shared retry/backoff logic for JSON-RPC transports
  module JsonRpcCommon
    include Envelopes
    include ErrorBodies
    include InputWaits
    include SubscriptionSupport
    include InputRoundTrips
    include ResultCaching

    # JSON-RPC methods with arbitrary side effects that MUST NOT be re-sent
    # automatically. Even a "transient" failure (5xx, dropped connection,
    # malformed response) can arrive AFTER the server received the request,
    # so a retry could execute the operation twice — and JSON-RPC has no
    # idempotency key to make the duplicate safe. Callers who want to retry
    # such an operation must decide that explicitly.
    NON_IDEMPOTENT_METHODS = %w[tools/call].freeze

    # Execute the block with retry/backoff for transient errors only.
    #
    # Retries genuinely transient failures where the request most likely did not
    # complete at the server: transport/network errors (TransportError, IOError,
    # Errno::ETIMEDOUT/ECONNRESET/EPIPE) and TransientServerError (HTTP 5xx).
    #
    # It deliberately does NOT retry a plain ServerError. A plain ServerError is
    # raised for a JSON-RPC error response or an HTTP 4xx — cases where the
    # server received and processed (or deterministically rejected) the request.
    # Re-sending those would silently re-execute a non-idempotent operation
    # (e.g. a tools/call), which JSON-RPC provides no way to make safe.
    #
    # It also never retries a NON_IDEMPOTENT_METHODS request (pass the
    # JSON-RPC method being sent): an ambiguous failure may follow server-side
    # receipt, so those fail fast instead of risking a duplicate execution.
    # @param method [String, nil] the JSON-RPC method the block sends
    # @yield block to execute
    # @return [Object] result of block
    # @raise original exception if max retries exceeded or the error is not retryable
    def with_retry(method = nil)
      attempts = 0
      begin
        yield
      rescue MCPClient::Errors::TransientServerError, MCPClient::Errors::TransportError, IOError,
             Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE => e
        # A timed-out request may still be executing server-side; re-sending
        # it could run a non-idempotent operation twice. Never retry those.
        # An oversized response is the same story from the other direction:
        # the server already ran the request, so a re-send risks a duplicate
        # side effect (and re-does the oversized decode).
        raise if e.is_a?(MCPClient::Errors::RequestTimeoutError)
        raise if e.is_a?(MCPClient::Errors::ResponseTooLargeError)
        # A broken response stream is already handled where it is raised: the
        # transport issues the one replacement request MCP 2026-07-28 calls
        # for and this error means that replacement was lost too. Retrying
        # here would silently turn "re-issue once" into retries + 1 rounds of
        # two attempts each.
        raise if e.is_a?(MCPClient::Errors::ResponseStreamClosedError)

        if NON_IDEMPOTENT_METHODS.include?(method)
          @logger.debug("Not retrying non-idempotent #{method} after error: #{e.message}")
          raise
        end

        attempts += 1
        if attempts <= @max_retries
          delay = @retry_backoff * (2**(attempts - 1))
          @logger.debug("Retry attempt #{attempts} after error: #{e.message}, sleeping #{delay}s")
          sleep(delay)
          retry
        end
        raise
      end
    end

    # Maximum characters of peer-supplied text written to the host log.
    MAX_PEER_LOG_TEXT_LENGTH = 4096

    # Make peer-supplied text safe to write to the host log: control
    # characters (notably newlines, which would let a server forge log
    # entries) are escaped and the result is capped.
    # @param text [Object] peer-supplied text
    # @return [String] sanitized, length-bounded text
    def sanitize_log_text(text)
      escaped = text.to_s.gsub(/[\x00-\x1F\x7F]/) { |c| format('\\x%02X', c.ord) }
      return escaped if escaped.length <= MAX_PEER_LOG_TEXT_LENGTH

      "#{escaped[0, MAX_PEER_LOG_TEXT_LENGTH]}... (truncated from #{escaped.length} chars)"
    end

    # Tell a host layered above this transport to drop the caches a
    # notification invalidates, surviving whatever it does with it.
    #
    # Called by every path that fans a notification out to the host — the
    # subscription routing on stdio and both HTTP transports, the legacy SSE
    # parser, and the synthetic tools/list_changed a HeaderMismatch refresh
    # announces — and always before the notification reaches a subscription's
    # listeners. See {MCPClient::ServerBase#on_cache_invalidation} for why the
    # host's own callback cannot serve.
    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def notify_cache_invalidation(method, params)
      @cache_invalidation_callback&.call(method, params)
    rescue StandardError => e
      @logger.warn("Cache invalidation callback error for #{sanitize_log_text(method)}: " \
                   "#{sanitize_log_text(e.message)}")
    end

    # A log-safe description of a JSON-RPC message: its method and id only.
    #
    # Params and results are deliberately omitted. tools/call arguments and
    # tool results routinely carry credentials, personal data or customer
    # content, and logs are frequently shipped to lower-trust destinations
    # (aggregators, CI artifacts, support bundles) — so enabling DEBUG must
    # not silently start recording payloads.
    # @param message [Hash] a JSON-RPC request, notification or response
    # @return [String] method/id summary, never payload content
    def describe_jsonrpc_message(message)
      return '(non-object message)' unless message.is_a?(Hash)

      parts = []
      parts << (message['method'] || message[:method] || '(response)').to_s
      id = message['id'] || message[:id]
      parts << "id=#{id}" if id
      parts << 'error' if message['error'] || message[:error]
      parts.join(' ')
    end

    # A log-safe description of a JSON parse failure.
    #
    # JSON::ParserError#message quotes the offending token — e.g.
    # "expected object key, got 'SECRET-123' at line 1 column 2" — so
    # interpolating it puts peer-controlled bytes straight into logs and
    # exception messages. Keep the position, which is what actually helps
    # diagnose a broken server, and drop the quoted content.
    # @param error [JSON::ParserError] the parse failure
    # @param payload [String, nil] the payload that failed to parse
    # @return [String] position and size, never payload content
    def describe_parse_error(error, payload = nil)
      location = error.message[/at line \d+ column \d+/]
      parts = ['malformed JSON']
      parts << location if location
      parts << describe_body_size(payload) if payload
      parts.join(', ')
    end

    # A log-safe description of a payload body: its size, never its content.
    # A host's `conn.response :json` middleware hands the decoded object here
    # instead of the bytes it came from; say so rather than measuring it.
    # @param body [String, Object, nil] the response/request body
    # @return [String]
    def describe_body_size(body)
      return 'empty body' if body.nil? || (body.respond_to?(:empty?) && body.empty?)
      return "decoded #{body.class} body" unless body.is_a?(String)

      "#{body.bytesize} bytes"
    end

    # Ping the server to keep the connection alive
    # @return [Hash] the result of the ping request
    # @raise [MCPClient::Errors::ToolCallError] if ping times out or fails
    # @raise [MCPClient::Errors::TransportError] if there's a connection error
    # @raise [MCPClient::Errors::ServerError] if the server returns an error
    def ping
      rpc_request('ping')
    end

    # Whether automatic notifications/cancelled on timeout is appropriate
    # for this request: never for initialize (MUST NOT be cancelled), and
    # never for task-augmented requests (tasks use tasks/cancel instead).
    # @param method [String] JSON-RPC method
    # @param params [Hash] request params
    # @return [Boolean]
    def cancellable_request?(method, params)
      return false if method == 'initialize'
      return false if params.is_a?(Hash) && (params.key?('task') || params.key?(:task))

      true
    end

    # Split request-level _meta (RequestParams._meta, e.g. progressToken or
    # related-task metadata) out of user-supplied tool/prompt arguments.
    # Accepts both :_meta and '_meta' key spellings; per MCP, _meta belongs at
    # the request params level, not inside the tool's arguments.
    # @param arguments [Hash, nil] user-supplied arguments
    # @return [Array(Hash, Hash|nil)] [arguments without _meta, _meta or nil]
    def split_request_meta(arguments)
      return [arguments, nil] unless arguments.is_a?(Hash)

      meta = arguments[:_meta] || arguments['_meta']
      return [arguments, nil] unless meta

      [arguments.except(:_meta, '_meta'), meta]
    end

    # Build tools/call- or prompts/get-style params with request-level _meta
    # hoisted out of the arguments (string keys, matching the JSON wire form).
    # @param name [String] tool or prompt name
    # @param arguments [Hash] user-supplied arguments (possibly carrying _meta)
    # @return [Hash] params hash for the JSON-RPC request
    def build_named_request_params(name, arguments)
      args, meta = split_request_meta(arguments)
      params = { 'name' => name, 'arguments' => args }
      params['_meta'] = meta if meta
      params
    end

    # Build a JSON-RPC request object
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the request
    # @param id [Integer] request ID
    # @return [Hash] the JSON-RPC request object
    def build_jsonrpc_request(method, params, id)
      {
        'jsonrpc' => '2.0',
        'id' => id,
        'method' => method,
        'params' => with_request_meta(params)
      }
    end

    # Reserved `_meta` keys (MCP 2026-07-28 basic/index "_meta").
    META_PROTOCOL_VERSION = 'io.modelcontextprotocol/protocolVersion'
    META_CLIENT_INFO = 'io.modelcontextprotocol/clientInfo'
    META_CLIENT_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities'
    META_LOG_LEVEL = 'io.modelcontextprotocol/logLevel'
    META_SERVER_INFO = 'io.modelcontextprotocol/serverInfo'
    META_SUBSCRIPTION_ID = 'io.modelcontextprotocol/subscriptionId'

    # Per-request protocol fields the client owns. A host-supplied `_meta`
    # may carry anything else (progressToken, trace context, vendor keys),
    # but these are always set from the transport's own state so the body
    # can never disagree with what the transport negotiated (on HTTP the
    # MCP-Protocol-Version header must match the body).
    PROTECTED_META_KEYS = [META_PROTOCOL_VERSION, META_CLIENT_INFO, META_CLIENT_CAPABILITIES].freeze

    # Log levels defined by the logging utility (RFC 5424 severities).
    LOG_LEVELS = %w[debug info notice warning error critical alert emergency].freeze

    # Extension identifiers follow the `_meta` key naming rules with a
    # mandatory prefix (basic/versioning "Extension Negotiation"): dotted
    # labels, a slash, then a name. The name is optional — basic/index says
    # of it "Unless empty, MUST begin and end with an alphanumeric
    # character" — so a prefix on its own (`com.example/`) is a valid
    # identifier.
    EXTENSION_ID_PATTERN = %r{\A(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?/
                              (?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)?\z}x

    # The server's established protocol era.
    #
    # Deliberately not the same question as {#modern?}: while a
    # server/discover probe is in flight, protocol_version holds the version
    # the probe *proposes*, which is what outgoing requests must declare but
    # says nothing about what the server speaks. Anything that reacts to the
    # peer — above all, whether a server-initiated request is prohibited —
    # must consult the era, not the tentative outgoing version.
    # @return [Symbol, nil] :modern, :legacy, or nil before the era is known
    def protocol_era
      return nil if era_probe_in_flight? || protocol_version.nil?

      modern? ? :modern : :legacy
    end

    # Begin proposing a protocol version that the server has not confirmed:
    # until the probe settles, the era is unknown.
    # @return [void]
    def begin_era_probe
      @era_probe_in_flight = true
    end

    # The probe has been answered (or given up on): the era is now whatever
    # protocol_version says.
    # @return [void]
    def settle_era_probe
      @era_probe_in_flight = false
    end

    # @return [Boolean] whether protocol_version is only a proposal so far
    def era_probe_in_flight?
      defined?(@era_probe_in_flight) ? @era_probe_in_flight : false
    end

    # Protocol versions a modern server advertised in its DiscoverResult.
    # @return [Array<String>, nil]
    def supported_versions
      defined?(@supported_versions) ? @supported_versions : nil
    end

    # Pick the newest modern version this client speaks from a server's
    # advertised list (DiscoverResult.supportedVersions or
    # UnsupportedProtocolVersionError.data.supported).
    # @param supported [Array<String>, nil] versions the server supports
    # @return [String, nil] the chosen version, nil when none is mutual
    def select_protocol_version(supported)
      return nil unless supported.is_a?(Array)

      MCPClient::MODERN_PROTOCOL_VERSIONS.find { |version| supported.include?(version) }
    end

    # Host-supplied metadata merged into every request's `_meta`: a Hash, or
    # a callable returning one, evaluated per request. Intended for
    # OpenTelemetry trace context (`traceparent`, `tracestate`, `baggage`)
    # and vendor-prefixed keys. Reserved protocol fields cannot be
    # overridden through it.
    # @return [Hash, #call, nil]
    attr_accessor :request_meta

    # Whether to identify this client on every request via
    # `io.modelcontextprotocol/clientInfo` (MCP 2026-07-28: clients SHOULD,
    # "unless specifically configured not to do so").
    # @param value [Boolean]
    attr_writer :send_client_info

    # @return [Boolean] whether clientInfo is sent (default true)
    def send_client_info?
      !(defined?(@send_client_info) && @send_client_info == false)
    end

    # Declare support for an MCP extension (basic/versioning "Extension
    # Negotiation"): advertised under `clientCapabilities.extensions` on
    # every modern request.
    # @param identifier [String] the extension id, e.g. 'io.modelcontextprotocol/tasks'
    # @param settings [Hash] per-extension settings ({} = support, no settings)
    # @return [void]
    # @raise [ArgumentError] if the identifier lacks the mandatory prefix
    def declare_extension(identifier, settings = {})
      unless identifier.is_a?(String) && identifier.match?(EXTENSION_ID_PATTERN)
        raise ArgumentError, "Extension identifier #{identifier.inspect} must have a dotted prefix and a slash " \
                             '(e.g. io.modelcontextprotocol/tasks)'
      end

      settings = {} if settings.nil?
      unless settings.is_a?(Hash)
        raise ArgumentError, "Extension settings for #{identifier} must be an object (Hash), got #{settings.class}"
      end

      # An extension that adds a result type is advertised only by a client
      # that can accept that result type: a server told the extension is
      # negotiated may answer with it, and an unrecognized resultType is an
      # invalid response — the usable answer would be lost.
      added = RESULT_TYPE_EXTENSIONS[identifier]
      if added && !implemented_extension_result_types.key?(identifier)
        raise ArgumentError,
              "Extension #{identifier} adds the result type #{added.inspect}, which this client does not implement"
      end

      @declared_extensions ||= {}
      @declared_extensions[identifier] = settings
    end

    # @return [Hash] declared extension id => settings
    def declared_extensions
      defined?(@declared_extensions) && @declared_extensions ? @declared_extensions : {}
    end

    # Attach request-level `_meta` to a params object: the host's
    # request_meta defaults first, then any per-request `_meta` the caller
    # supplied (which wins over the defaults), then — for a modern server —
    # the reserved protocol fields, which always win. Params are returned
    # untouched when there is nothing to add, so legacy traffic is unchanged.
    # @param params [Hash, nil] request params (String or Symbol keys)
    # @return [Hash, nil] params with `_meta` merged under the String key
    def with_request_meta(params)
      params = merge_meta_spellings(params)
      defaults = host_request_meta
      return params if defaults.empty? && !modern? && !reserved_meta_supplied?(params)

      params = params.is_a?(Hash) ? params.dup : {}
      supplied = params.delete('_meta')
      supplied = supplied.is_a?(Hash) ? supplied.transform_keys(&:to_s) : {}
      # The reserved protocol fields are transport-owned in per-call `_meta`
      # exactly as they are in request_meta. Merging the transport's own
      # values over the caller's is not enough: a field the transport omits
      # (clientInfo, once the host set send_client_info = false) has nothing
      # to overwrite the caller's value with, so it would be transmitted
      # anyway. Drop them before the defaults are merged.
      supplied = supplied.except(*PROTECTED_META_KEYS)

      meta = defaults.merge(supplied)
      if modern?
        meta[META_LOG_LEVEL] = @log_level if defined?(@log_level) && @log_level && !meta.key?(META_LOG_LEVEL)
        meta.merge!(required_request_meta)
      end
      params['_meta'] = meta
      params
    end

    # A caller's `_meta` supplied under the Symbol key, or under both
    # spellings, becomes one String-keyed `_meta` (the String one winning on
    # a clash). Two spellings would otherwise serialize as two `_meta`
    # members — and whatever was stripped from one copy would reach the wire
    # through the other, since only one is inspected.
    # @param params [Hash, nil] request params
    # @return [Hash, nil] params with at most one `_meta` member, under the String key
    def merge_meta_spellings(params)
      return params unless params.is_a?(Hash) && params.key?(:_meta)

      params = params.dup
      symbol_meta = params.delete(:_meta)
      string_meta = params['_meta']
      symbol_meta = symbol_meta.is_a?(Hash) ? symbol_meta.transform_keys(&:to_s) : {}
      string_meta = string_meta.is_a?(Hash) ? string_meta.transform_keys(&:to_s) : {}
      params['_meta'] = symbol_meta.merge(string_meta)
      params
    end

    # Whether a caller's params carry a `_meta` key the transport owns.
    #
    # A legacy request with no host defaults has nothing to merge and no
    # protocol fields to add, so it is otherwise handed on untouched — but the
    # reserved keys are the client's to set in every era. A dual-era server
    # reads a request carrying modern per-request `_meta` AS a modern request
    # (basic/versioning), so leaving a caller's copy on the wire would have
    # one call served statelessly while this session goes on believing it
    # negotiated 2025-11-25.
    # @param params [Hash, nil] request params
    # @return [Boolean]
    def reserved_meta_supplied?(params)
      return false unless params.is_a?(Hash)

      supplied = params['_meta'] || params[:_meta]
      return false unless supplied.is_a?(Hash)

      supplied.any? { |key, _| PROTECTED_META_KEYS.include?(key.to_s) }
    end

    # The reserved per-request protocol fields for a modern server
    # (basic/index "Per-request protocol fields").
    # @return [Hash]
    def required_request_meta
      meta = { META_PROTOCOL_VERSION => protocol_version }
      meta[META_CLIENT_INFO] = client_info_payload if send_client_info?
      meta[META_CLIENT_CAPABILITIES] = client_capabilities
      meta
    end

    # Evaluate the host's request_meta for one request, dropping any
    # reserved protocol keys it tries to set.
    # @return [Hash] String-keyed metadata (possibly empty)
    def host_request_meta
      source = request_meta
      source = source.call if source.respond_to?(:call)
      return {} unless source.is_a?(Hash)

      source.transform_keys(&:to_s).except(*PROTECTED_META_KEYS)
    end

    # Apply a DiscoverResult (server/discover): choose the protocol version
    # for subsequent requests and record the server's capabilities,
    # identity and instructions.
    # @param result [Hash] the DiscoverResult
    # @return [Hash] the result
    # @raise [MCPClient::Errors::ConnectionError] if the result is malformed or no version is mutual
    def apply_discover_result(result)
      unless result.is_a?(Hash)
        raise MCPClient::Errors::ConnectionError, "Server returned an invalid server/discover result (#{result.class})"
      end

      reject_input_required_discover!(result)
      versions = result['supportedVersions']
      unless versions.is_a?(Array) && versions.all?(String)
        raise MCPClient::Errors::ConnectionError, 'server/discover result has no supportedVersions list'
      end

      version = select_protocol_version(versions)
      unless version
        # A DiscoverResult settles the era even when it settles no version:
        # only a modern server answers server/discover with one. Raising the
        # typed error keeps MCPClient.connect from trying the legacy
        # transports, which cannot do better against a modern server.
        raise MCPClient::Errors::ModernServerError,
              "Server supports protocol versions #{versions.join(', ')}, none of which this client speaks " \
              "(modern versions supported: #{MCPClient::MODERN_PROTOCOL_VERSIONS.join(', ')})"
      end
      # Everything is checked before anything is recorded: a refresh that
      # fails to validate changes nothing, not even the identity it carried.
      capabilities = result['capabilities']
      unless capabilities.nil? || capabilities.is_a?(Hash)
        raise MCPClient::Errors::ConnectionError, 'server/discover result capabilities is not an object'
      end

      meta = result['_meta']
      unless meta.nil? || meta.is_a?(Hash)
        raise MCPClient::Errors::ConnectionError, 'server/discover result _meta is not an object'
      end

      @protocol_version = version
      @supported_versions = versions
      @last_discover_result = result
      record_cache_hint(:discover, result)
      @capabilities = capabilities || {}
      @instructions = result['instructions']
      info = meta && meta[META_SERVER_INFO]
      @server_info = info if info.is_a?(Hash)
      record_discovery_freshness(result)
      result
    end

    # Record a DiscoverResult's cache hints (CacheableResult: ttlMs,
    # cacheScope). A ttlMs of zero means the result is immediately stale.
    # @param result [Hash] the DiscoverResult
    # @return [void]
    def record_discovery_freshness(result)
      @discovery_expires_at = discovery_clock + discovery_ttl_seconds(result['ttlMs'])
      scope = result['cacheScope']
      @discovery_cache_scope = scope.is_a?(String) ? scope : nil
    end

    # The freshness a ttlMs hint grants, by the caching rules: a JSON number
    # (an Integer or a Float on the wire) of milliseconds; zero is
    # immediately stale, and a negative, absent or malformed hint SHOULD be
    # treated as zero.
    # @param ttl [Object] the ttlMs member
    # @return [Float] seconds of freshness
    def discovery_ttl_seconds(ttl)
      return 0.0 unless ttl.is_a?(Numeric) && ttl.finite? && ttl.positive?

      ttl / 1000.0
    end

    # @return [Float] the monotonic clock, in seconds, discovery freshness is judged by
    def discovery_clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Whether the last DiscoverResult is still fresh by its own ttlMs. A
    # session that recorded no discovery at all (a 2025-11-25 one) has
    # nothing to refresh.
    # @return [Boolean]
    def discovery_fresh?
      deadline = defined?(@discovery_expires_at) ? @discovery_expires_at : nil
      deadline.nil? || discovery_clock < deadline
    end

    # @return [String, nil] the cacheScope the last DiscoverResult declared
    def discovery_cache_scope
      defined?(@discovery_cache_scope) ? @discovery_cache_scope : nil
    end

    # Validate a log level name (logging utility levels).
    # @param level [String, Symbol] the level
    # @return [String] the normalized level
    # @raise [ArgumentError] if it is not a defined level
    def validate_log_level!(level)
      name = level.to_s
      return name if LOG_LEVELS.include?(name)

      raise ArgumentError, "Unknown log level #{level.inspect}; expected one of #{LOG_LEVELS.join(', ')}"
    end

    # Build a JSON-RPC notification object (no response expected)
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the notification
    # @return [Hash] the JSON-RPC notification object
    def build_jsonrpc_notification(method, params)
      {
        'jsonrpc' => '2.0',
        'method' => method,
        # Modern notifications carry the same _meta as requests: on HTTP the
        # MCP-Protocol-Version header must match the body.
        'params' => with_request_meta(params)
      }
    end

    # The protocol version in use with this server, once established: chosen
    # via server/discover for a modern server or negotiated by initialize for
    # a legacy one. nil until then.
    # @return [String, nil]
    def protocol_version
      defined?(@protocol_version) ? @protocol_version : nil
    end

    # Whether this server speaks a modern (per-request metadata, no
    # handshake) protocol revision (MCP 2026-07-28 basic/versioning
    # "Terminology"). false until the era is established.
    # @return [Boolean]
    def modern?
      MCPClient::MODERN_PROTOCOL_VERSIONS.include?(protocol_version)
    end

    # Generate initialization parameters for MCP protocol
    # @return [Hash] the initialization parameters
    def initialization_params
      {
        'protocolVersion' => MCPClient::PROTOCOL_VERSION,
        'capabilities' => client_capabilities,
        'clientInfo' => client_info_payload
      }
    end

    # Validate the protocol version the server negotiated in its initialize
    # result. Per the MCP lifecycle, the server may answer with a different
    # version than requested; if the client cannot support it, it MUST
    # disconnect. Disconnects (via the transport's cleanup) and raises when
    # the version is unsupported or absent.
    # @param result [Hash] the initialize result
    # @return [String] the negotiated protocol version
    # @raise [MCPClient::Errors::ConnectionError] if the version is unsupported
    def validate_protocol_version!(result)
      version = result['protocolVersion']
      # Only handshake-based revisions are valid here: a server answering
      # initialize with a modern (per-request metadata) version is confused.
      return version if MCPClient::LEGACY_PROTOCOL_VERSIONS.include?(version)

      begin
        cleanup if respond_to?(:cleanup)
      rescue StandardError => e
        @logger.debug("Cleanup after protocol version mismatch failed: #{e.message}")
      end
      raise MCPClient::Errors::ConnectionError,
            "Server negotiated unsupported protocol version #{version.inspect} " \
            "(supported: #{MCPClient::LEGACY_PROTOCOL_VERSIONS.join(', ')}); disconnecting"
    end

    # The Implementation object sent as clientInfo: the host-provided info
    # when configured (client_info=), otherwise the gem's identity.
    # @return [Hash]
    def client_info_payload
      return @client_info if defined?(@client_info) && @client_info

      { 'name' => 'ruby-mcp-client', 'version' => MCPClient::VERSION }
    end

    # Declared client capabilities, derived from the server-request callbacks
    # the host actually registered before connecting. Per MCP 2025-11-25,
    # clients that support a feature MUST declare it during initialization,
    # and only negotiated capabilities may be used afterwards — so declaring
    # a hardcoded set independent of host support violates the lifecycle in
    # both directions.
    # @return [Hash] the capabilities object for the initialize request
    def client_capabilities
      capabilities = {}
      # On a modern server these features are served through the multi
      # round-trip pattern (InputRequiredResult), on a legacy one through
      # server-initiated requests; either way they are declared only when
      # the host registered a handler, since the server MUST NOT ask for
      # what the client did not declare.
      if registered_callback?(:@elicitation_request_callback)
        # Both defined elicitation modes are implemented (an empty object
        # would mean form-only per the spec's backwards-compatibility rule).
        capabilities['elicitation'] = { 'form' => {}, 'url' => {} }
      end
      if registered_callback?(:@roots_list_request_callback)
        # notifications/roots/list_changed was removed in 2026-07-28, so the
        # modern roots capability has no listChanged flag.
        capabilities['roots'] = modern? ? {} : { 'listChanged' => true }
      end
      if registered_callback?(:@sampling_request_callback)
        # SEP-1577: servers may only send tool-enabled sampling requests when
        # the client declares the sampling.tools sub-capability.
        capabilities['sampling'] = sampling_tools_supported? ? { 'tools' => {} } : {}
      end
      capabilities['extensions'] = declared_extensions.dup unless declared_extensions.empty?
      # NOTE: we intentionally do NOT declare a client `tasks` capability. That
      # capability marks the client as a RECEIVER of task-augmented
      # sampling/elicitation requests, which is not implemented here — this
      # client only acts as a task REQUESTOR for tools/call (see
      # Client#call_tool_as_task), which requires no client-side declaration.
      capabilities
    end

    # Opt this transport into declaring tool-use support for sampling
    # (ClientCapabilities.sampling.tools, MCP 2025-11-25 / SEP-1577). Call
    # before connect so the initialize request advertises it; it only takes
    # effect when a sampling request callback is also registered, since
    # sampling.tools is a sub-capability of sampling.
    # @return [void]
    def declare_sampling_tools
      @sampling_tools_supported = true
    end

    # @param ivar [Symbol] callback instance variable name
    # @return [Boolean] whether the callback is registered on this transport
    def registered_callback?(ivar)
      instance_variable_defined?(ivar) && !instance_variable_get(ivar).nil?
    end

    # @return [Boolean] whether the host opted into sampling tool use
    def sampling_tools_supported?
      instance_variable_defined?(:@sampling_tools_supported) && @sampling_tools_supported
    end

    # Result types defined by the core protocol (basic/index.mdx "ResultType").
    # Extensions add more (e.g. "task"); the accepted set widens with the
    # declared extensions this client implements (#accepted_result_types).
    CORE_RESULT_TYPES = %w[complete input_required].freeze

    # The result type each known result-type-adding extension introduces. A
    # client advertises one of these only when it implements it (see
    # #implemented_extension_result_types).
    RESULT_TYPE_EXTENSIONS = { 'io.modelcontextprotocol/tasks' => 'task' }.freeze

    # The only result type a handshake-era (legacy) server can validly send:
    # the others were introduced with the discriminator itself.
    LEGACY_RESULT_TYPES = %w[complete].freeze

    # The resultType of a result object. MCP 2026-07-28 makes the field
    # required, but "for backward compatibility with servers implementing
    # earlier protocol versions, which do not include resultType, clients
    # MUST treat an absent resultType as 'complete'". Non-object results
    # (lenient handling of older servers) are likewise complete.
    # @param result [Object] a JSON-RPC result
    # @return [Object] the resultType value, 'complete' when absent
    def self.result_type(result)
      return 'complete' unless result.is_a?(Hash)
      return result['resultType'] if result.key?('resultType')
      return result[:resultType] if result.key?(:resultType)

      'complete'
    end

    # Restore the wire spelling of a peer's own JSON object. JSON object keys
    # are always strings, but a host's response middleware may symbolize the
    # keys of everything it parses (Faraday's :json parser with
    # symbolize_names) — the middleware ::result_type already tolerates for
    # the resultType discriminator. Undoing it once, on the protocol object
    # about to be read, keeps every lookup below (and the params the input
    # handlers see) on the shape the protocol defines. Values are returned
    # untouched, so an opaque requestState is still echoed verbatim.
    # @param value [Object] a parsed JSON value
    # @return [Object] the same value with Symbol keys spelled as Strings
    def self.restore_wire_keys(value)
      case value
      when Hash
        value.to_h { |key, member| [key.is_a?(Symbol) ? key.to_s : key, restore_wire_keys(member)] }
      when Array
        value.map { |member| restore_wire_keys(member) }
      else
        value
      end
    end

    # Result types this transport accepts. Overridden (widened) by transports
    # that negotiated a result-type-adding extension.
    # @return [Array<String>]
    def accepted_result_types
      # input_required names the multi round-trip pattern, which exists only
      # in modern revisions: a handshake-era server answering with it is
      # malformed, and treating it as valid would let a wrapper flatten an
      # unfinished result into an empty successful one.
      return LEGACY_RESULT_TYPES unless modern?

      extra = implemented_extension_result_types.select { |id, _| declared_extensions.key?(id) }.values.flatten
      extra.empty? ? CORE_RESULT_TYPES : (CORE_RESULT_TYPES + extra).uniq.freeze
    end

    # The result types of the extensions this client implements, by
    # extension identifier: what a declared extension may widen the accepted
    # result types with. The core client implements none; a transport that
    # implements a result-type-adding extension (the tasks extension, say)
    # overrides this.
    # @return [Hash{String => Array<String>}]
    def implemented_extension_result_types
      {}
    end

    # Project a payload out of a result that has to be finished. This client
    # recognizes InputRequiredResult (resultType "input_required") but does
    # not drive multi round-trip requests yet, so an operation that would
    # extract a field from it — and so drop the server's inputRequests and
    # opaque requestState — surfaces it instead of presenting an unfinished
    # answer as an empty successful one. The whole result rides on the
    # error's `data`, so a host can still drive the round trip itself.
    #
    # Every field projector goes through this, not just resources/read: MRTR
    # permits an unfinished result on exactly tools/call, prompts/get and
    # resources/read, so one on a list or a completion is malformed anyway —
    # and reading it as a finished empty page would drop a whole page of a
    # paginated list, or a completion, without a word. tools/call and
    # prompts/get return the entire result and so never project.
    # An unfinished answer is the InputRequired condition and is reported as
    # such, the same way #reject_unfulfillable_input_required! reports one
    # that reaches the response parser; any other discriminator this client
    # cannot carry through is an invalid result.
    # @param result [Object] the JSON-RPC result
    # @param method [String] the request method, for the message
    # @return [Object] the result, when it is complete
    # @raise [MCPClient::Errors::InputRequiredError] when it is unfinished
    # @raise [MCPClient::Errors::InvalidResultError] when it is neither
    def require_complete_result!(result, method)
      type = MCPClient::JsonRpcCommon.result_type(result)
      return result if type == 'complete'

      message = "#{method} answered with resultType #{type.to_s[0, 64].inspect}, which this " \
                'client cannot carry through'
      raise MCPClient::Errors::InputRequiredError.new(message, data: result) if type == 'input_required'

      raise MCPClient::Errors::InvalidResultError.new("Invalid result: #{message}", data: result)
    end

    # Which request field mirrors into the Mcp-Name header (MCP 2026-07-28
    # Streamable HTTP "Standard Request Headers"; the tasks extension adds
    # taskId routing for its methods).
    NAME_HEADER_SOURCES = {
      'tools/call' => 'name',
      'prompts/get' => 'name',
      'resources/read' => 'uri',
      'tasks/get' => 'taskId',
      'tasks/update' => 'taskId',
      'tasks/cancel' => 'taskId',
      'tasks/result' => 'taskId'
    }.freeze

    # Encode a parameter value for an MCP request header (Mcp-Name,
    # Mcp-Param-*): strings as-is when header-safe, integers in decimal,
    # booleans lowercase; anything not safely representable — non-ASCII,
    # control characters, leading/trailing whitespace, an empty string, or a
    # value that looks like the sentinel — as `=?base64?<b64 of UTF-8>?=`.
    # @param value [String, Integer, true, false] the parameter value
    # @return [String] the header value
    def encode_header_value(value)
      MCPClient::HeaderParams.encode_header_value(value)
    end

    # The HTTP headers a modern (2026-07-28) request must carry: the protocol
    # version (matching the body's _meta), the method, and for named
    # requests the name/URI (MCP 2026-07-28 Streamable HTTP "Request
    # Metadata").
    # @param request [Hash] the JSON-RPC request (String keys)
    # @return [Hash{String => String}] header name => value
    def modern_request_headers(request)
      # The version the body was built with, not the transport's current one:
      # a concurrent request may have switched versions in between, and the
      # header MUST match the body's _meta.
      meta = request['params'].is_a?(Hash) ? request['params']['_meta'] : nil
      version = (meta.is_a?(Hash) && meta[META_PROTOCOL_VERSION]) || protocol_version
      headers = { 'MCP-Protocol-Version' => version, 'Mcp-Method' => request['method'].to_s }
      name = mcp_name_header_value(request)
      headers['Mcp-Name'] = name if name
      headers
    end

    # @param request [Hash] the JSON-RPC request
    # @return [String, nil] the encoded Mcp-Name value, or nil when the method has none
    def mcp_name_header_value(request)
      key = NAME_HEADER_SOURCES[request['method']]
      params = request['params']
      return nil unless key && params.is_a?(Hash)

      value = params.key?(key) ? params[key] : params[key.to_sym]
      return nil if value.nil?

      encode_header_value(value)
    end

    # Process JSON-RPC response
    # @param response [Hash] the parsed JSON-RPC response
    # @return [Object] the result field from the response
    # @raise [MCPClient::Errors::ServerError] if the response contains an error
    # @raise [MCPClient::Errors::InvalidResultError] if the result's resultType is unrecognized
    def process_jsonrpc_response(response, method: nil)
      error = envelope_member(response, 'error')
      raise MCPClient::Errors::ServerError.from_jsonrpc(error) if error

      result = envelope_member(response, 'result')
      validate_result_type!(result)
      record_server_info(result, method: method)
      result
    end

    # Client requests a server MAY answer with an InputRequiredResult (MCP
    # 2026-07-28 basic/patterns/mrtr "Supported Requests"); on any other
    # request such a result is invalid.
    MRTR_METHODS = %w[tools/call resources/read prompts/get].freeze

    # Ceiling on consecutive input_required answers to one logical request.
    # Servers MAY keep asking, but an unbounded loop is a hostile server.
    MAX_INPUT_ROUND_TRIPS = 10

    # Pause before retrying an InputRequiredResult that asked for nothing
    # (requestState only — e.g. a URL-mode elicitation still in progress out
    # of band). The client MAY retry immediately, but a tight loop would just
    # burn the round-trip budget; doubles up to the maximum.
    INPUT_RETRY_DELAY = 0.5
    INPUT_RETRY_MAX_DELAY = 5

    # Input request methods and the transport callback that fulfils each.
    INPUT_REQUEST_HANDLERS = {
      'elicitation/create' => :@elicitation_request_callback,
      'sampling/createMessage' => :@sampling_request_callback,
      'roots/list' => :@roots_list_request_callback
    }.freeze

    # Drive a request through the multi round-trip pattern (MCP 2026-07-28
    # basic/patterns/mrtr): while the server answers with an
    # InputRequiredResult, fulfil its inputRequests through the registered
    # handlers and retry the original request — as an independent request
    # with a new id — carrying inputResponses keyed like the requests and
    # the opaque requestState echoed verbatim (omitted when the server sent
    # none). A result without inputRequests asks for nothing this client can
    # fulfil, so it is retried after a growing pause (INPUT_RETRY_DELAY) that
    # the host steers through {#on_input_required_wait} and that never runs
    # past the request timeout: the continuation is handed back instead, on
    # an error {#resume_input_required} accepts.
    # @param method [String] the JSON-RPC method
    # @param params [Hash] the original params
    # @param timeout [Numeric, nil] per-request timeout, also bounding the waits
    # @yieldparam params [Hash] params for one attempt (original, or with inputResponses)
    # @yieldreturn [Object] the attempt's result
    # @return [Object] the final (complete) result
    # @raise [MCPClient::Errors::InvalidResultError] input_required on an unsupported method
    # @raise [MCPClient::Errors::InputRequiredError] when a round trip cannot be fulfilled, is
    #   cancelled or times out, or too many occur — carrying the continuation
    def resolve_input_round_trips(method, params, timeout = nil)
      result = yield(params)
      round_trips = 0
      delay = INPUT_RETRY_DELAY
      started = input_wait_clock
      deadline = input_wait_deadline(started, timeout)
      while MCPClient::JsonRpcCommon.result_type(result) == 'input_required'
        # Read on the wire spelling, whatever the transport's JSON middleware
        # did to the keys: a symbolized inputRequests/requestState would
        # otherwise be invisible here and the retry would go out with neither
        # the fulfilled answers nor the state the server MUST get back.
        result = MCPClient::JsonRpcCommon.restore_wire_keys(result)
        unless modern? && MRTR_METHODS.include?(method)
          raise MCPClient::Errors::InvalidResultError.new(
            "Invalid result: input_required is only valid for #{MRTR_METHODS.join(', ')} " \
            "on an MCP 2026-07-28 server, not #{method} (#{protocol_version})", data: result
          )
        end

        round_trips += 1
        if round_trips > MAX_INPUT_ROUND_TRIPS
          raise MCPClient::Errors::InputRequiredError.new(
            "Server kept requesting input for #{method} after #{MAX_INPUT_ROUND_TRIPS} round trips", data: result
          )
        end

        @logger.debug("#{method} requires input (round trip #{round_trips}); fulfilling and retrying")
        retry_params = retry_params_for(params, result)
        unless retry_params.key?('inputResponses')
          now = input_wait_clock
          wait = InputRequiredWait.new(rpc_method: method, round_trip: round_trips, delay: delay,
                                       request_state: result['requestState'], result: result,
                                       elapsed: now - started)
          delay = pace_input_round_trip(wait, deadline)
        end
        result = yield(retry_params)
      end
      @last_result_from_round_trip = round_trips.positive?
      result
    rescue MCPClient::Errors::InputRequiredError => e
      # Every failure of the round trip hands the continuation back: the
      # request it was driving, for #resume_input_required.
      e.request_method ||= method
      e.request_params ||= params
      e.transport ||= self
      raise
    end

    # Notifications the 2026-07-28 revision removed; never written to a
    # modern server (the roots capability has no listChanged there).
    REMOVED_MODERN_NOTIFICATIONS = %w[notifications/roots/list_changed notifications/initialized].freeze

    # @param method [String] a notification method
    # @return [Boolean] whether it must be dropped for a modern server
    def suppressed_modern_notification?(method)
      modern? && REMOVED_MODERN_NOTIFICATIONS.include?(method)
    end

    # Servers SHOULD identify themselves in every result's `_meta`
    # (`io.modelcontextprotocol/serverInfo`, MCP 2026-07-28); keep the latest
    # self-reported identity for display and logging.
    # @param result [Object] a JSON-RPC result
    # @param method [String, nil] the method the result answers, when known
    # @return [void]
    def record_server_info(result, method: nil)
      return unless result.is_a?(Hash)
      # A DiscoverResult's identity is recorded by apply_discover_result, once
      # the WHOLE result has validated: a refresh that fails must change
      # nothing, not even the identity it carried. Judged by the method the
      # result answers rather than by the result's own shape — an answer that
      # is missing supportedVersions is exactly the one apply_discover_result
      # rejects, and reading the shape recorded its identity first. The shape
      # still stands in for the method where the caller cannot name it.
      return if method == 'server/discover' || result.key?('supportedVersions')

      info = result['_meta'].is_a?(Hash) ? result['_meta'][META_SERVER_INFO] : nil
      @server_info = info if info.is_a?(Hash)
    end

    # "A resultType of any value unrecognized by the client MUST be
    # considered invalid" (basic/index.mdx). The value is peer-controlled, so
    # only its class or a short prefix reaches the exception message.
    # @param result [Object] a JSON-RPC result
    # @return [void]
    # @raise [MCPClient::Errors::InvalidResultError]
    def validate_result_type!(result)
      unless result.is_a?(Hash)
        # A modern result MUST be an object. Legacy servers occasionally
        # answered list requests with a bare array; keep tolerating that.
        return unless modern?

        raise MCPClient::Errors::InvalidResultError, "Invalid result: expected an object, got #{result.class}"
      end

      type = MCPClient::JsonRpcCommon.result_type(result)
      return if type.is_a?(String) && accepted_result_types.include?(type)

      shown = type.is_a?(String) ? type[0, 64].inspect : type.class.name
      # The refused result travels with the error: only a modern server names
      # a resultType at all, which is how the discovery probe tells a modern
      # server's unusable answer from a legacy endpoint's.
      raise MCPClient::Errors::InvalidResultError.new(
        "Invalid result: unrecognized resultType #{shown} (accepted: #{accepted_result_types.join(', ')})",
        data: result
      )
    end
  end
end
