# frozen_string_literal: true

require 'faraday'
require 'json'
require 'uri'
require_relative '../auth'

module MCPClient
  module Auth
    # OAuth 2.1 provider for MCP client authentication
    # Handles the complete OAuth flow including server discovery, client registration,
    # authorization, token exchange, and refresh
    class OAuthProvider
      # @!attribute [rw] redirect_uri
      #   @return [String] OAuth redirect URI
      # @!attribute [rw] scope
      #   @return [String, nil] OAuth scope
      # @!attribute [rw] logger
      #   @return [Logger] Logger instance
      # @!attribute [rw] storage
      #   @return [Object] Storage backend for tokens and client info
      # @!attribute [r] server_url
      #   @return [String] The MCP server URL (normalized)
      attr_accessor :redirect_uri, :scope, :logger, :storage
      attr_reader :server_url

      # Initialize OAuth provider
      # @param server_url [String] The MCP server URL (used as OAuth resource parameter)
      # @param redirect_uri [String] OAuth redirect URI (default: http://localhost:8080/callback)
      # @param scope [String, nil] OAuth scope
      # @param logger [Logger, nil] Optional logger
      # @param storage [Object, nil] Storage backend for tokens and client info
      def initialize(server_url:, redirect_uri: 'http://localhost:8080/callback', scope: nil, logger: nil, storage: nil)
        self.server_url = server_url
        self.redirect_uri = redirect_uri
        self.scope = scope
        self.logger = logger || Logger.new($stdout, level: Logger::WARN)
        self.storage = storage || MemoryStorage.new
        @http_client = create_http_client
      end

      # @param url [String] Server URL to normalize
      def server_url=(url)
        @server_url = normalize_server_url(url)
      end

      # Get current access token (refresh if needed)
      # @return [Token, nil] Current valid access token or nil
      def access_token
        token = storage.get_token(server_url)
        logger.debug("OAuth access_token: retrieved token=#{token ? 'present' : 'nil'} for #{server_url}")
        return nil unless token

        # Return token if still valid
        return token unless token.expired? || token.expires_soon?

        # Try to refresh if we have a refresh token
        refresh_token(token) if token.refresh_token
      end

      # Start OAuth authorization flow
      # @return [String] Authorization URL to redirect user to
      # @raise [MCPClient::Errors::ConnectionError] if server discovery fails
      def start_authorization_flow
        # Discover authorization server
        server_metadata = discover_authorization_server

        # Register client if needed
        client_info = get_or_register_client(server_metadata)

        # Generate PKCE parameters
        pkce = PKCE.new
        storage.set_pkce(server_url, pkce)

        # Generate state parameter
        state = SecureRandom.urlsafe_base64(32)
        storage.set_state(server_url, state)

        # Build authorization URL
        build_authorization_url(server_metadata, client_info, pkce, state)
      end

      # Complete OAuth authorization flow with authorization code
      # @param code [String] Authorization code from callback
      # @param state [String] State parameter from callback
      # @return [Token] Access token
      # @raise [MCPClient::Errors::ConnectionError] if token exchange fails
      # @raise [ArgumentError] if state parameter doesn't match
      def complete_authorization_flow(code, state)
        # Verify state parameter
        stored_state = storage.get_state(server_url)
        raise ArgumentError, 'Invalid state parameter' unless stored_state == state

        # Get stored PKCE and client info
        pkce = storage.get_pkce(server_url)
        client_info = storage.get_client_info(server_url)
        server_metadata = discover_authorization_server

        raise MCPClient::Errors::ConnectionError, 'Missing PKCE or client info' unless pkce && client_info

        # Exchange authorization code for tokens
        token = exchange_authorization_code(server_metadata, client_info, code, pkce)

        # Store token
        storage.set_token(server_url, token)

        # Clean up temporary data
        storage.delete_pkce(server_url)
        storage.delete_state(server_url)

        token
      end

      # Apply OAuth authorization to HTTP request
      # @param request [Faraday::Request] HTTP request to authorize
      # @return [void]
      def apply_authorization(request)
        token = access_token
        logger.debug("OAuth apply_authorization: token=#{token ? 'present' : 'nil'}")
        return unless token

        logger.debug("OAuth applying authorization header: #{token.to_header[0..20]}...")
        request.headers['Authorization'] = token.to_header
      end

      # Handle 401 Unauthorized response (for server discovery)
      # @param response [Faraday::Response] HTTP response
      # @return [ResourceMetadata, nil] Resource metadata if found
      def handle_unauthorized_response(response)
        www_authenticate = response.headers['WWW-Authenticate'] || response.headers['www-authenticate']
        return nil unless www_authenticate

        # Parse WWW-Authenticate header to extract resource metadata URL
        # Format: Bearer resource="https://example.com/.well-known/oauth-protected-resource"
        if (match = www_authenticate.match(/resource="([^"]+)"/))
          resource_metadata_url = match[1]
          fetch_resource_metadata(resource_metadata_url)
        end
      end

      private

      # Normalize server URL to canonical form
      # @param url [String] Server URL
      # @return [String] Normalized URL
      def normalize_server_url(url)
        uri = URI.parse(url)

        # Use lowercase scheme and host
        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase

        # Remove default ports
        uri.port = nil if (uri.scheme == 'http' && uri.port == 80) || (uri.scheme == 'https' && uri.port == 443)

        # Remove trailing slash for empty path or just "/"
        if uri.path.nil? || uri.path.empty? || uri.path == '/'
          uri.path = ''
        elsif uri.path.end_with?('/')
          uri.path = uri.path.chomp('/')
        end

        # Remove fragment
        uri.fragment = nil

        uri.to_s
      end

      # Create HTTP client for OAuth requests
      # @return [Faraday::Connection] HTTP client
      def create_http_client
        Faraday.new do |f|
          f.request :retry, max: 3, interval: 1, backoff_factor: 2
          f.options.timeout = 30
          f.adapter Faraday.default_adapter
        end
      end

      # Build OAuth discovery URL from server URL
      # Uses only the origin (scheme + host + port) for discovery
      # @param server_url [String] Full MCP server URL
      # @param discovery_type [Symbol] Type of discovery endpoint (:authorization_server or :protected_resource)
      # @return [String] Discovery URL
      def build_discovery_url(server_url, discovery_type = :authorization_server)
        uri = URI.parse(server_url)

        # Build origin URL (scheme + host + port)
        origin = "#{uri.scheme}://#{uri.host}"
        origin += ":#{uri.port}" if uri.port && !default_port?(uri)

        # Select discovery endpoint based on type
        endpoint = discovery_type == :authorization_server ? 'oauth-authorization-server' : 'oauth-protected-resource'
        "#{origin}/.well-known/#{endpoint}"
      end

      # Check if URI uses default port for its scheme
      # @param uri [URI] Parsed URI
      # @return [Boolean] true if using default port
      def default_port?(uri)
        (uri.scheme == 'http' && uri.port == 80) ||
          (uri.scheme == 'https' && uri.port == 443)
      end

      # Discover authorization server metadata
      # Tries multiple discovery patterns:
      # 1. oauth-authorization-server (MCP spec pattern - server is its own auth server)
      # 2. oauth-protected-resource (delegation pattern - points to external auth server)
      # @return [ServerMetadata] Authorization server metadata
      # @raise [MCPClient::Errors::ConnectionError] if discovery fails
      def discover_authorization_server
        # Try to get from storage first
        if (cached = storage.get_server_metadata(server_url))
          return cached
        end

        server_metadata = nil

        # Primary discovery: oauth-authorization-server (MCP spec pattern)
        # Used by servers that are both resource and authorization server
        begin
          discovery_url = build_discovery_url(server_url, :authorization_server)
          logger.debug("Attempting OAuth discovery: #{discovery_url}")
          server_metadata = fetch_server_metadata(discovery_url)
        rescue MCPClient::Errors::ConnectionError => e
          logger.debug("oauth-authorization-server discovery failed: #{e.message}")
        end

        # Fallback discovery: oauth-protected-resource (delegation pattern)
        # Used by resource servers that delegate to external authorization servers
        unless server_metadata
          begin
            discovery_url = build_discovery_url(server_url, :protected_resource)
            logger.debug("Attempting OAuth discovery: #{discovery_url}")

            resource_metadata = fetch_resource_metadata(discovery_url)
            auth_server_url = resource_metadata.authorization_servers.first

            if auth_server_url
              server_metadata = fetch_server_metadata("#{auth_server_url}/.well-known/oauth-authorization-server")
            end
          rescue MCPClient::Errors::ConnectionError => e
            logger.debug("oauth-protected-resource discovery failed: #{e.message}")
          end
        end

        unless server_metadata
          raise MCPClient::Errors::ConnectionError,
                'OAuth discovery failed: no valid endpoints found'
        end

        # Cache the metadata
        storage.set_server_metadata(server_url, server_metadata)

        server_metadata
      end

      # Fetch resource metadata from URL
      # @param url [String] Resource metadata URL
      # @return [ResourceMetadata] Resource metadata
      # @raise [MCPClient::Errors::ConnectionError] if fetch fails
      def fetch_resource_metadata(url)
        logger.debug("Fetching resource metadata from: #{url}")

        response = @http_client.get(url) do |req|
          req.headers['Accept'] = 'application/json'
        end

        unless response.success?
          raise MCPClient::Errors::ConnectionError, "Failed to fetch resource metadata: HTTP #{response.status}"
        end

        data = JSON.parse(response.body)
        ResourceMetadata.from_h(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::ConnectionError, "Invalid resource metadata JSON: #{e.message}"
      rescue Faraday::Error => e
        raise MCPClient::Errors::ConnectionError, "Network error fetching resource metadata: #{e.message}"
      end

      # Fetch authorization server metadata from URL
      # @param url [String] Server metadata URL
      # @return [ServerMetadata] Server metadata
      # @raise [MCPClient::Errors::ConnectionError] if fetch fails
      def fetch_server_metadata(url)
        logger.debug("Fetching server metadata from: #{url}")

        response = @http_client.get(url) do |req|
          req.headers['Accept'] = 'application/json'
        end

        unless response.success?
          raise MCPClient::Errors::ConnectionError, "Failed to fetch server metadata: HTTP #{response.status}"
        end

        data = JSON.parse(response.body)
        ServerMetadata.from_h(data)
      rescue JSON::ParserError => e
        raise MCPClient::Errors::ConnectionError, "Invalid server metadata JSON: #{e.message}"
      rescue Faraday::Error => e
        raise MCPClient::Errors::ConnectionError, "Network error fetching server metadata: #{e.message}"
      end

      # Get or register OAuth client
      # @param server_metadata [ServerMetadata] Authorization server metadata
      # @return [ClientInfo] Client information
      # @raise [MCPClient::Errors::ConnectionError] if registration fails
      def get_or_register_client(server_metadata)
        # Try to get existing client info from storage
        if (client_info = storage.get_client_info(server_url)) && !client_info.client_secret_expired?
          logger.debug("Using cached OAuth client for #{server_url}")
          return client_info
        end

        # Register new client if server supports it
        logger.debug('No cached client found, registering new OAuth client...')
        if server_metadata.supports_registration?
          register_client(server_metadata)
        else
          raise MCPClient::Errors::ConnectionError,
                'Dynamic client registration not supported and no client credentials found'
        end
      end

      # Register OAuth client dynamically
      # @param server_metadata [ServerMetadata] Authorization server metadata
      # @return [ClientInfo] Registered client information
      # @raise [MCPClient::Errors::ConnectionError] if registration fails
      def register_client(server_metadata)
        logger.debug("Registering OAuth client at: #{server_metadata.registration_endpoint}")

        metadata = ClientMetadata.new(
          redirect_uris: [redirect_uri],
          token_endpoint_auth_method: 'none', # Public client
          grant_types: %w[authorization_code refresh_token],
          response_types: ['code'],
          scope: scope
        )

        response = @http_client.post(server_metadata.registration_endpoint) do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['Accept'] = 'application/json'
          req.body = metadata.to_h.to_json
        end

        unless response.success?
          raise MCPClient::Errors::ConnectionError, "Client registration failed: HTTP #{response.status}"
        end

        data = JSON.parse(response.body)
        logger.debug("OAuth client registered successfully: #{data['client_id']}")

        # Parse registered metadata from server response (may differ from our request)
        registered_metadata = ClientMetadata.new(
          redirect_uris: data['redirect_uris'] || [redirect_uri],
          token_endpoint_auth_method: data['token_endpoint_auth_method'] || 'none',
          grant_types: data['grant_types'] || %w[authorization_code refresh_token],
          response_types: data['response_types'] || ['code'],
          scope: data['scope']
        )

        # Warn if server changed redirect_uri
        requested_uri = redirect_uri
        registered_uri = registered_metadata.redirect_uris.first
        if registered_uri != requested_uri
          logger.warn('OAuth server changed redirect_uri:')
          logger.warn("  Requested:  #{requested_uri}")
          logger.warn("  Registered: #{registered_uri}")
          logger.warn("Using server's registered redirect_uri for token exchange.")
        end

        client_info = ClientInfo.new(
          client_id: data['client_id'],
          client_secret: data['client_secret'],
          client_id_issued_at: data['client_id_issued_at'],
          client_secret_expires_at: data['client_secret_expires_at'],
          metadata: registered_metadata
        )

        # Store client info
        storage.set_client_info(server_url, client_info)

        client_info
      rescue JSON::ParserError => e
        raise MCPClient::Errors::ConnectionError, "Invalid client registration response: #{e.message}"
      rescue Faraday::Error => e
        raise MCPClient::Errors::ConnectionError, "Network error during client registration: #{e.message}"
      end

      # Build authorization URL
      # @param server_metadata [ServerMetadata] Server metadata
      # @param client_info [ClientInfo] Client information
      # @param pkce [PKCE] PKCE parameters
      # @param state [String] State parameter
      # @return [String] Authorization URL
      def build_authorization_url(server_metadata, client_info, pkce, state)
        # Use the redirect_uri that was actually registered
        registered_redirect_uri = client_info.metadata.redirect_uris.first

        params = {
          response_type: 'code',
          client_id: client_info.client_id,
          redirect_uri: registered_redirect_uri,
          scope: scope,
          state: state,
          code_challenge: pkce.code_challenge,
          code_challenge_method: pkce.code_challenge_method,
          resource: server_url
        }.compact

        uri = URI.parse(server_metadata.authorization_endpoint)
        uri.query = URI.encode_www_form(params)
        uri.to_s
      end

      # Exchange authorization code for access token
      # @param server_metadata [ServerMetadata] Server metadata
      # @param client_info [ClientInfo] Client information
      # @param code [String] Authorization code
      # @param pkce [PKCE] PKCE parameters
      # @return [Token] Access token
      # @raise [MCPClient::Errors::ConnectionError] if token exchange fails
      def exchange_authorization_code(server_metadata, client_info, code, pkce)
        logger.debug('Exchanging authorization code for access token')

        # Use the redirect_uri that was actually registered, not our requested one
        registered_redirect_uri = client_info.metadata.redirect_uris.first

        params = {
          grant_type: 'authorization_code',
          code: code,
          redirect_uri: registered_redirect_uri,
          client_id: client_info.client_id,
          code_verifier: pkce.code_verifier,
          resource: server_url
        }

        # Add client_secret if required by token_endpoint_auth_method
        if client_info.client_secret && client_info.metadata.token_endpoint_auth_method == 'client_secret_post'
          params[:client_secret] = client_info.client_secret
        end

        request_body = URI.encode_www_form(params)

        send_token_request = lambda do |body|
          @http_client.post(server_metadata.token_endpoint) do |req|
            req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
            req.headers['Accept'] = 'application/json'
            req.body = body
          end
        end

        response = send_token_request.call(request_body)

        unless response.success?
          redirect_hint = extract_redirect_mismatch(response.body)

          if redirect_hint && redirect_hint[:expected] && redirect_hint[:expected] != registered_redirect_uri
            expected_uri = redirect_hint[:expected]
            logger.warn(
              "Token exchange failed: redirect_uri mismatch. Retrying with server's expected value: #{expected_uri}"
            )

            params[:redirect_uri] = redirect_hint[:expected]
            retry_body = URI.encode_www_form(params)

            response = send_token_request.call(retry_body)
          end
        end

        unless response.success?
          raise MCPClient::Errors::ConnectionError, "Token exchange failed: HTTP #{response.status} - #{response.body}"
        end

        data = JSON.parse(response.body)
        Token.new(
          access_token: data['access_token'],
          token_type: data['token_type'] || 'Bearer',
          expires_in: data['expires_in'],
          scope: data['scope'],
          refresh_token: data['refresh_token']
        )
      rescue JSON::ParserError => e
        raise MCPClient::Errors::ConnectionError, "Invalid token response: #{e.message}"
      rescue Faraday::Error => e
        raise MCPClient::Errors::ConnectionError, "Network error during token exchange: #{e.message}"
      end

      # Refresh access token
      # @param token [Token] Current token with refresh token
      # @return [Token, nil] New access token or nil if refresh failed
      def refresh_token(token)
        return nil unless token.refresh_token

        logger.debug('Refreshing access token')

        server_metadata = discover_authorization_server
        client_info = storage.get_client_info(server_url)

        return nil unless server_metadata && client_info

        params = {
          grant_type: 'refresh_token',
          refresh_token: token.refresh_token,
          client_id: client_info.client_id,
          resource: server_url
        }

        # Add client_secret if required by token_endpoint_auth_method
        if client_info.client_secret && client_info.metadata.token_endpoint_auth_method == 'client_secret_post'
          params[:client_secret] = client_info.client_secret
        end

        response = @http_client.post(server_metadata.token_endpoint) do |req|
          req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
          req.headers['Accept'] = 'application/json'
          req.body = URI.encode_www_form(params)
        end

        unless response.success?
          logger.warn("Token refresh failed: HTTP #{response.status}")
          return nil
        end

        data = JSON.parse(response.body)
        new_token = Token.new(
          access_token: data['access_token'],
          token_type: data['token_type'] || 'Bearer',
          expires_in: data['expires_in'],
          scope: data['scope'],
          refresh_token: data['refresh_token'] || token.refresh_token
        )

        storage.set_token(server_url, new_token)
        new_token
      rescue JSON::ParserError => e
        logger.warn("Invalid token refresh response: #{e.message}")
        nil
      rescue Faraday::Error => e
        logger.warn("Network error during token refresh: #{e.message}")
        nil
      end

      # Extract redirect_uri mismatch details from an OAuth error response
      # @param body [String] Raw HTTP response body
      # @return [Hash, nil] Hash with :sent and :expected URIs if mismatch detected
      def extract_redirect_mismatch(body)
        data = JSON.parse(body)
        error = data['error'] || data[:error]
        return nil unless error == 'unauthorized_client'

        description = data['error_description'] || data[:error_description]
        return nil unless description.is_a?(String)

        match = description.match(%r{You sent\s+(https?://\S+)[,.]?\s+and we expected\s+(https?://\S+)}i)
        return nil unless match

        {
          sent: match[1],
          expected: match[2],
          description: description
        }
      rescue JSON::ParserError
        nil
      end

      # Simple in-memory storage for OAuth data
      class MemoryStorage
        def initialize
          @tokens = {}
          @client_infos = {}
          @server_metadata = {}
          @pkce_data = {}
          @state_data = {}
        end

        def get_token(server_url)
          @tokens[server_url]
        end

        def set_token(server_url, token)
          @tokens[server_url] = token
        end

        def get_client_info(server_url)
          @client_infos[server_url]
        end

        def set_client_info(server_url, client_info)
          @client_infos[server_url] = client_info
        end

        def get_server_metadata(server_url)
          @server_metadata[server_url]
        end

        def set_server_metadata(server_url, metadata)
          @server_metadata[server_url] = metadata
        end

        def get_pkce(server_url)
          @pkce_data[server_url]
        end

        def set_pkce(server_url, pkce)
          @pkce_data[server_url] = pkce
        end

        def delete_pkce(server_url)
          @pkce_data.delete(server_url)
        end

        def get_state(server_url)
          @state_data[server_url]
        end

        def set_state(server_url, state)
          @state_data[server_url] = state
        end

        def delete_state(server_url)
          @state_data.delete(server_url)
        end
      end
    end
  end
end
