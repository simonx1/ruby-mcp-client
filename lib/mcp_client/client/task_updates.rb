# frozen_string_literal: true

require_relative '../errors'

module MCPClient
  class Client
    # The tasks/update delivery path of the MCP 2026-07-28 tasks extension:
    # which keys count as answered, the pending payload an unconfirmed
    # delivery leaves behind, and the session guard that keeps the answers of
    # an ended session out of the next one. Mixed into {TaskSupport}, which
    # owns the polling loop these deliveries run in.
    module TaskUpdates
      private

      # Record keys whose answers were handed to the transport by
      # {#update_task}: they stay answered even if a handler that reserved
      # them fails afterwards.
      # @return [void]
      def remember_answered_keys(srv, task_id, keys)
        remember_answered_keys_in(task_state(srv, task_id), keys)
      end

      # @param state [Hash] the task state the update is bound to
      # @return [void]
      def remember_answered_keys_in(state, keys)
        answered_keys_mutex.synchronize do
          state[:answered].merge(keys)
          state[:submitted].merge(keys)
        end
      end

      # Whether a tasks/update failure means the server definitely did not
      # take the answers: a JSON-RPC error with a code from the server
      # itself. A 5xx, a closed response stream or any untyped server error
      # is ambiguous (the update may have been applied).
      # @param error [MCPClient::Errors::ServerError]
      # @return [Boolean]
      def definite_rejection?(error)
        error.code.is_a?(Integer) && !error.is_a?(MCPClient::Errors::TransientServerError)
      end

      # Give back keys the server definitely did not take, in the state the
      # rejected update was built from: a rejection that lands after a
      # restart must not unmark keys the new session has answered for what
      # is a different request.
      # @param state [Hash] the task state the update was bound to
      # @return [void]
      def release_answered_keys_in(state, keys)
        answered_keys_mutex.synchronize do
          state[:answered].subtract(keys)
          state[:submitted].subtract(keys)
        end
      end

      # Send the answers a handler produced (or, with pending_only, only what
      # an earlier ambiguous delivery left pending), bounded by the caller's
      # timeout and carrying the session the answers belong to. An ambiguous
      # delivery (the server may or may not have applied it) is not the end
      # of the wait: the payload stays pending and goes out again with the
      # next poll, like a lost tasks/get. A definite rejection surfaces.
      # @return [void]
      def deliver_task_update(srv, task_id, responses, wait, pending_only: false)
        # The bookkeeping this delivery is bound to is captured here, before
        # anything is sent: a session that restarts meanwhile must not make
        # the send record its keys, drop its pending payload or release them
        # in another session's state (the epoch guard drops the payload
        # instead), and an abandoned send finishes against this very state.
        state = task_state(srv, task_id)
        bounded_by_wait(wait, deadline: wait[:deadline],
                              on_abandon: ->(_runner) { abandon_task_update(state) }) do
          send_task_update(srv, task_id, responses, epoch: wait[:epoch], pending_only: pending_only, state: state,
                                                    timeout: request_timeout(wait_deadline(wait), srv))
        end
      rescue MCPClient::Errors::TaskError => e
        raise unless ambiguous_update_failure?(e)

        logger.debug("tasks/update for task #{shown_task_id(task_id)} could not be confirmed; " \
                     'it is sent again on the next poll')
      end

      # One tasks/update, owning the pending-payload lifecycle: the keys are
      # answered as soon as the payload is handed to the transport; the
      # request carries every response still pending from an earlier
      # ambiguous delivery (the server ignores keys it already has, so a
      # resend is safe and no unconfirmed answer is left behind); a
      # confirmed delivery clears the pending payload (a later answer
      # supersedes a lost one); a definite JSON-RPC rejection gives the keys
      # back and drops the payload; an ambiguous outcome (timeout, transport
      # or connection failure, 5xx, untyped server error) keeps it pending
      # for retransmission.
      # @param timeout [Numeric, nil] request timeout, bounded by the wait when there is one
      # @param pending_only [Boolean] send whatever is pending under the lock and nothing else
      #   (a retransmission; nothing pending sends nothing)
      # @param epoch [Integer, nil] the session epoch the answers were produced in; the update is
      #   dropped when the server's session moved on since (nil: no expectation, e.g. #update_task)
      # @param state [Hash, nil] the bookkeeping the answers were built from; every mutation
      #   (answered keys, pending payload) lands there and nowhere else
      # @return [true]
      # @raise [MCPClient::Errors::TaskError, MCPClient::Errors::ServerError]
      def send_task_update(srv, task_id, input_responses, timeout: nil, pending_only: false, epoch: nil, state: nil)
        shown = shown_task_id(task_id)
        state ||= task_state(srv, task_id)
        # One update at a time per task: a concurrent update that read an
        # empty pending slot could otherwise confirm and wipe an answer
        # another delivery had just left pending. An explicit answer is
        # newer than a pending one for the same key and wins the merge.
        lock = state[:update_mutex]
        lock.synchronize do
          return true unless task_update_session_current?(srv, shown, epoch)

          pending = answered_keys_mutex.synchronize { state[:pending_update] }
          input_responses = pending_only ? pending : pending&.merge(input_responses) || input_responses
          return true if input_responses.nil?

          dispatch_task_update(srv, task_id, input_responses, shown: shown, state: state, lock: lock,
                                                              timeout: timeout)
        end
      end

      # Whether the answers may still go out: the session they were produced
      # in must be the one the request is about to reach. The connection is
      # established first, because the built-in rpc_request initializes (and
      # so may reconnect, ending the session) inside the very call this
      # guards — the epoch is then compared after that reconnect, as late as
      # the payload can still be held back. Task ids and input keys are
      # session-scoped and reusable, so an answer that arrives in the wrong
      # session could answer an unrelated request.
      # @return [Boolean]
      def task_update_session_current?(srv, shown, epoch)
        return true unless epoch

        establish_session(srv)
        return true if answered_keys_mutex.synchronize { current_session_epoch(srv) } == epoch

        logger.warn("Task #{shown}: the session restarted before the answers were sent; they are discarded")
        false
      end

      # Bring the transport's session up before the epoch is compared, so a
      # reconnect happens on this side of the guard. A failure is not
      # handled here: the request that follows raises it through its own
      # error path.
      # @return [void]
      def establish_session(srv)
        srv.ensure_session_ready if srv.respond_to?(:ensure_session_ready)
      rescue StandardError => e
        logger.debug("Could not establish the session before a tasks/update: #{sanitize_peer_log_text(e.message)}")
      end

      # The wire part of {#send_task_update}: the keys are answered and the
      # payload is pending from the moment it is handed to the transport, so
      # a wait that abandons this send on its wall clock leaves answers that
      # are still deliverable (the next wait retransmits them) rather than
      # keys marked answered with nothing to send. Only the thread that
      # still holds the task's update lock clears or releases them: once the
      # wait abandoned this send, the retry that took the lock over owns the
      # bookkeeping.
      # @return [true]
      def dispatch_task_update(srv, task_id, input_responses, shown:, state:, lock:, timeout:)
        keys = input_responses.keys.map(&:to_s)
        remember_answered_keys_in(state, keys)
        keep_pending_update(state, input_responses)
        begin
          task_rpc(srv, 'tasks/update', { taskId: task_id, inputResponses: input_responses }, timeout: timeout)
          clear_pending_update(state, lock)
          true
        rescue MCPClient::Errors::ServerError => e
          if definite_rejection?(e) && update_lock_current?(state, lock)
            release_answered_keys_in(state, keys)
            clear_pending_update(state, lock)
          end
          raise if e.protocol_error?

          raise task_failure(e, srv, task_id, 'updating', method: 'tasks/update', state: state)
        rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
          # Ambiguous: the payload stays pending for the next poll.
          raise MCPClient::Errors::TaskError,
                "Error updating task '#{shown}': #{sanitize_peer_log_text(e.message)}"
        end
      end

      # @return [void]
      def keep_pending_update(state, input_responses)
        answered_keys_mutex.synchronize do
          state[:pending_update] = (state[:pending_update] || {}).merge(input_responses)
        end
      end

      # Drop the pending payload of a delivery that is settled — unless the
      # wait abandoned this send and a retry holds the task's update lock
      # now: what that retry left pending is not this send's to clear.
      # @return [void]
      def clear_pending_update(state, lock)
        answered_keys_mutex.synchronize { state[:pending_update] = nil if state[:update_mutex].equal?(lock) }
      end

      # @return [Boolean] whether this send still holds the task's update lock
      def update_lock_current?(state, lock)
        answered_keys_mutex.synchronize { state[:update_mutex].equal?(lock) }
      end

      # A wait that ran out of wall clock abandons its tasks/update: the
      # thread keeps the task's update lock for as long as the request hangs
      # (a transport implementing only rpc_request(method, params) may never
      # come back), which would block the retransmission the next wait owes
      # the server. The lock is replaced so that retry can deliver the
      # answers this send left pending; the abandoned thread finishes
      # against the state it captured and touches none of it.
      # @return [void]
      def abandon_task_update(state)
        answered_keys_mutex.synchronize { state[:update_mutex] = Mutex.new }
      end

      # Whether a failed tasks/update may still have been applied.
      # @param error [MCPClient::Errors::TaskError]
      # @return [Boolean]
      def ambiguous_update_failure?(error)
        cause = error.cause
        return true if cause.is_a?(MCPClient::Errors::TransportError) || cause.is_a?(MCPClient::Errors::ConnectionError)

        cause.is_a?(MCPClient::Errors::ServerError) && !definite_rejection?(cause)
      end
    end
  end
end
