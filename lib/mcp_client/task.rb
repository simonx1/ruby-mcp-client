# frozen_string_literal: true

require 'time'

module MCPClient
  # Represents an MCP Task for long-running, task-augmented operations.
  # Conforms to the MCP 2025-11-25 Tasks utility and to the MCP 2026-07-28
  # tasks extension (io.modelcontextprotocol/tasks), whose flat Task uses
  # `ttlMs` / `pollIntervalMs` and whose DetailedTask (tasks/get,
  # notifications/tasks) inlines `inputRequests`, `result` or `error`.
  #
  # Task statuses: working, input_required, completed, failed, cancelled.
  # A task begins in `working`; completed/failed/cancelled are terminal.
  class Task
    # Valid task statuses (MCP 2025-11-25)
    VALID_STATUSES = %w[working input_required completed failed cancelled].freeze

    # Statuses from which a task will not transition further
    TERMINAL_STATUSES = %w[completed failed cancelled].freeze

    attr_reader :task_id, :status, :status_message, :created_at, :last_updated_at, :ttl, :poll_interval, :server,
                :input_requests, :result, :error

    # 2026-07-28 names of the retention and polling hints (milliseconds).
    alias ttl_ms ttl
    alias poll_interval_ms poll_interval

    # Create a new Task
    # @param task_id [String] unique task identifier
    # @param status [String] task status (working, input_required, completed, failed, cancelled)
    # @param status_message [String, nil] optional human-readable status detail
    # @param created_at [String, nil] ISO 8601 creation timestamp
    # @param last_updated_at [String, nil] ISO 8601 last-update timestamp
    # @param ttl [Integer, nil] retention duration in milliseconds since creation (nil = unspecified)
    # @param poll_interval [Integer, nil] suggested polling interval in milliseconds
    # @param server [MCPClient::ServerBase, nil] the server this task belongs to
    # @param input_requests [Hash, nil] outstanding inputRequests (2026-07-28 DetailedTask, input_required)
    # @param result [Hash, nil] the final result (2026-07-28 DetailedTask, completed)
    # @param error [Hash, nil] the JSON-RPC error (2026-07-28 DetailedTask, failed)
    # @param modern [Boolean] whether the task uses the 2026-07-28 field names (ttlMs, pollIntervalMs)
    # @param detailed [Boolean] whether this is a DetailedTask (tasks/get, notifications/tasks) whose
    #   result / error / inputRequests are authoritative, as opposed to a creation seed
    def initialize(task_id:, status: 'working', status_message: nil, created_at: nil,
                   last_updated_at: nil, ttl: nil, poll_interval: nil, server: nil,
                   input_requests: nil, result: nil, error: nil, modern: false, detailed: false)
      validate_status!(status)
      @task_id = task_id
      @status = status
      @status_message = status_message
      @created_at = created_at
      @last_updated_at = last_updated_at
      @ttl = ttl
      @poll_interval = poll_interval
      @server = server
      @input_requests = input_requests
      @result = result
      @error = error
      @modern = modern
      @detailed = detailed
    end

    # Build a Task from a flat Task hash. This is the shape of GetTaskResult,
    # CancelTaskResult, the items in a ListTasksResult, and the params of a
    # notifications/tasks/status notification.
    # @param json [Hash] the flat task hash
    # @param server [MCPClient::ServerBase, nil] optional server reference
    # @param detailed [Boolean] whether the hash is a DetailedTask (see #detailed?)
    # @return [Task]
    # @raise [MCPClient::Errors::InvalidResultError] when the peer data is not
    #   an object or names a status that is not a task status
    def self.from_json(json, server: nil, detailed: false)
      raise MCPClient::Errors::InvalidResultError, 'Invalid task: not an object' unless json.is_a?(Hash)

      data = json

      modern = modern_shape?(data)
      new(
        task_id: extract_field(data, 'taskId', :task_id),
        status: extract_field(data, 'status') || 'working',
        status_message: extract_field(data, 'statusMessage', :status_message),
        created_at: extract_field(data, 'createdAt', :created_at),
        last_updated_at: extract_field(data, 'lastUpdatedAt', :last_updated_at),
        ttl: modern ? extract_field(data, 'ttlMs', :ttl_ms) : extract_field(data, 'ttl'),
        poll_interval: if modern
                         extract_field(data, 'pollIntervalMs', :poll_interval_ms)
                       else
                         extract_field(data, 'pollInterval', :poll_interval)
                       end,
        input_requests: extract_field(data, 'inputRequests', :input_requests),
        result: extract_field(data, 'result'),
        error: extract_field(data, 'error'),
        modern: modern,
        detailed: detailed,
        server: server
      )
    rescue ArgumentError => e
      raise MCPClient::Errors::InvalidResultError, "Invalid task: #{e.message}"
    end

    # A task that never left the client: the server answered the request
    # synchronously, so there is nothing to poll. It has no task id.
    # @param result [Object] the request's result
    # @param server [MCPClient::ServerBase, nil]
    # @return [Task] a completed task carrying the result
    def self.completed_locally(result, server: nil)
      new(task_id: nil, status: 'completed', result: result, server: server, modern: true, detailed: true)
    end

    # Whether a task hash uses the 2026-07-28 field names.
    # @param data [Hash]
    # @return [Boolean]
    def self.modern_shape?(data)
      %w[ttlMs pollIntervalMs].any? { |k| data.key?(k) } ||
        %i[ttlMs pollIntervalMs ttl_ms poll_interval_ms].any? { |k| data.key?(k) } ||
        extract_field(data, 'resultType') == 'task'
    end
    private_class_method :modern_shape?

    # Build a Task from a CreateTaskResult, which wraps the task under `task`.
    # @param result [Hash] the CreateTaskResult ({ 'task' => { ... } })
    # @param server [MCPClient::ServerBase, nil] optional server reference
    # @return [Task]
    def self.from_create_result(result, server: nil)
      task_data = (result && (result['task'] || result[:task])) || result
      from_json(task_data, server: server)
    end

    # Read a value by camelCase string key, falling back to a snake_case symbol.
    # Uses key? so an explicit null value is preserved (not treated as absent).
    # @return [Object, nil]
    def self.extract_field(data, str_key, sym_key = nil)
      return data[str_key] if data.key?(str_key)
      return data[str_key.to_sym] if data.key?(str_key.to_sym)
      return data[sym_key] if sym_key && data.key?(sym_key)

      nil
    end
    private_class_method :extract_field

    # Convert to a spec-shaped, JSON-serializable hash
    # @return [Hash]
    def to_h
      # ttl / ttlMs is a REQUIRED Task field whose value may be null, so it is
      # always included (even when nil). The other optional fields are omitted
      # when nil.
      hash = { 'taskId' => @task_id, 'status' => @status, (@modern ? 'ttlMs' : 'ttl') => @ttl }
      hash['statusMessage'] = @status_message if @status_message
      hash['createdAt'] = @created_at if @created_at
      hash['lastUpdatedAt'] = @last_updated_at if @last_updated_at
      hash[@modern ? 'pollIntervalMs' : 'pollInterval'] = @poll_interval if @poll_interval
      hash['inputRequests'] = @input_requests if @input_requests
      hash['result'] = @result unless @result.nil?
      hash['error'] = @error if @error
      hash
    end

    # Whether the task uses the 2026-07-28 shape (ttlMs / pollIntervalMs).
    # @return [Boolean]
    def modern?
      @modern
    end

    # Whether the task came from tasks/get or notifications/tasks (a
    # DetailedTask, whose result, error and inputRequests are authoritative)
    # rather than from the CreateTaskResult seed, which carries none of them.
    # @return [Boolean]
    def detailed?
      @detailed
    end

    # Whether the terminal payload the status implies is present and well
    # formed: a result object (a CallToolResult) for completed, an error
    # object for failed (cancelled needs none).
    # @return [Boolean]
    def payload_present?
      case @status
      when 'completed' then self.class.complete_result_object?(@result)
      when 'failed' then jsonrpc_error_object?(@error)
      else terminal?
      end
    end

    # Whether a failed task's error is a JSON-RPC error object ("The
    # request failed due to a JSON-RPC error": an integer code and a
    # string message, as the JSON-RPC error shape requires).
    # @param error [Object]
    # @return [Boolean]
    def jsonrpc_error_object?(error)
      self.class.jsonrpc_error_object?(error)
    end

    # A completed task's result is the final result of the original request
    # (a CallToolResult): an object that is a complete result, so a
    # resultType it carries must be "complete" (or absent).
    # @param result [Object]
    # @return [Boolean]
    def self.complete_result_object?(result)
      return false unless result.is_a?(Hash)

      # Only an absent discriminator gets the compatibility default; a
      # present null is an unrecognized result type.
      key = ['resultType', :resultType].find { |k| result.key?(k) }
      key.nil? || result[key] == 'complete'
    end

    # @param error [Object]
    # @return [Boolean] whether it is a JSON-RPC error object (integer code, string message)
    def self.jsonrpc_error_object?(error)
      return false unless error.is_a?(Hash)

      code = error['code'] || error[:code]
      message = error['message'] || error[:message]
      code.is_a?(Integer) && message.is_a?(String)
    end

    # Seconds left before the TTL backstop (createdAt + ttlMs), nil when
    # unknown or unlimited.
    # @param now [Time]
    # @return [Float, nil]
    def ttl_remaining(now: Time.now)
      return nil unless @ttl.is_a?(Numeric) && @created_at.is_a?(String)

      (Time.iso8601(@created_at) + (@ttl / 1000.0)) - now
    rescue ArgumentError
      nil
    end

    # Whether this task exists on the server (has an id) as opposed to a
    # request the server answered synchronously (see .completed_locally).
    # @return [Boolean]
    def remote?
      !@task_id.nil?
    end

    # MCP 2026-07-28 TTL backstop: "if the task's observable status has not
    # reflected the update after createdAt plus ttlMs has elapsed, the client
    # MAY consider the task to no longer be usable".
    # @param now [Time] the current time
    # @return [Boolean] whether createdAt + ttl has passed (false when unknown or unlimited)
    def ttl_elapsed?(now: Time.now)
      return false unless @ttl.is_a?(Numeric) && @created_at.is_a?(String)

      created = Time.iso8601(@created_at)
      now > created + (@ttl / 1000.0)
    rescue ArgumentError
      false
    end

    # Convert to JSON string
    # @return [String]
    def to_json(*)
      to_h.to_json(*)
    end

    # Whether the task is in a terminal status (completed, failed, cancelled)
    # @return [Boolean]
    def terminal?
      TERMINAL_STATUSES.include?(@status)
    end

    # Whether the task is still active (not terminal — working or input_required)
    # @return [Boolean]
    def active?
      !terminal?
    end

    # Whether the task is waiting for input (status input_required)
    # @return [Boolean]
    def input_required?
      @status == 'input_required'
    end

    # Whether the task is still running (status working)
    # @return [Boolean]
    def working?
      @status == 'working'
    end

    # @return [Boolean] whether the task completed (its result is available)
    def completed?
      @status == 'completed'
    end

    # @return [Boolean] whether the task failed with a JSON-RPC error
    def failed?
      @status == 'failed'
    end

    # @return [Boolean] whether the task was cancelled
    def cancelled?
      @status == 'cancelled'
    end

    # Check equality
    def ==(other)
      return false unless other.is_a?(Task)
      # A locally completed task has no server-side identity: only itself.
      return equal?(other) if task_id.nil?

      task_id == other.task_id && status == other.status
    end

    alias eql? ==

    def hash
      return object_id.hash if task_id.nil?

      [task_id, status].hash
    end

    # String representation
    def to_s
      parts = ["Task[#{@task_id}]: #{@status}"]
      parts << "- #{@status_message}" if @status_message
      parts.join(' ')
    end

    def inspect
      "#<MCPClient::Task task_id=#{@task_id.inspect} status=#{@status.inspect}>"
    end

    private

    # Validate task status
    # @param status [String] the status to validate
    # @raise [ArgumentError] if the status is not valid
    def validate_status!(status)
      return if VALID_STATUSES.include?(status)

      raise ArgumentError, "Invalid task status: #{status.inspect}. Must be one of: #{VALID_STATUSES.join(', ')}"
    end
  end
end
