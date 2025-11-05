# frozen_string_literal: true

module MCPClient
  # Shared retry/backoff logic for JSON-RPC transports
  module JsonRpcCommon
    # Execute the block with retry/backoff for transient errors
    # @yield block to execute
    # @return [Object] result of block
    # @raise original exception if max retries exceeded
    def with_retry
      attempts = 0
      begin
        yield
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError, IOError, Errno::ETIMEDOUT,
             Errno::ECONNRESET => e
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
        'capabilities' => {
          'elicitation' => {} # MCP 2025-06-18: Support for server-initiated user interactions
        },
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
