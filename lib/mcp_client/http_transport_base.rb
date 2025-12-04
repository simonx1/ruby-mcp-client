# frozen_string_literal: true

require_relative 'json_rpc_common'
require_relative 'auth/oauth_provider'

module MCPClient
  # Base module for HTTP-based JSON-RPC transports
  # Contains common functionality shared between HTTP and Streamable HTTP transports
  module HttpTransportBase
    include JsonRpcCommon

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

    # Validate session ID format for security
    # @param session_id [String] the session ID to validate
    # @return [Boolean] true if session ID is valid
    def valid_session_id?(session_id)
      return false unless session_id.is_a?(String)
      return false if session_id.empty?

      # Session ID should be alphanumeric with optional hyphens and underscores
      # Length should be reasonable (8-128 characters)
      session_id.match?(/\A[a-zA-Z0-9\-_]{8,128}\z/)
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

    # Generate initialization parameters for HTTP MCP protocol
    # @return [Hash] the initialization parameters
    def initialization_params
      {
        'protocolVersion' => MCPClient::PROTOCOL_VERSION,
        'capabilities' => {},
        'clientInfo' => { 'name' => 'ruby-mcp-client', 'version' => MCPClient::VERSION }
      }
    end

    # Perform JSON-RPC initialize handshake with the MCP server
    # @return [void]
    # @raise [MCPClient::Errors::ConnectionError] if initialization fails
    def perform_initialize
      request_id = @mutex.synchronize { @request_id += 1 }
      json_rpc_request = build_jsonrpc_request('initialize', initialization_params, request_id)
      @logger.debug("Performing initialize RPC: #{json_rpc_request}")

      result = send_jsonrpc_request(json_rpc_request)
      return unless result.is_a?(Hash)

      @server_info = result['serverInfo']
      @capabilities = result['capabilities']
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
        parse_response(response)
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

      begin
        response = conn.post(@endpoint) do |req|
          apply_request_headers(req, request)
          req.body = request.to_json
        end

        handle_http_error_response(response) unless response.success?
        handle_successful_response(response, request)

        log_response(response)
        response
      rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
        handle_auth_error(e)
      rescue Faraday::ConnectionFailed => e
        raise MCPClient::Errors::ConnectionError, "Server connection lost: #{e.message}"
      rescue Faraday::Error => e
        raise MCPClient::Errors::TransportError, "HTTP request failed: #{e.message}"
      end
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

    # Handle authentication errors
    # @param error [Faraday::UnauthorizedError, Faraday::ForbiddenError] Auth error
    # @raise [MCPClient::Errors::ConnectionError] Connection error
    def handle_auth_error(error)
      # Handle OAuth authorization challenges
      if error.response && @oauth_provider
        resource_metadata = @oauth_provider.handle_unauthorized_response(error.response)
        if resource_metadata
          @logger.debug('Received OAuth challenge, discovered resource metadata')
          # Re-raise the error to trigger OAuth flow in calling code
          raise MCPClient::Errors::ConnectionError, "OAuth authorization required: HTTP #{error.response[:status]}"
        end
      end

      error_status = error.response ? error.response[:status] : 'unknown'
      raise MCPClient::Errors::ConnectionError, "Authorization failed: HTTP #{error_status}"
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
        raise MCPClient::Errors::ConnectionError, "Authorization failed: HTTP #{response.status}"
      when 400..499
        raise MCPClient::Errors::ServerError, "Client error: HTTP #{response.status}#{reason_text}"
      when 500..599
        raise MCPClient::Errors::ServerError, "Server error: HTTP #{response.status}#{reason_text}"
      else
        raise MCPClient::Errors::ServerError, "HTTP error: #{response.status}#{reason_text}"
      end
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
    def parse_response(response)
      raise NotImplementedError, 'Subclass must implement parse_response'
    end
  end
end
