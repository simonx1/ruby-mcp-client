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
      # Time allowed for a listen stream's socket to open. A cancellation
      # cannot close a session that is still inside this window (there is no
      # response stream yet), so it is also how long a request can stay
      # abandoned-but-unsent after a {#cancel_subscription}.
      LISTEN_OPEN_TIMEOUT = 10
      # Cap on a listen stream's unterminated-event buffer (peer-controlled).
      LISTEN_MAX_BUFFER_BYTES = 32 * 1024 * 1024

      # An SSE line ends with CRLF, CR or LF (a CR-only or mixed-ending
      # server is as compliant as a CRLF one).
      LINE_TERMINATOR = /\r\n|\r|\n/
      # An event ends at a blank line — two line terminators in a row, in any
      # mix. CRLF is matched first so one CRLF is never read as two.
      EVENT_TERMINATOR = /(?:\r\n|\r(?!\n)|\n){2}/

      # Ready the connection a subscription is about to be opened on, and mark
      # this connection as one listen streams may still be opened on.
      #
      # {#open_subscription} asks that question again under the very lock
      # {#close_listen_streams} closes them under, which is what a `listen`
      # paused between the two needs: it used to register and POST regardless,
      # so a `cleanup` landing in that window closed the registries while they
      # were still empty and the stream that arrived afterwards ran on a
      # transport the host had closed — unreachable to a later `cleanup`, which
      # returns at once on a transport that is already disconnected.
      # @return [void]
      def ensure_session_ready
        ensure_connected
        listen_threads_mutex.synchronize { @listen_streams_closed = false }
      end

      # Open a subscriptions/listen stream (MCP 2026-07-28): the request is a
      # POST whose SSE response stays open and carries the notifications the
      # client opted in to. Runs on its own thread; the subscription id is
      # assigned before returning so callers can correlate immediately.
      # @param subscription [MCPClient::Subscription]
      # @return [void]
      def open_subscription(subscription)
        return unless subscription.with_open_id(next_request_id) { register_subscription(subscription) }

        # The thread is held until both registries name it, so a cancellation
        # that arrives the moment this returns always finds the stream to
        # close and the thread to wait for — and it never starts at all when
        # the connection it was readied on has since been closed.
        started = Thread::Queue.new
        thread = Thread.new do
          Thread.current.name = 'MCP-listen'
          Thread.current.report_on_exception = false
          started.pop
          run_listen_stream(subscription)
        end
        return refuse_listen_on_closed_connection(subscription, thread) unless claim_listen_stream(subscription, thread)

        started << :go
      end

      # Cancel a subscription: on Streamable HTTP closing the SSE response
      # stream is the cancellation signal, so the response stream is closed
      # and the reader ends with it; no notifications/cancelled is sent. The
      # thread is not killed — a kill would interrupt it wherever it happened
      # to be, losing a notification it was in the middle of delivering.
      # @param subscription [MCPClient::Subscription]
      # @return [void]
      def cancel_subscription(subscription)
        # Closed first: the stream's own thread reads this state before it
        # sends anything, so once this line has run no listen request for the
        # subscription can still go out.
        subscription.finish(by_client: true)
        unregister_subscription(subscription)
        subscriptions_mutex.synchronize { resource_subscriptions.delete_if { |_uri, sub| sub.equal?(subscription) } }
        close_listen_stream(subscription)
        await_listen_stream(subscription)
      end

      THREAD_JOIN_TIMEOUT_FOR_LISTEN = 2
      # How often a cancellation looks again at a session whose socket was
      # still being opened the last time it looked.
      LISTEN_CLOSE_POLL_INTERVAL = 0.05

      # Stop every listen stream (transport shutdown). Unlike stdio there is no
      # process to re-establish: the host re-listens on a new connection.
      #
      # The threads are neither killed nor waited for. A kill would interrupt
      # a reader wherever it happened to be — losing whatever it was
      # delivering, or dropping it while it holds the subscription's own lock
      # to take a new listen id, which is exactly what a later {#close} or
      # {#listen} would then wait on. Waiting is no better: this runs under
      # the transport lock a reader needs for its next id, so a join here
      # would stall every later call for its whole timeout. Once its
      # subscription is closed and its response stream is closed, a reader can
      # no longer send anything: it leaves the loop and cleans up after itself.
      # @return [void]
      def close_listen_streams
        threads = listen_threads_mutex.synchronize do
          # Under the lock a stream is claimed under: a listen that was readied
          # on this connection and has not claimed its place yet is refused
          # rather than left running on a transport that is gone
          # (see {#ensure_session_ready}).
          @listen_streams_closed = true
          listen_threads.dup.tap { listen_threads.clear }
        end
        # Both registries move together under their own lock; the
        # Subscriptions are finished outside it, since a subscription being
        # opened holds its own lock while taking this one.
        closing = subscriptions_mutex.synchronize do
          open = subscriptions.values
          subscriptions.clear
          resource_subscriptions.clear
          open
        end
        # A stream between two listen ids is registered under neither, so the
        # threads name their own subscriptions too: one left open here would
        # re-open onto a transport that is already gone.
        (closing | threads.keys).each { |sub| sub.finish(gracefully: false, reason: 'transport closed') }
        threads.each_key { |sub| close_listen_stream(sub) }
      end

      private

      # Put the stream in the per-stream bookkeeping, unless the connection it
      # was readied on has been closed since (see {#ensure_session_ready}).
      # Both happen under the one lock {#close_listen_streams} takes, so a
      # `cleanup` either finds this stream and closes it or stops it here.
      # @param subscription [MCPClient::Subscription]
      # @param thread [Thread] the stream's own thread, not yet released
      # @return [Boolean] false when the connection was closed under it
      def claim_listen_stream(subscription, thread)
        listen_threads_mutex.synchronize do
          next false if @listen_streams_closed

          listen_wakeups[subscription] ||= Thread::Queue.new
          listen_threads[subscription] = thread
          true
        end
      end

      # End a listen the connection was closed under, before anything is sent:
      # its thread is still waiting to be released, so killing it holds nothing
      # up and no request ever goes out.
      # @param subscription [MCPClient::Subscription]
      # @param thread [Thread] the stream's own thread, still waiting
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] always
      def refuse_listen_on_closed_connection(subscription, thread)
        thread.kill
        unregister_subscription(subscription)
        error = MCPClient::Errors::ConnectionError.new(
          'the connection was closed while the subscription was being opened'
        )
        subscription.finish(gracefully: false, error: error)
        raise error
      end

      # Wake a subscription's thread if it is waiting to re-open, and close the
      # response stream it is reading: that ends the reader without killing it.
      # @param subscription [MCPClient::Subscription]
      # @return [Symbol] :closed, or :opening while the socket is still being
      #   opened (see {#close_listen_session})
      def close_listen_stream(subscription)
        wakeup = listen_threads_mutex.synchronize { listen_wakeups[subscription] }
        wakeup&.push(:cancelled)
        close_listen_session(subscription)
      end

      # Close the HTTP response stream of a listen request that is in flight —
      # the cancellation signal on Streamable HTTP. A session whose socket is
      # still being opened cannot be closed and must not be forgotten: the
      # request it is about to send would leave the server holding a stream
      # nothing reads, so the caller comes back for it.
      # @param subscription [MCPClient::Subscription]
      # @return [Symbol] :closed when the response stream is closed (or none
      #   was ever opened), :opening while its socket is still being opened
      def close_listen_session(subscription)
        session = listen_threads_mutex.synchronize { listen_sessions[subscription] }
        return :closed unless session
        return :opening unless session.started?

        listen_threads_mutex.synchronize { listen_sessions.delete(subscription) }
        begin
          session.finish
        rescue StandardError => e
          @logger.debug("Closing a listen stream raised #{e.class}")
        end
        :closed
      end

      # Wait for a cancelled stream's thread to end, closing its response
      # stream as soon as there is one to close.
      #
      # A close that finds the socket still opening has nothing to close, and
      # the socket can open at any point inside {LISTEN_OPEN_TIMEOUT} — longer
      # than anything worth blocking a {Subscription#close} for. So the close
      # is attempted again after every short join instead of once, and the
      # thread is left in {#listen_threads} throughout: it removes itself when
      # it ends, and until then a stream this gave up on is still one a later
      # {#close_listen_streams} can find and close. Nothing can be sent on it
      # meanwhile — {#arm_listen_session} has already refused the request.
      # @param subscription [MCPClient::Subscription]
      # @return [void]
      def await_listen_stream(subscription)
        thread = listen_threads_mutex.synchronize { listen_threads[subscription] }
        return if thread.nil? || thread.equal?(Thread.current)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + THREAD_JOIN_TIMEOUT_FOR_LISTEN
        while close_listen_session(subscription) == :opening
          return if thread.join(LISTEN_CLOSE_POLL_INTERVAL)
          return if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        end
        thread.join(THREAD_JOIN_TIMEOUT_FOR_LISTEN)
      end

      # Hand the stream's HTTP session over before its socket is opened, so a
      # cancellation can close the response stream — and refuse to open one at
      # all for a subscription the host has already closed. Both halves happen
      # under the lock {#close_listen_stream} takes, so a close either stops
      # the request outright or finds the session it has to close.
      # @param subscription [MCPClient::Subscription]
      # @param http [Net::HTTP] the session Faraday is about to use
      # @return [void]
      # @raise [ListenStreamClosed] when the subscription is already closed
      def arm_listen_session(subscription, http)
        listen_threads_mutex.synchronize do
          raise ListenStreamClosed if subscription.closed?

          refuse_listen_send_once_closed(subscription, http)
          listen_sessions[subscription] = http
        end
      end

      # Stop the request of a subscription that was closed while this session
      # was still opening its socket.
      #
      # This is the one point a cancellation cannot otherwise reach: Net::HTTP
      # opens the socket in `start` and sends the request only afterwards, and
      # a session that has not finished starting cannot be closed — so a close
      # that lands in that window has nothing to act on, and the connect can
      # go on to POST a subscription the host has already ended, leaving the
      # server holding a stream nothing will ever read. The check sits between
      # the two, on the session itself, so it holds however long the connect
      # takes and whether or not anything is still waiting for it.
      # @param subscription [MCPClient::Subscription]
      # @param http [Net::HTTP] the session Faraday is about to use
      # @return [void]
      def refuse_listen_send_once_closed(subscription, http)
        http.define_singleton_method(:request) do |*args, &block|
          raise MCPClient::HttpTransportBase::ListenStream::ListenStreamClosed if subscription.closed?

          super(*args, &block)
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

          # No server-side subscription exists between the drop and the next
          # acknowledgment, so it stops being active for as long as that lasts.
          subscription.mark_reconnecting
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
        # A request for a subscription the host has already closed must never
        # go out: the server would hold a stream nothing reads until its own
        # timeout. {#arm_listen_session} checks again under the cancellation's
        # own lock, when the request is about to open its socket.
        return :closed if subscription.closed?

        request = build_jsonrpc_request('subscriptions/listen', { 'notifications' => subscription.requested },
                                        subscription.id)
        buffer = +''
        state = { finished: nil, scanned: 0, framing: nil }
        response = listen_connection(subscription).post(@endpoint) do |req|
          apply_request_headers(req, request)
          # The stream is parsed incrementally as it arrives; a compressed
          # body could not be. Ask for it uncompressed.
          req.headers['Accept-Encoding'] = 'identity'
          req.body = request.to_json
          req.options.on_data = proc do |chunk, _bytes, env|
            # Closing the response stream is the cancellation signal: stop
            # reading as soon as the subscription is closed, by whichever end.
            raise ListenStreamClosed if subscription.closed?
            next if state[:finished]

            buffer << chunk
            state[:framing] ||= listen_stream_framing(env, buffer)
            state[:finished] = consume_listen_events(buffer, subscription, state) unless state[:framing] == :json
            enforce_listen_buffer_cap!(buffer)
          end
        end
        return :closed if state[:finished]
        return listen_stream_ended(subscription, response, buffer, state[:framing]) if response.success?

        listen_response_rejected(subscription, response, buffer)
      rescue ListenStreamClosed
        :closed
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, Net::ReadTimeout, IOError => e
        @logger.debug("Subscription #{subscription.id} stream dropped: #{e.class}")
        :dropped
      rescue Faraday::ServerError => e
        # raise_error middleware configured by the host, on the status the
        # branch below treats as transient: same answer.
        listen_server_error_dropped(subscription, e.response_status || 'error')
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

      # A non-2xx answer to the listen POST.
      #
      # A 5xx is the server being temporarily unable to serve the stream, not
      # a refusal of the subscription — {#listen_rejection_error} already
      # calls it {MCPClient::Errors::TransientServerError}, and every other
      # request retries it. Ending the subscription on one let a single 500 or
      # 503 kill a long-lived stream for good, while a connection that failed
      # or timed out on the very same request re-opened on the usual backoff.
      # So it takes that path instead. Anything else — a 4xx carrying the
      # server's typed JSON-RPC error, an authorization challenge — is the
      # server refusing this subscription, and still ends it.
      # @param subscription [MCPClient::Subscription]
      # @param response [Faraday::Response] the non-2xx answer
      # @param buffer [String] the bytes it delivered
      # @return [Symbol] :dropped or :closed
      def listen_response_rejected(subscription, response, buffer)
        return listen_server_error_dropped(subscription, response.status) if (500..599).cover?(response.status)

        fail_subscription_from_response(subscription, response, buffer)
        :closed
      end

      # @param subscription [MCPClient::Subscription]
      # @param status [Integer, String] the server error the listen POST got
      # @return [Symbol] :dropped
      def listen_server_error_dropped(subscription, status)
        @logger.info("subscriptions/listen #{subscription.id} answered with HTTP #{status}; " \
                     'treating it as a dropped stream')
        :dropped
      end

      # A 2xx listen response that ended without an SSE-framed closing
      # response. The server MAY answer with a single JSON object instead of
      # a stream: a JSON-RPC response for this listen id is then the closing
      # response (or the rejection). Anything else is a dropped stream.
      # @param framing [Symbol, nil] the framing the stream was read with
      # @return [Symbol] :closed or :dropped
      def listen_stream_ended(subscription, response, buffer, framing = nil)
        return :dropped unless json_framed_answer?(response, buffer, framing)

        message = parse_listen_message(buffer.strip)
        return :closed if message&.key?('id') && handle_listen_message(message, subscription) == :closed

        :dropped
      end

      # How a listen answer is framed. The server MAY answer the listen
      # request with a single JSON object rather than a stream, and SSE
      # framing applied to one would consume it as an event with no data
      # lines: a graceful close would then read as a dropped stream and a
      # typed rejection as a generic one. The Content-Type decides — Faraday
      # has saved the response headers before the first chunk reaches
      # `on_data` — and a server that sent none is read the way its answer
      # opens.
      # @param env [Faraday::Env, nil] the streaming request's environment
      # @param buffer [String] what has arrived so far
      # @return [Symbol, nil] :json or :sse, nil while it cannot be told yet
      def listen_stream_framing(env, buffer)
        content_type = listen_response_content_type(env)
        return :json if content_type.include?('application/json')
        return :sse if content_type.include?('text/event-stream')

        head = buffer.lstrip
        return nil if head.empty?

        head.start_with?('{') ? :json : :sse
      end

      # @param env [Faraday::Env, nil] the streaming request's environment
      # @return [String] the answer's Content-Type, empty when it had none
      def listen_response_content_type(env)
        headers = env.respond_to?(:response_headers) ? env.response_headers : nil
        return '' unless headers.respond_to?(:[])

        (headers['content-type'] || headers['Content-Type']).to_s
      end

      # @param response [Faraday::Response] the finished listen response
      # @param buffer [String] the bytes it delivered
      # @param framing [Symbol, nil] the framing the stream was read with
      # @return [Boolean] whether the answer is a single JSON object
      def json_framed_answer?(response, buffer, framing)
        return true if framing == :json
        return false if framing == :sse

        headers = response.headers || {}
        content_type = (headers['content-type'] || headers['Content-Type']).to_s
        content_type.include?('application/json') || buffer.lstrip.start_with?('{')
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
      # transient, other 4xx carry the (possibly typed) JSON-RPC error. A 5xx
      # answer to the listen POST itself no longer arrives here — it re-opens
      # the stream instead of ending it (see {#listen_response_rejected}) —
      # but middleware that surfaces one as a rejection is still classified.
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
          f.options.open_timeout = LISTEN_OPEN_TIMEOUT
          f.options.timeout = LISTEN_STREAM_TIMEOUT
          f.adapter :net_http do |http|
            http.read_timeout = LISTEN_STREAM_TIMEOUT
            http.open_timeout = LISTEN_OPEN_TIMEOUT
            # Runs on the stream's own thread, just before the socket is
            # opened: the last point at which a cancellation can still stop
            # the request, and the first at which it can close it.
            arm_listen_session(subscription, http)
          end
        end
        @faraday_config&.call(conn)
        conn
      end
    end
  end
end
