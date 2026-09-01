# frozen_string_literal: true

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
        'params' => params
      }
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

    # The resultType of a result object. MCP 2026-07-28 makes the field
    # required, but "for backward compatibility with servers implementing
    # earlier protocol versions, which do not include resultType, clients
    # MUST treat an absent resultType as 'complete'". Non-object results
    # (lenient handling of older servers) are likewise complete.
    # @param result [Object] a JSON-RPC result
    # @return [Object] the resultType value, 'complete' when absent
    def self.result_type(result)
      return 'complete' unless result.is_a?(Hash)

      type = result.key?('resultType') ? result['resultType'] : result[:resultType]
      type.nil? ? 'complete' : type
    end

    # Result types this transport accepts. Overridden (widened) by transports
    # that negotiated a result-type-adding extension.
    # @return [Array<String>]
    def accepted_result_types
      CORE_RESULT_TYPES
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
      result
    end

    # "A resultType of any value unrecognized by the client MUST be
    # considered invalid" (basic/index.mdx). The value is peer-controlled, so
    # only its class or a short prefix reaches the exception message.
    # @param result [Object] a JSON-RPC result
    # @return [void]
    # @raise [MCPClient::Errors::InvalidResultError]
    def validate_result_type!(result)
      type = MCPClient::JsonRpcCommon.result_type(result)
      return if accepted_result_types.include?(type)

      shown = type.is_a?(String) ? type[0, 64].inspect : type.class.name
      raise MCPClient::Errors::InvalidResultError,
            "Invalid result: unrecognized resultType #{shown} (accepted: #{accepted_result_types.join(', ')})"
    end
  end
end
