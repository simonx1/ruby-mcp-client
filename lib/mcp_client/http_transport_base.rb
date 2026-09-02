# frozen_string_literal: true

require 'net/http'
require_relative 'json_rpc_common'
require_relative 'called_tool_definition'
require_relative 'auth/oauth_provider'
require_relative 'http_transport_base/listen_stream'
require_relative 'http_transport_base/cache_support'

require_relative 'http_transport_base/param_headers'
require_relative 'http_transport_base/request_recovery'

module MCPClient
  # Base module for HTTP-based JSON-RPC transports
  # Contains common functionality shared between HTTP and Streamable HTTP transports
  module HttpTransportBase
    include JsonRpcCommon
    include CalledToolDefinition
    include ParamHeaders
    include RequestRecovery
    include ListenStream
    include CacheSupport

    # Lightweight response wrapper for Faraday exception payloads (Hashes),
    # so the exception path and the default path share one challenge pipeline.
    NormalizedResponse = Struct.new(:status, :headers, :body)

    # One auth-param (name = token / quoted-string) as it appears in a
    # WWW-Authenticate challenge (RFC 7235 §2.1, optional whitespace around '=').
    AUTH_PARAM = /[A-Za-z0-9._~+-]+\s*=\s*(?:"(?:[^"\\]|\\.)*"|[^,\s]*)/
    # A run of comma/space separated auth-params anchored at the start of a
    # string. The run ends before a token that is NOT followed by '=' — the
    # auth-scheme introducing the next challenge — while commas inside quoted
    # values are consumed by the quoted-string branch, not treated as boundaries.
    AUTH_PARAMS_RUN = /\A(?:[\s,]*#{AUTH_PARAM})*/

    # Socket-level failures that can only occur once the exchange was under
    # way: the peer reset or closed the connection, or the response head was
    # truncated. Failures proving the request never reached the server
    # (connection refused, DNS failure, unreachable network) are deliberately
    # absent — there is nothing in flight to replace.
    INTERRUPTED_EXCHANGE_ERRORS = [
      EOFError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE,
      Net::HTTPBadResponse, Net::ProtocolError
    ].freeze

    # Generic JSON-RPC request: send method with params and return result
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the request
    # @return [Object] result from JSON-RPC response
    # @raise [MCPClient::Errors::ConnectionError] if connection is not active
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during request execution
    def rpc_request(method, params = {}, timeout: nil)
      freshly_probed = !@mutex.synchronize { @connection_established }
      ensure_connected
      if method == 'ping' && modern?
        # `ping` was removed in MCP 2026-07-28; the mandatory server/discover
        # request is the modern heartbeat, and the probe that just established
        # the connection already was one.
        return @last_discover_result if freshly_probed && @last_discover_result

        method = 'server/discover'
      end

      header_refresh_done = false
      # The multi round-trip resolver sits outside the per-attempt recovery,
      # so a retry carrying inputResponses/requestState keeps them through
      # version renegotiation, the HeaderMismatch refresh and a re-issued
      # stream.
      result = resolve_input_round_trips(method, params, timeout) do |attempt_params|
        attempt_request(method, attempt_params, timeout, header_refresh_done) { header_refresh_done = true }
      end
      # Every server/discover answer is validated and applied: a later
      # heartbeat may advertise new versions or capabilities.
      result = apply_discover_result(result) if method == 'server/discover'
      result
    end

    # One request/response exchange with its own JSON-RPC id.
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the request
    # @param timeout [Numeric, nil] per-request timeout override
    # @return [Object] result from the JSON-RPC response
    def send_request_and_parse(method, params, timeout)
      request_id = @mutex.synchronize { @request_id += 1 }
      request = build_jsonrpc_request(method, params, request_id)
      # Computed before sending so a value that cannot be mirrored fails the
      # call locally (ValidationError) rather than mid-request.
      param_headers = modern? ? mcp_param_headers(request) : {}
      send_jsonrpc_request(request, timeout: timeout, extra_headers: param_headers)
    rescue MCPClient::Errors::RequestTimeoutError
      # MCP lifecycle: on timeout the sender SHOULD cancel the abandoned
      # request. On modern Streamable HTTP closing the response stream IS the
      # cancellation signal and no notifications/cancelled is expected; legacy
      # servers still get the notification.
      send_cancellation_notification(request_id) if !modern? && cancellable_request?(method, params)
      raise
    end

    # Best-effort notifications/cancelled for a request the client stopped
    # waiting on. Failures are swallowed.
    # @param request_id [Integer] id of the abandoned request
    # @return [void]
    def send_cancellation_notification(request_id)
      notif = build_jsonrpc_notification('notifications/cancelled',
                                         { 'requestId' => request_id, 'reason' => 'Request timed out' })
      send_http_request(notif)
    rescue StandardError => e
      @logger.debug("Failed to send cancellation notification: #{e.message}")
    end

    # Send a JSON-RPC notification (no response expected)
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the notification
    # @return [void]
    def rpc_notify(method, params = {})
      ensure_connected
      if suppressed_modern_notification?(method)
        @logger.debug("Not sending #{method}: removed in MCP #{protocol_version}")
        return
      end

      notif = build_jsonrpc_notification(method, params)

      begin
        send_http_request(notif)
      rescue MCPClient::Errors::ServerError, MCPClient::Errors::ConnectionError, Faraday::ConnectionFailed => e
        raise MCPClient::Errors::TransportError, "Failed to send notification: #{e.message}"
      end
    end

    # Terminate the current session with the server
    # Sends an HTTP DELETE request with the session ID to properly close the session
    # @return [Boolean] true if termination was successful
    # @raise [MCPClient::Errors::ConnectionError] if termination fails
    def terminate_session
      return true unless @session_id

      conn = http_connection

      begin
        @logger.debug("Terminating session: #{@session_id}")
        response = conn.delete(@endpoint) do |req|
          # Apply base headers but prioritize session termination headers
          @headers.each { |k, v| req.headers[k] = v }
          req.headers['Mcp-Session-Id'] = @session_id
          req.headers['Mcp-Protocol-Version'] = @protocol_version if @protocol_version
          # MCP: authorization MUST be included in every HTTP request
          @oauth_provider&.apply_authorization(req)
          note_request_authorization(authorization_header_value(req.headers))
        end

        if response.success?
          @logger.debug("Session terminated successfully: #{@session_id}")
          @session_id = nil
          true
        else
          @logger.warn("Session termination failed with HTTP #{response.status}")
          @session_id = nil # Clear session ID even on HTTP error
          false
        end
      rescue Faraday::Error => e
        @logger.warn("Session termination request failed: #{e.message}")
        # Clear session ID even if termination request failed
        @session_id = nil
        false
      end
    end

    # Resend a request against the freshly restarted session — unless doing so
    # could execute a side effect twice.
    #
    # A 404 usually means the server rejected the request outright, but it does
    # not prove that: a session can expire after the tool ran. Automatic
    # session recovery is worth having for idempotent methods, and would
    # otherwise be a hole straight through the no-replay guarantee that
    # with_retry enforces for NON_IDEMPOTENT_METHODS.
    #
    # Raises ConnectionError (which with_retry never retries) so no other path
    # can turn this into a second attempt.
    # @param request [Hash] the JSON-RPC request that hit the expired session
    # @return [Faraday::Response] the response to the resent request
    # @raise [MCPClient::Errors::ConnectionError] for a non-idempotent method
    def resend_after_session_restart(request)
      method = request['method']
      return send_http_request(request) unless NON_IDEMPOTENT_METHODS.include?(method)

      raise MCPClient::Errors::ConnectionError,
            "Session expired during #{method}; a new session was started but the request was NOT resent " \
            'because it may already have executed. Retry it explicitly if that is safe.'
    end

    # Validate session ID format
    # Per MCP 2025-11-25, the server-assigned session ID "MUST only contain
    # visible ASCII characters (ranging from 0x21 to 0x7E)" — e.g. a UUID, a
    # JWT, or a cryptographic hash — and the client MUST echo whatever the
    # server assigned. A generous length cap guards against abuse.
    # @param session_id [String] the session ID to validate
    # @return [Boolean] true if session ID is valid
    def valid_session_id?(session_id)
      return false unless session_id.is_a?(String)

      # The 4096-char cap is header-size hygiene, not MCP grammar — the spec
      # imposes no length limit on session IDs.
      session_id.match?(/\A[\x21-\x7E]{1,4096}\z/)
    end

    # Validate the server's base URL for security
    # @param url [String] the URL to validate
    # @return [Boolean] true if URL is considered safe
    def valid_server_url?(url)
      return false unless url.is_a?(String)

      uri = URI.parse(url)

      # Only allow HTTP and HTTPS protocols
      return false unless %w[http https].include?(uri.scheme)

      # Must have a host
      return false if uri.host.nil? || uri.host.empty?

      # Don't allow localhost binding to all interfaces in production
      if uri.host == '0.0.0.0'
        @logger.warn('Server URL uses 0.0.0.0 which may be insecure. Consider using 127.0.0.1 for localhost.')
      end

      true
    rescue URI::InvalidURIError
      false
    end

    # How the server's protocol era is established (MCP 2026-07-28 Streamable
    # HTTP "Backward Compatibility"): :auto attempts a modern request first
    # and falls back to the initialize handshake on a legacy rejection,
    # :modern never falls back, :legacy never probes.
    PROTOCOL_MODES = %i[auto modern legacy].freeze

    # @return [Symbol] the configured protocol mode (:auto, :modern or :legacy)
    attr_reader :protocol_mode

    # @return [Numeric] seconds allowed for the server/discover probe
    attr_reader :discover_timeout

    private

    # Validate and store the protocol-mode options shared by the HTTP transports.
    # @param protocol [Symbol] :auto, :modern or :legacy
    # @param discover_timeout [Numeric, nil] probe timeout (default: read_timeout)
    # @return [void]
    # @raise [ArgumentError] on an unknown mode
    def configure_protocol_mode(protocol, discover_timeout)
      unless PROTOCOL_MODES.include?(protocol)
        raise ArgumentError, "protocol must be one of #{PROTOCOL_MODES.inspect}, got #{protocol.inspect}"
      end

      @protocol_mode = protocol
      @discover_timeout = discover_timeout || @read_timeout
      @confirmed_era = nil
    end

    # Establish the server's protocol era: probe with a modern request unless
    # configured legacy-only (or the server was already found to be legacy),
    # and fall back to the initialize handshake when the probe shows a legacy
    # server. The era is cached for the life of this transport.
    # @return [void]
    # @raise [MCPClient::Errors::ConnectionError] if no era can be established
    def negotiate_protocol
      return perform_initialize if @protocol_mode == :legacy || @confirmed_era == :legacy
      return if probe_modern_server

      perform_initialize
    end

    # Send the modern server/discover probe. Outcomes (MCP 2026-07-28
    # Streamable HTTP "Backward Compatibility"): a DiscoverResult is modern;
    # a recognized modern JSON-RPC error in a 400 body is modern too
    # (UnsupportedProtocolVersion is retried with an advertised version,
    # HeaderMismatch / MissingRequiredClientCapability are surfaced); a 404
    # carrying -32601 is a modern server that violates the "MUST implement
    # server/discover" rule, tolerated with unknown capabilities; any other
    # 4xx (or a 2xx carrying a non-modern JSON-RPC error) is a legacy server.
    # Only a genuine rejection settles the era: authorization failures, 5xx,
    # timeouts and a broken response stream propagate untouched, because an
    # exchange that never completed says nothing about the era. Both verdicts
    # are cached, so a confirmed modern server never gets initialize later.
    # @return [Boolean] true when the server is modern and a version was selected
    # @raise [MCPClient::Errors::ConnectionError] if the server is modern but the
    #   probe failed, or legacy while protocol: :modern is configured
    def probe_modern_server
      @protocol_version = MCPClient::LATEST_PROTOCOL_VERSION
      # A server already found to be modern never gets the initialize
      # fallback again, however a later probe fails — the mirror image of the
      # cached legacy verdict.
      modern_confirmed = @confirmed_era == :modern
      begin
        perform_discover
      rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
        # Only a well-formed rejection (data.supported present) is a
        # recognized modern error; a bare -32022 is a legacy answer.
        raise unless e.modern_protocol_error?

        # A well-formed rejection settles the era: whatever the retried probe
        # does next, this server is modern and never gets initialize.
        modern_confirmed = true
        @confirmed_era = :modern
        retry_discover_with_advertised_version(e)
      end
      @confirmed_era = :modern
      true
    rescue MCPClient::Errors::ConnectionError => e
      # A DiscoverResult (or advertised list) with no mutual version, or an
      # authorization failure: nothing was negotiated. The first of those
      # still settles the era — the server answered server/discover as a
      # modern server — so cache it, exactly as a probe failure that reaches
      # modern_probe_failure does. An authorization failure settles nothing.
      @protocol_version = nil
      @confirmed_era = :modern if e.is_a?(MCPClient::Errors::ModernServerError)
      raise
    rescue MCPClient::Errors::ServerError, MCPClient::Errors::TransportError => e
      modern_despite_probe_failure?(e, modern_confirmed)
    end

    # Decide what a failed server/discover probe says about the server's era,
    # recording the verdict it settles.
    # @param error [MCPClient::Errors::MCPError] the probe failure
    # @param modern_confirmed [Boolean] whether the era was already settled as modern
    # @return [Boolean] true when the server is modern despite the failure
    # @raise [MCPClient::Errors::MCPError] when the failure settles nothing or the server is modern
    def modern_despite_probe_failure?(error, modern_confirmed)
      raise modern_probe_failure(error) if modern_confirmed || error.modern_protocol_error_for_probe?

      if error.era_inconclusive?
        # The exchange never completed (broken response stream, timeout, 5xx):
        # nothing was learned, so no verdict is recorded and the caller sees
        # the transport failure. Only a genuine rejection means legacy.
        @protocol_version = nil
        raise error
      end

      if unknown_method_404?(error)
        accept_modern_server_without_discover(error)
        return true
      end

      treat_probe_failure_as_legacy(error)
      false
    end

    # A modern server reports an unknown method as HTTP 404 with -32601;
    # server/discover is mandatory, so this is a non-conforming modern server.
    # @param error [MCPClient::Errors::MCPError] the probe failure
    # @return [Boolean]
    def unknown_method_404?(error)
      error.is_a?(MCPClient::Errors::ServerError) &&
        error.code == MCPClient::Errors::Codes::METHOD_NOT_FOUND && error.http_status == 404
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
      MCPClient::Errors::ModernServerError.new("Server is modern but incompatible: #{error.message}")
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

    # Send server/discover and apply the DiscoverResult.
    # @return [Hash] the DiscoverResult
    def perform_discover
      result = begin
        send_discover_request
      rescue MCPClient::Errors::ResponseStreamClosedError => e
        # The probe goes through the same recovery as every other modern
        # request: a broken response stream loses it and it MUST be re-issued
        # with a new request id. Without this a probe whose stream dies would
        # surface as a plain transport failure and be mistaken for a legacy
        # rejection, permanently misclassifying a modern server.
        @logger.warn("#{e.message}; re-issuing server/discover as a new request")
        send_discover_request
      end
      # A 2xx that is not a DiscoverResult (e.g. a permissive legacy endpoint
      # answering any method) is not a modern answer: let the probe treat it
      # as legacy rather than fail on a malformed modern result.
      unless discover_result?(result)
        raise MCPClient::Errors::ServerError, 'server/discover was answered without a DiscoverResult'
      end

      apply_discover_result(result)
    rescue MCPClient::Errors::InvalidResultError => e
      raise MCPClient::Errors::ServerError, "server/discover was answered without a DiscoverResult (#{e.message})"
    end

    # One server/discover exchange with its own JSON-RPC id.
    # @return [Object] the JSON-RPC result
    def send_discover_request
      request_id = @mutex.synchronize { @request_id += 1 }
      request = build_jsonrpc_request('server/discover', {}, request_id)
      send_jsonrpc_request(request, timeout: @discover_timeout)
    end

    # @param result [Object] a JSON-RPC result
    # @return [Boolean] whether it has the DiscoverResult shape
    def discover_result?(result)
      result.is_a?(Hash) && result['supportedVersions'].is_a?(Array)
    end

    # Perform JSON-RPC initialize handshake with the MCP server
    # @return [void]
    # @raise [MCPClient::Errors::ConnectionError] if initialization fails
    def perform_initialize
      request_id = @mutex.synchronize { @request_id += 1 }
      json_rpc_request = build_jsonrpc_request('initialize', initialization_params, request_id)
      @logger.debug("Performing initialize RPC: #{json_rpc_request}")

      result = send_jsonrpc_request(json_rpc_request)
      unless result.is_a?(Hash)
        raise MCPClient::Errors::ConnectionError,
              "Server returned invalid initialize result: #{result.inspect}"
      end

      # Disconnects if the server negotiated a version we cannot speak.
      @protocol_version = validate_protocol_version!(result)
      @server_info = result['serverInfo']
      @capabilities = result['capabilities']
      @instructions = result['instructions']
    end

    # Send a JSON-RPC request to the server and wait for result
    # @param request [Hash] the JSON-RPC request
    # @return [Hash] the result of the request
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during request execution
    def send_jsonrpc_request(request, timeout: nil, extra_headers: {})
      @logger.debug("Sending JSON-RPC request: #{describe_jsonrpc_message(request)}")

      begin
        exchange_jsonrpc(request, timeout: timeout, extra_headers: extra_headers)
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        raise
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{describe_parse_error(e)}"
      rescue Errno::ECONNREFUSED => e
        raise MCPClient::Errors::ConnectionError, "Server connection lost: #{e.message}"
      rescue StandardError => e
        method_name = request['method']
        raise MCPClient::Errors::ToolCallError, "Error executing request '#{method_name}': #{e.message}"
      end
    end

    # Send an HTTP request to the server
    # @param request [Hash] the JSON-RPC request
    # @return [Faraday::Response] the HTTP response
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def send_http_request(request, timeout: nil, extra_headers: {})
      conn = http_connection
      # The session id this request goes out with: a later 404 is attributed
      # to it, not to a fresh session another caller established meanwhile.
      sent_session_id = @mutex.synchronize { @session_id }

      begin
        response = post_json_rpc(conn) do |req|
          apply_request_headers(req, request)
          apply_param_headers(req, extra_headers)
          # Per-request timeout override (MCP lifecycle: timeouts SHOULD be
          # configurable on a per-request basis)
          req.options.timeout = timeout if timeout
          # The wire header must match the captured id exactly: a restart
          # completing between capture and header attachment would otherwise
          # attach a different (or fresh) session than the one attributed to
          # this request at 404-handling time.
          if req.headers.key?('Mcp-Session-Id')
            if sent_session_id
              req.headers['Mcp-Session-Id'] = sent_session_id
            else
              req.headers.delete('Mcp-Session-Id')
            end
          end
          req.body = request.to_json
        end
        # MCP 2026-07-28 caching: the result is bound to the Authorization
        # the request went out with, middleware included.
        note_sent_authorization(response)

        # MCP 2025-11-25 session management: HTTP 404 for a request carrying
        # Mcp-Session-Id means the session expired — the client MUST start a
        # new session with a fresh InitializeRequest (without a session ID).
        if response.status == 404 && session_restart_applicable?(sent_session_id)
          return restart_session_and_resend(request, sent_session_id)
        end

        handle_http_error_response(response) unless response.success?
        handle_successful_response(response, request)

        log_response(response)
        response
      rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
        handle_auth_error(e)
      rescue Faraday::ResourceNotFound => e
        # User-configured raise_error middleware surfaces 404 as an exception;
        # apply the same session-expiry recovery as the response path.
        return restart_session_and_resend(request, sent_session_id) if session_restart_applicable?(sent_session_id)

        raise client_error_from_exception(e, 404)
      rescue Faraday::ClientError => e
        # Other 4xx raised by raise_error middleware: same body inspection as
        # the response path, so a 400 carrying a modern JSON-RPC error still
        # becomes the typed error (never a retryable TransportError).
        status = e.response.is_a?(Hash) ? (e.response[:status] || e.response['status']) : nil
        raise client_error_from_exception(e, status || 400)
      rescue Faraday::ConnectionFailed => e
        raise connection_failure_error(e, request)
      rescue Faraday::TimeoutError => e
        raise MCPClient::Errors::RequestTimeoutError, "Request timed out: #{e.message}"
      rescue Faraday::ServerError => e
        # 5xx raised by user-configured raise_error middleware. It must reach
        # callers as the same retryable error the default response path
        # raises, or a 5xx would look like a generic transport failure — and
        # a server/discover probe would read it as a legacy rejection.
        # Ordered after Faraday::TimeoutError, which subclasses ServerError.
        status = e.response.is_a?(Hash) ? (e.response[:status] || e.response['status']) : nil
        raise MCPClient::Errors::TransientServerError, "Server error: HTTP #{status || '5xx'} #{e.message}".strip
      rescue Faraday::Error => e
        raise MCPClient::Errors::TransportError, "HTTP request failed: #{e.message}"
      end
    end

    # Translate a Faraday socket failure into the MCP error the caller must
    # act on.
    #
    # A response stream that dies mid-body is what a broken stream actually
    # looks like on the wire: Faraday raises rather than handing back a
    # truncated body, so it never reaches the SSE parser that recognises a
    # stream which closed *between* events. MCP 2026-07-28 has no resumption
    # — "a broken response stream loses the in-flight request; clients MUST
    # re-issue it as a new request with a new request ID" (changelog, major
    # change 9) — and the rule does not care where the break landed. Raising
    # ResponseStreamClosedError puts both breaks on the one re-issue path.
    #
    # A failure that never got the request out, and a notification (which has
    # no response to lose), stay a plain ConnectionError.
    # @param error [Faraday::ConnectionFailed] the socket failure
    # @param request [Hash] the JSON-RPC message that was being sent
    # @return [MCPClient::Errors::MCPError] the error to raise
    def connection_failure_error(error, request)
      if modern? && request.is_a?(Hash) && request.key?('id') && interrupted_exchange?(error)
        return MCPClient::Errors::ResponseStreamClosedError.new(
          "Response stream closed before delivering the response: #{error.message}"
        )
      end

      MCPClient::Errors::ConnectionError.new("Server connection lost: #{error.message}")
    end

    # Faraday wraps every socket failure in ConnectionFailed, whether the
    # connection was never established or it broke with a request in flight;
    # only the wrapped exception distinguishes them.
    # @param error [Faraday::ConnectionFailed] the socket failure
    # @return [Boolean] true when the exchange had started when it broke
    def interrupted_exchange?(error)
      cause = (error.wrapped_exception if error.respond_to?(:wrapped_exception)) || error.cause
      INTERRUPTED_EXCHANGE_ERRORS.any? { |klass| cause.is_a?(klass) }
    end

    # Start a new session after the server invalidated the current one, then
    # resend the original request once. The @restarting_session flag prevents
    # a second restart if the fresh session also answers 404.
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

    # Drop the cached tool list and re-fetch it. Hosts layered above the
    # transport (MCPClient::Client) keep their own tool cache, so the refresh
    # is announced the way the server itself would: as a tools/list_changed
    # notification.
    # @return [void]
    def refresh_tools_cache
      invalidate_tools_cache
      list_tools
      # Announced on both hooks, in the order routing uses them, so a host
      # whose cache invalidation runs ahead of subscription deliveries is told
      # here too (see {MCPClient::ServerBase#on_cache_invalidation}).
      notify_cache_invalidation('notifications/tools/list_changed', {})
      @notification_callback&.call('notifications/tools/list_changed', {})
    end

    # Forget the cached tool list. The generation counter lets a list fetch
    # that was already in flight recognise that it is stale and not
    # overwrite a fresher list.
    # @return [void]
    def invalidate_tools_cache
      @mutex.synchronize do
        @tools = nil
        @tools_data = nil
        @tools_generation = tools_generation + 1
      end
      # The cached entry (which carries the list too) is stale as well.
      invalidate_cache(:tools)
    end

    # @return [Integer] the current tool-list generation (bump on invalidation)
    def tools_generation
      @tools_generation ||= 0
    end

    # Fetch and cache the tool list, re-fetching when the cache was
    # invalidated while the fetch was in flight (bounded).
    # @return [Array<MCPClient::Tool>]
    def fetch_tools_list
      3.times do
        generation = @mutex.synchronize { tools_generation }
        tools_data = request_tools_list
        # MCP 2026-07-28: tools with invalid x-mcp-header annotations are
        # excluded from the list on this transport.
        tools_data = reject_invalid_header_tools(tools_data) if modern?
        tools = tools_data.map { |tool_data| MCPClient::Tool.from_json(tool_data, server: self) }
        stored = store_tools(tools, generation)
        return stored if stored
      end
      raise MCPClient::Errors::TransportError, 'tools/list kept changing while it was being fetched'
    end

    # Store a freshly fetched tool list unless the cache was invalidated
    # while it was being fetched, in which case the fresher list wins.
    # @param tools [Array<MCPClient::Tool>] the fetched list
    # @param generation [Integer] tools_generation when the fetch started
    # @return [Array<MCPClient::Tool>] the list to hand to the caller
    def store_tools(tools, generation)
      @mutex.synchronize do
        if tools_generation == generation
          # A copy is kept only when its hint was attached (or the list
          # carried none): a fetch whose entry was cleared or replaced in
          # flight leaves nothing behind, so the next access fetches again.
          @tools = attach_list_value(:tools, tools) ? tools : nil
          return tools
        end

        # Invalidated while in flight: this list is stale even if nothing
        # newer was stored yet, and whatever is current may be another
        # request's list — nil makes the caller fetch again.
        nil
      end
    end

    # Drop the transport's cached list of a kind, so a re-list after a change
    # (or the HeaderMismatch refresh) really fetches the new definitions.
    # @param kind [Symbol] :tools, :prompts or :resources
    # @return [void]
    def invalidate_list_cache(kind)
      case kind
      when :tools then invalidate_tools_cache
      when :prompts
        @mutex.synchronize do
          @prompts = nil
          @prompts_data = nil
        end
      when :resources
        @mutex.synchronize do
          @resources_result = nil
          @resources_data = nil
        end
      end
    end

    # Exclude tool definitions whose x-mcp-header annotations violate the
    # transport constraints (MCP 2026-07-28: "Rejection means the client
    # MUST exclude the invalid tool from the result of tools/list"), logging
    # a warning with the tool name and the reason.
    # @param tools_data [Array<Hash>] raw tool definitions
    # @return [Array<Hash>] the acceptable definitions
    def reject_invalid_header_tools(tools_data)
      tools_data.reject do |data|
        schema = data['inputSchema'] || data[:inputSchema] || data['schema'] || data[:schema]
        errors = MCPClient::HeaderParams.validate_schema(schema)
        next false if errors.empty?

        name = data['name'] || data[:name]
        @logger.warn("Rejecting tool #{sanitize_log_text(name.to_s.inspect)}: invalid x-mcp-header annotation: " \
                     "#{sanitize_log_text(errors.join('; '))}")
        true
      end
    end

    # Build the ServerError for a 4xx surfaced as a Faraday::ClientError by
    # user-configured raise_error middleware, inspecting the body like the
    # response path does.
    # @param error [Faraday::ClientError] the middleware exception
    # @param status [Integer] the HTTP status
    # @return [MCPClient::Errors::ServerError]
    def client_error_from_exception(error, status)
      response = normalize_error_response(error.response) || NormalizedResponse.new(status, {}, nil)
      response.status ||= status
      jsonrpc_error_from_http_response(response, "Client error: HTTP #{status} #{error.message}".strip)
    end

    # POST a JSON-RPC request; a failure before any response records the
    # Authorization the request went out with when Faraday kept it.
    # @param conn [Faraday::Connection]
    # @yield [Faraday::Request]
    # @return [Faraday::Response]
    def post_json_rpc(conn, &)
      conn.post(@endpoint, &)
    rescue Faraday::Error => e
      note_failed_request_authorization(e)
      raise
    end

    # Apply headers to the HTTP request (can be overridden by subclasses)
    # @param req [Faraday::Request] HTTP request
    # @param _request [Hash] JSON-RPC request
    def apply_request_headers(req, request)
      # The freshness probe models its request on the last method sent.
      @probe_method = request['method'] if request.is_a?(Hash) && request['method'].is_a?(String)
      # Apply all headers including custom ones
      @headers.each { |k, v| req.headers[k] = v }

      # Apply OAuth authorization if available
      @logger.debug("OAuth provider present: #{@oauth_provider ? 'yes' : 'no'}")
      @oauth_provider&.apply_authorization(req)
      note_request_authorization(authorization_header_value(req.headers))
      # Middleware installed through faraday_config may still change the
      # header: the context of this attempt is known once it was sent.
      note_request_authorization_pending if @faraday_config

      # MCP 2026-07-28: every POST carries MCP-Protocol-Version (matching the
      # body's _meta), Mcp-Method and, for named requests, Mcp-Name.
      modern_request_headers(request).each { |k, v| req.headers[k] = v } if modern?
    end

    # Handle successful HTTP response (can be overridden by subclasses)
    # @param response [Faraday::Response] HTTP response
    # @param _request [Hash] JSON-RPC request
    def handle_successful_response(response, _request)
      # Default: no additional handling
    end

    # Handle authentication errors raised by user-configured raise_error
    # middleware; routes through the same challenge pipeline as the default
    # response path.
    # @param error [Faraday::UnauthorizedError, Faraday::ForbiddenError] Auth error
    # @raise [MCPClient::Errors::InsufficientScopeError, MCPClient::Errors::ConnectionError]
    def handle_auth_error(error)
      response = normalize_error_response(error.response)
      if response
        process_authorization_challenge(response)
        raise_authorization_error(response)
      end

      raise MCPClient::Errors::ConnectionError, 'Authorization failed: HTTP unknown'
    end

    # @param raw [Faraday::Response, Hash, nil] an exception's response payload
    # @return [#status, nil] a response-like object with #status and #headers
    def normalize_error_response(raw)
      return nil unless raw
      return raw if raw.respond_to?(:status) && raw.respond_to?(:headers)

      status = raw[:status] || raw['status']
      headers = raw[:headers] || raw['headers'] || {}
      body = raw[:body] || raw['body']
      NormalizedResponse.new(status, headers, body)
    end

    # Handle HTTP error responses
    # @param response [Faraday::Response] the error response
    # @raise [MCPClient::Errors::ConnectionError] for auth errors
    # @raise [MCPClient::Errors::ServerError] for server errors
    def handle_http_error_response(response)
      reason = response.respond_to?(:reason_phrase) ? response.reason_phrase : ''
      reason = reason.to_s.strip
      reason_text = reason.empty? ? '' : " #{reason}"

      case response.status
      when 401, 403
        # MCP 2025-11-25: clients MUST parse WWW-Authenticate headers on 401
        # responses and use the advertised resource metadata; the challenge's
        # scope parameter is authoritative for the next authorization.
        process_authorization_challenge(response)
        raise_authorization_error(response)
      when 400..499
        # Deterministic client errors: the request was processed/rejected and
        # will not succeed on retry, so raise a plain (non-retryable) ServerError.
        # MCP 2026-07-28 carries its protocol errors in the body of a 400
        # (HeaderMismatch, UnsupportedProtocolVersion,
        # MissingRequiredClientCapability) and an unknown method as a 404
        # with -32601, so a JSON-RPC error body becomes the typed error.
        raise jsonrpc_error_from_http_response(response, "Client error: HTTP #{response.status}#{reason_text}")
      when 500..599
        # Server-side failures are plausibly transient: raise the retryable
        # subclass so with_retry can re-attempt them.
        raise MCPClient::Errors::TransientServerError, "Server error: HTTP #{response.status}#{reason_text}"
      else
        raise MCPClient::Errors::ServerError, "HTTP error: #{response.status}#{reason_text}"
      end
    end

    # Surface a 401/403 WWW-Authenticate challenge to the OAuth provider so
    # the advertised resource metadata and challenge scope are captured before
    # the error propagates. Discovery failures must not mask the original
    # authorization error.
    # @param response [Faraday::Response] the 401/403 response
    # @return [void]
    def process_authorization_challenge(response)
      return unless @oauth_provider && response.respond_to?(:headers)

      @oauth_provider.handle_unauthorized_response(response)
    rescue StandardError => e
      @logger.debug("OAuth challenge processing failed: #{e.message}")
    end

    # Raise the appropriate error for a 401/403: an insufficient_scope 403
    # challenge (SEP-835) raises InsufficientScopeError exposing the required
    # scopes so hosts can run a step-up authorization flow.
    # @param response [Faraday::Response] the 401/403 response
    # @raise [MCPClient::Errors::InsufficientScopeError, MCPClient::Errors::ConnectionError]
    def raise_authorization_error(response)
      challenge = bearer_challenge_segment(www_authenticate_header(response))

      if response.status == 403 && insufficient_scope_challenge?(challenge)
        scope = challenge[/(?:^|[\s,])scope\s*=\s*"([^"]*)"/i, 1] ||
                challenge[/(?:^|[\s,])scope\s*=\s*([^,\s"]+)/i, 1]
        description = challenge[/(?:^|[\s,])error_description\s*=\s*"([^"]*)"/i, 1]
        raise MCPClient::Errors::InsufficientScopeError.new(
          "Authorization failed: HTTP 403 insufficient_scope#{" (required scopes: #{scope})" if scope}",
          scope: scope, error_description: description
        )
      end

      raise MCPClient::Errors::ConnectionError, "Authorization failed: HTTP #{response.status}"
    end

    # Extract the Bearer challenge's own parameter segment from a (possibly
    # multi-challenge) WWW-Authenticate header, so params belonging to other
    # schemes (e.g. `Basic error="insufficient_scope", Bearer realm="x"`) are
    # never attributed to the Bearer challenge.
    # @param header [String, nil] the WWW-Authenticate header value
    # @return [String, nil] the Bearer challenge's parameters (possibly empty),
    #   or nil when the header has no Bearer challenge
    def bearer_challenge_segment(header)
      return nil unless header

      # Locate the Bearer scheme token only OUTSIDE quoted strings: a quoted
      # value such as realm="prefix Bearer x" must not anchor the segment.
      masked = header.gsub(/"(?:\\.|[^"\\])*"/) { |q| "\"#{' ' * (q.length - 2)}\"" }
      match = masked.match(/(?:\A|[\s,])Bearer(?=[\s,]|\z)/i)
      return nil unless match

      header[match.end(0)..][AUTH_PARAMS_RUN]
    end

    # The Bearer challenge segment carries an error auth-param that is exactly
    # insufficient_scope (RFC 6750 / SEP-835); prefixed or extended tokens
    # (e.g. insufficient_scope.extra) do not match.
    # @param challenge [String, nil] the Bearer challenge segment
    # @return [Boolean]
    def insufficient_scope_challenge?(challenge)
      return false unless challenge

      challenge.match?(/(?:^|[\s,])error\s*=\s*"?insufficient_scope"?(?![\w.-])/i)
    end

    # @param response [Faraday::Response] an HTTP response
    # @return [String, nil] the WWW-Authenticate header value, if any
    def www_authenticate_header(response)
      return nil unless response.respond_to?(:headers) && response.headers

      response.headers['WWW-Authenticate'] || response.headers['www-authenticate']
    end

    # Get or create HTTP connection
    # @return [Faraday::Connection] the HTTP connection
    def http_connection
      @http_connection ||= create_http_connection
    end

    # Create a Faraday connection for HTTP requests
    # Applies default configuration first, then allows user customization via @faraday_config block
    # @return [Faraday::Connection] the configured connection
    def create_http_connection
      conn = Faraday.new(url: @base_url) do |f|
        f.request :retry, max: @max_retries, interval: @retry_backoff, backoff_factor: 2
        f.options.open_timeout = @read_timeout
        f.options.timeout = @read_timeout
        f.adapter Faraday.default_adapter
      end

      # Apply user's Faraday customizations after defaults
      @faraday_config&.call(conn)

      # MCP 2026-07-28 caching: the Authorization a request finally carries
      # is recorded after the host's middleware ran.
      record_sent_authorization(conn)
    end

    # Log HTTP response (to be overridden by specific transports)
    # @param response [Faraday::Response] the HTTP response
    def log_response(response)
      @logger.debug("Received HTTP response: #{response.status} (#{describe_body_size(response.body)})")
    end

    # Parse HTTP response (to be implemented by specific transports)
    # @param response [Faraday::Response] the HTTP response
    # @return [Hash] the parsed result
    # @raise [NotImplementedError] if not implemented by concrete transport
    def parse_response(response, _request = nil)
      raise NotImplementedError, 'Subclass must implement parse_response'
    end
  end
end
