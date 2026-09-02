# frozen_string_literal: true

require_relative '../task'
require_relative '../errors'
require_relative '../json_rpc_common'
require_relative 'task_registry'
require_relative 'task_shape'
require_relative 'task_updates'

module MCPClient
  class Client
    # MCP 2026-07-28 tasks extension (io.modelcontextprotocol/tasks) support
    # for {MCPClient::Client}: declared through `extensions:`, a server may
    # answer tools/call with a task that the client then polls (tasks/get),
    # feeds (tasks/update) and cancels (tasks/cancel).
    module TaskSupport
      # The per-task bookkeeping (answered keys, in-flight keys, the session
      # epochs everything is keyed by) lives in its own module.
      include TaskRegistry
      include TaskShape
      # The tasks/update delivery path (answered keys, pending payloads, the
      # session guard) lives in its own module; the wait loop below drives it.
      include TaskUpdates

      # Seconds to wait before the next tasks/get when the server gave no
      # pollIntervalMs ("Clients SHOULD respect the pollIntervalMs provided
      # in responses"), and the floor that keeps a pollIntervalMs of 0 from
      # turning the wait into a busy loop.
      DEFAULT_TASK_POLL_INTERVAL = 1.0
      MIN_TASK_POLL_INTERVAL = 0.05
      # Longest pause between two polls, whatever pollIntervalMs says: a
      # peer-supplied interval the clock cannot represent (or that is merely
      # enormous) is bounded rather than handed to sleep.
      MAX_TASK_POLL_INTERVAL = 3600.0
      MIN_TASK_REQUEST_TIMEOUT = 0.001
      # The longest a single poll request may wait, whatever the TTL: a hung
      # tasks/get must not block the wait for the task's whole lifetime.
      MAX_TASK_REQUEST_TIMEOUT = 30.0

      # How many input_required rounds one wait answers before giving up:
      # a task is not a higher-trust channel than a multi round-trip request.
      MAX_TASK_INPUT_ROUNDS = 10

      # Answer the outstanding input requests of a task (tasks/update, MCP
      # 2026-07-28 tasks extension). The acknowledgement is eventually
      # consistent: keep observing the task (#get_task / #wait_for_task) until
      # it is terminal. {#wait_for_task} does this automatically through the
      # registered elicitation / sampling / roots handlers.
      # @param task [String, MCPClient::Task] the task or its id
      # @param input_responses [Hash{String => Hash}] responses keyed like the task's inputRequests
      # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
      # @return [true]
      # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
      # @raise [MCPClient::Errors::TaskError] if the update fails, the server predates tasks/update, or the
      #   task handle belongs to a server session that has ended (its task id is another task's now)
      def update_task(task, input_responses, server: nil)
        srv = select_task_server(task, server, 'update_task')
        task_id = task_identifier(task)
        ensure_task_capability!(srv, 'update', strict: true)
        unless modern_server?(srv)
          raise MCPClient::Errors::TaskError, 'tasks/update requires an MCP 2026-07-28 server (tasks extension)'
        end
        unless input_responses.is_a?(Hash)
          raise ArgumentError, 'input_responses must be a Hash keyed by input request key'
        end

        # The answers are for the task the handle names, in the session it
        # was seen in: they never reach the session that replaced it, where
        # the reused id and keys would answer an unrelated request. A bare id
        # answers the task of the session live at this call.
        epoch = handle_session_epoch(task, srv, 'updating') || invocation_session_epoch(srv)
        # A caller that asked for this delivery is told when it did not
        # happen: a wait would poll again, but nothing else would notice.
        send_task_update(srv, task_id, input_responses, epoch: epoch, strict_session: true)
      end

      # Wait for a task to reach a terminal status (MCP 2026-07-28 tasks
      # extension): poll tasks/get at the server's pollIntervalMs, answer
      # input_required states through tasks/update using the registered
      # handlers (each inputRequests key is answered once), and give up when
      # the task's TTL backstop or the caller's timeout elapses.
      # @param task [String, MCPClient::Task] the task or its id
      # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
      # @param timeout [Numeric, nil] seconds to wait before giving up (nil = until the TTL, if any)
      # @return [MCPClient::Task] the terminal task (completed, failed or cancelled), with its result or error
      # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
      # @raise [MCPClient::Errors::InputRequiredError] if an input request cannot be fulfilled
      # @raise [MCPClient::Errors::TaskError] on timeout, TTL expiry, a failed request, or a server session
      #   that ended before the task was terminal (the task went with it; its id may be another task's now)
      def wait_for_task(task, server: nil, timeout: nil)
        return task if task.is_a?(MCPClient::Task) && !task.remote?

        srv = select_task_server(task, server, 'wait_for_task')
        task_id = task_identifier(task)
        # The caller's deadline and the task's TTL backstop are kept apart:
        # the TTL may change with every observation (the server MAY extend
        # it) while the caller's timeout never moves. The deadline exists
        # before anything is sent, so a capability probe (initialization,
        # discovery) counts against it too.
        wait = { task_id: task_id, srv: srv, deadline: timeout && (monotonic_time + timeout), ttl_deadline: nil,
                 answered: nil, state: nil, epoch: nil, last: nil }
        probe_task_capability!(wait)
        unless modern_server?(srv)
          raise MCPClient::Errors::TaskError, 'wait_for_task requires an MCP 2026-07-28 server (tasks extension)'
        end

        final = final_task_handle(task, srv, wait)
        return final if final

        # A handle whose session has ended names a task that is gone: it is
        # never polled in the session that replaced it, where the id may
        # belong to something else (the same rule #update_task and
        # #cancel_task apply to a handle).
        handle_session_epoch(task, srv, 'waiting for')
        refresh_wait_session(wait)
        # The CreateTaskResult seed is not an observation: the first
        # tasks/get goes out at once, whatever the seed claims. Its TTL
        # still bounds a wait whose polls never come back, and its
        # pollIntervalMs paces them — but only when the handle came from
        # the server being polled: task ids and state are per server, so a
        # handle from another server says nothing about this one's task —
        # and neither does a handle from a session of this server that has
        # ended, whose task id the new session may have reused.
        seed_wait_from_handle(task, srv, wait)
        loop do
          # The server may have restarted since the last poll (during the
          # sleep between two of them, say): the task belonged to the session
          # that ended, so the wait ends here rather than polling an id the
          # new session may have reused for something else.
          end_of_session!(wait) if refresh_wait_session(wait)
          current = observe_task(wait)
          # A poll that came back with nothing is no observation: try again at
          # the pace the server last asked for, unless the wait is over. It
          # may have come back with nothing because the session ended under
          # it (a poll that timed out, or one the transport held back from
          # the session that replaced its own): the task then ended with its
          # session, and the wait ends here rather than asking the new
          # session about an id it may have reused — or waiting out the pace
          # of a task that no longer exists.
          unless current
            end_of_session!(wait) if refresh_wait_session(wait)
            raise_if_past_deadline!(wait)
            next sleep(wait[:last] ? task_poll_delay(wait[:last], wait_deadline(wait)) : default_poll_delay(wait))
          end

          # The session the poll belongs to may have ended while it was in
          # flight or just after it came back. The task went with it: its id
          # in the replacement session names whatever that session made of
          # it, so the wait never polls it there. What the ended session
          # already answered still stands — see #outcome_of_ended_session.
          polled_state = wait[:state]
          polled_epoch = wait[:epoch]
          return outcome_of_ended_session(current, wait, polled_state, polled_epoch) if refresh_wait_session(wait)

          if current.terminal?
            # A terminal task that came back after the caller's deadline
            # (transport retries) does not rescue a timed-out wait; the TTL
            # backstop is moot once the task is terminal.
            raise_if_past_caller_deadline!(wait)
            forget_task_keys(srv, task_id, state: wait[:state])
            return current
          end
          wait[:last] = current
          # The TTL backstop comes before any handler runs for the task, and
          # from now on bounds every poll, even ones that time out. A poll
          # that came back late (transport retries) ends the wait here.
          bound_wait_by_ttl(current, wait)
          raise_if_past_deadline!(wait)
          retransmit_pending_update(wait)
          # No new handler round once the wait is over, whatever the
          # retransmission took.
          raise_if_past_deadline!(wait)
          # The retransmission is a full tasks/update round trip, and the
          # session may have ended under it: the observation in hand says
          # nothing about the live session, its input requests must never be
          # put to the host, and the task itself did not survive.
          end_of_session!(wait) if refresh_wait_session(wait)
          answer_task_round(current, wait)

          sleep(task_poll_delay(current, wait_deadline(wait)))
        end
      end

      # Whether this client declared the MCP 2026-07-28 tasks extension
      # (`extensions: ['io.modelcontextprotocol/tasks']`).
      # @return [Boolean]
      def tasks_extension?
        @extensions.key?(MCPClient::JsonRpcCommon::TASKS_EXTENSION)
      end

      private

      # What a wait whose session has just ended returns — or raises.
      #
      # A task lives in one server session: the session that replaced it may
      # name an entirely different task with the same id, so the wait never
      # polls it there. What the ended session already answered is another
      # matter: a terminal payload that came back from a poll the transport
      # pinned to that session is this very task's result or error (the pin
      # holds a request back until the wire, so an answer in hand is the
      # answer of the session the wait was in), and it is the outcome. Short
      # of that — no observation, a non-terminal one, or a transport that
      # cannot pin a request to its session and so cannot vouch for which
      # session answered — the wait ends: the task did not survive.
      # @param current [MCPClient::Task, nil] the observation in hand
      # @param wait [Hash]
      # @param polled_state [Hash] the bookkeeping the poll belonged to
      # @param polled_epoch [Integer, nil] the session the poll was sent in
      # @return [MCPClient::Task] the terminal task
      # @raise [MCPClient::Errors::TaskError]
      def outcome_of_ended_session(current, wait, polled_state, polled_epoch)
        # An answer counts as this wait's outcome only when it is stamped
        # with the very session the poll was pinned to: a handle carrying
        # another session's epoch describes another lifetime of the id.
        terminal = current&.terminal? && observation_of_session?(current, polled_epoch)
        # Only the bookkeeping of the session the poll asked is forgotten;
        # the replacement session's is untouched.
        forget_task_keys(wait[:srv], wait[:task_id], state: polled_state) if terminal
        end_of_session!(wait) unless terminal && session_pinning?(wait[:srv])

        # A terminal task that came back after the caller's deadline
        # (transport retries) does not rescue a timed-out wait.
        raise_if_past_caller_deadline!(wait)
        current
      end

      # End a wait whose server session is over: the task belonged to that
      # session and is gone with it.
      # @return [void]
      # @raise [MCPClient::Errors::TaskError]
      def end_of_session!(wait)
        raise MCPClient::Errors::TaskError,
              "Error waiting for task '#{shown_task_id(wait[:task_id])}': the server session it belongs to ended " \
              'before the task did, so the task is gone (a restarted server may reuse its id for an unrelated task)'
      end

      # Whether an observation is about the session it was polled in: the
      # handle carries the session its request was pinned to. A handle
      # without one (a server that reports no session), or a poll that
      # belonged to no session, is taken at its word, as before.
      # @return [Boolean]
      def observation_of_session?(task, epoch)
        task.session_epoch.nil? || epoch.nil? || task.session_epoch == epoch
      end

      # Whether the transport holds a request back from the session that
      # replaced the one it belongs to (see {MCPClient::SessionPin}), which
      # is what makes an answer in hand provably the answer of the session
      # the wait was in.
      # @return [Boolean]
      def session_pinning?(srv)
        srv.respond_to?(:pinned_to_session)
      end

      # The task state to act on for this iteration: the seed when it is
      # still usable, else a fresh tasks/get; a seed that claims a terminal
      # or input_required status without its payload is confirmed by
      # tasks/get, and a terminal DetailedTask must carry its payload.
      # @param current [MCPClient::Task, nil]
      # @param wait [Hash] task_id, srv, deadline
      # @return [MCPClient::Task]
      # @raise [MCPClient::Errors::TaskError] once the deadline has passed
      def observe_task(wait)
        raise_if_past_deadline!(wait)
        current = poll_task(wait)
        return nil unless current

        validate_terminal_task!(current) if current.terminal?
        current
      end

      # Answer this poll's outstanding input requests, bounding how many
      # rounds a task may demand (the limit is per task, not per wait, and
      # is applied with the key reservation, see #answer_task_input_requests).
      # @return [void]
      def answer_task_round(current, wait)
        return unless pending_task_input?(current, wait[:answered])

        answer_task_input_requests(current, wait[:answered], wait[:srv], wait)
      end

      # Deliver again an update whose acknowledgement was lost, before any
      # new input is answered (the server ignores keys it already has). Only
      # what is still pending once the task's update lock is held is sent: a
      # snapshot taken before the lock could resend an answer a concurrent,
      # confirmed update has just superseded.
      # @return [void]
      def retransmit_pending_update(wait)
        deliver_task_update(wait[:srv], wait[:task_id], nil, wait, pending_only: true)
      end

      # Whether the task lists an input request that has not been answered.
      # @return [Boolean]
      def pending_task_input?(task, answered)
        return false unless task.input_required?

        requests = task.input_requests
        return false if requests.nil? && !task.detailed?
        unless requests.is_a?(Hash)
          raise MCPClient::Errors::InputRequiredError.new(
            'Malformed input_required task: inputRequests is not an object', data: task.to_h
          )
        end

        requests.keys.any? { |key| !answered.include?(key) }
      end

      # The inputRequests keys already answered for a task, kept across
      # waits ("Clients SHOULD deduplicate inputRequests keys across
      # consecutive polls") until the task is terminal or cancelled.
      # @return [Set<String>]
      def answered_task_keys(srv, task_id)
        task_state(srv, task_id)[:answered]
      end

      # Point a wait at the task state of the server's current session, and
      # report whether that is a session it has not been in before. What the
      # previous session said about the task goes with it: its TTL backstop
      # (createdAt + ttlMs of a task that no longer exists) must not end the
      # wait in place of the session being over, and its last observation
      # must not pace anything. A wait that reserves keys after a restart
      # reserves them in the new session's answered set, since the restarted
      # server may reuse the task id and its keys for what is a new request.
      # @param wait [Hash]
      # @return [Boolean] whether the wait moved to another session, so that
      #   nothing the previous one said (an observation in hand, its TTL, its
      #   pace) may be acted on
      def refresh_wait_session(wait)
        # The epoch and the state keyed under it are read in one step, so
        # a restart between the two cannot leave the wait pointing at one
        # session's set while recording another's epoch.
        answered_keys_mutex.synchronize do
          epoch = current_session_epoch(wait[:srv])
          next false if wait[:epoch] == epoch && wait[:answered]

          moved = !wait[:epoch].nil? && wait[:epoch] != epoch
          if moved
            wait[:ttl_deadline] = nil
            wait[:last] = nil
          end
          wait[:epoch] = epoch
          state = task_state_locked(wait[:srv], wait[:task_id], epoch)
          wait[:state] = state
          wait[:answered] = state[:answered]
          moved
        end
      end

      # A handle that is already final: a DetailedTask of this server whose
      # terminal payload is authoritative (and which the server may purge any
      # moment), so there is nothing to poll. Its own session's bookkeeping
      # dies with the task; a handle kept across a restart says nothing about
      # the session that replaced it, where the reused task id may name a
      # live task whose answered keys another wait is deduplicating against.
      # @return [MCPClient::Task, nil] the task when the wait is already over
      def final_task_handle(task, srv, wait)
        return nil unless task.is_a?(MCPClient::Task) && task.detailed? && task.terminal? && task.server.equal?(srv)

        validate_terminal_task!(task)
        refresh_wait_session(wait)
        forget_task_keys(srv, wait[:task_id], state: wait[:state]) if seed_of_session?(task, wait)
        task
      end

      # Take the seed's hints (its TTL backstop and its pace) from a handle
      # that describes the task this wait is about: the same server, and the
      # session the wait has joined.
      # @return [void]
      def seed_wait_from_handle(task, srv, wait)
        return unless task.is_a?(MCPClient::Task) && task.server.equal?(srv) && seed_of_session?(task, wait)

        seed_ttl_deadline(task, wait)
        wait[:last] = task
      end

      # Whether a task handle may seed the wait: it must come from the
      # session the wait has joined (a handle a host kept across a restart
      # describes a task the new session knows nothing about, even when the
      # id was reused). A server that reports no session (a bare double) is
      # taken at its word, as before.
      # @return [Boolean]
      def seed_of_session?(task, wait)
        task.session_epoch.nil? || task.session_epoch == wait[:epoch]
      end

      # The pace before the server ever said one (a bare task id, a handle
      # from another server): the default interval, never the busy-loop
      # floor, clamped to what is left of the wait.
      # @return [Float] seconds
      def default_poll_delay(wait)
        deadline = wait_deadline(wait)
        remaining = deadline && [deadline - monotonic_time, 0.0].max
        remaining ? DEFAULT_TASK_POLL_INTERVAL.clamp(0.0, remaining) : DEFAULT_TASK_POLL_INTERVAL
      end

      # The wait's effective deadline: the earlier of the caller's timeout
      # and the latest TTL backstop.
      # @return [Float, nil]
      def wait_deadline(wait)
        [wait[:deadline], wait[:ttl_deadline]].compact.min
      end

      # Send a task request through a transport that may implement only the
      # documented rpc_request(method, params) interface: the timeout keyword
      # goes out only when a bound applies and the transport accepts it. It
      # is a per-attempt transport timeout only; the wall-clock bound of a
      # wait comes from {#bounded_by_wait} around the whole call.
      # @return [Object] the JSON-RPC result
      def task_rpc(srv, method, params, timeout: nil, epoch: nil)
        pinned_to_session(srv, epoch) do
          if timeout.nil? || !accepts_timeout?(srv)
            srv.rpc_request(method, params)
          else
            srv.rpc_request(method, params, timeout: timeout)
          end
        end
      end

      # Run the request with the transport refusing to write it once the
      # session it belongs to has ended: the built-in transports establish
      # (and so may re-establish) their session inside rpc_request itself, so
      # a guard that compares before the call cannot cover the request that
      # actually goes out. A transport that knows no session pin sends as
      # before.
      # @param epoch [Integer, nil] the session the request belongs to
      # @return [Object] the block's value
      def pinned_to_session(srv, epoch, &block)
        return block.call if epoch.nil? || !srv.respond_to?(:pinned_to_session)

        srv.pinned_to_session(epoch, &block)
      end

      # @return [Boolean] whether the transport's rpc_request takes timeout:
      def accepts_timeout?(srv)
        srv.method(:rpc_request).parameters.any? { |type, name| type == :keyrest || (type == :key && name == :timeout) }
      rescue NameError
        true
      end

      # The timeout for a request that must not outlive the wait: what is
      # left of it (a tiny positive floor keeps the transport from reading 0
      # as "no timeout"), capped so a hung request never blocks the wait
      # for the task's whole lifetime.
      # @param deadline [Float, nil] monotonic deadline of the wait
      # @return [Float]
      def request_timeout(deadline, srv = nil)
        remaining = deadline && [deadline - monotonic_time, MIN_TASK_REQUEST_TIMEOUT].max
        # The cap bounds a request whose wait has no near deadline; it never
        # enlarges a shorter timeout the transport was configured with.
        configured = srv.respond_to?(:read_timeout) ? srv.read_timeout : nil
        [remaining, MAX_TASK_REQUEST_TIMEOUT, configured.is_a?(Numeric) ? configured : nil].compact.min
      end

      # @param task_id [Object] a peer-controlled task id
      # @return [String] safe for a log line or exception message
      def shown_task_id(task_id)
        sanitize_peer_log_text(task_id.to_s)
      end

      # The TTL backstop counts only once a poll has been tried: a seed that
      # already looks expired is still confirmed by tasks/get.
      # @return [void]
      # @raise [MCPClient::Errors::TaskError]
      def raise_if_past_deadline!(wait)
        raise_ttl_elapsed!(wait) if wait[:polled] && ttl_backstop_elapsed?(wait)
        raise_if_past_caller_deadline!(wait)
      end

      # Whether the TTL backstop the wait holds has run out — and is still
      # the backstop of the session that is live. A restart (during the
      # poll, during the sleep between two of them) ends the task the
      # backstop was observed on: what the replacement session calls this
      # task has a TTL of its own, so the stale one is dropped here rather
      # than ending the wait before the new session has been polled. The
      # wait's own epoch is left alone: the answer path compares it to
      # decide whether an answer still belongs to the session it was
      # produced in.
      # @return [Boolean]
      def ttl_backstop_elapsed?(wait)
        return false unless wait[:ttl_deadline] && monotonic_time >= wait[:ttl_deadline]
        return true unless wait[:epoch] &&
                           answered_keys_mutex.synchronize { current_session_epoch(wait[:srv]) } != wait[:epoch]

        wait[:ttl_deadline] = nil
        wait[:last] = nil
        false
      end

      # The capability probe (initialization, discovery) counts against the
      # caller's budget: a spent budget sends nothing, and a probe that
      # outlives the remaining budget ends the wait — the transports take no
      # per-call budget for their handshake, so the probe runs on its own
      # thread and is abandoned (it finishes or fails on its own) once the
      # wait is over.
      # @param wait [Hash]
      # @return [void]
      # @raise [MCPClient::Errors::TaskError] when the budget ran out
      def probe_task_capability!(wait)
        raise_if_past_caller_deadline!(wait)
        return ensure_task_capability!(wait[:srv], 'get', strict: true) unless wait[:deadline]

        probe = shared_task_probe(wait[:srv])
        remaining = [wait[:deadline] - monotonic_time, 0].max
        unless probe.join(remaining)
          raise MCPClient::Errors::TaskError, "Timed out waiting for task '#{shown_task_id(wait[:task_id])}'"
        end

        error = probe[:error]
        raise error if error

        raise_if_past_caller_deadline!(wait)
      end

      # One capability probe per server at a time: a wait that timed out on
      # the handshake leaves it running, and the next wait joins that same
      # probe instead of starting another (HTTP transports would tear down
      # the session the first handshake just established).
      # @param srv [MCPClient::ServerBase]
      # @return [Thread] the live probe
      def shared_task_probe(srv)
        answered_keys_mutex.synchronize do
          @task_probes ||= {}.compare_by_identity
          live = @task_probes[srv]
          return live if live&.alive?

          @task_probes[srv] = Thread.new do
            Thread.current.report_on_exception = false
            begin
              ensure_task_capability!(srv, 'get', strict: true)
            rescue Exception => e # rubocop:disable Lint/RescueException -- handed back to the waiting thread
              Thread.current[:error] = e
            end
          end
        end
      end

      # The caller's timeout never moves and is enforced whatever the task
      # did in the meantime.
      # @return [void]
      # @raise [MCPClient::Errors::TaskError]
      def raise_if_past_caller_deadline!(wait)
        return unless wait[:deadline] && monotonic_time >= wait[:deadline]

        raise MCPClient::Errors::TaskError, "Timed out waiting for task '#{shown_task_id(wait[:task_id])}'"
      end

      # @raise [MCPClient::Errors::TaskError]
      def raise_ttl_elapsed!(wait)
        # The server may purge the task any moment; its bookkeeping is done
        # — the bookkeeping of the session this wait was following, not
        # whatever a restart has recorded under the id since.
        forget_task_keys(wait[:srv], wait[:task_id], state: wait[:state])
        raise MCPClient::Errors::TaskError,
              "Task '#{shown_task_id(wait[:task_id])}' did not reach a terminal status within its TTL " \
              '(createdAt + ttlMs)'
      end

      # The seed's TTL backstop (see #raise_if_past_deadline! for why an
      # expired-looking seed does not end the wait before the first poll).
      # @return [void]
      def seed_ttl_deadline(task, wait)
        remaining = task.ttl_remaining
        wait[:ttl_deadline] = monotonic_time + [remaining, 0.0].max if remaining
      end

      # Record the latest TTL backstop (createdAt + ttlMs) of the task; every
      # observation replaces it ("ttlMs MAY change over the lifetime of a
      # task"), so an extended TTL extends the wait and a task made
      # unlimited (ttlMs null) has no backstop any more.
      # @return [void]
      # @raise [MCPClient::Errors::TaskError] when the TTL already elapsed
      def bound_wait_by_ttl(current, wait)
        remaining = current.ttl_remaining
        raise_ttl_elapsed!(wait) if remaining && remaining <= 0
        if remaining
          wait[:ttl_deadline] = monotonic_time + remaining
        elsif current.ttl_reported?
          # The observation reported a ttlMs the wait cannot turn into a
          # deadline: an explicit null, or a value the clock cannot
          # represent (Task#ttl_remaining answers nil for both). Either way
          # the task has no backstop any more, and keeping the previous one
          # would end the wait before the TTL the server just extended.
          # Only an observation carrying no ttlMs at all keeps the last one.
          wait[:ttl_deadline] = nil
        end
      end

      # One tasks/get, bounded by what is left of the wait and pinned to the
      # session the wait joined: the transports establish (and so may
      # re-establish) their session inside rpc_request itself, and a poll
      # answered by the session that replaced this one would describe another
      # lifetime of the same, reusable task id. A request that merely timed
      # out — or that the pin refused to write — is not the end of the task
      # ("Clients SHOULD continue polling until the task reaches a terminal
      # status"): nil is returned and the caller polls again.
      # @return [MCPClient::Task, nil]
      def poll_task(wait)
        wait[:polled] = true
        bounded_by_wait(wait, deadline: wait[:deadline]) do
          get_task(wait[:task_id], server: wait[:srv], state: wait[:state], epoch: wait[:epoch], polling: true,
                                   timeout: request_timeout(wait_deadline(wait), wait[:srv]))
        end
      rescue MCPClient::Errors::TaskNotFound
        # Gone for good: nothing of it may colour a later task with this id.
        forget_task_keys(wait[:srv], wait[:task_id], state: wait[:state])
        raise
      rescue MCPClient::Errors::SessionChangedError
        # Nothing was asked: the transport held the poll back from the
        # session that replaced its own. The wait sees the move on its next
        # refresh and ends there (the task belonged to the ended session).
        logger.debug("tasks/get for task #{shown_task_id(wait[:task_id])} was not sent into the session that " \
                     'replaced its own')
        nil
      rescue MCPClient::Errors::TaskError => e
        raise unless e.cause.is_a?(MCPClient::Errors::RequestTimeoutError)

        logger.debug("tasks/get for task #{shown_task_id(wait[:task_id])} timed out; polling again")
        nil
      end

      # A DetailedTask MUST carry the payload its terminal status implies
      # (the result of a completed task, the JSON-RPC error of a failed one).
      # @param task [MCPClient::Task] a detailed terminal task
      # @return [void]
      # @raise [MCPClient::Errors::InvalidResultError]
      def validate_terminal_task!(task)
        return if task.payload_present?

        field = task.failed? ? 'error' : 'result'
        present = task.failed? ? !task.error.nil? : !task.result.nil?
        shape = if task.failed?
                  'a JSON-RPC error object (integer code, string message)'
                else
                  'an object whose resultType, if any, is "complete"'
                end
        problem = present ? "with #{field} that is not #{shape}" : "without the #{field} field"
        raise MCPClient::Errors::InvalidResultError, "Invalid task: status #{task.status} #{problem}"
      end

      # Enforce the MCP 2026-07-28 tasks extension gate: this client must have
      # declared it and the server must have negotiated it.
      # @param srv [MCPClient::ServerBase]
      # @return [void]
      # @raise [MCPClient::Errors::CapabilityError]
      def ensure_tasks_extension!(srv)
        extension = MCPClient::JsonRpcCommon::TASKS_EXTENSION
        unless tasks_extension?
          raise MCPClient::Errors::CapabilityError,
                "Tasks on an MCP 2026-07-28 server require the #{extension} extension: pass " \
                "extensions: ['#{extension}'] to MCPClient::Client.new"
        end
        return if srv.capability?('extensions', extension)

        raise MCPClient::Errors::CapabilityError,
              "Server #{srv.name || srv.class.name} did not negotiate the #{extension} tasks extension"
      end

      # tools/call on a 2026-07-28 server: the server alone decides whether to
      # answer with a task, so send a plain call and wrap the outcome.
      # @return [MCPClient::Task] the server's task, or a locally completed one
      def call_tool_as_modern_task(tool_name, parameters, srv, tool: nil)
        ensure_tasks_extension!(srv)
        generation_before = tools_generation_of(srv)
        # The session the call reaches: a task it creates belongs to that
        # session, whatever session is live once the answer is parsed.
        epoch = invocation_session_epoch(srv)
        result = begin
          srv.call_tool(tool_name, parameters)
        rescue MCPClient::Errors::ServerError => e
          # Protocol errors (HeaderMismatch, missing capability, ...) keep
          # their type; anything else is a failed creation.
          raise if e.protocol_error?

          raise MCPClient::Errors::TaskError, 'Error creating task for tool ' \
                                              "'#{sanitize_peer_log_text(tool_name.to_s)}': " \
                                              "#{sanitize_peer_log_text(e.message)}"
        rescue MCPClient::Errors::ToolCallError, MCPClient::Errors::TransportError,
               MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::TaskError, 'Error creating task for tool ' \
                                              "'#{sanitize_peer_log_text(tool_name.to_s)}': " \
                                              "#{sanitize_peer_log_text(e.message)}"
        end
        return created_task(result, srv, epoch) if task_result?(result)

        # Answered synchronously: the result is validated against the tool's
        # outputSchema exactly as #call_tool would — against the definition
        # a mid-call HeaderMismatch refresh replaced, when it did.
        if tool
          tool = refreshed_tool(tool) || tool if tools_generation_of(srv) != generation_before
          result = validate_structured_content!(tool, result)
        end
        MCPClient::Task.completed_locally(result, server: srv)
      end

      # The handle for a CreateTaskResult, which MUST carry a taskId.
      # @param epoch [Integer, nil] the session the creating call was sent in;
      #   without one the session live at this call is taken
      # @return [MCPClient::Task]
      # @raise [MCPClient::Errors::InvalidResultError]
      def created_task(result, srv, epoch = nil)
        # A CreateTaskResult is a Task: a defaulted status or a missing TTL
        # would drive the wait on made-up state (and lose the backstop).
        unless result.is_a?(Hash) && result['taskId'].is_a?(String)
          raise MCPClient::Errors::InvalidResultError, 'Invalid CreateTaskResult: no taskId'
        end

        problem = task_shape_problem(result)
        raise MCPClient::Errors::InvalidResultError, "Invalid CreateTaskResult: #{problem}" if problem

        epoch ||= invocation_session_epoch(srv)
        # A creation is a new task lifetime: whatever an earlier task with
        # this id left behind (answered keys, an ambiguous update) is not its.
        forget_task_keys(srv, result['taskId'], epoch: epoch)
        # The handle is the object just validated: a 2026-07-28
        # CreateTaskResult is the flat Task itself, and an extra `task`
        # property (the legacy 2025 wrapper) must not replace it. It names
        # the session the call was answered in, not one that replaced it
        # between the answer and this handle.
        MCPClient::Task.from_json(result, server: srv, session_epoch: epoch)
      end

      # @param result [Object] a JSON-RPC result
      # @return [Boolean] whether it is a CreateTaskResult
      def task_result?(result)
        MCPClient::JsonRpcCommon.result_type(result) == 'task'
      end

      # Turn a CreateTaskResult answer to tools/call into the call's final
      # result by waiting for the task.
      # @param epoch [Integer, nil] the session the tools/call was sent in
      # @return [Object] the final CallToolResult
      def complete_task_result(tool_name, server, result, epoch = nil)
        return result unless task_result?(result)

        task = created_task(result, server, epoch)
        logger.info("tools/call '#{sanitize_peer_log_text(tool_name.to_s)}' was accepted as task " \
                    "#{shown_task_id(task.task_id)}; waiting for it to finish")
        task_outcome(wait_for_task(task))
      end

      # The request outcome carried by a terminal task.
      # @param task [MCPClient::Task] a terminal task
      # @return [Object] the result of a completed task
      # @raise [MCPClient::Errors::ServerError] the JSON-RPC error of a failed task
      # @raise [MCPClient::Errors::TaskError] when the task was cancelled (or is not terminal)
      def task_outcome(task)
        case task.status
        when 'completed' then task.result
        when 'failed'
          error = task.error.is_a?(Hash) ? task.error : {}
          error = error.merge('message' => sanitize_peer_log_text((error['message'] || task.status_message ||
                                                                  'Task failed').to_s))
          raise MCPClient::Errors::ServerError.from_jsonrpc(error)
        else
          raise MCPClient::Errors::TaskError, "Task '#{shown_task_id(task.task_id)}' ended #{task.status}"
        end
      end

      # Answer the input requests of an input_required task that have not
      # been answered yet (keys are unique over a task's lifetime, so a key
      # seen again on a later poll is the same request).
      # @return [Array<String>] the keys answered now
      def answer_task_input_requests(task, answered, srv, wait = {})
        return [] unless task.input_required?

        requests = task.input_requests
        # A creation seed says input_required without listing the requests;
        # the next tasks/get carries them.
        return [] if requests.nil? && !task.detailed?

        unless requests.is_a?(Hash)
          raise MCPClient::Errors::InputRequiredError.new(
            'Malformed input_required task: inputRequests is not an object', data: task.to_h
          )
        end

        # Reserve the keys before the handlers run, in one step with the
        # per-task round limit, so two waits on the same task cannot both
        # answer them nor spend the budget twice on one snapshot; a handler
        # that fails gives the keys back, except those answered through
        # #update_task in the meantime.
        # The bookkeeping of the session the wait joined, not of whatever a
        # restart has recorded since: the answered set the caller reserves
        # in belongs to that session, and a round charged to the replacement
        # session would block a task this observation says nothing about.
        state = wait[:state] || task_state(srv, task.task_id)
        # The keys a handler presents are in flight from the moment it
        # starts, in the set of the session it starts in — fixed here,
        # before anything runs — so no forget of the task's bookkeeping lets
        # a retry present them again while the host is still answering.
        pending, held, held_key = reserve_input_requests(task, requests, answered, srv, state)
        return [] if pending.empty?

        abandoned = false
        begin
          responses = bounded_by_wait(wait, on_abandon: lambda { |runner|
            abandoned = true
            hold_in_flight_keys(runner, state, answered, pending.keys, held, held_key)
          }) { srv.fulfil_input_requests(pending, task.to_h) }
          # The whole deadline (caller timeout and task TTL) is enforced
          # before anything is delivered.
          raise_if_past_deadline!(wait)
        rescue StandardError
          # Nothing was delivered: the keys go back (except those answered
          # through #update_task meanwhile) and so does the round.
          unless abandoned
            answered_keys_mutex.synchronize do
              answered.subtract(pending.keys - state[:submitted].to_a)
              state[:rounds] -= 1 if state[:rounds].positive?
              end_in_flight(pending.keys, held, held_key)
            end
          end
          raise
        end
        # The handler answered: its keys are no longer in flight (the
        # answered set keeps them deduplicated for this session).
        answered_keys_mutex.synchronize { end_in_flight(pending.keys, held, held_key) }
        # A session that restarted while the host was answering may have
        # reused the task id and the keys: the answers belong to the ended
        # session and are not delivered; the next poll asks again.
        if wait[:epoch] && answered_keys_mutex.synchronize { current_session_epoch(srv) } != wait[:epoch]
          logger.warn("Task #{shown_task_id(task.task_id)}: the server session restarted while its input was " \
                      'being answered; the answers are discarded')
          return []
        end
        deliver_task_update(srv, task.task_id, responses, wait)
        pending.keys
      end

      # Whether a task request's error means the task is gone. A rejection of
      # the supplied inputResponses (tasks/update) is about the params,
      # whatever else the message says: the task still exists. tasks/get
      # answers -32602 for an unknown task; tasks/update and tasks/cancel use
      # it for other reasons too, so there only an explicit indication counts.
      # @return [Boolean]
      def task_not_found_error?(error, method, modern)
        return false if method != 'tasks/get' && error.message.match?(/inputResponses/i)
        return true if error.message.match?(/not found|unknown task|no such task|invalid taskId|expired/i)
        return false if method != 'tasks/get' && error.message.match?(/params/i)

        modern && error.respond_to?(:code) && error.code == MCPClient::Errors::Codes::INVALID_PARAMS &&
          (method.nil? || method == 'tasks/get')
      end

      # Run a host handler or a task RPC within what is left of the wait:
      # with a deadline the work runs on its own thread and the wait ends
      # with the timed-out TaskError when it outlives the budget (the thread
      # is abandoned — a blocked elicitation cannot be interrupted, and a
      # transport implementing only the documented two-argument
      # rpc_request(method, params) takes no timeout at all, while the
      # built-in ones enforce theirs per attempt and may exceed it through
      # retry backoff — and its eventual answer is dropped); without a
      # deadline it runs inline.
      #
      # A handler is bounded by the whole wait (the caller's timeout and the
      # task's TTL); a task RPC only by the caller's timeout, which is what
      # makes wait_for_task(timeout:) a wall-clock bound on the complete
      # poll/update operation. The TTL is not applied to a request in
      # flight: an observation that comes back late MAY carry the extended
      # ttlMs that lifts the very backstop it outlived, so the TTL is
      # weighed against each observation (see #bound_wait_by_ttl) rather
      # than against the request fetching it.
      # @param on_abandon [Proc, nil] called with the abandoned thread before the wait ends
      # @param deadline [Float, nil] the bound to apply (default: the whole wait's)
      # @return [Object] the handler's result
      def bounded_by_wait(wait, on_abandon: nil, deadline: wait_deadline(wait))
        return yield unless deadline

        remaining = [deadline - monotonic_time, 0].max
        runner = Thread.new do
          Thread.current.report_on_exception = false
          yield
        end
        unless runner.join(remaining)
          on_abandon&.call(runner)
          # Whichever bound ran out ends the wait: the task's TTL or the
          # caller's timeout.
          raise_if_past_deadline!(wait)
          raise MCPClient::Errors::TaskError, "Timed out waiting for task '#{shown_task_id(wait[:task_id])}'"
        end

        runner.value
      end

      # Reserve, in one step under the registry lock, the requests nobody is
      # answering yet: they join the answered set, the in-flight set of this
      # session, and cost one input round.
      # @return [Array(Hash, Set, Array)] the requests to answer, the in-flight set and its key
      # @raise [MCPClient::Errors::InputRequiredError] past MAX_TASK_INPUT_ROUNDS
      def reserve_input_requests(task, requests, answered, srv, state)
        answered_keys_mutex.synchronize do
          keys = requests.except(*answered, *in_flight_task_keys(srv, task.task_id, key: state[:key]).to_a)
          return [keys, nil, nil] if keys.empty?

          if state[:rounds] >= MAX_TASK_INPUT_ROUNDS
            raise MCPClient::Errors::InputRequiredError.new(
              "Task '#{shown_task_id(task.task_id)}' kept requesting input after #{MAX_TASK_INPUT_ROUNDS} rounds",
              data: task.to_h
            )
          end

          held, held_key = in_flight_task_keys(srv, task.task_id, create: true, key: state[:key])
          held.merge(keys.keys)
          state[:rounds] += 1
          answered.merge(keys.keys)
          [keys, held, held_key]
        end
      end

      # An abandoned handler is still presenting its requests: the keys stay
      # reserved until it finishes (a later wait polls instead of asking the
      # host again, and the late answer is dropped), and the round it never
      # completed is given back so retries of a timed-out wait cannot spend
      # the per-task budget on one outstanding request.
      # @return [void]
      def hold_in_flight_keys(runner, state, answered, keys, held, held_key = nil)
        # The hold is the set of the session the handler was started in; the
        # watcher releases that very set — and drops only its own registry
        # entry — never one a later session's retry or another task filled.
        answered_keys_mutex.synchronize do
          state[:rounds] -= 1 if state[:rounds].positive?
          held.merge(keys)
        end
        Thread.new do
          Thread.current.report_on_exception = false
          begin
            runner.join
          rescue StandardError
            nil
          end
          answered_keys_mutex.synchronize do
            answered.subtract(keys - state[:submitted].to_a)
            end_in_flight(keys, held, held_key)
          end
        end
      end

      # The keys a handler presented are no longer in flight.
      # @return [void] (callers hold answered_keys_mutex)
      def end_in_flight(keys, held, held_key)
        return unless held

        held.subtract(keys)
        release_in_flight_entry(held, held_key) if held_key
      end

      # The wait before the next tasks/get: the server's pollIntervalMs
      # (never capped, never below MIN_TASK_POLL_INTERVAL), clamped to what
      # is left of the caller's timeout and of the task's TTL so neither can
      # be overshot by a whole polling interval.
      # @param task [MCPClient::Task]
      # @param deadline [Float, nil] monotonic deadline of the wait
      # @return [Float] seconds
      def task_poll_delay(task, deadline)
        interval = task.poll_interval_ms
        delay = interval.is_a?(Numeric) && interval >= 0 ? interval / 1000.0 : DEFAULT_TASK_POLL_INTERVAL
        # Infinity (an integer too large for a Float) and NaN land on the bound.
        delay = MAX_TASK_POLL_INTERVAL unless delay.finite?
        delay = delay.clamp(MIN_TASK_POLL_INTERVAL, MAX_TASK_POLL_INTERVAL)
        remaining = [deadline && (deadline - monotonic_time), task.ttl_remaining].compact.min
        remaining ? delay.clamp(0.0, [remaining, 0.0].max) : delay
      end

      # @return [Float] a monotonic clock reading in seconds
      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # The handle returned by a modern tasks/cancel: an acknowledgement only
      # (cancellation is eventually consistent), so the last known state of
      # this server's task. A handle from another server (or a bare id)
      # knows nothing about it: the task counts as still active.
      # @return [MCPClient::Task]
      def cancelled_task_handle(task, task_id, srv, epoch = nil)
        return task if task.is_a?(MCPClient::Task) && task.server.equal?(srv)

        MCPClient::Task.new(task_id: task_id, status: 'working', server: srv, modern: true, session_epoch: epoch)
      end
    end
  end
end
