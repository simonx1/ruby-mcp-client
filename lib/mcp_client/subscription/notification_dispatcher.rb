# frozen_string_literal: true

module MCPClient
  class Subscription
    # One subscription's notification dispatcher: the queue the transport
    # reader fills, the thread the listeners run on, and the policy that keeps
    # the queue bounded.
    #
    # Listeners never run on the transport's reader. On stdio that is the
    # single stdout reader, so a listener reacting to an update with a request
    # of its own (re-reading the resource that changed, say) would otherwise
    # wait for a response only the thread it is blocking could deliver — and
    # every other message would wait with it. Enqueuing therefore never blocks
    # and never waits for a listener.
    #
    # The queue is filled by the peer and drained by the host, so it needs a
    # ceiling ({MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS}), and
    # overflow has to discard something. What it discards is chosen by
    # identity — the notification's method together with the resource URI or
    # task id it names — never by arrival order alone: one stream can carry a
    # mixed filter, and dropping the oldest entry would throw away the only
    # queued update for a quiet resource to keep newer ones for a busy one,
    # with nothing left to tell the listener to re-read the quiet one. Since
    # every MCP notification is a "look again" signal about state the host
    # re-reads for itself, a second notice of the same thing is redundant and
    # the first notice of a thing is not. So overflow drops, in order of
    # preference:
    #
    # 1. the oldest queued notification of the same identity as the arriving
    #    one — the listener still gets the newest word on it;
    # 2. otherwise the oldest notification of whichever identity has the most
    #    queued, so nothing loses its only notice while something else has a
    #    spare;
    # 3. only when every queued notification names a different thing, the
    #    oldest — the queue is then full of distinct signals and one must go.
    class NotificationDispatcher
      # @param owner [MCPClient::Subscription] the subscription it serves
      def initialize(owner)
        @owner = owner
        @mutex = Mutex.new
        @ready = ConditionVariable.new
        @buffer = []
        @dropped = 0
        @warned_about_drops = false
        @stopped = false
        start_thread
      end

      # @return [Integer] notifications waiting for the listeners
      def pending
        @mutex.synchronize { @buffer.size }
      end

      # @return [Integer] notifications discarded because the listeners could
      #   not keep up with the peer
      def dropped
        @mutex.synchronize { @dropped }
      end

      # Queue one notification for the listeners, making room for it first.
      # @param listeners [Array<Proc>] the listeners to run
      # @param method [String] notification method
      # @param params [Hash, nil] notification params
      # @return [void]
      def deliver(listeners, method, params)
        @mutex.synchronize do
          return if @stopped

          key = identity(method, params)
          make_room(key)
          @buffer << [key, listeners, method, params]
          @ready.signal
        end
      end

      # End the dispatcher after everything already queued has been delivered.
      # @return [void]
      def stop
        @mutex.synchronize do
          @stopped = true
          @ready.broadcast
        end
      end

      private

      # What a notification is *about*: two notifications with the same
      # identity say the same thing about the same resource or task, so the
      # newer one carries everything the older one did.
      # @param method [String] notification method
      # @param params [Hash, nil] notification params
      # @return [Array(String, String, nil)]
      def identity(method, params)
        named = params.is_a?(Hash) ? (params['uri'] || params['taskId']) : nil
        [method, named]
      end

      # @return [Integer] the ceiling, read at each delivery so a host can
      #   change it for a transport it knows is chatty
      def capacity
        MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS
      end

      # Make room for one more notification of `key`. Called with the lock held.
      # @param key [Array] the arriving notification's identity
      # @return [void]
      def make_room(key)
        dropped = 0
        while @buffer.size >= capacity && (index = droppable_index(key))
          @buffer.delete_at(index)
          dropped += 1
        end
        return if dropped.zero?

        @dropped += dropped
        report_dropped(dropped)
      end

      # The entry overflow should discard (see the class comment). Called with
      # the lock held.
      # @param key [Array] the arriving notification's identity
      # @return [Integer, nil] its position, nil when the queue is empty
      def droppable_index(key)
        return nil if @buffer.empty?

        same = @buffer.index { |entry| entry[0] == key }
        return same if same

        redundant = most_queued_identity
        redundant ? @buffer.index { |entry| entry[0] == redundant } : 0
      end

      # @return [Array, nil] the identity with more than one queued
      #   notification, nil when every queued notification names its own thing
      def most_queued_identity
        counts = @buffer.each_with_object(Hash.new(0)) { |entry, tally| tally[entry[0]] += 1 }
        identity, count = counts.max_by { |_key, queued| queued }
        count > 1 ? identity : nil
      end

      # @param dropped [Integer] how many were discarded just now
      # @return [void]
      def report_dropped(dropped)
        logger = @owner.server.respond_to?(:logger) ? @owner.server.logger : nil
        return unless logger

        # The peer controls how often this happens, so it is said once per
        # subscription at warn level and counted after that.
        if @warned_about_drops
          logger.debug("Subscription #{@owner.id} dropped #{dropped} more queued notification(s)")
        else
          @warned_about_drops = true
          logger.warn("Subscription #{@owner.id} is receiving notifications faster than its listeners handle " \
                      "them; dropping repeats of what is already queued (at most #{capacity}, see " \
                      'MCPClient::Subscription#dropped_notifications)')
        end
      end

      # @return [Thread] the thread that runs the listeners
      def start_thread
        Thread.new do
          Thread.current.name = 'MCP-subscription'
          Thread.current.report_on_exception = false
          while (entry = next_entry)
            call_listeners(entry[1], entry[2], entry[3])
          end
        end
      end

      # @return [Array, nil] the next notification to deliver, nil once the
      #   subscription has ended and everything queued has been delivered
      def next_entry
        @mutex.synchronize do
          @ready.wait(@mutex) while @buffer.empty? && !@stopped
          @buffer.shift
        end
      end

      # @param listeners [Array<Proc>] listeners to run
      # @param method [String] notification method
      # @param params [Hash, nil] notification params
      # @return [void]
      def call_listeners(listeners, method, params)
        listeners.each do |listener|
          listener.call(method, params)
        rescue StandardError => e
          @owner.server.logger.warn("Subscription listener error: #{e.message}") if @owner.server.respond_to?(:logger)
        end
      end
    end
  end
end
