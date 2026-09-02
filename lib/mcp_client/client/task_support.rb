# frozen_string_literal: true

require_relative '../task'
require_relative '../errors'
require_relative '../json_rpc_common'

module MCPClient
  class Client
    # MCP 2026-07-28 tasks extension (io.modelcontextprotocol/tasks) support
    # for {MCPClient::Client}: declared through `extensions:`, a server may
    # answer tools/call with a task that the client then polls (tasks/get),
    # feeds (tasks/update) and cancels (tasks/cancel).
    module TaskSupport
      # Seconds to wait before the next tasks/get when the server gave no
      # pollIntervalMs ("Clients SHOULD respect the pollIntervalMs provided
      # in responses"), and the floor that keeps a pollIntervalMs of 0 from
      # turning the wait into a busy loop.
      DEFAULT_TASK_POLL_INTERVAL = 1.0
      MIN_TASK_POLL_INTERVAL = 0.05
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
      # @raise [MCPClient::Errors::TaskError] if the update fails or the server predates tasks/update
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

        send_task_update(srv, task_id, input_responses)
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
      # @raise [MCPClient::Errors::TaskError] on timeout, TTL expiry or a failed request
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
                 answered: nil, epoch: nil, last: nil }
        probe_task_capability!(wait)
        unless modern_server?(srv)
          raise MCPClient::Errors::TaskError, 'wait_for_task requires an MCP 2026-07-28 server (tasks extension)'
        end

        # A DetailedTask that is already terminal is final: its payload is
        # authoritative and the server may purge it any moment.
        if task.is_a?(MCPClient::Task) && task.detailed? && task.terminal? && task.server.equal?(srv)
          validate_terminal_task!(task)
          forget_task_keys(srv, task_id)
          return task
        end

        refresh_wait_session(wait)
        # The CreateTaskResult seed is not an observation: the first
        # tasks/get goes out at once, whatever the seed claims. Its TTL
        # still bounds a wait whose polls never come back, and its
        # pollIntervalMs paces them — but only when the handle came from
        # the server being polled: task ids and state are per server, so a
        # handle from another server says nothing about this one's task.
        if task.is_a?(MCPClient::Task) && task.server.equal?(srv)
          seed_ttl_deadline(task, wait)
          wait[:last] = task
        end
        loop do
          current = observe_task(wait)
          # A poll that timed out is no observation: try again at the pace
          # the server last asked for, unless the wait is over.
          unless current
            raise_if_past_deadline!(wait)
            next sleep(wait[:last] ? task_poll_delay(wait[:last], wait_deadline(wait)) : default_poll_delay(wait))
          end

          wait[:last] = current
          if current.terminal?
            # A terminal task that came back after the caller's deadline
            # (transport retries) does not rescue a timed-out wait; the TTL
            # backstop is moot once the task is terminal.
            raise_if_past_caller_deadline!(wait)
            forget_task_keys(srv, task_id)
            return current
          end

          # The TTL backstop comes before any handler runs for the task, and
          # from now on bounds every poll, even ones that time out. A poll
          # that came back late (transport retries) ends the wait here.
          bound_wait_by_ttl(current, wait)
          raise_if_past_deadline!(wait)
          # The server may have restarted since the last poll: the task id
          # and its keys then belong to a new session, and so must the
          # answered set this wait reserves keys in.
          refresh_wait_session(wait)
          retransmit_pending_update(wait)
          # No new handler round once the wait is over, whatever the
          # retransmission took.
          raise_if_past_deadline!(wait)
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
      # new input is answered (the server ignores keys it already has). An
      # outcome that is ambiguous again keeps the payload pending and the
      # wait polling; a definite rejection surfaces (its keys were given
      # back, so the next wait presents the requests again).
      # @return [void]
      def retransmit_pending_update(wait)
        # Only what is still pending once the task's update lock is held is
        # sent: a snapshot taken before the lock could resend an answer a
        # concurrent, confirmed update has just superseded.
        send_task_update(wait[:srv], wait[:task_id], nil, timeout: request_timeout(wait_deadline(wait), wait[:srv]),
                                                          pending_only: true)
      rescue MCPClient::Errors::TaskError => e
        raise unless ambiguous_update_failure?(e)

        logger.debug("tasks/update for task #{shown_task_id(wait[:task_id])} could not be confirmed; " \
                     'it is sent again on the next poll')
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

      # Point a wait at the task state of the server's current session: a
      # wait that outlives a restart must reserve keys in the new session's
      # answered set, since the restarted server may reuse the task id and
      # its keys for what is a new request.
      # @param wait [Hash]
      # @return [void]
      def refresh_wait_session(wait)
        # The epoch and the state keyed under it are read in one step, so
        # a restart between the two cannot leave the wait pointing at one
        # session's set while recording another's epoch.
        answered_keys_mutex.synchronize do
          epoch = current_session_epoch(wait[:srv])
          next if wait[:epoch] == epoch && wait[:answered]

          wait[:epoch] = epoch
          wait[:answered] = task_state_locked(wait[:srv], wait[:task_id], epoch)[:answered]
        end
      end

      # Per-task bookkeeping shared by every wait on the task: the answered
      # keys, the input rounds spent, an update still to be delivered and
      # the lock that serializes its updates. Task ids are per server
      # session (a restarted stdio process may reuse them), so the state is
      # keyed by the transport's session epoch too and dies with it. The
      # epoch is read under the lock and never runs backwards: a caller
      # that read it before a restart gets the current session's state and
      # cannot delete it or bring an older session back.
      # @return [Hash]
      def task_state(srv, task_id)
        answered_keys_mutex.synchronize { task_state_locked(srv, task_id, current_session_epoch(srv)) }
      end

      # {#task_state} for a caller already holding the registry lock and the
      # epoch it read under it.
      # @return [Hash]
      def task_state_locked(srv, task_id, epoch)
        @task_states ||= {}
        key = [srv.object_id, epoch, task_id]
        # A previous session of this server is over: its state (answered
        # keys, pending answers) is dropped, not left behind.
        @task_states.delete_if { |other, _| other[0] == key[0] && other[1] < key[1] }
        @task_states[key] ||= { answered: Set.new, submitted: Set.new, rounds: 0,
                                pending_update: nil, update_mutex: Mutex.new }
      end

      # Forget every task's bookkeeping (the client is being cleaned up).
      # @return [void]
      def clear_task_states
        answered_keys_mutex.synchronize do
          @task_states = nil
          @task_session_epochs = nil
        end
      end

      # The server's session epoch as this client knows it, monotonic: the
      # highest value ever read wins, so a stale reading never reopens an
      # ended session. Callers hold answered_keys_mutex or do not care about
      # a concurrent bump (the next task_state resolves it).
      # @return [Integer]
      def current_session_epoch(srv)
        read = srv.respond_to?(:session_epoch) ? srv.session_epoch : 0
        @task_session_epochs ||= {}.compare_by_identity
        seen = @task_session_epochs[srv] || 0
        @task_session_epochs[srv] = [read, seen].max
      end

      # @return [Array] the registry key of a task's state
      def task_state_key(srv, task_id)
        [srv.object_id, current_session_epoch(srv), task_id]
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

      # Record keys whose answers were handed to the transport by
      # {#update_task}: they stay answered even if a handler that reserved
      # them fails afterwards.
      # @return [void]
      def remember_answered_keys(srv, task_id, keys)
        state = task_state(srv, task_id)
        answered_keys_mutex.synchronize do
          state[:answered].merge(keys)
          state[:submitted].merge(keys)
        end
      end

      # Whether a tasks/update failure means the server definitely did not
      # take the answers: a JSON-RPC error with a code from the server
      # itself. A 5xx, a closed response stream or any untyped server error
      # is ambiguous (the update may have been applied).
      # @param error [MCPClient::Errors::ServerError]
      # @return [Boolean]
      def definite_rejection?(error)
        error.code.is_a?(Integer) && !error.is_a?(MCPClient::Errors::TransientServerError)
      end

      # Give back keys the server definitely did not take.
      # @return [void]
      def release_answered_keys(srv, task_id, keys)
        state = task_state(srv, task_id)
        answered_keys_mutex.synchronize do
          state[:answered].subtract(keys)
          state[:submitted].subtract(keys)
        end
      end

      # The wait's effective deadline: the earlier of the caller's timeout
      # and the latest TTL backstop.
      # @return [Float, nil]
      def wait_deadline(wait)
        [wait[:deadline], wait[:ttl_deadline]].compact.min
      end

      # @return [Mutex] guards the answered-key registry (request threads share the client)
      def answered_keys_mutex
        @answered_keys_mutex ||= Mutex.new
      end

      # Drop a task's bookkeeping: it is terminal, cancelled, gone or past
      # its TTL, so nothing of it may colour a later task with the same id.
      # @return [void]
      def forget_task_keys(srv, task_id)
        answered_keys_mutex.synchronize { @task_states&.delete(task_state_key(srv, task_id)) }
      end

      # Send the answers a handler produced. An ambiguous delivery (the
      # server may or may not have applied it) is not the end of the wait:
      # the payload stays pending and goes out again with the next poll,
      # like a lost tasks/get. A definite rejection surfaces.
      # @return [void]
      def deliver_task_update(task_id, responses, srv, wait)
        send_task_update(srv, task_id, responses, timeout: request_timeout(wait_deadline(wait), srv))
      rescue MCPClient::Errors::TaskError => e
        raise unless ambiguous_update_failure?(e)

        logger.debug("tasks/update for task #{shown_task_id(task_id)} could not be confirmed; " \
                     'it is sent again on the next poll')
      end

      # One tasks/update, owning the pending-payload lifecycle: the keys are
      # answered as soon as the payload is handed to the transport; the
      # request carries every response still pending from an earlier
      # ambiguous delivery (the server ignores keys it already has, so a
      # resend is safe and no unconfirmed answer is left behind); a
      # confirmed delivery clears the pending payload (a later answer
      # supersedes a lost one); a definite JSON-RPC rejection gives the keys
      # back and drops the payload; an ambiguous outcome (timeout, transport
      # or connection failure, 5xx, untyped server error) keeps it pending
      # for retransmission.
      # @param timeout [Numeric, nil] request timeout, bounded by the wait when there is one
      # @param pending_only [Boolean] send whatever is pending under the lock and nothing else
      #   (a retransmission; nothing pending sends nothing)
      # @return [true]
      # @raise [MCPClient::Errors::TaskError, MCPClient::Errors::ServerError]
      def send_task_update(srv, task_id, input_responses, timeout: nil, pending_only: false)
        shown = shown_task_id(task_id)
        state = task_state(srv, task_id)
        # One update at a time per task: a concurrent update that read an
        # empty pending slot could otherwise confirm and wipe an answer
        # another delivery had just left pending. An explicit answer is
        # newer than a pending one for the same key and wins the merge.
        state[:update_mutex].synchronize do
          pending = answered_keys_mutex.synchronize { state[:pending_update] }
          input_responses = pending_only ? pending : pending&.merge(input_responses) || input_responses
          return true if input_responses.nil?

          keys = input_responses.keys.map(&:to_s)
          remember_answered_keys(srv, task_id, keys)
          begin
            srv.rpc_request('tasks/update', { taskId: task_id, inputResponses: input_responses }, timeout: timeout)
            answered_keys_mutex.synchronize { state[:pending_update] = nil }
            true
          rescue MCPClient::Errors::ServerError => e
            if definite_rejection?(e)
              release_answered_keys(srv, task_id, keys)
              answered_keys_mutex.synchronize { state[:pending_update] = nil }
            else
              keep_pending_update(state, input_responses)
            end
            raise if e.protocol_error?

            raise task_error_from(e, task_id, 'updating', modern: true, method: 'tasks/update')
          rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
            keep_pending_update(state, input_responses)
            raise MCPClient::Errors::TaskError,
                  "Error updating task '#{shown}': #{sanitize_peer_log_text(e.message)}"
          end
        end
      end

      # @return [void]
      def keep_pending_update(state, input_responses)
        answered_keys_mutex.synchronize do
          state[:pending_update] = (state[:pending_update] || {}).merge(input_responses)
        end
      end

      # Whether a failed tasks/update may still have been applied.
      # @param error [MCPClient::Errors::TaskError]
      # @return [Boolean]
      def ambiguous_update_failure?(error)
        cause = error.cause
        return true if cause.is_a?(MCPClient::Errors::TransportError) || cause.is_a?(MCPClient::Errors::ConnectionError)

        cause.is_a?(MCPClient::Errors::ServerError) && !definite_rejection?(cause)
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
        raise_ttl_elapsed!(wait) if wait[:polled] && wait[:ttl_deadline] && monotonic_time >= wait[:ttl_deadline]
        raise_if_past_caller_deadline!(wait)
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
        # The server may purge the task any moment; its bookkeeping is done.
        forget_task_keys(wait[:srv], wait[:task_id])
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
        elsif current.ttl.nil?
          # Only an explicit ttlMs null lifts the backstop; anything else
          # that yields no remaining time keeps the last one.
          wait[:ttl_deadline] = nil
        end
      end

      # One tasks/get, bounded by what is left of the wait. A request that
      # merely timed out is not the end of the task ("Clients SHOULD continue
      # polling until the task reaches a terminal status"): nil is returned
      # and the caller polls again.
      # @return [MCPClient::Task, nil]
      def poll_task(wait)
        wait[:polled] = true
        get_task(wait[:task_id], server: wait[:srv], timeout: request_timeout(wait_deadline(wait), wait[:srv]))
      rescue MCPClient::Errors::TaskNotFound
        # Gone for good: nothing of it may colour a later task with this id.
        forget_task_keys(wait[:srv], wait[:task_id])
        raise
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

      # A modern tasks/get result is a DetailedTask: every field the Task
      # shape requires must be there (ttlMs may be null but must be
      # present), since a defaulted status or a missing TTL would drive the
      # wait on made-up state.
      # @param result [Object] the raw tasks/get result
      # @return [void]
      # @raise [MCPClient::Errors::InvalidResultError]
      def validate_detailed_task_shape!(result)
        problem = detailed_task_shape_problem(result)
        raise MCPClient::Errors::InvalidResultError, "Invalid tasks/get result: #{problem}" if problem
      end

      # @return [String, nil] what is wrong with a DetailedTask's shape
      def detailed_task_shape_problem(result)
        task_shape_problem(result) || task_status_payload_problem(result)
      end

      # The fields every Task carries (CreateTaskResult and DetailedTask
      # alike): a status, parseable timestamps and a ttlMs key.
      # @param result [Object]
      # @return [String, nil]
      def task_shape_problem(result)
        return 'not an object' unless result.is_a?(Hash)
        return 'status is not a task status' unless MCPClient::Task::VALID_STATUSES.include?(result['status'])

        problem = task_timestamp_problem(result)
        return problem if problem
        return 'ttlMs is missing' unless result.key?('ttlMs')
        return 'ttlMs is not an integer or null' unless result['ttlMs'].nil? || result['ttlMs'].is_a?(Integer)

        nil
      end

      # The timestamps of a Task are ISO 8601; one that does not parse could
      # never bound a wait, so it is not a task at all.
      # @return [String, nil]
      def task_timestamp_problem(result)
        %w[createdAt lastUpdatedAt].each do |field|
          return "#{field} is not a string" unless result[field].is_a?(String)
          return "#{field} is not an ISO 8601 timestamp" unless iso8601?(result[field])
        end
        nil
      end

      # @return [Boolean]
      def iso8601?(text)
        Time.iso8601(text)
        true
      rescue ArgumentError
        false
      end

      # The payload a DetailedTask's status implies ("If status is completed,
      # result MUST be included; if failed, error; if input_required,
      # inputRequests").
      # @return [String, nil]
      def task_status_payload_problem(result)
        case result['status']
        when 'completed'
          unless MCPClient::Task.complete_result_object?(result['result'])
            'a completed task needs an object result whose resultType, if any, is "complete"'
          end
        when 'failed'
          unless MCPClient::Task.jsonrpc_error_object?(result['error'])
            'a failed task needs a JSON-RPC error object (integer code, string message)'
          end
        when 'input_required'
          'an input_required task needs an inputRequests object' unless result['inputRequests'].is_a?(Hash)
        end
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
      def call_tool_as_modern_task(tool_name, parameters, srv)
        ensure_tasks_extension!(srv)
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
        return created_task(result, srv) if task_result?(result)

        MCPClient::Task.completed_locally(result, server: srv)
      end

      # The handle for a CreateTaskResult, which MUST carry a taskId.
      # @return [MCPClient::Task]
      # @raise [MCPClient::Errors::InvalidResultError]
      def created_task(result, srv)
        # A CreateTaskResult is a Task: a defaulted status or a missing TTL
        # would drive the wait on made-up state (and lose the backstop).
        unless result.is_a?(Hash) && result['taskId'].is_a?(String)
          raise MCPClient::Errors::InvalidResultError, 'Invalid CreateTaskResult: no taskId'
        end

        problem = task_shape_problem(result)
        raise MCPClient::Errors::InvalidResultError, "Invalid CreateTaskResult: #{problem}" if problem

        # The handle is the object just validated: a 2026-07-28
        # CreateTaskResult is the flat Task itself, and an extra `task`
        # property (the legacy 2025 wrapper) must not replace it.
        MCPClient::Task.from_json(result, server: srv)
      end

      # @param result [Object] a JSON-RPC result
      # @return [Boolean] whether it is a CreateTaskResult
      def task_result?(result)
        MCPClient::JsonRpcCommon.result_type(result) == 'task'
      end

      # Turn a CreateTaskResult answer to tools/call into the call's final
      # result by waiting for the task.
      # @return [Object] the final CallToolResult
      def complete_task_result(tool_name, server, result)
        return result unless task_result?(result)

        task = created_task(result, server)
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
        state = task_state(srv, task.task_id)
        pending = answered_keys_mutex.synchronize do
          keys = requests.except(*answered)
          next keys if keys.empty?
          if state[:rounds] >= MAX_TASK_INPUT_ROUNDS
            raise MCPClient::Errors::InputRequiredError.new(
              "Task '#{shown_task_id(task.task_id)}' kept requesting input after #{MAX_TASK_INPUT_ROUNDS} rounds",
              data: task.to_h
            )
          end

          state[:rounds] += 1
          answered.merge(keys.keys)
          keys
        end
        return [] if pending.empty?

        begin
          responses = bounded_by_wait(wait) { srv.fulfil_input_requests(pending, task.to_h) }
          # The whole deadline (caller timeout and task TTL) is enforced
          # before anything is delivered.
          raise_if_past_deadline!(wait)
        rescue StandardError
          submitted = task_state(srv, task.task_id)[:submitted]
          answered_keys_mutex.synchronize { answered.subtract(pending.keys - submitted.to_a) }
          raise
        end
        # A session that restarted while the host was answering may have
        # reused the task id and the keys: the answers belong to the ended
        # session and are not delivered; the next poll asks again.
        if wait[:epoch] && current_session_epoch(srv) != wait[:epoch]
          logger.warn("Task #{shown_task_id(task.task_id)}: the server session restarted while its input was " \
                      'being answered; the answers are discarded')
          return []
        end
        deliver_task_update(task.task_id, responses, srv, wait)
        pending.keys
      end

      # Run a host handler within what is left of the wait: with a deadline
      # the handler runs on its own thread and the wait ends with the
      # timed-out TaskError when it outlives the budget (the handler thread
      # is abandoned — a blocked elicitation cannot be interrupted — and its
      # eventual answer is dropped); without a deadline it runs inline.
      # @return [Object] the handler's result
      def bounded_by_wait(wait)
        deadline = wait_deadline(wait)
        return yield unless deadline

        remaining = [deadline - monotonic_time, 0].max
        runner = Thread.new do
          Thread.current.report_on_exception = false
          yield
        end
        unless runner.join(remaining)
          # Whichever bound ran out ends the wait: the task's TTL or the
          # caller's timeout.
          raise_if_past_deadline!(wait)
          raise MCPClient::Errors::TaskError, "Timed out waiting for task '#{shown_task_id(wait[:task_id])}'"
        end

        runner.value
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
        delay = [delay, MIN_TASK_POLL_INTERVAL].max
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
      def cancelled_task_handle(task, task_id, srv)
        return task if task.is_a?(MCPClient::Task) && task.server.equal?(srv)

        MCPClient::Task.new(task_id: task_id, status: 'working', server: srv, modern: true)
      end
    end
  end
end
