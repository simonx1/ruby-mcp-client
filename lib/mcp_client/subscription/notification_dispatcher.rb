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
    # run, and the peer chooses how big they are. So there is a count ceiling
    # ({MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS}) and a byte budget
    # ({MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES}).
    #
    # Two rules keep the queue honest, and they are the same rule seen from
    # each end:
    #
    # 1. **Every queued notification is charged exactly what it retains.**
    #    {#pending_bytes} is the sum of the queue, always, because the queue
    #    and its totals are only ever changed together (see {#push} and
    #    {#discard}).
    # 2. **Every eviction removes an entry whose removal relieves the pressure
    #    that caused it.** Each pressure has its own candidates: the byte
    #    budget admits only the entries charged against it, the count ceiling
    #    admits every entry (each is one of the count), and the oversized slot
    #    admits only its occupant. So overflow always makes progress and a
    #    signal is never spent on pressure that discarding it cannot relieve.
    #
    # Earlier revisions decided these two by rules that disagreed — a payload
    # exempt from the charge but not from eviction — and the queue could throw
    # away the only notice of a resource and still be over budget.
    #
    # *Which* of the candidates goes is chosen by identity — the
    # notification's method together with the resource URI or task id it names
    # — never by arrival order alone: one stream can carry a mixed filter, and
    # dropping the oldest entry would throw away the only queued update for a
    # quiet resource to keep newer ones for a busy one, with nothing left to
    # tell the listener to re-read the quiet one. Since every MCP notification
    # is a "look again" signal about state the host re-reads for itself, a
    # second notice of the same thing is redundant and the first notice of a
    # thing is not. So overflow gives up, in order of preference:
    #
    # 1. the oldest candidate of the same identity as the arriving
    #    notification — the listener still gets the newest word on it;
    # 2. otherwise the oldest candidate of whichever identity has the most
    #    queued, so nothing loses its only notice while something else has a
    #    spare;
    # 3. only when every candidate names a different thing, the oldest — the
    #    queue is then full of distinct signals and one must go.
    #
    # A notification whose payload is larger than the whole byte budget is not
    # charged against it. It is held in a slot of its own instead, and there is
    # only ever one such slot: a second oversized payload takes it from the
    # first, which is the only thing that ever displaces one. So such a payload
    # is neither lost for being large nor able to displace what the budget
    # holds — nothing else is charged to its slot, and discarding it would free
    # nothing the budget is short of — while what the queue retains stays
    # within the budget plus one peer-sized payload.
    class NotificationDispatcher
      # One queued notification: what it is about, who wants it, what it says,
      # what it costs to hold on to, and whether that cost is the budget's or
      # its own slot's.
      Queued = Struct.new(:key, :listeners, :method_name, :params, :bytes, :oversized)

      # @param owner [MCPClient::Subscription] the subscription it serves
      def initialize(owner)
        @owner = owner
        @mutex = Mutex.new
        @ready = ConditionVariable.new
        @buffer = []
        @bytes = 0
        @oversized_bytes = 0
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
        bytes = payload_bytesize(params)
        entry = Queued.new(identity(method, params), listeners, method, params, bytes, bytes > byte_capacity)
        @mutex.synchronize do
          return if @stopped

          make_room(entry)
          push(entry)
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

      # Add one entry, charging exactly what it retains. The queue and its
      # totals only change here and in {#discard}, which is what makes
      # {#pending_bytes} the sum of the queue rather than an estimate of it.
      # Called with the lock held.
      # @param entry [Queued]
      # @return [void]
      def push(entry)
        @buffer << entry
        @bytes += entry.bytes
        @oversized_bytes += entry.bytes if entry.oversized
      end

      # Remove the entry at `index`, releasing exactly what it was charged.
      # Called with the lock held.
      # @param index [Integer]
      # @return [Queued] the entry that was removed
      def discard(index)
        entry = @buffer.delete_at(index)
        @bytes -= entry.bytes
        @oversized_bytes -= entry.bytes if entry.oversized
        entry
      end

      # @return [Integer] the bytes charged against the budget: everything
      #   queued except the payload holding the oversized slot
      def budgeted_bytes
        @bytes - @oversized_bytes
      end

      # @return [Integer, nil] the position of the oversized payload, nil when
      #   the slot is free. There is at most one by construction: an arriving
      #   oversized payload takes the slot from its occupant first.
      def oversized_index
        @buffer.index(&:oversized)
      end

      # Make room for one more notification. Called with the lock held.
      # @param entry [Queued] the arriving notification
      # @return [void]
      def make_room(entry)
        dropped = 0
        while (index = crowded_out(entry))
          discard(index)
          dropped += 1
        end
        return if dropped.zero?

        @dropped += dropped
        report_dropped(dropped)
      end

      # The position of the entry that has to go before `entry` can be queued,
      # or nil once it fits. Each pressure admits only the entries whose
      # removal relieves *it*, so every eviction makes progress and the loop in
      # {#make_room} always ends:
      #
      # * the oversized slot: only its occupant will do, and an arriving
      #   payload that needs the slot always frees it in one step;
      # * the byte budget: only the entries charged against it, and with none
      #   of them left the budget holds anything that is not oversized;
      # * the count ceiling: every queued entry is one of the count.
      #
      # Which of the candidates goes is then the identity question (see the
      # class comment). Called with the lock held.
      # @param entry [Queued] the arriving notification
      # @return [Integer, nil]
      def crowded_out(entry)
        return oversized_index if entry.oversized && oversized_index
        return evictable_index(entry.key, budgeted_indices) if budgeted_bytes + budgeted_cost(entry) > byte_capacity
        return evictable_index(entry.key, (0...@buffer.size).to_a) if @buffer.size >= capacity

        nil
      end

      # @param entry [Queued] the arriving notification
      # @return [Integer] what queuing it would add to the budget: nothing when
      #   it is bound for the slot of its own
      def budgeted_cost(entry)
        entry.oversized ? 0 : entry.bytes
      end

      # @return [Array<Integer>] the positions of the entries the budget is
      #   charged for
      def budgeted_indices
        (0...@buffer.size).reject { |index| @buffer[index].oversized }
      end

      # The candidate overflow should discard (see the class comment). Called
      # with the lock held.
      # @param key [Array] the arriving notification's identity
      # @param candidates [Array<Integer>] positions that may be discarded
      # @return [Integer, nil] its position, nil when there is no candidate
      def evictable_index(key, candidates)
        return nil if candidates.empty?

        same = candidates.find { |index| @buffer[index].key == key }
        return same if same

        redundant = most_queued_identity(candidates)
        redundant ? candidates.find { |index| @buffer[index].key == redundant } : candidates.first
      end

      # @param candidates [Array<Integer>] positions that may be discarded
      # @return [Array, nil] the identity with more than one candidate queued,
      #   nil when every candidate names its own thing
      def most_queued_identity(candidates)
        counts = candidates.each_with_object(Hash.new(0)) { |index, tally| tally[@buffer[index].key] += 1 }
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
          discard(0) unless @buffer.empty?
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
