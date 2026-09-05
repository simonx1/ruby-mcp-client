# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # The recoveries one JSON-RPC exchange may need before it is handed to
    # with_retry: the MCP 2026-07-28 re-issue of a request whose response
    # stream broke, the HeaderMismatch refresh-and-retry-once, and the
    # protocol-version renegotiation. It also owns the boundary the transport
    # crosses when it hands control to host code, since an error from the far
    # side of that boundary is what these recoveries must not act on.
    module RequestRecovery
      # Marks an error that escaped host code this transport handed control to
      # while a response was still being parsed. It belongs to whatever that
      # code was doing -- typically a request of its own -- and never to the
      # exchange whose response reached it.
      module NestedExchange; end

      private

      # One with_retry attempt: the request itself plus the two 2026-07-28
      # recoveries it may need.
      #
      # Both re-sends `retry` the same guarded block rather than running inside
      # their own rescue clause, so either recovery's re-send is still covered by
      # the other — a HeaderMismatch retry whose stream closes is re-issued, and
      # a re-issue that is rejected for its headers still refreshes tools/list.
      # Each recovery fires at most once, so the pair is bounded at three sends.
      #
      # Both flags are scoped to this attempt, which is all a tools/call ever
      # gets — with_retry refuses to re-attempt a NON_IDEMPOTENT_METHODS
      # request — and gives an idempotent method one re-issue per attempt.
      #
      # The deadline is the caller's, shared by every send this attempt makes:
      # a recovery replaces the request, it does not buy it more time.
      # @param method [String] JSON-RPC method name
      # @param params [Hash] parameters for the request
      # @param timeout [Numeric, nil] per-request timeout override
      # @param deadline [Float, nil] monotonic instant this attempt must finish by
      # @return [Object] result from the JSON-RPC response
      def send_with_recovery(method, params, timeout, deadline = nil)
        stream_reissued = false
        header_refreshed = false
        begin
          send_request_with_version_retry(method, params, timeout, deadline)
        rescue MCPClient::Errors::HeaderMismatchError => e
          # A rejection that escaped host code reached from this response -- a
          # listener's own tools/call -- rejects that request, not this one.
          # This one the server has already executed, and re-sending it on
          # someone else's error would execute it twice.
          raise if e.is_a?(NestedExchange)
          raise unless modern? && method == 'tools/call' && !header_refreshed

          header_refreshed = true
          refresh_tools_after_header_mismatch(e)
          retry
        rescue MCPClient::Errors::ResponseStreamClosedError => e
          # Modern Streamable HTTP has no resumption: "a broken response stream
          # loses the in-flight request; clients MUST re-issue it as a new
          # request with a new request ID" (2026-07-28 changelog, major change
          # 9). The rule has no exception for tools/call, and this revision
          # makes closing the response stream itself the cancellation signal —
          # the server MUST treat the broken stream as a cancellation and stop
          # work — so the re-issue is the behaviour the protocol expects rather
          # than a blind replay. Exactly one re-issue happens, for every method:
          # this flag bounds the attempt, and with_retry never re-attempts a
          # ResponseStreamClosedError, so a second broken stream surfaces
          # instead of looping.
          #
          # A stream that closed between (or inside) SSE events reaches here
          # from the parser; one that died at the socket reaches here from
          # connection_failure_error. Both are the same loss.
          #
          # A stream a listener's own request lost is that request's to
          # re-issue, and it already did: this exchange still has its response.
          raise if stream_reissued || e.is_a?(NestedExchange)

          stream_reissued = true
          @logger.warn("#{e.message}; re-issuing #{method} as a new request")
          retry
        end
      end

      # Send the request, renegotiating the protocol version once if the server
      # rejects the one it went out with.
      # @param method [String] JSON-RPC method name
      # @param params [Hash] parameters for the request
      # @param timeout [Numeric, nil] per-request timeout override
      # @param deadline [Float, nil] monotonic instant the exchange and its
      #   renegotiated replacement must finish by
      # @return [Object] result from the JSON-RPC response
      def send_request_with_version_retry(method, params, timeout, deadline = nil)
        sent_version = protocol_version
        begin
          send_request_and_parse(method, params, timeout, deadline)
        rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
          # MCP 2026-07-28 basic/versioning: select a mutually supported
          # version from the error's list and retry. The server rejected the
          # request before processing it, so a re-send cannot duplicate a side
          # effect. Compared against the version THIS request went out with:
          # a concurrent request may already have moved the transport on.
          version = select_protocol_version(e.supported)
          raise unless modern? && version && version != sent_version

          @logger.info("Server does not support protocol version #{sent_version}; " \
                       "retrying #{method} with #{version}")
          @protocol_version = version
          send_request_and_parse(method, params, timeout, deadline)
        end
      end

      # Hand control to host code -- a notification listener, a handler for a
      # server-initiated request -- reached while a response is still being
      # parsed.
      #
      # A request that code issues is an exchange of its own: it gets a slot of
      # its own for the definition it goes out under
      # (MCPClient::CalledToolDefinition), and an error escaping it is marked
      # NestedExchange so the exchange whose response parsing reached here does
      # not mistake it for its own rejection and recover from it.
      # @yield the host code
      # @return [Object] the block's value
      def dispatching_to_host(&)
        called_tool_definition_slot(&)
      rescue StandardError => e
        e.extend(NestedExchange) unless e.frozen?
        raise
      end
    end
  end
end
