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
    # Ratio of close_after timeout to ping interval
    CLOSE_AFTER_PING_RATIO = 2.5

    attr_reader :base_url, :tools, :server_info, :capabilities

    # @param base_url [String] The base URL of the MCP server
    # @param headers [Hash] Additional headers to include in requests
    # @param read_timeout [Integer] Read timeout in seconds (default: 30)
    # @param ping [Integer] Time in seconds after which to send ping if no activity (default: 10)
    # @param retries [Integer] number of retry attempts on transient errors
    # @param retry_backoff [Numeric] base delay in seconds for exponential backoff
    # @param logger [Logger, nil] optional logger
    def initialize(base_url:, headers: {}, read_timeout: 30, ping: 10,
                   retries: 0, retry_backoff: 1, logger: nil)
      super()
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

      ensure_initialized

      begin
        tools_data = request_tools_list
        @mutex.synchronize do
          @tools = tools_data.map do |tool_data|
            MCPClient::Tool.from_json(tool_data)
          end
        end

        @mutex.synchronize { @tools }
      rescue MCPClient::Errors::TransportError
        # Re-raise TransportError directly
        raise
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
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
    def call_tool(tool_name, parameters)
      ensure_initialized

      begin
        request_id = @mutex.synchronize { @request_id += 1 }

        json_rpc_request = {
          jsonrpc: '2.0',
          id: request_id,
          method: 'tools/call',
          params: {
            name: tool_name,
            arguments: parameters
          }
        }

        send_jsonrpc_request(json_rpc_request)
      rescue MCPClient::Errors::TransportError
        # Re-raise TransportError directly
        raise
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
      rescue StandardError => e
        raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
      end
    end

    # Connect to the MCP server over HTTP/HTTPS with SSE
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      return true if @mutex.synchronize { @connection_established }

      begin
        start_sse_thread
        effective_timeout = [@read_timeout || 30, 30].min
        wait_for_connection(timeout: effective_timeout)
        start_activity_monitor
        true
      rescue MCPClient::Errors::ConnectionError => e
        cleanup
        # Check for stored auth error first, as it's more specific
        auth_error = @mutex.synchronize { @auth_error }
        raise MCPClient::Errors::ConnectionError, auth_error if auth_error

        raise MCPClient::Errors::ConnectionError, e.message if e.message.include?('Authorization failed')

        raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
      rescue StandardError => e
        cleanup
        # Check for stored auth error
        auth_error = @mutex.synchronize { @auth_error }
        raise MCPClient::Errors::ConnectionError, auth_error if auth_error

        raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
      end
    end

    # Clean up the server connection
    # Properly closes HTTP connections and clears cached tools
    def cleanup
      @mutex.synchronize do
        begin
          @sse_thread&.kill
        rescue StandardError
          nil
        end
        @sse_thread = nil

        begin
          @activity_timer_thread&.kill
        rescue StandardError
          nil
        end
        @activity_timer_thread = nil

        if @http_client
          @http_client.finish if @http_client.started?
          @http_client = nil
        end

        @tools = nil
        @connection_established = false
        @sse_connected = false
        # Don't clear auth error as we need it for reporting the correct error
      end
    end

    # Generic JSON-RPC request: send method with params and return result
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the request
    # @return [Object] result from JSON-RPC response
    def rpc_request(method, params = {})
      ensure_initialized
      with_retry do
        request_id = @mutex.synchronize { @request_id += 1 }
        request = { jsonrpc: '2.0', id: request_id, method: method, params: params }
        send_jsonrpc_request(request)
      end
    end

    # Send a JSON-RPC notification (no response expected)
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the notification
    # @return [void]
    def rpc_notify(method, params = {})
      ensure_initialized
      uri = URI.parse(@base_url)
      base = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      rpc_ep = @mutex.synchronize { @rpc_endpoint }
      @rpc_conn ||= Faraday.new(url: base) do |f|
        f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
        f.options.open_timeout = @read_timeout
        f.options.timeout = @read_timeout
        f.adapter Faraday.default_adapter
      end
      response = @rpc_conn.post(rpc_ep) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['Accept'] = 'application/json'
        (@headers.dup.tap do |h|
          h.delete('Accept')
          h.delete('Cache-Control')
        end).each do |k, v|
          req.headers[k] = v
        end
        req.body = { jsonrpc: '2.0', method: method, params: params }.to_json
      end
      unless response.success?
        raise MCPClient::Errors::ServerError, "Notification failed: #{response.status} #{response.reason_phrase}"
      end
    rescue StandardError => e
      raise MCPClient::Errors::TransportError, "Failed to send notification: #{e.message}"
    end

    # Ping the server to keep the connection alive
    # @return [Hash] the result of the ping request
    def ping
      rpc_request('ping')
    end

    private

    # Start the activity monitor thread
    # This thread monitors connection activity and:
    # 1. Sends a ping if there's no activity for @ping_interval seconds
    # 2. Closes the connection if there's no activity for @close_after seconds
    def start_activity_monitor
      return if @activity_timer_thread&.alive?

      @mutex.synchronize { @last_activity_time = Time.now }

      @activity_timer_thread = Thread.new do
        loop do
          sleep 1 # Check every second

          last_activity = nil
          @mutex.synchronize { last_activity = @last_activity_time }

          time_since_activity = Time.now - last_activity

          if @close_after && time_since_activity >= @close_after
            @logger.info("Closing connection due to inactivity (#{time_since_activity.round(1)}s)")
            cleanup
            break
          elsif @ping_interval && time_since_activity >= @ping_interval
            begin
              @logger.debug("Sending ping after #{time_since_activity.round(1)}s of inactivity")
              ping
              @mutex.synchronize { @last_activity_time = Time.now }
            rescue StandardError => e
              @logger.error("Error sending ping: #{e.message}")
            end
          end
        end
      rescue StandardError => e
        @logger.error("Activity monitor error: #{e.message}")
      end
    end

    # Record activity to reset the inactivity timer
    def record_activity
      @mutex.synchronize { @last_activity_time = Time.now }
    end

    # Wait for SSE connection to be established with periodic checks
    # @param timeout [Integer] Maximum time to wait in seconds
    # @raise [MCPClient::Errors::ConnectionError] if timeout expires
    def wait_for_connection(timeout:)
      @mutex.synchronize do
        deadline = Time.now + timeout

        until @connection_established
          remaining = [1, deadline - Time.now].min
          break if remaining <= 0 || @connection_cv.wait(remaining) { @connection_established }
        end

        unless @connection_established
          cleanup
          raise MCPClient::Errors::ConnectionError, 'Timed out waiting for SSE connection to be established'
        end
      end
    end

    # Ensure SSE initialization handshake has been performed
    def ensure_initialized
      return if @initialized

      connect
      perform_initialize

      @initialized = true
    end

    # Perform JSON-RPC initialize handshake with the MCP server
    def perform_initialize
      request_id = @mutex.synchronize { @request_id += 1 }
      json_rpc_request = {
        jsonrpc: '2.0',
        id: request_id,
        method: 'initialize',
        params: {
          'protocolVersion' => MCPClient::VERSION,
          'capabilities' => {},
          'clientInfo' => { 'name' => 'ruby-mcp-client', 'version' => MCPClient::VERSION }
        }
      }
      @logger.debug("Performing initialize RPC: #{json_rpc_request}")
      result = send_jsonrpc_request(json_rpc_request)
      return unless result.is_a?(Hash)

      @server_info = result['serverInfo'] if result.key?('serverInfo')
      @capabilities = result['capabilities'] if result.key?('capabilities')
    end

    # Set up the SSE connection
    # @param uri [URI] The parsed base URL
    # @return [Faraday::Connection] The configured Faraday connection
    def setup_sse_connection(uri)
      sse_base = "#{uri.scheme}://#{uri.host}:#{uri.port}"

      @sse_conn ||= Faraday.new(url: sse_base) do |f|
        f.options.open_timeout = 10
        f.options.timeout = nil
        f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
        f.adapter Faraday.default_adapter
      end

      # Use response handling with status check
      @sse_conn.builder.use Faraday::Response::RaiseError
      @sse_conn
    end

    # Handle authorization errors from Faraday
    # @param error [Faraday::Error] The authorization error
    # @raise [MCPClient::Errors::ConnectionError] with appropriate message
    def handle_sse_auth_error(error)
      error_message = "Authorization failed: HTTP #{error.response[:status]}"
      @logger.error(error_message)

      @mutex.synchronize do
        @auth_error = error_message
        @connection_established = false
        @connection_cv.broadcast
      end
      raise MCPClient::Errors::ConnectionError, error_message
    end

    # Reset connection state and signal waiting threads
    def reset_connection_state
      @mutex.synchronize do
        @connection_established = false
        @connection_cv.broadcast
      end
    end

    # Start the SSE thread to listen for events
    def start_sse_thread
      return if @sse_thread&.alive?

      @sse_thread = Thread.new do
        uri = URI.parse(@base_url)
        sse_path = uri.request_uri
        conn = setup_sse_connection(uri)

        # Reset connection state
        @mutex.synchronize do
          @sse_connected = false
          @connection_established = false
        end

        begin
          conn.get(sse_path) do |req|
            @headers.each { |k, v| req.headers[k] = v }

            req.options.on_data = proc do |chunk, _bytes|
              process_sse_chunk(chunk.dup) if chunk && !chunk.empty?
            end
          end
        rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
          handle_sse_auth_error(e)
        rescue Faraday::Error => e
          @logger.error("Failed SSE connection: #{e.message}")
          raise
        end
      rescue MCPClient::Errors::ConnectionError => e
        # Re-raise connection errors to propagate them
        # Signal connect method to stop waiting
        reset_connection_state
        raise e
      rescue StandardError => e
        @logger.error("SSE connection error: #{e.message}")
        # Signal connect method to avoid deadlock
        reset_connection_state
      ensure
        @mutex.synchronize { @sse_connected = false }
      end
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

    # Handle SSE endpoint event
    # @param data [String] The endpoint path
    def handle_endpoint_event(data)
      @mutex.synchronize do
        @rpc_endpoint = data
        @sse_connected = true
        @connection_established = true
        @connection_cv.broadcast
      end
    end

    # Check if the error represents an authorization error
    # @param error_message [String] The error message from the server
    # @param error_code [Integer, nil] The error code if available
    # @return [Boolean] True if it's an authorization error
    def authorization_error?(error_message, error_code)
      return true if error_message.include?('Unauthorized') || error_message.include?('authentication')
      return true if [401, -32_000].include?(error_code)

      false
    end

    # Handle authorization error in SSE message
    # @param error_message [String] The error message from the server
    def handle_sse_auth_error_message(error_message)
      @mutex.synchronize do
        @auth_error = "Authorization failed: #{error_message}"
        @connection_established = false
        @connection_cv.broadcast
      end

      raise MCPClient::Errors::ConnectionError, "Authorization failed: #{error_message}"
    end

    # Process error messages in SSE responses
    # @param data [Hash] The parsed SSE message data
    def process_error_in_message(data)
      return unless data['error']

      error_message = data['error']['message'] || 'Unknown server error'
      error_code = data['error']['code']

      # Handle unauthorized errors (close connection immediately)
      handle_sse_auth_error_message(error_message) if authorization_error?(error_message, error_code)

      @logger.error("Server error: #{error_message}")
      true # Error was processed
    end

    # Process JSON-RPC notifications
    # @param data [Hash] The parsed SSE message data
    # @return [Boolean] True if a notification was processed
    def process_notification(data)
      return false unless data['method'] && !data.key?('id')

      @notification_callback&.call(data['method'], data['params'])
      true
    end

    # Process JSON-RPC responses
    # @param data [Hash] The parsed SSE message data
    # @return [Boolean] True if a response was processed
    def process_response(data)
      return false unless data['id']

      @mutex.synchronize do
        # Store tools data if present
        @tools_data = data['result']['tools'] if data['result'] && data['result']['tools']

        # Store response for the waiting request
        if data['error']
          @sse_results[data['id']] = {
            'isError' => true,
            'content' => [{ 'type' => 'text', 'text' => data['error'].to_json }]
          }
        elsif data['result']
          @sse_results[data['id']] = data['result']
        end
      end

      true
    end

    # Parse and handle an SSE event
    # @param event_data [String] the event data to parse
    def parse_and_handle_sse_event(event_data)
      event = parse_sse_event(event_data)
      return if event.nil?

      case event[:event]
      when 'endpoint'
        handle_endpoint_event(event[:data])
      when 'ping'
        # Received ping event, no action needed
      when 'message'
        handle_message_event(event)
      end
    end

    # Handle a message event from SSE
    # @param event [Hash] The parsed SSE event
    def handle_message_event(event)
      return if event[:data].empty?

      begin
        data = JSON.parse(event[:data])

        # Process the message in order of precedence
        return if process_error_in_message(data)

        return if process_notification(data)

        process_response(data)
      rescue MCPClient::Errors::ConnectionError
        # Re-raise connection errors to propagate to the calling code
        raise
      rescue JSON::ParserError => e
        @logger.warn("Failed to parse JSON from event data: #{e.message}")
      rescue StandardError => e
        @logger.error("Error processing SSE event: #{e.message}")
      end
    end

    # Parse an SSE event
    # @param event_data [String] the event data to parse
    # @return [Hash, nil] the parsed event, or nil if the event is invalid
    def parse_sse_event(event_data)
      event = { event: 'message', data: '', id: nil }
      data_lines = []
      has_content = false

      event_data.each_line do |line|
        line = line.chomp
        next if line.empty?

        # Skip SSE comments (lines starting with colon)
        next if line.start_with?(':')

        has_content = true

        if line.start_with?('event:')
          event[:event] = line[6..].strip
        elsif line.start_with?('data:')
          data_lines << line[5..].strip
        elsif line.start_with?('id:')
          event[:id] = line[3..].strip
        end
      end

      event[:data] = data_lines.join("\n")

      # Return the event even if data is empty as long as we had non-comment content
      has_content ? event : nil
    end

    # Request the tools list using JSON-RPC
    # @return [Array<Hash>] the tools data
    def request_tools_list
      @mutex.synchronize do
        return @tools_data if @tools_data
      end

      request_id = @mutex.synchronize { @request_id += 1 }

      json_rpc_request = {
        jsonrpc: '2.0',
        id: request_id,
        method: 'tools/list',
        params: {}
      }

      result = send_jsonrpc_request(json_rpc_request)

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

    # Helper: execute block with retry/backoff for transient errors
    # @yield block to execute
    # @return result of block
    def with_retry
      attempts = 0
      begin
        yield
      rescue MCPClient::Errors::TransportError, MCPClient::Errors::ServerError, IOError, Errno::ETIMEDOUT,
             Errno::ECONNRESET => e
        attempts += 1
        if attempts <= @max_retries
          delay = @retry_backoff * (2**(attempts - 1))
          @logger.debug("Retry attempt #{attempts} after error: #{e.message}, sleeping #{delay}s")
          sleep(delay)
          retry
        end
        raise
      end
    end

    # Send a JSON-RPC request to the server and wait for result
    # @param request [Hash] the JSON-RPC request
    # @return [Hash] the result of the request
    def send_jsonrpc_request(request)
      @logger.debug("Sending JSON-RPC request: #{request.to_json}")

      # Record activity when sending a request
      record_activity

      uri = URI.parse(@base_url)
      base = "#{uri.scheme}://#{uri.host}:#{uri.port}"
      rpc_ep = @mutex.synchronize { @rpc_endpoint }

      @rpc_conn ||= Faraday.new(url: base) do |f|
        f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
        f.options.open_timeout = @read_timeout
        f.options.timeout = @read_timeout
        f.adapter Faraday.default_adapter
      end

      response = @rpc_conn.post(rpc_ep) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.headers['Accept'] = 'application/json'
        (@headers.dup.tap do |h|
          h.delete('Accept')
          h.delete('Cache-Control')
        end).each do |k, v|
          req.headers[k] = v
        end
        req.body = request.to_json
      end
      @logger.debug("Received JSON-RPC response: #{response.status} #{response.body}")

      # Record activity when receiving a response
      record_activity

      unless response.success?
        raise MCPClient::Errors::ServerError, "Server returned error: #{response.status} #{response.reason_phrase}"
      end

      if @use_sse
        # Wait for result via SSE channel
        request_id = request[:id]
        start_time = Time.now
        # Use the specified read_timeout for the overall operation
        timeout = @read_timeout || 10

        # Check every 100ms for the result, with a total timeout from read_timeout
        loop do
          result = nil
          @mutex.synchronize do
            result = @sse_results.delete(request_id) if @sse_results.key?(request_id)
          end

          if result
            # Record activity when receiving a result
            record_activity
            return result
          end

          current_time = Time.now
          time_elapsed = current_time - start_time

          # If we've exceeded the timeout, raise an error
          break if time_elapsed > timeout

          # Sleep for a short time before checking again
          sleep 0.1
        end

        raise MCPClient::Errors::ToolCallError, "Timeout waiting for SSE result for request #{request_id}"
      else
        begin
          data = JSON.parse(response.body)
          data['result']
        rescue JSON::ParserError => e
          raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
        end
      end
    end
  end
end
