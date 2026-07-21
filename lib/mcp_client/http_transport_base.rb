# frozen_string_literal: true

require_relative 'json_rpc_common'
require_relative 'auth/oauth_provider'

module MCPClient
  # Base module for HTTP-based JSON-RPC transports
  # Contains common functionality shared between HTTP and Streamable HTTP transports
  module HttpTransportBase
    include JsonRpcCommon

    # Lightweight response wrapper for Faraday exception payloads (Hashes),
    # so the exception path and the default path share one challenge pipeline.
    NormalizedResponse = Struct.new(:status, :headers)

    # One auth-param (name = token / quoted-string) as it appears in a
    # WWW-Authenticate challenge (RFC 7235 §2.1, optional whitespace around '=').
    AUTH_PARAM = /[A-Za-z0-9._~+-]+\s*=\s*(?:"(?:[^"\\]|\\.)*"|[^,\s]*)/
    # A run of comma/space separated auth-params anchored at the start of a
    # string. The run ends before a token that is NOT followed by '=' — the
    # auth-scheme introducing the next challenge — while commas inside quoted
    # values are consumed by the quoted-string branch, not treated as boundaries.
    AUTH_PARAMS_RUN = /\A(?:[\s,]*#{AUTH_PARAM})*/

    # Generic JSON-RPC request: send method with params and return result
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the request
    # @return [Object] result from JSON-RPC response
    # @raise [MCPClient::Errors::ConnectionError] if connection is not active
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during request execution
    def rpc_request(method, params = {})
      ensure_connected

      with_retry do
        request_id = @mutex.synchronize { @request_id += 1 }
        request = build_jsonrpc_request(method, params, request_id)
        send_jsonrpc_request(request)
      end
    end

    # Send a JSON-RPC notification (no response expected)
    # @param method [String] JSON-RPC method name
    # @param params [Hash] parameters for the notification
    # @return [void]
    def rpc_notify(method, params = {})
      ensure_connected

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

    private

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
    def send_jsonrpc_request(request)
      @logger.debug("Sending JSON-RPC request: #{request.to_json}")

      begin
        response = send_http_request(request)
        parse_response(response, request)
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        raise
      rescue JSON::ParserError => e
        raise MCPClient::Errors::TransportError, "Invalid JSON response from server: #{e.message}"
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
    def send_http_request(request)
      conn = http_connection
      # Capture the session id this request goes out with — the value
      # apply_request_headers attaches — so a later 404 is attributed to the
      # id that actually accompanied the request, not to whatever @session_id
      # holds by 404-handling time (another caller may have completed a
      # restart in between, and its fresh session must not be re-initialized).
      sent_session_id = @mutex.synchronize { @session_id }

      begin
        response = conn.post(@endpoint) do |req|
          apply_request_headers(req, request)
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

        raise MCPClient::Errors::ServerError, "Client error: HTTP 404 #{e.message}"
      rescue Faraday::ConnectionFailed => e
        raise MCPClient::Errors::ConnectionError, "Server connection lost: #{e.message}"
      rescue Faraday::Error => e
        raise MCPClient::Errors::TransportError, "HTTP request failed: #{e.message}"
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
        return send_http_request(request) if @session_id != expired_session_id

        @logger.warn("Session #{@session_id} no longer valid (HTTP 404); starting a new session")
        @restarting_session = true
        @session_id = nil
        @last_event_id = nil if instance_variable_defined?(:@last_event_id)
        perform_initialize
        send_http_request(request)
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

    # Apply headers to the HTTP request (can be overridden by subclasses)
    # @param req [Faraday::Request] HTTP request
    # @param _request [Hash] JSON-RPC request
    def apply_request_headers(req, _request)
      # Apply all headers including custom ones
      @headers.each { |k, v| req.headers[k] = v }

      # Apply OAuth authorization if available
      @logger.debug("OAuth provider present: #{@oauth_provider ? 'yes' : 'no'}")
      @oauth_provider&.apply_authorization(req)
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
      NormalizedResponse.new(status, headers)
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
        raise MCPClient::Errors::ServerError, "Client error: HTTP #{response.status}#{reason_text}"
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

      conn
    end

    # Log HTTP response (to be overridden by specific transports)
    # @param response [Faraday::Response] the HTTP response
    def log_response(response)
      @logger.debug("Received HTTP response: #{response.status} #{response.body}")
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
