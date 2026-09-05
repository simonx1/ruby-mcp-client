# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'zlib'
require_relative 'json_rpc_common'
require_relative 'called_tool_definition'
require_relative 'auth/oauth_provider'
require_relative 'http_transport_base/sse_event_scanner'
require_relative 'http_transport_base/stream_capture'
require_relative 'http_transport_base/era_detection'

require_relative 'http_transport_base/param_headers'
require_relative 'http_transport_base/request_recovery'

module MCPClient
  # Base module for HTTP-based JSON-RPC transports
  # Contains common functionality shared between HTTP and Streamable HTTP transports
  module HttpTransportBase
    include JsonRpcCommon
    include StreamCapture
    include EraDetection
    include CalledToolDefinition
    include ParamHeaders
    include RequestRecovery

    # Lightweight response wrapper for Faraday exception payloads (Hashes),
    # so the exception path and the default path share one challenge pipeline.
    # `context` carries the per-request capture state (see ResponseBodyCapture)
    # for a response assembled from a captured body, so the parser can tell
    # which events were already dispatched while the body was arriving.
    NormalizedResponse = Struct.new(:status, :headers, :body, :context)

    # One auth-param (name = token / quoted-string) as it appears in a
    # WWW-Authenticate challenge (RFC 7235 §2.1, optional whitespace around '=').
    AUTH_PARAM = /[A-Za-z0-9._~+-]+\s*=\s*(?:"(?:[^"\\]|\\.)*"|[^,\s]*)/
    # A run of comma/space separated auth-params anchored at the start of a
    # string. The run ends before a token that is NOT followed by '=' — the
    # auth-scheme introducing the next challenge — while commas inside quoted
    # values are consumed by the quoted-string branch, not treated as boundaries.
    AUTH_PARAMS_RUN = /\A(?:[\s,]*#{AUTH_PARAM})*/

    # Socket-level failures that can only occur once the exchange was under
    # way: the peer reset or closed the connection, the response head was
    # truncated, or the encoded body stopped short. Failures proving the
    # request never reached the server (connection refused, DNS failure,
    # unreachable network) are deliberately absent — there is nothing in
    # flight to replace.
    #
    # IOError covers EOFError and Net::HTTP's own "closed stream"; Zlib::Error
    # covers a gzip body (Streamable HTTP always offers gzip) that stops
    # before its footer; OpenSSL::SSL::SSLError covers an HTTPS body whose TLS
    # session dies mid-read, which is what production Streamable HTTP actually
    # raises — see tls_handshake_failure? for the one OpenSSL case that means
    # the exchange never started.
    INTERRUPTED_EXCHANGE_ERRORS = [
      IOError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE,
      Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error, OpenSSL::SSL::SSLError
    ].freeze

    # Faraday exception classes that can carry a broken response stream. TLS
    # failures are a sibling of ConnectionFailed, not a subclass, so both must
    # be named for an HTTPS stream to reach the re-issue path at all.
    INTERRUPTED_EXCHANGE_FARADAY_ERRORS = [Faraday::ConnectionFailed, Faraday::SSLError].freeze

    # Innermost Faraday middleware: streams the response body into a
    # per-request buffer so that
    #
    # 1. a socket failure mid-body still leaves the bytes that did arrive
    #    (Faraday discards a partially read body and raises), letting a
    #    response that was fully delivered settle its request instead of being
    #    re-issued and executed twice; and
    # 2. a deadline can be enforced while the body is arriving, which a socket
    #    timeout alone cannot do for a stream that keeps dripping keep-alives.
    #
    # It restores the buffer as the response body, and being the innermost
    # handler its on_complete runs before any user middleware (raise_error and
    # friends) looks at that body.
    class ResponseBodyCapture < Faraday::Middleware
      # @param env [Faraday::Env] the outgoing request environment
      # @return [void]
      def on_request(env)
        state = env.request&.context
        buffer = state && state[:mcp_body_buffer]
        return unless buffer

        # The retry middleware sits above this one and replays the whole inner
        # stack, so each attempt must start from an empty buffer (and from an
        # empty event scanner: the count of events dispatched while the body
        # arrived belongs to the attempt whose body is finally parsed).
        buffer.clear
        listener = state[:mcp_stream_listener]
        scanner = listener && SseEventScanner.new(max_inflated_bytes: state[:mcp_inflate_limit])
        state[:mcp_live_events] = 0
        # The adapter fills this same env in as it reads: its status is set
        # from the status line, so a salvaged answer can be rebuilt under the
        # status it really arrived with. The era rule reads a recognized
        # modern error only under the status it came with.
        state[:mcp_env] = env
        env.request.on_data = lambda do |chunk, _size, _env|
          # Before the chunk is kept, never after: bytes that arrive past the
          # deadline are not part of an answer this request may settle on, and
          # buffering them first would let the salvage hand back an answer the
          # caller had already stopped waiting for.
          deadline = state[:mcp_deadline]
          raise Faraday::TimeoutError, 'Request exceeded its deadline' if deadline && monotonic_now > deadline

          buffer << chunk.to_s
          # Only a streamed body can be measured against its Content-Length
          # here; a response the adapter hands over whole never reaches this.
          state[:mcp_streamed] = true

          next unless scanner

          # Every complete event is handed over as it arrives, so a server
          # request or a progress notification on the stream is acted on
          # while the response is still open (a server that waits for its
          # ping to be answered before sending the result would otherwise
          # deadlock against a client that answers only at EOF).
          scanner.feed(chunk.to_s) { |event| listener.call(event) }
          state[:mcp_live_events] = scanner.count
        end
      end

      # @param env [Faraday::Env] the completed request environment
      # @return [void]
      def on_complete(env)
        state = env.request&.context
        buffer = state && state[:mcp_body_buffer]
        env.body = buffer.dup if buffer && env.body.to_s.empty?
        state[:mcp_short_body] = short_body?(env, state, buffer) if state
      end

      private

      # Whether a streamed body stopped short of the length it promised.
      #
      # A Content-Length body that ends early does not raise: Net::HTTP hands
      # back what arrived as if it were whole, and only the promised length
      # says the exchange was cut. Read as a malformed body it would look like
      # a server that speaks bad JSON, and the request the stream took with it
      # would never be re-issued.
      # @param env [Faraday::Env] the completed request environment
      # @param state [Hash] the capture state
      # @param buffer [String, nil] the bytes this exchange streamed
      # @return [Boolean]
      def short_body?(env, state, buffer)
        return false unless buffer && state[:mcp_streamed]

        declared = env.response_headers && (env.response_headers['content-length'] ||
                                            env.response_headers['Content-Length'])
        return false if declared.nil? || !declared.to_s.match?(/\A\d+\z/)

        buffer.bytesize < declared.to_i
      end

      # @return [Float] a monotonic clock reading in seconds
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

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

      result = with_retry(method) do
        # One budget for the exchange and every replacement it may need: the
        # maximum timeout the spec asks for holds "regardless of progress",
        # and neither a lost stream nor a rejected header set is progress. The
        # probe already shares its deadline with its own replacement.
        budget = timeout || @read_timeout
        send_with_recovery(method, params, timeout, budget && (monotonic_now + budget))
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
    # @param deadline [Float, nil] monotonic instant this exchange and the one
    #   replacement the re-issue rule allows must finish by
    # @return [Object] result from the JSON-RPC response
    def send_request_and_parse(method, params, timeout, deadline = nil)
      request_id = @mutex.synchronize { @request_id += 1 }
      request = build_jsonrpc_request(method, params, request_id)
      # Computed before sending so a value that cannot be mirrored fails the
      # call locally (ValidationError) rather than mid-request.
      param_headers = modern? ? mcp_param_headers(request) : {}
      send_jsonrpc_request(request, timeout: timeout, deadline: deadline, extra_headers: param_headers)
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
      # MCP 2026-07-28 removed the session layer: a modern connection has no
      # session to terminate and MUST NOT send the DELETE, whatever a
      # non-conforming server (or a caller) put in @session_id.
      if modern?
        @session_id = nil
        return true
      end

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
    # 4xx, or a 2xx carrying a JSON-RPC error (reserved code or not), is a
    # legacy server.
    # Only a genuine rejection settles the era: authorization failures, 5xx,
    # timeouts and a broken response stream propagate untouched, because an
    # exchange that never completed says nothing about the era. Both verdicts
    # are cached, so a confirmed modern server never gets initialize later.
    # @return [Boolean] true when the server is modern and a version was selected
    # @raise [MCPClient::Errors::ConnectionError] if the server is modern but the
    #   probe failed, or legacy while protocol: :modern is configured
    def probe_modern_server
      @protocol_version = MCPClient::LATEST_PROTOCOL_VERSION
      # The version is a proposal until the server answers: a 2025-11-25
      # server may send a request on the probe's own response stream and wait
      # for the answer, and it gets one while the era is unknown (a modern
      # server never sends one, so answering costs nothing).
      begin_era_probe
      # A server already found to be modern never gets the initialize
      # fallback again, however a later probe fails — the mirror image of the
      # cached legacy verdict.
      modern_confirmed = @confirmed_era == :modern
      begin
        perform_discover
      rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
        # Only a well-formed rejection (data.supported present) in a 400
        # body is a recognized modern error; a bare -32022, or the same body
        # under any other status, is a legacy answer.
        raise unless modern_probe_rejection?(e)

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
    ensure
      settle_era_probe
    end

    # Send server/discover and apply the DiscoverResult.
    # @return [Hash] the DiscoverResult
    def perform_discover
      # MCP 2026-07-28 cancellation/timeouts: implementations SHOULD enforce a
      # maximum timeout regardless of progress. Faraday's socket timeout only
      # bounds the gap between bytes, so a probe answered with an endless
      # trickle of SSE keep-alives would never time out and every caller
      # waiting on the connection monitor would block with it. One deadline
      # covers the probe and its one re-issue.
      deadline = @discover_timeout && (monotonic_now + @discover_timeout)
      result = begin
        send_discover_request(deadline)
      rescue MCPClient::Errors::ResponseStreamClosedError => e
        # The probe goes through the same recovery as every other modern
        # request: a broken response stream loses it and it MUST be re-issued
        # with a new request id. Without this a probe whose stream dies would
        # surface as a plain transport failure and be mistaken for a legacy
        # rejection, permanently misclassifying a modern server.
        @logger.warn("#{e.message}; re-issuing server/discover as a new request")
        send_discover_request(deadline)
      end
      # A 2xx that is not a DiscoverResult (e.g. a permissive legacy endpoint
      # answering any method) is not a modern answer: let the probe treat it
      # as legacy rather than fail on a malformed modern result. A result
      # carrying a resultType is the exception — see #invalid_discover_answer.
      raise invalid_discover_answer(result, 'answered without a DiscoverResult') unless discover_result?(result)

      apply_discover_result(result)
    rescue MCPClient::Errors::InvalidResultError => e
      # The error carries the result it refused. One that named a resultType
      # this client does not recognize could only have been written by a
      # modern server; one that is not an object at all (a permissive legacy
      # endpoint answering any method) says nothing modern.
      raise invalid_discover_answer(e.data, "answered without a DiscoverResult (#{e.message})")
    end

    # What an unusable probe answer says about the server's era.
    #
    # `resultType` was introduced in MCP 2026-07-28, so a result carrying one
    # could only have been written by a modern server, however little else of
    # it this client can use: falling back would open the handshake that
    # revision removed, on a server that has already answered as modern. The
    # ModernServerError settles the era for good (see #probe_modern_server);
    # anything else stays a plain ServerError the probe may read as legacy.
    # @param result [Object] the probe's result
    # @param message [String] what was wrong with it
    # @return [MCPClient::Errors::MCPError] the failure to raise
    def invalid_discover_answer(result, message)
      modern = result.is_a?(Hash) && (result.key?('resultType') || result.key?(:resultType))
      return MCPClient::Errors::ServerError.new("server/discover was #{message}") unless modern

      MCPClient::Errors::ModernServerError.new("Server is modern but incompatible: server/discover was #{message}")
    end

    # One server/discover exchange with its own JSON-RPC id.
    # @param deadline [Float, nil] monotonic instant the whole probe must finish by
    # @return [Object] the JSON-RPC result
    def send_discover_request(deadline = nil)
      request_id = @mutex.synchronize { @request_id += 1 }
      request = build_jsonrpc_request('server/discover', {}, request_id)
      send_jsonrpc_request(request, timeout: @discover_timeout, deadline: deadline)
    end

    # @return [Float] a monotonic clock reading in seconds
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
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

      begin
        result = send_jsonrpc_request(json_rpc_request)
      rescue MCPClient::Errors::UnsupportedProtocolVersionError => e
        # A modern-only server SHOULD name the versions it supports when
        # rejecting initialize (basic/versioning), and this message may be
        # the only diagnostic a legacy configuration can surface. The list
        # travels in `data`, not in the peer's prose, so spell it out here
        # (as stdio does) rather than letting connect's generic wrap drop it.
        raise MCPClient::Errors::ConnectionError,
              "Initialize failed: #{e.message} (server supports: #{e.supported.join(', ')})"
      end
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
    def send_jsonrpc_request(request, timeout: nil, deadline: nil, extra_headers: {})
      @logger.debug("Sending JSON-RPC request: #{describe_jsonrpc_message(request)}")

      begin
        response = send_http_request(request, timeout: timeout, deadline: deadline, extra_headers: extra_headers)
        parse_response(response, request)
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
    def send_http_request(request, timeout: nil, deadline: nil, extra_headers: {})
      conn = http_connection
      # Capture the session id this request goes out with — the value
      # apply_request_headers attaches — so a later 404 is attributed to the
      # id that actually accompanied the request, not to whatever @session_id
      # holds by 404-handling time (another caller may have completed a
      # restart in between, and its fresh session must not be re-initialized).
      sent_session_id = @mutex.synchronize { @session_id }
      timeout, deadline = request_bounds(timeout, deadline)
      # ResponseBodyCapture fills this in as the body arrives, so the bytes
      # that made it are still here when Faraday raises instead of returning.
      capture = { mcp_body_buffer: +'', mcp_deadline: deadline,
                  mcp_stream_listener: response_stream_listener(request), mcp_inflate_limit: inflate_limit }

      begin
        response = with_request_watchdog(deadline) do
          conn.post(@endpoint) do |req|
            prepare_http_request(req, request, sent_session_id, timeout, capture, extra_headers)
          end
        end

        return restart_session_and_resend(request, sent_session_id) if expired_session?(response, sent_session_id)
        # A body that stopped short of its Content-Length was cut on the way,
        # exactly like a socket that died mid-body — it just did not raise.
        return truncated_body_outcome(request, capture) if capture[:mcp_short_body]

        handle_http_error_response(response) unless response.success?
        handle_successful_response(response, request)

        log_response(response)
        response
      rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
        handle_auth_error(e)
      rescue Faraday::ResourceNotFound => e
        # User-configured raise_error middleware surfaces 404 as an exception;
        # apply the same session-expiry recovery as the response path.
        if expired_session?(normalize_error_response(e.response) || NormalizedResponse.new(404, {}, nil),
                            sent_session_id)
          return restart_session_and_resend(request, sent_session_id)
        end

        raise client_error_from_exception(e, 404)
      rescue Faraday::ClientError => e
        # Other 4xx raised by raise_error middleware: same body inspection as
        # the response path, so a 400 carrying a modern JSON-RPC error still
        # becomes the typed error (never a retryable TransportError).
        status = e.response.is_a?(Hash) ? (e.response[:status] || e.response['status']) : nil
        raise client_error_from_exception(e, status || 400)
      rescue *INTERRUPTED_EXCHANGE_FARADAY_ERRORS => e
        # The body may have been fully delivered before the socket died; if it
        # was, that response settles the request and must not be replaced.
        salvaged = salvaged_response(capture[:mcp_body_buffer], request, e, capture)
        return settled_salvage(salvaged) if salvaged

        raise connection_failure_error(e, request)
      rescue Faraday::TimeoutError => e
        # A stream that stalled after delivering the whole final event has
        # answered the request; the timeout only tears the idle socket down.
        salvaged = salvaged_response(capture[:mcp_body_buffer], request, e, capture)
        return settled_salvage(salvaged) if salvaged

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

    # Fill in one outgoing Faraday POST: headers, capture state, timeout and body.
    # @param req [Faraday::Request] the request being built
    # @param request [Hash] the JSON-RPC message to send
    # @param sent_session_id [String, nil] the session id captured for this request
    # @param timeout [Numeric, nil] per-request timeout override
    # @param capture [Hash] ResponseBodyCapture state for this request
    # @return [void]
    def prepare_http_request(req, request, sent_session_id, timeout, capture, extra_headers = {})
      apply_request_headers(req, request)
      apply_param_headers(req, extra_headers)
      extra_headers.each { |name, value| req.headers[name] = value }
      # The capture hash itself is the request context, not a merged copy:
      # what the capture middleware records as the body arrives (the events
      # already handed to the stream listener) must be on the hash a salvaged
      # response carries, or those events would be delivered a second time.
      req.options.context = capture.replace((req.options.context || {}).merge(capture))
      # Per-request timeout override (MCP lifecycle: timeouts SHOULD be
      # configurable on a per-request basis)
      # The same bound covers connection setup: a server that accepts the
      # socket and stalls the TLS handshake never delivers a byte for the
      # deadline check to see.
      req.options.timeout = req.options.open_timeout = timeout if timeout
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
    # @param error [Faraday::ConnectionFailed, Faraday::SSLError] the socket failure
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

    # Faraday wraps every socket failure in ConnectionFailed (or, for TLS, in
    # SSLError), whether the connection was never established or it broke with
    # a request in flight; only the wrapped exception distinguishes them.
    # @param error [Faraday::ConnectionFailed, Faraday::SSLError] the socket failure
    # @return [Boolean] true when the exchange had started when it broke
    def interrupted_exchange?(error)
      cause = (error.wrapped_exception if error.respond_to?(:wrapped_exception)) || error.cause
      return false if tls_handshake_failure?(cause)

      INTERRUPTED_EXCHANGE_ERRORS.any? { |klass| cause.is_a?(klass) }
    end

    # OpenSSL names the failing operation in its message. A handshake that
    # never completed ("SSL_connect ... certificate verify failed") means the
    # request never left this client, so there is nothing in flight to
    # replace; a body that dies mid-read ("SSL_read: unexpected eof while
    # reading") is a broken response stream like any other.
    # @param cause [Exception, nil] the exception Faraday wrapped
    # @return [Boolean] true when TLS failed before the request was sent
    def tls_handshake_failure?(cause)
      cause.is_a?(OpenSSL::SSL::SSLError) && cause.message.to_s.include?('SSL_connect')
    end

    # The response that did arrive before the socket died, when the stream
    # carried this request's complete answer.
    #
    # Faraday discards a partially read body and raises, so without the
    # streamed capture a break after the final SSE event is indistinguishable
    # from a break before it — and re-issuing there would run a tools/call the
    # server already executed a second time. MCP 2026-07-28's re-issue rule is
    # about an in-flight request that was *lost*; a delivered response settles
    # its request, however the socket ends afterwards.
    # A socket that stalls after the final event until the timeout is the
    # same case from the other direction: the answer arrived, the framing
    # after it did not.
    # @param partial_body [String, nil] the bytes captured before the failure
    # @param request [Hash] the JSON-RPC message that was being sent
    # @param error [Faraday::Error] the socket failure or timeout
    # @param capture [Hash, nil] the capture state of the failed exchange
    # @return [NormalizedResponse, nil] a response carrying the delivered answer
    def salvaged_response(partial_body, request, error, capture = nil)
      return nil unless modern? && request.is_a?(Hash) && request.key?('id')
      return nil unless error.is_a?(Faraday::TimeoutError) || interrupted_exchange?(error)

      body = partial_body.to_s
      body = inflate_delivered_gzip(body) if body.b.start_with?(SseEventScanner::GZIP_MAGIC)
      return nil if body.nil? || body.empty?

      sse = sse_framed_body?(body)
      # A truncated stream's last event has no terminating blank line, so it
      # was never dispatched (HTML SSE parsing rules) and must be dropped
      # before asking whether the answer arrived.
      body = complete_sse_events(body) if sse
      return nil if body.empty? || !body_carries_response?(body, sse, request['id'])

      @logger.warn("Response stream ended after the response arrived (#{error.message}); " \
                   "keeping the delivered #{request['method']} response instead of re-issuing it")
      NormalizedResponse.new(delivered_status(capture),
                             { 'content-type' => sse ? 'text/event-stream' : 'application/json' }, body,
                             capture)
    end

    # The status a salvaged answer arrived under. A well-formed -32022 in a
    # 400 body identifies a modern server and is retried with an advertised
    # version, while the same body under 200 is a permissive legacy echo:
    # rebuilding every salvaged answer as 200 would turn the first into the
    # second. The adapter fills the captured env in as it reads, so its status
    # is the status line this response really carried.
    # @param capture [Hash, nil] the capture state of the failed exchange
    # @return [Integer]
    def delivered_status(capture)
      (capture.is_a?(Hash) && capture[:mcp_env]&.status) || 200
    end

    # What a body that stopped short of its Content-Length settles: the
    # answer if it is all there anyway (the bytes that arrived carry this
    # request's response, and the rest was framing), otherwise the loss the
    # re-issue rule is written for.
    # @param request [Hash] the JSON-RPC message that was being sent
    # @param capture [Hash] the capture state of the exchange
    # @return [NormalizedResponse] the delivered answer
    # @raise [MCPClient::Errors::MCPError] when the response was lost
    def truncated_body_outcome(request, capture)
      error = Faraday::ConnectionFailed.new(EOFError.new('response body stopped short of its Content-Length'))
      salvaged = salvaged_response(capture[:mcp_body_buffer], request, error, capture)
      return settled_salvage(salvaged) if salvaged

      raise connection_failure_error(error, request)
    end

    # A salvaged answer read the way the unbroken path reads one: an error
    # status it arrived under still becomes the typed JSON-RPC error, so a
    # recognized modern error keeps the status the era rule needs. Returning
    # it unread would settle a 400 rejection as if it were a 200 result.
    # @param salvaged [NormalizedResponse] the response the salvage rebuilt
    # @return [NormalizedResponse] the same response, once it is an answer
    # @raise [MCPClient::Errors::MCPError] whatever its status and body say
    def settled_salvage(salvaged)
      handle_http_error_response(salvaged) unless (200..299).cover?(salvaged.status.to_i)
      salvaged
    end

    # Per the SSE specification a line is terminated by CRLF, CR or LF alone;
    # normalizing to LF lets one set of framing rules serve all three.
    # @param body [String] a response body
    # @return [String] the body with LF line terminators
    def normalize_sse_newlines(body)
      without_bom(body).gsub(/\r\n|\r/, "\n")
    end

    # The UTF-8 decode step of the SSE algorithm drops one leading byte-order
    # mark; the field it precedes must still be recognized.
    # @param body [String] a response body
    # @return [String]
    def without_bom(body)
      bom = body.encoding == Encoding::BINARY ? SseEventScanner::BOM : "\uFEFF".encode(body.encoding)
      body.start_with?(bom) ? body[bom.length..] : body
    rescue EncodingError
      body
    end

    # @param body [String] a response body
    # @return [Boolean] whether the body is SSE-framed rather than plain JSON
    def sse_framed_body?(body)
      normalize_sse_newlines(body).each_line.any? { |line| line.match?(/\A(?::|(?:data|event|id|retry):)/) }
    end

    # @param body [String] an SSE body that may end mid-event
    # @return [String] the prefix up to and including the last event terminator
    def complete_sse_events(body)
      normalized = normalize_sse_newlines(body)
      index = normalized.rindex("\n\n")
      index ? normalized[0, index + 2] : +''
    end

    # Side-effect-free check for this request's answer, so the real parser
    # (which dispatches notifications and tracks event ids) still runs exactly
    # once, on the salvaged response.
    # @param body [String] the complete portion of the body
    # @param sse [Boolean] whether the body is SSE-framed
    # @param request_id [Integer, String] id of the originating request
    # @return [Boolean] whether the body carries a response to this request
    def body_carries_response?(body, sse, request_id)
      payloads = sse ? sse_data_payloads(body) : [body]
      payloads.any? do |payload|
        message = begin
          JSON.parse(payload)
        rescue JSON::ParserError
          nil
        end
        message.is_a?(Hash) && !message.key?('method') &&
          (message['id'] == request_id || message['id'].to_s == request_id.to_s)
      end
    end

    # @param body [String] an LF-normalized SSE body
    # @return [Array<String>] the joined data payload of each event
    def sse_data_payloads(body)
      body.split("\n\n").filter_map do |event|
        lines = event.lines.map(&:chomp).select { |line| line.start_with?('data:') }
        next if lines.empty?

        lines.map { |line| line.sub(/\Adata:\s*/, '') }.join("\n")
      end
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

    # Whether a 404 means the session this request went out under has expired.
    #
    # MCP 2025-11-25 session management: "When receiving HTTP 404 in response
    # to a request containing an Mcp-Session-Id, the client MUST start a new
    # session by sending a new InitializeRequest without a session ID." The
    # rule names the status and the session id and takes no exception for what
    # the body carries, so on a session negotiated under that revision the 404
    # is read as the expiry it is — a server on the era this session speaks
    # answers the session, not the request.
    #
    # Off such a session — an era never established, or a modern one whose
    # server assigned a session id 2026-07-28 gives it no reason to assign —
    # a well-formed -32601 IS the answer to this very request (unknown
    # method), and replaying it after a fresh initialize would only ask the
    # unknown method a second time.
    # @param response [#status, #body, nil] the normalized 404 response
    # @param sent_session_id [String, nil] the session id the request carried
    # @return [Boolean]
    def expired_session?(response, sent_session_id)
      return false unless response && response.status == 404
      return false unless session_restart_applicable?(sent_session_id)

      legacy_session? || !method_not_found_answer?(response)
    end

    # Whether this transport negotiated a handshake-era revision, which is
    # what makes Mcp-Session-Id — and the session-expiry rule that goes with
    # it — part of the protocol in force.
    # @return [Boolean]
    def legacy_session?
      MCPClient::LEGACY_PROTOCOL_VERSIONS.include?(@protocol_version)
    end

    # Whether a 404 body is a well-formed JSON-RPC -32601 — MCP 2026-07-28's
    # "unknown method" answer to the request itself — rather than a
    # 2025-11-25 session expiry, which answers nothing.
    #
    # Read the way every other HTTP error body is (jsonrpc_error_in_body): a
    # JSON-RPC 2.0 envelope, size-bounded, gunzipped when the response says
    # so. Anything else — an "error" member outside an envelope, an oversized
    # or undecodable body — is not an answer to this request and leaves the
    # 404 meaning what 2025-11-25 says it means.
    # @param response [#body, nil] the 404 response, if its body is readable
    # @return [Boolean]
    def method_not_found_answer?(response)
      return false unless response

      error = jsonrpc_error_in_body(response)
      return false unless error.is_a?(Hash)

      (error['code'] || error[:code]) == MCPClient::Errors::Codes::METHOD_NOT_FOUND &&
        (error['message'] || error[:message]).is_a?(String)
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
        return @tools = tools if tools_generation == generation

        # Invalidated while in flight: this list is stale even if nothing
        # newer was stored yet. Hand back whatever is current (nil makes the
        # caller fetch again).
        @tools
      end
    end

    # Keep the transport's list caches in step with the server's list-changed
    # notifications, so a re-list after a change (or the HeaderMismatch
    # refresh) really fetches the new definitions.
    # @param method [String] a notification method
    # @return [void]
    def invalidate_cache_for_notification(method)
      case method
      when 'notifications/tools/list_changed' then invalidate_tools_cache
      when 'notifications/prompts/list_changed'
        @mutex.synchronize do
          @prompts = nil
          @prompts_data = nil
        end
      when 'notifications/resources/list_changed'
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

    # Apply headers to the HTTP request (can be overridden by subclasses)
    # @param req [Faraday::Request] HTTP request
    # @param _request [Hash] JSON-RPC request
    def apply_request_headers(req, request)
      # Apply all headers including custom ones
      @headers.each { |k, v| req.headers[k] = v }

      # Apply OAuth authorization if available
      @logger.debug("OAuth provider present: #{@oauth_provider ? 'yes' : 'no'}")
      @oauth_provider&.apply_authorization(req)

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

      # Appended last, so it is the innermost handler: its on_complete puts
      # the streamed body back before any user middleware (raise_error and
      # friends) inspects it, and the retry middleware above it re-enters it
      # on every attempt.
      conn.builder.use(ResponseBodyCapture)

      conn
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
