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

    # The states {#wait_until_settled} waits for: the server has answered the
    # listen request one way or the other.
    SETTLED_STATES = %i[active closed].freeze

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
      @settled = ConditionVariable.new
      @id = nil
      @acknowledged = nil
      @error = nil
      @close_reason = nil
      @closed_gracefully = false
      @closed_by_client = false
      @dispatch_queue = nil
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

    # Requested notification types the server did not agree to honour
    # (a resource subscription counts as unsupported when none of its URIs
    # was acknowledged; see {#unacknowledged_resource_uris} for a partial
    # acknowledgment).
    # @return [Array<String>] empty until acknowledged
    def unsupported
      ack = @mutex.synchronize { @acknowledged }
      return [] unless ack

      @requested.keys - ack.keys
    end

    # Requested resource URIs the server did not agree to watch.
    # @return [Array<String>] empty until acknowledged
    def unacknowledged_resource_uris
      ack = @mutex.synchronize { @acknowledged }
      return [] unless ack

      wanted = Array(@requested['resourceSubscriptions'])
      granted = ack['resourceSubscriptions'].is_a?(Array) ? ack['resourceSubscriptions'] : []
      wanted - granted
    end

    # Block until the server has settled the subscription: acknowledged it,
    # or ended it with a response, an error or a cancellation.
    # @param timeout [Numeric] seconds to wait
    # @return [Symbol, nil] :active or :closed, nil while it is still pending
    def wait_until_settled(timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @mutex.synchronize do
        until SETTLED_STATES.include?(@state)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          @settled.wait(@mutex, remaining)
        end
        SETTLED_STATES.include?(@state) ? @state : nil
      end
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
        @acknowledged = nil
        # A subscription the host closed stays closed, whatever a racing
        # reconnect does.
        @state = :pending unless @state == :closed
      end
    end

    # Take a fresh listen id and register/send the request under this
    # subscription's own lock, so a concurrent {#close} either wins outright
    # (nothing is sent) or waits and then cancels the id that was sent. A
    # closed subscription is never re-opened.
    # @param id [Integer, String] the new listen request id
    # @yield runs while the id cannot change underneath it
    # @return [Boolean] false when the host had already closed it
    # @api private
    def with_open_id(id)
      @mutex.synchronize do
        return false if @state == :closed

        @id = id
        @acknowledged = nil
        @state = :pending
        yield
        true
      end
    end

    # @api private
    def acknowledge(filter)
      @mutex.synchronize do
        return if @state == :closed

        @acknowledged = filter.is_a?(Hash) ? filter : {}
        @state = :active
        @settled.broadcast
      end
    end

    # @api private
    def deliver(method, params)
      @mutex.synchronize do
        return if @state == :closed || @listeners.empty?

        # Queued while still open, so a closure that follows cannot swallow a
        # notification that had already arrived, and the :stop that ends the
        # dispatcher can never overtake this one.
        (@dispatch_queue ||= start_dispatcher) << [@listeners.dup, method, params]
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
        @settled.broadcast
        # Deliveries already queued still run; the dispatcher ends after them.
        @dispatch_queue&.push(:stop)
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

    private

    # Start this subscription's dispatcher: one thread per subscription, so
    # listeners see notifications in the order they arrived and never run on
    # the thread that reads the transport. On stdio that is the single stdout
    # reader, so a listener reacting to an update with a request of its own
    # (re-reading the resource, say) would otherwise wait for a response that
    # only the thread it is blocking could deliver — and every other message
    # would wait with it.
    # @return [Thread::Queue] the queue it consumes
    def start_dispatcher
      queue = Thread::Queue.new
      Thread.new do
        Thread.current.name = 'MCP-subscription'
        Thread.current.report_on_exception = false
        loop do
          item = queue.pop
          break if item.nil? || item == :stop

          call_listeners(*item)
        end
      end
      queue
    end

    # @param listeners [Array<Proc>] listeners to run
    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def call_listeners(listeners, method, params)
      listeners.each do |listener|
        listener.call(method, params)
      rescue StandardError => e
        @server.logger.warn("Subscription listener error: #{e.message}") if @server.respond_to?(:logger)
      end
    end
  end
end
