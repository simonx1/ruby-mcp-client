# frozen_string_literal: true

require_relative '../errors'

module MCPClient
  class Client
    # The boundaries a wait on a task can cross, and what it may still act on
    # once it has crossed one.
    #
    # A task lives in one server session and, within it, in one lifetime of
    # its id: a restart ends it, and so does a CreateTaskResult that hands the
    # id to another task. Either way what the wait was following is gone, and
    # neither its TTL backstop, nor its pace, nor the answered keys of its
    # bookkeeping say anything about what answers to that id now. This module
    # is where the wait joins a session and a lifetime, notices that it has
    # left one, and decides what a handle it was seeded with — or an answer
    # that came back across the boundary — is still good for. Mixed into
    # {TaskSupport}, which owns the polling loop.
    module TaskWaitBoundaries
      private

      # What a wait whose session has just ended returns — or raises.
      #
      # A task lives in one server session: the session that replaced it may
      # name an entirely different task with the same id, so the wait never
      # polls it there. What the ended session already answered is another
      # matter: a terminal payload that came back from a poll the transport
      # pinned to that session is this very task's result or error (the pin
      # holds a request back until the wire, so an answer in hand is the
      # answer of the session the wait was in), and it is the outcome. Short
      # of that — no observation, a non-terminal one, or a transport that
      # cannot pin a request to its session and so cannot vouch for which
      # session answered — the wait ends: the task did not survive.
      # @param current [MCPClient::Task, nil] the observation in hand
      # @param wait [Hash]
      # @param polled_state [Hash] the bookkeeping the poll belonged to
      # @param polled_epoch [Integer, nil] the session the poll was sent in
      # @return [MCPClient::Task] the terminal task
      # @raise [MCPClient::Errors::TaskError]
      def outcome_of_ended_session(current, wait, polled_state, polled_epoch)
        # An answer counts as this wait's outcome only when it is stamped
        # with the very session the poll was pinned to: a handle carrying
        # another session's epoch describes another lifetime of the id. A
        # task id the server handed out again is not that case: the pin is
        # about sessions, and nothing on the wire tells which of the two
        # tasks under that id the answer describes — so the wait ends.
        terminal = wait[:ended] == :session && current&.terminal? &&
                   observation_of_session?(current, polled_epoch)
        # Only the bookkeeping of the session the poll asked is forgotten;
        # the replacement session's is untouched.
        forget_task_keys(wait[:srv], wait[:task_id], state: polled_state) if terminal
        end_of_task!(wait) unless terminal && session_pinning?(wait[:srv])

        # A terminal task that came back after the caller's deadline
        # (transport retries) does not rescue a timed-out wait.
        raise_if_past_caller_deadline!(wait)
        current
      end

      # End a wait whose task is gone: its server session is over and the task
      # went with it, or the server handed the task id out again — a task id
      # is unique within a session, so a fresh CreateTaskResult under it ended
      # the task this wait was following.
      # @return [void]
      # @raise [MCPClient::Errors::TaskError]
      def end_of_task!(wait)
        shown = shown_task_id(wait[:task_id])
        if wait[:ended] == :replaced
          raise MCPClient::Errors::TaskError,
                "Error waiting for task '#{shown}': the server created a new task with this id, so the task " \
                'being waited for was replaced and is gone'
        end

        raise MCPClient::Errors::TaskError,
              "Error waiting for task '#{shown}': the server session it belongs to ended " \
              'before the task did, so the task is gone (a restarted server may reuse its id for an unrelated task)'
      end

      # Whether an observation is about the session it was polled in: the
      # handle carries the session its request was pinned to. A handle
      # without one (a server that reports no session), or a poll that
      # belonged to no session, is taken at its word, as before.
      # @return [Boolean]
      def observation_of_session?(task, epoch)
        task.session_epoch.nil? || epoch.nil? || task.session_epoch == epoch
      end

      # Whether the transport holds a request back from the session that
      # replaced the one it belongs to (see {MCPClient::SessionPin}), which
      # is what makes an answer in hand provably the answer of the session
      # the wait was in.
      # @return [Boolean]
      def session_pinning?(srv)
        srv.respond_to?(:pinned_to_session)
      end

      # Point a wait at the task state of the server's current session and
      # lifetime, and report whether that is one it has not been in before.
      # What the previous session — or the previous task under this id — said
      # goes with it: its TTL backstop (createdAt + ttlMs of a task that no
      # longer exists) must not end the wait in place of the boundary being
      # crossed, and its last observation must not pace anything. A wait that
      # reserves keys afterwards reserves them in the new set, since the id
      # and its keys now name a different request.
      # @param wait [Hash]
      # @return [Boolean] whether the wait crossed a boundary, so that
      #   nothing the previous lifetime said (an observation in hand, its TTL,
      #   its pace) may be acted on
      def refresh_wait_session(wait)
        # The epoch, the lifetime and the state keyed under them are read in
        # one step, so a restart (or a creation) between them cannot leave the
        # wait pointing at one task's set while recording another's stamp.
        answered_keys_mutex.synchronize do
          epoch = current_session_epoch(wait[:srv])
          generation = task_lifetime([wait[:srv].object_id, epoch, wait[:task_id]])
          next false if wait[:epoch] == epoch && wait[:generation] == generation && wait[:answered]

          moved = wait_boundary_crossed(wait, epoch, generation)
          if moved
            wait[:ttl_deadline] = nil
            wait[:last] = nil
          end
          wait[:ended] = moved
          wait[:epoch] = epoch
          wait[:generation] = generation
          state = task_state_locked(wait[:srv], wait[:task_id], epoch)
          wait[:state] = state
          wait[:answered] = state[:answered]
          !moved.nil?
        end
      end

      # Which boundary the wait has just crossed: the session it was in ended
      # (:session), or the server handed the task id it is polling out again,
      # so the task the wait follows is over and another one answers to that
      # id now (:replaced).
      # @return [Symbol, nil] nil when the wait is still where it was
      def wait_boundary_crossed(wait, epoch, generation)
        return :session if !wait[:epoch].nil? && wait[:epoch] != epoch
        # The key is absent until the wait first joins a session: a lifetime
        # of nil is an id no creation is on the books for, and a creation
        # that gives it one has replaced the task the wait was following.
        return :replaced if wait.key?(:generation) && wait[:generation] != generation

        nil
      end

      # A handle that is already final: a DetailedTask of this server whose
      # terminal payload is authoritative (and which the server may purge any
      # moment), so there is nothing to poll. Its own lifetime's bookkeeping
      # dies with the task; a handle kept across a restart — or across a
      # creation that handed its task id out again — says nothing about what
      # answers to that id now, where the reused id may name a live task
      # whose answered keys another wait is deduplicating against.
      # @return [MCPClient::Task, nil] the task when the wait is already over
      def final_task_handle(task, srv, wait)
        return nil unless task.is_a?(MCPClient::Task) && task.detailed? && task.terminal? && task.server.equal?(srv)

        validate_terminal_task!(task)
        refresh_wait_session(wait)
        forget_task_keys(srv, wait[:task_id], state: wait[:state]) if seed_of_lifetime?(task, wait)
        task
      end

      # Whether a task handle describes the very task whose bookkeeping the
      # wait is pointing at: the session the wait joined and, within it, the
      # lifetime the id has now. A handle that names no lifetime (a bare id,
      # a handle that never came from a creation) cannot claim the live
      # occupancy of the id: what it describes may be the task that answered
      # to the id before, and the keys under it now would be another task's.
      # @return [Boolean]
      def seed_of_lifetime?(task, wait)
        seed_of_session?(task, wait) && task.task_generation == wait[:generation]
      end

      # Take the seed's hints (its TTL backstop and its pace) from a handle
      # that describes the task this wait is about: the same server, and the
      # session the wait has joined.
      # @return [void]
      def seed_wait_from_handle(task, srv, wait)
        return unless task.is_a?(MCPClient::Task) && task.server.equal?(srv) && seed_of_session?(task, wait)

        seed_ttl_deadline(task, wait)
        wait[:last] = task
      end

      # Whether a task handle may seed the wait: it must come from the
      # session the wait has joined (a handle a host kept across a restart
      # describes a task the new session knows nothing about, even when the
      # id was reused). A server that reports no session (a bare double) is
      # taken at its word, as before.
      # @return [Boolean]
      def seed_of_session?(task, wait)
        task.session_epoch.nil? || task.session_epoch == wait[:epoch]
      end
    end
  end
end
