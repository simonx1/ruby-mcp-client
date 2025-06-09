# frozen_string_literal: true

module MCPClient
  # Base class for MCP servers - serves as the interface for different server implementations
  class ServerBase
    # @!attribute [r] name
    #   @return [String] the name of the server
    attr_reader :name

    # Initialize the server with a name
    # @param name [String, nil] server name
    def initialize(name: nil)
      @name = name
    end

    # Initialize a connection to the MCP server
    # @return [Boolean] true if connection successful
    def connect
      raise NotImplementedError, 'Subclasses must implement connect'
    end

    # List all prompts available from the MCP server
    # @return [Array<MCPClient::Prompt>] list of available prompts
    def list_prompts
      raise NotImplementedError, 'Subclasses must implement list_prompts'
    end

    # Get a prompt with the given parameters
    # @return [MCPClient::Prompt] prompt
    def get_prompt(prompt_name, parameters)
      raise NotImplementedError, 'Subclasses must implement get_prompt'
    end

    # List all tools available from the MCP server
    # @return [Array<MCPClient::Tool>] list of available tools
    def list_tools
      raise NotImplementedError, 'Subclasses must implement list_tools'
    end

    # Call a tool with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation
    def call_tool(tool_name, parameters)
      raise NotImplementedError, 'Subclasses must implement call_tool'
    end

    # Clean up the server connection
    def cleanup
      raise NotImplementedError, 'Subclasses must implement cleanup'
    end

    # Send a JSON-RPC request and return the result
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the request
    # @return [Object] result field from the JSON-RPC response
    # @raise [MCPClient::Errors::ServerError, MCPClient::Errors::TransportError, MCPClient::Errors::ToolCallError]
    def rpc_request(method, params = {})
      raise NotImplementedError, 'Subclasses must implement rpc_request'
    end

    # Send a JSON-RPC notification (no response expected)
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the notification
    # @return [void]
    def rpc_notify(method, params = {})
      raise NotImplementedError, 'Subclasses must implement rpc_notify'
    end

    # Stream a tool call result (default implementation returns single-value stream)
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Enumerator] stream of results
    def call_tool_streaming(tool_name, parameters)
      Enumerator.new do |yielder|
        yielder << call_tool(tool_name, parameters)
      end
    end

    # Ping the MCP server to check connectivity (zero-parameter heartbeat call)
    # @return [Object] result from the ping request
    def ping
      rpc_request('ping')
    end

    # Register a callback to receive JSON-RPC notifications
    # @yield [method, params] invoked when a notification is received
    # @return [void]
    def on_notification(&block)
      @notification_callback = block
    end
  end
end
