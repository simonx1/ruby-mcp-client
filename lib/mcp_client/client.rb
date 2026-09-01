# frozen_string_literal: true

require 'logger'
require 'securerandom'
require_relative 'deep_copy'
require_relative 'client/list_aggregation'

module MCPClient
  # MCP Client for integrating with the Model Context Protocol
  # This is the main entry point for using MCP tools
  class Client
    include ListAggregation
    include MCPClient::Client::TaskSupport

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

    # Supported modes for structuredContent validation (MCP 2025-11-25):
    # :warn logs a warning on mismatch, :strict raises a ValidationError.
    STRUCTURED_CONTENT_MODES = %i[warn strict].freeze

    # Server-config keys whose values carry credentials (HTTP headers, the
    # subprocess environment, inline tokens). Their values are replaced before
    # a config is written to the log.
    SENSITIVE_CONFIG_KEYS = %i[headers env token access_token api_key auth authorization
                               password secret client_secret oauth_provider].freeze

    # Placeholder written in place of a redacted value.
    REDACTED = '[REDACTED]'

    # Where {#register_notification_handlers} leaves word, on the thread that
    # is routing, that the caches for the notification in hand have already
    # been dropped by the transport's invalidation hook.
    CACHE_INVALIDATION_MARK = :mcp_client_cache_invalidation

    # Maximum characters of a peer-supplied log message written to the host
    # log. The remote server controls this content, so an unbounded message
    # would let it inflate log storage at will.
    MAX_PEER_LOG_MESSAGE_LENGTH = 4096

    # Initialize a new MCPClient::Client
    # @param mcp_server_configs [Array<Hash>] configurations for MCP servers
    # @param logger [Logger, nil] optional logger, defaults to STDOUT
    # @param elicitation_handler [Proc, nil] optional handler for elicitation requests (MCP 2025-06-18)
    # @param roots [Array<MCPClient::Root, Hash>, nil] optional list of roots (MCP 2025-06-18)
    # @param sampling_handler [Proc, nil] optional handler for sampling requests (MCP 2025-11-25)
    # @param sampling_supports_tools [Boolean] whether the sampling handler supports tool use
    #   (MCP 2025-11-25 / SEP-1577); declares the sampling.tools capability and forwards
    #   tools/toolChoice params to the handler instead of rejecting tool-enabled requests
    # @param client_info [Hash, nil] host-provided Implementation info sent as clientInfo
    #   (name and version required; title, description, websiteUrl, icons optional)
    # @param validate_structured_content [Symbol] how to treat a tools/call result whose
    #   structuredContent does not match the tool's declared outputSchema (MCP 2025-11-25:
    #   "Clients SHOULD validate structured results against this schema"): :warn (default)
    #   logs a warning, :strict raises MCPClient::Errors::ValidationError
    # @param request_meta [Hash, #call, nil] metadata merged into every request's `_meta`
    #   (a Hash, or a callable returning one, evaluated per request) — e.g. OpenTelemetry
    #   trace context (`traceparent`, `tracestate`, `baggage`, MCP 2026-07-28) or
    #   vendor-prefixed keys. Reserved protocol keys cannot be set this way.
    # @param extensions [Array<String>, Hash{String => Hash}, nil] MCP 2026-07-28 extensions to declare
    #   in every request's clientCapabilities (identifier, or identifier => settings), e.g.
    #   `['io.modelcontextprotocol/tasks']` to let servers answer tools/call with a task
    def initialize(mcp_server_configs: [], logger: nil, elicitation_handler: nil, roots: nil, sampling_handler: nil,
                   sampling_supports_tools: false, client_info: nil, validate_structured_content: :warn,
                   request_meta: nil, extensions: nil)
      unless STRUCTURED_CONTENT_MODES.include?(validate_structured_content)
        raise ArgumentError, "validate_structured_content must be one of #{STRUCTURED_CONTENT_MODES.inspect}, " \
                             "got #{validate_structured_content.inspect}"
      end

      @validate_structured_content = validate_structured_content
      @extensions = normalize_extensions(extensions)
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
        @logger.debug("Creating server with config: #{redact_config(config).inspect}")
        MCPClient::ServerFactory.create(config, logger: @logger)
      end
      @tool_cache = {}
      # The effective-parameter fingerprint each server's slice of a list
      # cache was filled under (MCP 2026-07-28 caching: a result is served
      # only to a request that would carry the same parameters).
      @cache_params = Hash.new { |h, k| h[k] = {}.compare_by_identity }
      # Which servers have filled their slice of a list cache, so a snapshot
      # is known to be complete however few items it holds: a server that
      # legitimately lists nothing must be served from the cache too, not
      # asked again on every call.
      @cache_filled = {}
      # One lock for the list caches and their parameter tags: a freshness
      # check and the copy it approves are one snapshot, and the notification
      # thread's clears wait for it.
      @cache_mutex = Mutex.new
      # Bumped by every write under @cache_mutex, so a freshness verdict
      # reached outside the lock can be revalidated before a copy is served.
      @cache_version = 0
      # Active progressToken -> callback registrations (MCP progress utility)
      @progress_callbacks = {}
      @progress_mutex = Mutex.new
      @prompt_cache = {}
      @resource_cache = {}
      # JSON-RPC notification listeners
      @notification_listeners = []
      # Elicitation handler (MCP 2025-06-18)
      @elicitation_handler = elicitation_handler
      # Sampling handler (MCP 2025-11-25)
      @sampling_handler = sampling_handler
      # Whether the sampling handler supports tool use (SEP-1577)
      @sampling_supports_tools = sampling_supports_tools
      # Roots (MCP 2025-06-18)
      @roots = normalize_roots(roots)
      # Register default and user-defined notification handlers on each server
      @servers.each do |server|
        configure_server_identity(server, client_info, request_meta)
        register_notification_handlers(server)
        # Register feature callbacks only for features the host actually
        # supports: transports derive their declared client capabilities from
        # the callbacks registered before connecting, and MCP forbids using
        # capabilities that were not negotiated.
        if @elicitation_handler && server.respond_to?(:on_elicitation_request)
          server.on_elicitation_request(&method(:handle_elicitation_request))
        end
        # The client always implements the roots feature (roots/list and
        # list_changed notifications), independent of the current roots list.
        server.on_roots_list_request(&method(:handle_roots_list_request)) if server.respond_to?(:on_roots_list_request)
        next unless @sampling_handler && server.respond_to?(:on_sampling_request)

        server.on_sampling_request(&method(:handle_sampling_request))
        # Declare the sampling.tools sub-capability (SEP-1577) only when the
        # host opted in; the transport derives its initialize declaration
        # from this before connecting.
        server.declare_sampling_tools if @sampling_supports_tools && server.respond_to?(:declare_sampling_tools)
      end
    end

    # Lists all available prompts from all connected MCP servers
    # @param cache [Boolean] whether to use cached prompts or fetch fresh
    # @return [Array<MCPClient::Prompt>] list of available prompts
    # @raise [MCPClient::Errors::ConnectionError] on authorization failures
    # @raise [MCPClient::Errors::PromptGetError] if no prompts could be retrieved from any server
    def list_prompts(cache: true)
      holding_request_meta('prompts/list') do
        if cache && (snapshot = cached_snapshot(:prompts, @prompt_cache))
          release_held_request_meta
          return snapshot
        end

        collect_prompts_from_servers(cache)
      end
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
      holding_request_meta('resources/list') do
        # If cursor is provided, we can only query one server (the one that provided the cursor)
        # This is a limitation of aggregating multiple servers
        if cursor
          # For now, just use the first server when cursor is provided
          return servers.first.list_resources(cursor: cursor) if servers.any?

          return { 'resources' => [], 'nextCursor' => nil }
        end

        # Use cache if available and no cursor
        if cache && (snapshot = cached_snapshot(:resources, @resource_cache))
          release_held_request_meta
          return { 'resources' => snapshot, 'nextCursor' => nil }
        end

        collect_resources_from_servers(cache)
      end
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
      holding_request_meta('tools/list') do
        if cache && (snapshot = cached_snapshot(:tools, @tool_cache))
          release_held_request_meta
          return snapshot
        end

        collect_tools_from_servers(cache)
      end
    end

    # Calls a specific tool by name with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @param server [String, Symbol, Integer, MCPClient::ServerBase, nil] optional server to use
    # @return [Object] the result of the tool invocation
    def call_tool(tool_name, parameters, server: nil, progress: nil)
      tool = resolve_tool(tool_name, server: server)

      # Validate parameters against tool schema
      validate_params!(tool, parameters)
      reject_task_required!(tool, tool_name)

      # Use the tool's associated server
      server = tool.server
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless server

      # MCP progress utility: attach an auto-generated progressToken to the
      # request _meta and route matching notifications/progress to the
      # caller's callback while the request is active.
      parameters, token = setup_progress_tracking(parameters, progress)

      # The call and the re-resolve that follows it share one slot for the
      # definition the transport's request goes out under, so a call that a
      # notification listener nests inside this one cannot leave its own
      # there.
      with_called_tool_definition(server) do
        result = begin
          server.call_tool(tool_name, parameters)
        rescue MCPClient::Errors::ConnectionError => e
          # Add server identity information to the error for better context
          server_id = server.name ? "#{server.class}[#{server.name}]" : server.class.name
          raise MCPClient::Errors::ToolCallError,
                "Error calling tool '#{tool_name}': #{e.message} (Server: #{server_id})"
        ensure
          # Tokens are only valid for the lifetime of the request: dropping the
          # registration filters out stale post-completion notifications.
          unregister_progress_callback(token) if token
        end

        # MCP 2026-07-28 tasks extension: the server may have turned the call
        # into a task; drive it to its final result so the contract of this
        # method does not change.
        result = complete_task_result(tool_name, server, result)

        # MCP 2026-07-28 HeaderMismatch recovery re-derives a call's
        # Mcp-Param-* headers from a refreshed tools/list, so the attempt that
        # was answered may have gone out under a definition this client never
        # resolved. Validate against that one -- never against the transport's
        # current list, which a tools/list_changed racing the call may already
        # have replaced with a definition the server never used.
        tool = called_tool_definition(server, tool_name) || tool
        validate_structured_content!(tool, result)
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
      # The transports forgot their results; the slices built from them go too.
      clear_cache
    end

    # The list kinds this client caches, each with the transport-level cache
    # behind it.
    CACHED_LIST_KINDS = %i[tools prompts resources].freeze

    # Clear the cached lists so that the next list_tools, list_prompts or
    # list_resources fetches fresh data.
    # @return [void]
    def clear_cache
      @cache_mutex.synchronize do
        @cache_version += 1
        @tool_cache.clear
        @prompt_cache.clear
        @resource_cache.clear
        # A slice's tag goes with the slice: a leftover tag must not vouch
        # for a server whose slice a later, partial refill never rebuilt.
        @cache_params.clear
        @cache_filled.clear
      end
      # The promise is fresh data, and a transport holding a list the server
      # bounded with a positive `ttlMs` (MCP 2026-07-28
      # server/utilities/caching) would answer the next listing from it
      # without sending anything at all. Dropped outside this client's lock:
      # each transport takes its own.
      servers.each do |server|
        CACHED_LIST_KINDS.each { |kind| refresh_server_cache(server, kind) }
      end
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
      tool = resolve_tool(tool_name, server: server)

      # Validate parameters against tool schema
      validate_params!(tool, parameters)
      reject_task_required!(tool, tool_name)

      # Use the tool's associated server
      server = tool.server
      raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless server

      begin
        # Use the streaming API if it's available
        stream = server.call_tool_streaming(tool_name, parameters)
        return stream unless tasks_extension? && modern_server?(server)

        # MCP 2026-07-28 tasks extension: a chunk may be a task; resolve it
        # to the call's result as #call_tool does.
        Enumerator.new do |yielder|
          stream.each { |chunk| yielder << complete_task_result(tool_name, server, chunk) }
        end
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
    def send_rpc(method, params: {}, server: nil, timeout: nil)
      srv = select_server(server)
      # Only pass the per-request timeout when set, so transports (and test
      # doubles) with the two-argument signature keep working.
      return srv.rpc_request(method, params) unless timeout

      srv.rpc_request(method, params, timeout: timeout)
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
      return call_tool_as_modern_task(tool_name, parameters, srv) if modern_server?(srv)

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
    # @param task_id [String, MCPClient::Task] the task to query; passing the
    #   Task handle returned by #call_tool_as_task routes to its own server
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [MCPClient::Task] the task with current status
    # @raise [ArgumentError] if the server is ambiguous in a multi-server client
    # @raise [MCPClient::Errors::ServerNotFound] if no server is available
    # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
    # @raise [MCPClient::Errors::TaskError] if retrieving the task fails
    # @param timeout [Numeric, nil] request timeout in seconds (the transport default when nil)
    def get_task(task_id, server: nil, timeout: nil)
      srv = select_task_server(task_id, server, 'get_task')
      task_id = task_identifier(task_id)
      ensure_task_capability!(srv, 'get')

      begin
        result = if timeout
                   srv.rpc_request('tasks/get', { taskId: task_id }, timeout: timeout)
                 else
                   srv.rpc_request('tasks/get', { taskId: task_id })
                 end
        task = MCPClient::Task.from_json(result, server: srv, detailed: true)
        # The answer must be about the task that was asked for: its state
        # drives result delivery and tasks/update.
        if modern_server?(srv) && task.task_id != task_id.to_s
          raise MCPClient::Errors::InvalidResultError,
                "Invalid tasks/get result: taskId #{sanitize_peer_log_text(task.task_id.to_s).inspect} does not " \
                "match the requested task #{sanitize_peer_log_text(task_id.to_s).inspect}"
        end
        task
      rescue MCPClient::Errors::ServerError => e
        raise if e.protocol_error?

        raise task_error_from(e, task_id, 'getting', modern: modern_server?(srv), method: 'tasks/get')
      rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
        raise MCPClient::Errors::TaskError, "Error getting task '#{sanitize_peer_log_text(task_id.to_s)}': " \
                                            "#{sanitize_peer_log_text(e.message)}"
      end
    end

    # Retrieve the result of a completed task (tasks/result, MCP 2025-11-25).
    # Returns exactly what the underlying request would have returned (e.g. a
    # CallToolResult hash with 'content'/'isError'/'structuredContent'); it is
    # NOT wrapped in a Task. Blocks on the server until the task is terminal.
    #
    # NOTE: structured-content validation (see #validate_structured_content!)
    # does not cover task-delivered results yet: a task ID alone does not
    # identify which tool (and therefore which outputSchema) produced the
    # result, and the client keeps no task-to-tool registry. Callers who need
    # validation here can run MCPClient::SchemaValidator.validate themselves.
    # @param task_id [String, MCPClient::Task] the task; passing the Task
    #   handle returned by #call_tool_as_task routes to its own server
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [Object] the underlying task result
    # @raise [ArgumentError] if the server is ambiguous in a multi-server client
    # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
    # @raise [MCPClient::Errors::TaskError] if retrieval fails
    def get_task_result(task_id, server: nil)
      srv = select_task_server(task_id, server, 'get_task_result')
      # tasks/result must never reach a 2026-07-28 server, so the era has
      # to be known: an initialization failure surfaces here.
      ensure_task_capability!(srv, 'result', strict: true)
      # MCP 2026-07-28 removed tasks/result: the result is delivered inline
      # by tasks/get once the task is terminal.
      return task_outcome(wait_for_task(task_id, server: srv)) if modern_server?(srv)

      task_id = task_identifier(task_id)

      begin
        srv.rpc_request('tasks/result', { taskId: task_id })
      rescue MCPClient::Errors::ServerError => e
        raise if e.protocol_error?

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
      # tasks/list is gone on 2026-07-28 regardless of any extension, so the
      # era is settled before the capability gate could ask for one.
      probe_server_era(srv)
      if modern_server?(srv)
        raise MCPClient::Errors::TaskError,
              'tasks/list does not exist on MCP 2026-07-28 servers: keep the Task handles you created'
      end
      ensure_task_capability!(srv, 'list')

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
    # @param task_id [String, MCPClient::Task] the task to cancel; passing the
    #   Task handle returned by #call_tool_as_task routes to its own server
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @return [MCPClient::Task] the task with updated (cancelled) status
    # @raise [ArgumentError] if the server is ambiguous in a multi-server client
    # @raise [MCPClient::Errors::ServerNotFound] if no server is available
    # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
    # @raise [MCPClient::Errors::TaskError] if cancellation fails (including cancelling a terminal task)
    def cancel_task(task_id, server: nil)
      srv = select_task_server(task_id, server, 'cancel_task')
      task = task_id
      task_id = task_identifier(task_id)
      ensure_task_capability!(srv, 'cancel')

      begin
        result = srv.rpc_request('tasks/cancel', { taskId: task_id })
        return cancelled_task_handle(task, task_id, srv) if modern_server?(srv)

        MCPClient::Task.from_json(result, server: srv)
      rescue MCPClient::Errors::ServerError => e
        raise if e.protocol_error?
        # A terminal task cannot be cancelled (-32602); that is an error, not a
        # missing task, so keep it as a TaskError.
        if e.message.match?(/terminal/i)
          raise MCPClient::Errors::TaskError, "Error cancelling task '#{task_id}': #{e.message}"
        end

        raise task_error_from(e, task_id, 'cancelling', modern: modern_server?(srv), method: 'tasks/cancel')
      rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
        raise MCPClient::Errors::TaskError, "Error cancelling task '#{sanitize_peer_log_text(task_id.to_s)}': " \
                                            "#{sanitize_peer_log_text(e.message)}"
      end
    end

    # Open a long-lived notification stream on a server (MCP 2026-07-28
    # subscriptions/listen). The subscription's notifications also flow
    # through the client's regular notification handling (cache
    # invalidation, on_notification listeners).
    # @param notifications [Hash] the SubscriptionFilter: tools_list_changed,
    #   prompts_list_changed, resources_list_changed (booleans),
    #   resource_subscriptions, task_ids (arrays of strings)
    # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
    # @param ack_timeout [Numeric, false, nil] seconds to wait for the server's
    #   acknowledgment before giving the listen up and cancelling it; nil takes
    #   the transport's own read timeout, false waits for ever
    # @yield [method, params] notifications delivered on the subscription
    # @return [MCPClient::Subscription]
    # @raise [MCPClient::Errors::CapabilityError] if the server is not a 2026-07-28 server
    def listen(notifications:, server: nil, ack_timeout: nil, &listener)
      srv = select_server(server)
      filter = MCPClient::Subscription.normalize_filter(notifications)
      if filter.key?('taskIds')
        unless tasks_extension?
          raise MCPClient::Errors::CapabilityError,
                'Task notifications (taskIds) require the tasks extension: pass ' \
                "extensions: ['#{MCPClient::JsonRpcCommon::TASKS_EXTENSION}'] to MCPClient::Client.new"
        end
        # The server must have negotiated the extension too (it answers a
        # taskIds filter from a non-declaring client with -32021).
        ensure_task_capability!(srv, 'listen')
      end

      srv.listen(notifications: notifications, ack_timeout: ack_timeout, &listener)
    end

    # Set the logging level on all connected servers (MCP 2025-06-18)
    # To set on a specific server, use: client.find_server('name').log_level = 'debug'
    # @param level [String] the log level ('debug', 'info', 'notice', 'warning', 'error',
    #   'critical', 'alert', 'emergency')
    # @return [Array<Hash>] results from servers
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    def log_level=(level)
      @servers.filter_map do |srv|
        # MCP lifecycle: only use capabilities that were successfully
        # negotiated — skip servers whose NEGOTIATED set lacks logging.
        # Unconnected servers proceed: the transport-level gate re-checks
        # after its handshake establishes the capability set.
        unless !capabilities_known?(srv) || srv.capability?('logging')
          @logger.debug("Skipping logging/setLevel for #{srv.name || srv.class.name}: " \
                        'logging capability not negotiated')
          next
        end

        srv.log_level = level
      end
    end

    private

    # Hand the host's identity and request metadata to a transport.
    # @param server [MCPClient::ServerBase] the transport
    # @param client_info [Hash, nil] Implementation info sent as clientInfo
    # @param request_meta [Hash, #call, nil] metadata merged into every request's _meta
    # @return [void]
    def configure_server_identity(server, client_info, request_meta)
      # Host-provided Implementation info for clientInfo (initialize on
      # legacy servers, per-request _meta on modern ones)
      server.client_info = client_info if client_info && server.respond_to?(:client_info=)
      server.request_meta = request_meta if request_meta && server.respond_to?(:request_meta=)
      return if @extensions.empty? || !server.respond_to?(:declare_extension)

      @extensions.each { |identifier, settings| server.declare_extension(identifier, settings) }
    end

    # @param extensions [Array, Hash, nil] the extensions option
    # @return [Hash{String => Hash}] identifier => settings
    def normalize_extensions(extensions)
      case extensions
      when nil then {}
      when Hash then extensions.to_h { |identifier, settings| [identifier.to_s, settings || {}] }
      when Array then extensions.to_h { |identifier| [identifier.to_s, {}] }
      else
        raise ArgumentError, 'extensions must be an Array of identifiers or a Hash of identifier => settings, ' \
                             "got #{extensions.class}"
      end
    end

    # @param srv [MCPClient::ServerBase]
    # @return [Boolean] whether the server negotiated an MCP 2026-07-28 revision
    def modern_server?(srv)
      srv.respond_to?(:modern?) && srv.modern?
    end

    # Whether every server's cached list of a kind is still fresh (MCP
    # 2026-07-28 caching: a stale list is re-fetched on access).
    # The parameters go first: reading them evaluates the host's request_meta
    # and the transport holds that evaluation, which the freshness check then
    # reuses instead of reading the callable a second time. Asking the other
    # way round released the held value in between, so a hit spent two
    # trace ids (or nonces) on a decision that sends nothing.
    # @param kind [Symbol] :tools, :prompts or :resources
    # @return [Boolean]
    def caches_fresh?(kind)
      servers.all? do |server|
        cache_params_current?(kind, server) && (!server.respond_to?(:cache_fresh?) || server.cache_fresh?(kind))
      end
    rescue StandardError
      # One server's check aborted -- an OAuth refresh that failed, a host
      # `request_meta` callable that raised -- so nothing is fetched from any
      # of them. Every server the loop had already passed is still holding
      # the evaluation this decision read for the fetch it would have made:
      # dropped here, all of them, or an unrelated request on this worker
      # thread would go out carrying that decision's tenant, baggage or nonce.
      release_held_request_meta
      raise
    end

    # The cache's items as one snapshot taken under the lock, when the cache
    # holds something and every server's slice is fresh for the parameters
    # its next request would carry.
    # @param kind [Symbol]
    # @param cache [Hash]
    # @return [Array, nil]
    def cached_snapshot(kind, cache)
      # Freshness consults the servers (a request_meta callable, host
      # middleware), which may clear this cache in turn: it runs outside the
      # lock, and the copy is served only when nothing changed meanwhile.
      version = @cache_mutex.synchronize { @cache_version }
      # An empty snapshot is a hit too: a server may list nothing, and its
      # entry says so for as long as it is fresh. What makes a hit is that
      # every server has filled its slice, not that the hash holds items.
      return nil unless @cache_mutex.synchronize { snapshot_complete?(kind, cache) }
      return nil unless caches_fresh?(kind)

      @cache_mutex.synchronize do
        # A cleanup that landed after the verdict replaced the transport
        # entries the slices came from; that check touches only the
        # transport's cache lock, so it can run under this one.
        next unless version == @cache_version && snapshot_complete?(kind, cache) && slices_still_current?(kind)

        cached_copies(cache)
      end
    end

    # Whether every server this client talks to has filled its slice of a
    # list cache (an empty list fills a slice as much as a long one does).
    # Called under {@cache_mutex}.
    # @param kind [Symbol]
    # @param cache [Hash] the kind's cache, to tell an empty snapshot apart
    # @return [Boolean]
    def snapshot_complete?(kind, cache)
      filled = @cache_filled[kind]
      return false if filled.nil?

      list = servers
      return false if list.empty? || !list.all? { |server| filled.key?(server) }
      # A snapshot with nothing in it is only a hit while a server says so
      # itself: a 2026-07-28 server bounds its empty list with a ttlMs, an
      # older one records no hint at all and keeps the client's previous
      # heuristic — ask again until something is listed.
      return true unless cache.empty?

      list.all? { |server| hinted_slice?(kind, server) }
    end

    # @param kind [Symbol]
    # @param server [MCPClient::ServerBase]
    # @return [Boolean] whether the entry behind this server's slice bounds
    #   its own freshness (the server sent a hint)
    def hinted_slice?(kind, server)
      server.respond_to?(:cache_entry_hinted?, true) && server.send(:cache_entry_hinted?, kind)
    end

    # Whether every server's slice of a kind still comes from the transport
    # entry it was recorded against (a cleanup or a replaced entry ends it).
    # @param kind [Symbol]
    # @return [Boolean]
    def slices_still_current?(kind)
      servers.all? do |server|
        next true unless server.respond_to?(:cache_entry_token, true)

        _fingerprint, token = @cache_params[kind][server]
        current = server.send(:cache_entry_token, kind)
        next current.nil? if token == MCPClient::ResultCaching::LEGACY_ENTRY
        next false unless !token.nil? && !current.nil? && current.equal?(token)

        # The verdict may be old by the time the copy is made: the entry's
        # own hint is re-read here (transport cache lock only).
        !server.respond_to?(:cache_entry_fresh?, true) || server.send(:cache_entry_fresh?, kind)
      end
    end

    # Replace one server's slice of a list cache under the lock: its previous
    # entries go, the fingerprint the fetch was made under is recorded, and
    # the block inserts the new entries.
    # @param kind [Symbol]
    # @param cache [Hash]
    # @param server [MCPClient::ServerBase]
    # @param fingerprint [String, nil]
    # @return [void]
    def replace_cached_slice(kind, cache, server, fingerprint)
      @cache_mutex.synchronize do
        @cache_version += 1
        drop_cached_entries(cache, server)
        # This server's slice now stands for its whole list, empty or not.
        (@cache_filled[kind] ||= {}.compare_by_identity)[server] = true
        if server.respond_to?(:current_params_fingerprint, true)
          # The slice is tied to the very transport entry its list came
          # from — its identity and the parameters that entry is bound to
          # (the request that produced it, which a first fetch may have made
          # with more than was known before connecting): a transport list
          # refreshed on its own (rotated credentials, a concurrent fetch)
          # replaces that entry, and the slice with it.
          token, bound = served_entry_for(kind, server)
          @cache_params[kind][server] = [bound || fingerprint, token]
        end
        yield
      end
    end

    # @return [Array(Object, String), nil] the identity of the transport
    #   entry the list this thread just obtained from the server came from,
    #   and the parameters fingerprint it is bound to
    def served_entry_for(kind, server)
      return nil unless server.respond_to?(:take_served_entry, true)

      # Taken rather than read: the note exists for this one tagging, and
      # leaving it behind would keep a slot on this thread for every
      # transport a long-lived worker has ever listed through.
      server.send(:take_served_entry, kind)
    end

    # @return [Boolean] whether the server's next request would carry the
    #   parameters its slice of the cache was filled under, and the transport
    #   still holds the entry that slice came from
    def cache_params_current?(kind, server)
      return true unless server.respond_to?(:current_params_fingerprint, true)

      fingerprint, token = @cache_params[kind][server]
      return false unless fingerprint == server.send(:current_params_fingerprint)
      return true unless server.respond_to?(:cache_entry_token, true)

      # A slice is identified by the very entry it came from; a legacy list
      # (no hint recorded) stays a hit only while the transport still holds
      # no entry, and a fetch that recorded no entry identifies nothing.
      current = server.send(:cache_entry_token, kind)
      return current.nil? if token == MCPClient::ResultCaching::LEGACY_ENTRY

      !token.nil? && !current.nil? && current.equal?(token)
    end

    # The cache's items as copies: a caller can neither change the cache nor
    # what later callers (and the x-mcp-header derivation) see.
    # @param cache [Hash]
    # @return [Array]
    def cached_copies(cache)
      cache.values.map { |item| MCPClient::DeepCopy.copy(item) }
    end

    # Whether the server's negotiated capability set is available yet.
    # @param srv [MCPClient::ServerBase] the server
    # @return [Boolean]
    def capabilities_known?(srv)
      srv.respond_to?(:capabilities) && !srv.capabilities.nil?
    end

    # Enforce the tasks.<operation> capability gate for a server (MCP
    # lifecycle: "Only use capabilities that were successfully negotiated").
    # When the negotiated capability set is not yet known, first trigger the
    # handshake with a cheap standard request (ping) and then re-apply the
    # gate against the freshly negotiated set, so a previously uninitialized
    # server that negotiates no tasks capability never receives the
    # prohibited request.
    # @param srv [MCPClient::ServerBase] the selected server
    # @param operation [String] the tasks sub-capability ('list' or 'cancel')
    # @return [void]
    # @raise [MCPClient::Errors::CapabilityError] if the negotiated set lacks the capability
    # Make the server's protocol era known (a cheap request triggers the
    # handshake or the server/discover probe); failures are left to the
    # request that follows.
    # @param srv [MCPClient::ServerBase]
    # @return [void]
    def probe_server_era(srv)
      return if capabilities_known?(srv) || !srv.respond_to?(:ping)

      srv.ping
    rescue MCPClient::Errors::MCPError
      nil
    end

    # @param strict [Boolean] surface an initialization failure instead of
    #   leaving it to the request (for operations that never send one on a
    #   server whose era is unknown)
    def ensure_task_capability!(srv, operation, strict: false)
      if !capabilities_known?(srv) && srv.respond_to?(:ping)
        begin
          srv.ping
        rescue MCPClient::Errors::MCPError
          # Initialization failed; fall through and let the task request
          # itself surface the failure via the normal error path.
          raise if strict
        end
      end

      # MCP 2026-07-28: tasks are the io.modelcontextprotocol/tasks extension.
      return ensure_tasks_extension!(srv) if modern_server?(srv)
      # Legacy tasks/get and tasks/result need only the tasks capability the
      # request itself is gated on server-side.
      return unless %w[list cancel].include?(operation)
      return if !capabilities_known?(srv) || srv.capability?('tasks', operation)

      raise MCPClient::Errors::CapabilityError,
            "Server #{srv.name || srv.class.name} did not declare the tasks.#{operation} capability"
    end

    # Wire this client's notification processing and the host's listeners onto
    # a transport.
    #
    # The cache invalidation goes on the transport's own invalidation hook,
    # which runs *before* a notification is delivered to a subscription's
    # listeners — so a listener reacting to a `list_changed` notification
    # re-fetches instead of reading the entry the notification just
    # invalidated. Everything else this client does with a notification is host
    # code or leads to it (logging, progress callbacks, task status), and stays
    # on the callback that runs last, behind the delivery. A transport that
    # emits no such hook — a host-supplied adapter written against the older
    # interface, say — keeps the invalidation on `on_notification`, ahead of
    # everything else there: it routes no subscriptions, so there is no
    # delivery for it to be ahead of.
    #
    # Which of the two it is cannot be answered by whether the transport *has*
    # the hook: every {MCPClient::ServerBase} subclass inherits it, so the
    # answer was yes for every custom adapter as well, and one that fans its
    # notifications out through `@notification_callback` alone — exactly what
    # the interface used to be — silently stopped invalidating anything. The
    # question is whether the hook actually *ran* for the notification in
    # hand, and the hook answers it itself: every path that emits it does so
    # immediately before the host callback and on the same thread
    # ({MCPClient::JsonRpcCommon#notify_cache_invalidation}), so a callback
    # that arrives without that mark is one nothing invalidated for. Having
    # the hook still decides whether one is *registered* — a host may supply
    # an object that is no ServerBase at all — but no longer decides who
    # invalidates.
    # @param server [MCPClient::ServerBase] the server to wire
    # @return [void]
    def register_notification_handlers(server)
      if server.class.method_defined?(:on_cache_invalidation)
        server.on_cache_invalidation do |method, _params|
          invalidate_caches_for_notification(server, method)
          Thread.current[CACHE_INVALIDATION_MARK] = [server, method]
        end
      end
      server.on_notification do |method, params|
        mark = Thread.current[CACHE_INVALIDATION_MARK]
        Thread.current[CACHE_INVALIDATION_MARK] = nil
        invalidate_caches_for_notification(server, method) unless mark_covers?(mark, server, method)
        # Default notification processing (e.g., logging, progress)
        process_notification(server, method, params)
        # Invoke user-defined listeners
        @notification_listeners.each { |cb| cb.call(server, method, params) }
      end
    end

    # @param mark [Array, nil] what the invalidation hook left behind
    # @param server [MCPClient::ServerBase] the transport routing now
    # @param method [String] the notification being routed
    # @return [Boolean] whether the mark is this notification's
    def mark_covers?(mark, server, method)
      mark.is_a?(Array) && mark[0].equal?(server) && mark[1] == method
    end

    # Drop the caches a notification invalidates.
    #
    # Registered on the transport's `on_cache_invalidation` hook, which runs
    # before the notification is delivered to a subscription's listeners — so a
    # listener that reacts to a `list_changed` notification by calling
    # `list_tools` (or the prompt/resource equivalents) re-fetches instead of
    # reading the entry the notification just invalidated. It used to ride on
    # `on_notification`, which round 10 moved to the end of the routing order
    # for good reason: that callback is host code and may block the very reader
    # the delivery came from. Only the cache drops moved forward; everything
    # else {#process_notification} does still runs behind the delivery.
    # @param server [MCPClient::ServerBase] the server that emitted it
    # @param method [String] JSON-RPC notification method
    # @return [void]
    def invalidate_caches_for_notification(server, method)
      server_id = notification_server_id(server)
      case method
      when 'notifications/tools/list_changed'
        logger.warn("[#{server_id}] Tool list has changed, clearing tool cache")
        @cache_mutex.synchronize do
          @cache_version += 1
          @tool_cache.clear
          @cache_params.delete(:tools)
          @cache_filled.delete(:tools)
        end
      when 'notifications/prompts/list_changed'
        logger.warn("[#{server_id}] Prompt list has changed, clearing prompt cache")
        @cache_mutex.synchronize do
          @cache_version += 1
          @prompt_cache.clear
          @cache_params.delete(:prompts)
          @cache_filled.delete(:prompts)
        end
      when 'notifications/resources/list_changed'
        logger.warn("[#{server_id}] Resource list has changed, clearing resource cache")
        @cache_mutex.synchronize do
          @cache_version += 1
          @resource_cache.clear
          @cache_params.delete(:resources)
          @cache_filled.delete(:resources)
        end
      end
    end

    # @param server [MCPClient::ServerBase] the server that emitted a notification
    # @return [String] the identity used to prefix its log lines
    def notification_server_id(server)
      server.name ? "#{server.class}[#{server.name}]" : server.class.to_s
    end

    # Process incoming JSON-RPC notifications with default handlers
    # @param server [MCPClient::ServerBase] the server that emitted the notification
    # @param method [String] JSON-RPC notification method
    # @param params [Hash] parameters for the notification
    # @return [void]
    def process_notification(server, method, params)
      server_id = notification_server_id(server)
      case method
      when 'notifications/tools/list_changed', 'notifications/prompts/list_changed',
           'notifications/resources/list_changed'
        # Already handled, ahead of the delivery to any subscription listener
        # (see {#invalidate_caches_for_notification}).
        nil
      when 'notifications/resources/updated'
        logger.warn("[#{server_id}] Resource #{params['uri']} updated")
      when 'notifications/message'
        # MCP 2025-06-18: Handle logging messages from server
        handle_log_message(server_id, params)
      when 'notifications/tasks/status', 'notifications/tasks'
        # MCP 2025-11-25: task status update (params are a flat Task);
        # MCP 2026-07-28 tasks extension: notifications/tasks carries a
        # DetailedTask (only ever on a subscriptions/listen stream).
        handle_task_status_notification(server_id, params)
      when 'notifications/subscriptions/acknowledged'
        # MCP 2026-07-28: the transport already recorded the acknowledged
        # filter on the Subscription; log for observability.
        sub_id = params&.dig('_meta', 'io.modelcontextprotocol/subscriptionId')
        logger.debug("[#{server_id}] Subscription #{sanitize_peer_log_text(sub_id.to_s)} acknowledged")
      when 'notifications/cancelled'
        # MCP 2025-11-25 cancellation utility: the server cancelled one of its
        # own in-flight requests (sampling/elicitation). Server-request
        # dispatch is synchronous per transport, so by the time this arrives
        # the handler has usually completed; receivers MAY ignore
        # cancellations they cannot honor — log for observability. On MCP
        # 2026-07-28 it only ever tears down a subscriptions/listen stream,
        # which the transport handled before this point.
        request_id = sanitize_peer_log_text(params&.dig('requestId').to_s)
        reason = sanitize_peer_log_text((params&.dig('reason') || 'no reason given').to_s)
        logger.debug("[#{server_id}] Server cancelled request #{request_id}: #{reason}")
      when 'notifications/progress'
        handle_progress_notification(server_id, params)
      else
        # Log unknown notification types for debugging purposes
        logger.debug("[#{server_id}] Received unknown notification: #{method} - #{params}")
      end
    end

    # Handle logging message notification from server (MCP 2025-06-18)
    # @param server_id [String] server identifier for log prefix
    # @param params [Hash] log message params (level, logger, data)
    # @return [void]
    # Route a notifications/progress message to the callback registered for
    # its progressToken; unknown or stale tokens are debug-logged and dropped
    # (MCP: "Senders and receivers SHOULD track active progress tokens").
    # @param server_id [String] identity of the emitting server (for logs)
    # @param params [Hash, nil] notification params
    # @return [void]
    def handle_progress_notification(server_id, params)
      token = params && params['progressToken']
      callback = @progress_mutex.synchronize { @progress_callbacks[token] }
      unless callback
        logger.debug("[#{server_id}] Progress for unknown or completed token #{token.inspect}")
        return
      end

      callback.call(params['progress'], params['total'], params['message'])
    rescue StandardError => e
      logger.warn("[#{server_id}] Progress callback error: #{e.message}")
    end

    # Attach progress tracking to an outgoing request when requested.
    # @param parameters [Hash] user arguments
    # @param progress [#call, nil] optional progress callback
    # @return [Array(Hash, String|nil)] possibly-augmented parameters and token
    def setup_progress_tracking(parameters, progress)
      return [parameters, nil] unless progress

      token = generate_progress_token
      register_progress_callback(token, progress)
      [attach_progress_token(parameters, token), token]
    end

    # @return [String] a unique progress token for an outgoing request
    def generate_progress_token
      "rb-mcp-#{SecureRandom.hex(8)}"
    end

    # @param parameters [Hash] user arguments (not mutated)
    # @param token [String] progress token
    # @return [Hash] parameters with _meta.progressToken merged in
    def attach_progress_token(parameters, token)
      params = parameters.dup
      meta = (params['_meta'] || params[:_meta] || {}).merge('progressToken' => token)
      params.delete(:_meta)
      params['_meta'] = meta
      params
    end

    # @param token [String] progress token
    # @param callback [#call] receives (progress, total, message)
    # @return [void]
    def register_progress_callback(token, callback)
      @progress_mutex.synchronize { @progress_callbacks[token] = callback }
    end

    # @param token [String] progress token
    # @return [void]
    def unregister_progress_callback(token)
      @progress_mutex.synchronize { @progress_callbacks.delete(token) }
    end

    def handle_log_message(server_id, params)
      level = params['level'] || 'info'
      logger_name = params['logger']
      data = params['data']

      # Format the message. Both the logger name and the payload come from the
      # remote server, so both are sanitized before they reach the host log.
      prefix = logger_name ? "[#{server_id}:#{sanitize_peer_log_text(logger_name.to_s)}]" : "[#{server_id}]"
      message = sanitize_peer_log_text(data.is_a?(String) ? data : data.inspect)

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
        # An out-of-enum level is peer-controlled text like any other: it must
        # be sanitized and capped, or it becomes the log-forging vector the
        # sanitizing of `data` was added to close.
        logger.info("#{prefix} [#{sanitize_peer_log_text(level.to_s)}] #{message}")
      end
    end

    # Make peer-supplied log text safe to write to the host log: control
    # characters (notably newlines, which would let a server forge additional
    # log entries) are escaped, and the result is capped.
    # @param text [String] the peer-supplied text
    # @return [String] sanitized, length-bounded text
    def sanitize_peer_log_text(text)
      escaped = text.gsub(/[ -]/) { |c| format('\\x%02X', c.ord) }
      return escaped if escaped.length <= MAX_PEER_LOG_MESSAGE_LENGTH

      "#{escaped[0, MAX_PEER_LOG_MESSAGE_LENGTH]}... (truncated from #{escaped.length} chars)"
    end

    # Copy of a server config with credential-bearing values replaced, for
    # safe logging. Nested hashes (headers, env) have every value redacted;
    # sensitive scalars are replaced outright.
    # @param config [Hash, Object] a server configuration
    # @return [Hash, Object] a redacted copy (non-Hash input is returned as-is)
    def redact_config(config)
      return config unless config.is_a?(Hash)

      config.to_h do |key, value|
        next [key, value] unless SENSITIVE_CONFIG_KEYS.include?(key.to_s.downcase.to_sym)

        redacted = value.is_a?(Hash) ? value.transform_values { REDACTED } : REDACTED
        [key, redacted]
      end
    end

    # Resolve which server a task operation targets.
    #
    # Task IDs are only unique within the server that issued them, so silently
    # defaulting to the first configured server can poll, read or cancel an
    # unrelated task on the wrong server. Resolution order:
    #   1. an explicit server: argument wins;
    #   2. a Task handle carries the server that issued it;
    #   3. a bare ID with exactly one configured server is unambiguous;
    #   4. anything else is ambiguous and fails closed.
    # @param task [String, MCPClient::Task] the task or its ID
    # @param server_arg [Integer, String, Symbol, MCPClient::ServerBase, nil] explicit selector
    # @param operation [String] calling method name, for the error message
    # @return [MCPClient::ServerBase]
    # @raise [ArgumentError] when the target server cannot be determined
    def select_task_server(task, server_arg, operation)
      # nil, not falsiness: `server: false` is an invalid selector that
      # select_server rejects with ArgumentError, and treating it as "omitted"
      # would silently route a read or a cancel somewhere instead of failing.
      return select_server(server_arg) unless server_arg.nil?
      return task.server if task.is_a?(MCPClient::Task) && task.server
      return select_server(nil) if @servers.size <= 1

      raise ArgumentError,
            "#{operation} is ambiguous with multiple servers configured: task IDs are only unique per server. " \
            'Pass the Task returned by call_tool_as_task, or name the server explicitly ' \
            "(e.g. #{operation}(id, server: 'name'))."
    end

    # @param task [String, MCPClient::Task] a task or its ID
    # @return [String] the task ID
    def task_identifier(task)
      return task unless task.is_a?(MCPClient::Task)

      unless task.remote?
        raise MCPClient::Errors::TaskError,
              'The task was completed locally (the server answered synchronously); there is nothing to fetch, ' \
              'update or cancel'
      end
      task.task_id
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

    # Validate a tools/call result's structuredContent against the tool's
    # declared outputSchema (MCP 2025-11-25 server/tools spec: "Clients SHOULD
    # validate structured results against this schema"; a tool declaring an
    # outputSchema must return structuredContent in successful results). Error
    # results (isError: true) are exempt: the conformance requirements apply to
    # successful results only. Validation covers the common JSON Schema
    # keywords; the full 2020-12 vocabulary is out of scope (see
    # MCPClient::SchemaValidator), and when the schema uses keywords outside
    # that subset a partial-coverage warning is logged in both modes so :strict
    # never silently passes what it cannot fully check. On a violation
    # (mismatch or missing structuredContent) a warning is always logged, and
    # in :strict mode a ValidationError is raised as well.
    # @param tool [MCPClient::Tool] the tool that produced the result
    # @param result [Object] the raw tools/call result
    # @return [Object] the result, unchanged
    # @raise [MCPClient::Errors::ValidationError] in :strict mode when structuredContent
    #   is missing from a successful result or does not match the schema
    def validate_structured_content!(tool, result)
      return result unless tool.structured_output? && result.is_a?(Hash)
      return result if result['isError'] || result[:isError]

      warn_partial_schema_coverage(tool)

      structured = result.key?('structuredContent') ? result['structuredContent'] : result[:structuredContent]
      if structured.nil?
        handle_structured_content_violation(
          "Tool '#{tool.name}' declares an output schema but its successful result carries no structuredContent " \
          '(required by the MCP 2025-11-25 tools spec)'
        )
        return result
      end

      errors = MCPClient::SchemaValidator.validate(structured, tool.output_schema)
      unless errors.empty?
        handle_structured_content_violation(
          "Structured content for tool '#{tool.name}' does not match its output schema: #{errors.join('; ')}"
        )
      end
      result
    end

    # Warn (in both :warn and :strict modes) when a tool's output schema uses
    # JSON Schema keywords the built-in validator cannot evaluate, so partial
    # coverage is never silent.
    # @param tool [MCPClient::Tool] the tool whose output schema is being used
    # @return [void]
    def warn_partial_schema_coverage(tool)
      unsupported = MCPClient::SchemaValidator.unsupported_keywords(tool.output_schema)
      return if unsupported.empty?

      @logger.warn(
        "Structured content check for tool '#{tool.name}': validation is partial: schema uses unsupported " \
        "keywords: #{unsupported.join(', ')} (full JSON Schema 2020-12 evaluation is not implemented, so " \
        'conforming-looking data may still violate the schema)'
      )
    end

    # Log a structured-content conformance violation and, in :strict mode,
    # raise it as a ValidationError.
    # @param message [String] the violation description
    # @return [void]
    # @raise [MCPClient::Errors::ValidationError] in :strict mode
    def handle_structured_content_violation(message)
      @logger.warn(message)
      raise MCPClient::Errors::ValidationError, message if @validate_structured_content == :strict
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

    # The definition the transport's own tools/call request went out under,
    # taken from the transport so it is spent on this one re-resolve.
    #
    # It is read back rather than re-listed because a list is only ever the
    # transport's *current* answer: a tools/list_changed that raced the call
    # has already replaced it, and the server answered under the definition
    # the request carried.
    # @param server [MCPClient::ServerBase] the transport the call went to
    # @param tool_name [String] the tool being re-resolved
    # @return [MCPClient::Tool, nil] the definition the answering attempt went
    #   out under, or nil when the transport recorded none (or recorded that
    #   its list did not carry the tool), in which case the definition the
    #   caller resolved before the call stands
    def called_tool_definition(server, tool_name)
      return nil unless server.respond_to?(:take_called_tool_definition, true)

      server.send(:take_called_tool_definition, tool_name.to_s)&.first
    end

    # Reject a plain (synchronous) call for a tool whose execution.taskSupport is
    # 'required'. A compliant server would reject a non-task-augmented tools/call
    # for such a tool, so fail fast and point the caller at call_tool_as_task.
    # @param tool [MCPClient::Tool] the resolved tool
    # @param tool_name [String] the tool name (for the message)
    # @raise [MCPClient::Errors::ToolCallError] if the tool requires task execution
    def reject_task_required!(tool, tool_name)
      # Tasks Tool-Level Negotiation rule 1: without tasks.requests.tools.call
      # in the server capabilities, taskSupport is disregarded entirely and
      # the tool is invoked as a plain call.
      return unless tool.task_required?
      # MCP 2026-07-28: the server alone decides whether a call becomes a
      # task, and Client#call_tool drives that task to its result.
      return if modern_server?(tool.server)
      return unless server_supports_task_tool_call?(tool.server)

      raise MCPClient::Errors::ToolCallError,
            "Tool '#{tool_name}' requires task-augmented execution; call it with call_tool_as_task instead"
    end

    # Whether a server advertised support for task-augmented tools/call, i.e.
    # capabilities.tasks.requests.tools.call.
    # @param srv [MCPClient::ServerBase] the server
    # @return [Boolean]
    def server_supports_task_tool_call?(srv)
      return srv.capability?('extensions', MCPClient::JsonRpcCommon::TASKS_EXTENSION) if modern_server?(srv)

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
    # @param modern [Boolean] MCP 2026-07-28: an invalid/nonexistent taskId is -32602
    # @param method [String, nil] the request that failed: on 2026-07-28 servers -32602 always means an
    #   unknown task for tasks/get, while tasks/update and tasks/cancel may use it for bad params too
    def task_error_from(error, task_id, action, modern: false, method: nil)
      shown = sanitize_peer_log_text(task_id.to_s)
      not_found = error.message.match?(/not found|unknown task|expired/i) ||
                  (modern && error.respond_to?(:code) && error.code == MCPClient::Errors::Codes::INVALID_PARAMS &&
                   (method == 'tasks/get' || !error.message.match?(/inputResponses|params/i)))
      return MCPClient::Errors::TaskNotFound.new("Task '#{shown}' not found") if not_found

      MCPClient::Errors::TaskError.new("Error #{action} task '#{shown}': #{sanitize_peer_log_text(error.message)}")
    end

    # Handle a notifications/tasks/status notification (MCP 2025-11-25).
    # The params are a flat Task.
    # @param server_id [String] server identifier for the log prefix
    # @param params [Hash] the flat task params
    # @return [void]
    def handle_task_status_notification(server_id, params)
      task = MCPClient::Task.from_json(params, detailed: true)
      logger.info("[#{server_id}] Task #{sanitize_peer_log_text(task.task_id.to_s)} status: #{task.status}")
    rescue StandardError => e
      logger.debug("[#{server_id}] Failed to parse task status notification: #{e.message}")
    end

    # Remove one server's entries from a client-level cache.
    # @param cache [Hash] the cache keyed by #cache_key_for
    # @param server [MCPClient::ServerBase]
    # @return [void]
    def drop_cached_entries(cache, server)
      prefix = "#{server.object_id}:"
      cache.delete_if { |key, _| key.start_with?(prefix) }
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
        @logger.warn("Rejecting elicitation request with unsupported mode '#{sanitize_peer_log_text(mode.to_s)}'")
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
        # Same reasoning as the sampling path: the handler's exception text is
        # host-internal and must not cross to the server. Because this rescue
        # runs inside the client, the transports' constant-message rescues
        # never see it — so it has to be constant here.
        @logger.error("Elicitation handler error: #{e.message}")
        @logger.debug(e.backtrace.join("\n"))
        jsonrpc_error_result(-32_603, 'Elicitation handler error')
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
        unless schema_errors.empty?
          @logger.warn("Elicitation schema validation warnings: #{sanitize_peer_log_text(schema_errors.join('; '))}")
        end
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
      response = if (params['mode'] || 'form') == 'url'
                   normalize_url_elicitation_result(result)
                 else
                   normalize_elicitation_result(result)
                 end

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

    # A URL-mode elicitation reports the user's consent to open the URL, so
    # only an explicit answer counts: `true` or an ElicitResult with an
    # `action` of accept/decline/cancel. Anything else — a bare value, a form
    # style content hash, nil — is not consent and is answered with cancel.
    # @param result [Object] handler result
    # @return [Hash] normalized ElicitResult without content
    def normalize_url_elicitation_result(result)
      return { 'action' => 'accept' } if result == true

      action = result.is_a?(Hash) ? (result['action'] || result[:action]) : nil
      if %w[accept decline cancel].include?(action.to_s)
        # ElicitResult carries `_meta` in every mode; only `content` is
        # form-mode-specific, and format_elicitation_response strips it.
        meta = result['_meta'] || result[:_meta]
        return { 'action' => action.to_s, '_meta' => meta }.compact
      end

      unless result.nil? || result == false
        @logger.warn('URL-mode elicitation handler gave no explicit action; answering cancel (consent is explicit)')
      end
      { 'action' => 'cancel' }
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
        meta = result['_meta'] || result[:_meta]
        normalised_action_response({ 'action' => action.to_s, 'content' => content, '_meta' => meta }.compact)
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

      @logger.warn("Unknown elicitation action '#{sanitize_peer_log_text(action.to_s)}', defaulting to accept")
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

    # Whether a server may be told the roots list changed. MCP forbids using a
    # capability that was not declared during initialization, so the
    # notification goes only to sessions whose declared client capabilities
    # include roots: a transport that registers the handlers for the modern
    # multi round-trip pattern but has no server-request channel to serve
    # them on (plain HTTP on a legacy session) declares none, however it
    # answers respond_to?.
    # @param server [Object] an MCP server transport
    # @return [Boolean]
    def roots_list_changed_recipient?(server)
      return false unless server.respond_to?(:on_roots_list_request)
      # notifications/roots/list_changed was removed in MCP 2026-07-28: a
      # modern server reads roots through the multi round-trip pattern when it
      # needs them, and has no channel to be told they changed.
      return false if server.respond_to?(:modern?) && server.modern?
      return true unless server.respond_to?(:client_capabilities)

      server.client_capabilities.key?('roots')
    end

    # Send notification to all servers that roots have changed (MCP 2025-06-18)
    # @return [void]
    def notify_roots_changed
      @servers.each do |server|
        next unless roots_list_changed_recipient?(server)

        begin
          server.rpc_notify('notifications/roots/list_changed', {})
        rescue StandardError => e
          server_id = server.name ? "#{server.class}[#{server.name}]" : server.class
          @logger.warn("[#{server_id}] Failed to send roots/list_changed notification: #{e.message}")
        end
      end
    end

    # Handle sampling/createMessage request from server (MCP 2025-11-25)
    # @param _request_id [String, Integer] the JSON-RPC request ID (unused, kept for callback signature)
    # @param params [Hash] the sampling parameters
    # @return [Hash] the sampling response (role, content, model, stopReason)
    def handle_sampling_request(_request_id, params)
      # Without a handler the sampling capability was never declared, so the
      # request targets an unsupported method: answer -32601 (Method not
      # found) rather than -1, which sampling.mdx § Error Handling reserves
      # for "User rejected sampling request".
      unless @sampling_handler
        @logger.warn('Received sampling request but no sampling handler is configured')
        return jsonrpc_error_result(-32_601, 'Sampling not supported: no sampling handler configured')
      end

      # SEP-1577 (schema.ts CreateMessageRequestParams.tools/.toolChoice):
      # "The client MUST return an error if this field is provided but
      # ClientCapabilities.sampling.tools is not declared." -32602 is the
      # Invalid params code used by sampling.mdx § Error Handling.
      if (params.key?('tools') || params.key?('toolChoice')) && !@sampling_supports_tools
        @logger.warn('Rejecting tool-enabled sampling request: sampling.tools capability not declared')
        return jsonrpc_error_result(-32_602,
                                    'Invalid params: tools/toolChoice provided but the sampling.tools ' \
                                    'capability was not declared')
      end

      messages = params['messages'] || []
      model_preferences = normalize_model_preferences(params['modelPreferences'])
      system_prompt = params['systemPrompt']
      max_tokens = params['maxTokens']

      begin
        # Call the user-defined handler with parameters based on arity
        result = call_sampling_handler(messages, model_preferences, system_prompt, max_tokens, params)

        # Validate and format response
        validate_sampling_response(result)
      rescue StandardError => e
        @logger.error("Sampling handler error: #{e.message}")
        @logger.debug(e.backtrace.join("\n"))
        # A handler exception is an internal client failure (-32603), not a
        # user rejection: sampling.mdx § Error Handling reserves -1 for
        # "User rejected sampling request". The exception message itself is
        # host-internal (file paths, connection strings, library internals)
        # and stays in the local log rather than crossing to the server.
        jsonrpc_error_result(-32_603, 'Sampling error')
      end
    end

    # Call sampling handler with appropriate arity
    # @param messages [Array] the messages
    # @param model_preferences [Hash, nil] normalized model preferences
    # @param system_prompt [String, nil] system prompt
    # @param max_tokens [Integer, nil] max tokens
    # @param params [Hash] the complete sampling/createMessage request params;
    #   handlers whose fifth parameter is required, optional, or part of a
    #   rest argument receive this hash verbatim, so they can read
    #   includeContext, temperature, stopSequences, metadata, the SEP-1577
    #   tools/toolChoice fields, _meta, and any future params
    # @return [Hash] the handler result
    def call_sampling_handler(messages, model_preferences, system_prompt, max_tokens, params)
      args = [messages, model_preferences, system_prompt, max_tokens, params]
      @sampling_handler.call(*args.first(sampling_handler_arg_count))
    end

    # Number of the five positional sampling arguments the handler can accept.
    # Arity alone cannot size variable-arity handlers: lambdas with optional
    # or rest parameters report a negative arity, and non-lambda procs with
    # optional parameters report their mandatory minimum as a nonnegative
    # arity (proc { |m, p = nil, s = nil, t = nil, extra = nil| }.arity == 1).
    # Normalizing either to the minimum required count would starve the
    # handler of the raw params (including the SEP-1577 tools/toolChoice
    # fields), so any handler whose parameters include :opt or :rest entries
    # (or whose arity is negative) is sized from Proc#parameters instead:
    # each :req/:opt parameter accepts one argument and a :rest accepts the
    # full list. Plain fixed-arity handlers keep arity-based sizing.
    # @return [Integer] how many arguments to pass, capped at 5
    def sampling_handler_arg_count
      parameters = @sampling_handler.parameters
      return 5 if parameters.any? { |type, _name| type == :rest }

      if @sampling_handler.arity.negative? || parameters.any? { |type, _name| type == :opt }
        return [parameters.count { |type, _name| %i[req opt].include?(type) }, 5].min
      end

      [@sampling_handler.arity, 5].min
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
      # A nil handler result is the host's rejection signal; -1 is the code
      # sampling.mdx § Error Handling assigns to "User rejected sampling
      # request" (internal failures use -32603 instead, see
      # handle_sampling_request).
      return jsonrpc_error_result(-1, 'Sampling rejected') if result.nil?

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

      # Set defaults for missing fields. ToolUseContent blocks (SEP-1577) are
      # passed through verbatim; when the handler omits stopReason for them,
      # default to "toolUse" per the CreateMessageResult stopReason values.
      result['role'] ||= 'assistant'
      result['model'] ||= 'unknown'
      result['stopReason'] ||= tool_use_content?(result['content']) ? 'toolUse' : 'endTurn'

      # Normalize content if it's a string
      result['content'] = { 'type' => 'text', 'text' => result['content'] } if result['content'].is_a?(String)

      result
    end

    # Whether sampling response content contains ToolUseContent blocks (MCP 2025-11-25 / SEP-1577)
    # @param content [Object] the content field of a CreateMessageResult
    # @return [Boolean] true when any content block has type "tool_use"
    def tool_use_content?(content)
      blocks = content.is_a?(Array) ? content : [content]
      blocks.any? do |block|
        block.is_a?(Hash) && (block['type'] == 'tool_use' || block[:type] == 'tool_use')
      end
    end
  end
end
