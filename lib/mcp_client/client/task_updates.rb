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
        # It is the wait's own state — the one the answers were built in —
        # not whatever the live session now keys under the same id: a
        # delivery the pin drops must not give back keys a concurrent wait
        # has reserved in the session that replaced it.
        state = wait[:state] || task_state(srv, task_id)
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
      def send_task_update(srv, task_id, input_responses, timeout: nil, pending_only: false, epoch: nil, state: nil,
                           strict_session: false)
        shown = shown_task_id(task_id)
        state ||= task_state(srv, task_id)
        # The answers are pending — and their keys answered — from the moment
        # this delivery is queued, before it waits for the task's update
        # lock: a wait that gives up while queued behind a hanging update
        # (its wall clock ran out) must leave answers the next wait can
        # retransmit, not keys marked answered with nothing to send. An
        # explicit answer is newer than a pending one for the same key and
        # wins the merge.
        queue_task_update(state, input_responses) unless pending_only
        # One update at a time per task: a concurrent update that read an
        # empty pending slot could otherwise confirm and wipe an answer
        # another delivery had just left pending.
        lock = state[:update_mutex]
        lock.synchronize do
          payload = answered_keys_mutex.synchronize { state[:pending_update] }
          # An explicit answer goes out even when it adds nothing to send
          # (#update_task with no responses is the caller's request, not a
          # retransmission).
          payload = input_responses if payload.nil? && !pending_only
          return true if payload.nil?

          dispatch_task_update(srv, task_id, payload, shown: shown, state: state, lock: lock,
                                                      timeout: timeout, epoch: epoch,
                                                      strict_session: strict_session)
        end
      end

      # Record a delivery's answers before it queues for the task's update
      # lock: answered (so no handler is asked again) and pending (so any
      # wait can deliver them).
      # @return [void]
      def queue_task_update(state, input_responses)
        return if input_responses.nil? || input_responses.empty?

        remember_answered_keys_in(state, input_responses.keys.map(&:to_s))
        keep_pending_update(state, input_responses)
      end

      # Whether the answers may still go out: the session they were produced
      # in must be the one the request is about to reach. The connection is
      # established first, because the built-in rpc_request initializes (and
      # so may reconnect, ending the session) inside the very call this
      # guards; the request itself is then pinned to the session (see
      # {MCPClient::JsonRpcCommon#pinned_to_session}), so a reconnect between
      # this compare and the write drops the payload at the wire rather than
      # sending it into the next session. Task ids and input keys are
      # session-scoped and reusable, so an answer that arrives in the wrong
      # session could answer an unrelated request.
      # @return [Boolean]
      def task_update_session_current?(srv, shown, epoch)
        return true unless epoch

        begin
          establish_session(srv)
        rescue StandardError
          # Not swallowed, only overtaken by the session it ended: with the
          # session still the answers', the caller surfaces the failure
          # (nothing was sent, the answers stay pending for the next poll).
          raise if answered_keys_mutex.synchronize { current_session_epoch(srv) } == epoch
        end
        return true if answered_keys_mutex.synchronize { current_session_epoch(srv) } == epoch

        logger.warn("Task #{shown}: the session restarted before the answers were sent; they are discarded")
        false
      end

      # Bring the transport's session up before the epoch is compared, so a
      # reconnect happens on this side of the guard. A failure is not
      # swallowed: nothing is sent, and the caller (which has already
      # recorded the answers as pending) surfaces it as the ambiguous
      # delivery failure it is, so the next poll delivers them again.
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError]
      def establish_session(srv)
        srv.ensure_session_ready if srv.respond_to?(:ensure_session_ready)
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
      def dispatch_task_update(srv, task_id, input_responses, shown:, state:, lock:, timeout:, epoch: nil,
                               strict_session: false)
        keys = input_responses.keys.map(&:to_s)
        begin
          # Checked before the session is established, since it needs nothing
          # from the wire: a task id the server handed out again names a task
          # of its own, and these answers were built for the previous one.
          unless task_lifetime_current?(state)
            logger.warn("Task #{shown}: the server created a new task with this id before the answers were " \
                        'sent; they are discarded')
            drop_ended_session_update(state, lock, keys)
            return ended_session_update_result(shown, strict_session, replaced: true)
          end
          unless task_update_session_current?(srv, shown, epoch)
            drop_ended_session_update(state, lock, keys)
            return ended_session_update_result(shown, strict_session)
          end

          task_rpc(srv, 'tasks/update', { taskId: task_id, inputResponses: input_responses },
                   timeout: timeout, epoch: epoch)
          clear_pending_update(state, lock, keys)
          true
        rescue MCPClient::Errors::SessionChangedError
          # The transport refused to write into the session that replaced the
          # answers' own: nothing went out, and in the new session these keys
          # would answer a different request.
          logger.warn("Task #{shown}: the session restarted before the answers were sent; they are discarded")
          drop_ended_session_update(state, lock, keys)
          ended_session_update_result(shown, strict_session)
        rescue MCPClient::Errors::ServerError => e
          if definite_rejection?(e) && update_lock_current?(state, lock)
            release_answered_keys_in(state, keys)
            clear_pending_update(state, lock, keys)
          end
          raise if e.protocol_error?

          raise task_failure(e, srv, task_id, 'updating', method: 'tasks/update', state: state)
        rescue MCPClient::Errors::TransportError, MCPClient::Errors::ConnectionError => e
          # Ambiguous (a failure to establish the session included): the
          # payload stays pending for the next poll.
          raise MCPClient::Errors::TaskError,
                "Error updating task '#{shown}': #{sanitize_peer_log_text(e.message)}"
        end
      end

      # What a delivery the session guard (or the pin at the wire) dropped
      # reports. A wait polls again and ends on the session move it will see
      # next, so the drop is not an error for it; a caller that asked for
      # this very delivery is told that nothing was sent, rather than being
      # left to believe the server has the answers.
      # @param replaced [Boolean] the task id was handed out again rather than
      #   the session having ended
      # @return [true]
      # @raise [MCPClient::Errors::TaskError] for a direct #update_task
      def ended_session_update_result(shown, strict_session, replaced: false)
        return true unless strict_session

        if replaced
          raise MCPClient::Errors::TaskError,
                "Error updating task '#{shown}': the server created a new task with this id before the answers " \
                'were sent, so they were discarded (they belong to the task it replaced)'
        end

        raise MCPClient::Errors::TaskError,
              "Error updating task '#{shown}': the server session the answers belong to ended before they were " \
              'sent, so they were discarded (a restarted server may reuse the task id for an unrelated task)'
      end

      # Nothing was written: the keys go back and the payload is dropped, in
      # the state the answers were built from (the ended session's, which
      # dies with it).
      # @return [void]
      def drop_ended_session_update(state, lock, keys)
        return unless update_lock_current?(state, lock)

        release_answered_keys_in(state, keys)
        clear_pending_update(state, lock, keys)
      end

      # @return [void]
      def keep_pending_update(state, input_responses)
        answered_keys_mutex.synchronize do
          state[:pending_update] = (state[:pending_update] || {}).merge(input_responses)
        end
      end

      # Drop from the pending payload what this delivery settled — its own
      # keys and no others: an answer another delivery queued while this one
      # was on the wire never went out and must stay deliverable. Nothing is
      # dropped when the wait abandoned this send and a retry holds the
      # task's update lock now: what that retry left pending is not this
      # send's to clear.
      # @param keys [Array<String>] the keys this delivery carried
      # @return [void]
      def clear_pending_update(state, lock, keys)
        answered_keys_mutex.synchronize do
          next unless state[:update_mutex].equal?(lock)

          pending = state[:pending_update]
          next if pending.nil?

          remaining = pending.reject { |key, _| keys.include?(key.to_s) }
          state[:pending_update] = remaining.empty? ? nil : remaining
        end
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
