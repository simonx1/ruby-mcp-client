# frozen_string_literal: true

module MCPClient
  # Represents an MCP Task for long-running, task-augmented operations.
  # Conforms to the MCP 2025-11-25 Tasks utility.
  #
  # Task statuses: working, input_required, completed, failed, cancelled.
  # A task begins in `working`; completed/failed/cancelled are terminal.
  class Task
    # Valid task statuses (MCP 2025-11-25)
    VALID_STATUSES = %w[working input_required completed failed cancelled].freeze

    # Statuses from which a task will not transition further
    TERMINAL_STATUSES = %w[completed failed cancelled].freeze

    attr_reader :task_id, :status, :status_message, :created_at, :last_updated_at, :ttl, :poll_interval, :server

    # Create a new Task
    # @param task_id [String] unique task identifier
    # @param status [String] task status (working, input_required, completed, failed, cancelled)
    # @param status_message [String, nil] optional human-readable status detail
    # @param created_at [String, nil] ISO 8601 creation timestamp
    # @param last_updated_at [String, nil] ISO 8601 last-update timestamp
    # @param ttl [Integer, nil] retention duration in milliseconds since creation (nil = unspecified)
    # @param poll_interval [Integer, nil] suggested polling interval in milliseconds
    # @param server [MCPClient::ServerBase, nil] the server this task belongs to
    def initialize(task_id:, status: 'working', status_message: nil, created_at: nil,
                   last_updated_at: nil, ttl: nil, poll_interval: nil, server: nil)
      validate_status!(status)
      @task_id = task_id
      @status = status
      @status_message = status_message
      @created_at = created_at
      @last_updated_at = last_updated_at
      @ttl = ttl
      @poll_interval = poll_interval
      @server = server
    end

    # Build a Task from a flat Task hash. This is the shape of GetTaskResult,
    # CancelTaskResult, the items in a ListTasksResult, and the params of a
    # notifications/tasks/status notification.
    # @param json [Hash] the flat task hash
    # @param server [MCPClient::ServerBase, nil] optional server reference
    # @return [Task]
    def self.from_json(json, server: nil)
      data = json || {}
      new(
        task_id: extract_field(data, 'taskId', :task_id),
        status: extract_field(data, 'status') || 'working',
        status_message: extract_field(data, 'statusMessage', :status_message),
        created_at: extract_field(data, 'createdAt', :created_at),
        last_updated_at: extract_field(data, 'lastUpdatedAt', :last_updated_at),
        ttl: extract_field(data, 'ttl'),
        poll_interval: extract_field(data, 'pollInterval', :poll_interval),
        server: server
      )
    end

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
      # ttl is a REQUIRED Task field whose value may be null, so it is always
      # included (even when nil). The other optional fields are omitted when nil.
      hash = { 'taskId' => @task_id, 'status' => @status, 'ttl' => @ttl }
      hash['statusMessage'] = @status_message if @status_message
      hash['createdAt'] = @created_at if @created_at
      hash['lastUpdatedAt'] = @last_updated_at if @last_updated_at
      hash['pollInterval'] = @poll_interval if @poll_interval
      hash
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

    # Check equality
    def ==(other)
      return false unless other.is_a?(Task)

      task_id == other.task_id && status == other.status
    end

    alias eql? ==

    def hash
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
