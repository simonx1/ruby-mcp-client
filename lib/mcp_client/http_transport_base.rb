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
require_relative 'http_transport_base/listen_stream'
require_relative 'http_transport_base/cache_support'
require_relative 'http_transport_base/tool_listing'
require_relative 'http_transport_base/session_recovery'

require_relative 'http_transport_base/param_headers'
require_relative 'http_transport_base/stream_recovery'
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
    include StreamRecovery
    include RequestRecovery
    include ListenStream
    include CacheSupport
    include ToolListing
    include SessionRecovery

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
      # stream. Each attempt is a request of its own, with its own id and its
      # own budget; the deadline lives in attempt_request.
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
    #
    # It is sent for the abandoned request, on that request's own thread and
    # after it, and it brings nothing back to cache: the credentials it
    # carries are whatever the host holds by now -- a rotation, a refresh --
    # and they must not stand in for the ones the abandoned request went out
    # with, which are what its failure is judged by (MCP 2026-07-28 caching,
    # cacheScope "private": a stale copy may be served only to the context
    # the failed request itself carried).
    # @param request_id [Integer] id of the abandoned request
    # @return [void]
    def send_cancellation_notification(request_id)
      notif = build_jsonrpc_notification('notifications/cancelled',
                                         { 'requestId' => request_id, 'reason' => 'Request timed out' })
      abandoned = recorded_request_authorization
      begin
        send_http_request(notif)
      ensure
        restore_request_authorization(abandoned)
      end
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

      # The session is over from here whatever the DELETE answers (every
      # outcome below clears the id), and it ends without a #cleanup: the
      # epoch moves so nothing keyed by it — the tasks extension's task ids,
      # answered and pending input keys — outlives it into the session the
      # next request establishes, which may reuse those very ids.
      bump_session_epoch
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

    # Whether tearing this connection down ends an MCP session — and with it
    # the namespace a task id and an input request key live in.
    #
    # A legacy transport's session is the one `initialize` opened (named by
    # Mcp-Session-Id when the server assigned one, unnamed otherwise): closing
    # the connection ends it, the next request opens another with a fresh
    # handshake, and the server may hand the ids of the old one out again — so
    # the epoch must move. MCP 2026-07-28 removed the handshake and the
    # session with it: a modern transport is sessionless (it never sends an
    # Mcp-Session-Id — this client only ever captures one from an initialize
    # response, which a modern server does not send), a task lives for its own
    # ttlMs in the server's own id namespace, and a reconnect resumes exactly
    # what was there before. Ending the connection there is not a task
    # namespace reset: throwing away the answered keys and the undelivered
    # tasks/update of a task that is still alive would ask the host to answer
    # an input request twice and drop an answer the server never confirmed,
    # and it would make the task's own handles refuse tasks/get, tasks/update
    # and tasks/cancel for a session that never existed. A modern server that
    # does hand a task id out again is handled where it happens, by the task
    # registry's per-creation lifetime.
    # A 2025-11-25 session is the one the server assigned with an
    # Mcp-Session-Id, and assigning one is optional ("Session Management"): a
    # legacy server that never sent the header kept no session state for this
    # client, so there is nothing for a cleanup to end there either, and its
    # durable tasks — and the handles naming them — outlive the connection
    # exactly as a modern server's do. What decides is therefore the session
    # id itself, not the era; the era only decides while it is still unknown,
    # when a session may yet be assigned and the connection counts as
    # session-bearing until the probe settles.
    # @return [Boolean]
    def session_bearing_connection?
      !@session_id.nil? || protocol_era.nil?
    end

    # Whether #cleanup ends a session. A transport nothing was ever sent
    # through has none to end: a first connect failing on its way, or a
    # transport a host restored a task handle into before anything was sent
    # — and until the era is known the connection counts as session-bearing,
    # so without this the epoch would move on that first connect and the
    # restored handle be refused for a session that never existed (and, on a
    # sessionless 2026-07-28 server, never will).
    # @return [Boolean]
    def ending_session?
      session_bearing_connection? && (@connection_established || @initialized)
    end

    # Store the session id a handshake established. A handshake that lands a
    # different id on a live session replaced it — the 404 recovery is only
    # one way there, and none of them goes through #cleanup — so the epoch
    # moves with it: task ids and input keys are per session and reusable,
    # and nothing the previous one recorded may colour the next.
    # @param session_id [String] the validated id the server assigned
    # @return [void]
    def capture_session_id(session_id)
      bump_session_epoch if @session_id && @session_id != session_id
      @session_id = session_id
    end

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
      deadline = @discover_timeout && (Process.clock_gettime(Process::CLOCK_MONOTONIC) + @discover_timeout)
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
      # The input_required rejection comes first: an InputRequiredResult need
      # only carry `requestState`, so an unfinished discover answer does not
      # have to look like a DiscoverResult at all, and testing the shape first
      # would classify it as a permissive legacy endpoint. Any other 2xx that
      # is not a DiscoverResult is a legacy answer the probe may fall back on
      # — unless it carries a resultType, which only a modern server writes
      # (see #invalid_discover_answer).
      reject_input_required_discover!(result)
      reject_task_result_discover!(result)
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
      # As late as a request pinned to a session can be held back: every
      # reconnect on the way here (ensure_connected, a retry after the
      # connection dropped) has happened by now.
      check_session_pin!
      @logger.debug("Sending JSON-RPC request: #{describe_jsonrpc_message(request)}")

      begin
        exchange_jsonrpc(request, timeout: timeout, deadline: deadline, extra_headers: extra_headers)
      # A pre-write refusal keeps its type: the late pin check inside
      # #send_http_request turns a request down (or the caller's own guard
      # does, see {MCPClient::SessionPin#guarded_writes}) and nothing was
      # written, which is not an error of executing the request.
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError,
             MCPClient::Errors::ServerError, MCPClient::Errors::TaskReplacedError
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
    # What an answered POST means: the session it was sent under may have
    # expired, its body may have been cut short, it may carry an error, or it
    # settles the request.
    # @param response [Faraday::Response] the answer as it arrived
    # @param request [Hash] the JSON-RPC message that was sent
    # @param sent_session_id [String, nil] the session id the request carried
    # @param capture [Hash] the capture state of this exchange
    # @return [Faraday::Response] the response the caller settles on
    def settle_http_response(response, request, sent_session_id, capture)
      # MCP 2026-07-28 caching: the result is bound to the Authorization
      # the request went out with, middleware included.
      note_sent_authorization(response)

      return restart_session_and_resend(request, sent_session_id) if expired_session?(response, sent_session_id)
      # A body that stopped short of its Content-Length was cut on the way,
      # exactly like a socket that died mid-body — it just did not raise.
      return truncated_body_outcome(request, capture) if capture[:mcp_short_body]

      handle_http_error_response(response) unless response.success?
      handle_successful_response(response, request)

      log_response(response)
      response
    end

    def send_http_request(request, timeout: nil, deadline: nil, extra_headers: {})
      conn = http_connection
      # The session id this request goes out with: a later 404 is attributed
      # to it, not to a fresh session another caller established meanwhile.
      # The pin is re-checked in the same critical section: a cleanup or a
      # reconnect completing between the check in #send_jsonrpc_request and
      # this capture would otherwise select the session that replaced the
      # one the request belongs to (the epoch is bumped before the session
      # is torn down and re-established under this monitor).
      sent_session_id = @mutex.synchronize do
        check_session_pin!
        @session_id
      end
      timeout, deadline = request_bounds(timeout, deadline)
      # ResponseBodyCapture fills this in as the body arrives, so the bytes
      # that made it are still here when Faraday raises instead of returning.
      capture = { mcp_body_buffer: +'', mcp_deadline: deadline,
                  mcp_stream_listener: response_stream_listener(request), mcp_inflate_limit: inflate_limit,
                  mcp_response_id: (request['id'] if request.is_a?(Hash)) }

      begin
        response = with_request_watchdog(deadline) do
          post_json_rpc(conn) do |req|
            prepare_http_request(req, request, sent_session_id, timeout, capture, extra_headers)
          end
        end
        settle_http_response(response, request, sent_session_id, capture)
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
      apply_captured_session_id(req, request, sent_session_id)
      req.body = request.to_json
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

    # Put the captured session id on the wire, whatever @session_id says by
    # now: the header must match the id this request was cleared for and is
    # attributed to at 404-handling time. It is set (or removed)
    # unconditionally — #apply_request_headers reads @session_id outside the
    # monitor, so a concurrent recovery that nils it (a 404 restart running
    # its replacement handshake) would otherwise send this pinned request
    # with no session header at all, where the server may run it in another
    # session. The handshake that establishes a session carries none.
    # @param req [Faraday::Request] the request being built
    # @param request [Hash] the JSON-RPC request
    # @param sent_session_id [String, nil] the session id captured under the monitor
    # @return [void]
    def apply_captured_session_id(req, request, sent_session_id)
      return if request['method'] == 'initialize'

      # A modern session has none at all -- the client MUST NOT send
      # Mcp-Session-Id -- so what such a request was cleared for is "no
      # session", whatever a non-conforming server got itself recorded.
      if sent_session_id && !modern?
        req.headers['Mcp-Session-Id'] = sent_session_id
      else
        req.headers.delete('Mcp-Session-Id')
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

      # Appended below any user middleware: the capture's on_complete puts the
      # streamed body back before raise_error and friends inspect it, and the
      # retry middleware above re-enters it on every attempt.
      begin
        conn.builder.use(ResponseBodyCapture)
      rescue StandardError => e
        @logger.debug("Could not install the response capture middleware: #{e.class}")
      end
      # Innermost of all, so its on_request sees the Authorization a request
      # finally carries -- after the host's middleware has run (MCP 2026-07-28
      # caching binds an entry to the credentials it was fetched with).
      record_sent_authorization(conn)

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
