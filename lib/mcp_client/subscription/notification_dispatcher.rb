# frozen_string_literal: true

require 'json'

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
    # ceiling, and overflow has to discard something. There are two ceilings,
    # because a queue bounded by count alone is not bounded in memory: the
    # params of every queued notification are retained until its listener has
    # run, and the peer chooses how big they are. Overflow therefore starts at
    # whichever of {MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS} and
    # {MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES} the arriving
    # notification would breach. What it discards is chosen by
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
    #
    # A notification whose payload is larger than the whole byte budget is
    # still queued once the buffer has been emptied for it, and it is not then
    # charged against the budget it exceeds on its own: the peer can hold one
    # such payload behind a stalled listener, never a queueful of them, while
    # a signal is neither lost merely for being large nor evicted by the next
    # notice of something else.
    class NotificationDispatcher
      # One queued notification: what it is about, who wants it, what it says,
      # and what it costs to hold on to.
      Queued = Struct.new(:key, :listeners, :method_name, :params, :bytes)

      # @param owner [MCPClient::Subscription] the subscription it serves
      def initialize(owner)
        @owner = owner
        @mutex = Mutex.new
        @ready = ConditionVariable.new
        @buffer = []
        @bytes = 0
        @dropped = 0
        @warned_about_drops = false
        @stopped = false
        start_thread
      end

      # @return [Integer] notifications waiting for the listeners
      def pending
        @mutex.synchronize { @buffer.size }
      end

      # @return [Integer] bytes retained by the notifications waiting for the
      #   listeners
      def pending_bytes
        @mutex.synchronize { @bytes }
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
        # Measured before the lock is taken: sizing a large payload must not
        # hold up the reader thread that is delivering the next one.
        entry = Queued.new(identity(method, params), listeners, method, params, payload_bytesize(params))
        @mutex.synchronize do
          return if @stopped

          make_room(entry)
          @buffer << entry
          @bytes += entry.bytes
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

      # What holding a notification costs, measured as the JSON the peer sent:
      # the parsed objects are larger but proportional, and the peer decides
      # the size either way.
      # @param params [Hash, nil] notification params
      # @return [Integer] bytes
      def payload_bytesize(params)
        return 0 if params.nil?

        JSON.generate(params).bytesize
      rescue StandardError
        # Params always come from a parsed JSON message; if one somehow cannot
        # be re-encoded, charge for it rather than letting it slip the budget.
        params.to_s.bytesize
      end

      # @return [Integer] the ceiling, read at each delivery so a host can
      #   change it for a transport it knows is chatty
      def capacity
        MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS
      end

      # @return [Integer] the byte ceiling, read at each delivery for the same
      #   reason as {#capacity}
      def byte_capacity
        MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES
      end

      # Whether queuing `entry` would breach either ceiling. Called with the
      # lock held.
      # @param entry [Queued] the arriving notification
      # @return [Boolean]
      def overflowing?(entry)
        @buffer.size >= capacity || charged_bytes(entry) > byte_capacity
      end

      # The bytes queuing `entry` would charge against the byte ceiling: what
      # the queue would retain, less the one payload that is larger than the
      # whole budget, if it holds such a payload.
      #
      # That payload is admitted alone by design, and charging it would leave
      # the queue permanently over budget: every notification that followed
      # would find it overflowing, and with nothing redundant queued the
      # oversized entry, being the oldest, would be the first discarded — the
      # only notice of its resource lost to make room for a notice of
      # something else, which is exactly the loss this policy exists to
      # prevent. Only one payload is ever exempt, so a peer sending oversized
      # notifications back to back still keeps just one of them queued and the
      # retained total stays within the budget plus one peer-sized payload.
      # Called with the lock held.
      # @param entry [Queued] the arriving notification
      # @return [Integer] bytes
      def charged_bytes(entry)
        total = @bytes + entry.bytes
        largest = [@buffer.max_by(&:bytes)&.bytes || 0, entry.bytes].max
        largest > byte_capacity ? total - largest : total
      end

      # Make room for one more notification. Called with the lock held.
      # @param entry [Queued] the arriving notification
      # @return [void]
      def make_room(entry)
        dropped = 0
        # `droppable_index` answers nil only for an empty buffer, so a payload
        # too big to be made room for is queued rather than lost — and a
        # payload bigger than the whole budget needs no room made for it at
        # all (see {#charged_bytes}).
        while overflowing?(entry) && (index = droppable_index(entry.key))
          @bytes -= @buffer.delete_at(index).bytes
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

        same = @buffer.index { |entry| entry.key == key }
        return same if same

        redundant = most_queued_identity
        redundant ? @buffer.index { |entry| entry.key == redundant } : 0
      end

      # @return [Array, nil] the identity with more than one queued
      #   notification, nil when every queued notification names its own thing
      def most_queued_identity
        counts = @buffer.each_with_object(Hash.new(0)) { |entry, tally| tally[entry.key] += 1 }
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
                      "them; dropping repeats of what is already queued (at most #{capacity} notifications " \
                      "or #{byte_capacity} bytes, see MCPClient::Subscription#dropped_notifications)")
        end
      end

      # @return [Thread] the thread that runs the listeners
      def start_thread
        Thread.new do
          Thread.current.name = 'MCP-subscription'
          Thread.current.report_on_exception = false
          while (entry = next_entry)
            call_listeners(entry.listeners, entry.method_name, entry.params)
          end
        end
      end

      # @return [Queued, nil] the next notification to deliver, nil once the
      #   subscription has ended and everything queued has been delivered
      def next_entry
        @mutex.synchronize do
          @ready.wait(@mutex) while @buffer.empty? && !@stopped
          entry = @buffer.shift
          @bytes -= entry.bytes if entry
          entry
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
