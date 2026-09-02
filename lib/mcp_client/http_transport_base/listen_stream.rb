# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # The subscriptions/listen stream on Streamable HTTP (MCP 2026-07-28
    # basic/patterns/subscriptions): a POST whose SSE response stays open and
    # carries the notifications the client opted in to. Closing the stream is
    # the cancellation signal; an abrupt drop is re-opened with a new id
    # while the host still wants the subscription.
    module ListenStream
      # Raised inside the streaming read to abandon a stream the host closed.
      class ListenStreamClosed < StandardError; end

      # Delay before re-opening a subscriptions/listen stream that ended
      # without the server's closing response (doubles up to the maximum).
      LISTEN_RECONNECT_DELAY = 1
      LISTEN_MAX_RECONNECT_DELAY = 30
      # Read timeout for a listen stream; servers keep quiet streams alive with
      # SSE comment lines, so this only bounds a dead connection.
      LISTEN_STREAM_TIMEOUT = 300
      # Cap on a listen stream's unterminated-event buffer (peer-controlled).
      LISTEN_MAX_BUFFER_BYTES = 32 * 1024 * 1024

      # An SSE line ends with CRLF, CR or LF (a CR-only or mixed-ending
      # server is as compliant as a CRLF one).
      LINE_TERMINATOR = /\r\n|\r|\n/
      # An event ends at a blank line — two line terminators in a row, in any
      # mix. CRLF is matched first so one CRLF is never read as two.
      EVENT_TERMINATOR = /(?:\r\n|\r(?!\n)|\n){2}/

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
        return unless subscription.with_open_id(next_request_id) { register_subscription(subscription) }

        listen_threads_mutex.synchronize { listen_wakeups[subscription] ||= Thread::Queue.new }
        thread = Thread.new do
          Thread.current.name = 'MCP-listen'
          Thread.current.report_on_exception = false
          run_listen_stream(subscription)
        end
        listen_threads_mutex.synchronize { listen_threads[subscription] = thread }
      end

      # Cancel a subscription: on Streamable HTTP closing the SSE response
      # stream is the cancellation signal, so the response stream is closed
      # and the reader ends with it; no notifications/cancelled is sent. The
      # thread is not killed — a kill would interrupt it wherever it happened
      # to be, losing a notification it was in the middle of delivering.
      # @param subscription [MCPClient::Subscription]
      # @return [void]
      def cancel_subscription(subscription)
        subscription.finish(by_client: true)
        unregister_subscription(subscription)
        subscriptions_mutex.synchronize { resource_subscriptions.delete_if { |_uri, sub| sub.equal?(subscription) } }
        close_listen_stream(subscription)
        thread = listen_threads_mutex.synchronize { listen_threads.delete(subscription) }
        return unless thread && thread != Thread.current

        thread.join(THREAD_JOIN_TIMEOUT_FOR_LISTEN)
      end

      THREAD_JOIN_TIMEOUT_FOR_LISTEN = 2

      # Stop every listen stream (transport shutdown). Unlike stdio there is no
      # process to re-establish: the host re-listens on a new connection.
      # @return [void]
      def close_listen_streams
        threads = listen_threads_mutex.synchronize { listen_threads.dup.tap { listen_threads.clear } }
        # Both registries move together under their own lock; the
        # Subscriptions are finished outside it, since a subscription being
        # opened holds its own lock while taking this one.
        closing = subscriptions_mutex.synchronize do
          open = subscriptions.values
          subscriptions.clear
          resource_subscriptions.clear
          open
        end
        closing.each { |sub| sub.finish(gracefully: false, reason: 'transport closed') }
        threads.each_key { |sub| close_listen_stream(sub) }
        threads.each_value do |thread|
          next if thread == Thread.current

          thread.kill
          thread.join(THREAD_JOIN_TIMEOUT_FOR_LISTEN)
        end
      end

      private

      # Close a subscription's response stream, and wake its thread if it is
      # waiting to re-open: that ends the reader without killing it.
      # @param subscription [MCPClient::Subscription]
      # @return [void]
      def close_listen_stream(subscription)
        session, wakeup = listen_threads_mutex.synchronize do
          [listen_sessions.delete(subscription), listen_wakeups[subscription]]
        end
        wakeup&.push(:cancelled)
        return unless session

        begin
          session.finish if session.started?
        rescue StandardError => e
          @logger.debug("Closing a listen stream raised #{e.class}")
        end
      end

      # @return [Hash{MCPClient::Subscription => Thread}] running listen streams
      def listen_threads
        @listen_threads ||= {}
      end

      # The HTTP session each listen stream is reading, so a cancellation can
      # close the response stream from the host's thread.
      # @return [Hash{MCPClient::Subscription => Net::HTTP}]
      def listen_sessions
        @listen_sessions ||= {}
      end

      # Queues that interrupt a stream's re-open backoff.
      # @return [Hash{MCPClient::Subscription => Thread::Queue}]
      def listen_wakeups
        @listen_wakeups ||= {}
      end

      # @return [Mutex] guards the per-stream bookkeeping above
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
          wait_before_reopen(subscription, delay)
          delay = [delay * 2, LISTEN_MAX_RECONNECT_DELAY].min
          unregister_subscription(subscription)
          # Taking the new id, registering it and sending the request are one
          # step: a close that lands in between must not leave a stream the
          # host can no longer cancel.
          break unless subscription.with_open_id(next_request_id) { register_subscription(subscription) }
        end
        # The subscription may still be marked open after an unrecoverable drop.
        unless subscription.closed?
          unregister_subscription(subscription)
          subscription.finish(gracefully: false, reason: 'stream ended')
        end
      ensure
        listen_threads_mutex.synchronize do
          listen_threads.delete(subscription)
          listen_sessions.delete(subscription)
          listen_wakeups.delete(subscription)
        end
      end

      # Wait out the re-open backoff, interruptibly: a cancellation wakes the
      # stream so it ends at once instead of after the whole delay.
      # @param subscription [MCPClient::Subscription]
      # @param delay [Numeric] seconds to wait
      # @return [void]
      def wait_before_reopen(subscription, delay)
        wakeup = listen_threads_mutex.synchronize { listen_wakeups[subscription] }
        return sleep(delay) unless wakeup

        wakeup.pop(timeout: delay)
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
        state = { finished: nil, scanned: 0 }
        response = listen_connection(subscription).post(@endpoint) do |req|
          apply_request_headers(req, request)
          # The stream is parsed incrementally as it arrives; a compressed
          # body could not be. Ask for it uncompressed.
          req.headers['Accept-Encoding'] = 'identity'
          req.body = request.to_json
          req.options.on_data = proc do |chunk, _bytes|
            # Closing the response stream is the cancellation signal: stop
            # reading as soon as the host closed the subscription.
            raise ListenStreamClosed if subscription.closed_by_client?
            next if state[:finished]

            buffer << chunk
            state[:finished] = consume_listen_events(buffer, subscription, state)
            enforce_listen_buffer_cap!(buffer)
          end
        end
        return :closed if state[:finished]
        return listen_stream_ended(subscription, response, buffer) if response.success?

        fail_subscription_from_response(subscription, response, buffer)
        :closed
      rescue ListenStreamClosed
        :closed
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Net::ReadTimeout, IOError => e
        @logger.debug("Subscription #{subscription.id} stream dropped: #{e.class}")
        :dropped
      rescue Faraday::ClientError => e
        # raise_error middleware configured by the host: same pipeline as a
        # plain error response.
        normalized = normalize_error_response(e.response)
        if normalized
          # With on_data streaming the middleware sees an empty body; the
          # bytes went to the buffer.
          body = normalized.body.to_s
          fail_subscription_from_response(subscription, normalized, body.empty? ? buffer : body)
        else
          unregister_subscription(subscription)
          subscription.finish(gracefully: false, error: MCPClient::Errors::TransportError.new(e.message))
        end
        :closed
      rescue MCPClient::Errors::MCPError => e
        unregister_subscription(subscription)
        subscription.finish(gracefully: false, error: e)
        :closed
      rescue StandardError => e
        unregister_subscription(subscription)
        subscription.finish(gracefully: false, error: MCPClient::Errors::TransportError.new(e.message))
        :closed
      end

      # A 2xx listen response that ended without an SSE-framed closing
      # response. The server MAY answer with a single JSON object instead of
      # a stream: a JSON-RPC response for this listen id is then the closing
      # response (or the rejection). Anything else is a dropped stream.
      # @return [Symbol] :closed or :dropped
      def listen_stream_ended(subscription, response, buffer)
        headers = response.headers || {}
        content_type = (headers['content-type'] || headers['Content-Type']).to_s
        return :dropped unless content_type.include?('application/json') || buffer.lstrip.start_with?('{')

        message = parse_listen_message(buffer.strip)
        return :closed if message&.key?('id') && handle_listen_message(message, subscription) == :closed

        :dropped
      end

      # A non-2xx answer to subscriptions/listen: 401/403 are authorization
      # failures, other 4xx carry the (possibly typed) JSON-RPC error.
      # @return [void]
      def fail_subscription_from_response(subscription, response, body)
        normalized = NormalizedResponse.new(response.status, response.headers || {}, body)
        error = listen_rejection_error(normalized)
        @logger.warn("subscriptions/listen #{subscription.id} rejected: #{sanitize_log_text(error.message)}")
        unregister_subscription(subscription)
        subscription.finish(gracefully: false, error: error)
      end

      # The error for a non-2xx listen response, through the same pipeline
      # as any other request: 401/403 feed the OAuth challenge handling
      # (insufficient_scope surfaces as InsufficientScopeError), 5xx is
      # transient, other 4xx carry the (possibly typed) JSON-RPC error.
      # @param response [NormalizedResponse]
      # @return [MCPClient::Errors::MCPError]
      def listen_rejection_error(response)
        if [401, 403].include?(response.status)
          process_authorization_challenge(response)
          raise_authorization_error(response)
        elsif (500..599).cover?(response.status)
          MCPClient::Errors::TransientServerError.new("Server error: HTTP #{response.status}")
        else
          jsonrpc_error_from_http_response(response, "Client error: HTTP #{response.status}")
        end
      rescue MCPClient::Errors::MCPError => e
        e
      end

      # Consume the complete SSE events in the buffer: notifications are
      # routed (acknowledgment, tagged notifications, server-side
      # cancellation), a response to the listen request ends the subscription,
      # and comment lines are ignored (keep-alives).
      # @param buffer [String] mutable stream buffer
      # @param subscription [MCPClient::Subscription]
      # @return [Symbol, nil] :closed once the subscription ended
      def consume_listen_events(buffer, subscription, state = { scanned: 0 })
        finished = nil
        while (separator = match_event_terminator(buffer, [state[:scanned].to_i - 3, 0].max))
          event = buffer.slice!(0, separator.end(0))
          state[:scanned] = 0
          data = event.split(LINE_TERMINATOR).select { |l| l.start_with?('data:') }.map { |l| l.sub(/\Adata:\s*/, '') }
          next if data.empty?

          message = parse_listen_message(data.join("\n"))
          next unless message

          finished ||= handle_listen_message(message, subscription)
        end
        # Only what arrives next is searched next time, so an unterminated
        # event delivered in many chunks stays linear. Counted in characters,
        # like the offset String#match takes.
        state[:scanned] = buffer.length
        finished
      end

      # @param buffer [String] the stream buffer
      # @param from [Integer] character offset to search from
      # @return [MatchData, nil] the next event terminator
      def match_event_terminator(buffer, from)
        buffer.match(EVENT_TERMINATOR, from)
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
        elsif message.key?('id')
          # A listen stream is scoped to its own request: a response for any
          # other id on it is not this subscription's business.
          unless message['id'].to_s == subscription.id.to_s
            @logger.warn("Ignoring a response for request #{sanitize_log_text(message['id'].to_s)} " \
                         "on the stream of subscription #{subscription.id}")
            return nil
          end
          return :closed if handle_subscription_response(message)
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
      # @param subscription [MCPClient::Subscription] the stream it serves
      # @return [Faraday::Connection]
      def listen_connection(subscription)
        conn = Faraday.new(url: @base_url) do |f|
          f.request :retry, max: 0
          f.options.open_timeout = 10
          f.options.timeout = LISTEN_STREAM_TIMEOUT
          f.adapter :net_http do |http|
            http.read_timeout = LISTEN_STREAM_TIMEOUT
            http.open_timeout = 10
            # Keep the session so cancelling can close the response stream.
            listen_threads_mutex.synchronize { listen_sessions[subscription] = http }
          end
        end
        @faraday_config&.call(conn)
        conn
      end
    end
  end
end
