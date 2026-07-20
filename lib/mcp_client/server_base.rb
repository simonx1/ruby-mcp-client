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
      collect_paginated(key) do |cursor|
        params = cursor ? { cursor: cursor } : {}
        result = rpc_request(method, params)
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
