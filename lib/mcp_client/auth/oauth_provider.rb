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
      #   @return [String, Symbol, nil] OAuth scope (use :all for all server-supported scopes)
      # @!attribute [rw] logger
      #   @return [Logger] Logger instance
      # @!attribute [rw] storage
      #   @return [Object] Storage backend for tokens and client info
      # @!attribute [r] server_url
      #   @return [String] The MCP server URL (normalized)
      # @!attribute [r] client_id_metadata_url
      #   @return [String, nil] HTTPS URL of this client's Client ID Metadata Document (SEP-991)
      attr_accessor :redirect_uri, :scope, :logger, :storage
      attr_reader :server_url, :client_id_metadata_url

      # Initialize OAuth provider
      # @param server_url [String] The MCP server URL (used as OAuth resource parameter)
      # @param redirect_uri [String] OAuth redirect URI (default: http://localhost:8080/callback)
      # @param scope [String, Symbol, nil] OAuth scope (use :all for all server-supported scopes)
      # @param logger [Logger, nil] Optional logger
      # @param storage [Object, nil] Storage backend for tokens and client info
      # @param client_metadata [Hash] Extra OIDC client metadata fields for DCR registration.
      #   Supported keys: :client_name, :client_uri, :logo_uri, :tos_uri, :policy_uri, :contacts
      # @param client_id_metadata_url [String, nil] HTTPS URL identifying this client per
      #   MCP 2025-11-25 Client ID Metadata Documents (SEP-991). The URL doubles as the OAuth
      #   client_id when the authorization server advertises client_id_metadata_document_supported,
      #   skipping dynamic registration. Hosting the metadata JSON at that URL is the
      #   application's responsibility.
      # @raise [ArgumentError] if client_id_metadata_url is not an HTTPS URL with a path component
      def initialize(server_url:, redirect_uri: 'http://localhost:8080/callback', scope: nil, logger: nil, storage: nil,
                     client_metadata: {}, client_id_metadata_url: nil)
        self.server_url = server_url
        self.redirect_uri = redirect_uri
        self.scope = scope
        self.logger = logger || Logger.new($stdout, level: Logger::WARN)
        self.storage = storage || MemoryStorage.new
        self.client_id_metadata_url = client_id_metadata_url
        @extra_client_metadata = client_metadata
        @http_client = create_http_client
        # Protected resource metadata learned from a 401 WWW-Authenticate
        # challenge, reused by discovery so a challenge-advertised metadata URL
        # is not re-derived (and possibly missed).
        @challenge_resource_metadata = nil
      end

      # @param url [String] Server URL to normalize
      def server_url=(url)
        @server_url = normalize_server_url(url)
      end

      # Set the Client ID Metadata Document URL (SEP-991), validating it per the
      # MCP spec: the client_id URL MUST use the "https" scheme and contain a
      # path component (e.g. https://example.com/client.json).
      # @param url [String, nil] HTTPS URL of this client's metadata document, or nil to clear
      # @raise [ArgumentError] if the URL is not HTTPS or lacks a path component
      def client_id_metadata_url=(url)
        @client_id_metadata_url = url.nil? ? nil : validate_client_id_metadata_url(url)
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

      # Return the scopes supported by the authorization server
      # Discovers server metadata and returns the scopes_supported list.
      # @return [Array<String>] supported scopes, or empty array if not advertised
      # @raise [MCPClient::Errors::ConnectionError] if server discovery fails
      def supported_scopes
        @supported_scopes ||= discover_authorization_server.scopes_supported || []
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

        # MCP 2025-11-25: "Clients MUST treat the scopes provided in the
        # challenge as authoritative for satisfying the current request" —
        # including resetting a previously challenged scope when the current
        # challenge carries none.
        @challenge_scope = extract_challenge_param(www_authenticate, 'scope')

        url = extract_resource_metadata_url(www_authenticate)
        return nil unless url

        # Remember the advertised URL even if the fetch below fails, so a
        # later discovery retries it instead of probing well-known URIs the
        # challenge already superseded.
        @challenge_metadata_url = url

        # This URL was explicitly advertised by the 401 challenge, so a 404 is a
        # misconfiguration to surface (strict), not a speculative miss to skip.
        metadata = fetch_resource_metadata(url, strict: true)
        # Reuse this challenge-advertised metadata during the subsequent OAuth
        # flow instead of re-deriving (and possibly missing) the well-known URL.
        @challenge_resource_metadata = metadata
        metadata
      end

      # Extract the protected-resource-metadata URL from a WWW-Authenticate header.
      # Per RFC 9728 the parameter is `resource_metadata`; a legacy `resource`
      # parameter is accepted as a fallback for older servers.
      # @param header [String] the WWW-Authenticate header value
      # @return [String, nil] the metadata URL if present
      def extract_resource_metadata_url(header)
        # Auth-params may include optional whitespace around '=' (RFC 7235).
        # Quoted form: resource_metadata = "https://..."
        if (m = header.match(/resource_metadata\s*=\s*"([^"]+)"/))
          return m[1]
        end

        # Unquoted token form: resource_metadata = https://...
        if (m = header.match(/resource_metadata\s*=\s*([^,\s]+)/))
          return m[1]
        end

        # Legacy fallback: resource="https://..."
        header.match(/resource\s*=\s*"([^"]+)"/)&.captures&.first
      end

      # Extract an auth-param value from a WWW-Authenticate header
      # (quoted or unquoted form, optional whitespace around '=').
      # @param header [String] the WWW-Authenticate header value
      # @param name [String] the auth-param name
      # @return [String, nil] the parameter value if present
      def extract_challenge_param(header, name)
        if (m = header.match(/(?:^|[\s,])#{Regexp.escape(name)}\s*=\s*"([^"]*)"/i))
          return m[1]
        end

        header.match(/(?:^|[\s,])#{Regexp.escape(name)}\s*=\s*([^,\s]+)/i)&.captures&.first
      end

      # Scope requested by the most recent WWW-Authenticate challenge.
      # @return [String, nil]
      attr_reader :challenge_scope

      private

      # Resolve the scope for authorization/registration requests using the
      # MCP 2025-11-25 scope selection strategy: the challenge's scope
      # parameter is authoritative; then an explicitly configured scope
      # (:all resolves to the AS-advertised scope list); then the Protected
      # Resource Metadata's scopes_supported; otherwise omit scope entirely.
      # @return [String, nil]
      def resolved_scope
        return @challenge_scope if @challenge_scope && !@challenge_scope.empty?

        if scope == :all
          all_scopes = supported_scopes
          return all_scopes.join(' ') unless all_scopes.empty?
        elsif scope
          return scope
        end

        prm = @challenge_resource_metadata || @resource_metadata
        prm_scopes = prm&.scopes_supported
        return prm_scopes.join(' ') if prm_scopes && !prm_scopes.empty?

        nil
      end

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

      # Build the scheme://host[:port] origin for a parsed URI.
      # @param uri [URI] Parsed URI
      # @return [String] origin string
      def origin_of(uri)
        origin = "#{uri.scheme}://#{uri.host}"
        origin += ":#{uri.port}" if uri.port && !default_port?(uri)
        origin
      end

      # Protected Resource Metadata well-known URLs to try, in priority order
      # (RFC 9728 §3.1). When the resource identifier has a path, the well-known
      # segment is inserted between the host and the path; a root-level URL is
      # always tried as a fallback.
      # @param server_url [String] the MCP server (protected resource) URL
      # @return [Array<String>] ordered candidate URLs
      def protected_resource_metadata_urls(server_url)
        uri = URI.parse(server_url)
        origin = origin_of(uri)
        path = uri.path.to_s

        urls = []
        urls << "#{origin}/.well-known/oauth-protected-resource#{path}" unless path.empty? || path == '/'
        urls << "#{origin}/.well-known/oauth-protected-resource"
        urls.uniq
      end

      # Authorization Server Metadata well-known URLs to try, in priority order
      # (RFC 8414 §3.1 path-insertion plus OpenID Connect Discovery). When the
      # issuer has a path, the well-known segment is INSERTED between host and
      # path (not appended); the OIDC path-append form is also tried.
      # @param issuer [String] the authorization server issuer URL
      # @return [Array<String>] ordered candidate URLs
      def authorization_server_metadata_urls(issuer)
        uri = URI.parse(issuer)
        origin = origin_of(uri)
        path = uri.path.to_s

        urls = []
        if path.empty? || path == '/'
          urls << "#{origin}/.well-known/oauth-authorization-server"
          urls << "#{origin}/.well-known/openid-configuration"
        else
          urls << "#{origin}/.well-known/oauth-authorization-server#{path}"
          urls << "#{origin}/.well-known/openid-configuration#{path}"
          urls << "#{origin}#{path}/.well-known/openid-configuration"
        end
        urls.uniq
      end

      # Discover authorization server metadata
      # Tries multiple discovery patterns:
      # 1. oauth-authorization-server (MCP spec pattern - server is its own auth server)
      # 2. oauth-protected-resource (delegation pattern - points to external auth server)
      # @return [ServerMetadata] Authorization server metadata
      # @raise [MCPClient::Errors::ConnectionError] if discovery fails
      def discover_authorization_server
        # A fresh 401 challenge is authoritative and overrides any cached
        # (possibly stale or direct-discovered) authorization server metadata.
        cached = storage.get_server_metadata(server_url) unless @challenge_resource_metadata
        if cached
          # Validate the cached entry before use so a persisted/older cache with
          # an HTTP endpoint or without S256 is still rejected.
          validate_server_metadata!(cached)
          return cached
        end

        discover_and_cache_authorization_server
      end

      # Discover authorization server metadata, validate it, and cache it.
      # @return [ServerMetadata]
      # @raise [MCPClient::Errors::ConnectionError] if discovery or validation fails
      def discover_and_cache_authorization_server
        previous = storage.get_server_metadata(server_url)

        # RFC 9728: Protected Resource Metadata is authoritative — try it first,
        # then fall back to treating the MCP server origin as its own AS.
        server_metadata = discover_via_protected_resource || discover_via_direct_authorization_server

        unless server_metadata
          raise MCPClient::Errors::ConnectionError,
                'OAuth discovery failed: no valid authorization server metadata found'
        end

        # Validate BEFORE caching so invalid metadata is never persisted.
        validate_server_metadata!(server_metadata)

        invalidate_client_info_on_as_change(previous, server_metadata)

        storage.set_server_metadata(server_url, server_metadata)
        @challenge_resource_metadata = nil # consumed
        server_metadata
      end

      # When a 401 challenge changes the authorization server, per-AS state cached
      # under this server_url becomes invalid: a client_id registered with the
      # previous AS would fail as invalid_client, and memoized scopes belong to
      # the old AS. Discard both so the new flow re-registers and re-discovers.
      # @param previous [ServerMetadata, nil] previously cached AS metadata
      # @param current [ServerMetadata] newly discovered AS metadata
      def invalidate_client_info_on_as_change(previous, current)
        return unless previous && previous.issuer != current.issuer

        logger.debug('Authorization server changed; discarding client and scopes from the previous AS')

        # Prefer an explicit delete; fall back to the always-available
        # set_client_info(nil) so custom storage backends are handled too.
        if storage.respond_to?(:delete_client_info)
          storage.delete_client_info(server_url)
        else
          storage.set_client_info(server_url, nil)
        end

        @supported_scopes = nil
      end

      # Apply the PKCE-support and HTTPS-endpoint checks to server metadata.
      # @param server_metadata [ServerMetadata]
      # @raise [MCPClient::Errors::ConnectionError] if a check fails
      def validate_server_metadata!(server_metadata)
        verify_pkce_support!(server_metadata)
        enforce_https_endpoints!(server_metadata)
      end

      # PRM-first discovery: fetch Protected Resource Metadata and then the
      # authorization server it advertises.
      # @return [ServerMetadata, nil] AS metadata, or nil if no PRM document exists
      # @raise [MCPClient::Errors::ConnectionError] if PRM is malformed or mismatched
      def discover_via_protected_resource
        # A missing PRM document (return nil) permits the direct-AS fallback. But
        # once PRM IS found it is authoritative: any subsequent failure must be a
        # hard error, never a silent fallback to an authorization server the PRM
        # did not advertise.
        candidate_urls = ([@challenge_metadata_url] + protected_resource_metadata_urls(server_url)).compact.uniq
        resource_metadata = @challenge_resource_metadata ||
                            fetch_first_resource_metadata(candidate_urls)
        return nil unless resource_metadata

        validate_resource_matches!(resource_metadata)

        auth_server_url = Array(resource_metadata.authorization_servers).first
        unless auth_server_url
          raise MCPClient::Errors::ConnectionError,
                'Protected resource metadata does not advertise any authorization_servers'
        end

        server_metadata = fetch_first_server_metadata(authorization_server_metadata_urls(auth_server_url))
        unless server_metadata
          raise MCPClient::Errors::ConnectionError,
                "Authorization server advertised by protected resource metadata (#{auth_server_url}) " \
                'could not be discovered'
        end

        server_metadata
      end

      # Legacy/self-hosted discovery: treat the MCP server ORIGIN as its own
      # authorization server issuer.
      # @return [ServerMetadata, nil]
      def discover_via_direct_authorization_server
        origin = origin_of(URI.parse(server_url))
        fetch_first_server_metadata(authorization_server_metadata_urls(origin))
      end

      # Fetch the first Protected Resource Metadata document that resolves.
      #
      # PRM is authoritative: a candidate that genuinely does not exist (HTTP
      # 404) is skipped so the next candidate is tried, but a candidate that
      # exists yet is malformed or errors (bad JSON, 5xx, network failure) is a
      # HARD failure — it must not silently fall through to a root PRM or the
      # direct-AS path, which could point at a different authorization server.
      # @param urls [Array<String>] candidate URLs
      # @return [ResourceMetadata, nil]
      def fetch_first_resource_metadata(urls)
        urls.each do |url|
          md = fetch_resource_metadata(url) # returns nil only for a 404 (absent); raises otherwise
          return md if md
        end
        nil
      end

      # Fetch the first Authorization Server Metadata document that resolves.
      # The oauth-authorization-server and openid-configuration forms are
      # genuine alternatives, so any failing candidate is skipped to try the next.
      # @param urls [Array<String>] candidate URLs
      # @return [ServerMetadata, nil]
      def fetch_first_server_metadata(urls)
        urls.each do |url|
          md = try_fetch_server_metadata(url)
          return md if md
        end
        nil
      end

      # Non-raising server-metadata fetch used while iterating candidates.
      def try_fetch_server_metadata(url)
        fetch_server_metadata(url)
      rescue MCPClient::Errors::ConnectionError => e
        logger.debug("Authorization server metadata candidate failed (#{url}): #{e.message}")
        nil
      end

      # Verify the authorization server supports PKCE S256 (RFC 8414 / MCP).
      # Refuses when S256 is explicitly not offered; warns (and proceeds, since
      # the client always uses S256) when the field is not advertised at all.
      # @param server_metadata [ServerMetadata]
      # @raise [MCPClient::Errors::ConnectionError] if S256 is explicitly unsupported
      def verify_pkce_support!(server_metadata)
        methods = server_metadata.code_challenge_methods_supported
        if methods.nil?
          logger.warn(
            'Authorization server metadata omits code_challenge_methods_supported; ' \
            'proceeding with PKCE S256'
          )
        elsif !methods.include?('S256')
          raise MCPClient::Errors::ConnectionError,
                'Authorization server does not support PKCE S256 ' \
                '(code_challenge_methods_supported does not include "S256")'
        end
      end

      # Require HTTPS for all discovered authorization server endpoints, with a
      # localhost exception for local development.
      # @param server_metadata [ServerMetadata]
      def enforce_https_endpoints!(server_metadata)
        enforce_https!(server_metadata.authorization_endpoint, 'authorization endpoint')
        enforce_https!(server_metadata.token_endpoint, 'token endpoint')
        return unless server_metadata.registration_endpoint

        enforce_https!(server_metadata.registration_endpoint, 'registration endpoint')
      end

      # @param url [String, nil] endpoint URL
      # @param label [String] human-readable endpoint name for errors
      # @raise [MCPClient::Errors::ConnectionError] if the URL is not HTTPS (non-localhost)
      def enforce_https!(url, label)
        return if url.nil?

        uri = URI.parse(url)
        return if uri.scheme == 'https'
        # Dev exception is only for plain HTTP on a loopback host — not any other
        # scheme (e.g. ftp://localhost). Use #hostname (not #host) so an IPv6
        # loopback like http://[::1]:9292 matches without the surrounding brackets.
        return if uri.scheme == 'http' && %w[localhost 127.0.0.1 ::1].include?(uri.hostname)

        raise MCPClient::Errors::ConnectionError, "OAuth #{label} must use HTTPS: #{url}"
      rescue URI::InvalidURIError
        raise MCPClient::Errors::ConnectionError, "OAuth #{label} is not a valid URL: #{url}"
      end

      # Validate the PRM `resource` identifies this server (RFC 9728 confused
      # deputy protection). Path/canonicalization differences on the same host
      # are tolerated; a different host is rejected.
      # @param resource_metadata [ResourceMetadata]
      # @raise [MCPClient::Errors::ConnectionError] on host mismatch
      def validate_resource_matches!(resource_metadata)
        # RFC 9728 requires `resource`; without it the confused-deputy check is
        # impossible, so a PRM that omits it must be rejected (not trusted).
        if resource_metadata.resource.nil?
          raise MCPClient::Errors::ConnectionError,
                'Protected resource metadata is missing the required "resource" identifier'
        end

        # Require an EXACT canonical match (scheme/host/port/path). A same-host
        # match is not enough: a host that serves multiple resources/tenants
        # must not have one tenant's PRM trusted for another.
        advertised = resource_identity(resource_metadata.resource)
        expected = resource_identity(server_url)
        return if advertised == expected

        raise MCPClient::Errors::ConnectionError,
              "Protected resource metadata resource (#{resource_metadata.resource}) " \
              "does not match the server URL (#{server_url})"
      end

      # Canonical resource identity (scheme, host, port, path, query) used for
      # the confused-deputy comparison. The query is included because the
      # `resource` parameter sent in the authorization and token requests is the
      # full server URL (some servers distinguish resources by query, e.g.
      # ?serverId=a vs ?serverId=b); only the fragment is ignored. Rejects a
      # non-absolute URL, since the value is untrusted server input.
      # @param url [String] a resource URL
      # @return [String] canonical identity string
      # @raise [MCPClient::Errors::ConnectionError] if the URL is not an absolute URI
      def resource_identity(url)
        uri = URI.parse(url)
        unless uri.scheme && uri.host
          raise MCPClient::Errors::ConnectionError, "Invalid resource URL (must be absolute): #{url}"
        end

        scheme = uri.scheme.downcase
        host = uri.host.downcase
        port = uri.port
        port = nil if (scheme == 'http' && port == 80) || (scheme == 'https' && port == 443)
        path = uri.path.to_s
        path = '' if path == '/'
        path = path.chomp('/') while path.end_with?('/')
        query = uri.query ? "?#{uri.query}" : ''

        "#{scheme}://#{host}#{":#{port}" if port}#{path}#{query}"
      rescue URI::InvalidURIError
        raise MCPClient::Errors::ConnectionError, "Invalid resource URL: #{url}"
      end

      # Fetch resource metadata from URL.
      #
      # Returns nil when the document is genuinely absent (HTTP 404) so a
      # discovery loop can try the next candidate. Any other failure — a
      # non-404 error status, malformed JSON, or a network error — raises,
      # because PRM is authoritative and such a response must not be silently
      # skipped in favor of a different authorization server.
      # @param url [String] Resource metadata URL
      # @param strict [Boolean] when true, a 404 raises instead of returning nil
      #   (used for a URL explicitly advertised by a 401 challenge)
      # @return [ResourceMetadata, nil] metadata, or nil if a speculative URL returns 404
      # @raise [MCPClient::Errors::ConnectionError] on any non-404 failure, or on 404 when strict
      def fetch_resource_metadata(url, strict: false)
        logger.debug("Fetching resource metadata from: #{url}")

        response = @http_client.get(url) do |req|
          req.headers['Accept'] = 'application/json'
        end

        return nil if response.status == 404 && !strict

        unless response.success?
          raise MCPClient::Errors::ConnectionError, "Failed to fetch resource metadata: HTTP #{response.status}"
        end

        data = JSON.parse(response.body)
        metadata = ResourceMetadata.from_h(data)
        # Retain the most recently fetched PRM so scope resolution can fall
        # back to its scopes_supported (MCP scope selection priority 2).
        @resource_metadata = metadata
        metadata
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

      # Get or register OAuth client, following the MCP 2025-11-25 client
      # registration priority order: pre-registered/cached client information
      # first, then Client ID Metadata Documents (SEP-991) when the
      # authorization server advertises support and a metadata URL is
      # configured, then Dynamic Client Registration as a fallback.
      # @param server_metadata [ServerMetadata] Authorization server metadata
      # @return [ClientInfo] Client information
      # @raise [MCPClient::Errors::ConnectionError] if registration fails
      def get_or_register_client(server_metadata)
        # 1. Pre-registered or previously registered client info from storage
        if (client_info = storage.get_client_info(server_url)) && !client_info.client_secret_expired?
          logger.debug("Using cached OAuth client for #{server_url}")
          return client_info
        end

        # 2. Client ID Metadata Documents (SEP-991): the HTTPS metadata URL is
        # itself the client_id — no registration request is needed.
        if client_id_metadata_url && server_metadata.supports_client_id_metadata_documents?
          return client_info_from_metadata_url
        end

        # 3. Dynamic Client Registration (RFC 7591) fallback
        logger.debug('No cached client found, registering new OAuth client...')
        if server_metadata.supports_registration?
          register_client(server_metadata)
        else
          raise MCPClient::Errors::ConnectionError,
                'Dynamic client registration not supported and no client credentials found'
        end
      end

      # Build client information for a Client ID Metadata Document client
      # (SEP-991): the configured HTTPS metadata URL is used directly as the
      # client_id in authorization and token requests, without a dynamic
      # registration POST. Serving the metadata JSON at that URL is the
      # application's responsibility, not this library's.
      # @return [ClientInfo] Client information with the metadata URL as client_id
      def client_info_from_metadata_url
        logger.debug("Using Client ID Metadata Document URL as client_id: #{client_id_metadata_url}")

        metadata = ClientMetadata.new(
          redirect_uris: [redirect_uri],
          token_endpoint_auth_method: 'none', # Public client
          grant_types: %w[authorization_code refresh_token],
          response_types: ['code'],
          scope: resolved_scope,
          **@extra_client_metadata
        )

        client_info = ClientInfo.new(client_id: client_id_metadata_url, metadata: metadata)

        # Persist so complete_authorization_flow and token refresh can find it
        storage.set_client_info(server_url, client_info)

        client_info
      end

      # Validate a Client ID Metadata Document URL (SEP-991): "The client_id
      # URL MUST use the 'https' scheme and contain a path component, e.g.
      # https://example.com/client.json".
      # @param url [String] Candidate metadata URL
      # @return [String] The validated URL
      # @raise [ArgumentError] if the URL is invalid, not HTTPS, or lacks a path component
      def validate_client_id_metadata_url(url)
        uri = URI.parse(url)
        raise ArgumentError, "client_id_metadata_url must be an HTTPS URL: #{url.inspect}" unless uri.is_a?(URI::HTTPS)

        if uri.path.to_s.empty? || uri.path == '/'
          raise ArgumentError,
                'client_id_metadata_url must contain a path component ' \
                "(e.g. https://example.com/client.json): #{url.inspect}"
        end

        url
      rescue URI::InvalidURIError
        raise ArgumentError, "client_id_metadata_url is not a valid URL: #{url.inspect}"
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
          scope: resolved_scope,
          **@extra_client_metadata
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
          scope: data['scope'],
          client_name: data['client_name'],
          client_uri: data['client_uri'],
          logo_uri: data['logo_uri'],
          tos_uri: data['tos_uri'],
          policy_uri: data['policy_uri'],
          contacts: data['contacts']
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
          scope: resolved_scope,
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

        def delete_client_info(server_url)
          @client_infos.delete(server_url)
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
