# frozen_string_literal: true

module MCPClient
  # Base class for MCP servers - serves as the interface for different server implementations
  class ServerBase
    # @!attribute [r] name
    #   @return [String] the name of the server
    attr_reader :name

    # Initialize the server with a name
    # @param name [String, nil] server name
    # Server-declared instructions from the initialize result, if any
    # @return [String, nil]
    attr_reader :instructions

    # Host-supplied Implementation info sent as clientInfo during initialize
    # (MCP 2025-11-25 Implementation: name, version, plus optional title,
    # description, websiteUrl, icons). Defaults to the gem's identity.
    # @param info [Hash] implementation info; must include name and version
    # @raise [ArgumentError] when name or version is missing
    def client_info=(info)
      raise ArgumentError, 'client_info must include name' unless info['name'] || info[:name]
      raise ArgumentError, 'client_info must include version' unless info['version'] || info[:version]

      @client_info = info.transform_keys(&:to_s)
    end

    def initialize(name: nil)
      @name = name
    end

    # Initialize a connection to the MCP server
    # @return [Boolean] true if connection successful
    def connect
      raise NotImplementedError, 'Subclasses must implement connect'
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

    # List all prompts available from the MCP server
    # @return [Array<MCPClient::Prompt>] list of available prompts
    def list_prompts
      raise NotImplementedError, 'Subclasses must implement list_prompts'
    end

    # Get a prompt with the given parameters
    # @param prompt_name [String] the name of the prompt to get
    # @param parameters [Hash] the parameters to pass to the prompt
    # @return [Object] the result of the prompt interpolation
    def get_prompt(prompt_name, parameters)
      raise NotImplementedError, 'Subclasses must implement get_prompt'
    end

    # List all resources available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resources array and optional nextCursor
    def list_resources(cursor: nil)
      raise NotImplementedError, 'Subclasses must implement list_resources'
    end

    # Read a resource by its URI
    # @param uri [String] the URI of the resource to read
    # @return [Array<MCPClient::ResourceContent>] array of resource contents
    def read_resource(uri)
      raise NotImplementedError, 'Subclasses must implement read_resource'
    end

    # List all resource templates available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resourceTemplates array and optional nextCursor
    def list_resource_templates(cursor: nil)
      raise NotImplementedError, 'Subclasses must implement list_resource_templates'
    end

    # Subscribe to resource updates
    # @param uri [String] the URI of the resource to subscribe to
    # @return [Boolean] true if subscription successful
    def subscribe_resource(uri)
      raise NotImplementedError, 'Subclasses must implement subscribe_resource'
    end

    # Unsubscribe from resource updates
    # @param uri [String] the URI of the resource to unsubscribe from
    # @return [Boolean] true if unsubscription successful
    def unsubscribe_resource(uri)
      raise NotImplementedError, 'Subclasses must implement unsubscribe_resource'
    end

    # Get server capabilities
    # MCP 2025-11-25 tasks: all messages related to a task MUST carry the
    # io.modelcontextprotocol/related-task key in _meta. Reserved key name:
    RELATED_TASK_META_KEY = 'io.modelcontextprotocol/related-task'

    # Echo the related-task _meta of an incoming server request onto the
    # outgoing result, so responses to task-related requests (elicitation or
    # sampling during input_required) stay associated with their task.
    # @param result [Hash] the outgoing JSON-RPC result payload
    # @param params [Hash, nil] the incoming request params
    # @return [Hash] result with related-task _meta merged when applicable
    def merge_related_task_meta(result, params)
      related = params.is_a?(Hash) ? params.dig('_meta', RELATED_TASK_META_KEY) : nil
      return result unless related && result.is_a?(Hash) && !result.key?('error')

      meta = (result['_meta'] || {}).merge(RELATED_TASK_META_KEY => related)
      result.merge('_meta' => meta)
    end

    # @return [Hash, nil] server capabilities
    def capabilities
      raise NotImplementedError, 'Subclasses must implement capabilities'
    end

    # Whether the server declared the given (possibly nested) capability
    # during initialization.
    # @param path [Array<String, Symbol>] capability key path, e.g. 'logging'
    #   or 'resources', 'subscribe'
    # @return [Boolean]
    def capability?(*path)
      node = begin
        capabilities
      rescue NotImplementedError
        nil
      end
      path.each do |key|
        return false unless node.is_a?(Hash)

        node = node[key.to_s]
      end
      !node.nil? && node != false
    end

    # Raise unless the server negotiated the given capability (MCP lifecycle:
    # "Only use capabilities that were successfully negotiated").
    # @param path [Array<String, Symbol>] capability key path
    # @param method [String] the JSON-RPC method the caller wants to send
    # @raise [MCPClient::Errors::CapabilityError]
    def require_capability!(*path, method:)
      return if capability?(*path)

      raise MCPClient::Errors::CapabilityError,
            "Server #{name || self.class.name} did not declare the #{path.join('.')} capability " \
            "required for #{method}"
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

    # Open a long-lived notification stream (MCP 2026-07-28 subscriptions/listen).
    # @param notifications [Hash] the SubscriptionFilter (tools_list_changed,
    #   prompts_list_changed, resources_list_changed, resource_subscriptions,
    #   task_ids — snake_case or camelCase)
    # @param ack_timeout [Numeric, false, nil] seconds to wait for the
    #   server's acknowledgment before giving the listen up; nil takes the
    #   transport's own read timeout, false waits for ever
    # @yield [method, params] notifications delivered on the subscription
    # @return [MCPClient::Subscription]
    def listen(notifications:, ack_timeout: nil, &listener)
      raise NotImplementedError, 'Subclasses must implement listen'
    end

    # Cancel a subscription opened with {#listen}.
    # @param subscription [MCPClient::Subscription]
    # @return [void]
    def cancel_subscription(subscription)
      raise NotImplementedError, 'Subclasses must implement cancel_subscription'
    end

    # @return [Logger] the transport logger
    attr_reader :logger

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

    # Register a callback for the caches a notification invalidates, run
    # *before* the notification is delivered to a subscription's listeners.
    #
    # A host layered above the transport (MCPClient::Client) keeps caches of
    # its own, and they have to be gone by the time a listener reacting to a
    # `list_changed` notification calls the cached list method. `on_notification`
    # cannot serve for that: it is the last routing step, deliberately after
    # the delivery, because it is host code that may block on the very reader
    # the delivery came from. So the invalidation gets a hook of its own, ahead
    # of the delivery, and only the invalidation goes on it.
    # @yield [method, params] invoked before the notification is delivered
    # @return [void]
    # @see MCPClient::JsonRpcCommon#notify_cache_invalidation for where it runs
    def on_cache_invalidation(&block)
      @cache_invalidation_callback = block
    end

    # Map a resources/read error response to ResourceNotFound. MCP 2026-07-28
    # (server/resources.mdx "Error Handling"): a missing resource is reported
    # with -32602 (Invalid params); "for backwards compatibility, clients
    # SHOULD also accept -32002 as a resource not found error".
    # @param uri [String] the requested resource URI
    # @param error [MCPClient::Errors::ServerError] the server's error response
    # @return [MCPClient::Errors::ResourceNotFound]
    def resource_not_found_error(uri, error)
      MCPClient::Errors::ResourceNotFound.new("Resource '#{uri}' not found: #{error.message}")
    end

    # Whether a resources/read error response means the resource does not
    # exist, given this session's protocol era.
    # @param error [MCPClient::Errors::ServerError] the server's error response
    # @return [Boolean]
    def resource_not_found_response?(error)
      modern = respond_to?(:modern?) && modern?
      MCPClient::Errors::Codes.resource_not_found_code?(error.code, modern: modern)
    end

    # Safety bound on the number of pages followed when auto-paginating a
    # cursor-based list operation, to protect against a server that returns
    # a nextCursor indefinitely.
    MAX_LIST_PAGES = 1000

    protected

    # Follow cursor-based pagination across pages, collecting every item.
    #
    # Yields the current cursor (nil for the first page) and expects the block
    # to return a two-element array: [items_for_this_page, next_cursor]. The
    # loop stops when next_cursor is nil or empty, when a cursor repeats
    # (malformed server), or when MAX_LIST_PAGES pages have been fetched.
    #
    # @param kind [String] label used in diagnostic log messages
    # @yieldparam cursor [String, nil] cursor for the page to fetch
    # @yieldreturn [Array(Array, String), Array(Array, nil)] page items and next cursor
    # @return [Array] all items collected across pages
    def collect_paginated(kind = 'items')
      items = []
      cursor = nil
      seen_cursors = {}
      pages = 0

      loop do
        page_items, next_cursor = yield(cursor)
        items.concat(Array(page_items))
        pages += 1

        break if next_cursor.nil? || next_cursor.to_s.empty?

        if seen_cursors[next_cursor]
          @logger.warn("Pagination for #{kind} stopped: server returned a repeated cursor #{next_cursor.inspect}")
          break
        end
        if pages >= MAX_LIST_PAGES
          @logger.warn("Pagination for #{kind} stopped after #{pages} pages (safety bound reached)")
          break
        end

        seen_cursors[next_cursor] = true
        cursor = next_cursor
      end

      items
    end

    # Fetch a full, cursor-paginated list result via rpc_request, following
    # nextCursor across pages until the server stops returning one.
    #
    # Accepts either a spec-shaped Hash ({ key => [...], 'nextCursor' => ... })
    # or, leniently, a bare Array (a single unpaginated page). A response that
    # is neither (e.g. a null/missing result or a scalar) is a malformed list
    # response and raises, rather than being silently treated as an empty list.
    #
    # @param method [String] the list method, e.g. 'tools/list'
    # @param key [String] the result array key, e.g. 'tools'
    # @return [Array<Hash>] all raw item hashes collected across pages
    # @raise [MCPClient::Errors::TransportError] if a page result is not a Hash or Array
    def request_paginated_list(method, key)
      pages = []
      received_ats = []
      contexts = []
      fingerprints = []
      epoch = cache_epoch if respond_to?(:cache_epoch, true)
      items = collect_paginated(key) do |cursor|
        params = cursor ? { cursor: cursor } : {}
        result = rpc_request(method, params)
        pages << result
        received_ats << monotonic_now if respond_to?(:monotonic_now, true)
        contexts << (respond_to?(:request_authorization_context, true) ? request_authorization_context : nil)
        fingerprints << (respond_to?(:request_params_fingerprint, true) ? request_params_fingerprint : nil)
        case result
        when Hash
          [result[key] || [], result['nextCursor']]
        when Array
          [result, nil]
        else
          raise MCPClient::Errors::TransportError,
                "Invalid #{method} response: expected an object or array, got #{result.class}"
        end
      end
      # MCP 2026-07-28 caching: every page carries its own ttlMs; the list is
      # fresh only as long as its shortest-lived page, and pages fetched
      # under differing credentials or parameters are never served combined.
      if respond_to?(:record_list_cache_hint, true)
        record_list_cache_hint(method, pages, received_ats, contexts: contexts, params: fingerprints, epoch: epoch)
      end
      items
    end

    # Whether a cached list of the given kind may still be served (MCP
    # 2026-07-28 caching); transports without freshness hints keep caching
    # until a change notification.
    # @param _kind [Symbol]
    # @return [Boolean]
    def cache_fresh?(_kind)
      true
    end

    # Initialize logger with proper formatter handling
    # Preserves custom formatter if logger is provided, otherwise sets a default formatter
    # @param logger [Logger, nil] custom logger to use, or nil to create a default one
    # @return [Logger] the configured logger
    def initialize_logger(logger)
      if logger
        @logger = logger
        @logger.progname = self.class.name
      else
        @logger = Logger.new($stdout, level: Logger::WARN)
        @logger.progname = self.class.name
        @logger.formatter = proc { |severity, _datetime, progname, msg| "#{severity} [#{progname}] #{msg}\n" }
      end
      @logger
    end
  end
end
