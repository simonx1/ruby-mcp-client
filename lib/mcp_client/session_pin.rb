# frozen_string_literal: true

require_relative 'errors'

module MCPClient
  # Pinning a request to the server session it belongs to: a payload whose
  # meaning is session-scoped (task ids, input request keys) must never be
  # written into the session that replaced the one it was built in, and the
  # transports establish (and so may re-establish) their session inside the
  # very request that carries it. Mixed into the JSON-RPC transports, which
  # call {#check_session_pin!} immediately before the wire.
  module SessionPin
    # Fiber-local key of the session pins in effect (see #pinned_to_session).
    SESSION_PINS = :mcp_client_session_pins
    # Fiber-local key of the extra pre-write guards (see #guarded_writes).
    WRITE_GUARDS = :mcp_client_write_guards

    # Run the block with every request this thread sends through this server
    # pinned to `epoch` (a {MCPClient::ServerBase#session_epoch} reading):
    # the transport refuses to write once that session has ended, however the
    # reconnect that ended it got in — a lazy `ensure_initialized` /
    # `ensure_connected` inside the very request, a transport retry, a
    # concurrent cleanup. A session-scoped payload (the tasks extension's
    # `inputResponses`, whose task ids and input keys are per session and
    # reusable) must never reach the session that replaced the one it was
    # built in, where it could answer an unrelated request.
    # @param epoch [Integer, nil] the session the requests belong to (nil: no pin)
    # @return [Object] the block's value
    def pinned_to_session(epoch)
      return yield if epoch.nil?

      previous = Thread.current[SESSION_PINS]
      pins = {}.compare_by_identity
      previous&.each { |server, pinned| pins[server] = pinned }
      pins[self] = epoch
      Thread.current[SESSION_PINS] = pins
      begin
        yield
      ensure
        Thread.current[SESSION_PINS] = previous
      end
    end

    # Run the block with `guard` called immediately before every request this
    # thread writes through this server, at the very point the session pin is
    # checked (see {#check_session_pin!}). A request whose payload a
    # concurrent answer can invalidate — the tasks extension's task ids, which
    # a fresh CreateTaskResult hands to a different task — is guarded there
    # rather than before the request is built: everything the client records
    # up to the wire is seen, so a decision taken earlier cannot leave the
    # request going out for a task that no longer exists. Only one guard is in
    # force per server; a nested one replaces it for the duration of its block.
    # @param guard [#call] raises to refuse the write
    # @return [Object] the block's value
    def guarded_writes(guard)
      previous = Thread.current[WRITE_GUARDS]
      guards = {}.compare_by_identity
      previous&.each { |server, guarded| guards[server] = guarded }
      guards[self] = guard
      Thread.current[WRITE_GUARDS] = guards
      begin
        yield
      ensure
        Thread.current[WRITE_GUARDS] = previous
      end
    end

    # Run the block with this server's pin — and its pre-write guard — lifted
    # for this thread: the request that establishes the session replacing an
    # ended one is not part of the session it replaces, and the pin (whose
    # epoch the end of that session has just invalidated) would otherwise
    # refuse the very handshake the caller is in the middle of performing.
    # @return [Object] the block's value
    def unpinned_session
      previous = Thread.current[SESSION_PINS]
      guarded = Thread.current[WRITE_GUARDS]
      return yield if (previous.nil? || !previous.key?(self)) && (guarded.nil? || !guarded.key?(self))

      Thread.current[SESSION_PINS] = without_self(previous)
      Thread.current[WRITE_GUARDS] = without_self(guarded)
      begin
        yield
      ensure
        Thread.current[SESSION_PINS] = previous
        Thread.current[WRITE_GUARDS] = guarded
      end
    end

    # Refuse a request whose session has ended (see #pinned_to_session), or
    # which the caller's own guard turns down (see #guarded_writes).
    # Transports call this as late as they can, immediately before the
    # request goes on the wire, so nothing of an ended session is written.
    # @return [void]
    # @raise [MCPClient::Errors::SessionChangedError]
    def check_session_pin!
      Thread.current[WRITE_GUARDS]&.[](self)&.call
      pinned = Thread.current[SESSION_PINS]&.[](self)
      return if pinned.nil?

      current = respond_to?(:session_epoch) ? session_epoch : nil
      return if current.nil? || current == pinned

      raise MCPClient::Errors::SessionChangedError,
            "The server session the request belongs to ended before it was sent (session #{pinned} is over)"
    end

    private

    # A copy of a per-server fiber-local map without this server's entry.
    # @return [Hash, nil]
    def without_self(entries)
      return entries if entries.nil?

      copy = {}.compare_by_identity
      entries.each { |server, value| copy[server] = value unless server.equal?(self) }
      copy
    end
  end
end
