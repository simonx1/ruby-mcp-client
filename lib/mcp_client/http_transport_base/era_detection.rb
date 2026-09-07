# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # How a probe failure is read as an era verdict: a modern server's
    # rejection of server/discover, a legacy server's ignorance of it, or an
    # exchange that never completed and therefore says nothing. Mixed into
    # {MCPClient::HttpTransportBase}; every method is private there.
    module EraDetection
      private

      # Decide what a failed server/discover probe says about the server's era,
      # recording the verdict it settles.
      # @param error [MCPClient::Errors::MCPError] the probe failure
      # @param modern_confirmed [Boolean] whether the era was already settled as modern
      # @return [Boolean] true when the server is modern despite the failure
      # @raise [MCPClient::Errors::MCPError] when the failure settles nothing or the server is modern
      def modern_despite_probe_failure?(error, modern_confirmed)
        raise modern_probe_failure(error) if modern_probe_rejection?(error)

        # A 404 with -32601 is a complete answer rather than a failed exchange:
        # the server is modern and simply has no discovery support. It answers
        # that way on every connect, so a reconnect must tolerate it exactly as
        # the first connect did — checked before the cached modern verdict,
        # which would otherwise turn the second identical answer into a failure.
        if unknown_method_404?(error)
          accept_modern_server_without_discover(error)
          return true
        end

        if error.era_inconclusive?
          # The exchange never completed (broken response stream, timeout, 5xx):
          # nothing was learned, so no verdict is recorded — a cached modern
          # verdict stays, and still rules initialize out — and the caller sees
          # the transport failure as itself. Only a genuine rejection means
          # legacy, or "modern but incompatible" once the server is known modern.
          @protocol_version = nil
          raise error
        end

        raise modern_probe_failure(error) if modern_confirmed

        treat_probe_failure_as_legacy(error)
        false
      end

      # Whether a probe failure is a modern server's rejection of the probe.
      # Streamable HTTP "Backward Compatibility" recognizes the reserved
      # errors in a **400** response; the same JSON-RPC error under 200 (a
      # permissive legacy endpoint echoing an error object) or any other 4xx
      # says nothing modern. The typed error is still raised for ordinary
      # requests whatever the status — only the era verdict is status-gated.
      # @param error [MCPClient::Errors::MCPError] the probe failure
      # @return [Boolean]
      def modern_probe_rejection?(error)
        error.respond_to?(:http_status) && error.http_status == 400 && error.modern_protocol_error_for_probe?
      end

      # A modern server reports an unknown method as HTTP 404 with -32601;
      # server/discover is mandatory, so this is a non-conforming modern server.
      # @param error [MCPClient::Errors::MCPError] the probe failure
      # @return [Boolean]
      def unknown_method_404?(error)
        # Only a well-formed error object counts (from_jsonrpc types the -32601
        # only when it carries a string message): a malformed one identifies
        # nothing, and must not be cached as a modern verdict either.
        error.is_a?(MCPClient::Errors::MethodNotFoundError) && error.modern_http_protocol_error?
      end

      # After UnsupportedProtocolVersionError, pick a mutually supported version
      # from the error's advertised list and re-issue the probe.
      # @param error [MCPClient::Errors::UnsupportedProtocolVersionError]
      # @return [void]
      def retry_discover_with_advertised_version(error)
        version = select_protocol_version(error.supported)
        unless version
          # The rejection was well-formed, so the server is modern: the typed
          # error stops MCPClient.connect from trying the legacy transports.
          raise MCPClient::Errors::ModernServerError,
                "Server rejected protocol version #{@protocol_version} and supports only " \
                "#{error.supported.join(', ')}, none of which this client speaks"
        end

        @logger.info("Server does not support #{@protocol_version}; retrying server/discover with #{version}")
        @protocol_version = version
        perform_discover
      end

      # The server is modern but the connection cannot be completed. The era is
      # cached so a later connect never falls back to initialize, and the typed
      # error survives MCPClient's transport detector instead of sending it on
      # to the legacy SSE transport.
      # @param error [StandardError] a modern-era probe failure
      # @return [MCPClient::Errors::ModernServerError]
      def modern_probe_failure(error)
        @protocol_version = nil
        @confirmed_era = :modern
        # A version rejection names what the server would accept.
        suffix = error.respond_to?(:supported_suffix) ? error.supported_suffix : ''
        MCPClient::Errors::ModernServerError.new("Server is modern but incompatible: #{error.message}#{suffix}")
      end

      # A 404 with -32601 is how a modern server reports an unknown method;
      # server/discover is mandatory, so this is a non-conforming modern
      # server. Continue with the requested version and no known capabilities.
      # @param error [MCPClient::Errors::ServerError] the -32601 error
      # @return [void]
      def accept_modern_server_without_discover(error)
        @logger.warn("Server answered server/discover with 404 -32601 (#{error.message}); treating it as a " \
                     'modern MCP server without discovery support (capabilities unknown)')
        @supported_versions = [@protocol_version]
        @capabilities = {}
        @last_discover_result = nil
        @confirmed_era = :modern
      end

      # Record that the server is legacy (the era is cached for this transport).
      # @param error [StandardError] the non-modern probe failure
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] when protocol: :modern is configured
      def treat_probe_failure_as_legacy(error)
        @protocol_version = nil
        if @protocol_mode == :modern
          raise MCPClient::Errors::ConnectionError,
                "Server did not answer server/discover as a modern MCP server (#{error.message}); it is most likely " \
                'a legacy server expecting the initialize handshake. Use protocol: :auto or :legacy to allow that.'
        end

        @logger.debug("server/discover probe failed (#{error.class}); treating the server as legacy")
        @confirmed_era = :legacy
      end
    end
  end
end
