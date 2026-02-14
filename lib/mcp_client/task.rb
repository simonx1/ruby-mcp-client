# frozen_string_literal: true

module MCPClient
  # Represents an MCP Task for long-running operations with progress tracking
  # Tasks follow the MCP 2025-11-25 specification for structured task management
  #
  # Task states: pending, running, completed, failed, cancelled
  class Task
    # Valid task states
    VALID_STATES = %w[pending running completed failed cancelled].freeze

    attr_reader :id, :state, :progress_token, :progress, :total, :message, :result, :server

    # Create a new Task
    # @param id [String] unique task identifier
    # @param state [String] task state (pending, running, completed, failed, cancelled)
    # @param progress_token [String, nil] optional token for tracking progress
    # @param progress [Integer, nil] current progress value
    # @param total [Integer, nil] total progress value
    # @param message [String, nil] human-readable status message
    # @param result [Object, nil] task result (when completed)
    # @param server [MCPClient::ServerBase, nil] the server this task belongs to
    def initialize(id:, state: 'pending', progress_token: nil, progress: nil, total: nil,
                   message: nil, result: nil, server: nil)
      validate_state!(state)
      @id = id
      @state = state
      @progress_token = progress_token
      @progress = progress
      @total = total
      @message = message
      @result = result
      @server = server
    end

    # Create a Task from a JSON hash
    # @param json [Hash] the JSON hash with task fields
    # @param server [MCPClient::ServerBase, nil] optional server reference
    # @return [Task]
    def self.from_json(json, server: nil)
      new(
        id: json['id'] || json[:id],
        state: json['state'] || json[:state] || 'pending',
        progress_token: json['progressToken'] || json[:progressToken] || json[:progress_token],
        progress: json['progress'] || json[:progress],
        total: json['total'] || json[:total],
        message: json['message'] || json[:message],
        result: json['result'] || json[:result],
        server: server
      )
    end

    # Convert to JSON-serializable hash
    # @return [Hash]
    def to_h
      result = { 'id' => @id, 'state' => @state }
      result['progressToken'] = @progress_token if @progress_token
      result['progress'] = @progress if @progress
      result['total'] = @total if @total
      result['message'] = @message if @message
      result['result'] = @result if @result
      result
    end

    # Convert to JSON string
    # @return [String]
    def to_json(*)
      to_h.to_json(*)
    end

    # Check if task is in a terminal state
    # @return [Boolean]
    def terminal?
      %w[completed failed cancelled].include?(@state)
    end

    # Check if task is still active (pending or running)
    # @return [Boolean]
    def active?
      %w[pending running].include?(@state)
    end

    # Calculate progress percentage
    # @return [Float, nil] percentage (0.0-100.0) or nil if progress info unavailable
    def progress_percentage
      return nil unless @progress && @total&.positive?

      (@progress.to_f / @total * 100).round(2)
    end

    # Check equality
    def ==(other)
      return false unless other.is_a?(Task)

      id == other.id && state == other.state
    end

    alias eql? ==

    def hash
      [id, state].hash
    end

    # String representation
    def to_s
      parts = ["Task[#{@id}]: #{@state}"]
      parts << "(#{@progress}/#{@total})" if @progress && @total
      parts << "- #{@message}" if @message
      parts.join(' ')
    end

    def inspect
      "#<MCPClient::Task id=#{@id.inspect} state=#{@state.inspect}>"
    end

    private

    # Validate task state
    # @param state [String] the state to validate
    # @raise [ArgumentError] if the state is not valid
    def validate_state!(state)
      return if VALID_STATES.include?(state)

      raise ArgumentError, "Invalid task state: #{state.inspect}. Must be one of: #{VALID_STATES.join(', ')}"
    end
  end
end
