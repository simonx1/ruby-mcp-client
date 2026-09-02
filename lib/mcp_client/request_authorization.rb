# frozen_string_literal: true

module MCPClient
  # The Authorization one request went out with, kept per thread and per
  # transport (MCP 2026-07-28 caching, cacheScope "private"): a result is
  # bound to the credentials of its own request rather than to whatever the
  # transport is configured with at the moment it is recorded.
  #
  # Every transport that can send an Authorization header keeps it the same
  # way, in a slot named after the transport's `object_id` so that
  # {MCPClient::ResultCaching#forget_transport_thread_state} finds it: a
  # worker thread that builds and discards transports must not keep one
  # entry per transport for its whole life.
  module RequestAuthorization
    # Thread-local marker meaning "this attempt has not applied its headers
    # yet": a failure before that point leaves the credentials of the
    # attempt unknown, so no private stale copy may be served for it.
    UNRECORDED_AUTHORIZATION = :unrecorded

    # Thread-local marker for "this attempt went out with no Authorization
    # at all". The anonymous context is `nil` everywhere else, and an empty
    # thread-local slot is `nil` too: a request that really was anonymous is
    # noted with this marker so that a slot a cleanup dropped reads as
    # unrecorded rather than as an anonymous request that never happened.
    ANONYMOUS_AUTHORIZATION = :anonymous

    private

    # Remember the Authorization header a request goes out with, on the
    # thread that sends it, so the result it brings back can be bound to
    # that context.
    # @param authorization [String, nil] the Authorization header of the request
    # @return [void]
    def note_request_authorization(authorization)
      Thread.current[request_authorization_key] =
        authorization_fingerprint(authorization) || ANONYMOUS_AUTHORIZATION
    end

    # Forget the header recorded before middleware ran: until the request is
    # sent (or its error reports the headers) the attempt's context is
    # unknown, so no private stale copy can be served for it.
    # @return [void]
    def note_request_authorization_pending
      Thread.current[request_authorization_key] = UNRECORDED_AUTHORIZATION
    end

    # @return [String, nil] the Authorization header of the request this thread last sent
    def request_authorization_context
      context = Thread.current[request_authorization_key]
      context.is_a?(String) ? context : nil
    end

    # @return [Boolean] whether the current attempt on this thread applied
    #   its headers. An empty slot — nothing sent yet on this thread, or a
    #   cleanup that dropped what this transport left on it — is as
    #   unrecorded as the pending marker.
    def request_authorization_recorded?
      context = Thread.current[request_authorization_key]
      !context.nil? && context != UNRECORDED_AUTHORIZATION
    end

    # @return [Symbol] the thread-local key of this transport's request authorization
    def request_authorization_key
      :"mcp_client_request_authorization_#{object_id}"
    end
  end
end
