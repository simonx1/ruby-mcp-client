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
      @faraday_config = opts[:faraday_config]
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
      @oauth_provider = opts[:oauth_provider]

      # SSE events connection state
      @events_connection = nil
      @events_thread = nil
      @buffer = '' # Buffer for partial SSE event data
      @elicitation_request_callback = nil # MCP 2025-06-18
      @roots_list_request_callback = nil # MCP 2025-06-18
      @sampling_request_callback = nil # MCP 2025-06-18
    end

    # Connect to the MCP server over Streamable HTTP
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      return true if @mutex.synchronize { @connection_established }

      begin
        @mutex.synchronize do
          @connection_established = false
          @initialized = false
        end

        # Test connectivity with a simple HTTP request
        test_connection

        # Perform MCP initialization handshake
        perform_initialize

        # Start long-lived GET connection for server events
        start_events_connection

        @mutex.synchronize do
          @connection_established = true
          @initialized = true
        end

        true
      rescue MCPClient::Errors::ConnectionError => e
        cleanup
        raise e
      rescue StandardError => e
        cleanup
        raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
      end
    end

    # List all tools available from the MCP server
    # @return [Array<MCPClient::Tool>] list of available tools
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool listing
    def list_tools
      @mutex.synchronize do
        return @tools if @tools
      end

      begin
        ensure_connected

        tools_data = request_tools_list
        @mutex.synchronize do
          @tools = tools_data.map do |tool_data|
            MCPClient::Tool.from_json(tool_data, server: self)
          end
        end

        @mutex.synchronize { @tools }
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
      rpc_request('tools/call', {
                    name: tool_name,
                    arguments: parameters.except(:_meta),
                    **parameters.slice(:_meta)
                  })
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      # Re-raise connection/transport errors directly to match test expectations
      raise
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
      params = { ref: ref, argument: argument }
      params[:context] = context if context
      result = rpc_request('completion/complete', params)
      result['completion'] || { 'values' => [] }
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
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
      rpc_request('logging/setLevel', { level: level })
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ServerError, "Error setting log level: #{e.message}"
    end

    # List all prompts available from the MCP server
    # @return [Array<MCPClient::Prompt>] list of available prompts
    # @raise [MCPClient::Errors::PromptGetError] if prompts list retrieval fails
    def list_prompts
      @mutex.synchronize do
        return @prompts if @prompts
      end

      begin
        ensure_connected

        prompts_data = request_prompts_list
        @mutex.synchronize do
          @prompts = prompts_data.map do |prompt_data|
            MCPClient::Prompt.from_json(prompt_data, server: self)
          end
        end

        @mutex.synchronize { @prompts }
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        # Re-raise these errors directly
        raise
      rescue StandardError => e
        raise MCPClient::Errors::PromptGetError, "Error listing prompts: #{e.message}"
      end
    end

    # Get a prompt with the given parameters
    # @param prompt_name [String] the name of the prompt to get
    # @param parameters [Hash] the parameters to pass to the prompt
    # @return [Object] the result of the prompt (with string keys for backward compatibility)
    # @raise [MCPClient::Errors::PromptGetError] if prompt retrieval fails
    def get_prompt(prompt_name, parameters)
      rpc_request('prompts/get', {
                    name: prompt_name,
                    arguments: parameters.except(:_meta),
                    **parameters.slice(:_meta)
                  })
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      # Re-raise connection/transport errors directly
      raise
    rescue StandardError => e
      # For all other errors, wrap in PromptGetError
      raise MCPClient::Errors::PromptGetError, "Error getting prompt '#{prompt_name}': #{e.message}"
    end

    # List all resources available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resources array and optional nextCursor
    # @raise [MCPClient::Errors::ResourceReadError] if resources list retrieval fails
    def list_resources(cursor: nil)
      @mutex.synchronize do
        return @resources_result if @resources_result && !cursor
      end

      begin
        ensure_connected

        params = {}
        params['cursor'] = cursor if cursor
        result = rpc_request('resources/list', params)

        resources = (result['resources'] || []).map do |resource_data|
          MCPClient::Resource.from_json(resource_data, server: self)
        end

        resources_result = { 'resources' => resources, 'nextCursor' => result['nextCursor'] }

        @mutex.synchronize do
          @resources_result = resources_result unless cursor
        end

        resources_result
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        # Re-raise these errors directly
        raise
      rescue StandardError => e
        raise MCPClient::Errors::ResourceReadError, "Error listing resources: #{e.message}"
      end
    end

    # Read a resource by its URI
    # @param uri [String] the URI of the resource to read
    # @return [Array<MCPClient::ResourceContent>] array of resource contents
    # @raise [MCPClient::Errors::ResourceReadError] if resource reading fails
    def read_resource(uri)
      result = rpc_request('resources/read', { uri: uri })
      contents = result['contents'] || []
      contents.map { |content| MCPClient::ResourceContent.from_json(content) }
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
      params = {}
      params['cursor'] = cursor if cursor
      result = rpc_request('resources/templates/list', params)

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
      rpc_request('resources/subscribe', { uri: uri })
      true
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error subscribing to resource '#{uri}': #{e.message}"
    end

    # Unsubscribe from resource updates
    # @param uri [String] the URI of the resource to unsubscribe from
    # @return [Boolean] true if unsubscription successful
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during unsubscription
    def unsubscribe_resource(uri)
      rpc_request('resources/unsubscribe', { uri: uri })
      true
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error unsubscribing from resource '#{uri}': #{e.message}"
    end

    # Override apply_request_headers to add session and SSE headers for MCP protocol
    def apply_request_headers(req, request)
      super

      # Add session header if we have one (for non-initialize requests)
      if @session_id && request['method'] != 'initialize'
        req.headers['Mcp-Session-Id'] = @session_id
        @logger.debug("Adding session header: Mcp-Session-Id: #{@session_id}")
      end

      # Add Last-Event-ID header for resumability (if available)
      return unless @last_event_id

      req.headers['Last-Event-ID'] = @last_event_id
      @logger.debug("Adding Last-Event-ID header: #{@last_event_id}")
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
      @mutex.synchronize do
        return unless @connection_established || @initialized

        @logger.info('Cleaning up Streamable HTTP connection')

        # Mark connection as closed to stop reconnection attempts
        @connection_established = false
        @initialized = false

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

        # Clear cached data
        @tools = nil
        @tools_data = nil
        @prompts = nil
        @prompts_data = nil
        @resources = nil
        @resources_data = nil
        @buffer = ''

        @logger.info('Cleanup completed')
      end
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

    # Register a callback for sampling requests (MCP 2025-06-18)
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
        faraday_config: nil
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
      return if @mutex.synchronize { @connection_established && @initialized }

      @logger.debug('Connection not active, attempting to reconnect before request')
      cleanup
      connect
    end

    # Request the tools list using JSON-RPC
    # @return [Array<Hash>] the tools data
    # @raise [MCPClient::Errors::ToolCallError] if tools list retrieval fails
    def request_tools_list
      @mutex.synchronize do
        return @tools_data if @tools_data
      end

      result = rpc_request('tools/list')

      if result.is_a?(Hash) && result['tools']
        @mutex.synchronize do
          @tools_data = result['tools']
        end
        return @mutex.synchronize { @tools_data.dup }
      elsif result.is_a?(Array) || result
        @mutex.synchronize do
          @tools_data = result
        end
        return @mutex.synchronize { @tools_data.dup }
      end

      raise MCPClient::Errors::ToolCallError, 'Failed to get tools list from JSON-RPC request'
    end

    # Request the prompts list using JSON-RPC
    # @return [Array<Hash>] the prompts data
    # @raise [MCPClient::Errors::PromptGetError] if prompts list retrieval fails
    def request_prompts_list
      @mutex.synchronize do
        return @prompts_data if @prompts_data
      end

      result = rpc_request('prompts/list')

      if result.is_a?(Hash) && result['prompts']
        @mutex.synchronize do
          @prompts_data = result['prompts']
        end
        return @mutex.synchronize { @prompts_data.dup }
      elsif result.is_a?(Array) || result
        @mutex.synchronize do
          @prompts_data = result
        end
        return @mutex.synchronize { @prompts_data.dup }
      end

      raise MCPClient::Errors::PromptGetError, 'Failed to get prompts list from JSON-RPC request'
    end

    # Request the resources list using JSON-RPC
    # @return [Array<Hash>] the resources data
    # @raise [MCPClient::Errors::ResourceReadError] if resources list retrieval fails
    def request_resources_list
      @mutex.synchronize do
        return @resources_data if @resources_data
      end

      result = rpc_request('resources/list')

      if result.is_a?(Hash) && result['resources']
        @mutex.synchronize do
          @resources_data = result['resources']
        end
        return @mutex.synchronize { @resources_data.dup }
      elsif result.is_a?(Array) || result
        @mutex.synchronize do
          @resources_data = result
        end
        return @mutex.synchronize { @resources_data.dup }
      end

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
        sleep reconnect_delay
        reconnect_delay = [reconnect_delay * 2, SSE_MAX_RECONNECT_DELAY].min

      # Intentional shutdown
      rescue Net::ReadTimeout, Faraday::TimeoutError
        # Timeout after inactivity - this is expected for long-lived connections
        break unless @mutex.synchronize { @connection_established }

        @logger.debug('Events connection timed out after inactivity, reconnecting...')
        sleep reconnect_delay
      rescue Faraday::ConnectionFailed => e
        break unless @mutex.synchronize { @connection_established }

        @logger.warn("Events connection failed: #{e.message}, retrying in #{reconnect_delay}s...")
        sleep reconnect_delay
        reconnect_delay = [reconnect_delay * 2, SSE_MAX_RECONNECT_DELAY].min
      rescue StandardError => e
        break unless @mutex.synchronize { @connection_established }

        @logger.error("Unexpected error in events connection: #{e.class} - #{e.message}")
        @logger.debug(e.backtrace.join("\n")) if @logger.level <= Logger::DEBUG
        sleep reconnect_delay
        reconnect_delay = [reconnect_delay * 2, SSE_MAX_RECONNECT_DELAY].min
      end
    ensure
      @logger.info('Events connection thread terminated')
    end

    # Apply headers for events connection
    # @param req [Faraday::Request] HTTP request
    def apply_events_headers(req)
      @headers.each { |k, v| req.headers[k] = v }
      req.headers['Mcp-Session-Id'] = @session_id if @session_id
    end

    # Process event chunks from the server
    # Buffers partial chunks and processes complete SSE events
    # @param chunk [String] the chunk to process
    def process_event_chunk(chunk)
      @logger.debug("Processing event chunk: #{chunk.inspect}") if @logger.level <= Logger::DEBUG

      @mutex.synchronize do
        @buffer += chunk

        # Extract complete events (SSE format: events end with double newline)
        while (event_end = @buffer.index("\n\n") || @buffer.index("\r\n\r\n"))
          event_data = extract_event(event_end)
          parse_and_handle_event(event_data)
        end
      end
    rescue StandardError => e
      @logger.error("Error processing event chunk: #{e.message}")
      @logger.debug(e.backtrace.join("\n")) if @logger.level <= Logger::DEBUG
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
          # Track event ID for resumability (MCP future enhancement)
          event[:id] = line[3..].strip
          @last_event_id = event[:id]
        elsif line.start_with?('retry:')
          # Server can suggest reconnection delay (in milliseconds)
          retry_ms = line[6..].strip.to_i
          @logger.debug("Server suggested retry delay: #{retry_ms}ms") if @logger.level <= Logger::DEBUG
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

        # Handle ping requests from server (keepalive mechanism)
        if message['method'] == 'ping' && message.key?('id')
          handle_ping_request(message['id'])
        elsif message['method'] && message.key?('id')
          # Handle server-to-client requests (MCP 2025-06-18)
          handle_server_request(message)
        elsif message['method'] && !message.key?('id')
          # Handle server notifications (messages without id)
          @notification_callback&.call(message['method'], message['params'])
        end
      rescue JSON::ParserError => e
        @logger.error("Invalid JSON in server message: #{e.message}")
        @logger.debug("Raw data: #{data.inspect}") if @logger.level <= Logger::DEBUG
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

      # Send pong response in a separate thread to avoid blocking event processing
      Thread.new do
        conn = http_connection
        response = conn.post(@endpoint) do |req|
          @headers.each { |k, v| req.headers[k] = v }
          req.headers['Mcp-Session-Id'] = @session_id if @session_id
          req.body = pong_response.to_json
        end

        if response.success?
          @logger.debug("Sent pong response for ping ID: #{ping_id}") if @logger.level <= Logger::DEBUG
        else
          @logger.warn("Failed to send pong response: HTTP #{response.status}")
        end
      rescue StandardError => e
        @logger.error("Failed to send pong response: #{e.message}")
      end
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
      @logger.error("Error handling server request: #{e.message}")
      send_error_response(request_id, -32_603, "Internal error: #{e.message}")
    end

    # Handle elicitation/create request from server (MCP 2025-06-18)
    # @param request_id [String, Integer] the JSON-RPC request ID (used as elicitationId)
    # @param params [Hash] the elicitation parameters
    # @return [void]
    def handle_elicitation_create(request_id, params)
      # The request_id is the elicitationId per MCP spec
      elicitation_id = request_id

      # If no callback is registered, decline the request
      unless @elicitation_request_callback
        @logger.warn('Received elicitation request but no callback registered, declining')
        send_elicitation_response(elicitation_id, { 'action' => 'decline' })
        return
      end

      # Call the registered callback
      result = @elicitation_request_callback.call(request_id, params)

      # Send the response back to the server
      send_elicitation_response(elicitation_id, result)
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

      # Send the response back to the server
      send_roots_list_response(request_id, result)
    end

    # Handle sampling/createMessage request from server (MCP 2025-06-18)
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

      # Send the response back to the server
      send_sampling_response(request_id, result)
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

    # Send sampling response back to server via HTTP POST (MCP 2025-06-18)
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

    # Send elicitation response back to server via HTTP POST (MCP 2025-06-18)
    # For streamable HTTP, this is sent as a JSON-RPC request (not response)
    # because HTTP is unidirectional.
    # @param elicitation_id [String] the elicitation ID from the server
    # @param result [Hash] the elicitation result (action and optional content)
    # @return [void]
    def send_elicitation_response(elicitation_id, result)
      params = {
        'elicitationId' => elicitation_id,
        'action' => result['action']
      }

      # Only include content if present (typically for 'accept' action)
      params['content'] = result['content'] if result['content']

      request = {
        'jsonrpc' => '2.0',
        'method' => 'elicitation/response',
        'params' => params
      }

      # Send as a JSON-RPC request via HTTP POST
      post_jsonrpc_response(request)
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
      # Send response in a separate thread to avoid blocking event processing
      Thread.new do
        conn = http_connection
        json_body = JSON.generate(response)

        resp = conn.post(@endpoint) do |req|
          @headers.each { |k, v| req.headers[k] = v }
          req.headers['Mcp-Session-Id'] = @session_id if @session_id
          req.body = json_body
        end

        if resp.success?
          @logger.debug("Sent JSON-RPC response: #{json_body}")
        else
          @logger.warn("Failed to send JSON-RPC response: HTTP #{resp.status}")
        end
      rescue StandardError => e
        @logger.error("Failed to send JSON-RPC response: #{e.message}")
      end
    end
  end
end
