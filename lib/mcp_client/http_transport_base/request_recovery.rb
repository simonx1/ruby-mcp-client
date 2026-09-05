# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # The recoveries an attempt of a request may need before its result is
    # the caller's: renegotiating the protocol version the request went out
    # with, refreshing the tool list a HeaderMismatch rejected the headers
    # of, and re-issuing a response stream that closed without the response
    # (MCP 2026-07-28). They all re-send the same params, so they sit under
    # the multi round-trip resolver rather than around it.
    module RequestRecovery
      private

      # One attempt of a request with the transport-level recoveries that
      # re-send the same params: version renegotiation, HeaderMismatch refresh
      # and a response stream that closed without the response.
      #
      # Both re-sends `retry` the same guarded block rather than running inside
      # their own rescue clause, so either recovery's re-send is still covered by
      # the other — a HeaderMismatch retry whose stream closes is re-issued, and
      # a re-issue that is rejected for its headers still refreshes tools/list.
      # Each recovery fires at most once, so the pair is bounded at three sends.
      #
      # The refresh is spent once for the whole logical request: the caller's
      # flag rides in, and the block marks it. A re-issue is scoped to the
      # attempt, which is all a tools/call ever gets — with_retry refuses to
      # re-attempt a NON_IDEMPOTENT_METHODS request.
      # @param method [String] JSON-RPC method name
      # @param params [Hash] parameters for this attempt (may carry inputResponses)
      # @param timeout [Numeric, nil] per-request timeout override
      # @param header_refresh_done [Boolean] whether the one HeaderMismatch refresh was spent
      # @yield marks the HeaderMismatch refresh as spent
      # @return [Object] the attempt's result
      def attempt_request(method, params, timeout, header_refresh_done)
        with_retry(method) do
          stream_reissued = false
          header_refreshed = header_refresh_done
          begin
            send_request_with_version_retry(method, params, timeout)
          rescue MCPClient::Errors::HeaderMismatchError => e
            raise unless modern? && method == 'tools/call' && !header_refreshed

            header_refreshed = true
            yield
            refresh_tools_after_header_mismatch(e)
            retry
          rescue MCPClient::Errors::ResponseStreamClosedError => e
            # Modern Streamable HTTP has no resumption: "a broken response
            # stream loses the in-flight request; clients MUST re-issue it as a
            # new request with a new request ID" (2026-07-28 changelog, major
            # change 9). The rule has no exception for tools/call, and this
            # revision makes closing the response stream itself the cancellation
            # signal — the server MUST treat the broken stream as a cancellation
            # and stop work — so the re-issue is the behaviour the protocol
            # expects rather than a blind replay. Exactly one re-issue happens,
            # for every method: this flag bounds the attempt, and with_retry
            # never re-attempts a ResponseStreamClosedError, so a second broken
            # stream surfaces instead of looping.
            #
            # A stream that closed between (or inside) SSE events reaches here
            # from the parser; one that died at the socket reaches here from
            # connection_failure_error. Both are the same loss.
            raise if stream_reissued

            stream_reissued = true
            @logger.warn("#{e.message}; re-issuing #{method} as a new request")
            retry
          end
        end
      end

      # Send the request, renegotiating the protocol version once if the server
      # rejects the one it went out with.
      # @param method [String] JSON-RPC method name
      # @param params [Hash] parameters for the request
      # @param timeout [Numeric, nil] per-request timeout override
      # @return [Object] result from the JSON-RPC response
      def send_request_with_version_retry(method, params, timeout)
        sent_version = protocol_version
        begin
          send_request_and_parse(method, params, timeout)
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
          send_request_and_parse(method, params, timeout)
        end
      end
    end
  end
end
