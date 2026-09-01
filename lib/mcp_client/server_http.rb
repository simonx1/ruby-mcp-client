# frozen_string_literal: true

require 'uri'
require 'json'
require 'monitor'
require 'logger'
require 'faraday'
require 'faraday/retry'
require 'faraday/follow_redirects'

module MCPClient
  # Implementation of MCP server that communicates via HTTP requests/responses
  # Useful for communicating with MCP servers that support HTTP-based transport
  # without Server-Sent Events streaming
  #
  # @note Elicitation Support (MCP 2025-06-18)
  #   This transport does NOT support server-initiated elicitation requests.
  #   The HTTP transport uses a pure request-response architecture where only the client
  #   can initiate requests. A legacy server that sends one on an SSE response
  #   stream is answered with JSON-RPC -32601 rather than left waiting (a
  #   `ping` gets the empty result it requires). For elicitation support, use
  #   one of these transports instead:
  #   - ServerStdio: Full bidirectional JSON-RPC over stdin/stdout
  #   - ServerSSE: Server requests via SSE stream, client responses via HTTP POST
  #   - ServerStreamableHTTP: Server requests via SSE-formatted responses, client responses via HTTP POST
  class ServerHTTP < ServerBase
    require_relative 'server_http/json_rpc_transport'

    include JsonRpcTransport

    # Default values for connection settings
    DEFAULT_READ_TIMEOUT = 30
    DEFAULT_MAX_RETRIES = 3

    # @!attribute [r] base_url
    #   @return [String] The base URL of the MCP server
    # @!attribute [r] endpoint
    #   @return [String] The JSON-RPC endpoint path
    # @!attribute [r] tools
    #   @return [Array<MCPClient::Tool>, nil] List of available tools (nil if not fetched yet)
    attr_reader :base_url, :endpoint, :tools

    # Server information from initialize response
    # @return [Hash, nil] Server information
    attr_reader :server_info

    # Server capabilities from initialize response
    # @return [Hash, nil] Server capabilities
    attr_reader :capabilities

    # @param base_url [String] The base URL of the MCP server
    # @param options [Hash] Server configuration options
    # @option options [String] :endpoint JSON-RPC endpoint path (default: '/rpc')
    # @option options [Hash] :headers Additional headers to include in requests
    # @option options [Integer] :read_timeout Read timeout in seconds (default: 30)
    # @option options [Integer] :retries Retry attempts on transient errors (default: 3)
    # @option options [Numeric] :retry_backoff Base delay for exponential backoff (default: 1)
    # @option options [String, nil] :name Optional name for this server
    # @option options [Logger, nil] :logger Optional logger
    # @option options [MCPClient::Auth::OAuthProvider, nil] :oauth_provider Optional OAuth provider
    # @option options [Proc, nil] :faraday_config Optional block to customize the Faraday connection
    def initialize(base_url:, **options)
      opts = default_options.merge(options)
      super(name: opts[:name])
      initialize_logger(opts[:logger])

      @max_retries = opts[:retries]
      @retry_backoff = opts[:retry_backoff]

      # Validate and normalize base_url
      raise ArgumentError, "Invalid or insecure server URL: #{base_url}" unless valid_server_url?(base_url)

      # Normalize base_url and handle cases where full endpoint is provided in base_url
      uri = URI.parse(base_url.chomp('/'))

      # Helper to build base URL without default ports
      build_base_url = lambda do |parsed_uri|
        port_part = if parsed_uri.port &&
                       !((parsed_uri.scheme == 'http' && parsed_uri.port == 80) ||
                         (parsed_uri.scheme == 'https' && parsed_uri.port == 443))
                      ":#{parsed_uri.port}"
                    else
                      ''
                    end
        "#{parsed_uri.scheme}://#{parsed_uri.host}#{port_part}"
      end

      @base_url = build_base_url.call(uri)
      @endpoint = if uri.path && !uri.path.empty? && uri.path != '/' && opts[:endpoint] == '/rpc'
                    # If base_url contains a path and we're using default endpoint,
                    # treat the path as the endpoint and use the base URL without path
                    uri.path
                  else
                    # Standard case: base_url is just scheme://host:port, endpoint is separate
                    opts[:endpoint]
                  end

      # Set up headers for HTTP requests
      # MCP 2026-07-28 Streamable HTTP: the client MUST list both content
      # types and support either framing of the response.
      @headers = opts[:headers].merge({
                                        'Content-Type' => 'application/json',
                                        'Accept' => 'application/json, text/event-stream',
                                        'User-Agent' => "ruby-mcp-client/#{MCPClient::VERSION}"
                                      })

      @read_timeout = opts[:read_timeout]
      configure_protocol_mode(opts[:protocol], opts[:discover_timeout])
      @faraday_config = opts[:faraday_config]
      @tools = nil
      @tools_data = nil
      @request_id = 0
      @mutex = Monitor.new
      @connection_established = false
      @initialized = false
      @http_conn = nil
      @session_id = nil
      @oauth_provider = opts[:oauth_provider]
      @elicitation_request_callback = nil # MCP 2026-07-28 multi round-trip requests
      @roots_list_request_callback = nil
      @sampling_request_callback = nil
    end

    # Connect to the MCP server over HTTP
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      # Serialized: concurrent first requests must not each run the probe
      # and possibly settle on different eras (the monitor is reentrant, so
      # the request plumbing inside may take @mutex again).
      @mutex.synchronize do
        return true if @connection_established

        begin
          @connection_established = false
          @initialized = false

          # Test connectivity with a simple HTTP request
          test_connection

          # Establish the protocol era: server/discover for a modern server,
          # the initialize handshake for a legacy one.
          negotiate_protocol

          @connection_established = true
          @initialized = true

          true
        rescue MCPClient::Errors::ConnectionError => e
          cleanup
          raise e
        rescue StandardError => e
          cleanup
          raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
        end
      end
    end

    # List all tools available from the MCP server
    # @return [Array<MCPClient::Tool>] list of available tools
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool listing
    def list_tools
      # MCP 2026-07-28 caching: a cached list is served only while fresh, and
      # only from the entry that carries its hint.
      cached = fresh_list_value(:tools) { @mutex.synchronize { @tools } }
      return cached if cached

      # Stale: the raw page cache must go too, or the re-fetch would be
      # answered from memory.
      @mutex.synchronize { @tools_data = nil }
      begin
        ensure_connected

        refetch_or_serve_stale(:tools, stale_list_entry(:tools)) { fetch_tools_list }
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        # Re-raise these errors directly
        raise
      rescue StandardError => e
        raise MCPClient::Errors::ToolCallError, "Error listing tools: #{e.message}"
      end
    end

    # Call a tool with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool execution
    # @raise [MCPClient::Errors::ConnectionError] if server is disconnected
    def call_tool(tool_name, parameters)
      rpc_request('tools/call', build_named_request_params(tool_name, parameters))
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ValidationError
      # Re-raise connection/transport errors directly to match test expectations
      raise
    rescue MCPClient::Errors::ServerError => e
      # 2026-07-28 protocol errors (typed -3202x, invalid result) carry
      # actionable data such as requiredCapabilities; keep them intact.
      raise if e.protocol_error?

      raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
    rescue StandardError => e
      # For all other errors, wrap in ToolCallError
      raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
    end

    # Override apply_request_headers to add session and protocol version headers
    def apply_request_headers(req, request)
      super

      # Modern servers have no session; the base class added the 2026-07-28
      # request metadata headers.
      return if modern?

      # Add session and protocol version headers for non-initialize requests
      return unless request['method'] != 'initialize'

      if @session_id
        req.headers['Mcp-Session-Id'] = @session_id
        @logger.debug("Adding session header: Mcp-Session-Id: #{@session_id}")
      end

      return unless @protocol_version

      req.headers['Mcp-Protocol-Version'] = @protocol_version
      @logger.debug("Adding protocol version header: Mcp-Protocol-Version: #{@protocol_version}")
    end

    # Override handle_successful_response to capture session ID
    def handle_successful_response(response, request)
      super

      # Capture session ID from initialize response with validation
      return unless request['method'] == 'initialize' && response.success?

      session_id = response.headers['mcp-session-id'] || response.headers['Mcp-Session-Id']
      if session_id
        if valid_session_id?(session_id)
          @session_id = session_id
          @logger.debug("Captured session ID: #{@session_id}")
        else
          @logger.warn("Invalid session ID format received: #{session_id.inspect}")
        end
      else
        @logger.warn('No session ID found in initialize response headers')
      end
    end

    # List all prompts available from the MCP server
    # @return [Array<MCPClient::Prompt>] list of available prompts
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::PromptGetError] for other errors during prompt listing
    def list_prompts
      cached = fresh_list_value(:prompts) { @mutex.synchronize { @prompts } }
      return cached if cached

      @mutex.synchronize { @prompts_data = nil }
      begin
        ensure_connected
        refetch_or_serve_stale(:prompts, stale_list_entry(:prompts)) { fetch_prompts_list }
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        raise
      rescue StandardError => e
        raise MCPClient::Errors::PromptGetError, "Error listing prompts: #{e.message}"
      end
    end

    # Fetch and cache the prompt list.
    # @return [Array<MCPClient::Prompt>]
    def fetch_prompts_list
      ensure_connected

      # Follow nextCursor across pages so the full prompt list is returned.
      prompts = request_paginated_list('prompts/list', 'prompts')

      prompts = prompts.map { |prompt_data| MCPClient::Prompt.from_json(prompt_data, server: self) }
      @mutex.synchronize do
        @prompts = prompts
        attach_list_value(:prompts, prompts)
      end

      # This request's own list, never a re-read of @prompts (another
      # request may have stored its list in between).
      prompts
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::PromptGetError, "Error listing prompts: #{e.message}"
    end

    # Get a prompt with the given parameters
    # @param prompt_name [String] the name of the prompt to get
    # @param parameters [Hash] the parameters to pass to the prompt
    # @return [Object] the result of the prompt interpolation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::PromptGetError] for other errors during prompt interpolation
    def get_prompt(prompt_name, parameters)
      rpc_request('prompts/get', build_named_request_params(prompt_name, parameters))
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      raise
    rescue MCPClient::Errors::ServerError => e
      # 2026-07-28 protocol errors (typed -3202x, invalid result) carry
      # actionable data such as requiredCapabilities; keep them intact.
      raise if e.protocol_error?

      raise MCPClient::Errors::PromptGetError, "Error getting prompt '#{prompt_name}': #{e.message}"
    rescue StandardError => e
      raise MCPClient::Errors::PromptGetError, "Error getting prompt '#{prompt_name}': #{e.message}"
    end

    # List all resources available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resources array and optional nextCursor
    # @raise [MCPClient::Errors::ResourceReadError] if resources list retrieval fails
    def list_resources(cursor: nil)
      cached = cursor ? nil : fresh_list_value(:resources) { @mutex.synchronize { @resources_result } }
      return cached if cached

      begin
        ensure_connected
        unless cursor
          return refetch_or_serve_stale(:resources, stale_list_entry(:resources)) do
            fetch_resources_list(nil)
          end
        end

        fetch_resources_list(cursor)
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        raise
      rescue StandardError => e
        raise MCPClient::Errors::ResourceReadError, "Error listing resources: #{e.message}"
      end
    end

    # Fetch one page of resources/list, caching the first page.
    # @param cursor [String, nil]
    # @return [Hash]
    def fetch_resources_list(cursor)
      params = {}
      params['cursor'] = cursor if cursor
      epoch = cache_epoch
      result = rpc_request('resources/list', params)
      record_cache_hint(:resources, result, epoch: epoch) unless cursor

      resources = (result['resources'] || []).map do |resource_data|
        MCPClient::Resource.from_json(resource_data, server: self)
      end

      resources_result = { 'resources' => resources, 'nextCursor' => result['nextCursor'] }

      @mutex.synchronize do
        unless cursor
          @resources_result = resources_result
          attach_list_value(:resources, resources_result)
        end
      end

      resources_result
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error listing resources: #{e.message}"
    end

    # Read a resource by its URI
    # @param uri [String] the URI of the resource to read
    # @return [Array<MCPClient::ResourceContent>] array of resource contents
    # @raise [MCPClient::Errors::ResourceReadError] if resource reading fails
    def read_resource(uri)
      read_resource_with_cache(uri) { rpc_request('resources/read', { uri: uri }) }
    rescue MCPClient::Errors::ServerError => e
      raise if e.protocol_error?
      raise resource_not_found_error(uri, e) if resource_not_found_response?(e)

      raise MCPClient::Errors::ResourceReadError, "Error reading resource '#{uri}': #{e.message}"
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error reading resource '#{uri}': #{e.message}"
    end

    # Request completion suggestions from the server (MCP 2025-06-18)
    # @param ref [Hash] reference to complete (prompt or resource)
    # @param argument [Hash] the argument being completed (e.g., { 'name' => 'arg_name', 'value' => 'partial' })
    # @param context [Hash, nil] optional context for the completion (MCP 2025-11-25)
    # @return [Hash] completion result with 'values', optional 'total', and 'hasMore' fields
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    def complete(ref:, argument:, context: nil)
      ensure_connected
      require_capability!('completions', method: 'completion/complete')
      params = { ref: ref, argument: argument }
      params[:context] = context if context
      result = rpc_request('completion/complete', params)
      result['completion'] || { 'values' => [] }
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError,
           MCPClient::Errors::CapabilityError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ServerError, "Error requesting completion: #{e.message}"
    end

    # Set the logging level on the server (MCP 2025-06-18)
    # @param level [String] the log level ('debug', 'info', 'notice', 'warning', 'error',
    #   'critical', 'alert', 'emergency')
    # @return [Hash] empty result on success
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    def log_level=(level)
      ensure_connected
      # MCP 2026-07-28 removed logging/setLevel: the level travels per request
      # in _meta["io.modelcontextprotocol/logLevel"].
      if modern?
        @log_level = validate_log_level!(level)
        return
      end

      require_capability!('logging', method: 'logging/setLevel')
      rpc_request('logging/setLevel', { level: level })
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError,
           MCPClient::Errors::CapabilityError, ArgumentError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ServerError, "Error setting log level: #{e.message}"
    end

    # List all resource templates available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resourceTemplates array and optional nextCursor
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during resource template listing
    def list_resource_templates(cursor: nil)
      params = {}
      params['cursor'] = cursor if cursor
      epoch = cache_epoch
      result = rpc_request('resources/templates/list', params)
      record_cache_hint(:templates, result, epoch: epoch) unless cursor

      templates = (result['resourceTemplates'] || []).map do |template_data|
        MCPClient::ResourceTemplate.from_json(template_data, server: self)
      end

      { 'resourceTemplates' => templates, 'nextCursor' => result['nextCursor'] }
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error listing resource templates: #{e.message}"
    end

    # Subscribe to resource updates
    # @param uri [String] the URI of the resource to subscribe to
    # @return [Boolean] true if subscription successful
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during subscription
    def subscribe_resource(uri)
      ensure_connected
      require_capability!('resources', 'subscribe', method: 'resources/subscribe')
      # MCP 2026-07-28 replaced resources/subscribe with a subscriptions/listen
      # stream carrying resourceSubscriptions.
      if modern?
        subscribe_resource_via_listen(uri)
        return true
      end

      rpc_request('resources/subscribe', { uri: uri })
      true
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError,
           MCPClient::Errors::CapabilityError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error subscribing to resource '#{uri}': #{e.message}"
    end

    # Unsubscribe from resource updates
    # @param uri [String] the URI of the resource to unsubscribe from
    # @return [Boolean] true if unsubscription successful
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during unsubscription
    def unsubscribe_resource(uri)
      ensure_connected
      require_capability!('resources', 'subscribe', method: 'resources/unsubscribe')
      if modern?
        unsubscribe_resource_via_listen(uri)
        return true
      end

      rpc_request('resources/unsubscribe', { uri: uri })
      true
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError,
           MCPClient::Errors::CapabilityError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error unsubscribing from resource '#{uri}': #{e.message}"
    end

    # Stream tool call (default implementation returns single-value stream)
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Enumerator] stream of results
    def call_tool_streaming(tool_name, parameters)
      Enumerator.new do |yielder|
        yielder << call_tool(tool_name, parameters)
      end
    end

    # Register a handler for elicitation input requests (MCP 2026-07-28 multi
    # round-trip requests; there is no server-initiated request channel on
    # this transport, so these only serve InputRequiredResult round trips).
    # @param block [Proc] callback that receives (key, params) and returns an ElicitResult
    # @return [void]
    def on_elicitation_request(&block)
      @elicitation_request_callback = block
    end

    # Register a handler for roots/list input requests (MCP 2026-07-28).
    # @param block [Proc] callback that receives (key, params) and returns a ListRootsResult
    # @return [void]
    def on_roots_list_request(&block)
      @roots_list_request_callback = block
    end

    # Register a handler for sampling input requests (MCP 2026-07-28).
    # @param block [Proc] callback that receives (key, params) and returns a CreateMessageResult
    # @return [void]
    def on_sampling_request(&block)
      @sampling_request_callback = block
    end

    # This transport has no legacy server-request channel (server requests on
    # a response stream are dropped), so on a legacy session it must not
    # advertise roots, elicitation or sampling: the handlers above only serve
    # the modern multi round-trip pattern.
    # @return [Hash]
    def client_capabilities
      capabilities = super
      return capabilities if modern?

      capabilities.except('roots', 'elicitation', 'sampling')
    end

    # Terminate the current session (if any)
    # @return [Boolean] true if termination was successful or no session exists
    def terminate_session
      @mutex.synchronize do
        return true unless @session_id

        super
      end
    end

    # Clean up the server connection
    # Properly closes HTTP connections and clears cached state
    def cleanup
      @mutex.synchronize do
        # Attempt to terminate session before cleanup
        terminate_session if @session_id

        @connection_established = false
        @initialized = false
        # Subscription streams (MCP 2026-07-28) end with the connection
        close_listen_streams

        @logger.debug('Cleaning up HTTP connection')

        # Close HTTP connection if it exists
        @http_conn = nil
        @session_id = nil

        @tools = nil
        @tools_data = nil
        @prompts = nil
        @prompts_data = nil
        @resources_result = nil
        @resources_data = nil
      end
      # Cached results and their hints belong to the connection (and its
      # authorization context) that was just torn down; outside @mutex, as
      # the cache has its own lock.
      clear_result_cache
    end

    private

    # Perform the MCP initialize handshake, then announce readiness.
    #
    # The base handshake sends the initialize request and captures
    # serverInfo/capabilities. Per the MCP lifecycle the client MUST send an
    # `initialized` notification after a successful initialize before issuing
    # any other requests; the plain HTTP transport previously skipped it.
    # @return [void]
    # @raise [MCPClient::Errors::TransportError] if the notification fails to send
    def perform_initialize
      super

      notification = build_jsonrpc_notification('notifications/initialized', {})
      begin
        send_http_request(notification)
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::ConnectionError, Faraday::ConnectionFailed => e
        raise MCPClient::Errors::TransportError, "Failed to send initialized notification: #{e.message}"
      end
    end

    # Default options for server initialization
    # @return [Hash] Default options
    def default_options
      {
        endpoint: '/rpc',
        headers: {},
        read_timeout: DEFAULT_READ_TIMEOUT,
        retries: DEFAULT_MAX_RETRIES,
        retry_backoff: 1,
        name: nil,
        logger: nil,
        oauth_provider: nil,
        faraday_config: nil,
        protocol: :auto,
        discover_timeout: nil
      }
    end

    # Test basic connectivity to the HTTP endpoint
    # @return [void]
    # @raise [MCPClient::Errors::ConnectionError] if connection test fails
    def test_connection
      create_http_connection

      # Simple connectivity test - we'll use the actual initialize call
      # since there's no standard HTTP health check endpoint
    rescue Faraday::ConnectionFailed => e
      raise MCPClient::Errors::ConnectionError, "Cannot connect to server at #{@base_url}: #{e.message}"
    rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
      error_status = e.response ? e.response[:status] : 'unknown'
      raise MCPClient::Errors::ConnectionError, "Authorization failed: HTTP #{error_status}"
    rescue Faraday::Error => e
      raise MCPClient::Errors::ConnectionError, "HTTP connection error: #{e.message}"
    end

    # Ensure connection is established
    # @return [void]
    # @raise [MCPClient::Errors::ConnectionError] if connection is not established
    def ensure_connected
      # Serialized on the transport monitor (reentrant, so the nested
      # cleanup/connect may take it again): checking the flags and acting on
      # them must be one step. Otherwise a caller that observed "disconnected"
      # can be overtaken by one that reconnects, and then tear that fresh
      # connection down — terminating its session and re-running the era
      # probe.
      @mutex.synchronize do
        return if @connection_established && @initialized

        @logger.debug('Connection not active, attempting to reconnect before request')
        cleanup
        connect
      end
    end

    # Request the tools list using JSON-RPC
    # @return [Array<Hash>] the tools data
    # @raise [MCPClient::Errors::ToolCallError] if tools list retrieval fails
    def request_tools_list
      # Follow nextCursor across pages so the full tool list is returned even
      # when the server paginates. The raw pages are this fetch's own: a
      # shared copy could answer a concurrent caller under other
      # credentials with a privately scoped list (MCP 2026-07-28 caching).
      request_paginated_list('tools/list', 'tools')
    end
  end
end
