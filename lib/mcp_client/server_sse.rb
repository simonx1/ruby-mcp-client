# frozen_string_literal: true

require 'uri'
require 'json'
require 'monitor'
require 'logger'
require 'faraday'
require 'faraday/retry'
require 'faraday/follow_redirects'

module MCPClient
  # Implementation of MCP server that communicates via Server-Sent Events (SSE)
  # Useful for communicating with remote MCP servers over HTTP
  #
  # @note Elicitation Support (MCP 2025-06-18)
  #   This transport FULLY supports server-initiated elicitation requests via bidirectional
  #   JSON-RPC. The server sends elicitation/create requests via the SSE stream, and the
  #   client responds via HTTP POST to the RPC endpoint. This provides full elicitation
  #   capability for remote servers.
  class ServerSSE < ServerBase
    require_relative 'server_sse/sse_parser'
    require_relative 'server_sse/json_rpc_transport'

    include SseParser
    include JsonRpcTransport

    require_relative 'server_sse/reconnect_monitor'

    include ReconnectMonitor

    # Ratio of close_after timeout to ping interval
    CLOSE_AFTER_PING_RATIO = 2.5

    # Default values for connection monitoring
    DEFAULT_MAX_PING_FAILURES = 3
    DEFAULT_MAX_RECONNECT_ATTEMPTS = 5

    # Reconnection backoff constants
    BASE_RECONNECT_DELAY = 0.5
    MAX_RECONNECT_DELAY = 30
    JITTER_FACTOR = 0.25

    # @!attribute [r] base_url
    #   @return [String] The base URL of the MCP server
    # @!attribute [r] tools
    #   @return [Array<MCPClient::Tool>, nil] List of available tools (nil if not fetched yet)
    # @!attribute [r] prompts
    #   @return [Array<MCPClient::Prompt>, nil] List of available prompts (nil if not fetched yet)
    # @!attribute [r] resources
    #   @return [Array<MCPClient::Resource>, nil] List of available resources (nil if not fetched yet)
    attr_reader :base_url, :tools, :prompts, :resources

    # Server information from initialize response
    # @return [Hash, nil] Server information
    attr_reader :server_info

    # Server capabilities from initialize response
    # @return [Hash, nil] Server capabilities
    attr_reader :capabilities

    # @param base_url [String] The base URL of the MCP server
    # @param headers [Hash] Additional headers to include in requests
    # @param read_timeout [Integer] Read timeout in seconds (default: 30)
    # @param ping [Integer] Time in seconds after which to send ping if no activity (default: 10)
    # @param retries [Integer] number of retry attempts on transient errors
    # @param retry_backoff [Numeric] base delay in seconds for exponential backoff
    # @param name [String, nil] optional name for this server
    # @param logger [Logger, nil] optional logger
    def initialize(base_url:, headers: {}, read_timeout: 30, ping: 10,
                   retries: 0, retry_backoff: 1, name: nil, logger: nil)
      super(name: name)
      initialize_logger(logger)
      @max_retries = retries
      @retry_backoff = retry_backoff
      # Normalize base_url: preserve trailing slash if explicitly provided for SSE endpoints
      @base_url = base_url
      @headers = headers.merge({
                                 'Accept' => 'text/event-stream',
                                 'Cache-Control' => 'no-cache',
                                 'Connection' => 'keep-alive'
                               })
      # HTTP client is managed via Faraday
      @tools = nil
      @read_timeout = read_timeout
      @ping_interval = ping
      # Set close_after to a multiple of the ping interval
      @close_after = (ping * CLOSE_AFTER_PING_RATIO).to_i

      # SSE-provided JSON-RPC endpoint path for POST requests
      @rpc_endpoint = nil
      @tools_data = nil
      @request_id = 0
      @sse_results = {}
      @mutex = Monitor.new
      @buffer = ''
      @sse_connected = false
      @connection_established = false
      @connection_cv = @mutex.new_cond
      @initialized = false
      @auth_error = nil
      # Whether to use SSE transport; may disable if handshake fails
      @use_sse = true

      # Time of last activity
      @last_activity_time = Time.now
      @activity_timer_thread = nil
      @elicitation_request_callback = nil # MCP 2025-06-18
    end

    # Stream tool call fallback for SSE transport (yields single result)
    # @param tool_name [String]
    # @param parameters [Hash]
    # @return [Enumerator]
    def call_tool_streaming(tool_name, parameters)
      Enumerator.new do |yielder|
        yielder << call_tool(tool_name, parameters)
      end
    end

    # List all prompts available from the MCP server
    # @return [Array<MCPClient::Prompt>] list of available prompts
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::PromptGetError] for other errors during prompt listing
    def list_prompts
      @mutex.synchronize do
        return @prompts if @prompts
      end

      begin
        ensure_initialized

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
    # @return [Object] the result of the prompt interpolation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::PromptGetError] for other errors during prompt interpolation
    # @raise [MCPClient::Errors::ConnectionError] if server is disconnected
    def get_prompt(prompt_name, parameters)
      rpc_request('prompts/get', {
                    name: prompt_name,
                    arguments: parameters
                  })
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      # Re-raise connection/transport errors directly to match test expectations
      raise
    rescue StandardError => e
      # For all other errors, wrap in PromptGetError
      raise MCPClient::Errors::PromptGetError, "Error get prompt '#{prompt_name}': #{e.message}"
    end

    # List all resources available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resources array and optional nextCursor
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during resource listing
    def list_resources(cursor: nil)
      @mutex.synchronize do
        return @resources_result if @resources_result && !cursor
      end

      begin
        ensure_initialized

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
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during resource reading
    # @raise [MCPClient::Errors::ConnectionError] if server is disconnected
    def read_resource(uri)
      result = rpc_request('resources/read', { uri: uri })
      contents = result['contents'] || []
      contents.map { |content| MCPClient::ResourceContent.from_json(content) }
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      # Re-raise connection/transport errors directly to match test expectations
      raise
    rescue StandardError => e
      # For all other errors, wrap in ResourceReadError
      raise MCPClient::Errors::ResourceReadError, "Error reading resource '#{uri}': #{e.message}"
    end

    # List all resource templates available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resourceTemplates array and optional nextCursor
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during resource template listing
    def list_resource_templates(cursor: nil)
      ensure_initialized
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
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during subscription
    def subscribe_resource(uri)
      ensure_initialized
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
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during unsubscription
    def unsubscribe_resource(uri)
      ensure_initialized
      rpc_request('resources/unsubscribe', { uri: uri })
      true
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error unsubscribing from resource '#{uri}': #{e.message}"
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
        ensure_initialized

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
    # @return [Object] the result of the tool invocation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool execution
    # @raise [MCPClient::Errors::ConnectionError] if server is disconnected
    # Call a tool with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation (with string keys for backward compatibility)
    def call_tool(tool_name, parameters)
      rpc_request('tools/call', {
                    name: tool_name,
                    arguments: parameters
                  })
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      # Re-raise connection/transport errors directly to match test expectations
      raise
    rescue StandardError => e
      # For all other errors, wrap in ToolCallError
      raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
    end

    # Connect to the MCP server over HTTP/HTTPS with SSE
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      return true if @mutex.synchronize { @connection_established }

      # Check for pre-existing auth error (needed for tests)
      pre_existing_auth_error = @mutex.synchronize { @auth_error }

      begin
        # Don't reset auth error if it's pre-existing
        @mutex.synchronize { @auth_error = nil } unless pre_existing_auth_error

        start_sse_thread
        effective_timeout = [@read_timeout || 30, 30].min
        wait_for_connection(timeout: effective_timeout)
        start_activity_monitor
        true
      rescue MCPClient::Errors::ConnectionError => e
        cleanup
        # Simply pass through any ConnectionError without wrapping it again
        # This prevents duplicate error messages in the stack
        raise e
      rescue StandardError => e
        cleanup
        # Check for stored auth error first as it's more specific
        auth_error = @mutex.synchronize { @auth_error }
        raise MCPClient::Errors::ConnectionError, auth_error if auth_error

        raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
      end
    end

    # Clean up the server connection
    # Properly closes HTTP connections and clears cached state
    #
    # @note This method preserves ping failure and reconnection metrics between
    #   reconnection attempts, allowing the client to track failures across
    #   multiple connection attempts. This is essential for proper reconnection
    #   logic and exponential backoff.
    def cleanup
      @mutex.synchronize do
        # Set flags first before killing threads to prevent race conditions
        # where threads might check flags after they're set but before they're killed
        @connection_established = false
        @sse_connected = false
        @initialized = false # Reset initialization state for reconnection

        # Log cleanup for debugging
        @logger.debug('Cleaning up SSE connection')

        # Store threads locally to avoid race conditions
        sse_thread = @sse_thread
        activity_thread = @activity_timer_thread

        # Clear thread references first
        @sse_thread = nil
        @activity_timer_thread = nil

        # Kill threads outside the critical section
        begin
          sse_thread&.kill
        rescue StandardError => e
          @logger.debug("Error killing SSE thread: #{e.message}")
        end

        begin
          activity_thread&.kill
        rescue StandardError => e
          @logger.debug("Error killing activity thread: #{e.message}")
        end

        if @http_client
          @http_client.finish if @http_client.started?
          @http_client = nil
        end

        # Close Faraday connections if they exist
        @rpc_conn = nil
        @sse_conn = nil

        @tools = nil
        # Don't clear auth error as we need it for reporting the correct error
        # Don't reset @consecutive_ping_failures or @reconnect_attempts as they're tracked across reconnections
      end
    end

    # Register a callback for elicitation requests (MCP 2025-06-18)
    # @param block [Proc] callback that receives (request_id, params) and returns response hash
    # @return [void]
    def on_elicitation_request(&block)
      @elicitation_request_callback = block
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
      else
        # Unknown request method, send error response
        send_error_response(request_id, -32_601, "Method not found: #{method}")
      end
    rescue StandardError => e
      @logger.error("Error handling server request: #{e.message}")
      send_error_response(request_id, -32_603, "Internal error: #{e.message}")
    end

    # Handle elicitation/create request from server (MCP 2025-06-18)
    # @param request_id [String, Integer] the JSON-RPC request ID
    # @param params [Hash] the elicitation parameters
    # @return [void]
    def handle_elicitation_create(request_id, params)
      # If no callback is registered, decline the request
      unless @elicitation_request_callback
        @logger.warn('Received elicitation request but no callback registered, declining')
        send_elicitation_response(request_id, { 'action' => 'decline' })
        return
      end

      # Call the registered callback
      result = @elicitation_request_callback.call(request_id, params)

      # Send the response back to the server
      send_elicitation_response(request_id, result)
    end

    # Send elicitation response back to server via HTTP POST (MCP 2025-06-18)
    # @param request_id [String, Integer] the JSON-RPC request ID
    # @param result [Hash] the elicitation result (action and optional content)
    # @return [void]
    def send_elicitation_response(request_id, result)
      ensure_initialized

      response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'result' => result
      }

      # Send response via HTTP POST to the RPC endpoint
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
      ensure_initialized

      response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'error' => {
          'code' => code,
          'message' => message
        }
      }

      # Send response via HTTP POST to the RPC endpoint
      post_jsonrpc_response(response)
    rescue StandardError => e
      @logger.error("Error sending error response: #{e.message}")
    end

    # Post a JSON-RPC response message to the server via HTTP
    # @param response [Hash] the JSON-RPC response
    # @return [void]
    # @private
    def post_jsonrpc_response(response)
      unless @rpc_endpoint
        @logger.error('Cannot send response: RPC endpoint not available')
        return
      end

      # Use the same connection pattern as post_json_rpc_request
      uri = URI.parse(@base_url)
      base = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      @rpc_conn ||= create_json_rpc_connection(base)

      json_body = JSON.generate(response)

      @rpc_conn.post do |req|
        req.url @rpc_endpoint
        req.headers['Content-Type'] = 'application/json'
        @headers.each { |k, v| req.headers[k] = v }
        req.body = json_body
      end

      @logger.debug("Sent response via HTTP POST: #{json_body}")
    rescue StandardError => e
      @logger.error("Failed to send response via HTTP POST: #{e.message}")
    end

    private

    # Start the SSE thread to listen for events
    # This thread handles the long-lived Server-Sent Events connection
    # @return [Thread] the SSE thread
    # @private
    def start_sse_thread
      return if @sse_thread&.alive?

      @sse_thread = Thread.new do
        handle_sse_connection
      end
    end

    # Handle the SSE connection in a separate method to reduce method size
    # @return [void]
    # @private
    def handle_sse_connection
      uri = URI.parse(@base_url)
      sse_path = uri.request_uri
      conn = setup_sse_connection(uri)

      reset_sse_connection_state

      begin
        establish_sse_connection(conn, sse_path)
      rescue MCPClient::Errors::ConnectionError => e
        reset_connection_state
        raise e
      rescue StandardError => e
        @logger.error("SSE connection error: #{e.message}")
        reset_connection_state
      ensure
        @mutex.synchronize { @sse_connected = false }
      end
    end

    # Reset SSE connection state
    # @return [void]
    # @private
    def reset_sse_connection_state
      @mutex.synchronize do
        @sse_connected = false
        @connection_established = false
      end
    end

    # Establish SSE connection with error handling
    # @param conn [Faraday::Connection] the Faraday connection to use
    # @param sse_path [String] the SSE endpoint path
    # @return [void]
    # @private
    def establish_sse_connection(conn, sse_path)
      conn.get(sse_path) do |req|
        @headers.each { |k, v| req.headers[k] = v }

        req.options.on_data = proc do |chunk, _bytes|
          process_sse_chunk(chunk.dup) if chunk && !chunk.empty?
        end
      end
    rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
      handle_sse_auth_response_error(e)
    rescue Faraday::ConnectionFailed => e
      handle_sse_connection_failed(e)
    rescue Faraday::Error => e
      handle_sse_general_error(e)
    end

    # Handle auth errors from SSE response
    # @param err [Faraday::Error] the authorization error
    # @return [void]
    # @private
    def handle_sse_auth_response_error(err)
      error_status = err.response ? err.response[:status] : 'unknown'
      auth_error = "Authorization failed: HTTP #{error_status}"

      @mutex.synchronize do
        @auth_error = auth_error
        @connection_established = false
        @connection_cv.broadcast
      end
      @logger.error(auth_error)
    end

    # Handle connection failures in SSE
    # @param err [Faraday::ConnectionFailed] the connection failure error
    # @return [void]
    # @raise [Faraday::ConnectionFailed] re-raises the original error
    # @private
    def handle_sse_connection_failed(err)
      @logger.error("Failed to connect to MCP server at #{@base_url}: #{err.message}")

      @mutex.synchronize do
        @connection_established = false
        @connection_cv.broadcast
      end
      raise
    end

    # Handle general Faraday errors in SSE
    # @param err [Faraday::Error] the general Faraday error
    # @return [void]
    # @raise [Faraday::Error] re-raises the original error
    # @private
    def handle_sse_general_error(err)
      @logger.error("Failed SSE connection: #{err.message}")

      @mutex.synchronize do
        @connection_established = false
        @connection_cv.broadcast
      end
      raise
    end

    # Process an SSE chunk from the server
    # @param chunk [String] the chunk to process
    def process_sse_chunk(chunk)
      @logger.debug("Processing SSE chunk: #{chunk.inspect}")

      # Only record activity for real events
      record_activity if chunk.include?('event:')

      # Check for direct JSON error responses (which aren't proper SSE events)
      handle_json_error_response(chunk)

      event_buffers = extract_complete_events(chunk)

      # Process extracted events outside the mutex to avoid deadlocks
      event_buffers&.each { |event_data| parse_and_handle_sse_event(event_data) }
    end

    # Check if the error represents an authorization error
    # @param error_message [String] The error message from the server
    # @param error_code [Integer, nil] The error code if available
    # @return [Boolean] True if it's an authorization error
    # @private
    def authorization_error?(error_message, error_code)
      return true if error_message.include?('Unauthorized') || error_message.include?('authentication')
      return true if [401, -32_000].include?(error_code)

      false
    end

    # Handle JSON error responses embedded in SSE chunks
    # @param chunk [String] the chunk to check for JSON errors
    # @return [void]
    # @raise [MCPClient::Errors::ConnectionError] if authentication error is found
    # @private
    def handle_json_error_response(chunk)
      return unless chunk.start_with?('{') && chunk.include?('"error"') &&
                    (chunk.include?('Unauthorized') || chunk.include?('authentication'))

      begin
        data = JSON.parse(chunk)
        if data['error']
          error_message = data['error']['message'] || 'Unknown server error'

          @mutex.synchronize do
            @auth_error = "Authorization failed: #{error_message}"
            @connection_established = false
            @connection_cv.broadcast
          end

          raise MCPClient::Errors::ConnectionError, "Authorization failed: #{error_message}"
        end
      rescue JSON::ParserError
        # Not valid JSON, process normally
      end
    end

    # Extract complete SSE events from the buffer
    # @param chunk [String] the chunk to add to the buffer
    # @return [Array<String>, nil] array of complete events or nil if none
    # @private
    def extract_complete_events(chunk)
      event_buffers = nil
      @mutex.synchronize do
        @buffer += chunk

        # Extract all complete events from the buffer
        # Handle both Unix (\n\n) and Windows (\r\n\r\n) line endings
        event_buffers = []
        while (event_end = @buffer.index("\n\n") || @buffer.index("\r\n\r\n"))
          event_data = extract_single_event(event_end)
          event_buffers << event_data
        end
      end
      event_buffers
    end

    # Extract a single event from the buffer
    # @param event_end [Integer] the position where the event ends
    # @return [String] the extracted event data
    # @private
    def extract_single_event(event_end)
      # Determine the line ending style and extract accordingly
      crlf_index = @buffer.index("\r\n\r\n")
      lf_index = @buffer.index("\n\n")
      if crlf_index && (lf_index.nil? || crlf_index < lf_index)
        @buffer.slice!(0, event_end + 4) # \r\n\r\n is 4 chars
      else
        @buffer.slice!(0, event_end + 2) # \n\n is 2 chars
      end
    end

    # Handle authorization error in SSE message
    # @param error_message [String] The error message from the server
    # @return [void]
    # @raise [MCPClient::Errors::ConnectionError] with an authentication error message
    # @private
    def handle_sse_auth_error_message(error_message)
      @mutex.synchronize do
        @auth_error = "Authorization failed: #{error_message}"
        @connection_established = false
        @connection_cv.broadcast
      end

      raise MCPClient::Errors::ConnectionError, "Authorization failed: #{error_message}"
    end

    # Request the prompts list using JSON-RPC
    # @return [Array<Hash>] the prompts data
    # @raise [MCPClient::Errors::PromptGetError] if prompts list retrieval fails
    # @private
    def request_prompts_list
      @mutex.synchronize do
        return @prompts_data if @prompts_data
      end

      result = rpc_request('prompts/list')

      if result && result['prompts']
        @mutex.synchronize do
          @prompts_data = result['prompts']
        end
        return @mutex.synchronize { @prompts_data.dup }
      elsif result
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
    # @private
    def request_resources_list
      @mutex.synchronize do
        return @resources_data if @resources_data
      end

      result = rpc_request('resources/list')

      if result && result['resources']
        @mutex.synchronize do
          @resources_data = result['resources']
        end
        return @mutex.synchronize { @resources_data.dup }
      elsif result
        @mutex.synchronize do
          @resources_data = result
        end
        return @mutex.synchronize { @resources_data.dup }
      end

      raise MCPClient::Errors::ResourceReadError, 'Failed to get resources list from JSON-RPC request'
    end

    # Request the tools list using JSON-RPC
    # @return [Array<Hash>] the tools data
    # @raise [MCPClient::Errors::ToolCallError] if tools list retrieval fails
    # @private
    def request_tools_list
      @mutex.synchronize do
        return @tools_data if @tools_data
      end

      result = rpc_request('tools/list')

      if result && result['tools']
        @mutex.synchronize do
          @tools_data = result['tools']
        end
        return @mutex.synchronize { @tools_data.dup }
      elsif result
        @mutex.synchronize do
          @tools_data = result
        end
        return @mutex.synchronize { @tools_data.dup }
      end

      raise MCPClient::Errors::ToolCallError, 'Failed to get tools list from JSON-RPC request'
    end
  end
end
