# frozen_string_literal: true

require 'uri'
require 'json'
require 'monitor'
require 'logger'
require 'faraday'
require 'faraday/retry'
require 'faraday/follow_redirects'

module MCPClient
  # Implementation of MCP server that communicates via Streamable HTTP transport (MCP 2025-06-18)
  # This transport uses HTTP POST for RPC calls with optional SSE responses, and GET for event streams
  # Compliant with MCP specification version 2025-06-18
  #
  # Key features:
  # - Supports server-sent events (SSE) for real-time notifications
  # - Handles ping/pong keepalive mechanism
  # - Thread-safe connection management
  # - Automatic reconnection with exponential backoff
  class ServerStreamableHTTP < ServerBase
    require_relative 'server_streamable_http/json_rpc_transport'

    include JsonRpcTransport

    # Default values for connection settings
    DEFAULT_READ_TIMEOUT = 30
    DEFAULT_MAX_RETRIES = 3

    # SSE connection settings
    SSE_CONNECTION_TIMEOUT = 300 # 5 minutes
    SSE_RECONNECT_DELAY = 1        # Initial reconnect delay in seconds
    SSE_MAX_RECONNECT_DELAY = 30   # Maximum reconnect delay in seconds
    THREAD_JOIN_TIMEOUT = 5 # Timeout for thread cleanup

    # Floor for the delay between resumption GETs. SEP-1699's polling pattern
    # wants fast reconnects, so this is far smaller than the events-stream
    # floor — it only prevents a peer-supplied "retry: 0" from turning the
    # deadline window into a back-to-back request loop.
    MIN_RESUMPTION_RECONNECT_DELAY = 0.01

    # Maximum length of a server-supplied SSE event id retained as the
    # resumption cursor. The id is echoed in the Last-Event-ID header of
    # subsequent requests, so an unbounded value means unbounded retained
    # memory and oversized outbound headers.
    MAX_EVENT_ID_LENGTH = 1024

    # Characters allowed in a retained event id: printable ASCII, since the
    # value becomes an HTTP header value. Notably excludes CR/LF. The range
    # starts at 0x20 because a space is legal inside a field value, and
    # rejecting ids like "cursor 42" would silently strand resumption on a
    # stale cursor.
    EVENT_ID_PATTERN = /\A[\x20-\x7E]+\z/

    # Ceiling on concurrent threads POSTing server-initiated responses
    # (pongs, roots/sampling/elicitation replies, error responses). Each
    # server request on the events stream costs one blocking HTTP POST in
    # its own thread; without a bound, a peer flooding requests could
    # accumulate threads and connections until the host is exhausted.
    # Responses beyond the budget are dropped, with saturation logged at most
    # once per SATURATION_LOG_INTERVAL seconds.
    MAX_CONCURRENT_RESPONSE_POSTS = 8

    # Minimum gap between "response budget saturated" warnings
    SATURATION_LOG_INTERVAL = 5

    # Floor for server-supplied retry directives on the long-lived events
    # stream. The directive is peer-controlled: honoring "retry: 0" literally
    # would let a hostile server that closes every stream drive a tight
    # reconnect loop (sustained CPU/TLS/connection churn). Waiting longer
    # than the directive stays SEP-1699 compliant — the retry field is a
    # lower bound on the reconnect delay, not an exact schedule.
    MIN_EVENTS_RECONNECT_DELAY = 0.1

    # Maximum bytes an SSE parse buffer (events stream or resumption GET) may
    # hold while waiting for an event terminator. The stream is
    # peer-controlled: without a cap, a hostile server could withhold the
    # blank-line delimiter forever and grow the buffer until the host runs
    # out of memory. Generous enough for any legitimate JSON-RPC event.
    MAX_SSE_BUFFER_BYTES = 32 * 1024 * 1024

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
    # @param options [Hash] Server configuration options (same as ServerHTTP)
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

      # Set up headers for Streamable HTTP requests
      @headers = opts[:headers].merge({
                                        'Content-Type' => 'application/json',
                                        'Accept' => 'text/event-stream, application/json',
                                        'Accept-Encoding' => 'gzip',
                                        'User-Agent' => "ruby-mcp-client/#{MCPClient::VERSION}",
                                        'Cache-Control' => 'no-cache'
                                      })

      @read_timeout = opts[:read_timeout]
      configure_protocol_mode(opts[:protocol], opts[:discover_timeout])
      @faraday_config = opts[:faraday_config]
      @max_decompressed_body_bytes = validate_decompression_limit(opts[:max_decompressed_body_bytes])
      @tools = nil
      @tools_data = nil
      @prompts = nil
      @prompts_data = nil
      @resources = nil
      @resources_data = nil
      @request_id = 0
      @mutex = Monitor.new
      @connection_established = false
      @initialized = false
      @http_conn = nil
      @session_id = nil
      @last_event_id = nil
      @sse_retry_ms = nil
      @pending_stream_responses = {}
      @response_post_count = 0
      # Saturation bookkeeping for the response-POST budget
      @dropped_response_posts = 0
      @last_saturation_log_at = nil
      @oauth_provider = opts[:oauth_provider]

      # SSE events connection state
      @events_connection = nil
      @events_thread = nil
      @buffer = +'' # Buffer for partial SSE event data
      # How much of @buffer has already been searched for an event terminator
      @buffer_scanned = 0
      @elicitation_request_callback = nil # MCP 2025-06-18
      @roots_list_request_callback = nil # MCP 2025-06-18
      @sampling_request_callback = nil # MCP 2025-11-25
    end

    # Connect to the MCP server over Streamable HTTP
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

          # Long-lived GET stream for server events: legacy only. MCP
          # 2026-07-28 removed the GET endpoint; change notifications arrive
          # on subscriptions/listen streams instead.
          start_events_connection unless modern?

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
    # @return [Object] the result of the tool invocation (with string keys for backward compatibility)
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

    # Stream tool call (default implementation returns single-value stream)
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Enumerator] stream of results
    def call_tool_streaming(tool_name, parameters)
      Enumerator.new do |yielder|
        yielder << call_tool(tool_name, parameters)
      end
    end

    # Request completion suggestions from the server (MCP 2025-06-18)
    # @param ref [Hash] reference object (e.g., { 'type' => 'ref/prompt', 'name' => 'prompt_name' })
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

    # List all prompts available from the MCP server
    # @return [Array<MCPClient::Prompt>] list of available prompts
    # @raise [MCPClient::Errors::PromptGetError] if prompts list retrieval fails
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

      prompts = request_prompts_list.map { |prompt_data| MCPClient::Prompt.from_json(prompt_data, server: self) }
      @mutex.synchronize do
        @prompts = attach_list_value(:prompts, prompts) ? prompts : nil
      end

      # This request's own list, never a re-read of @prompts (another
      # request may have stored its list in between).
      prompts
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      # Re-raise these errors directly
      raise
    rescue StandardError => e
      raise MCPClient::Errors::PromptGetError, "Error listing prompts: #{e.message}"
    end

    # Get a prompt with the given parameters
    # @param prompt_name [String] the name of the prompt to get
    # @param parameters [Hash] the parameters to pass to the prompt
    # @return [Object] the result of the prompt (with string keys for backward compatibility)
    # @raise [MCPClient::Errors::PromptGetError] if prompt retrieval fails
    def get_prompt(prompt_name, parameters)
      rpc_request('prompts/get', build_named_request_params(prompt_name, parameters))
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      # Re-raise connection/transport errors directly
      raise
    rescue MCPClient::Errors::ServerError => e
      # 2026-07-28 protocol errors (typed -3202x, invalid result) carry
      # actionable data such as requiredCapabilities; keep them intact.
      raise if e.protocol_error?

      raise MCPClient::Errors::PromptGetError, "Error getting prompt '#{prompt_name}': #{e.message}"
    rescue StandardError => e
      # For all other errors, wrap in PromptGetError
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
      epoch = cache_epoch(:resources)
      result = rpc_request('resources/list', params)
      record_cache_hint(:resources, result, epoch: epoch) unless cursor

      resources = (result['resources'] || []).map do |resource_data|
        MCPClient::Resource.from_json(resource_data, server: self)
      end

      resources_result = { 'resources' => resources, 'nextCursor' => result['nextCursor'] }

      @mutex.synchronize do
        unless cursor
          @resources_result = attach_list_value(:resources, resources_result) ? resources_result : nil
        end
      end

      resources_result
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      # Re-raise these errors directly
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error listing resources: #{e.message}"
    end

    # Read a resource by its URI
    # @param uri [String] the URI of the resource to read
    # @return [Array<MCPClient::ResourceContent>] array of resource contents
    # @raise [MCPClient::Errors::ResourceReadError] if resource reading fails
    def read_resource(uri)
      ensure_connected
      read_resource_with_cache(uri) { rpc_request('resources/read', { uri: uri }) }
    rescue MCPClient::Errors::ServerError => e
      raise if e.protocol_error?
      raise resource_not_found_error(uri, e) if resource_not_found_response?(e)

      raise MCPClient::Errors::ResourceReadError, "Error reading resource '#{uri}': #{e.message}"
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      # Re-raise connection/transport errors directly
      raise
    rescue StandardError => e
      # For all other errors, wrap in ResourceReadError
      raise MCPClient::Errors::ResourceReadError, "Error reading resource '#{uri}': #{e.message}"
    end

    # List all resource templates available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resourceTemplates array and optional nextCursor
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during resource template listing
    def list_resource_templates(cursor: nil)
      cached = cursor ? nil : fresh_list_value(:templates) { @mutex.synchronize { @templates_result } }
      return cached if cached

      begin
        ensure_connected
        unless cursor
          return refetch_or_serve_stale(:templates, stale_list_entry(:templates)) do
            fetch_templates_list(nil)
          end
        end

        fetch_templates_list(cursor)
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        raise
      rescue StandardError => e
        raise MCPClient::Errors::ResourceReadError, "Error listing resource templates: #{e.message}"
      end
    end

    # Fetch one page of resources/templates/list, caching the first page.
    # @param cursor [String, nil]
    # @return [Hash]
    def fetch_templates_list(cursor)
      params = {}
      params['cursor'] = cursor if cursor
      epoch = cache_epoch(:templates)
      result = rpc_request('resources/templates/list', params)
      record_cache_hint(:templates, result, epoch: epoch) unless cursor

      templates = (result['resourceTemplates'] || []).map do |template_data|
        MCPClient::ResourceTemplate.from_json(template_data, server: self)
      end
      templates_result = { 'resourceTemplates' => templates, 'nextCursor' => result['nextCursor'] }

      @mutex.synchronize do
        unless cursor
          @templates_result = attach_list_value(:templates, templates_result) ? templates_result : nil
        end
      end

      templates_result
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

    # Override apply_request_headers to add session and SSE headers for MCP protocol
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

      # NOTE: Last-Event-ID is deliberately NOT sent on POSTs — per SEP-1699,
      # resumption is always via HTTP GET with Last-Event-ID.
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

    # Terminate the current session (if any)
    # @return [Boolean] true if termination was successful or no session exists
    def terminate_session
      @mutex.synchronize do
        return true unless @session_id

        super
      end
    end

    # Clean up the server connection
    # Properly closes HTTP connections, stops threads, and clears cached state
    def cleanup
      # The cache notes this transport left on this thread are for a slice
      # that will never be tagged now.
      forget_served_entries
      @mutex.synchronize do
        return unless @connection_established || @initialized

        @logger.info('Cleaning up Streamable HTTP connection')

        # Mark connection as closed to stop reconnection attempts
        @connection_established = false
        @initialized = false

        # Subscription streams (MCP 2026-07-28) end with the connection
        close_listen_streams

        # Attempt to terminate session before cleanup
        begin
          terminate_session if @session_id
        rescue StandardError => e
          @logger.warn("Failed to terminate session: #{e.message}")
        end

        # Stop events thread gracefully
        if @events_thread&.alive?
          @logger.debug('Stopping events thread...')
          @events_thread.kill
          @events_thread.join(THREAD_JOIN_TIMEOUT)
        end
        @events_thread = nil

        # Clear connections and state
        @http_conn = nil
        @events_connection = nil
        @session_id = nil
        @last_event_id = nil
        @sse_retry_ms = nil
        @pending_stream_responses.each_value(&:close)
        @pending_stream_responses.clear

        # Clear cached data
        @tools = nil
        @tools_data = nil
        @prompts = nil
        @prompts_data = nil
        @resources = nil
        @resources_data = nil
        @resources_result = nil
        @templates_result = nil
        @buffer = +''
        @buffer_scanned = 0

        @logger.info('Cleanup completed')
      end
      # Cached results and their hints belong to the connection (and its
      # authorization context) that was just torn down; outside @mutex, as
      # the cache has its own lock.
      clear_result_cache
    end

    # Register a callback for elicitation requests (MCP 2025-06-18)
    # @param block [Proc] callback that receives (request_id, params) and returns response hash
    # @return [void]
    def on_elicitation_request(&block)
      @elicitation_request_callback = block
    end

    # Register a callback for roots/list requests (MCP 2025-06-18)
    # @param block [Proc] callback that receives (request_id, params) and returns response hash
    # @return [void]
    def on_roots_list_request(&block)
      @roots_list_request_callback = block
    end

    # Register a callback for sampling requests (MCP 2025-11-25)
    # @param block [Proc] callback that receives (request_id, params) and returns response hash
    # @return [void]
    def on_sampling_request(&block)
      @sampling_request_callback = block
    end

    private

    def perform_initialize
      super
      # Send initialized notification to acknowledge completion of initialization
      notification = build_jsonrpc_notification('notifications/initialized', {})
      begin
        send_http_request(notification)
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::ConnectionError, Faraday::ConnectionFailed => e
        raise MCPClient::Errors::TransportError, "Failed to send initialized notification: #{e.message}"
      end
    end

    # Default options for server initialization
    # @return [Hash] Default options
    # Validate the configured decompression ceiling.
    # @param value [Object] the max_decompressed_body_bytes option
    # @return [Integer] the validated positive byte limit
    # @raise [ArgumentError] if the value is not a positive Integer
    def validate_decompression_limit(value)
      return value if value.is_a?(Integer) && value.positive?

      raise ArgumentError,
            "max_decompressed_body_bytes must be a positive Integer, got #{value.inspect}"
    end

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
        max_decompressed_body_bytes: JsonRpcTransport::MAX_DECOMPRESSED_BODY_BYTES,
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

    # Request the prompts list using JSON-RPC
    # @return [Array<Hash>] the prompts data
    # @raise [MCPClient::Errors::PromptGetError] if prompts list retrieval fails
    def request_prompts_list
      # Follow nextCursor across pages so the full prompt list is returned;
      # the raw pages are this fetch's own (see request_tools_list).
      request_paginated_list('prompts/list', 'prompts')
    end

    # Request the resources list using JSON-RPC
    # @return [Array<Hash>] the resources data
    # @raise [MCPClient::Errors::ResourceReadError] if resources list retrieval fails
    def request_resources_list
      # The raw list is this fetch's own (see request_tools_list).
      result = rpc_request('resources/list')

      return result['resources'].dup if result.is_a?(Hash) && result['resources']
      return result.dup if result.is_a?(Array) || result

      raise MCPClient::Errors::ResourceReadError, 'Failed to get resources list from JSON-RPC request'
    end

    # Start the long-lived GET connection for server events
    # Creates a separate thread to maintain SSE connection for server notifications
    # @return [void]
    def start_events_connection
      return if @events_thread&.alive?

      @logger.info('Starting SSE events connection thread')
      @events_thread = Thread.new do
        Thread.current.name = 'MCP-SSE-Events'
        Thread.current.report_on_exception = false # We handle exceptions internally

        begin
          handle_events_connection
        rescue StandardError => e
          @logger.error("Events thread crashed: #{e.message}")
          @logger.debug(e.backtrace.join("\n")) if @logger.level <= Logger::DEBUG
        end
      end
    end

    # Handle the events connection in a separate thread
    # Maintains a persistent SSE connection for server notifications and ping/pong
    # @return [void]
    def handle_events_connection
      reconnect_delay = SSE_RECONNECT_DELAY

      loop do
        # Create a Faraday connection specifically for SSE streaming
        # Using net_http adapter for better streaming support
        conn = Faraday.new(url: @base_url) do |f|
          f.request :retry, max: 0 # No automatic retries for SSE stream
          f.options.open_timeout = 10
          f.options.timeout = SSE_CONNECTION_TIMEOUT
          f.adapter :net_http do |http|
            http.read_timeout = SSE_CONNECTION_TIMEOUT
            http.open_timeout = 10
          end
        end

        # Apply user's Faraday customizations after defaults
        @faraday_config&.call(conn)

        @logger.debug("Establishing SSE events connection to #{@endpoint}") if @logger.level <= Logger::DEBUG

        response = conn.get(@endpoint) do |req|
          apply_events_headers(req)

          # Handle streaming response with on_data callback
          req.options.on_data = proc do |chunk, _total_bytes|
            if chunk && !chunk.empty?
              @logger.debug("Received event chunk (#{chunk.bytesize} bytes)") if @logger.level <= Logger::DEBUG
              process_event_chunk(chunk)
            end
          end
        end

        @logger.debug("Events connection completed with status: #{response.status}") if @logger.level <= Logger::DEBUG

        # Connection closed normally, check if we should reconnect
        break unless @mutex.synchronize { @connection_established }

        @logger.info('Events connection closed, reconnecting...')
        sleep events_reconnect_delay(reconnect_delay)
        reconnect_delay = [reconnect_delay * 2, SSE_MAX_RECONNECT_DELAY].min

      # Intentional shutdown
      rescue Net::ReadTimeout, Faraday::TimeoutError
        # Timeout after inactivity - this is expected for long-lived connections
        break unless @mutex.synchronize { @connection_established }

        @logger.debug('Events connection timed out after inactivity, reconnecting...')
        sleep events_reconnect_delay(reconnect_delay)
      rescue Faraday::ConnectionFailed => e
        break unless @mutex.synchronize { @connection_established }

        @logger.warn("Events connection failed: #{e.message}, retrying in #{reconnect_delay}s...")
        sleep events_reconnect_delay(reconnect_delay)
        reconnect_delay = [reconnect_delay * 2, SSE_MAX_RECONNECT_DELAY].min
      rescue StandardError => e
        break unless @mutex.synchronize { @connection_established }

        @logger.error("Unexpected error in events connection: #{e.class} - #{e.message}")
        @logger.debug(e.backtrace.join("\n")) if @logger.level <= Logger::DEBUG
        sleep events_reconnect_delay(reconnect_delay)
        reconnect_delay = [reconnect_delay * 2, SSE_MAX_RECONNECT_DELAY].min
      end
    ensure
      @logger.info('Events connection thread terminated')
    end

    # Reconnect delay for the events stream: the server's SSE retry directive
    # (in ms) when present, otherwise the caller's backoff value. The
    # peer-controlled directive is floored at MIN_EVENTS_RECONNECT_DELAY so a
    # zero/near-zero value cannot drive a tight reconnect loop; the
    # deadline-bounded resumption loop intentionally keeps honoring zero.
    # @param fallback_seconds [Numeric] exponential-backoff fallback
    # @return [Numeric] delay in seconds
    def events_reconnect_delay(fallback_seconds)
      retry_ms = @sse_retry_ms
      return fallback_seconds unless retry_ms

      [retry_ms / 1000.0, MIN_EVENTS_RECONNECT_DELAY].max
    end

    # Wait for a response replayed after the POST stream was closed before
    # delivering it (SEP-1699 polling pattern). A dedicated worker issues
    # HTTP GETs carrying the disconnected stream's Last-Event-ID cursor — the
    # general events stream (opened without that cursor) cannot receive the
    # replay.
    # @param request_id [Integer, String] id of the outstanding request
    # @param cursor [String] last event id received on the closed stream
    # @param retry_ms [Integer, nil] retry directive received on the closed
    #   stream itself (not the shared events-stream directive)
    # @return [Hash, nil] the replayed JSON-RPC response, or nil on timeout
    def resume_response_via_get(request_id, cursor, retry_ms = nil)
      queue = Thread::Queue.new
      @mutex.synchronize { @pending_stream_responses[request_id] = queue }

      resume_thread = Thread.new { run_resumption_loop(request_id, cursor, retry_ms) }
      begin
        queue.pop(timeout: @read_timeout)
      ensure
        @mutex.synchronize { @pending_stream_responses.delete(request_id) }
        resume_thread.kill
        resume_thread.join(1)
      end
    end

    # Reconnecting worker for SEP-1699 resumption. The server MAY close a
    # resumed stream again before returning the response (polling pattern),
    # so each iteration issues a GET with the CURRENT cursor until the
    # overall read timeout elapses or the waiter has been served. `id:`
    # fields received on the resumed stream advance the cursor and `retry:`
    # fields update the delay honored before the next reconnect (zero is a
    # valid immediate-reconnect directive).
    # @param request_id [Integer, String] id of the outstanding request
    # @param cursor [String] Last-Event-ID cursor from the closed stream
    # @param retry_ms [Integer, nil] retry directive from the closed stream
    # @return [void]
    def run_resumption_loop(request_id, cursor, retry_ms)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @read_timeout
      state = { cursor: cursor, retry_ms: retry_ms }
      # SEP-1699: the client MUST respect the server's retry directive before
      # attempting to reconnect. With no directive the FIRST GET goes out
      # immediately, as before this change: delaying it adds latency to every
      # resumption and, on a short read_timeout, can burn the whole budget
      # before any I/O happens.
      delay = retry_ms ? resumption_delay(retry_ms) : 0

      loop do
        sleep(delay) if delay.positive?
        issue_resumption_get(state)
        break unless @mutex.synchronize { @pending_stream_responses.key?(request_id) }
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        delay = resumption_delay(state[:retry_ms])
      end
    end

    # Delay before the next resumption GET: the peer's retry directive when
    # present, floored so "retry: 0" cannot turn the deadline window into a
    # back-to-back request loop, otherwise the standard reconnect delay.
    # @param retry_ms [Integer, nil] retry directive in milliseconds
    # @return [Numeric] delay in seconds
    def resumption_delay(retry_ms)
      return SSE_RECONNECT_DELAY unless retry_ms

      [retry_ms / 1000.0, MIN_RESUMPTION_RECONNECT_DELAY].max
    end

    # One GET with the current cursor; complete SSE events are dispatched
    # through the standard server-message path, which routes replayed
    # responses to their registered waiters. `id:` and `retry:` fields
    # received on this stream update the resumption state live.
    # @param state [Hash] mutable resumption state (:cursor, :retry_ms)
    # @return [void]
    def issue_resumption_get(state)
      conn = Faraday.new(url: @base_url) do |f|
        f.options.open_timeout = 10
        f.options.timeout = @read_timeout
        f.adapter :net_http
      end

      buffer = +''
      conn.get(@endpoint) do |req|
        apply_events_headers(req)
        req.headers['Last-Event-ID'] = state[:cursor]
        req.options.on_data = proc do |chunk, _bytes|
          buffer << chunk
          process_resumption_buffer(buffer, state)
          # A peer replaying delimiter-free data must not grow this buffer
          # without bound: abort the GET (rescued below); the deadline-bounded
          # resumption loop decides whether to retry with a fresh buffer.
          enforce_sse_buffer_cap!(buffer)
        end
      end
    rescue StandardError => e
      @logger.debug("Resumption GET failed: #{e.message}")
    end

    # Extract complete SSE events (terminated by a blank line, LF or CRLF)
    # from the resumption buffer and handle each of them.
    # @param buffer [String] mutable stream buffer
    # @param state [Hash] mutable resumption state (:cursor, :retry_ms)
    # @return [void]
    def process_resumption_buffer(buffer, state)
      # Same incremental scan as the events stream: without a cursor every
      # chunk re-matched the whole accumulated buffer from byte zero.
      scan_from = [state[:scanned].to_i - 3, 0].max
      while (separator = buffer.match(/\r\n\r\n|\n\n/, scan_from))
        event_text = buffer.slice!(0, separator.end(0))
        handle_resumption_event(event_text, state)
        scan_from = 0
        state[:scanned] = 0
      end
      state[:scanned] = buffer.length
    end

    # Parse one SSE event received on a resumption stream: track `id:` lines
    # (advancing the cursor used by the next reconnect) and `retry:` lines
    # (updating the reconnect delay; zero is valid), then dispatch any data.
    # @param event_text [String] one complete SSE event, separator included
    # @param state [Hash] mutable resumption state (:cursor, :retry_ms)
    # @return [void]
    def handle_resumption_event(event_text, state)
      data_lines = []
      event_text.each_line do |raw_line|
        line = raw_line.chomp
        if line.start_with?('data:')
          data_lines << line.sub(/\Adata:\s*/, '')
        elsif line.start_with?('id:')
          id = line.sub(/\Aid:\s*/, '').strip
          # Same validation as the events stream: this cursor is echoed in
          # the Last-Event-ID header of the next resumption GET.
          state[:cursor] = id if retainable_event_id?(id)
        elsif line.start_with?('retry:')
          raw = line.sub(/\Aretry:\s*/, '').strip
          state[:retry_ms] = raw.to_i if raw.match?(/\A\d+\z/)
        end
      end
      handle_server_message(data_lines.join("\n")) unless data_lines.empty?
    end

    # Deliver a response replayed on the events stream to a waiting request.
    # The pending entry is removed on delivery so resumption workers can see
    # that their waiter has been served.
    # @param message [Hash] a JSON-RPC response message
    # @return [void]
    def deliver_stream_response(message)
      queue = @mutex.synchronize do
        key = [message['id'], message['id'].to_s].find { |k| @pending_stream_responses.key?(k) }
        @pending_stream_responses.delete(key) unless key.nil?
      end
      queue << message if queue
    end

    # Apply headers for events connection
    # @param req [Faraday::Request] HTTP request
    def apply_events_headers(req)
      @headers.each { |k, v| req.headers[k] = v }
      req.headers['Mcp-Session-Id'] = @session_id if @session_id
      req.headers['Mcp-Protocol-Version'] = @protocol_version if @protocol_version
      # MCP: authorization MUST be included in every HTTP request
      @oauth_provider&.apply_authorization(req)
      note_request_authorization(req.headers['Authorization'])
      # SEP-1699: resumption is via GET with the Last-Event-ID cursor, so the
      # server can replay messages missed since the last received event.
      last_event_id = @mutex.synchronize { @last_event_id }
      req.headers['Last-Event-ID'] = last_event_id if last_event_id
    end

    # Process event chunks from the server
    # Buffers partial chunks and processes complete SSE events
    # @param chunk [String] the chunk to process
    def process_event_chunk(chunk)
      # Size only: the chunk is raw wire data carrying sampling prompts,
      # elicitation content and tool results.
      @logger.debug("Processing event chunk (#{describe_body_size(chunk)})") if @logger.level <= Logger::DEBUG

      @mutex.synchronize do
        # Append in place and scan only the newly arrived bytes. `+= chunk`
        # reallocated and copied the whole buffer per callback, and each
        # search restarted at index 0, so an unterminated event delivered in
        # N chunks cost O(N^2) work: capped memory, uncapped CPU.
        @buffer << chunk

        scan_from = [@buffer_scanned - 3, 0].max
        while (event_end = next_buffer_event_end(scan_from))
          event_data = extract_event(event_end)
          parse_and_handle_event(event_data)
          scan_from = 0
          @buffer_scanned = 0
        end
        @buffer_scanned = @buffer.length

        # Everything left is a partial event awaiting its terminator; cap how
        # much a peer may accumulate. The raise propagates (unlike processing
        # errors below) so the events loop drops this connection and its
        # backoff takes over — memory stays bounded either way.
        begin
          enforce_sse_buffer_cap!(@buffer)
        rescue MCPClient::Errors::ConnectionError
          @buffer = +''
          @buffer_scanned = 0
          raise
        end
      end
    rescue MCPClient::Errors::ConnectionError
      raise
    rescue StandardError => e
      @logger.error("Error processing event chunk: #{e.message}")
      @logger.debug(e.backtrace.join("\n")) if @logger.level <= Logger::DEBUG
    end

    # Index of the earliest event terminator at or after an offset.
    # @param offset [Integer] character offset to start searching from
    # @return [Integer, nil] index of the terminator, or nil if none yet
    def next_buffer_event_end(offset)
      lf = @buffer.index("\n\n", offset)
      crlf = @buffer.index("\r\n\r\n", offset)
      [lf, crlf].compact.min
    end

    # @param buffer [String] a partial-event SSE buffer
    # @raise [MCPClient::Errors::ConnectionError] when the buffer exceeds MAX_SSE_BUFFER_BYTES
    def enforce_sse_buffer_cap!(buffer)
      return if buffer.bytesize <= MAX_SSE_BUFFER_BYTES

      raise MCPClient::Errors::ConnectionError,
            "SSE event exceeded the maximum buffered size (#{MAX_SSE_BUFFER_BYTES} bytes) " \
            'without a terminator'
    end

    # Extract a single event from the buffer
    # @param event_end [Integer] the position where the event ends
    # @return [String] the extracted event data
    def extract_event(event_end)
      # Determine the line ending style and extract accordingly
      crlf_index = @buffer.index("\r\n\r\n")
      lf_index = @buffer.index("\n\n")
      if crlf_index && (lf_index.nil? || crlf_index < lf_index)
        @buffer.slice!(0, event_end + 4) # \r\n\r\n is 4 chars
      else
        @buffer.slice!(0, event_end + 2) # \n\n is 2 chars
      end
    end

    # Parse and handle an SSE event
    # Parses SSE format according to the W3C specification
    # @param event_data [String] the raw event data
    def parse_and_handle_event(event_data)
      event = { event: 'message', data: '', id: nil }
      data_lines = []

      event_data.each_line do |line|
        line = line.chomp
        next if line.empty? || line.start_with?(':') # Skip empty lines and comments

        if line.start_with?('event:')
          event[:event] = line[6..].strip
        elsif line.start_with?('data:')
          # SSE allows multiple data lines that should be joined with newlines
          data_lines << line[5..].strip
        elsif line.start_with?('id:')
          # Track event ID for resumability (MCP future enhancement). The id
          # is peer-controlled and gets echoed in the Last-Event-ID header, so
          # only a bounded, header-safe value is retained; the previous valid
          # cursor is kept when one is rejected.
          event[:id] = line[3..].strip
          @last_event_id = event[:id] if retainable_event_id?(event[:id])
        elsif line.start_with?('retry:')
          # SEP-1699: the client MUST respect the server's retry directive
          # (milliseconds) when reconnecting; zero is a valid directive.
          raw = line[6..].strip
          @sse_retry_ms = raw.to_i if raw.match?(/\A\d+\z/)
          @logger.debug("Server suggested retry delay: #{raw}ms") if @logger.level <= Logger::DEBUG
        end
      end

      event[:data] = data_lines.join("\n")

      # Only process non-empty data
      handle_server_message(event[:data]) unless event[:data].empty?
    end

    # Handle server messages (notifications and requests)
    # Processes ping/pong keepalive and server notifications
    # @param data [String] the JSON data from SSE event
    def handle_server_message(data)
      return if data.empty?

      begin
        message = JSON.parse(data)
        unless message.is_a?(Hash)
          # A JSON-parseable scalar/array is not a JSON-RPC message; dispatch
          # would raise on it. Log the type, never the value.
          @logger.warn("Skipping non-object JSON-RPC message on the events stream (#{message.class})")
          return
        end

        dispatch_server_message(message)
      rescue JSON::ParserError => e
        # The parser message names the failure position, not the payload; the
        # payload itself stays out of the log.
        @logger.error("Invalid JSON in server message: #{describe_parse_error(e, data)}")
      end
    end

    # Dispatch a parsed server message (request, ping, or notification).
    # Used for messages arriving on the GET events stream and for messages
    # interleaved on a POST SSE response stream.
    # @param message [Hash] the parsed JSON-RPC message
    def dispatch_server_message(message)
      # Host code reached from here -- a notification listener, a handler for
      # a server-initiated request -- may issue a tools/call of its own while
      # the response that carried this message is still being parsed. Give it
      # a slot of its own for the definition that call goes out under, so the
      # call still waiting for this response keeps its own
      # (MCPClient::CalledToolDefinition).
      called_tool_definition_slot { dispatch_server_message_now(message) }
    end

    # @param message [Hash] the parsed JSON-RPC message
    def dispatch_server_message_now(message)
      if modern? && message['method'] && message.key?('id')
        # MCP 2026-07-28: "The server MUST NOT send independent JSON-RPC
        # requests on this stream" — server-to-client interactions are
        # embedded in InputRequiredResult. There is no response channel
        # either (clients MUST NOT POST responses), so the request is dropped.
        @logger.warn("Ignoring server-initiated request #{message['method']} on a response stream: " \
                     'not permitted by MCP 2026-07-28')
        return
      end

      # Handle ping requests from server (keepalive mechanism)
      if message['method'] == 'ping' && message.key?('id')
        handle_ping_request(message['id'])
      elsif message['method'] && message.key?('id')
        # Handle server-to-client requests (MCP 2025-06-18)
        handle_server_request(message)
      elsif message['method'] && !message.key?('id')
        # Handle server notifications (messages without id)
        route_notification(message['method'], message['params'])
      elsif message.key?('id')
        # A response replayed on the events stream after its POST stream was
        # closed before delivery (SEP-1699 resumption)
        deliver_stream_response(message)
      end
    end

    # Handle ping request from server
    # Sends pong response to maintain session keepalive
    # @param ping_id [Integer, String] the ping request ID
    def handle_ping_request(ping_id)
      pong_response = {
        jsonrpc: '2.0',
        id: ping_id,
        result: {}
      }

      # Pongs go through the same bounded response path as every other
      # server-initiated reply, so a ping flood cannot fan out threads.
      post_jsonrpc_response(pong_response)
    end

    # Handle incoming JSON-RPC request from server (MCP 2025-06-18)
    # @param msg [Hash] the JSON-RPC request message
    # @return [void]
    def handle_server_request(msg)
      request_id = msg['id']
      method = msg['method']
      params = msg['params'] || {}

      @logger.debug("Received server request: #{method} (id: #{request_id})")

      case method
      when 'elicitation/create'
        handle_elicitation_create(request_id, params)
      when 'roots/list'
        handle_roots_list(request_id, params)
      when 'sampling/createMessage'
        handle_sampling_create_message(request_id, params)
      else
        # Unknown request method, send error response
        send_error_response(request_id, -32_601, "Method not found: #{method}")
      end
    rescue StandardError => e
      # The exception message is host-internal (file paths, connection
      # strings, library internals): log it locally, but answer the peer with
      # a constant message so failures cannot be used to probe the host.
      @logger.error("Error handling server request: #{e.message}")
      send_error_response(request_id, -32_603, 'Internal error')
    end

    # Handle elicitation/create request from server (MCP 2025-11-25)
    # @param request_id [String, Integer] the JSON-RPC request ID
    # @param params [Hash] the elicitation parameters
    # @return [void]
    def handle_elicitation_create(request_id, params)
      # Without a callback there is no user to interact with: answer with a
      # JSON-RPC error rather than fabricating a user "decline".
      unless @elicitation_request_callback
        @logger.warn('Received elicitation request but no callback registered')
        send_error_response(request_id, -32_601, 'Elicitation not supported: no handler configured')
        return
      end

      # Call the registered callback
      result = @elicitation_request_callback.call(request_id, params)

      # Send the response back to the server (echoing related-task _meta)
      send_elicitation_response(request_id, merge_related_task_meta(result, params))
    end

    # Handle roots/list request from server (MCP 2025-06-18)
    # @param request_id [String, Integer] the JSON-RPC request ID
    # @param params [Hash] the request parameters
    # @return [void]
    def handle_roots_list(request_id, params)
      # If no callback is registered, return empty roots list
      unless @roots_list_request_callback
        @logger.debug('Received roots/list request but no callback registered, returning empty list')
        send_roots_list_response(request_id, { 'roots' => [] })
        return
      end

      # Call the registered callback
      result = @roots_list_request_callback.call(request_id, params)

      # Send the response back to the server (echoing related-task _meta)
      send_roots_list_response(request_id, merge_related_task_meta(result, params))
    end

    # Handle sampling/createMessage request from server (MCP 2025-11-25)
    # @param request_id [String, Integer] the JSON-RPC request ID
    # @param params [Hash] the sampling parameters
    # @return [void]
    def handle_sampling_create_message(request_id, params)
      # If no callback is registered, return error
      unless @sampling_request_callback
        @logger.warn('Received sampling request but no callback registered, returning error')
        send_error_response(request_id, -1, 'Sampling not supported')
        return
      end

      # Call the registered callback
      result = @sampling_request_callback.call(request_id, params)

      # Send the response back to the server (echoing related-task _meta)
      send_sampling_response(request_id, merge_related_task_meta(result, params))
    end

    # Send roots/list response back to server via HTTP POST (MCP 2025-06-18)
    # @param request_id [String, Integer] the JSON-RPC request ID
    # @param result [Hash] the roots list result
    # @return [void]
    def send_roots_list_response(request_id, result)
      response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'result' => result
      }

      # Send response via HTTP POST
      post_jsonrpc_response(response)
    rescue StandardError => e
      @logger.error("Error sending roots/list response: #{e.message}")
    end

    # Send sampling response back to server via HTTP POST (MCP 2025-11-25)
    # @param request_id [String, Integer] the JSON-RPC request ID
    # @param result [Hash] the sampling result (role, content, model, stopReason)
    # @return [void]
    def send_sampling_response(request_id, result)
      # Check if result contains an error
      if result.is_a?(Hash) && result['error']
        send_error_response(request_id, result['error']['code'] || -1, result['error']['message'] || 'Sampling error')
        return
      end

      response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'result' => result
      }

      # Send response via HTTP POST
      post_jsonrpc_response(response)
    rescue StandardError => e
      @logger.error("Error sending sampling response: #{e.message}")
    end

    # Send elicitation response back to server via HTTP POST (MCP 2025-11-25)
    # The reply to a server's elicitation/create request is a standard
    # JSON-RPC response echoing the request id, POSTed like every other
    # response on this transport.
    # @param request_id [String, Integer] the JSON-RPC request ID
    # @param result [Hash] the elicitation result (action and optional content)
    # @return [void]
    def send_elicitation_response(request_id, result)
      # Error-shaped results become JSON-RPC error responses (e.g. -32602 for
      # an undeclared elicitation mode), mirroring the sampling error path.
      if result.is_a?(Hash) && result['error']
        send_error_response(request_id, result['error']['code'] || -32_603,
                            result['error']['message'] || 'Elicitation error')
        return
      end

      response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'result' => result
      }

      post_jsonrpc_response(response)
    rescue StandardError => e
      @logger.error("Error sending elicitation response: #{e.message}")
    end

    # Send error response back to server via HTTP POST (MCP 2025-06-18)
    # @param request_id [String, Integer] the JSON-RPC request ID
    # @param code [Integer] the error code
    # @param message [String] the error message
    # @return [void]
    def send_error_response(request_id, code, message)
      response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'error' => {
          'code' => code,
          'message' => message
        }
      }

      # Send response via HTTP POST to the endpoint
      post_jsonrpc_response(response)
    rescue StandardError => e
      @logger.error("Error sending error response: #{e.message}")
    end

    # Post a JSON-RPC response message to the server via HTTP
    # @param response [Hash] the JSON-RPC response
    # @return [void]
    # @private
    def post_jsonrpc_response(response)
      # Send the response in a separate thread to avoid blocking event
      # processing, but never beyond the concurrency budget: server requests
      # arrive at the peer's rate, and each unanswered POST would otherwise
      # pin one thread and one connection.
      unless acquire_response_post_slot
        log_response_post_saturation
        return
      end

      begin
        start_response_post_thread(response)
      rescue ThreadError => e
        # Thread.new failed, so the ensure inside the block never runs and the
        # reservation would leak. Eight such failures would silently mute this
        # instance's replies for the rest of its life, including after
        # reconnect (cleanup does not reset the counter).
        release_response_post_slot
        @logger.error("Failed to start response POST thread: #{e.message}")
      end
    end

    # Spawn the worker that POSTs one server-initiated response.
    # @param response [Hash] the JSON-RPC response
    # @return [Thread]
    def start_response_post_thread(response)
      Thread.new do
        conn = http_connection
        json_body = JSON.generate(response)

        resp = conn.post(@endpoint) do |req|
          @headers.each { |k, v| req.headers[k] = v }
          req.headers['Mcp-Session-Id'] = @session_id if @session_id
          req.headers['Mcp-Protocol-Version'] = @protocol_version if @protocol_version
          # MCP: authorization MUST be included in every HTTP request
          @oauth_provider&.apply_authorization(req)
          note_request_authorization(req.headers['Authorization'])
          req.body = json_body
        end

        if resp.success?
          @logger.debug("Sent JSON-RPC response: #{describe_jsonrpc_message(response)}")
        else
          @logger.warn("Failed to send JSON-RPC response: HTTP #{resp.status}")
        end
      rescue StandardError => e
        @logger.error("Failed to send JSON-RPC response: #{e.message}")
      ensure
        release_response_post_slot
      end
    end

    # Warn that the response-POST budget is saturated, at most once per
    # SATURATION_LOG_INTERVAL.
    #
    # The peer controls how often this path is reached, so logging every
    # rejection (at WARN, which the default logger emits) would just trade a
    # thread-exhaustion vector for a log-volume one. The peer-supplied request
    # id is deliberately omitted for the same reason.
    # @return [void]
    def log_response_post_saturation
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      dropped = @mutex.synchronize do
        @dropped_response_posts += 1
        next nil if @last_saturation_log_at && now - @last_saturation_log_at < SATURATION_LOG_INTERVAL

        @last_saturation_log_at = now
        @dropped_response_posts
      end
      return unless dropped

      @logger.warn("Dropping server-initiated responses: #{MAX_CONCURRENT_RESPONSE_POSTS} " \
                   "response POSTs already in flight (#{dropped} dropped so far)")
    end

    # Reserve one slot of the response-POST concurrency budget.
    # @return [Boolean] whether a slot was available
    def acquire_response_post_slot
      @mutex.synchronize do
        return false if @response_post_count >= MAX_CONCURRENT_RESPONSE_POSTS

        @response_post_count += 1
        true
      end
    end

    # Release a slot reserved by acquire_response_post_slot.
    # @return [void]
    def release_response_post_slot
      @mutex.synchronize { @response_post_count -= 1 }
    end
  end
end
