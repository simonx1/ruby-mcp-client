# frozen_string_literal: true

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
        ensure_task_capability!(srv, 'get', strict: true)
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

        # The caller's deadline and the task's TTL backstop are kept apart:
        # the TTL may change with every observation (the server MAY extend
        # it) while the caller's timeout never moves.
        wait = { task_id: task_id, srv: srv, deadline: timeout && (monotonic_time + timeout), ttl_deadline: nil,
                 answered: answered_task_keys(srv, task_id), last: nil }
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
            next sleep(wait[:last] ? task_poll_delay(wait[:last],
                                                     wait_deadline(wait)) : MIN_TASK_POLL_INTERVAL)
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
        state = task_state(wait[:srv], wait[:task_id])
        pending = answered_keys_mutex.synchronize { state[:pending_update] }
        return unless pending

        send_task_update(wait[:srv], wait[:task_id], pending, timeout: request_timeout(wait_deadline(wait)))
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

      # Per-task bookkeeping shared by every wait on the task: the answered
      # keys, the input rounds spent and an update still to be delivered.
      # @return [Hash]
      def task_state(srv, task_id)
        answered_keys_mutex.synchronize do
          @task_states ||= {}
          @task_states[[srv.object_id, task_id]] ||= { answered: Set.new, submitted: Set.new, rounds: 0,
                                                       pending_update: nil }
        end
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

      # @return [void]
      def forget_task_keys(srv, task_id)
        answered_keys_mutex.synchronize { @task_states&.delete([srv.object_id, task_id]) }
      end

      # Send the answers a handler produced. An ambiguous delivery (the
      # server may or may not have applied it) is not the end of the wait:
      # the payload stays pending and goes out again with the next poll,
      # like a lost tasks/get. A definite rejection surfaces.
      # @return [void]
      def deliver_task_update(task_id, responses, srv, wait)
        send_task_update(srv, task_id, responses, timeout: request_timeout(wait_deadline(wait)))
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
      # @return [true]
      # @raise [MCPClient::Errors::TaskError, MCPClient::Errors::ServerError]
      def send_task_update(srv, task_id, input_responses, timeout: nil)
        shown = shown_task_id(task_id)
        state = task_state(srv, task_id)
        pending = answered_keys_mutex.synchronize { state[:pending_update] }
        input_responses = pending.merge(input_responses) if pending
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
          raise MCPClient::Errors::TaskError, "Error updating task '#{shown}': #{sanitize_peer_log_text(e.message)}"
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
      def request_timeout(deadline)
        remaining = deadline && [deadline - monotonic_time, MIN_TASK_REQUEST_TIMEOUT].max
        remaining = [remaining, MAX_TASK_REQUEST_TIMEOUT].min if remaining
        remaining || MAX_TASK_REQUEST_TIMEOUT
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
        wait[:ttl_deadline] = remaining && (monotonic_time + remaining)
      end

      # One tasks/get, bounded by what is left of the wait. A request that
      # merely timed out is not the end of the task ("Clients SHOULD continue
      # polling until the task reaches a terminal status"): nil is returned
      # and the caller polls again.
      # @return [MCPClient::Task, nil]
      def poll_task(wait)
        wait[:polled] = true
        get_task(wait[:task_id], server: wait[:srv], timeout: request_timeout(wait_deadline(wait)))
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
        problem = present ? "with a #{field} that is not an object" : "without the #{field} field"
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
        task = MCPClient::Task.from_create_result(result, server: srv)
        unless task.task_id.is_a?(String)
          raise MCPClient::Errors::InvalidResultError, 'Invalid CreateTaskResult: no taskId'
        end

        task
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
          responses = srv.fulfil_input_requests(pending, task.to_h)
        rescue StandardError
          submitted = task_state(srv, task.task_id)[:submitted]
          answered_keys_mutex.synchronize { answered.subtract(pending.keys - submitted.to_a) }
          raise
        end
        deliver_task_update(task.task_id, responses, srv, wait)
        pending.keys
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
