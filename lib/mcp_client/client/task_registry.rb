# frozen_string_literal: true

module MCPClient
  class Client
    # The per-task bookkeeping of the tasks extension: the answered and
    # in-flight input keys, the rounds spent and the pending update of each
    # task, all keyed by the server session they belong to. Task ids are per
    # session and reusable, so every entry dies with its session — and every
    # request that names a task carries the session it is about. Inside one
    # session an id is reusable too: every CreateTaskResult starts a fresh
    # lifetime under it (see {#start_task_lifetime}), and a wait, a hold or an
    # answer of one lifetime never reaches another. Mixed into
    # {MCPClient::Client} through {TaskSupport}.
    module TaskRegistry
      private

      # Per-task bookkeeping shared by every wait on the task: the answered
      # keys, the input rounds spent, an update still to be delivered and
      # the lock that serializes its updates. Task ids are per server
      # session (a restarted stdio process may reuse them), so the state is
      # keyed by the transport's session epoch too and dies with it. The
      # epoch is read under the lock and never runs backwards: a caller
      # that read it before a restart gets the current session's state and
      # cannot delete it or bring an older session back.
      # @return [Hash]
      def task_state(srv, task_id)
        answered_keys_mutex.synchronize { task_state_locked(srv, task_id, current_session_epoch(srv)) }
      end

      # {#task_state} for a caller already holding the registry lock and the
      # epoch it read under it.
      # @return [Hash]
      def task_state_locked(srv, task_id, epoch)
        @task_states ||= {}
        lookup = [srv.object_id, epoch, task_id]
        drop_ended_session_state(lookup)
        @task_states[lookup] ||= new_task_state(lookup)
      end

      # A task's bookkeeping, stamped with the lifetime of its id (see
      # {#start_task_lifetime}). The state carries both keys: `lookup`, under
      # which the live task of an id is found, so a request that captured the
      # state can drop exactly what it was working on (see #forget_task_keys)
      # and never a later lifetime of the same id; and `key`, which names the
      # lifetime itself and under which the in-flight holds of a running
      # handler live, so two lifetimes of one id never share them.
      # @param lookup [Array] server, session epoch and task id
      # @return [Hash] (callers hold answered_keys_mutex)
      def new_task_state(lookup)
        generation = task_lifetime(lookup)
        { key: [*lookup, generation], lookup: lookup, generation: generation, answered: Set.new,
          submitted: Set.new, rounds: 0, pending_update: nil, update_mutex: Mutex.new }
      end

      # A previous session of this server is over: its state (answered keys,
      # pending answers) and the id lifetimes counted in it are dropped, not
      # left behind — the epoch alone already separates them from the next
      # session's.
      # @return [void] (callers hold answered_keys_mutex)
      def drop_ended_session_state(lookup)
        @task_states.delete_if { |other, _| other[0] == lookup[0] && other[1] < lookup[1] }
        @task_lifetimes&.delete_if { |other, _| other[0] == lookup[0] && other[1] < lookup[1] }
      end

      # How many times the server has already handed this task id out inside
      # this session; 0 for an id no reuse was ever seen for.
      # @param lookup [Array] server, session epoch and task id
      # @return [Integer] (callers hold answered_keys_mutex)
      def task_lifetime(lookup)
        @task_lifetimes&.fetch(lookup, nil) || 0
      end

      # Begin the lifetime a CreateTaskResult just created. A task id is
      # unique within a session, so a server that answers with an id whose
      # previous task is still on this client's books has ended that task and
      # started another: the bookkeeping of the previous lifetime is dropped
      # and the id's generation moves, which gives the new task an answered
      # set, an in-flight registry entry and a pending update entirely of its
      # own. Without the move, an input key a handler of the previous task is
      # still presenting would be suppressed as already in flight on the new
      # one, and that handler's answer would be delivered to the new task.
      #
      # Only an id whose previous lifetime is still around is counted: for
      # every well-behaved server (and for the first task under any id) there
      # is nothing to separate, so nothing is recorded.
      # @return [void]
      def start_task_lifetime(srv, task_id, epoch)
        answered_keys_mutex.synchronize do
          lookup = [srv.object_id, epoch, task_id]
          previous = @task_states&.delete(lookup)
          next unless previous || presenting_earlier_lifetime?(lookup)

          (@task_lifetimes ||= {})[lookup] = task_lifetime(lookup) + 1
        end
      end

      # Whether a handler is still presenting the input keys of some lifetime
      # of this task id (an abandoned handler outlives its state).
      # @return [Boolean] (callers hold answered_keys_mutex)
      def presenting_earlier_lifetime?(lookup)
        return false unless @in_flight_keys

        @in_flight_keys.any? { |key, held| key.first(3) == lookup && !held.empty? }
      end

      # The lifetime a task id has now in a given session.
      # @return [Integer]
      def current_task_lifetime(srv, task_id, epoch)
        answered_keys_mutex.synchronize { task_lifetime([srv.object_id, epoch, task_id]) }
      end

      # Refuse a request whose task handle names a task the server has since
      # replaced. A task id is unique within a session, so a fresh
      # CreateTaskResult under it ended the task the handle was built for: the
      # request must not be sent for the task that answers to the id now. A
      # bare id, a handle from another server, and a handle that never came
      # from a creation all name whatever the id means now and are let
      # through, exactly as before.
      # @param task [Object] what the caller named the task with
      # @param epoch [Integer, nil] the session the request is pinned to
      # @param operation [String] for the error message ('updating', 'waiting for')
      # @return [void]
      # @raise [MCPClient::Errors::TaskError] if the handle's task was replaced
      def check_handle_lifetime!(task, srv, epoch, operation)
        return unless task.is_a?(MCPClient::Task) && task.server.equal?(srv) && task.task_generation
        return if current_task_lifetime(srv, task.task_id, epoch) == task.task_generation

        raise MCPClient::Errors::TaskError,
              "Error #{operation} task '#{shown_task_id(task.task_id)}': the server has created a new task with " \
              'this id since, so the task this handle names was replaced and is gone'
      end

      # Whether the bookkeeping a request was built from is still what its
      # task id names: a CreateTaskResult that handed the id out again since
      # started a different task, and the request belongs to the previous one.
      # @param state [Hash] the bookkeeping the request captured
      # @return [Boolean]
      def task_lifetime_current?(state)
        answered_keys_mutex.synchronize { task_lifetime(state[:lookup]) == state[:generation] }
      end

      # Forget every task's bookkeeping (the client is being cleaned up).
      # @return [void]
      def clear_task_states
        answered_keys_mutex.synchronize do
          @task_states = nil
          @in_flight_keys = nil
          @task_session_epochs = nil
          @task_lifetimes = nil
        end
      end

      # The server's session epoch as this client knows it, monotonic: the
      # highest value ever read wins, so a stale reading never reopens an
      # ended session. Callers hold answered_keys_mutex or do not care about
      # a concurrent bump (the next task_state resolves it).
      # @return [Integer]
      def current_session_epoch(srv)
        read = srv.respond_to?(:session_epoch) ? srv.session_epoch : 0
        @task_session_epochs ||= {}.compare_by_identity
        seen = @task_session_epochs[srv] || 0
        @task_session_epochs[srv] = [read, seen].max
      end

      # The session an explicit request for a task handle belongs to. Task
      # ids are per session and reusable, so a handle a host kept across a
      # restart names a task that no longer exists: the request is refused
      # rather than sent into the session that replaced it, where the same id
      # may name something else. A bare task id, a handle from another
      # server, or a server that reports no session names whatever the live
      # session knows and carries no pin.
      # @param task [Object] what the caller named the task with
      # @param operation [String] for the error message ('updating', 'cancelling')
      # @return [Integer, nil] the epoch to pin the request to
      # @raise [MCPClient::Errors::TaskError] if the handle's session has ended
      def handle_session_epoch(task, srv, operation)
        return nil unless task.is_a?(MCPClient::Task) && task.server.equal?(srv) && task.session_epoch

        epoch = task.session_epoch
        return epoch if answered_keys_mutex.synchronize { current_session_epoch(srv) } == epoch

        raise MCPClient::Errors::TaskError,
              "Error #{operation} task '#{shown_task_id(task.task_id)}': the server session it belongs to has " \
              'ended, so the task is gone (a restarted server may reuse its id for an unrelated task)'
      end

      # The session a task request that named its task with a bare id belongs
      # to: the one live when the caller asked. Task ids are per session and
      # reusable, so a request that is only written (or replayed, after an
      # HTTP 404 restarted the session) once the session has moved would
      # read, cancel or answer whatever the replacement session named with
      # the same id. A server that reports no session carries no pin.
      # @return [Integer, nil] the epoch to pin the request to
      def invocation_session_epoch(srv)
        return nil unless srv.respond_to?(:session_epoch)

        begin
          # The session comes up before it is sampled: the transports connect
          # lazily inside the request itself, and that first connection ends
          # the session the epoch was read in — a pin taken before it would
          # refuse the very request that establishes the session.
          establish_session(srv)
        rescue StandardError
          # Not this method's failure to report: the request that follows
          # sends (and fails) exactly as it would have.
          nil
        end
        answered_keys_mutex.synchronize { current_session_epoch(srv) }
      end

      # @return [Array] where a task id's live bookkeeping is found in the
      #   session live at this call (callers hold answered_keys_mutex)
      def task_state_lookup(srv, task_id)
        [srv.object_id, current_session_epoch(srv), task_id]
      end

      # @return [Array] the registry key of the current lifetime of a task id,
      #   under which its in-flight holds live (callers hold answered_keys_mutex)
      def task_state_key(srv, task_id)
        lookup = task_state_lookup(srv, task_id)
        [*lookup, task_lifetime(lookup)]
      end

      # @return [Mutex] guards the answered-key registry (request threads share the client)
      def answered_keys_mutex
        @answered_keys_mutex ||= Mutex.new
      end

      # Drop a task's bookkeeping: it is terminal, cancelled, gone or past
      # its TTL, so nothing of it may colour a later task with the same id.
      # @param state [Hash, nil] the bookkeeping the caller was working on;
      #   only that very state is dropped, so a request abandoned on the
      #   wait's wall clock cannot, on its late completion, wipe what a new
      #   session — or a new lifetime of a reused task id — has recorded
      #   since. Without one, the state of the session the request was about
      #   is dropped (the current one when that session is not known either).
      # @param epoch [Integer, nil] the session the request that reported the
      #   task gone (or terminal) was pinned to
      # @return [void]
      def forget_task_keys(srv, task_id, state: nil, epoch: nil)
        answered_keys_mutex.synchronize do
          unless state
            @task_states&.delete(epoch.nil? ? task_state_lookup(srv, task_id) : [srv.object_id, epoch, task_id])
            next
          end
          next unless @task_states && @task_states[state[:lookup]].equal?(state)

          @task_states.delete(state[:lookup])
        end
      end

      NO_KEYS = Set.new.freeze
      private_constant :NO_KEYS

      # Keys a running handler presents, kept apart from the task's
      # bookkeeping so no forget lets a retry present them again meanwhile.
      # A read allocates nothing; the reservation that holds keys asks for
      # the set to be created and receives its registry key with it.
      # @param key [Array, nil] the registry key to use; without one the
      #   current lifetime's is resolved (a caller working on the state a wait
      #   captured passes that state's key, so neither a restart nor a task id
      #   handed out again can move its reservation to what replaced it)
      # @return [Set<String>, Array(Set<String>, Array)] (callers hold answered_keys_mutex)
      def in_flight_task_keys(srv, task_id, create: false, key: nil)
        key ||= task_state_key(srv, task_id)
        return [(@in_flight_keys ||= {})[key] ||= Set.new, key] if create

        @in_flight_keys&.fetch(key, nil) || NO_KEYS
      end

      # Drop a registry entry once its own set is empty; another task's or
      # session's entry is never touched.
      # @return [void] (callers hold answered_keys_mutex)
      def release_in_flight_entry(held, held_key)
        return unless held.empty? && @in_flight_keys && @in_flight_keys[held_key].equal?(held)

        @in_flight_keys.delete(held_key)
      end
    end
  end
end
