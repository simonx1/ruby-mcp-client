# frozen_string_literal: true

require 'json'
require 'zlib'
require 'stringio'

module MCPClient
  # Shared retry/backoff logic for JSON-RPC transports
  module JsonRpcCommon
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
    # @param body [String, nil] the response/request body
    # @return [String]
    def describe_body_size(body)
      return 'empty body' if body.nil? || body.empty?

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
    # mandatory prefix: dotted labels, a slash, then a name.
    EXTENSION_ID_PATTERN = %r{\A(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?/
                              [A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z}x

    # @return [Symbol, nil] :modern, :legacy, or nil before the era is known
    def protocol_era
      return nil if protocol_version.nil?

      modern? ? :modern : :legacy
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

      @declared_extensions ||= {}
      @declared_extensions[identifier] = settings || {}
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
      defaults = host_request_meta
      return params if defaults.empty? && !modern?

      params = params.is_a?(Hash) ? params.dup : {}
      supplied = params.delete('_meta')
      symbol_meta = params.delete(:_meta)
      supplied = symbol_meta if supplied.nil?
      supplied = supplied.is_a?(Hash) ? supplied.transform_keys(&:to_s) : {}

      meta = defaults.merge(supplied)
      if modern?
        meta[META_LOG_LEVEL] = @log_level if defined?(@log_level) && @log_level && !meta.key?(META_LOG_LEVEL)
        meta.merge!(required_request_meta)
      end
      params['_meta'] = meta
      params
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

      versions = result['supportedVersions']
      unless versions.is_a?(Array) && versions.all?(String)
        raise MCPClient::Errors::ConnectionError, 'server/discover result has no supportedVersions list'
      end

      version = select_protocol_version(versions)
      unless version
        raise MCPClient::Errors::ConnectionError,
              "Server supports protocol versions #{versions.join(', ')}, none of which this client speaks " \
              "(modern versions supported: #{MCPClient::MODERN_PROTOCOL_VERSIONS.join(', ')})"
      end

      @protocol_version = version
      @supported_versions = versions
      @last_discover_result = result
      @capabilities = result['capabilities'].is_a?(Hash) ? result['capabilities'] : {}
      @instructions = result['instructions']
      info = result.dig('_meta', META_SERVER_INFO)
      @server_info = info if info.is_a?(Hash)
      result
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
        'params' => params
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
      # MCP 2026-07-28 delivers roots/sampling/elicitation through the multi
      # round-trip pattern (InputRequiredResult), not server-initiated
      # requests. Until that pattern is implemented, modern requests declare
      # none of these: a server MUST NOT ask for what the client did not
      # declare, so an unfulfillable input request is never provoked.
      unless modern?
        if registered_callback?(:@elicitation_request_callback)
          # Both defined elicitation modes are implemented (an empty object
          # would mean form-only per the spec's backwards-compatibility rule).
          capabilities['elicitation'] = { 'form' => {}, 'url' => {} }
        end
        capabilities['roots'] = { 'listChanged' => true } if registered_callback?(:@roots_list_request_callback)
        if registered_callback?(:@sampling_request_callback)
          # SEP-1577: servers may only send tool-enabled sampling requests when
          # the client declares the sampling.tools sub-capability.
          capabilities['sampling'] = sampling_tools_supported? ? { 'tools' => {} } : {}
        end
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
    # Extensions add more (e.g. "task"); transports widen the accepted set
    # via #accepted_result_types once such an extension is negotiated.
    CORE_RESULT_TYPES = %w[complete input_required].freeze

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

    # Result types this transport accepts. Overridden (widened) by transports
    # that negotiated a result-type-adding extension.
    # @return [Array<String>]
    def accepted_result_types
      # input_required names the multi round-trip pattern, which exists only
      # in modern revisions: a handshake-era server answering with it is
      # malformed, and treating it as valid would let a wrapper flatten an
      # unfinished result into an empty successful one.
      modern? ? CORE_RESULT_TYPES : LEGACY_RESULT_TYPES
    end

    # Project a payload out of a result that has to be finished. This client
    # recognizes InputRequiredResult (resultType "input_required") but does
    # not drive multi round-trip requests yet, so an operation that would
    # extract a field from it — and so drop the server's inputRequests and
    # opaque requestState — surfaces it instead of presenting an unfinished
    # answer as an empty successful one. The whole result rides on the
    # error's `data`, so a host can still drive the round trip itself.
    # @param result [Object] the JSON-RPC result
    # @param method [String] the request method, for the message
    # @return [Object] the result, when it is complete
    # @raise [MCPClient::Errors::InvalidResultError] when it is not
    def require_complete_result!(result, method)
      type = MCPClient::JsonRpcCommon.result_type(result)
      return result if type == 'complete'

      raise MCPClient::Errors::InvalidResultError.new(
        "Invalid result: #{method} answered with resultType #{type.to_s[0, 64].inspect}, which this " \
        'client cannot carry through (multi round-trip requests are not implemented)', data: result
      )
    end

    # Build the error for a 4xx response: the typed JSON-RPC error when the
    # body is a JSON-RPC error response (with the HTTP status prefixed to the
    # peer's message), otherwise a plain ServerError with the fallback text.
    # @param response [Faraday::Response] the 4xx response
    # @param fallback [String] message when the body carries no JSON-RPC error
    # @return [MCPClient::Errors::ServerError]
    def jsonrpc_error_from_http_response(response, fallback)
      status = response.status
      error = jsonrpc_error_in_body(response)
      return MCPClient::Errors::ServerError.new(fallback).tap { |e| e.http_status = status } unless error

      typed = MCPClient::Errors::ServerError.from_jsonrpc(error)
      typed.class.new("#{fallback}: #{typed.message}", code: typed.code, data: typed.data)
           .tap { |e| e.http_status = status }
    end

    # Ceiling on the size of an HTTP error body inspected for a JSON-RPC
    # error. A protocol error response is a few hundred bytes; the body is
    # peer-controlled, so anything larger is not parsed at all rather than
    # handed to JSON.parse.
    MAX_ERROR_BODY_BYTES = 64 * 1024

    # Extract a JSON-RPC error object from an HTTP error body, if there is one.
    # Only a JSON-RPC 2.0 error response is recognized; anything else is
    # ignored.
    # @param response [Faraday::Response] the HTTP response
    # @return [Hash, nil] the JSON-RPC `error` member, or nil
    def jsonrpc_error_in_body(response)
      return nil unless response.respond_to?(:body)

      data = decoded_error_body(response)
      # Only a JSON-RPC 2.0 error response counts; an arbitrary JSON body
      # with an "error" member is not a protocol error.
      return nil unless data.is_a?(Hash) && (data['jsonrpc'] || data[:jsonrpc]) == '2.0'

      error = data['error'] || data[:error]
      error.is_a?(Hash) ? error : nil
    end

    # The error body as a decoded object.
    #
    # A host may configure the connection (faraday_config) with response
    # middleware — `conn.response :json` — that decodes the body before it
    # reaches this transport, on the exception path (`raise_error`) as well
    # as the response path. That already-parsed body carries the same
    # protocol error, so it is accepted as-is; only a raw String body is
    # size-bounded, gunzipped and parsed here (the middleware has already
    # spent the memory for the ones it decoded).
    # @param response [Faraday::Response] the HTTP response
    # @return [Object, nil] the decoded body, or nil when it cannot be read
    def decoded_error_body(response)
      body = response.body
      return body if body.is_a?(Hash)
      return nil unless body.is_a?(String) && !body.empty?
      return nil if oversized_error_body?(body)

      headers = response.respond_to?(:headers) ? response.headers || {} : {}
      encoding = headers['content-encoding'] || headers['Content-Encoding'] || ''
      body = gunzip_bounded(body) if encoding.include?('gzip')
      return nil if body.nil?

      JSON.parse(body)
    rescue JSON::ParserError, Zlib::Error => e
      @logger.debug("HTTP error body is not a JSON-RPC error: #{e.class}")
      nil
    end

    # @param body [String] an HTTP error body
    # @return [Boolean] whether it exceeds the inspection ceiling (logged)
    def oversized_error_body?(body)
      return false if body.bytesize <= MAX_ERROR_BODY_BYTES

      @logger.debug("Ignoring HTTP error body of #{body.bytesize} bytes (over #{MAX_ERROR_BODY_BYTES})")
      true
    end

    # Decompress a gzip error body, giving up once the expansion passes the
    # inspection ceiling (a compressed 4xx body is peer-controlled too).
    # @param body [String] gzip data
    # @return [String, nil] the decompressed body, or nil when too large
    def gunzip_bounded(body)
      reader = Zlib::GzipReader.new(StringIO.new(body))
      expanded = reader.read(MAX_ERROR_BODY_BYTES + 1) || ''
      return expanded if expanded.bytesize <= MAX_ERROR_BODY_BYTES

      @logger.debug("Ignoring gzip HTTP error body expanding past #{MAX_ERROR_BODY_BYTES} bytes")
      nil
    ensure
      reader&.close
    end

    # Process JSON-RPC response
    # @param response [Hash] the parsed JSON-RPC response
    # @return [Object] the result field from the response
    # @raise [MCPClient::Errors::ServerError] if the response contains an error
    # @raise [MCPClient::Errors::InvalidResultError] if the result's resultType is unrecognized
    def process_jsonrpc_response(response)
      raise MCPClient::Errors::ServerError.from_jsonrpc(response['error']) if response['error']

      result = response['result']
      validate_result_type!(result)
      record_server_info(result)
      reject_unfulfillable_input_required!(result)
      result
    end

    # Notifications the 2026-07-28 revision removed; never written to a
    # modern server (the roots capability has no listChanged there).
    REMOVED_MODERN_NOTIFICATIONS = %w[notifications/roots/list_changed notifications/initialized].freeze

    # @param method [String] a notification method
    # @return [Boolean] whether it must be dropped for a modern server
    def suppressed_modern_notification?(method)
      modern? && REMOVED_MODERN_NOTIFICATIONS.include?(method)
    end

    # An InputRequiredResult asks the client to fulfil server requests and
    # retry. This client declares no capability a modern server could use
    # for that yet, so such a result cannot be honoured and must not be
    # mistaken for the operation's result.
    # @param result [Object] a JSON-RPC result
    # @return [void]
    # @raise [MCPClient::Errors::InputRequiredError]
    def reject_unfulfillable_input_required!(result)
      return unless MCPClient::JsonRpcCommon.result_type(result) == 'input_required'

      raise MCPClient::Errors::InputRequiredError.new(
        'Server returned an input_required result (multi round-trip request) that this client cannot fulfil',
        data: result
      )
    end

    # Servers SHOULD identify themselves in every result's `_meta`
    # (`io.modelcontextprotocol/serverInfo`, MCP 2026-07-28); keep the latest
    # self-reported identity for display and logging.
    # @param result [Object] a JSON-RPC result
    # @return [void]
    def record_server_info(result)
      return unless result.is_a?(Hash)

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
      raise MCPClient::Errors::InvalidResultError,
            "Invalid result: unrecognized resultType #{shown} (accepted: #{accepted_result_types.join(', ')})"
    end
  end
end
