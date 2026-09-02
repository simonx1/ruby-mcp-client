# frozen_string_literal: true

module MCPClient
  class Client
    # The per-task bookkeeping of the tasks extension: the answered and
    # in-flight input keys, the rounds spent and the pending update of each
    # task, all keyed by the server session they belong to. Task ids are per
    # session and reusable, so every entry dies with its session — and every
    # request that names a task carries the session it is about. Mixed into
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
        key = [srv.object_id, epoch, task_id]
        # A previous session of this server is over: its state (answered
        # keys, pending answers) is dropped, not left behind.
        @task_states.delete_if { |other, _| other[0] == key[0] && other[1] < key[1] }
        # The state carries its own registry key, so a request that captured
        # it can drop exactly what it was working on (see #forget_task_keys)
        # and never a later lifetime of the same task id.
        @task_states[key] ||= { key: key, answered: Set.new, submitted: Set.new, rounds: 0,
                                pending_update: nil, update_mutex: Mutex.new }
      end

      # Forget every task's bookkeeping (the client is being cleaned up).
      # @return [void]
      def clear_task_states
        answered_keys_mutex.synchronize do
          @task_states = nil
          @in_flight_keys = nil
          @task_session_epochs = nil
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

      # @return [Array] the registry key of a task's state
      def task_state_key(srv, task_id)
        [srv.object_id, current_session_epoch(srv), task_id]
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
            @task_states&.delete(epoch.nil? ? task_state_key(srv, task_id) : [srv.object_id, epoch, task_id])
            next
          end
          next unless @task_states && @task_states[state[:key]].equal?(state)

          @task_states.delete(state[:key])
        end
      end

      NO_KEYS = Set.new.freeze
      private_constant :NO_KEYS

      # Keys a running handler presents, kept apart from the task's
      # bookkeeping so no forget lets a retry present them again meanwhile.
      # A read allocates nothing; the reservation that holds keys asks for
      # the set to be created and receives its registry key with it.
      # @param key [Array, nil] the registry key to use; without one the
      #   current session's is resolved (a caller working on the state a wait
      #   captured passes that state's key, so a restart cannot move its
      #   reservation to the replacement session)
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
