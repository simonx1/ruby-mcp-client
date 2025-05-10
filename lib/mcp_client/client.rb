# frozen_string_literal: true

require 'logger'

module MCPClient
  # MCP Client for integrating with the Model Context Protocol
  # This is the main entry point for using MCP tools
  class Client
    # @!attribute [r] servers
    #   @return [Array<MCPClient::ServerBase>] list of servers
    # @!attribute [r] tool_cache
    #   @return [Hash<String, MCPClient::Tool>] cache of tools by name
    # @!attribute [r] logger
    #   @return [Logger] logger for client operations
    attr_reader :servers, :tool_cache, :logger

    # Initialize a new MCPClient::Client
    # @param mcp_server_configs [Array<Hash>] configurations for MCP servers
    # @param logger [Logger, nil] optional logger, defaults to STDOUT
    def initialize(mcp_server_configs: [], logger: nil)
      @logger = logger || Logger.new($stdout, level: Logger::WARN)
      @logger.progname = self.class.name
      @logger.formatter = proc { |severity, _datetime, progname, msg| "#{severity} [#{progname}] #{msg}\n" }
      @servers = mcp_server_configs.map do |config|
        @logger.debug("Creating server with config: #{config.inspect}")
        MCPClient::ServerFactory.create(config)
      end
      @tool_cache = {}
      # JSON-RPC notification listeners
      @notification_listeners = []
      # Register default and user-defined notification handlers on each server
      @servers.each do |server|
        server.on_notification do |method, params|
          # Default notification processing (e.g., cache invalidation, logging)
          process_notification(server, method, params)
          # Invoke user-defined listeners
          @notification_listeners.each { |cb| cb.call(server, method, params) }
        end
      end
    end

    # Lists all available tools from all connected MCP servers
    # @param cache [Boolean] whether to use cached tools or fetch fresh
    # @return [Array<MCPClient::Tool>] list of available tools
    def list_tools(cache: true)
      return @tool_cache.values if cache && !@tool_cache.empty?

      tools = []
      servers.each do |server|
        server.list_tools.each do |tool|
          @tool_cache[tool.name] = tool
          tools << tool
        end
      end

      tools
    end

    # Calls a specific tool by name with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation
    def call_tool(tool_name, parameters)
      tools = list_tools
      tool = tools.find { |t| t.name == tool_name }

      raise MCPClient::Errors::ToolNotFound, "Tool '#{tool_name}' not found" unless tool

      # Validate parameters against tool schema
      validate_params!(tool, parameters)

      # Find the server that owns this tool
      server = find_server_for_tool(tool)
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless server

      server.call_tool(tool_name, parameters)
    end

    # Convert MCP tools to OpenAI function specifications
    # @param tool_names [Array<String>, nil] optional list of tool names to include, nil means all tools
    # @return [Array<Hash>] OpenAI function specifications
    def to_openai_tools(tool_names: nil)
      tools = list_tools
      tools = tools.select { |t| tool_names.include?(t.name) } if tool_names
      tools.map(&:to_openai_tool)
    end

    # Convert MCP tools to Anthropic Claude tool specifications
    # @param tool_names [Array<String>, nil] optional list of tool names to include, nil means all tools
    # @return [Array<Hash>] Anthropic Claude tool specifications
    def to_anthropic_tools(tool_names: nil)
      tools = list_tools
      tools = tools.select { |t| tool_names.include?(t.name) } if tool_names
      tools.map(&:to_anthropic_tool)
    end

    def to_google_tools(tool_names: nil)
      tools = list_tools
      tools = tools.select { |t| tool_names.include?(t.name) } if tool_names
      tools.map(&:to_google_tool)
    end

    # Clean up all server connections
    def cleanup
      servers.each(&:cleanup)
    end

    # Clear the cached tools so that next list_tools will fetch fresh data
    # @return [void]
    def clear_cache
      @tool_cache.clear
    end

    # Register a callback for JSON-RPC notifications from servers
    # @yield [server, method, params]
    # @return [void]
    def on_notification(&block)
      @notification_listeners << block
    end

    # Find all tools whose name matches the given pattern (String or Regexp)
    # @param pattern [String, Regexp] pattern to match tool names
    # @return [Array<MCPClient::Tool>] matching tools
    def find_tools(pattern)
      rx = pattern.is_a?(Regexp) ? pattern : /#{Regexp.escape(pattern)}/
      list_tools.select { |t| t.name.match(rx) }
    end

    # Find the first tool whose name matches the given pattern
    # @param pattern [String, Regexp] pattern to match tool names
    # @return [MCPClient::Tool, nil]
    def find_tool(pattern)
      find_tools(pattern).first
    end

    # Call multiple tools in batch
    # @param calls [Array<Hash>] array of calls in the form { name: tool_name, parameters: {...} }
    # @return [Array<Object>] array of results for each tool invocation
    def call_tools(calls)
      calls.map do |call|
        name = call[:name] || call['name']
        params = call[:parameters] || call['parameters'] || {}
        call_tool(name, params)
      end
    end

    # Stream call of a specific tool by name with the given parameters.
    # Returns an Enumerator yielding streaming updates if supported.
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Enumerator] streaming enumerator or single-value enumerator
    def call_tool_streaming(tool_name, parameters)
      tools = list_tools
      tool = tools.find { |t| t.name == tool_name }
      raise MCPClient::Errors::ToolNotFound, "Tool '#{tool_name}' not found" unless tool

      # Validate parameters against tool schema
      validate_params!(tool, parameters)
      # Find the server that owns this tool
      server = find_server_for_tool(tool)
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless server

      if server.respond_to?(:call_tool_streaming)
        server.call_tool_streaming(tool_name, parameters)
      else
        Enumerator.new do |yielder|
          yielder << server.call_tool(tool_name, parameters)
        end
      end
    end

    # Ping the MCP server to check connectivity (zero-parameter heartbeat call)
    # @param server_index [Integer, nil] optional index of a specific server to ping, nil for first available
    # @return [Object] result from the ping request
    # @raise [MCPClient::Errors::ServerNotFound] if no server is available
    def ping(server_index: nil)
      if server_index.nil?
        # Ping first available server
        raise MCPClient::Errors::ServerNotFound, 'No server available for ping' if @servers.empty?

        @servers.first.ping
      else
        # Ping specified server
        if server_index >= @servers.length
          raise MCPClient::Errors::ServerNotFound,
                "Server at index #{server_index} not found"
        end

        @servers[server_index].ping
      end
    end

    # Send a raw JSON-RPC request to a server
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the request
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [Object] result from the JSON-RPC response
    def send_rpc(method, params: {}, server: nil)
      srv = select_server(server)
      srv.rpc_request(method, params)
    end

    # Send a raw JSON-RPC notification to a server (no response expected)
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the notification
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [void]
    def send_notification(method, params: {}, server: nil)
      srv = select_server(server)
      srv.rpc_notify(method, params)
    end

    private

    # Process incoming JSON-RPC notifications with default handlers
    # @param server [MCPClient::ServerBase] the server that emitted the notification
    # @param method [String] JSON-RPC notification method
    # @param params [Hash] parameters for the notification
    # @return [void]
    def process_notification(server, method, params)
      case method
      when 'notifications/tools/list_changed'
        logger.warn("[#{server.class}] Tool list has changed, clearing tool cache")
        clear_cache
      when 'notifications/resources/updated'
        logger.warn("[#{server.class}] Resource #{params['uri']} updated")
      when 'notifications/prompts/list_changed'
        logger.warn("[#{server.class}] Prompt list has changed")
      when 'notifications/resources/list_changed'
        logger.warn("[#{server.class}] Resource list has changed")
      end
    end

    # Select a server based on index, type, or instance
    # @param server_arg [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [MCPClient::ServerBase]
    def select_server(server_arg)
      case server_arg
      when nil
        raise MCPClient::Errors::ServerNotFound, 'No server available' if @servers.empty?

        @servers.first
      when Integer
        @servers.fetch(server_arg) do
          raise MCPClient::Errors::ServerNotFound, "Server at index #{server_arg} not found"
        end
      when String, Symbol
        key = server_arg.to_s.downcase
        srv = @servers.find { |s| s.class.name.split('::').last.downcase.end_with?(key) }
        raise MCPClient::Errors::ServerNotFound, "Server of type #{server_arg} not found" unless srv

        srv
      else
        raise ArgumentError, "Invalid server argument: #{server_arg.inspect}" unless @servers.include?(server_arg)

        server_arg

      end
    end

    # Validate parameters against tool JSON schema (checks required properties)
    # @param tool [MCPClient::Tool] tool definition with schema
    # @param parameters [Hash] parameters to validate
    # @raise [MCPClient::Errors::ValidationError] when required params are missing
    def validate_params!(tool, parameters)
      schema = tool.schema
      return unless schema.is_a?(Hash)

      required = schema['required'] || schema[:required]
      return unless required.is_a?(Array)

      missing = required.map(&:to_s) - parameters.keys.map(&:to_s)
      return unless missing.any?

      raise MCPClient::Errors::ValidationError, "Missing required parameters: #{missing.join(', ')}"
    end

    def find_server_for_tool(tool)
      servers.find do |server|
        server.list_tools.any? { |t| t.name == tool.name }
      end
    end
  end
end
