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
      # in responses"), and the longest wait honoured.
      DEFAULT_TASK_POLL_INTERVAL = 1.0
      MAX_TASK_POLL_INTERVAL = 60.0

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
        ensure_task_capability!(srv, 'update')
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

          raise task_error_from(e, task_id, 'updating', modern: true)
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
        unless modern_server?(srv)
          raise MCPClient::Errors::TaskError, 'wait_for_task requires an MCP 2026-07-28 server (tasks extension)'
        end

        deadline = timeout && (monotonic_time + timeout)
        answered = []
        current = task.is_a?(MCPClient::Task) ? task : nil
        loop do
          current ||= get_task(task_id, server: srv)
          return current if current.terminal?

          answered.concat(answer_task_input_requests(current, answered, srv))
          if current.ttl_elapsed?
            raise MCPClient::Errors::TaskError,
                  "Task '#{task_id}' did not reach a terminal status within its TTL (createdAt + ttlMs)"
          end
          if deadline && monotonic_time >= deadline
            raise MCPClient::Errors::TaskError, "Timed out waiting for task '#{task_id}'"
          end

          sleep(task_poll_delay(current))
          current = nil
        end
      end

      # Whether this client declared the MCP 2026-07-28 tasks extension
      # (`extensions: ['io.modelcontextprotocol/tasks']`).
      # @return [Boolean]
      def tasks_extension?
        @extensions.key?(MCPClient::JsonRpcCommon::TASKS_EXTENSION)
      end

      private

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
        rescue MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::TaskError, "Error creating task for tool '#{tool_name}': #{e.message}"
        end
        return MCPClient::Task.from_create_result(result, server: srv) if task_result?(result)

        MCPClient::Task.completed_locally(result, server: srv)
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

        task = MCPClient::Task.from_create_result(result, server: server)
        logger.info("tools/call '#{tool_name}' was accepted as task #{sanitize_peer_log_text(task.task_id.to_s)}; " \
                    'waiting for it to finish')
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
          error = task.error.is_a?(Hash) ? task.error : { 'message' => task.status_message || 'Task failed' }
          raise MCPClient::Errors::ServerError.from_jsonrpc(error)
        else
          raise MCPClient::Errors::TaskError, "Task '#{task.task_id}' ended #{task.status}"
        end
      end

      # Answer the input requests of an input_required task that have not
      # been answered yet (keys are unique over a task's lifetime, so a key
      # seen again on a later poll is the same request).
      # @return [Array<String>] the keys answered now
      def answer_task_input_requests(task, answered, srv)
        return [] unless task.input_required?

        requests = task.input_requests
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

      # @param task [MCPClient::Task]
      # @return [Float] seconds to wait before the next tasks/get
      def task_poll_delay(task)
        interval = task.poll_interval_ms
        return DEFAULT_TASK_POLL_INTERVAL unless interval.is_a?(Numeric) && interval >= 0

        [interval / 1000.0, MAX_TASK_POLL_INTERVAL].min
      end

      # @return [Float] a monotonic clock reading in seconds
      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # The handle returned by a modern tasks/cancel: an acknowledgement only
      # (cancellation is eventually consistent), so the last known state.
      # @return [MCPClient::Task]
      def cancelled_task_handle(task, task_id, srv)
        return task if task.is_a?(MCPClient::Task)

        MCPClient::Task.new(task_id: task_id, status: 'working', server: srv, modern: true)
      end
    end
  end
end
