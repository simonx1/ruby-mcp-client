# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # MCP 2025-11-25 session management for the HTTP transports: an HTTP 404
    # answering a request that carried an Mcp-Session-Id means the session
    # expired, and "the client MUST start a new session by sending a new
    # InitializeRequest without a session ID attached". That new session is a
    # new session in every sense — the session epoch moves with it, so
    # everything scoped to the old one (the tasks extension's task ids and
    # input keys, which the replacement session may reuse for entirely
    # different requests) dies with it.
    module SessionRecovery
      # Resend a request against the freshly restarted session — unless doing
      # so could execute a side effect twice.
      #
      # A 404 usually means the server rejected the request outright, but it
      # does not prove that: a session can expire after the tool ran.
      # Automatic session recovery is worth having for idempotent methods, and
      # would otherwise be a hole straight through the no-replay guarantee
      # that with_retry enforces for NON_IDEMPOTENT_METHODS.
      #
      # Raises ConnectionError (which with_retry never retries) so no other
      # path can turn this into a second attempt.
      # @param request [Hash] the JSON-RPC request that hit the expired session
      # @return [Faraday::Response] the response to the resent request
      # @raise [MCPClient::Errors::ConnectionError] for a non-idempotent method
      # @raise [MCPClient::Errors::SessionChangedError] for a request of the session that ended
      def resend_after_session_restart(request)
        method = request['method']
        # A request pinned to the session the 404 ended is not resent into the
        # session that replaced it: its payload (task ids, input request keys)
        # names something else there. Nothing was written, so the caller may
        # drop it — see {MCPClient::SessionPin}.
        check_session_pin!
        return send_http_request(request) unless MCPClient::JsonRpcCommon::NON_IDEMPOTENT_METHODS.include?(method)

        raise MCPClient::Errors::ConnectionError,
              "Session expired during #{method}; a new session was started but the request was NOT resent " \
              'because it may already have executed. Retry it explicitly if that is safe.'
      end

      private

      # Start a new session after the server invalidated the current one, then
      # resend the original request once. The @restarting_session flag prevents
      # a second restart if the fresh session also answers 404.
      #
      # The 404 ended a session as surely as a cleanup or a restarted stdio
      # process does, so the session epoch moves with it: a wait notices the
      # move and the bookkeeping keyed by the old session dies rather than
      # colouring a task id the new session may reuse.
      # @param request [Hash] the JSON-RPC request that hit the expired session
      # @param expired_session_id [String] the session id the 404'd request was sent with
      # @return [Faraday::Response] the response to the resent request
      def restart_session_and_resend(request, expired_session_id)
        # Serialized on the transport monitor so concurrent 404s trigger a
        # single restart; the monitor is reentrant, so the nested
        # perform_initialize/id generation inside is safe.
        @mutex.synchronize do
          # Recheck now that the monitor is held: another caller may already
          # have restarted the session while this one waited. If so, skip the
          # extra initialize and just resend against the fresh session.
          return resend_after_session_restart(request) if @session_id != expired_session_id

          @logger.warn("Session #{@session_id} no longer valid (HTTP 404); starting a new session")
          @restarting_session = true
          @session_id = nil
          @last_event_id = nil if instance_variable_defined?(:@last_event_id)
          perform_initialize
          # The handshake itself is the new session being established, and it
          # goes out on this very transport: the epoch moves once it is
          # through, before anything of the old session can be resent into the
          # new one. No other request can slip in between — the monitor is
          # held for the whole restart.
          bump_session_epoch
          resend_after_session_restart(request)
        ensure
          @restarting_session = false
        end
      end

      # Whether a 404 should trigger a session restart: only when the 404'd
      # request was actually sent with a session id and no restart is already
      # in flight (a restart's own resend answering 404 must not loop).
      # @param sent_session_id [String, nil] session id captured when the request was sent
      # @return [Boolean] true if session restart recovery applies
      def session_restart_applicable?(sent_session_id)
        return false if sent_session_id.nil?

        @mutex.synchronize { !@restarting_session }
      end
    end
  end
end
