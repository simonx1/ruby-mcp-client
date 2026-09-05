# frozen_string_literal: true

require_relative '../errors'
require_relative '../session_pin'

module MCPClient
  class Client
    # Which task a task id names, over the life of one server session.
    #
    # A task id is unique within a session, so a server that answers with an
    # id it has already handed out has ended that task and started another:
    # every CreateTaskResult begins a lifetime of its own, and a wait, a hold,
    # an answer or a cancel of one lifetime never reaches another. A lifetime
    # is a number drawn from the session's own counter, never reused and
    # never restarted, so two lifetimes stay distinguishable even after the
    # counters of the ids created longest ago are pruned.
    #
    # A request is bound to the lifetime it is about (see {#task_lifetime_pin})
    # rather than cleared by a preflight: the binding is checked at the wire,
    # where a CreateTaskResult a concurrent call records is already visible,
    # and again before the answer is acted on. Mixed into {TaskRegistry},
    # whose task states and in-flight key registry it reads to decide what a
    # prune may forget.
    module TaskLifetimes
      # How many task ids one client keeps a lifetime counter for. The counter
      # has to outlive the task's own bookkeeping — that is the point: a
      # creation under an id this client has already seen is a different task,
      # whether or not anything of the previous one is still around — so on a
      # sessionless connection, where the epoch never moves and nothing else
      # prunes it, the map would otherwise grow with every task ever created.
      # It bounds the ids of tasks that are over: a task still running keeps
      # its lifetime however many ids follow it (see {#prune_task_lifetimes}).
      MAX_TRACKED_TASK_LIFETIMES = 4096
      # How far a prune goes once the cap is passed: dropping a batch keeps the
      # scan amortized instead of walking the map on every creation.
      TRACKED_TASK_LIFETIMES_LOW_WATER = (MAX_TRACKED_TASK_LIFETIMES * 3) / 4

      private

      # Which task the id names now, as a number of its session's counter.
      # @param lookup [Array] server, session epoch and task id
      # @return [Integer, nil] nil for an id no creation is on the books for
      #   (never seen, or crowded out of the counter map)
      def task_lifetime(lookup)
        @task_lifetimes&.fetch(lookup, nil)
      end

      # Begin the lifetime a CreateTaskResult just created, and answer with
      # it. A task id is unique within a session, so a server that answers
      # with an id it has already handed out in this session has ended that
      # task and started another: the bookkeeping of the previous lifetime is
      # dropped and the id's lifetime moves, which gives the new task an
      # answered set, an in-flight registry entry and a pending update
      # entirely of its own. Without the move, an input key a handler of the
      # previous task is still presenting would be suppressed as already in
      # flight on the new one, and that handler's answer would be delivered to
      # the new task.
      #
      # Every creation this client observed counts, whether or not anything of
      # the previous one is still around: a second CreateTaskResult that
      # arrives before any wait allocated state, or after a terminal poll (or
      # a TTL expiry) forgot it, is just as much a different task, and two
      # handles that named the same lifetime would let the older one update or
      # cancel the task that replaced it.
      #
      # The lifetime is returned rather than read back afterwards: two
      # concurrent creations of one id take this lock one after the other, and
      # a second reading would stamp both handles with the later of the two.
      # @return [Integer] the lifetime this creation started
      def start_task_lifetime(srv, task_id, epoch)
        answered_keys_mutex.synchronize do
          lookup = [srv.object_id, epoch, task_id]
          @task_states ||= {}
          drop_ended_session_state(lookup)
          lifetimes = (@task_lifetimes ||= {})
          generation = next_task_lifetime(lookup)
          # Re-inserted, so the ids created most recently are the last a prune
          # reaches (a Hash keeps a rewritten key where it was).
          lifetimes.delete(lookup)
          lifetimes[lookup] = generation
          # The task exists from here until something says it is over, and its
          # own bookkeeping — never the replaced task's — says so: a live
          # entry is what keeps the prune below off the lifetime the handle
          # this creation produces names.
          @task_states[lookup] = new_task_state(lookup)
          prune_task_lifetimes(lifetimes)
          generation
        end
      end

      # The next lifetime number of a server session: one counter for the
      # whole session rather than one per id, so a number is never handed out
      # twice in it and a task id crowded out of the map (see
      # {#prune_task_lifetimes}) cannot be created again at a number some
      # handle of the pruned lifetime still names.
      # @param lookup [Array] server, session epoch and task id
      # @return [Integer] (callers hold answered_keys_mutex)
      def next_task_lifetime(lookup)
        counters = (@task_lifetime_counters ||= {})
        session = lookup.first(2)
        counter = counters[session] || 0
        counters[session] = counter + 1
        counter
      end

      # A previous session of this server is over: the lifetimes counted in it
      # go too, the session's counter with them — the epoch alone already
      # separates them from the next session's.
      # @return [void] (callers hold answered_keys_mutex)
      def drop_ended_lifetimes(lookup)
        @task_lifetimes&.delete_if { |other, _| other[0] == lookup[0] && other[1] < lookup[1] }
        @task_lifetime_counters&.delete_if { |other, _| other[0] == lookup[0] && other[1] < lookup[1] }
      end

      # Forget the lifetimes of the task ids created longest ago, once more of
      # them are kept than {MAX_TRACKED_TASK_LIFETIMES}. A handle of a
      # forgotten lifetime is refused rather than let through (see
      # {#check_task_lifetime_locked!}): the session's counter never restarts,
      # so a later creation under a pruned id is a number of its own and can
      # never read as the lifetime such a handle names.
      #
      # Only the lifetimes of tasks this client no longer tracks are
      # forgotten. A creation records the task's bookkeeping (see
      # {#start_task_lifetime}) and a terminal poll, a cancellation, a TTL
      # expiry or a `TaskNotFound` drops it again, so what the cap bounds is
      # the ids of tasks that have ended — never a handle whose task is still
      # running, whose absence from the registry the client has no business
      # reading as the task being over. An id whose keys a handler is still
      # presenting stays too: an abandoned handler outlives the bookkeeping,
      # and its holds name the lifetime they belong to.
      # @return [void] (callers hold answered_keys_mutex)
      def prune_task_lifetimes(lifetimes)
        return if lifetimes.size <= MAX_TRACKED_TASK_LIFETIMES

        # A snapshot: the entries are deleted as the scan walks them.
        tracked = lifetimes.keys
        tracked.each do |lookup|
          break if lifetimes.size <= TRACKED_TASK_LIFETIMES_LOW_WATER
          next if @task_states&.key?(lookup) || presenting_earlier_lifetime?(lookup)

          lifetimes.delete(lookup)
        end
      end

      # Whether a handler is still presenting the input keys of some lifetime
      # of this task id (an abandoned handler outlives its state).
      # @return [Boolean] (callers hold answered_keys_mutex)
      def presenting_earlier_lifetime?(lookup)
        return false unless @in_flight_keys

        @in_flight_keys.any? { |key, held| key.first(3) == lookup && !held.empty? }
      end

      # Whether the bookkeeping a request was built from is still what its
      # task id names: a CreateTaskResult that handed the id out again since
      # started a different task, and the request belongs to the previous one.
      # @param state [Hash] the bookkeeping the request captured
      # @return [Boolean]
      def task_lifetime_current?(state)
        answered_keys_mutex.synchronize { task_lifetime(state[:lookup]) == state[:generation] }
      end

      # The lifetime a handle refreshed from another one keeps: the one the
      # source handle named, when that handle is this server's. A request
      # that named its task with a bare id (or with another server's handle)
      # asks about whatever the id means now and produces a handle that says
      # the same, exactly as before — but a handle built from one that named
      # a definite task must keep naming it, or a later creation under the id
      # would silently move it to the task that replaced it.
      # @param task [Object] what the caller named the task with
      # @return [Integer, nil]
      def handle_task_generation(task, srv)
        return nil unless task.is_a?(MCPClient::Task) && task.server.equal?(srv)

        task.task_generation
      end

      # Bind a request to the task it is about, and refuse it here and now if
      # that task is already gone.
      #
      # A handle from a creation names a definite task: the request is for
      # that lifetime and no other, and the pin holds the transport to it at
      # the wire (see {#pinned_to_lifetime}) as well as the answer to it
      # afterwards (see {#verify_task_lifetime!}). A bare id, a handle from
      # another server and a handle that never came from a creation name
      # whatever the id means now and are let through, exactly as before —
      # their pin only records which lifetime that was, so what the request
      # forgets on the way out is that lifetime's and never a replacement's.
      # @param task [Object] what the caller named the task with
      # @param task_id [String] the id the request carries
      # @param epoch [Integer, nil] the session the request is pinned to
      # @param operation [String] for the error message ('updating', 'waiting for')
      # @return [Hash] the pin
      # @raise [MCPClient::Errors::TaskReplacedError] if the handle's task was replaced
      def task_lifetime_pin(task, task_id, srv, epoch, operation)
        named = handle_task_generation(task, srv)
        pin = { lookup: [srv.object_id, epoch, task_id], generation: named, named: !named.nil?,
                task_id: task_id, operation: operation }
        answered_keys_mutex.synchronize do
          pin[:generation] = task_lifetime(pin[:lookup]) unless pin[:named]
          check_task_lifetime_locked!(pin)
        end
        pin
      end

      # Run the block with the transport refusing to write once the task id
      # names another task than the request is about. The check happens where
      # the session pin's does — immediately before the wire, so a
      # CreateTaskResult a concurrent call records while this request is being
      # built (or while its session is being established) is seen, and the
      # request is not sent for a task that is already gone. A transport that
      # knows no write guard sends as before.
      # @param pin [Hash, nil] the request's lifetime pin
      # @return [Object] the block's value
      def pinned_to_lifetime(srv, pin, &block)
        return block.call if pin.nil? || !pin[:named] || !srv.respond_to?(:guarded_writes)

        srv.guarded_writes(-> { check_task_lifetime!(pin) }, &block)
      end

      # The answer of a request is acted on only while the task it named is
      # still what its id names: a creation that landed while the answer was
      # in flight makes the answer the previous task's, and the handle,
      # the delivered result and the bookkeeping cleanup it drives would all
      # be about a task that is gone.
      # @param pin [Hash, nil] the request's lifetime pin
      # @return [void]
      # @raise [MCPClient::Errors::TaskReplacedError]
      def verify_task_lifetime!(pin)
        check_task_lifetime!(pin) if pin
      end

      # @return [void]
      # @raise [MCPClient::Errors::TaskReplacedError]
      def check_task_lifetime!(pin)
        answered_keys_mutex.synchronize { check_task_lifetime_locked!(pin) }
      end

      # {#check_task_lifetime!} for a caller already holding the registry lock.
      # @return [void] (callers hold answered_keys_mutex)
      # @raise [MCPClient::Errors::TaskReplacedError]
      def check_task_lifetime_locked!(pin)
        return unless pin[:named]

        current = task_lifetime(pin[:lookup])
        return if current == pin[:generation]

        raise MCPClient::Errors::TaskReplacedError, replaced_task_message(pin, current)
      end

      # @param current [Integer, nil] the lifetime the id names now
      # @return [String]
      def replaced_task_message(pin, current)
        shown = shown_task_id(pin[:task_id])
        if current.nil?
          # Crowded out of the counter map (or forgotten with the client's
          # state): what the id names now cannot be told from what the handle
          # names, so the request is refused rather than sent on a guess.
          return "Error #{pin[:operation]} task '#{shown}': this client no longer tracks the task this handle " \
                 'names (the session created task ids enough to crowd it out), so the request is refused rather ' \
                 'than sent for whatever answers to the id now'
        end

        "Error #{pin[:operation]} task '#{shown}': the server has created a new task with this id since, so the " \
          'task this handle names was replaced and is gone'
      end
    end
  end
end
