# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # The subscriptions/listen stream on Streamable HTTP (MCP 2026-07-28
    # basic/patterns/subscriptions): a POST whose SSE response stays open and
    # carries the notifications the client opted in to. Closing the stream is
    # the cancellation signal; an abrupt drop is re-opened with a new id
    # while the host still wants the subscription.
    module ListenStream
      # Delay before re-opening a subscriptions/listen stream that ended
      # without the server's closing response (doubles up to the maximum).
      LISTEN_RECONNECT_DELAY = 1
      LISTEN_MAX_RECONNECT_DELAY = 30
      # Read timeout for a listen stream; servers keep quiet streams alive with
      # SSE comment lines, so this only bounds a dead connection.
      LISTEN_STREAM_TIMEOUT = 300
      # Cap on a listen stream's unterminated-event buffer (peer-controlled).
      LISTEN_MAX_BUFFER_BYTES = 32 * 1024 * 1024

      # @return [void]
      def ensure_session_ready
        ensure_connected
      end

      # Open a subscriptions/listen stream (MCP 2026-07-28): the request is a
      # POST whose SSE response stays open and carries the notifications the
      # client opted in to. Runs on its own thread; the subscription id is
      # assigned before returning so callers can correlate immediately.
      # @param subscription [MCPClient::Subscription]
      # @return [void]
      def open_subscription(subscription)
        subscription.assign_id(next_request_id)
        register_subscription(subscription)
        thread = Thread.new do
          Thread.current.name = 'MCP-listen'
          Thread.current.report_on_exception = false
          run_listen_stream(subscription)
        end
        listen_threads_mutex.synchronize { listen_threads[subscription] = thread }
      end

      # Cancel a subscription: on Streamable HTTP closing the SSE response
      # stream is the cancellation signal, so the stream thread is stopped
      # (which closes the connection); no notifications/cancelled is sent.
      # @param subscription [MCPClient::Subscription]
      # @return [void]
      def cancel_subscription(subscription)
        subscription.finish(by_client: true)
        unregister_subscription(subscription)
        resource_subscriptions.delete_if { |_uri, sub| sub.equal?(subscription) }
        thread = listen_threads_mutex.synchronize { listen_threads.delete(subscription) }
        return unless thread && thread != Thread.current

        thread.kill
        thread.join(THREAD_JOIN_TIMEOUT_FOR_LISTEN)
      end

      THREAD_JOIN_TIMEOUT_FOR_LISTEN = 2

      # Stop every listen stream (transport shutdown). Unlike stdio there is no
      # process to re-establish: the host re-listens on a new connection.
      # @return [void]
      def close_listen_streams
        threads = listen_threads_mutex.synchronize { listen_threads.dup.tap { listen_threads.clear } }
        subscriptions_mutex.synchronize do
          subscriptions.each_value { |sub| sub.finish(gracefully: false, reason: 'transport closed') }
          subscriptions.clear
        end
        resource_subscriptions.clear
        threads.each_value do |thread|
          next if thread == Thread.current

          thread.kill
          thread.join(THREAD_JOIN_TIMEOUT_FOR_LISTEN)
        end
      end

      private

      # @return [Hash{MCPClient::Subscription => Thread}] running listen streams
      def listen_threads
        @listen_threads ||= {}
      end

      # @return [Mutex]
      def listen_threads_mutex
        @listen_threads_mutex ||= Mutex.new
      end

      # @return [Integer] a fresh JSON-RPC request id
      def next_request_id
        @mutex.synchronize { @request_id += 1 }
      end

      # Keep a subscription's stream open: POST subscriptions/listen, consume
      # the SSE response until the server closes it, and — while the host still
      # wants the subscription and the transport is connected — re-open it with
      # a new id after an abrupt drop ("a transport that closes without [the
      # closing response] indicates an unexpected disconnect, which the client
      # MAY treat as a trigger to reconnect").
      # @param subscription [MCPClient::Subscription]
      # @return [void]
      def run_listen_stream(subscription)
        delay = LISTEN_RECONNECT_DELAY
        loop do
          outcome = stream_listen_request(subscription)
          break unless outcome == :dropped && subscription.reconnectable? && listen_transport_connected?

          @logger.info("Subscription #{subscription.id} stream ended without a closing response; " \
                       "re-opening in #{delay}s")
          sleep delay
          delay = [delay * 2, LISTEN_MAX_RECONNECT_DELAY].min
          unregister_subscription(subscription)
          subscription.assign_id(next_request_id)
          register_subscription(subscription)
        end
        # The subscription may still be marked open after an unrecoverable drop.
        unless subscription.closed?
          unregister_subscription(subscription)
          subscription.finish(gracefully: false, reason: 'stream ended')
        end
      ensure
        listen_threads_mutex.synchronize { listen_threads.delete(subscription) }
      end

      # @return [Boolean] whether the transport is still connected
      def listen_transport_connected?
        @mutex.synchronize { @connection_established }
      end

      # One POST of subscriptions/listen, streaming its SSE response.
      # @param subscription [MCPClient::Subscription]
      # @return [Symbol] :closed when the subscription ended (response, error,
      #   client), :dropped when the stream ended without a closing response
      def stream_listen_request(subscription)
        request = build_jsonrpc_request('subscriptions/listen', { 'notifications' => subscription.requested },
                                        subscription.id)
        buffer = +''
        state = { finished: nil }
        response = listen_connection.post(@endpoint) do |req|
          apply_request_headers(req, request)
          req.body = request.to_json
          req.options.on_data = proc do |chunk, _bytes|
            next if state[:finished]

            buffer << chunk
            state[:finished] = consume_listen_events(buffer, subscription)
            enforce_listen_buffer_cap!(buffer)
          end
        end
        return :closed if state[:finished]
        return :dropped if response.success?

        fail_subscription_from_response(subscription, response, buffer)
        :closed
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Net::ReadTimeout, IOError => e
        @logger.debug("Subscription #{subscription.id} stream dropped: #{e.class}")
        :dropped
      rescue MCPClient::Errors::MCPError => e
        unregister_subscription(subscription)
        subscription.finish(gracefully: false, error: e)
        :closed
      rescue StandardError => e
        unregister_subscription(subscription)
        subscription.finish(gracefully: false, error: MCPClient::Errors::TransportError.new(e.message))
        :closed
      end

      # A non-2xx answer to subscriptions/listen: 401/403 are authorization
      # failures, other 4xx carry the (possibly typed) JSON-RPC error.
      # @return [void]
      def fail_subscription_from_response(subscription, response, body)
        normalized = NormalizedResponse.new(response.status, response.headers || {}, body)
        error = if [401, 403].include?(response.status)
                  MCPClient::Errors::ConnectionError.new("Authorization failed: HTTP #{response.status}")
                elsif (500..599).cover?(response.status)
                  MCPClient::Errors::TransientServerError.new("Server error: HTTP #{response.status}")
                else
                  jsonrpc_error_from_http_response(normalized, "Client error: HTTP #{response.status}")
                end
        @logger.warn("subscriptions/listen #{subscription.id} rejected: #{sanitize_log_text(error.message)}")
        unregister_subscription(subscription)
        subscription.finish(gracefully: false, error: error)
      end

      # Consume the complete SSE events in the buffer: notifications are
      # routed (acknowledgment, tagged notifications, server-side
      # cancellation), a response to the listen request ends the subscription,
      # and comment lines are ignored (keep-alives).
      # @param buffer [String] mutable stream buffer
      # @param subscription [MCPClient::Subscription]
      # @return [Symbol, nil] :closed once the subscription ended
      def consume_listen_events(buffer, subscription)
        finished = nil
        while (separator = buffer.match(/\r\n\r\n|\n\n/))
          event = buffer.slice!(0, separator.end(0))
          data = event.lines.map(&:chomp).select { |l| l.start_with?('data:') }.map { |l| l.sub(/\Adata:\s*/, '') }
          next if data.empty?

          message = parse_listen_message(data.join("\n"))
          next unless message

          finished ||= handle_listen_message(message, subscription)
        end
        finished
      end

      # @param message [Hash] a JSON-RPC message from the listen stream
      # @param subscription [MCPClient::Subscription]
      # @return [Symbol, nil] :closed once the subscription ended
      def handle_listen_message(message, subscription)
        if message['method']
          if message.key?('id')
            @logger.warn("Ignoring server-initiated request #{sanitize_log_text(message['method'])} on a listen stream")
          else
            route_notification(message['method'], message['params'])
          end
          return :closed if subscription.closed?
        elsif message.key?('id') && handle_subscription_response(message)
          return :closed
        end
        nil
      end

      # @param json [String] one SSE event's data
      # @return [Hash, nil]
      def parse_listen_message(json)
        message = JSON.parse(json)
        return message if message.is_a?(Hash)

        @logger.warn("Skipping non-object JSON-RPC message on a listen stream (#{message.class})")
        nil
      rescue JSON::ParserError => e
        @logger.warn("Skipping invalid JSON on a listen stream: #{describe_parse_error(e, json)}")
        nil
      end

      # @param buffer [String] a partial-event buffer
      # @raise [MCPClient::Errors::ConnectionError] when it exceeds LISTEN_MAX_BUFFER_BYTES
      def enforce_listen_buffer_cap!(buffer)
        return if buffer.bytesize <= LISTEN_MAX_BUFFER_BYTES

        raise MCPClient::Errors::ConnectionError,
              "Listen stream event exceeded the maximum buffered size (#{LISTEN_MAX_BUFFER_BYTES} bytes)"
      end

      # A streaming connection for listen requests (no retries: the loop above
      # decides about re-opening).
      # @return [Faraday::Connection]
      def listen_connection
        conn = Faraday.new(url: @base_url) do |f|
          f.request :retry, max: 0
          f.options.open_timeout = 10
          f.options.timeout = LISTEN_STREAM_TIMEOUT
          f.adapter :net_http do |http|
            http.read_timeout = LISTEN_STREAM_TIMEOUT
            http.open_timeout = 10
          end
        end
        @faraday_config&.call(conn)
        conn
      end
    end
  end
end
