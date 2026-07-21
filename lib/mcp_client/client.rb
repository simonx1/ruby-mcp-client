# frozen_string_literal: true

require 'logger'

module MCPClient
  # MCP Client for integrating with the Model Context Protocol
  # This is the main entry point for using MCP tools
  class Client
    # Elicitation modes implemented by this client (MCP 2025-11-25).
    # Requests with a mode outside this set are rejected with -32602.
    SUPPORTED_ELICITATION_MODES = %w[form url].freeze

    # @!attribute [r] servers
    #   @return [Array<MCPClient::ServerBase>] list of servers
    # @!attribute [r] tool_cache
    #   @return [Hash<String, MCPClient::Tool>] cache of tools by composite key (server_id:name)
    # @!attribute [r] prompt_cache
    #   @return [Hash<String, MCPClient::Prompt>] cache of prompts by composite key (server_id:name)
    # @!attribute [r] resource_cache
    #   @return [Hash<String, MCPClient::Resource>] cache of resources by composite key (server_id:uri)
    # @!attribute [r] logger
    #   @return [Logger] logger for client operations
    # @!attribute [r] roots
    #   @return [Array<MCPClient::Root>] list of MCP roots (MCP 2025-06-18)
    attr_reader :servers, :tool_cache, :prompt_cache, :resource_cache, :logger, :roots

    # Initialize a new MCPClient::Client
    # @param mcp_server_configs [Array<Hash>] configurations for MCP servers
    # @param logger [Logger, nil] optional logger, defaults to STDOUT
    # @param elicitation_handler [Proc, nil] optional handler for elicitation requests (MCP 2025-06-18)
    # @param roots [Array<MCPClient::Root, Hash>, nil] optional list of roots (MCP 2025-06-18)
    # @param sampling_handler [Proc, nil] optional handler for sampling requests (MCP 2025-11-25)
    def initialize(mcp_server_configs: [], logger: nil, elicitation_handler: nil, roots: nil, sampling_handler: nil)
      # Preserve a caller-supplied logger's formatter (only tag progname), and
      # install the default formatter solely on a logger we create ourselves.
      # Overwriting the formatter of an application's logger would silently
      # reformat every log line it emits elsewhere.
      if logger
        @logger = logger
        @logger.progname = self.class.name
      else
        @logger = Logger.new($stdout, level: Logger::WARN)
        @logger.progname = self.class.name
        @logger.formatter = proc { |severity, _datetime, progname, msg| "#{severity} [#{progname}] #{msg}\n" }
      end
      @servers = mcp_server_configs.map do |config|
        @logger.debug("Creating server with config: #{config.inspect}")
        MCPClient::ServerFactory.create(config, logger: @logger)
      end
      @tool_cache = {}
      @prompt_cache = {}
      @resource_cache = {}
      # JSON-RPC notification listeners
      @notification_listeners = []
      # Elicitation handler (MCP 2025-06-18)
      @elicitation_handler = elicitation_handler
      # Sampling handler (MCP 2025-11-25)
      @sampling_handler = sampling_handler
      # Roots (MCP 2025-06-18)
      @roots = normalize_roots(roots)
      # Register default and user-defined notification handlers on each server
      @servers.each do |server|
        server.on_notification do |method, params|
          # Default notification processing (e.g., cache invalidation, logging)
          process_notification(server, method, params)
          # Invoke user-defined listeners
          @notification_listeners.each { |cb| cb.call(server, method, params) }
        end
        # Register elicitation handler on each server
        if server.respond_to?(:on_elicitation_request)
          server.on_elicitation_request(&method(:handle_elicitation_request))
        end
        # Register roots list handler on each server (MCP 2025-06-18)
        server.on_roots_list_request(&method(:handle_roots_list_request)) if server.respond_to?(:on_roots_list_request)
        # Register sampling handler on each server (MCP 2025-11-25)
        server.on_sampling_request(&method(:handle_sampling_request)) if server.respond_to?(:on_sampling_request)
      end
    end

    # Lists all available prompts from all connected MCP servers
    # @param cache [Boolean] whether to use cached prompts or fetch fresh
    # @return [Array<MCPClient::Prompt>] list of available prompts
    # @raise [MCPClient::Errors::ConnectionError] on authorization failures
    # @raise [MCPClient::Errors::PromptGetError] if no prompts could be retrieved from any server
    def list_prompts(cache: true)
      return @prompt_cache.values if cache && !@prompt_cache.empty?

      prompts = []
      connection_errors = []

      servers.each do |server|
        server.list_prompts.each do |prompt|
          cache_key = cache_key_for(server, prompt.name)
          @prompt_cache[cache_key] = prompt
          prompts << prompt
        end
      rescue MCPClient::Errors::ConnectionError => e
        # Fast-fail on authorization errors for better user experience
        # If this is the first server or we haven't collected any prompts yet,
        # raise the auth error directly to avoid cascading error messages
        raise e if e.message.include?('Authorization failed') && prompts.empty?

        # Store the error and try other servers
        connection_errors << e
        @logger.error("Server error: #{e.message}")
      end

      prompts
    end

    # Gets a specific prompt by name with the given parameters
    # @param prompt_name [String] the name of the prompt to get
    # @param parameters [Hash] the parameters to pass to the prompt
    # @param server [String, Symbol, Integer, MCPClient::ServerBase, nil] optional server to use
    # @return [Object] the final prompt
    def get_prompt(prompt_name, parameters, server: nil)
      prompts = list_prompts

      if server
        # Use the specified server
        srv = select_server(server)
        # Find the prompt on this specific server
        prompt = prompts.find { |t| t.name == prompt_name && t.server == srv }
        unless prompt
          raise MCPClient::Errors::PromptNotFound,
                "Prompt '#{prompt_name}' not found on server '#{srv.name || srv.class.name}'"
        end
      else
        # Find the prompt across all servers
        matching_prompts = prompts.select { |t| t.name == prompt_name }

        if matching_prompts.empty?
          raise MCPClient::Errors::PromptNotFound, "Prompt '#{prompt_name}' not found"
        elsif matching_prompts.size > 1
          # If multiple matches, disambiguate with server names
          server_names = matching_prompts.map { |t| t.server&.name || 'unnamed' }
          raise MCPClient::Errors::AmbiguousPromptName,
                "Multiple prompts named '#{prompt_name}' found across servers (#{server_names.join(', ')}). " \
                "Please specify a server using the 'server' parameter."
        end

        prompt = matching_prompts.first
      end

      # Use the prompt's associated server
      server = prompt.server
      raise MCPClient::Errors::ServerNotFound, "No server found for prompt '#{prompt_name}'" unless server

      begin
        server.get_prompt(prompt_name, parameters)
      rescue MCPClient::Errors::ConnectionError => e
        # Add server identity information to the error for better context
        server_id = server.name ? "#{server.class}[#{server.name}]" : server.class.name
        raise MCPClient::Errors::PromptGetError,
              "Error getting prompt '#{prompt_name}': #{e.message} (Server: #{server_id})"
      end
    end

    # Lists all available resources from all connected MCP servers
    # @param cache [Boolean] whether to use cached resources or fetch fresh
    # @param cursor [String, nil] optional cursor for pagination (only works with single server)
    # @return [Hash] result containing 'resources' array and optional 'nextCursor'
    # @raise [MCPClient::Errors::ConnectionError] on authorization failures
    # @raise [MCPClient::Errors::ResourceReadError] if no resources could be retrieved from any server
    def list_resources(cache: true, cursor: nil)
      # If cursor is provided, we can only query one server (the one that provided the cursor)
      # This is a limitation of aggregating multiple servers
      if cursor
        # For now, just use the first server when cursor is provided
        # In a real implementation, you'd need to track which server the cursor came from
        return servers.first.list_resources(cursor: cursor) if servers.any?

        return { 'resources' => [], 'nextCursor' => nil }
      end

      # Use cache if available and no cursor
      return { 'resources' => @resource_cache.values, 'nextCursor' => nil } if cache && !@resource_cache.empty?

      resources = []
      connection_errors = []

      servers.each do |server|
        result = server.list_resources
        resource_list = result['resources'] || []

        resource_list.each do |resource|
          cache_key = cache_key_for(server, resource.uri)
          @resource_cache[cache_key] = resource
          resources << resource
        end
      rescue MCPClient::Errors::ConnectionError => e
        # Fast-fail on authorization errors for better user experience
        # If this is the first server or we haven't collected any resources yet,
        # raise the auth error directly to avoid cascading error messages
        raise e if e.message.include?('Authorization failed') && resources.empty?

        # Store the error and try other servers
        connection_errors << e
        @logger.error("Server error: #{e.message}")
      end

      # Return hash format consistent with server methods
      { 'resources' => resources, 'nextCursor' => nil }
    end

    # Reads a specific resource by URI
    # @param uri [String] the URI of the resource to read
    # @param server [String, Symbol, Integer, MCPClient::ServerBase, nil] optional server to use
    # @return [Object] the resource contents
    def read_resource(uri, server: nil)
      result = list_resources
      resources = result['resources'] || []

      resource = if server
                   find_resource_on_server(uri, resources, server)
                 else
                   find_resource_across_servers(uri, resources)
                 end

      execute_resource_read(resource, uri)
    end

    # Lists all available tools from all connected MCP servers
    # @param cache [Boolean] whether to use cached tools or fetch fresh
    # @return [Array<MCPClient::Tool>] list of available tools
    # @raise [MCPClient::Errors::ConnectionError] on authorization failures
    # @raise [MCPClient::Errors::ToolCallError] if no tools could be retrieved from any server
    def list_tools(cache: true)
      return @tool_cache.values if cache && !@tool_cache.empty?

      tools = []
      connection_errors = []

      servers.each do |server|
        server.list_tools.each do |tool|
          cache_key = cache_key_for(server, tool.name)
          @tool_cache[cache_key] = tool
          tools << tool
        end
      rescue MCPClient::Errors::ConnectionError => e
        # Fast-fail on authorization errors for better user experience
        # If this is the first server or we haven't collected any tools yet,
        # raise the auth error directly to avoid cascading error messages
        raise e if e.message.include?('Authorization failed') && tools.empty?

        # Store the error and try other servers
        connection_errors << e
        @logger.error("Server error: #{e.message}")
      end

      # If we didn't get any tools from any server but have servers configured, report failure
      if tools.empty? && !servers.empty?
        raise connection_errors.first if connection_errors.any?

        @logger.warn('No tools found from any server.')
      end

      tools
    end

    # Calls a specific tool by name with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @param server [String, Symbol, Integer, MCPClient::ServerBase, nil] optional server to use
    # @return [Object] the result of the tool invocation
    def call_tool(tool_name, parameters, server: nil)
      tools = list_tools

      if server
        # Use the specified server
        srv = select_server(server)
        # Find the tool on this specific server
        tool = tools.find { |t| t.name == tool_name && t.server == srv }
        unless tool
          raise MCPClient::Errors::ToolNotFound,
                "Tool '#{tool_name}' not found on server '#{srv.name || srv.class.name}'"
        end
      else
        # Find the tool across all servers
        matching_tools = tools.select { |t| t.name == tool_name }

        if matching_tools.empty?
          raise MCPClient::Errors::ToolNotFound, "Tool '#{tool_name}' not found"
        elsif matching_tools.size > 1
          # If multiple matches, disambiguate with server names
          server_names = matching_tools.map { |t| t.server&.name || 'unnamed' }
          raise MCPClient::Errors::AmbiguousToolName,
                "Multiple tools named '#{tool_name}' found across servers (#{server_names.join(', ')}). " \
                "Please specify a server using the 'server' parameter."
        end

        tool = matching_tools.first
      end

      # Validate parameters against tool schema
      validate_params!(tool, parameters)
      reject_task_required!(tool, tool_name)

      # Use the tool's associated server
      server = tool.server
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless server

      begin
        server.call_tool(tool_name, parameters)
      rescue MCPClient::Errors::ConnectionError => e
        # Add server identity information to the error for better context
        server_id = server.name ? "#{server.class}[#{server.name}]" : server.class.name
        raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message} (Server: #{server_id})"
      end
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

    # Convert MCP tools to Google Vertex AI tool specifications
    # @param tool_names [Array<String>, nil] optional list of tool names to include, nil means all tools
    # @return [Array<Hash>] Google Vertex AI tool specifications with cleaned schemas
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
      @prompt_cache.clear
      @resource_cache.clear
    end

    # Register a callback for JSON-RPC notifications from servers
    # @yield [server, method, params]
    # @return [void]
    def on_notification(&block)
      @notification_listeners << block
    end

    # Set the roots for this client (MCP 2025-06-18)
    # When roots are changed, a notification is sent to all connected servers
    # @param new_roots [Array<MCPClient::Root, Hash>] the new roots to set
    # @return [void]
    def roots=(new_roots)
      @roots = normalize_roots(new_roots)
      # Notify servers that roots have changed
      notify_roots_changed
    end

    # Find a server by name
    # @param name [String] the name of the server to find
    # @return [MCPClient::ServerBase, nil] the server with the given name, or nil if not found
    def find_server(name)
      @servers.find { |s| s.name == name }
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
    # @param calls [Array<Hash>] array of call hashes with keys:
    #   - name: tool name (required)
    #   - parameters: tool parameters (optional, default empty hash)
    #   - server: server name for routing (optional)
    # @return [Array<Object>] array of results for each tool invocation
    def call_tools(calls)
      calls.map do |call|
        name = call[:name] || call['name']
        params = call[:parameters] || call['parameters'] || {}
        server = call[:server] || call['server']
        call_tool(name, params, server: server)
      end
    end

    # Stream call of a specific tool by name with the given parameters.
    # Returns an Enumerator yielding streaming updates if supported.
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @param server [String, Symbol, Integer, MCPClient::ServerBase, nil] optional server to use
    # @return [Enumerator] streaming enumerator or single-value enumerator
    def call_tool_streaming(tool_name, parameters, server: nil)
      tools = list_tools

      if server
        # Use the specified server
        srv = select_server(server)
        # Find the tool on this specific server
        tool = tools.find { |t| t.name == tool_name && t.server == srv }
        unless tool
          raise MCPClient::Errors::ToolNotFound,
                "Tool '#{tool_name}' not found on server '#{srv.name || srv.class.name}'"
        end
      else
        # Find the tool across all servers
        matching_tools = tools.select { |t| t.name == tool_name }

        if matching_tools.empty?
          raise MCPClient::Errors::ToolNotFound, "Tool '#{tool_name}' not found"
        elsif matching_tools.size > 1
          # If multiple matches, disambiguate with server names
          server_names = matching_tools.map { |t| t.server&.name || 'unnamed' }
          raise MCPClient::Errors::AmbiguousToolName,
                "Multiple tools named '#{tool_name}' found across servers (#{server_names.join(', ')}). " \
                "Please specify a server using the 'server' parameter."
        end

        tool = matching_tools.first
      end

      # Validate parameters against tool schema
      validate_params!(tool, parameters)
      reject_task_required!(tool, tool_name)

      # Use the tool's associated server
      server = tool.server
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless server

      begin
        # Use the streaming API if it's available
        server.call_tool_streaming(tool_name, parameters)
      rescue MCPClient::Errors::ConnectionError => e
        # Add server identity information to the error for better context
        server_id = server.name ? "#{server.class}[#{server.name}]" : server.class.name
        msg = "Error calling streaming tool '#{tool_name}': #{e.message} (Server: #{server_id})"
        raise MCPClient::Errors::ToolCallError, msg
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

    # Request completion suggestions from a server (MCP 2025-06-18)
    # @param ref [Hash] reference object (e.g., { 'type' => 'ref/prompt', 'name' => 'prompt_name' })
    # @param argument [Hash] the argument being completed (e.g., { 'name' => 'arg_name', 'value' => 'partial' })
    # @param context [Hash, nil] optional context for the completion (MCP 2025-11-25),
    #   e.g., { 'arguments' => { 'arg1' => 'value1' } } for previously-resolved arguments
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [Hash] completion result with 'values', optional 'total', and 'hasMore' fields
    # @raise [MCPClient::Errors::ServerNotFound] if no server is available
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    def complete(ref:, argument:, context: nil, server: nil)
      srv = select_server(server)
      srv.complete(ref: ref, argument: argument, context: context)
    end

    # Call a tool as a task (task-augmented tools/call, MCP 2025-11-25).
    #
    # Instead of blocking for the result, the server accepts the request and
    # immediately returns a task handle; the actual result is retrieved later
    # via {#get_task_result} once the task reaches a terminal status. The server
    # must advertise the tasks.requests.tools.call capability, and the tool must
    # declare execution.taskSupport of 'optional' or 'required'.
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @param ttl [Integer, nil] optional requested task lifetime in milliseconds
    # @param server [String, Symbol, Integer, MCPClient::ServerBase, nil] optional server to use
    # @return [MCPClient::Task] the created task (status typically 'working')
    # @raise [MCPClient::Errors::ToolNotFound] if the tool is not found
    # @raise [MCPClient::Errors::ValidationError] if required parameters are missing
    # @raise [MCPClient::Errors::TaskError] if the server or tool does not support tasks, or creation fails
    def call_tool_as_task(tool_name, parameters, ttl: nil, server: nil)
      tool = resolve_tool(tool_name, server: server)
      validate_params!(tool, parameters)

      srv = tool.server
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless srv

      unless server_supports_task_tool_call?(srv)
        raise MCPClient::Errors::TaskError,
              'Server does not support task-augmented tools/call (no tasks.requests.tools.call capability)'
      end
      unless tool.supports_task?
        raise MCPClient::Errors::TaskError,
              "Tool '#{tool_name}' does not support task execution (execution.taskSupport is forbidden/unset)"
      end

      task_params = {}
      task_params[:ttl] = ttl if ttl
      # Keep _meta (string or symbol key) as a top-level request field rather
      # than a tool argument, so request metadata is preserved and does not fail
      # tool input-schema validation.
      meta_key = [:_meta, '_meta'].find { |k| parameters.key?(k) }
      arguments = meta_key ? parameters.reject { |k, _| k == meta_key } : parameters
      rpc_params = { name: tool_name, arguments: arguments, task: task_params }
      rpc_params[:_meta] = parameters[meta_key] if meta_key

      begin
        result = srv.rpc_request('tools/call', rpc_params)
        MCPClient::Task.from_create_result(result, server: srv)
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
        raise MCPClient::Errors::TaskError, "Error creating task for tool '#{tool_name}': #{e.message}"
      end
    end

    # Get the current state of a task (tasks/get, MCP 2025-11-25)
    # @param task_id [String] the ID of the task to query
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [MCPClient::Task] the task with current status
    # @raise [MCPClient::Errors::ServerNotFound] if no server is available
    # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
    # @raise [MCPClient::Errors::TaskError] if retrieving the task fails
    def get_task(task_id, server: nil)
      srv = select_server(server)

      begin
        result = srv.rpc_request('tasks/get', { taskId: task_id })
        MCPClient::Task.from_json(result, server: srv)
      rescue MCPClient::Errors::ServerError => e
        raise task_error_from(e, task_id, 'getting')
      rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
        raise MCPClient::Errors::TaskError, "Error getting task '#{task_id}': #{e.message}"
      end
    end

    # Retrieve the result of a completed task (tasks/result, MCP 2025-11-25).
    # Returns exactly what the underlying request would have returned (e.g. a
    # CallToolResult hash with 'content'/'isError'/'structuredContent'); it is
    # NOT wrapped in a Task. Blocks on the server until the task is terminal.
    # @param task_id [String] the ID of the task
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [Object] the underlying task result
    # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
    # @raise [MCPClient::Errors::TaskError] if retrieval fails
    def get_task_result(task_id, server: nil)
      srv = select_server(server)

      begin
        srv.rpc_request('tasks/result', { taskId: task_id })
      rescue MCPClient::Errors::ServerError => e
        raise task_error_from(e, task_id, 'getting result for')
      rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
        raise MCPClient::Errors::TaskError, "Error getting result for task '#{task_id}': #{e.message}"
      end
    end

    # List tasks known to a server (tasks/list, paginated, MCP 2025-11-25)
    # @param cursor [String, nil] optional pagination cursor
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [Hash] { tasks: Array<MCPClient::Task>, next_cursor: String, nil }
    # @raise [MCPClient::Errors::TaskError] if listing fails
    def list_tasks(cursor: nil, server: nil)
      srv = select_server(server)
      params = cursor ? { cursor: cursor } : {}

      begin
        result = srv.rpc_request('tasks/list', params) || {}
        tasks = (result['tasks'] || []).map { |t| MCPClient::Task.from_json(t, server: srv) }
        { tasks: tasks, next_cursor: result['nextCursor'] }
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
        raise MCPClient::Errors::TaskError, "Error listing tasks: #{e.message}"
      end
    end

    # Cancel a task (tasks/cancel, MCP 2025-11-25)
    # @param task_id [String] the ID of the task to cancel
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [MCPClient::Task] the task with updated (cancelled) status
    # @raise [MCPClient::Errors::ServerNotFound] if no server is available
    # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
    # @raise [MCPClient::Errors::TaskError] if cancellation fails (including cancelling a terminal task)
    def cancel_task(task_id, server: nil)
      srv = select_server(server)

      begin
        result = srv.rpc_request('tasks/cancel', { taskId: task_id })
        MCPClient::Task.from_json(result, server: srv)
      rescue MCPClient::Errors::ServerError => e
        # A terminal task cannot be cancelled (-32602); that is an error, not a
        # missing task, so keep it as a TaskError.
        if e.message.match?(/terminal/i)
          raise MCPClient::Errors::TaskError, "Error cancelling task '#{task_id}': #{e.message}"
        end

        raise task_error_from(e, task_id, 'cancelling')
      rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
        raise MCPClient::Errors::TaskError, "Error cancelling task '#{task_id}': #{e.message}"
      end
    end

    # Set the logging level on all connected servers (MCP 2025-06-18)
    # To set on a specific server, use: client.find_server('name').log_level = 'debug'
    # @param level [String] the log level ('debug', 'info', 'notice', 'warning', 'error',
    #   'critical', 'alert', 'emergency')
    # @return [Array<Hash>] results from servers
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    def log_level=(level)
      @servers.map { |srv| srv.log_level = level }
    end

    private

    # Process incoming JSON-RPC notifications with default handlers
    # @param server [MCPClient::ServerBase] the server that emitted the notification
    # @param method [String] JSON-RPC notification method
    # @param params [Hash] parameters for the notification
    # @return [void]
    def process_notification(server, method, params)
      server_id = server.name ? "#{server.class}[#{server.name}]" : server.class
      case method
      when 'notifications/tools/list_changed'
        logger.warn("[#{server_id}] Tool list has changed, clearing tool cache")
        @tool_cache.clear
      when 'notifications/resources/updated'
        logger.warn("[#{server_id}] Resource #{params['uri']} updated")
      when 'notifications/prompts/list_changed'
        logger.warn("[#{server_id}] Prompt list has changed, clearing prompt cache")
        @prompt_cache.clear
      when 'notifications/resources/list_changed'
        logger.warn("[#{server_id}] Resource list has changed, clearing resource cache")
        @resource_cache.clear
      when 'notifications/message'
        # MCP 2025-06-18: Handle logging messages from server
        handle_log_message(server_id, params)
      when 'notifications/tasks/status'
        # MCP 2025-11-25: task status update (params are a flat Task)
        handle_task_status_notification(server_id, params)
      else
        # Log unknown notification types for debugging purposes
        logger.debug("[#{server_id}] Received unknown notification: #{method} - #{params}")
      end
    end

    # Handle logging message notification from server (MCP 2025-06-18)
    # @param server_id [String] server identifier for log prefix
    # @param params [Hash] log message params (level, logger, data)
    # @return [void]
    def handle_log_message(server_id, params)
      level = params['level'] || 'info'
      logger_name = params['logger']
      data = params['data']

      # Format the message
      prefix = logger_name ? "[#{server_id}:#{logger_name}]" : "[#{server_id}]"
      message = data.is_a?(String) ? data : data.inspect

      # Map MCP log levels to Ruby Logger levels
      case level.to_s.downcase
      when 'debug'
        logger.debug("#{prefix} #{message}")
      when 'info', 'notice'
        logger.info("#{prefix} #{message}")
      when 'warning'
        logger.warn("#{prefix} #{message}")
      when 'error', 'critical', 'alert', 'emergency'
        logger.error("#{prefix} #{message}")
      else
        logger.info("#{prefix} [#{level}] #{message}")
      end
    end

    # Select a server based on index, name, type, or instance
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

        # First check if it's a server name match
        srv = @servers.find { |s| s.name && s.name.downcase == key }
        return srv if srv

        # Then check if it's a server type match
        srv = @servers.find { |s| s.class.name.split('::').last.downcase.end_with?(key) }
        raise MCPClient::Errors::ServerNotFound, "Server with name or type '#{server_arg}' not found" unless srv

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

      properties = schema['properties'] || schema[:properties] || {}

      missing = required.map(&:to_s) - parameters.keys.map(&:to_s)

      # Exclude required params that have a default value in the schema,
      # since the server will apply the default.
      missing = missing.reject do |param|
        prop = properties[param] || properties[param.to_sym]
        prop.is_a?(Hash) && (prop.key?('default') || prop.key?(:default))
      end

      return unless missing.any?

      raise MCPClient::Errors::ValidationError, "Missing required parameters: #{missing.join(', ')}"
    end

    def find_server_for_tool(tool)
      servers.find do |server|
        server.list_tools.any? { |t| t.name == tool.name }
      end
    end

    # Resolve a tool by name (optionally scoped to a server), raising the same
    # not-found / ambiguity errors as call_tool.
    # @param tool_name [String] the tool name
    # @param server [String, Symbol, Integer, MCPClient::ServerBase, nil] optional server selector
    # @return [MCPClient::Tool] the resolved tool
    # @raise [MCPClient::Errors::ToolNotFound, MCPClient::Errors::AmbiguousToolName]
    def resolve_tool(tool_name, server: nil)
      tools = list_tools

      if server
        srv = select_server(server)
        tool = tools.find { |t| t.name == tool_name && t.server == srv }
        unless tool
          raise MCPClient::Errors::ToolNotFound,
                "Tool '#{tool_name}' not found on server '#{srv.name || srv.class.name}'"
        end
        return tool
      end

      matching_tools = tools.select { |t| t.name == tool_name }
      if matching_tools.empty?
        raise MCPClient::Errors::ToolNotFound, "Tool '#{tool_name}' not found"
      elsif matching_tools.size > 1
        server_names = matching_tools.map { |t| t.server&.name || 'unnamed' }
        raise MCPClient::Errors::AmbiguousToolName,
              "Multiple tools named '#{tool_name}' found across servers (#{server_names.join(', ')}). " \
              "Please specify a server using the 'server' parameter."
      end

      matching_tools.first
    end

    # Reject a plain (synchronous) call for a tool whose execution.taskSupport is
    # 'required'. A compliant server would reject a non-task-augmented tools/call
    # for such a tool, so fail fast and point the caller at call_tool_as_task.
    # @param tool [MCPClient::Tool] the resolved tool
    # @param tool_name [String] the tool name (for the message)
    # @raise [MCPClient::Errors::ToolCallError] if the tool requires task execution
    def reject_task_required!(tool, tool_name)
      return unless tool.task_required?

      raise MCPClient::Errors::ToolCallError,
            "Tool '#{tool_name}' requires task-augmented execution; call it with call_tool_as_task instead"
    end

    # Whether a server advertised support for task-augmented tools/call, i.e.
    # capabilities.tasks.requests.tools.call.
    # @param srv [MCPClient::ServerBase] the server
    # @return [Boolean]
    def server_supports_task_tool_call?(srv)
      caps = srv.respond_to?(:capabilities) ? srv.capabilities : nil
      return false unless caps.is_a?(Hash)

      tasks = caps['tasks'] || caps[:tasks]
      requests = tasks && (tasks['requests'] || tasks[:requests])
      tools = requests && (requests['tools'] || requests[:tools])
      call = tools && (tools['call'] || tools[:call])
      !call.nil?
    end

    # Map a ServerError from a task operation to TaskNotFound or TaskError.
    # @param error [MCPClient::Errors::ServerError] the server error
    # @param task_id [String] the task id
    # @param action [String] a verb phrase for the error message (e.g. 'getting')
    # @return [MCPClient::Errors::TaskNotFound, MCPClient::Errors::TaskError]
    def task_error_from(error, task_id, action)
      if error.message.match?(/not found|unknown task|expired/i)
        return MCPClient::Errors::TaskNotFound.new("Task '#{task_id}' not found")
      end

      MCPClient::Errors::TaskError.new("Error #{action} task '#{task_id}': #{error.message}")
    end

    # Handle a notifications/tasks/status notification (MCP 2025-11-25).
    # The params are a flat Task.
    # @param server_id [String] server identifier for the log prefix
    # @param params [Hash] the flat task params
    # @return [void]
    def handle_task_status_notification(server_id, params)
      task = MCPClient::Task.from_json(params)
      logger.info("[#{server_id}] Task #{task.task_id} status: #{task.status}")
    rescue StandardError => e
      logger.debug("[#{server_id}] Failed to parse task status notification: #{e.message}")
    end

    # Generate a cache key for server-specific items
    # @param server [MCPClient::ServerBase] the server
    # @param item_id [String] the item identifier (name or URI)
    # @return [String] composite cache key
    def cache_key_for(server, item_id)
      server_id = server.object_id.to_s
      "#{server_id}:#{item_id}"
    end

    # Find a resource on a specific server
    # @param uri [String] the URI of the resource
    # @param resources [Array<Resource>] available resources
    # @param server [String, Symbol, Integer, MCPClient::ServerBase] server selector
    # @return [Resource] the found resource
    # @raise [MCPClient::Errors::ResourceNotFound] if resource not found
    def find_resource_on_server(uri, resources, server)
      srv = select_server(server)
      resource = resources.find { |r| r.uri == uri && r.server == srv }
      unless resource
        raise MCPClient::Errors::ResourceNotFound,
              "Resource '#{uri}' not found on server '#{srv.name || srv.class.name}'"
      end
      resource
    end

    # Find a resource across all servers
    # @param uri [String] the URI of the resource
    # @param resources [Array<Resource>] available resources
    # @return [Resource] the found resource
    # @raise [MCPClient::Errors::ResourceNotFound] if resource not found
    # @raise [MCPClient::Errors::AmbiguousResourceURI] if multiple resources found
    def find_resource_across_servers(uri, resources)
      matching_resources = resources.select { |r| r.uri == uri }

      if matching_resources.empty?
        raise MCPClient::Errors::ResourceNotFound, "Resource '#{uri}' not found"
      elsif matching_resources.size > 1
        server_names = matching_resources.map { |r| r.server&.name || 'unnamed' }
        raise MCPClient::Errors::AmbiguousResourceURI,
              "Multiple resources with URI '#{uri}' found across servers (#{server_names.join(', ')}). " \
              "Please specify a server using the 'server' parameter."
      end

      matching_resources.first
    end

    # Execute the resource read operation
    # @param resource [Resource] the resource to read
    # @param uri [String] the URI of the resource
    # @return [Object] the resource contents
    # @raise [MCPClient::Errors::ServerNotFound] if no server found
    # @raise [MCPClient::Errors::ResourceReadError] on read errors
    def execute_resource_read(resource, uri)
      server = resource.server
      raise MCPClient::Errors::ServerNotFound, "No server found for resource '#{uri}'" unless server

      begin
        server.read_resource(uri)
      rescue MCPClient::Errors::ConnectionError => e
        server_id = server.name ? "#{server.class}[#{server.name}]" : server.class.name
        raise MCPClient::Errors::ResourceReadError,
              "Error reading resource '#{uri}': #{e.message} (Server: #{server_id})"
      end
    end

    # Handle elicitation request from server (MCP 2025-11-25)
    # Supports both form mode (structured data) and URL mode (out-of-band interaction).
    # @param _request_id [String, Integer] the JSON-RPC request ID (unused at client layer)
    # @param params [Hash] the elicitation parameters
    # @return [Hash] the elicitation response
    def handle_elicitation_request(_request_id, params)
      mode = params['mode'] || 'form'
      # MCP 2025-11-25: requests with a mode not declared in client
      # capabilities MUST be rejected with -32602 (Invalid params). This check
      # precedes everything else — an undeclared mode is -32602 even when no
      # handler is configured.
      unless SUPPORTED_ELICITATION_MODES.include?(mode)
        @logger.warn("Rejecting elicitation request with unsupported mode '#{mode}'")
        return jsonrpc_error_result(-32_602, "Elicitation mode '#{mode}' is not supported")
      end

      # Without a handler there is no user to interact with: answer with a
      # JSON-RPC error rather than fabricating a user "decline".
      unless @elicitation_handler
        @logger.warn('Received elicitation request but no elicitation handler is configured')
        return jsonrpc_error_result(-32_601, 'Elicitation not supported: no elicitation handler configured')
      end

      message = params['message']

      begin
        result = if mode == 'url'
                   handle_url_elicitation(params, message)
                 else
                   handle_form_elicitation(params, message)
                 end

        format_elicitation_response(result, params)
      rescue StandardError => e
        @logger.error("Elicitation handler error: #{e.message}")
        @logger.debug(e.backtrace.join("\n"))
        jsonrpc_error_result(-32_603, "Elicitation handler error: #{e.message}")
      end
    end

    # Build an error-shaped handler result that transports turn into a
    # JSON-RPC error response (mirroring the sampling error path).
    # @param code [Integer] JSON-RPC error code
    # @param message [String] error message
    # @return [Hash] error result
    def jsonrpc_error_result(code, message)
      { 'error' => { 'code' => code, 'message' => message } }
    end

    # Handle form mode elicitation (MCP 2025-11-25)
    # @param params [Hash] the elicitation parameters
    # @param message [String] the human-readable message
    # @return [Object] handler result
    def handle_form_elicitation(params, message)
      schema = params['requestedSchema'] || params['schema']
      metadata = params['metadata']

      # Validate schema if present
      if schema
        schema_errors = ElicitationValidator.validate_schema(schema)
        @logger.warn("Elicitation schema validation warnings: #{schema_errors.join('; ')}") unless schema_errors.empty?
      end

      # Call the user-defined handler
      case @elicitation_handler.arity
      when 0
        @elicitation_handler.call
      when 1
        @elicitation_handler.call(message)
      when 2, -1
        @elicitation_handler.call(message, schema)
      else
        @elicitation_handler.call(message, schema, metadata)
      end
    end

    # Handle URL mode elicitation (MCP 2025-11-25)
    # @param params [Hash] the elicitation parameters
    # @param message [String] the human-readable message
    # @return [Object] handler result
    def handle_url_elicitation(params, message)
      url = params['url']
      elicitation_id = params['elicitationId']

      # Call handler with URL-mode specific params
      case @elicitation_handler.arity
      when 0
        @elicitation_handler.call
      when 1
        @elicitation_handler.call(message)
      when 2, -1
        @elicitation_handler.call(message, { 'mode' => 'url', 'url' => url, 'elicitationId' => elicitation_id })
      else
        @elicitation_handler.call(message, { 'mode' => 'url', 'url' => url, 'elicitationId' => elicitation_id },
                                  params['metadata'])
      end
    end

    # Format and validate the elicitation response
    # @param result [Object] handler result
    # @param params [Hash] original request params (for schema validation)
    # @return [Hash] formatted response
    def format_elicitation_response(result, params)
      response = normalize_elicitation_result(result)

      # Per the ElicitResult schema, content is only present when the action
      # is accept and the mode was form; it is omitted for decline/cancel and
      # for out-of-band (url) mode responses.
      response.delete('content') if response['action'] != 'accept' || (params['mode'] || 'form') == 'url'

      # ElicitResult.content is an object mapping property names to primitive
      # values — a scalar cannot be transmitted.
      if response.key?('content') && !response['content'].is_a?(Hash)
        @logger.warn("Elicitation handler returned non-object content (#{response['content'].class})")
        return jsonrpc_error_result(-32_603, 'Elicitation content must be an object of primitive values')
      end

      # Validate content against schema for form mode accept responses; do not
      # transmit content that violates the requestedSchema (spec SHOULD).
      errors = validate_elicitation_content(response, params)
      unless errors.empty?
        @logger.warn("Elicitation content validation failed: #{errors.join('; ')}")
        return jsonrpc_error_result(-32_603, "Elicitation content failed schema validation: #{errors.join('; ')}")
      end

      response
    end

    # Normalize a handler's return value into a string-keyed ElicitResult
    # shape, so mixed or symbol keys cannot bypass content handling.
    # @param result [Object] handler result
    # @return [Hash] normalized response with string keys
    def normalize_elicitation_result(result)
      case result
      when Hash
        action = result['action'] || result[:action]
        return { 'action' => 'accept', 'content' => result } unless action

        content = result.key?('content') || result.key?(:content) ? (result['content'] || result[:content]) : nil
        normalised_action_response({ 'action' => action.to_s, 'content' => content }.compact)
      when nil
        { 'action' => 'cancel' }
      else
        { 'action' => 'accept', 'content' => result }
      end
    end

    # Validate elicitation response content against the requestedSchema
    # @param response [Hash] the formatted response
    # @param params [Hash] original request params
    # @return [Array<String>] validation errors (empty when conforming or not applicable)
    def validate_elicitation_content(response, params)
      return [] unless response['action'] == 'accept' && response['content'].is_a?(Hash)

      mode = params['mode'] || 'form'
      return [] unless mode == 'form'

      schema = params['requestedSchema'] || params['schema']
      return [] unless schema.is_a?(Hash)

      ElicitationValidator.validate_content(response['content'], schema)
    end

    # Ensure the action value conforms to MCP spec (accept, decline, cancel)
    # Falls back to accept for unknown action values.
    def normalised_action_response(result)
      action = result['action']
      return result if %w[accept decline cancel].include?(action)

      @logger.warn("Unknown elicitation action '#{action}', defaulting to accept")
      result.merge('action' => 'accept')
    end

    # Normalize roots array - convert Hashes to Root objects (MCP 2025-06-18)
    # @param roots [Array<MCPClient::Root, Hash>, nil] the roots to normalize
    # @return [Array<MCPClient::Root>] normalized roots array
    def normalize_roots(roots)
      return [] if roots.nil?

      roots.map do |root|
        case root
        when MCPClient::Root
          root
        when Hash
          MCPClient::Root.from_json(root)
        else
          raise ArgumentError, "Invalid root type: #{root.class}. Expected MCPClient::Root or Hash."
        end
      end
    end

    # Handle roots/list request from server (MCP 2025-06-18)
    # @param _request_id [String, Integer] the JSON-RPC request ID (unused, kept for callback signature)
    # @param _params [Hash] the request parameters (unused)
    # @return [Hash] the roots list response
    def handle_roots_list_request(_request_id, _params)
      { 'roots' => @roots.map(&:to_h) }
    end

    # Send notification to all servers that roots have changed (MCP 2025-06-18)
    # @return [void]
    def notify_roots_changed
      @servers.each do |server|
        server.rpc_notify('notifications/roots/list_changed', {})
      rescue StandardError => e
        server_id = server.name ? "#{server.class}[#{server.name}]" : server.class
        @logger.warn("[#{server_id}] Failed to send roots/list_changed notification: #{e.message}")
      end
    end

    # Handle sampling/createMessage request from server (MCP 2025-11-25)
    # @param _request_id [String, Integer] the JSON-RPC request ID (unused, kept for callback signature)
    # @param params [Hash] the sampling parameters
    # @return [Hash] the sampling response (role, content, model, stopReason)
    def handle_sampling_request(_request_id, params)
      # If no handler is configured, return an error
      unless @sampling_handler
        @logger.warn('Received sampling request but no handler configured')
        return { 'error' => { 'code' => -1, 'message' => 'Sampling not supported' } }
      end

      messages = params['messages'] || []
      model_preferences = normalize_model_preferences(params['modelPreferences'])
      system_prompt = params['systemPrompt']
      max_tokens = params['maxTokens']
      include_context = params['includeContext']
      temperature = params['temperature']
      stop_sequences = params['stopSequences']
      metadata = params['metadata']

      begin
        # Call the user-defined handler with parameters based on arity
        result = call_sampling_handler(messages, model_preferences, system_prompt, max_tokens,
                                       include_context, temperature, stop_sequences, metadata)

        # Validate and format response
        validate_sampling_response(result)
      rescue StandardError => e
        @logger.error("Sampling handler error: #{e.message}")
        @logger.debug(e.backtrace.join("\n"))
        { 'error' => { 'code' => -1, 'message' => "Sampling error: #{e.message}" } }
      end
    end

    # Call sampling handler with appropriate arity
    # @param messages [Array] the messages
    # @param model_preferences [Hash, nil] normalized model preferences
    # @param system_prompt [String, nil] system prompt
    # @param max_tokens [Integer, nil] max tokens
    # @param include_context [String, nil] context inclusion setting
    # @param temperature [Float, nil] temperature
    # @param stop_sequences [Array, nil] stop sequences
    # @param metadata [Hash, nil] metadata
    # @return [Hash] the handler result
    def call_sampling_handler(messages, model_preferences, system_prompt, max_tokens,
                              include_context, temperature, stop_sequences, metadata)
      arity = @sampling_handler.arity
      # Normalize negative arity (optional params) to minimum required args
      arity = -(arity + 1) if arity.negative?
      case arity
      when 0
        @sampling_handler.call
      when 1
        @sampling_handler.call(messages)
      when 2
        @sampling_handler.call(messages, model_preferences)
      when 3
        @sampling_handler.call(messages, model_preferences, system_prompt)
      when 4
        @sampling_handler.call(messages, model_preferences, system_prompt, max_tokens)
      else
        @sampling_handler.call(messages, model_preferences, system_prompt, max_tokens,
                               { 'includeContext' => include_context, 'temperature' => temperature,
                                 'stopSequences' => stop_sequences, 'metadata' => metadata })
      end
    end

    # Normalize and validate modelPreferences from sampling request (MCP 2025-11-25)
    # Ensures hints is an array of hashes with 'name', and priority values are clamped to 0.0..1.0
    # @param prefs [Hash, nil] raw modelPreferences from request
    # @return [Hash, nil] normalized modelPreferences or nil
    def normalize_model_preferences(prefs)
      return nil if prefs.nil?
      return nil unless prefs.is_a?(Hash)

      normalized = {}

      # Normalize hints: array of { 'name' => String }
      if prefs['hints']
        normalized['hints'] = Array(prefs['hints']).filter_map do |hint|
          next nil unless hint.is_a?(Hash) && hint['name']

          { 'name' => hint['name'].to_s }
        end
      end

      # Normalize priority values (0.0 to 1.0)
      %w[costPriority speedPriority intelligencePriority].each do |key|
        next unless prefs.key?(key)

        value = prefs[key]
        normalized[key] = value.is_a?(Numeric) ? value.to_f.clamp(0.0, 1.0) : nil
      end

      normalized
    end

    # Validate sampling response from handler (MCP 2025-11-25)
    # @param result [Hash] the result from the sampling handler
    # @return [Hash] validated sampling response
    def validate_sampling_response(result)
      return { 'error' => { 'code' => -1, 'message' => 'Sampling rejected' } } if result.nil?

      # Convert symbol keys to string keys
      result = result.transform_keys(&:to_s) if result.is_a?(Hash) && result.keys.first.is_a?(Symbol)

      # Ensure required fields are present
      unless result.is_a?(Hash) && result['content']
        return {
          'role' => 'assistant',
          'content' => { 'type' => 'text', 'text' => result.to_s },
          'model' => 'unknown',
          'stopReason' => 'endTurn'
        }
      end

      # Set defaults for missing fields
      result['role'] ||= 'assistant'
      result['model'] ||= 'unknown'
      result['stopReason'] ||= 'endTurn'

      # Normalize content if it's a string
      result['content'] = { 'type' => 'text', 'text' => result['content'] } if result['content'].is_a?(String)

      result
    end
  end
end
