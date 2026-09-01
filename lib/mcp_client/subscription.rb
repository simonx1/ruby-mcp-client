# frozen_string_literal: true

module MCPClient
  # A long-lived notification subscription opened with `subscriptions/listen`
  # (MCP 2026-07-28 basic/patterns/subscriptions).
  #
  # The subscription is identified by the JSON-RPC id of its listen request;
  # every notification delivered on it carries that id in
  # `_meta["io.modelcontextprotocol/subscriptionId"]`. It starts :pending,
  # becomes :active when the server acknowledges it (with the subset of
  # notification types it agreed to honour), and ends :closed — gracefully
  # when the server answers the listen request, otherwise on a transport
  # drop, a server `notifications/cancelled`, an error, or {#close}.
  class Subscription
    # SubscriptionFilter fields and their value types (taskIds comes from the
    # tasks extension).
    FILTER_FIELDS = {
      'toolsListChanged' => :boolean,
      'promptsListChanged' => :boolean,
      'resourcesListChanged' => :boolean,
      'resourceSubscriptions' => :string_array,
      'taskIds' => :string_array
    }.freeze

    # snake_case spellings accepted for the filter fields
    FILTER_ALIASES = {
      'tools_list_changed' => 'toolsListChanged',
      'prompts_list_changed' => 'promptsListChanged',
      'resources_list_changed' => 'resourcesListChanged',
      'resource_subscriptions' => 'resourceSubscriptions',
      'task_ids' => 'taskIds'
    }.freeze

    STATES = %i[pending active reconnecting closed].freeze

    # @return [Integer, String, nil] the JSON-RPC id of the listen request (nil before it is sent)
    attr_reader :id
    # @return [Hash] the requested SubscriptionFilter (camelCase keys)
    attr_reader :requested
    # @return [Hash, nil] the filter the server agreed to honour, once acknowledged
    attr_reader :acknowledged
    # @return [MCPClient::ServerBase] the transport that owns the subscription
    attr_reader :server
    # @return [Symbol] :pending, :active, :reconnecting or :closed
    attr_reader :state
    # @return [MCPClient::Errors::MCPError, nil] why the subscription failed, if it did
    attr_reader :error
    # @return [String, nil] the reason a server-side teardown gave, if any
    attr_reader :close_reason

    # Normalize and validate a SubscriptionFilter given with String or Symbol,
    # camelCase or snake_case keys.
    # @param filter [Hash] the notification filter
    # @return [Hash] camelCase String keys
    # @raise [ArgumentError] on an unknown key or a mistyped value
    def self.normalize_filter(filter)
      raise ArgumentError, 'notifications must be a Hash (SubscriptionFilter)' unless filter.is_a?(Hash)

      filter.to_h do |key, value|
        name = key.to_s
        name = FILTER_ALIASES.fetch(name, name)
        type = FILTER_FIELDS[name]
        raise ArgumentError, "Unknown subscription filter field #{key.inspect}" unless type

        case type
        when :boolean
          raise ArgumentError, "#{name} must be true or false" unless [true, false].include?(value)
        when :string_array
          raise ArgumentError, "#{name} must be an array of strings" unless value.is_a?(Array) && value.all?(String)
        end
        [name, value]
      end
    end

    # @param server [MCPClient::ServerBase] owning transport
    # @param requested [Hash] normalized filter
    # @yield [method, params] optional listener for notifications on this subscription
    def initialize(server:, requested:, &listener)
      @server = server
      @requested = requested
      @listeners = []
      @listeners << listener if listener
      @state = :pending
      @mutex = Mutex.new
      @id = nil
      @acknowledged = nil
      @error = nil
      @close_reason = nil
      @closed_gracefully = false
      @closed_by_client = false
    end

    # Add a listener for notifications delivered on this subscription.
    # @yield [method, params]
    # @return [self]
    def on_notification(&block)
      @mutex.synchronize { @listeners << block }
      self
    end

    # @return [Boolean] whether the server acknowledged it and it is still open
    def active?
      @mutex.synchronize { @state == :active }
    end

    # @return [Boolean]
    def closed?
      @mutex.synchronize { @state == :closed }
    end

    # @return [Boolean] whether the server ended it with a response to the listen request
    def closed_gracefully?
      @mutex.synchronize { @closed_gracefully }
    end

    # @return [Boolean] whether {#close} ended it
    def closed_by_client?
      @mutex.synchronize { @closed_by_client }
    end

    # Requested notification types the server did not agree to honour.
    # @return [Array<String>] empty until acknowledged
    def unsupported
      ack = @mutex.synchronize { @acknowledged }
      return [] unless ack

      @requested.keys - ack.keys
    end

    # Cancel the subscription: the transport closes the stream (HTTP) or
    # sends notifications/cancelled (stdio).
    # @return [MCPClient::Subscription, nil] self if it was open, nil if already closed
    def close
      return nil if closed?

      @server.cancel_subscription(self)
      self
    end

    # --- transport-facing state transitions -------------------------------

    # @api private
    def assign_id(id)
      @mutex.synchronize do
        @id = id
        @state = :pending
        @acknowledged = nil
      end
    end

    # @api private
    def acknowledge(filter)
      @mutex.synchronize do
        return if @state == :closed

        @acknowledged = filter.is_a?(Hash) ? filter : {}
        @state = :active
      end
    end

    # @api private
    def deliver(method, params)
      listeners = @mutex.synchronize do
        return if @state == :closed

        @listeners.dup
      end
      listeners.each do |listener|
        listener.call(method, params)
      rescue StandardError => e
        @server.logger.warn("Subscription listener error: #{e.message}") if @server.respond_to?(:logger)
      end
    end

    # @api private
    def mark_reconnecting
      @mutex.synchronize { @state = :reconnecting unless @state == :closed }
    end

    # @api private
    def finish(gracefully: false, by_client: false, error: nil, reason: nil)
      @mutex.synchronize do
        return if @state == :closed

        @state = :closed
        @closed_gracefully = gracefully
        @closed_by_client = by_client
        @error = error
        @close_reason = reason
      end
    end

    # @return [Boolean] whether the subscription should be re-established after a reconnect
    # @api private
    def reconnectable?
      @mutex.synchronize { @state != :closed && !@closed_by_client }
    end

    def inspect
      "#<MCPClient::Subscription id=#{@id.inspect} state=#{@state} requested=#{@requested.keys.join(',')}>"
    end
  end
end
