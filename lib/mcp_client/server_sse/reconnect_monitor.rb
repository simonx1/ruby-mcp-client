# frozen_string_literal: true

module MCPClient
  class ServerSSE
    # Extracted module for back-off, ping, and reconnection logic
    module ReconnectMonitor
      # Start an activity monitor thread to maintain the connection
      # @return [void]
      def start_activity_monitor
        return if @activity_timer_thread&.alive?

        @mutex.synchronize do
          @last_activity_time = Time.now
          @consecutive_ping_failures = 0
          @max_ping_failures = DEFAULT_MAX_PING_FAILURES
          @reconnect_attempts = 0
          @max_reconnect_attempts = DEFAULT_MAX_RECONNECT_ATTEMPTS
        end

        @activity_timer_thread = Thread.new do
          activity_monitor_loop
        rescue StandardError => e
          @logger.error("Activity monitor error: #{e.message}")
        end
      end

      # Check if the connection is currently active
      # @return [Boolean] true if connection is established and SSE is connected
      def connection_active?
        @mutex.synchronize { @connection_established && @sse_connected }
      end

      # Main loop for the activity monitor thread
      # @return [void]
      # @private
      def activity_monitor_loop
        loop do
          sleep 1

          unless connection_active?
            @logger.debug('Activity monitor exiting: connection no longer active')
            return
          end

          @mutex.synchronize do
            @consecutive_ping_failures ||= 0
            @reconnect_attempts ||= 0
            @max_ping_failures ||= DEFAULT_MAX_PING_FAILURES
            @max_reconnect_attempts ||= DEFAULT_MAX_RECONNECT_ATTEMPTS
          end

          return unless connection_active?

          time_since_activity = Time.now - @last_activity_time

          if @close_after && time_since_activity >= @close_after
            @logger.info("Closing connection due to inactivity (#{time_since_activity.round(1)}s)")
            cleanup
            return
          end

          next unless @ping_interval && time_since_activity >= @ping_interval
          return unless connection_active?

          if @consecutive_ping_failures >= @max_ping_failures
            attempt_reconnection
          else
            attempt_ping
          end
        end
      end

      # Attempt to reconnect with exponential backoff
      # @return [void]
      # @private
      def attempt_reconnection
        if @reconnect_attempts < @max_reconnect_attempts
          begin
            base_delay = BASE_RECONNECT_DELAY * (2**@reconnect_attempts)
            jitter = rand * JITTER_FACTOR * base_delay
            backoff_delay = [base_delay + jitter, MAX_RECONNECT_DELAY].min

            reconnect_msg = "Attempting to reconnect (attempt #{@reconnect_attempts + 1}/#{@max_reconnect_attempts}) "
            reconnect_msg += "after #{@consecutive_ping_failures} consecutive ping failures. "
            reconnect_msg += "Waiting #{backoff_delay.round(2)}s before reconnect..."
            @logger.warn(reconnect_msg)
            sleep(backoff_delay)

            cleanup

            # Clear any stale auth/connection error from the previous connection
            # so it does not spuriously abort this reconnect via
            # wait_for_connection.
            @mutex.synchronize do
              @auth_error = nil
              @connection_error = nil
            end

            connect
            @logger.info('Successfully reconnected after ping failures')

            @mutex.synchronize do
              @consecutive_ping_failures = 0
              # Reset attempt counter after a successful reconnect
              @reconnect_attempts = 0
              @last_activity_time = Time.now
            end
          rescue StandardError => e
            @logger.error("Failed to reconnect after ping failures: #{e.message}")
            @mutex.synchronize { @reconnect_attempts += 1 }
          end
        else
          @logger.error("Exceeded maximum reconnection attempts (#{@max_reconnect_attempts}). Closing connection.")
          cleanup
        end
      end

      # Attempt to ping the server to check if connection is still alive
      # @return [void]
      # @private
      def attempt_ping
        unless connection_active?
          @logger.debug('Skipping ping - connection not active')
          return
        end

        time_since = Time.now - @last_activity_time
        @logger.debug("Sending ping after #{time_since.round(1)}s of inactivity")

        begin
          ping
          @mutex.synchronize do
            @last_activity_time = Time.now
            @consecutive_ping_failures = 0
          end
        rescue StandardError => e
          unless connection_active?
            @logger.debug("Ignoring ping failure - connection already closed: #{e.message}")
            return
          end
          handle_ping_failure(e)
        end
      end

      # Handle ping failures by incrementing a counter and logging
      # @param error [StandardError] the error that caused the ping failure
      # @return [void]
      # @private
      def handle_ping_failure(error)
        @mutex.synchronize { @consecutive_ping_failures += 1 }
        consecutive_failures = @consecutive_ping_failures

        if consecutive_failures == 1
          @logger.error("Error sending ping: #{error.message}")
        else
          error_msg = error.message.split("\n").first
          @logger.warn("Ping failed (#{consecutive_failures}/#{@max_ping_failures}): #{error_msg}")
        end
      end

      # Record activity to prevent unnecessary pings
      # @return [void]
      def record_activity
        @mutex.synchronize { @last_activity_time = Time.now }
      end

      # Wait for the connection to be established
      # @param timeout [Numeric] timeout in seconds
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if connection times out or fails
      def wait_for_connection(timeout:)
        @mutex.synchronize do
          deadline = Time.now + timeout

          until @connection_established
            break if @connection_error

            remaining = [1, deadline - Time.now].min
            break if remaining <= 0 || @connection_cv.wait(remaining) { @connection_established }
          end

          raise MCPClient::Errors::ConnectionError, @auth_error if @auth_error
          raise MCPClient::Errors::ConnectionError, @connection_error if @connection_error

          unless @connection_established
            cleanup
            error_msg = "Failed to connect to MCP server at #{@base_url}"
            error_msg += ': Timed out waiting for SSE connection to be established'
            raise MCPClient::Errors::ConnectionError, error_msg
          end
        end
      end

      # Setup the SSE connection with Faraday
      # @param uri [URI] the URI to connect to
      # @return [Faraday::Connection] the configured connection
      # @private
      def setup_sse_connection(uri)
        sse_base = "#{uri.scheme}://#{uri.host}:#{uri.port}"

        @sse_conn ||= Faraday.new(url: sse_base) do |f|
          f.options.open_timeout = 10
          f.options.timeout = nil
          f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
          f.response :follow_redirects, limit: 3
          f.adapter Faraday.default_adapter
        end

        @sse_conn.builder.use Faraday::Response::RaiseError
        @sse_conn
      end

      # Handle authentication errors from SSE
      # @param error [StandardError] the authentication error
      # @return [void]
      # @private
      def handle_sse_auth_error(error)
        error_message = "Authorization failed: HTTP #{error.response[:status]}"
        @logger.error(error_message)

        @mutex.synchronize do
          @auth_error = error_message
          @connection_established = false
          @connection_cv.broadcast
        end
      end

      # Reset the connection state
      # @return [void]
      # @private
      def reset_connection_state
        @mutex.synchronize do
          @connection_established = false
          @connection_cv.broadcast
        end
      end
    end
  end
end
