# frozen_string_literal: true

require_relative 'task_support'

module MCPClient
  class Client
    # The task lifecycle API of {MCPClient::Client} (call_tool_as_task,
    # get_task, get_task_result, list_tasks, cancel_task) and the helpers
    # that gate task operations on the server's era and capabilities. Mixed
    # into Client; the polling and input handling live in {TaskSupport}.
    module TaskApi
      # Call a tool as a task (task-augmented tools/call, MCP 2025-11-25).
      #
      # Instead of blocking for the result, the server accepts the request and
      # immediately returns a task handle; the actual result is retrieved later
      # via {#get_task_result} once the task reaches a terminal status. The server
      # must advertise the tasks.requests.tools.call capability, and the tool must
      # declare execution.taskSupport of 'optional' or 'required'.
      # @param tool_name [String] the name of the tool to call
      # @param parameters [Hash] the parameters to pass to the tool
      # @param ttl [Integer, nil] optional requested task lifetime in milliseconds
      # @param server [String, Symbol, Integer, MCPClient::ServerBase, nil] optional server to use
      # @return [MCPClient::Task] the created task (status typically 'working')
      # @raise [MCPClient::Errors::ToolNotFound] if the tool is not found
      # @raise [MCPClient::Errors::ValidationError] if required parameters are missing
      # @raise [MCPClient::Errors::TaskError] if the server or tool does not support tasks, or creation fails
      def call_tool_as_task(tool_name, parameters, ttl: nil, server: nil)
        tool = resolve_tool(tool_name, server: server)
        validate_params!(tool, parameters)

        srv = tool.server
        raise MCPClient::Errors::ServerNotFound, "No server found for tool '#{tool_name}'" unless srv
        return call_tool_as_modern_task(tool_name, parameters, srv, tool: tool) if modern_server?(srv)

        unless server_supports_task_tool_call?(srv)
          raise MCPClient::Errors::TaskError,
                'Server does not support task-augmented tools/call (no tasks.requests.tools.call capability)'
        end
        unless tool.supports_task?
          raise MCPClient::Errors::TaskError,
                "Tool '#{tool_name}' does not support task execution (execution.taskSupport is forbidden/unset)"
        end

        task_params = {}
        task_params[:ttl] = ttl if ttl
        # Keep _meta (string or symbol key) as a top-level request field rather
        # than a tool argument, so request metadata is preserved and does not fail
        # tool input-schema validation.
        meta_key = [:_meta, '_meta'].find { |k| parameters.key?(k) }
        arguments = meta_key ? parameters.reject { |k, _| k == meta_key } : parameters
        rpc_params = { name: tool_name, arguments: arguments, task: task_params }
        rpc_params[:_meta] = parameters[meta_key] if meta_key

        # The task is created in the session this call reaches: a session that
        # ends before the handle is built takes the task with it, so the
        # handle names the session it was created in and not its successor.
        epoch = invocation_session_epoch(srv)

        begin
          result = pinned_to_session(srv, epoch) { srv.rpc_request('tools/call', rpc_params) }
          # A creation is a new lifetime of its task id here too: the handle
          # names the task this call started, so a handle of the task it
          # replaced never updates, cancels or waits for the one that
          # answers to the id now.
          started_task_lifetime(MCPClient::Task.from_create_result(result, server: srv, session_epoch: epoch),
                                srv, epoch)
        rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError,
               MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::TaskError, "Error creating task for tool '#{tool_name}': #{e.message}"
        end
      end

      # Get the current state of a task (tasks/get, MCP 2025-11-25)
      # @param task_id [String, MCPClient::Task] the task to query; passing the
      #   Task handle returned by #call_tool_as_task routes to its own server
      # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
      # @return [MCPClient::Task] the task with current status
      # @raise [ArgumentError] if the server is ambiguous in a multi-server client
      # @raise [MCPClient::Errors::ServerNotFound] if no server is available
      # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
      # @raise [MCPClient::Errors::TaskError] if retrieving the task fails, or the task handle belongs to a
      #   server session that has ended (its task id is another task's now)
      # @param timeout [Numeric, nil] request timeout in seconds (the transport default when nil)
      # @param state [Hash, nil] the task bookkeeping this poll belongs to (internal): a poll a
      #   wait abandoned on its wall clock forgets only what it was polling, never what a new
      #   session — or a new lifetime of a reused task id — recorded since
      # @param epoch [Integer, nil] the server session this poll is about (internal): task ids are
      #   per session and reusable, so a request that would reach the session which replaced it is
      #   not sent — what came back would describe another lifetime of the same id
      # @param polling [Boolean] whether the caller is a wait (internal): a session that ended under
      #   the request is a lost poll (SessionChangedError) for it, and a TaskError for anyone else
      def get_task(task_id, server: nil, timeout: nil, state: nil, epoch: nil, polling: false)
        srv = select_task_server(task_id, server, 'get_task')
        # A caller that named the task with a handle asks about the task that
        # handle names: the request is pinned to its session and refused once
        # that session has ended, where the reused id names another task
        # (the wait passes the session it polls in itself). A bare id names
        # what the session live at this call knows, and is pinned to it.
        epoch ||= handle_session_epoch(task_id, srv, 'getting') || invocation_session_epoch(srv)
        check_handle_lifetime!(task_id, srv, epoch, 'getting')
        # A refreshed handle names the task the caller asked about, not
        # whatever the id means when the answer comes back: without the
        # source handle's lifetime it would pass the guard above unchecked
        # and could later update, cancel or be waited on for a replacement.
        generation = handle_task_generation(task_id, srv)
        task_id = task_identifier(task_id)
        ensure_task_capability!(srv, 'get')

        begin
          result = task_rpc(srv, 'tasks/get', { taskId: task_id }, timeout: timeout, epoch: epoch)
          validate_detailed_task_shape!(result) if modern_server?(srv)
          # The handle is about the session the request was pinned to: one
          # that ended while the answer was in flight (or just after it came
          # back) must not stamp it with the session that replaced it.
          task = MCPClient::Task.from_json(result, server: srv, detailed: true, session_epoch: epoch,
                                                   task_generation: generation)
          # The answer must be about the task that was asked for: its state
          # drives result delivery and tasks/update.
          if modern_server?(srv) && task.task_id != task_id.to_s
            raise MCPClient::Errors::InvalidResultError,
                  "Invalid tasks/get result: taskId #{sanitize_peer_log_text(task.task_id.to_s).inspect} does not " \
                  "match the requested task #{sanitize_peer_log_text(task_id.to_s).inspect}"
          end
          # A terminal task is done with its input bookkeeping (answered keys,
          # pending answers): a reused id must never inherit it. What is
          # forgotten is the bookkeeping of the session that was asked, never
          # what the session replacing it has recorded under the same id.
          forget_task_keys(srv, task_id, state: state, epoch: epoch) if task.terminal?
          task
        rescue MCPClient::Errors::ServerError => e
          raise if e.protocol_error?

          error = task_error_from(e, task_id, 'getting', modern: modern_server?(srv), method: 'tasks/get')
          forget_task_keys(srv, task_id, state: state, epoch: epoch) if error.is_a?(MCPClient::Errors::TaskNotFound)
          raise error
        rescue MCPClient::Errors::SessionChangedError => e
          # Nothing was asked: the session this request is about has ended,
          # and the answer of the one that replaced it would be another
          # task's. A wait wants the raw signal (it treats it as a lost poll);
          # a direct caller gets the documented TaskError.
          raise if polling

          raise MCPClient::Errors::TaskError, "Error getting task '#{sanitize_peer_log_text(task_id.to_s)}': " \
                                              "#{sanitize_peer_log_text(e.message)}"
        rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::TaskError, "Error getting task '#{sanitize_peer_log_text(task_id.to_s)}': " \
                                              "#{sanitize_peer_log_text(e.message)}"
        end
      end

      # Retrieve the result of a completed task (tasks/result, MCP 2025-11-25).
      # Returns exactly what the underlying request would have returned (e.g. a
      # CallToolResult hash with 'content'/'isError'/'structuredContent'); it is
      # NOT wrapped in a Task. Blocks on the server until the task is terminal.
      #
      # NOTE: structured-content validation (see #validate_structured_content!)
      # does not cover task-delivered results yet: a task ID alone does not
      # identify which tool (and therefore which outputSchema) produced the
      # result, and the client keeps no task-to-tool registry. Callers who need
      # validation here can run MCPClient::SchemaValidator.validate themselves.
      # @param task_id [String, MCPClient::Task] the task; passing the Task
      #   handle returned by #call_tool_as_task routes to its own server
      # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
      # @return [Object] the underlying task result
      # @raise [ArgumentError] if the server is ambiguous in a multi-server client
      # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
      # @raise [MCPClient::Errors::TaskError] if retrieval fails, or the task handle belongs to a server
      #   session that has ended (its task id is another task's now)
      def get_task_result(task_id, server: nil)
        # A handle the server completed synchronously already carries its
        # result: no server is needed (or probed) to read it.
        return task_outcome(task_id) if task_id.is_a?(MCPClient::Task) && !task_id.remote?

        srv = select_task_server(task_id, server, 'get_task_result')
        # tasks/result must never reach a 2026-07-28 server, so the era has
        # to be known: an initialization failure surfaces here.
        ensure_task_capability!(srv, 'result', strict: true)
        # MCP 2026-07-28 removed tasks/result: the result is delivered inline
        # by tasks/get once the task is terminal.
        return task_outcome(wait_for_task(task_id, server: srv)) if modern_server?(srv)

        # The result of the task the handle names, in the session it was seen
        # in: the request is pinned to that session and refused once it has
        # ended, where the reused id would hand back another task's result.
        epoch = handle_session_epoch(task_id, srv, 'getting result for') || invocation_session_epoch(srv)
        check_handle_lifetime!(task_id, srv, epoch, 'getting result for')
        task_id = task_identifier(task_id)

        begin
          task_rpc(srv, 'tasks/result', { taskId: task_id }, epoch: epoch)
        rescue MCPClient::Errors::ServerError => e
          raise if e.protocol_error?

          raise task_error_from(e, task_id, 'getting result for')
        rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::TaskError, "Error getting result for task '#{shown_task_id(task_id)}': " \
                                              "#{sanitize_peer_log_text(e.message)}"
        end
      end

      # List tasks known to a server (tasks/list, paginated, MCP 2025-11-25)
      # @param cursor [String, nil] optional pagination cursor
      # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
      # @return [Hash] { tasks: Array<MCPClient::Task>, next_cursor: String, nil }
      # @raise [MCPClient::Errors::TaskError] if listing fails
      def list_tasks(cursor: nil, server: nil)
        srv = select_server(server)
        # tasks/list is gone on 2026-07-28 regardless of any extension, so the
        # era is settled before the capability gate could ask for one.
        begin
          probe_server_era(srv)
        rescue MCPClient::Errors::MCPError => e
          raise MCPClient::Errors::TaskError, "Error listing tasks: #{sanitize_peer_log_text(e.message)}"
        end
        if modern_server?(srv)
          raise MCPClient::Errors::TaskError,
                'tasks/list does not exist on MCP 2026-07-28 servers: keep the Task handles you created'
        end
        ensure_task_capability!(srv, 'list')

        params = cursor ? { cursor: cursor } : {}

        # The listed tasks are the ones the session this call reaches knows:
        # a handle from it names that session, not whatever replaced it.
        epoch = invocation_session_epoch(srv)

        begin
          result = pinned_to_session(srv, epoch) { srv.rpc_request('tasks/list', params) } || {}
          tasks = (result['tasks'] || []).map { |t| MCPClient::Task.from_json(t, server: srv, session_epoch: epoch) }
          { tasks: tasks, next_cursor: result['nextCursor'] }
        rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError,
               MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::TaskError, "Error listing tasks: #{sanitize_peer_log_text(e.message)}"
        end
      end

      # Cancel a task (tasks/cancel, MCP 2025-11-25)
      # @param task_id [String, MCPClient::Task] the task to cancel; passing the
      #   Task handle returned by #call_tool_as_task routes to its own server
      # @param server [Integer, String, Symbol, MCPClient::ServerBase, nil] server selector
      # @return [MCPClient::Task] the task with updated (cancelled) status
      # @raise [ArgumentError] if the server is ambiguous in a multi-server client
      # @raise [MCPClient::Errors::ServerNotFound] if no server is available
      # @raise [MCPClient::Errors::TaskNotFound] if the task does not exist
      # @raise [MCPClient::Errors::TaskError] if cancellation fails (including cancelling a terminal task, or
      #   naming it with a task handle whose server session has ended)
      def cancel_task(task_id, server: nil)
        srv = select_task_server(task_id, server, 'cancel_task')
        task = task_id
        task_id = task_identifier(task_id)
        ensure_task_capability!(srv, 'cancel')
        # Cancelling by a handle cancels that task, in the session it was
        # seen in: a handle kept across a restart must not cancel whatever
        # the replacement session named with the same id. A bare id cancels
        # what the session live at this call knows, and nothing else.
        epoch = handle_session_epoch(task, srv, 'cancelling') || invocation_session_epoch(srv)
        check_handle_lifetime!(task, srv, epoch, 'cancelling')

        begin
          result = task_rpc(srv, 'tasks/cancel', { taskId: task_id }, epoch: epoch)
          return cancelled_task_handle(task, task_id, srv, epoch) if modern_server?(srv)

          MCPClient::Task.from_json(result, server: srv, session_epoch: epoch)
        rescue MCPClient::Errors::ServerError => e
          raise if e.protocol_error?
          # A terminal task cannot be cancelled (-32602); that is an error, not a
          # missing task, so keep it as a TaskError.
          if e.message.match?(/terminal/i)
            raise MCPClient::Errors::TaskError, "Error cancelling task '#{sanitize_peer_log_text(task_id.to_s)}': " \
                                                "#{sanitize_peer_log_text(e.message)}"
          end

          raise task_failure(e, srv, task_id, 'cancelling', epoch: epoch,
                                                            method: 'tasks/cancel', modern: modern_server?(srv))
        rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
          raise MCPClient::Errors::TaskError, "Error cancelling task '#{sanitize_peer_log_text(task_id.to_s)}': " \
                                              "#{sanitize_peer_log_text(e.message)}"
        end
      end

      private

      # Enforce the tasks.<operation> capability gate for a server (MCP
      # lifecycle: "Only use capabilities that were successfully negotiated").
      # When the negotiated capability set is not yet known, first trigger the
      # handshake with a cheap standard request (ping) and then re-apply the
      # gate against the freshly negotiated set, so a previously uninitialized
      # server that negotiates no tasks capability never receives the
      # prohibited request.
      # @param srv [MCPClient::ServerBase] the selected server
      # @param operation [String] the tasks sub-capability ('list' or 'cancel')
      # @return [void]
      # @raise [MCPClient::Errors::CapabilityError] if the negotiated set lacks the capability
      # Make the server's protocol era known (a cheap request triggers the
      # handshake or the server/discover probe); failures are left to the
      # request that follows.
      # @param srv [MCPClient::ServerBase]
      # @return [void]
      def probe_server_era(srv)
        return if capabilities_known?(srv) || !srv.respond_to?(:ping)

        # A method that no longer exists on 2026-07-28 servers must not go out
        # on a guess: an initialization failure surfaces.
        srv.ping
      end

      # @param strict [Boolean] surface an initialization failure instead of
      #   leaving it to the request (for operations that never send one on a
      #   server whose era is unknown)
      def ensure_task_capability!(srv, operation, strict: false)
        if !capabilities_known?(srv) && srv.respond_to?(:ping)
          begin
            srv.ping
          rescue MCPClient::Errors::MCPError
            # Initialization failed; fall through and let the task request
            # itself surface the failure via the normal error path.
            raise if strict
          end
        end

        # MCP 2026-07-28: tasks are the io.modelcontextprotocol/tasks extension.
        return ensure_tasks_extension!(srv) if modern_server?(srv)
        # Legacy tasks/get and tasks/result need only the tasks capability the
        # request itself is gated on server-side.
        return unless %w[list cancel].include?(operation)
        return if !capabilities_known?(srv) || srv.capability?('tasks', operation)

        raise MCPClient::Errors::CapabilityError,
              "Server #{srv.name || srv.class.name} did not declare the tasks.#{operation} capability"
      end

      # Resolve which server a task operation targets.
      #
      # Task IDs are only unique within the server that issued them, so silently
      # defaulting to the first configured server can poll, read or cancel an
      # unrelated task on the wrong server. Resolution order:
      #   1. an explicit server: argument wins;
      #   2. a Task handle carries the server that issued it;
      #   3. a bare ID with exactly one configured server is unambiguous;
      #   4. anything else is ambiguous and fails closed.
      # @param task [String, MCPClient::Task] the task or its ID
      # @param server_arg [Integer, String, Symbol, MCPClient::ServerBase, nil] explicit selector
      # @param operation [String] calling method name, for the error message
      # @return [MCPClient::ServerBase]
      # @raise [ArgumentError] when the target server cannot be determined
      def select_task_server(task, server_arg, operation)
        # nil, not falsiness: `server: false` is an invalid selector that
        # select_server rejects with ArgumentError, and treating it as "omitted"
        # would silently route a read or a cancel somewhere instead of failing.
        return select_server(server_arg) unless server_arg.nil?
        return task.server if task.is_a?(MCPClient::Task) && task.server
        return select_server(nil) if @servers.size <= 1

        raise ArgumentError,
              "#{operation} is ambiguous with multiple servers configured: task IDs are only unique per server. " \
              'Pass the Task returned by call_tool_as_task, or name the server explicitly ' \
              "(e.g. #{operation}(id, server: 'name'))."
      end

      # @param task [String, MCPClient::Task] a task or its ID
      # @return [String] the task ID
      def task_identifier(task)
        return task unless task.is_a?(MCPClient::Task)

        unless task.remote?
          raise MCPClient::Errors::TaskError,
                'The task was completed locally (the server answered synchronously); there is nothing to fetch, ' \
                'update or cancel'
        end
        task.task_id
      end

      # Reject a plain (synchronous) call for a tool whose execution.taskSupport is
      # 'required'. A compliant server would reject a non-task-augmented tools/call
      # for such a tool, so fail fast and point the caller at call_tool_as_task.
      # @param tool [MCPClient::Tool] the resolved tool
      # @param tool_name [String] the tool name (for the message)
      # @raise [MCPClient::Errors::ToolCallError] if the tool requires task execution
      def reject_task_required!(tool, tool_name)
        # Tasks Tool-Level Negotiation rule 1: without tasks.requests.tools.call
        # in the server capabilities, taskSupport is disregarded entirely and
        # the tool is invoked as a plain call.
        return unless tool.task_required?
        # MCP 2026-07-28: the server alone decides whether a call becomes a
        # task, and Client#call_tool drives that task to its result.
        return if modern_server?(tool.server)
        return unless server_supports_task_tool_call?(tool.server)

        raise MCPClient::Errors::ToolCallError,
              "Tool '#{tool_name}' requires task-augmented execution; call it with call_tool_as_task instead"
      end

      # Whether a server advertised support for task-augmented tools/call, i.e.
      # capabilities.tasks.requests.tools.call.
      # @param srv [MCPClient::ServerBase] the server
      # @return [Boolean]
      def server_supports_task_tool_call?(srv)
        return srv.capability?('extensions', MCPClient::JsonRpcCommon::TASKS_EXTENSION) if modern_server?(srv)

        caps = srv.respond_to?(:capabilities) ? srv.capabilities : nil
        return false unless caps.is_a?(Hash)

        tasks = caps['tasks'] || caps[:tasks]
        requests = tasks && (tasks['requests'] || tasks[:requests])
        tools = requests && (requests['tools'] || requests[:tools])
        call = tools && (tools['call'] || tools[:call])
        !call.nil?
      end

      # Map a ServerError from a task operation to TaskNotFound or TaskError.
      # @param error [MCPClient::Errors::ServerError] the server error
      # @param task_id [String] the task id
      # @param action [String] a verb phrase for the error message (e.g. 'getting')
      # @return [MCPClient::Errors::TaskNotFound, MCPClient::Errors::TaskError]
      # @param modern [Boolean] MCP 2026-07-28: an invalid/nonexistent taskId is -32602
      # @param method [String, nil] the request that failed: on 2026-07-28 servers -32602 always means an
      #   unknown task for tasks/get, while tasks/update and tasks/cancel may use it for bad params too
      def task_error_from(error, task_id, action, modern: false, method: nil)
        shown = sanitize_peer_log_text(task_id.to_s)
        if task_not_found_error?(error, method, modern)
          return MCPClient::Errors::TaskNotFound.new("Task '#{shown}' not found")
        end

        MCPClient::Errors::TaskError.new("Error #{action} task '#{shown}': #{sanitize_peer_log_text(error.message)}")
      end

      # The error for a failed task request; a task the server reports gone
      # takes its bookkeeping with it (answered keys, pending answers,
      # rounds — in-flight holds excepted), like the tasks/get path, so a
      # later task reusing the id is not treated as already answered.
      # @param state [Hash, nil] the bookkeeping the failed request was working on; only that
      #   state is dropped, so a late failure cannot touch a reused task id's (see #forget_task_keys)
      # @param epoch [Integer, nil] the session the failed request was pinned to; without a captured
      #   state it is that session's bookkeeping that dies with the task, never the bookkeeping a
      #   session which replaced it under the request has recorded under the same, reusable id
      # @return [MCPClient::Errors::TaskError]
      def task_failure(error, srv, task_id, action, modern: true, method: nil, state: nil, epoch: nil)
        mapped = task_error_from(error, task_id, action, modern: modern, method: method)
        forget_task_keys(srv, task_id, state: state, epoch: epoch) if mapped.is_a?(MCPClient::Errors::TaskNotFound)
        mapped
      end

      # Handle a notifications/tasks/status notification (MCP 2025-11-25).
      # The params are a flat Task.
      # @param server_id [String] server identifier for the log prefix
      # @param params [Hash] the flat task params
      # @return [void]
      def handle_task_status_notification(server_id, params, method = 'notifications/tasks')
        # A 2026-07-28 notifications/tasks carries a DetailedTask: anything
        # short of that is a parse failure, not a working task. The legacy
        # notifications/tasks/status carries the flat 2025 Task (ttl,
        # pollInterval, no inline payloads).
        if method == 'notifications/tasks/status'
          problem = params.is_a?(Hash) && params['taskId'].is_a?(String) ? nil : 'not a task'
          detailed = false
        else
          problem = params.is_a?(Hash) ? detailed_task_shape_problem(params) : 'not an object'
          detailed = true
        end
        raise MCPClient::Errors::InvalidResultError, "Invalid task notification: #{problem}" if problem

        task = MCPClient::Task.from_json(params, detailed: detailed)
        logger.info("[#{server_id}] Task #{sanitize_peer_log_text(task.task_id.to_s)} status: #{task.status}")
      rescue StandardError => e
        logger.debug("[#{server_id}] Failed to parse task status notification: #{e.message}")
      end
    end
  end
end
