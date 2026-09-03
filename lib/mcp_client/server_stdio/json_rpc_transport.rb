# frozen_string_literal: true

require_relative '../json_rpc_common'

module MCPClient
  class ServerStdio
    # JSON-RPC request/notification plumbing for stdio transport
    module JsonRpcTransport
      include JsonRpcCommon

      # Ensure the server process is started and initialized (handshake)
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if initialization fails
      def ensure_initialized
        return if @initialized && !transport_retired?

        @init_lock.synchronize do
          # The subprocess behind a completed handshake exited under it:
          # release its pipes and reader threads before connect overwrites
          # the handles, then negotiate again against the fresh process.
          release_retired_transport if transport_retired?
          return if @initialized

          # Whether this session is one a subscription restart is establishing
          # is decided before it exists and carried through: a restart that
          # overlaps this one must not answer the question on its behalf.
          restart = restarting_for_subscriptions?
          begin
            connect
            # The record of the process that is now the session. Everything the
            # crash-loop bound needs is written on it, by its own lifecycle: see
            # {MCPClient::ServerStdio::ChildSession}.
            session = (@session = MCPClient::ServerStdio::ChildSession.new)
            start_reader
            start_stderr_reader
            negotiate_protocol
          rescue StandardError
            # A failed negotiation must not leave the subprocess, its pipes
            # and its reader threads behind. @initialized stays false, so the
            # next request runs connect again and overwrites @stdin/@stdout/
            # @wait_thread — putting the first process permanently out of
            # cleanup's reach.
            release_transport
            raise
          end

          @initialized = true
          # The record is passed rather than read back: a cleanup on another
          # thread can retire @session while this one is still handing the
          # subscriptions to the process it established, and the crash-loop
          # bound must be stamped on the process that actually received them.
          reopen_subscriptions(session)
        end
      end

      # @return [void]
      def ensure_session_ready
        ensure_initialized
      end

      # Send the subscriptions/listen request for a subscription (a fresh id
      # each time it is opened or re-opened).
      # @param subscription [MCPClient::Subscription]
      # @return [void]
      def open_subscription(subscription)
        id = next_id
        # No caller waits on this id: the response, if any, is the server's
        # graceful closure and is routed to the subscription itself.
        @mutex.synchronize { @awaiting.delete(id) }
        request = build_jsonrpc_request('subscriptions/listen', { 'notifications' => subscription.requested }, id)
        # A {Subscription#close} racing with a re-open must not leave the
        # server holding a subscription this client can no longer cancel:
        # taking the id and registering it happen under the subscription's own
        # lock (so a close that wins stops the re-open outright), and a close
        # that cancelled this id while the request was still going out is
        # named again below, once the server has seen the listen.
        return unless subscription.with_open_id(id) { register_subscription(subscription) }

        # Recorded before the write, and whatever the write does: from here on
        # the server may be serving this listen, and {#cancel_subscription}
        # has to be able to name it even after a later request has taken the
        # subscription's own id (see {Subscription#record_outstanding_listen}).
        subscription.record_outstanding_listen(id)
        send_request(request)
        cancel_outstanding_listens(subscription) if subscription.closed_by_client?
      rescue StandardError => e
        fail_open_attempt(subscription, id, e)
      end

      # Undo the listen attempt that just failed — but only when the
      # subscription is this attempt's to undo.
      #
      # A write can block long enough for the child to exit and for the
      # restart that follows to take the subscription over. Two things can
      # have happened by then, and neither is this attempt's to tear down:
      #
      # * the restart already re-opened it under a *newer id*. The registry is
      #   keyed by listen id, so unregistering "the subscription" would delete
      #   the new registration and finishing it would close a stream the fresh
      #   process is serving. Naming the id the write went out with keeps this
      #   attempt to its own. It only says so in the log — unless that newer
      #   stream has itself already failed, in which case the caller must be
      #   told rather than handed a closed handle with no explanation.
      # * the subscription is one a session is being handed
      #   ({MCPClient::Subscription#reestablishing?}): it is a stream the spec
      #   requires to be re-sent, not one this caller asked for, so a write
      #   that failed because the process was gone (stdin closed under it, an
      #   EPIPE to a child that exited on sight, or a nested restart holding
      #   the init lock) leaves it for the next session instead of ending it.
      #   The question is asked of the subscription rather than of its state:
      #   taking the new listen id has already moved it from :reconnecting to
      #   :pending by the time the write raises, so the state says "being
      #   opened" for the very hand-over that is failing.
      # @param subscription [MCPClient::Subscription]
      # @param id [Integer, String] the listen id this attempt sent under
      # @param error [StandardError] why it failed
      # @return [void]
      # @raise [StandardError] the failure, when it was still this attempt's
      def fail_open_attempt(subscription, id, error)
        return fail_superseded_attempt(subscription, id, error) unless subscription.open_as?(id)

        unregister_subscription_id(subscription, id)
        return defer_reestablished_attempt(subscription, id, error) if subscription.reestablishing?

        subscription.finish(
          error: error.is_a?(MCPClient::Errors::MCPError) ? error : MCPClient::Errors::TransportError.new(error.message)
        )
        raise error
      end

      # Put a subscription whose hand-over could not be written back on the
      # queue the next session drains, and say so.
      #
      # It has just been taken off that queue by {#reopen_subscriptions} and
      # out of the registry above, so leaving it alone would strand it: no
      # session would re-send it and no `cleanup` would find it again. The
      # queue is where a subscription waiting for a process belongs, and the
      # process that could not be written to is on its way out — its reader
      # reaches EOF and restarts, and the crash-loop bound then decides
      # whether another one is worth spawning.
      # @param subscription [MCPClient::Subscription]
      # @param id [Integer, String] the listen id this attempt sent under
      # @param error [StandardError] why it failed
      # @return [void]
      def defer_reestablished_attempt(subscription, id, error)
        subscription.mark_reconnecting
        enqueue_reconnecting_subscriptions([subscription])
        @logger.debug("subscriptions/listen #{id} failed while the subscription was being handed to a new " \
                      "process (#{error.message}); it will be re-sent to the next one")
      end

      # A failure the subscription has already moved on from: harmless while
      # the stream that replaced it stands, and the caller's answer when it
      # does not.
      # @param subscription [MCPClient::Subscription]
      # @param id [Integer, String] the listen id this attempt sent under
      # @param error [StandardError] why it failed
      # @return [void]
      # @raise [MCPClient::Errors::MCPError] the replacement's own failure
      def fail_superseded_attempt(subscription, id, error)
        replacement_error = subscription.closed? ? subscription.error : nil
        if replacement_error
          @logger.warn("subscriptions/listen #{id} failed (#{error.message}) and the stream that replaced it " \
                       "failed too: #{sanitize_log_text(replacement_error.message)}")
          raise replacement_error
        end

        @logger.debug("subscriptions/listen #{id} failed after the subscription was re-opened " \
                      "(#{error.message}); the newer stream stands")
      end

      # After the process was re-established, re-send subscriptions/listen
      # for every subscription the host still holds open ("the server holds
      # no subscription state across reconnections").
      #
      # This is the one place a session is handed the subscriptions, so it is
      # the one place that decides whether to hand them over at all:
      #
      # * a re-established session that turns out to be legacy cannot carry
      #   them. On `protocol: :auto` the restarted process may negotiate an
      #   older revision than the one that died, and {#cleanup} has already
      #   moved the open subscriptions out of the registry — returning would
      #   leave them :reconnecting for ever with the host never told.
      # * neither can a session that would only continue a crash loop: if the
      #   last process these subscriptions were given died less than
      #   {MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL} after
      #   receiving them, handing them over again would spawn the same corpse
      #   for ever. Deciding here rather than at the restart is what makes the
      #   bound hold: a process is re-established by whichever thread gets
      #   there first — the reader's restart or a host request — and only the
      #   re-send is common to both.
      #
      # Either way the subscriptions end with the error, so the host learns
      # from `closed?`/`error` rather than waiting on a stream that is not
      # coming back.
      # @param session [MCPClient::ServerStdio::ChildSession, nil] the record of
      #   the process being handed the subscriptions
      # @return [void]
      def reopen_subscriptions(session = @session)
        pending = take_reconnecting_subscriptions
        # A session handed nothing asks nothing, and must not spend the record
        # either: the subscriptions are still open on the session this one
        # replaced (a nested restart re-establishes the process between a
        # hand-over and the next exit), and the process that carried them is
        # still what the next hand-over has to be judged against.
        return if pending.empty?

        # The record of the process that last carried subscriptions answers
        # exactly one question — whether handing them over again would only
        # respawn the same corpse — and this is the moment it is asked. Asking
        # spends it, whatever the answer: the loop it recorded is either
        # broken here (these subscriptions are closed and never handed on) or
        # replaced below by the record of the process that takes them. Left
        # standing it outlived the loop it described, and the next hand-over —
        # of a subscription opened directly on the replacement, which then ran
        # healthily for hours — was refused for a crash it had no part in.
        carrier = @subscription_carrier
        @subscription_carrier = nil

        refusal = reopen_refusal(carrier)
        return fail_subscriptions(pending, refusal) if refusal

        # Stamped on the process before the writes go out: one that exits
        # while they are still going to it survived receiving them by no time
        # at all, which is what the next hand-over needs to know.
        session&.carrying_subscriptions
        @subscription_carrier = session
        pending.each do |subscription|
          open_subscription(subscription)
        rescue StandardError => e
          @logger.warn("Could not re-establish subscription: #{e.message}")
        end
      end

      # @return [Boolean] whether the subprocess behind the handshake exited
      def transport_retired?
        @transport_retired
      end

      # Discard a transport whose subprocess exited after a successful
      # handshake, so the next negotiation starts from a clean slate rather
      # than on top of the dead process's handles.
      # @return [void]
      def release_retired_transport
        @logger.info('The MCP server subprocess exited; restarting it for this request')
        @initialized = false
        @transport_retired = false
        release_transport
      end

      # Tear down a transport that is not going to be used again — a
      # handshake that never completed, or a subprocess that exited under a
      # completed one. Failures are swallowed: the transport being unusable
      # is often the reason it is being released, and the original error is
      # the one worth raising.
      # @return [void]
      def release_transport
        cleanup
      rescue StandardError => e
        @logger.debug("Releasing the stdio transport did not complete cleanly: #{e.message}")
      end

      # Why this session must not be given the open subscriptions, if it must
      # not (see {#reopen_subscriptions}).
      # @param carrier [MCPClient::ServerStdio::ChildSession, nil] the record
      #   of the process that last carried them
      # @return [StandardError, nil]
      def reopen_refusal(carrier)
        unless modern?
          return MCPClient::Errors::CapabilityError.new(
            'the re-established server process negotiated ' \
            "#{protocol_version || 'no version'}, which cannot carry a subscriptions/listen stream"
          )
        end
        return nil unless crash_looping?(carrier)

        @logger.error('MCP server process exited again right after it was given its subscriptions; closing them')
        MCPClient::Errors::TransportError.new('MCP server process exited again right after a restart')
      end

      # Whether the process these subscriptions were last given to died too
      # soon after receiving them for another process to be worth spawning.
      # The two moments are stamped on that process's own record, by its own
      # lifecycle, so this answer cannot be spoiled by whatever another thread
      # is doing to another process.
      # @param carrier [MCPClient::ServerStdio::ChildSession, nil] the record
      #   of the process that last carried them
      # @return [Boolean]
      def crash_looping?(carrier)
        carrier&.died_carrying_subscriptions?(
          MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL
        ) || false
      end

      # Put subscriptions on the queue the next session drains, at most once
      # each.
      #
      # Two paths write to this queue and they overlap: {#cleanup} moves the
      # open subscriptions onto it, and {#defer_reestablished_attempt} puts
      # back a hand-over whose write failed — and the second happens inside
      # the window the first leaves between taking the registry snapshot and
      # writing it here. An unguarded Array `concat`ed by one and `<<`ed by
      # the other is undefined in MRI: the same window can lose the entry, and
      # a subscription no session re-sends and no `cleanup` finds again is a
      # stream the spec says MUST be re-established, stranded with the host
      # never told. Scanning that Array with `equal?` while another thread
      # grows it does not make the append safe either — it only decided,
      # unreliably, whether to make a second one. So both paths come through
      # here, under the one lock that also guards the take, and membership is
      # by identity: a handle appears on the queue once, and one hand-over
      # goes out for it.
      # @param subscriptions [Array<MCPClient::Subscription>] to enqueue
      # @return [Array<MCPClient::Subscription>] the whole queue afterwards
      def enqueue_reconnecting_subscriptions(subscriptions)
        reconnecting_mutex.synchronize { enqueue_reconnecting_locked(subscriptions) }
      end

      # Hand the subscriptions of a process that is being torn down to the
      # next one, forgetting the listen ids that process was holding: nothing
      # written to it is outstanding any more, and none of those ids may be
      # cancelled on the process that replaces it (see
      # {MCPClient::Subscription#record_outstanding_listen}).
      #
      # Both steps happen under the lock a hand-over takes them off the queue
      # under, so a session that is already re-sending them cannot have the
      # ids it has just written forgotten by this teardown: it cannot reach
      # its own writes until this has finished.
      # @param subscriptions [Array<MCPClient::Subscription>] the ones still open
      # @return [void]
      def queue_subscriptions_of_ended_process(subscriptions)
        reconnecting_mutex.synchronize do
          enqueue_reconnecting_locked(subscriptions).each(&:discard_outstanding_listens)
        end
      end

      # @param subscriptions [Array<MCPClient::Subscription>] to enqueue
      # @return [Array<MCPClient::Subscription>] the whole queue afterwards
      def enqueue_reconnecting_locked(subscriptions)
        queue = (@reconnecting_subscriptions ||= [])
        subscriptions.each do |subscription|
          queue << subscription unless queue.any? { |queued| queued.equal?(subscription) }
        end
        queue.dup
      end

      # Take the subscriptions waiting for a process, leaving the queue empty.
      # @return [Array<MCPClient::Subscription>]
      def take_reconnecting_subscriptions
        reconnecting_mutex.synchronize do
          pending = (@reconnecting_subscriptions || []).select(&:reconnectable?)
          @reconnecting_subscriptions = []
          pending
        end
      end

      # @return [Array<MCPClient::Subscription>] the subscriptions on the queue
      #   that a process could still be re-sent to
      def reconnecting_subscriptions
        reconnecting_mutex.synchronize { (@reconnecting_subscriptions || []).select(&:reconnectable?) }
      end

      # @return [Mutex] guards the queue of subscriptions waiting for a process
      #   (created by {MCPClient::ServerStdio#initialize}, so no two threads
      #   ever race to make it)
      def reconnecting_mutex
        @reconnecting_mutex ||= Mutex.new
      end

      # Restart the process the reader just watched exit, for the
      # subscriptions the host still holds.
      #
      # A subscription is a standing request the host does not repeat: while
      # it only waits for notifications there is no RPC for
      # {#ensure_initialized} to re-establish the process on, so leaving the
      # restart to "the next request" leaves every subscription
      # :reconnecting for ever, with the host neither notified nor served.
      # Restarting is also what MCP 2026-07-28 stdio "Unexpected Termination"
      # asks of a client, and re-sending the subscriptions afterwards is what
      # this transport already promises. With no subscription open there is
      # nothing standing, and the process stays lazily re-established on the
      # next request.
      #
      # A server that keeps exiting must not be respawned in a loop; that
      # bound is enforced where the subscriptions are handed over rather than
      # here (see {#reopen_subscriptions}), because the process is
      # re-established by whichever thread gets there first — this restart or
      # a host request that raced it — and only the hand-over is common to
      # both. A restart that fails outright ends them here instead. Either way
      # the host learns from `closed?`/`error` rather than waiting on a stream
      # that is never coming back.
      # @return [void]
      def restart_for_open_subscriptions
        pending = reconnecting_subscriptions
        return if pending.empty?

        @logger.info("Re-establishing the server process for #{pending.size} open subscription(s)")
        ensure_initialized
      rescue StandardError => e
        @logger.warn("Could not re-establish the server process: #{e.message}")
        fail_reconnecting_subscriptions(e)
      end

      # End the subscriptions waiting for a process that is not coming back.
      # @param error [StandardError] why it is not
      # @return [void]
      def fail_reconnecting_subscriptions(error)
        fail_subscriptions(take_reconnecting_subscriptions, error)
      end

      # @param pending [Array<MCPClient::Subscription>] the subscriptions to end
      # @param error [StandardError] why they ended
      # @return [void]
      def fail_subscriptions(pending, error)
        failure = error.is_a?(MCPClient::Errors::MCPError) ? error : MCPClient::Errors::TransportError.new(error.message)
        pending.each { |subscription| subscription.finish(gracefully: false, error: failure) }
      end

      # Establish the server's protocol era (MCP 2026-07-28
      # basic/transports/stdio "Backward Compatibility"): probe with
      # server/discover unless configured legacy-only, and fall back to the
      # initialize handshake when the probe shows a legacy server.
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if no era can be established
      def negotiate_protocol
        return perform_initialize if @protocol_mode == :legacy
        return if probe_modern_server

        perform_initialize
      end

      # Send the server/discover probe with this client's preferred modern
      # version. Three outcomes, per the stdio backward-compatibility rules:
      # a DiscoverResult (modern: select a version from supportedVersions), a
      # recognized modern error such as UnsupportedProtocolVersionError
      # (modern: retry with an advertised version, never fall back), or any
      # other error / a timeout (legacy: fall back to initialize). The
      # fallback is deliberately not keyed to one error code — legacy servers
      # answer pre-initialize requests with implementation-defined errors.
      # @return [Boolean] true when the server is modern and a version was selected
      # @raise [MCPClient::Errors::ConnectionError] if the server is modern but no
      #   version is mutually supported, or legacy while protocol: :modern is configured
      def probe_modern_server
        # The probe DECLARES this version; it does not establish it. Until the
        # answer arrives the era stays unknown, so an incoming server request
        # is still handled — a legacy server MAY ping during initialization and
        # the receiver MUST respond promptly, and a server waiting for that
        # response answers nothing until it arrives.
        @protocol_version = MCPClient::LATEST_PROTOCOL_VERSION
        begin_era_probe
        modern_confirmed = false
        begin
          perform_discover
        rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
          raise unless e.modern_protocol_error?

          # A well-formed rejection settles the era: whatever the retried
          # probe does next, this server is modern and never gets initialize.
          modern_confirmed = true
          settle_era_probe
          retry_discover_with_advertised_version(e)
        end
        true
      rescue MCPClient::Errors::ConnectionError
        # A DiscoverResult (or advertised list) with no mutual version: the
        # server is modern but incompatible. Nothing was negotiated.
        @protocol_version = nil
        raise
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError => e
        # A recognized modern error (-32020/-32021, or -32022 with no usable
        # version) identifies a modern server: surface it, never fall back.
        # Anything else — including a 2xx-style result that is not a
        # DiscoverResult — is a legacy server, unless the era was already
        # settled by a well-formed rejection.
        if modern_confirmed || e.modern_protocol_error_for_probe?
          @protocol_version = nil
          raise MCPClient::Errors::ConnectionError, "Server is modern but incompatible: #{e.message}"
        end

        legacy_after_probe(e)
        false
      ensure
        # However the probe ended, it is no longer proposing anything.
        settle_era_probe
      end

      # Not a recognized modern error: a legacy server (or one that never
      # answered).
      # @param error [StandardError] the probe failure
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] when protocol: :modern is configured
      def legacy_after_probe(error)
        e = error
        @protocol_version = nil
        if @protocol_mode == :modern
          raise MCPClient::Errors::ConnectionError,
                "Server did not answer server/discover as a modern MCP server (#{e.message}); it is most likely " \
                'a legacy server expecting the initialize handshake. Use protocol: :auto or :legacy to allow that.'
        end

        @logger.debug("server/discover probe failed (#{e.class}); treating the server as legacy")
      end

      # After UnsupportedProtocolVersionError, pick a mutually supported
      # version from the error's advertised list and re-issue the probe.
      # @param error [MCPClient::Errors::UnsupportedProtocolVersionError]
      # @return [void]
      def retry_discover_with_advertised_version(error)
        version = select_protocol_version(error.supported)
        unless version
          raise MCPClient::Errors::ConnectionError,
                "Server rejected protocol version #{@protocol_version} and supports only " \
                "#{error.supported.join(', ')}, none of which this client speaks " \
                "(modern versions supported: #{MCPClient::MODERN_PROTOCOL_VERSIONS.join(', ')})"
        end

        @logger.info("Server does not support #{@protocol_version}; retrying server/discover with #{version}")
        @protocol_version = version
        perform_discover
      end

      # Send server/discover and apply the DiscoverResult. Bounded by
      # discover_timeout rather than the general read timeout so a silent
      # legacy server delays the fallback only briefly.
      # @return [Hash] the DiscoverResult
      def perform_discover
        req_id = next_id
        req = build_registered_request('server/discover', {}, req_id)
        send_request(req)
        begin
          res = wait_response(req_id, timeout: @discover_timeout)
        rescue MCPClient::Errors::RequestTimeoutError
          send_cancellation_notification(req_id)
          raise
        end
        result = process_jsonrpc_response(res)
        # Not a DiscoverResult at all (a permissive legacy server answering
        # an unknown method with some result): a legacy answer, not a
        # malformed modern one.
        unless discover_result?(result)
          raise MCPClient::Errors::ServerError, 'server/discover was answered without a DiscoverResult'
        end

        apply_discover_result(result)
      rescue MCPClient::Errors::InvalidResultError => e
        raise MCPClient::Errors::ServerError, "server/discover was answered without a DiscoverResult (#{e.message})"
      end

      # Handshake: send initialize request and initialized notification
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] if initialization fails
      def perform_initialize
        # Initialize request
        init_id = next_id
        init_req = build_registered_request('initialize', initialization_params, init_id)
        send_request(init_req)
        res = wait_response(init_id)
        begin
          result = process_jsonrpc_response(res) || {}
        rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
          # A modern-only server SHOULD name the versions it supports when
          # rejecting initialize (basic/versioning): surface them, since a
          # legacy-only configuration has no fall-forward path.
          raise MCPClient::Errors::ConnectionError,
                "Initialize failed: #{e.message} (server supports: #{e.supported.join(', ')})"
        rescue MCPClient::Errors::ServerError => e
          raise MCPClient::Errors::ConnectionError, "Initialize failed: #{e.message}"
        end

        # Store negotiated protocol version, server info and capabilities.
        # Disconnects if the server negotiated a version we cannot speak.
        @protocol_version = validate_protocol_version!(result)
        @server_info = result['serverInfo']
        @capabilities = result['capabilities']
        @instructions = result['instructions']

        # Send initialized notification
        notif = build_jsonrpc_notification('notifications/initialized', {})
        @stdin.puts(notif.to_json)
      end

      # Generate a new unique request ID and mark it as awaiting a response.
      # Registering the id before the request is sent lets the reader thread
      # distinguish expected responses from late/unsolicited ones.
      # @return [Integer] a unique request ID
      def next_id
        @mutex.synchronize do
          id = @next_id
          @next_id += 1
          @awaiting[id] = true
          id
        end
      end

      # Build a JSON-RPC request under an id {#next_id} has already registered
      # as outstanding. Building can fail — the host's request_meta provider
      # is evaluated here and may raise — and a request that was never built
      # is never sent and never answered, so its marker has to go with it;
      # otherwise every such failure leaks an entry into @awaiting.
      # @param method [String] JSON-RPC method
      # @param params [Hash, nil] parameters for the request
      # @param req_id [Integer] the registered request id
      # @return [Hash] the JSON-RPC request
      def build_registered_request(method, params, req_id)
        build_jsonrpc_request(method, params, req_id)
      rescue StandardError
        @mutex.synchronize { @awaiting.delete(req_id) }
        raise
      end

      # Send a JSON-RPC request and return nothing
      # @param req [Hash] the JSON-RPC request
      # @return [void]
      # @raise [MCPClient::Errors::TransportError] on write errors
      def send_request(req)
        @logger.debug("Sending JSONRPC request: #{describe_jsonrpc_message(req)}")
        @stdin.puts(req.to_json)
      rescue StandardError => e
        # A request that failed to send will never receive a response, so drop
        # its awaiting marker; otherwise a broken transport (e.g. the server
        # exited) would leak an entry per retry/attempt into @awaiting.
        @mutex.synchronize { @awaiting.delete(req['id']) } if req.is_a?(Hash) && req['id']
        raise MCPClient::Errors::TransportError, "Failed to send JSONRPC request: #{e.message}"
      end

      # Wait for a response with the given request ID
      # @param id [Integer] the request ID
      # @return [Hash] the JSON-RPC response message
      # @raise [MCPClient::Errors::TransportError] on timeout
      def wait_response(id, timeout: nil)
        deadline = Time.now + (timeout || @read_timeout)
        @mutex.synchronize do
          until @pending.key?(id)
            remaining = deadline - Time.now
            break if remaining <= 0

            @cond.wait(@mutex, remaining)
          end
          # Remove the response and the awaiting marker on both success and
          # timeout so neither @pending nor @awaiting accumulates entries.
          msg = @pending.delete(id)
          @awaiting.delete(id)
          raise MCPClient::Errors::RequestTimeoutError, "Timeout waiting for JSONRPC response id=#{id}" unless msg

          msg
        end
      end

      # Stream tool call fallback for stdio transport (yields single result)
      # @param tool_name [String] the name of the tool to call
      # @param parameters [Hash] the parameters to pass to the tool
      # @return [Enumerator] a stream containing a single result
      def call_tool_streaming(tool_name, parameters)
        Enumerator.new do |yielder|
          yielder << call_tool(tool_name, parameters)
        end
      end

      # Generic JSON-RPC request: send method with params and wait for result
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the request
      # @return [Object] result from JSON-RPC response
      # @raise [MCPClient::Errors::ServerError] if server returns an error
      # @raise [MCPClient::Errors::TransportError] on transport errors
      # @raise [MCPClient::Errors::ToolCallError] on tool call errors
      def rpc_request(method, params = {}, timeout: nil)
        freshly_probed = !@initialized || transport_retired?
        ensure_initialized
        if method == 'ping' && modern?
          # `ping` was removed in MCP 2026-07-28; the mandatory server/discover
          # request is the modern heartbeat. The probe that just established
          # the connection IS such a round trip, so answer from it rather than
          # paying for a second one.
          return @last_discover_result if freshly_probed && @last_discover_result

          method = 'server/discover'
        end

        # The multi round-trip resolver sits outside the per-attempt
        # recovery, so a retry that carries inputResponses/requestState keeps
        # them through transport retries, version renegotiation and the like.
        result = resolve_input_round_trips(method, params, timeout) do |attempt_params|
          with_retry(method) do
            sent_version = nil
            begin
              send_request_and_wait(method, attempt_params, timeout) { |version| sent_version = version }
            rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
              # MCP 2026-07-28 basic/versioning: "The client SHOULD select a
              # mutually supported version from the supported list and retry
              # the request". The server rejected the request before
              # processing it, so re-sending cannot duplicate a side effect.
              # Compared against the version THIS request declared, read back
              # from the request itself: a concurrent request may have moved
              # the transport on while this one was being built.
              version = select_protocol_version(e.supported)
              raise unless modern? && version && version != sent_version

              @logger.info("Server does not support protocol version #{sent_version}; " \
                           "retrying #{method} with #{version}")
              @protocol_version = version
              send_request_and_wait(method, attempt_params, timeout)
            end
          end
        end
        # Every server/discover answer is validated and applied: a later
        # heartbeat may advertise new versions or capabilities.
        result = apply_discover_result(result) if method == 'server/discover'
        result
      end

      # @param result [Object] a JSON-RPC result
      # @return [Boolean] whether it has the DiscoverResult shape
      def discover_result?(result)
        result.is_a?(Hash) && result['supportedVersions'].is_a?(Array)
      end

      # One request/response exchange with its own JSON-RPC id.
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the request
      # @param timeout [Numeric, nil] per-request timeout override
      # @yieldparam version [String, nil] the protocol version the request declares
      # @return [Object] result from the JSON-RPC response
      def send_request_and_wait(method, params, timeout)
        req_id = next_id
        req = build_registered_request(method, params, req_id)
        yield declared_protocol_version(req) if block_given?
        send_request(req)
        begin
          res = wait_response(req_id, timeout: timeout)
        rescue MCPClient::Errors::RequestTimeoutError
          # MCP lifecycle: on timeout the sender SHOULD issue a cancellation
          # notification for the abandoned request and stop waiting.
          send_cancellation_notification(req_id) if cancellable_request?(method, params)
          raise
        end
        process_jsonrpc_response(res)
      end

      # The protocol version a built request declares in its `_meta`. Read
      # back from the request rather than from the transport: building it
      # evaluates the host's metadata provider, during which a concurrent
      # request may settle the transport on a different version.
      # @param req [Hash] a JSON-RPC request
      # @return [String, nil] the declared version, nil for a legacy request
      def declared_protocol_version(req)
        params = req['params']
        meta = params.is_a?(Hash) ? params['_meta'] : nil
        meta.is_a?(Hash) ? meta[JsonRpcCommon::META_PROTOCOL_VERSION] : nil
      end

      # Best-effort notifications/cancelled for a request the client stopped
      # waiting on. Failures are swallowed: the transport may be the reason
      # the request timed out in the first place.
      # @param request_id [Integer] id of the abandoned request
      # @return [void]
      def send_cancellation_notification(request_id)
        notif = build_jsonrpc_notification('notifications/cancelled',
                                           { 'requestId' => request_id, 'reason' => 'Request timed out' })
        @stdin.puts(notif.to_json)
      rescue StandardError => e
        @logger.debug("Failed to send cancellation notification: #{e.message}")
      end

      # Send a JSON-RPC notification (no response expected)
      # @param method [String] JSON-RPC method
      # @param params [Hash] parameters for the notification
      # @return [void]
      def rpc_notify(method, params = {})
        ensure_initialized
        if suppressed_modern_notification?(method)
          @logger.debug("Not sending #{method}: removed in MCP #{protocol_version}")
          return
        end

        notif = build_jsonrpc_notification(method, params)
        @stdin.puts(notif.to_json)
      end
    end
  end
end
