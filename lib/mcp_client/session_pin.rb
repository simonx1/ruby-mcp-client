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

    # Refuse a request whose session has ended (see #pinned_to_session).
    # Transports call this as late as they can, immediately before the
    # request goes on the wire, so nothing of an ended session is written.
    # @return [void]
    # @raise [MCPClient::Errors::SessionChangedError]
    def check_session_pin!
      pinned = Thread.current[SESSION_PINS]&.[](self)
      return if pinned.nil?

      current = respond_to?(:session_epoch) ? session_epoch : nil
      return if current.nil? || current == pinned

      raise MCPClient::Errors::SessionChangedError,
            "The server session the request belongs to ended before it was sent (session #{pinned} is over)"
    end
  end
end
