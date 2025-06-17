# frozen_string_literal: true

require 'uri'
require 'json'
require 'monitor'
require 'logger'
require 'faraday'
require 'faraday/retry'

module MCPClient
  # Implementation of MCP server that communicates via Server-Sent Events (SSE)
  # Useful for communicating with remote MCP servers over HTTP
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
    # @!attribute [r] server_info
    #   @return [Hash, nil] Server information from initialize response
    # @!attribute [r] capabilities
    #   @return [Hash, nil] Server capabilities from initialize response
    attr_reader :base_url, :tools, :server_info, :capabilities

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
      @logger = logger || Logger.new($stdout, level: Logger::WARN)
      @logger.progname = self.class.name
      @logger.formatter = proc { |severity, _datetime, progname, msg| "#{severity} [#{progname}] #{msg}\n" }
      @max_retries = retries
      @retry_backoff = retry_backoff
      # Normalize base_url: strip any trailing slash, use exactly as provided
      @base_url = base_url.chomp('/')
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
      if chunk.start_with?('{') && chunk.include?('"error"') &&
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

      event_buffers = nil
      @mutex.synchronize do
        @buffer += chunk

        # Extract all complete events from the buffer
        event_buffers = []
        while (event_end = @buffer.index("\n\n"))
          event_data = @buffer.slice!(0, event_end + 2)
          event_buffers << event_data
        end
      end

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
