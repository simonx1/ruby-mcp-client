# frozen_string_literal: true

module MCPClient
  # Shared retry/backoff logic for JSON-RPC transports
  module JsonRpcCommon
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
    # @yield block to execute
    # @return [Object] result of block
    # @raise original exception if max retries exceeded or the error is not retryable
    def with_retry
      attempts = 0
      begin
        yield
      rescue MCPClient::Errors::TransientServerError, MCPClient::Errors::TransportError, IOError,
             Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE => e
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

    # Ping the server to keep the connection alive
    # @return [Hash] the result of the ping request
    # @raise [MCPClient::Errors::ToolCallError] if ping times out or fails
    # @raise [MCPClient::Errors::TransportError] if there's a connection error
    # @raise [MCPClient::Errors::ServerError] if the server returns an error
    def ping
      rpc_request('ping')
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
      capabilities = {
        'elicitation' => {}, # MCP 2025-11-25: Support for server-initiated user interactions
        'roots' => { 'listChanged' => true }, # MCP 2025-11-25: Support for roots
        'sampling' => {} # MCP 2025-11-25: Support for server-initiated LLM sampling
        # NOTE: we intentionally do NOT declare a client `tasks` capability. That
        # capability marks the client as a RECEIVER of task-augmented
        # sampling/elicitation requests, which is not implemented here — this
        # client only acts as a task REQUESTOR for tools/call (see
        # Client#call_tool_as_task), which requires no client-side declaration.
      }

      {
        'protocolVersion' => MCPClient::PROTOCOL_VERSION,
        'capabilities' => capabilities,
        'clientInfo' => { 'name' => 'ruby-mcp-client', 'version' => MCPClient::VERSION }
      }
    end

    # Process JSON-RPC response
    # @param response [Hash] the parsed JSON-RPC response
    # @return [Object] the result field from the response
    # @raise [MCPClient::Errors::ServerError] if the response contains an error
    def process_jsonrpc_response(response)
      raise MCPClient::Errors::ServerError, response['error']['message'] if response['error']

      response['result']
    end
  end
end
