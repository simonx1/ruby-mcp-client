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
      file_request_authorization(authorization_fingerprint(authorization) || ANONYMOUS_AUTHORIZATION)
    end

    # Forget the header recorded before middleware ran: until the request is
    # sent (or its error reports the headers) the attempt's context is
    # unknown, so no private stale copy can be served for it.
    # @return [void]
    def note_request_authorization_pending
      file_request_authorization(UNRECORDED_AUTHORIZATION)
    end

    # Run one exchange with a record of its own.
    #
    # A record is filed against the innermost exchange open on this thread,
    # and when that exchange ends the record it made stands again — over
    # anything a request nested inside it left behind. A host `on_complete`
    # may send a request of its own, under credentials of its own, before the
    # exchange it is nested in has bound its result or failed; the failing
    # request must still be judged by what it carried itself (MCP 2026-07-28
    # caching, cacheScope "private").
    #
    # A resend the exchange makes for itself — the one after a session
    # restart — is not nested: it opens no exchange of its own, so its
    # credentials are this exchange's, exactly as they were before.
    # @yield the exchange
    # @return [Object] the block's value
    def recording_one_exchange
      stack = (Thread.current[exchange_records_key] ||= [])
      own = []
      stack.push(own)
      begin
        yield
      ensure
        stack.pop
        Thread.current[exchange_records_key] = nil if stack.empty?
        # Written straight to the slot, never filed: this record is this
        # exchange's, and filing it would make it the enclosing exchange's
        # too — which is the very confusion the frame exists to prevent.
        Thread.current[request_authorization_key] = own.first unless own.empty?
      end
    end

    # @param record [String, Symbol, nil] the record to file for the request being sent
    # @return [void]
    def file_request_authorization(record)
      Thread.current[request_authorization_key] = record
      own = Thread.current[exchange_records_key]&.last
      own&.replace([record])
      nil
    end

    # The record this thread holds for the request it is sending, exactly as
    # it stands. Taken before a response is parsed and put back afterwards
    # ({MCPClient::HttpTransportBase::CacheSupport#exchange_jsonrpc}): the
    # parse dispatches the notifications the response carried, and a request
    # host code nests inside it would otherwise leave its own record here.
    # @return [String, Symbol, nil]
    def recorded_request_authorization
      Thread.current[request_authorization_key]
    end

    # @param record [String, Symbol, nil] a record {#recorded_request_authorization} handed out
    # @return [void]
    def restore_request_authorization(record)
      file_request_authorization(record)
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

    # @return [Symbol] the thread-local key of the exchanges open on this
    #   thread, innermost last
    def exchange_records_key
      :"mcp_client_exchange_records_#{object_id}"
    end
  end
end
