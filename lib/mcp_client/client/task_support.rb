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

        begin
          srv.rpc_request('tasks/update', { taskId: task_id, inputResponses: input_responses })
          true
        rescue MCPClient::Errors::ServerError => e
          raise if e.protocol_error?

          raise task_error_from(e, task_id, 'updating', modern: true, method: 'tasks/update')
        rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::TaskError, "Error updating task '#{task_id}': #{e.message}"
        end
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

        wait = { task_id: task_id, srv: srv, deadline: timeout && (monotonic_time + timeout), rounds: 0,
                 answered: answered_task_keys(srv, task_id) }
        # The CreateTaskResult seed is not an observation: the first
        # tasks/get goes out at once, and only DetailedTasks drive the wait.
        loop do
          current = observe_task(wait)
          if current.terminal?
            forget_task_keys(srv, task_id)
            return current
          end

          answer_task_round(current, wait)
          if current.ttl_elapsed?
            raise MCPClient::Errors::TaskError,
                  "Task '#{shown_task_id(task_id)}' did not reach a terminal status within its TTL (createdAt + ttlMs)"
          end

          sleep(task_poll_delay(current, wait[:deadline]))
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
        validate_terminal_task!(current) if current.terminal?
        current
      end

      # Answer this poll's outstanding input requests, bounding how many
      # rounds a task may demand.
      # @return [void]
      def answer_task_round(current, wait)
        return unless pending_task_input?(current, wait[:answered])

        # The limit is checked before the handlers run and the update goes out.
        if wait[:rounds] >= MAX_TASK_INPUT_ROUNDS
          raise MCPClient::Errors::InputRequiredError.new(
            "Task '#{shown_task_id(wait[:task_id])}' kept requesting input after #{MAX_TASK_INPUT_ROUNDS} rounds",
            data: current.to_h
          )
        end

        answered_now = answer_task_input_requests(current, wait[:answered], wait[:srv])
        return if answered_now.empty?

        wait[:answered].merge(answered_now)
        wait[:rounds] += 1
      end

      # Whether the task lists an input request that has not been answered.
      # @return [Boolean]
      def pending_task_input?(task, answered)
        return false unless task.input_required? && task.input_requests.is_a?(Hash)

        task.input_requests.keys.any? { |key| !answered.include?(key) }
      end

      # The inputRequests keys already answered for a task, kept across
      # waits ("Clients SHOULD deduplicate inputRequests keys across
      # consecutive polls") until the task is terminal or cancelled.
      # @return [Set<String>]
      def answered_task_keys(srv, task_id)
        @answered_task_keys ||= {}
        @answered_task_keys[[srv.object_id, task_id]] ||= Set.new
      end

      # @return [void]
      def forget_task_keys(srv, task_id)
        @answered_task_keys&.delete([srv.object_id, task_id])
      end

      # @param task_id [Object] a peer-controlled task id
      # @return [String] safe for a log line or exception message
      def shown_task_id(task_id)
        sanitize_peer_log_text(task_id.to_s)
      end

      # @return [void]
      # @raise [MCPClient::Errors::TaskError]
      def raise_if_past_deadline!(wait)
        return unless wait[:deadline] && monotonic_time >= wait[:deadline]

        raise MCPClient::Errors::TaskError, "Timed out waiting for task '#{shown_task_id(wait[:task_id])}'"
      end

      # One tasks/get, bounded by what is left of the wait.
      # @return [MCPClient::Task]
      def poll_task(wait)
        deadline = wait[:deadline]
        # The request never outlives the wait (a tiny positive floor keeps
        # the transport from reading 0 as "no timeout").
        remaining = deadline && [deadline - monotonic_time, MIN_TASK_REQUEST_TIMEOUT].max
        get_task(wait[:task_id], server: wait[:srv], timeout: remaining)
      end

      # A DetailedTask MUST carry the payload its terminal status implies
      # (the result of a completed task, the JSON-RPC error of a failed one).
      # @param task [MCPClient::Task] a detailed terminal task
      # @return [void]
      # @raise [MCPClient::Errors::InvalidResultError]
      def validate_terminal_task!(task)
        return if task.payload_present?

        missing = task.failed? ? 'error' : 'result'
        raise MCPClient::Errors::InvalidResultError,
              "Invalid task: status #{task.status} without the #{missing} field"
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

          raise MCPClient::Errors::TaskError, "Error creating task for tool '#{tool_name}': #{e.message}"
        rescue MCPClient::Errors::ToolCallError, MCPClient::Errors::TransportError,
               MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::TaskError, "Error creating task for tool '#{tool_name}': #{e.message}"
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
      def answer_task_input_requests(task, answered, srv)
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

        pending = requests.except(*answered)
        return [] if pending.empty?

        update_task(task.task_id, srv.fulfil_input_requests(pending, task.to_h), server: srv)
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
      # (cancellation is eventually consistent), so the last known state.
      # @return [MCPClient::Task]
      def cancelled_task_handle(task, task_id, srv)
        return task if task.is_a?(MCPClient::Task) && task.server.equal?(srv)

        status = task.is_a?(MCPClient::Task) ? task.status : 'working'
        MCPClient::Task.new(task_id: task_id, status: status, server: srv, modern: true)
      end
    end
  end
end
