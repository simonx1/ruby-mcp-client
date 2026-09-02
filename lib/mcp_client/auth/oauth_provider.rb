# frozen_string_literal: true

require 'faraday'
require 'json'
require 'uri'
require 'ipaddr'
require_relative '../auth'
require_relative 'oauth_provider/challenge_handling'

module MCPClient
  module Auth
    # OAuth 2.1 provider for MCP client authentication
    # Handles the complete OAuth flow including server discovery, client registration,
    # authorization, token exchange, and refresh
    class OAuthProvider
      # One auth-param (name = token / quoted-string) as it appears in a
      # WWW-Authenticate challenge (RFC 7235 §2.1, optional whitespace around
      # '='). Mirrors HttpTransportBase::AUTH_PARAM so provider-side challenge
      # parsing segments headers exactly like the transport does.
      AUTH_PARAM = /[A-Za-z0-9._~+-]+\s*=\s*(?:"(?:[^"\\]|\\.)*"|[^,\s]*)/
      # A run of comma/space separated auth-params anchored at the start of a
      # string. The run ends before a token that is NOT followed by '=' — the
      # auth-scheme introducing the next challenge — while commas inside quoted
      # values are consumed by the quoted-string branch, not treated as
      # boundaries. Mirrors HttpTransportBase::AUTH_PARAMS_RUN.
      AUTH_PARAMS_RUN = /\A(?:[\s,]*#{AUTH_PARAM})*/

      include ChallengeHandling

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
      # OIDC application types accepted for Dynamic Client Registration.
      APPLICATION_TYPES = %w[native web].freeze

      # Loopback hosts whose redirect URIs mark a native application.
      LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

      # @return [String, nil] the explicit application_type for Dynamic Client Registration
      attr_reader :application_type

      def initialize(server_url:, redirect_uri: 'http://localhost:8080/callback', scope: nil, logger: nil, storage: nil,
                     client_metadata: {}, client_id_metadata_url: nil, application_type: nil)
        self.server_url = server_url
        self.redirect_uri = redirect_uri
        self.scope = scope
        self.logger = logger || Logger.new($stdout, level: Logger::WARN)
        self.storage = storage || MemoryStorage.new
        self.client_id_metadata_url = client_id_metadata_url
        # An application_type given through client_metadata is the host's
        # explicit choice too; it never silently overrides the derived type.
        extra = (client_metadata || {}).transform_keys(&:to_sym)
        self.application_type = application_type || extra[:application_type]
        @extra_client_metadata = extra.except(:application_type)
        @http_client = create_http_client
        # Protected resource metadata learned from a 401 WWW-Authenticate
        # challenge, reused by discovery so a challenge-advertised metadata URL
        # is not re-derived (and possibly missed). The URL itself is retained
        # separately so a failed fetch is retried authoritatively by discovery.
        @challenge_resource_metadata = nil
        @challenge_metadata_url = nil
        # Why a peer-advertised challenge URL was refused, if one was
        @challenge_error = nil
      end

      # @param type [String, nil] 'native', 'web' or nil (derived from the redirect URI)
      # @raise [ArgumentError] for any other value
      def application_type=(type)
        type = type&.to_s
        unless type.nil? || APPLICATION_TYPES.include?(type)
          raise ArgumentError, "application_type must be one of #{APPLICATION_TYPES.join(', ')}: #{type.inspect}"
        end

        @application_type = type
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
        token = stored_token
        logger.debug("OAuth access_token: retrieved token=#{token ? 'present' : 'nil'} for #{server_url}")
        return nil unless token

        # A token from another authorization server is never presented
        # (MCP 2026-07-28: registration state and tokens are per AS). Retired
        # bytes are refused before any binding could attribute them anew.
        return nil if retired_token?(token)

        resolve_pending_challenge
        token = bind_token_issuer(token)
        return nil unless token && token_for_current_issuer?(token)

        # Return token if still valid
        return token unless token.expired? || token.expires_soon?

        # Refresh early when possible; a still-valid token is presented when
        # the refresh (or the discovery it needs) cannot run right now.
        refreshed = refresh_if_possible(token)
        return refreshed if refreshed
        # The discovery a refresh ran may have retired this very token.
        return nil if token.expired? || retired_token?(token) || !token_for_current_issuer?(token)

        token
      end

      # @param token [Token]
      # @return [Token, nil] the refreshed token, or nil when no refresh could be obtained
      def refresh_if_possible(token)
        return nil unless token.refresh_token

        refresh_token(token)
      rescue MCPClient::Errors::ConnectionError => e
        logger.warn("Token refresh could not run: #{e.message}")
        nil
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

        # Generate PKCE parameters. MCP 2026-07-28 "Authorization Response
        # Validation": the selected authorization server's issuer is recorded
        # in the same per-request record so the `iss` of the response can be
        # checked against an authenticated value.
        pkce = PKCE.new(issuer: server_metadata.issuer,
                        iss_parameter_supported: server_metadata.iss_parameter_supported?,
                        client_id: client_info.client_id,
                        redirect_uri: client_info.metadata.redirect_uris.first)
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
      # @param iss [String, nil] the `iss` parameter of the authorization response (RFC 9207);
      #   validated against the issuer recorded when the flow started, before the code is sent
      #   to any token endpoint (MCP 2026-07-28)
      # @return [Token] Access token
      # @raise [MCPClient::Errors::ConnectionError] if the issuer check or the token exchange fails
      # @raise [ArgumentError] if state parameter doesn't match
      def complete_authorization_flow(code, state, iss: nil)
        # Verify state parameter
        stored_state = storage.get_state(server_url)
        raise ArgumentError, 'Invalid state parameter' unless stored_state == state

        # Get stored PKCE and client info
        pkce = stored_pkce
        client_info = stored_client_info
        raise MCPClient::Errors::ConnectionError, 'Missing PKCE or client info' unless pkce && client_info

        # The code is redeemed only at the authorization server the request
        # was sent to: the issuer recorded with the PKCE record (RFC 9207
        # mix-up protection). A different server discovered since — a 401
        # challenge pointing elsewhere — ends this flow instead.
        unless pkce.issuer.is_a?(String)
          raise MCPClient::Errors::ConnectionError,
                'Authorization response rejected: no issuer was recorded for this authorization request, ' \
                'so it cannot be bound to an authorization server; restart the authorization'
        end
        server_metadata = discover_authorization_server
        unless server_metadata.issuer == pkce.issuer
          raise MCPClient::Errors::ConnectionError,
                'Authorization response rejected: the authorization server changed during the flow ' \
                "(recorded #{safe_error_text(pkce.issuer)}); restart the authorization"
        end
        validate_authorization_response_issuer!(iss, pkce.issuer, iss_parameter_supported_for?(pkce, server_metadata))
        # The credentials that redeem the code are the ones the request was
        # made with: a record swapped in shared storage meanwhile (another
        # client id, or credentials of another authorization server) is
        # never sent to this token endpoint.
        ensure_client_for_request!(client_info, pkce)

        # Exchange authorization code for tokens
        token = exchange_authorization_code(server_metadata, client_info, code, pkce)

        # Store token
        store_token(token)

        # Clean up temporary data
        storage.delete_pkce(server_url)
        storage.delete_state(server_url)

        token
      end

      # The stored credentials must be the ones the authorization request
      # was made with; a request that recorded no client cannot be bound to
      # any and fails closed, like one that recorded no issuer.
      # @param client_info [ClientInfo, nil]
      # @param pkce [PKCE]
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError]
      def ensure_client_for_request!(client_info, pkce)
        unless pkce.respond_to?(:client_id) && pkce.client_id.is_a?(String)
          raise MCPClient::Errors::ConnectionError,
                'Authorization response rejected: no client was recorded for this authorization request; ' \
                'restart the authorization'
        end
        return if client_info && client_for_request?(client_info, pkce)

        raise MCPClient::Errors::ConnectionError,
              'Authorization response rejected: the client credentials changed during the flow; ' \
              'restart the authorization'
      end

      # Whether stored credentials are the ones an authorization request was
      # made with: the recorded client id and, unless portable, bound to the
      # request's authorization server.
      # @param client_info [ClientInfo]
      # @param pkce [PKCE]
      # @return [Boolean]
      def client_for_request?(client_info, pkce)
        return false if pkce.client_id != client_info.client_id
        return true if portable_client?(client_info)

        # A started flow binds its non-portable client, so an unbound record
        # here was put in storage by someone else meanwhile.
        !client_info.respond_to?(:issuer) || client_info.issuer == pkce.issuer
      end

      # Check a success response before anything is shown or exchanged: the
      # state must be the one of the pending flow and the response's `iss`
      # must identify the authorization server the request went to (RFC
      # 9207). {#complete_authorization_flow} repeats the check before the
      # token exchange; a browser callback uses this to answer correctly.
      # @param state [String, nil] the callback's state parameter
      # @param iss [String, nil] the callback's iss parameter
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError] when the response is not this flow's or the issuer fails
      def validate_authorization_response!(state, iss: nil)
        stored_state = storage.get_state(server_url)
        unless stored_state && stored_state == state
          raise MCPClient::Errors::ConnectionError, 'Authorization response rejected: state mismatch'
        end

        pkce = stored_pkce
        unless pkce.respond_to?(:issuer) && pkce.issuer.is_a?(String)
          raise MCPClient::Errors::ConnectionError,
                'Authorization response rejected: no issuer was recorded for this authorization request'
        end

        cached = stored_server_metadata
        # A challenge received meanwhile — refused, still to be fetched, or
        # naming another authorization server — or cached metadata for
        # another server ends this flow here, not after a success page.
        if @challenge_error || (@challenge_metadata_url && @challenge_resource_metadata.nil?)
          raise MCPClient::Errors::ConnectionError,
                'Authorization response rejected: a challenge received during the flow must be resolved first; ' \
                'restart the authorization'
        end
        advertised = Array(@challenge_resource_metadata&.authorization_servers).first
        if (advertised && advertised != pkce.issuer) || (cached && cached.issuer != pkce.issuer)
          raise MCPClient::Errors::ConnectionError,
                'Authorization response rejected: the authorization server changed during the flow; ' \
                'restart the authorization'
        end
        ensure_client_for_request!(stored_client_info, pkce)
        validate_authorization_response_issuer!(iss, pkce.issuer, iss_parameter_supported_for?(pkce, cached))
      end

      # The message to surface for an authorization *error* response, after
      # the same RFC 9207 issuer check as a success response: "on mismatch
      # the client MUST NOT act on or display error, error_description, or
      # error_uri" (MCP 2026-07-28 "Authorization Response Validation").
      # @param params [Hash] the callback parameters (error, error_description, iss, state, ...)
      # @return [String] the error text to show
      # @raise [MCPClient::Errors::ConnectionError] when the response's issuer does not check out
      def authorization_error_message(params)
        params = params.to_h.transform_keys(&:to_s)
        # Every started flow records a state, so a response that cannot be
        # matched to one is not this client's to act on.
        stored_state = storage.get_state(server_url)
        if stored_state.nil? || params['state'] != stored_state
          raise MCPClient::Errors::ConnectionError, 'Authorization error response rejected: state mismatch'
        end

        pkce = stored_pkce
        cached = stored_server_metadata
        # Only the request's own authorization server can say whether iss is
        # expected: a cache that names another server is no guide.
        cached = nil unless pkce && cached && cached.issuer == pkce.issuer
        validate_authorization_response_issuer!(params['iss'], pkce&.issuer, iss_parameter_supported_for?(pkce, cached))
        safe_error_text((params['error_description'] || params['error'] || 'unknown error').to_s).strip
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

      # Scope requested by the most recent WWW-Authenticate challenge.
      # @return [String, nil]
      attr_reader :challenge_scope

      private

      # RFC 9207 Section 2.4 as applied by MCP 2026-07-28: a present `iss`
      # must equal the recorded issuer byte for byte (no scheme/host case
      # folding, default-port elision, trailing-slash or percent-encoding
      # normalization); an absent `iss` is rejected when the authorization
      # server advertises the parameter. Without a recorded issuer nothing
      # can be validated, so a present `iss` is rejected (fail closed).
      # @param iss [String, nil] the response's iss parameter
      # @param expected [String, nil] the issuer recorded when the flow started
      # @param server_metadata [ServerMetadata, nil] the authorization server metadata
      # @return [void]
      # @raise [MCPClient::Errors::ConnectionError]
      # @param supported [Boolean] whether the request's authorization server advertises iss
      def validate_authorization_response_issuer!(iss, expected, supported)
        unless expected.is_a?(String)
          raise MCPClient::Errors::ConnectionError,
                'Authorization response rejected: no issuer was recorded for this authorization request, ' \
                'so it cannot be bound to an authorization server; restart the authorization'
        end
        if iss.nil?
          return unless supported

          raise MCPClient::Errors::ConnectionError,
                'Authorization response rejected: the authorization server advertises the iss parameter ' \
                '(authorization_response_iss_parameter_supported) but the response carries none'
        end
        return if iss.to_s == expected

        raise MCPClient::Errors::ConnectionError,
              "Authorization response rejected: issuer mismatch (expected #{safe_error_text(expected)})"
      end

      # Whether the authorization server of a request advertised the iss
      # response parameter: recorded with the PKCE record; for a record
      # persisted before that field existed, the metadata of the same
      # issuer decides.
      # @return [Boolean]
      def iss_parameter_supported_for?(pkce, server_metadata)
        recorded = pkce&.iss_parameter_supported
        return recorded == true unless recorded.nil?

        server_metadata&.iss_parameter_supported? == true
      end

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
        # A challenge we refused is still authoritative: it says the cached
        # authorization server is no longer the right one. Falling back to
        # that cache (or to speculative well-known probing) would quietly
        # undo the rejection, so surface it instead.
        raise MCPClient::Errors::ConnectionError, @challenge_error if @challenge_error

        # A fresh 401 challenge is authoritative and overrides any cached
        # (possibly stale or direct-discovered) authorization server metadata —
        # whether the challenge-advertised PRM was already fetched or only its
        # URL is pending (e.g. the initial fetch failed and must be retried).
        challenge_pending = @challenge_resource_metadata || @challenge_metadata_url
        cached = stored_server_metadata unless challenge_pending
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
        previous = stored_server_metadata

        # RFC 9728: Protected Resource Metadata is authoritative — try it first,
        # then fall back to treating the MCP server origin as its own AS.
        server_metadata = discover_via_protected_resource || discover_via_direct_authorization_server

        unless server_metadata
          raise MCPClient::Errors::ConnectionError,
                'OAuth discovery failed: no valid authorization server metadata found'
        end

        # Validate BEFORE caching so invalid metadata is never persisted.
        validate_server_metadata!(server_metadata)

        if previous
          invalidate_client_info_on_as_change(previous, server_metadata)
        else
          retire_records_without_issuer
        end

        storage.set_server_metadata(server_url, server_metadata)
        # Remembered in-process as well: a backend that does not persist
        # metadata would otherwise never know the current issuer.
        @discovered_server_metadata = server_metadata
        @challenge_resource_metadata = nil # consumed
        @challenge_metadata_url = nil # consumed
        @challenge_error = nil
        server_metadata
      end

      # Records persisted before issuers were recorded, with no cached
      # authorization server to prove where they came from, cannot be bound
      # to whatever discovery finds now: a dynamic registration (with its
      # secret) and a token are retired so the flow re-registers and
      # re-authorizes. Pre-registered and portable credentials are the
      # host's own configuration and are bound on first use.
      # @return [void]
      def retire_records_without_issuer
        token = stored_token
        delete_token(bind_to: Token::RETIRED_ISSUER) if token.respond_to?(:issuer) && token.issuer.nil?

        client_info = stored_client_info
        return unless client_info.respond_to?(:issuer) && client_info.issuer.nil?
        return if portable_client?(client_info) || resolved_registration_type(client_info) != 'dynamic'

        logger.debug('Discarding a dynamic OAuth client registration whose authorization server is unknown')
        # Stamped as retired first, so a backend that cannot delete still
        # leaves a record no authorization server matches.
        begin
          storage.set_client_info(server_url, client_info.with_issuer(Token::RETIRED_ISSUER,
                                                                      registration_type: 'dynamic'))
        rescue StandardError => e
          logger.debug("The stale OAuth client registration could not be re-stored as retired (#{e.class})")
        end
        delete_client_info
      end

      # When a 401 challenge changes the authorization server, per-AS state cached
      # under this server_url becomes invalid: a client_id registered with the
      # previous AS would fail as invalid_client, and memoized scopes belong to
      # the old AS. Discard both so the new flow re-registers and re-discovers.
      # @param previous [ServerMetadata, nil] previously cached AS metadata
      # @param current [ServerMetadata] newly discovered AS metadata
      def invalidate_client_info_on_as_change(previous, current)
        return unless previous && previous.issuer != current.issuer

        logger.debug('Authorization server changed; discarding the token and scopes from the previous AS')

        # Registration state is per authorization server: a token from the
        # previous one is not valid for the new one. Credentials stored
        # without a binding belonged to the previous server, so they are
        # bound to it first; then they are kept only when bound
        # (pre-registered, so the mismatch can be reported) or portable
        # (Client ID Metadata Document), and a dynamic registration is
        # discarded so the next flow re-registers.
        @authorization_server_switched = true
        @supported_scopes = nil
        # Records another provider sharing the storage already bound to the
        # new server are its: only unbound ones and those of the previous
        # server are affected.
        delete_token(bind_to: previous.issuer) unless record_bound_to?(stored_token_or_nil, current.issuer)
        client_info = stored_client_info
        return if record_bound_to?(client_info, current.issuer)

        if client_info.respond_to?(:issuer) && client_info.issuer.nil? && !portable_client?(client_info)
          client_info = client_info.with_issuer(previous.issuer,
                                                registration_type: resolved_registration_type(client_info))
          storage.set_client_info(server_url, client_info)
        end
        keep = client_info.respond_to?(:portable?) && (portable_client?(client_info) || client_info.pre_registered?)
        delete_client_info unless keep
      end

      # @param record [Token, ClientInfo, Object, nil]
      # @param issuer [String]
      # @return [Boolean] whether the record says it belongs to that issuer
      def record_bound_to?(record, issuer)
        record.respond_to?(:issuer) && record.issuer == issuer
      end

      # The stored token, or nil when the backend cannot even be asked
      # (a minimal backend without get_token, tolerated as before).
      # @return [Token, nil]
      def stored_token_or_nil
        stored_token
      rescue StandardError
        nil
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
        resource_metadata = challenge_or_well_known_resource_metadata
        return nil unless resource_metadata

        validate_resource_matches!(resource_metadata)

        auth_server_url = Array(resource_metadata.authorization_servers).first
        unless auth_server_url
          raise MCPClient::Errors::ConnectionError,
                'Protected resource metadata does not advertise any authorization_servers'
        end

        # authorization_servers is untrusted PRM content: validate the
        # advertised origin BEFORE constructing and fetching well-known URLs
        # on it, so a malicious protected resource cannot drive discovery GETs
        # against internal services (SSRF).
        validate_peer_advertised_url!(auth_server_url,
                                      'authorization server (advertised by protected resource metadata)')

        server_metadata = fetch_first_server_metadata(authorization_server_metadata_urls(auth_server_url),
                                                      auth_server_url)
        unless server_metadata
          raise MCPClient::Errors::ConnectionError,
                "Authorization server advertised by protected resource metadata (#{auth_server_url}) " \
                'could not be discovered'
        end

        server_metadata
      end

      # Resolve the Protected Resource Metadata for discovery.
      #
      # MCP 2025-11-25 MUST: use the resource metadata URL from the parsed
      # WWW-Authenticate headers when present; otherwise fall back to the
      # well-known URIs. A challenge-advertised URL is therefore authoritative:
      # it is fetched strictly, and any failure (including a 404) raises rather
      # than falling through to constructed well-known candidates the challenge
      # superseded.
      # @return [ResourceMetadata, nil] metadata, or nil when no PRM exists at
      #   the speculative well-known URLs (permitting the direct-AS fallback)
      # @raise [MCPClient::Errors::ConnectionError] if the challenge-advertised
      #   URL cannot be fetched, or a well-known candidate exists but is invalid
      def challenge_or_well_known_resource_metadata
        return @challenge_resource_metadata if @challenge_resource_metadata
        return fetch_resource_metadata(@challenge_metadata_url, strict: true) if @challenge_metadata_url

        fetch_first_resource_metadata(protected_resource_metadata_urls(server_url))
      end

      # Legacy/self-hosted discovery: treat the MCP server ORIGIN as its own
      # authorization server issuer.
      # @return [ServerMetadata, nil]
      def discover_via_direct_authorization_server
        origin = origin_of(URI.parse(server_url))
        fetch_first_server_metadata(authorization_server_metadata_urls(origin), origin)
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
      # @param urls [Array<String>] well-known candidates
      # @param issuer [String] the issuer identifier the candidates were built from
      def fetch_first_server_metadata(urls, issuer)
        rejected = nil
        urls.each do |url|
          md = try_fetch_server_metadata(url)
          next unless md

          begin
            validate_metadata_issuer!(md, issuer)
          rescue MCPClient::Errors::ConnectionError => e
            # Not this candidate: the next well-known location may hold the
            # document for the issuer actually asked for.
            logger.debug("Authorization server metadata candidate rejected (#{url}): #{e.message}")
            rejected = e
            next
          end
          return md
        end
        # Only mismatching documents were found: say so rather than "nothing".
        raise rejected if rejected

        nil
      end

      # RFC 8414 Section 3.3 / OpenID Connect Discovery 4.3 (MCP 2026-07-28
      # "Authorization Server Metadata Discovery"): "the issuer value in the
      # document MUST be identical to the issuer identifier used to construct
      # the well-known URL. If they differ, the client MUST NOT use the
      # metadata." The issuer is the trust anchor of the RFC 9207 check, so a
      # document naming another issuer is rejected outright.
      # @param metadata [ServerMetadata]
      # @param issuer [String]
      # @raise [MCPClient::Errors::ConnectionError]
      def validate_metadata_issuer!(metadata, issuer)
        # Byte-for-byte (RFC 8414 Section 4): no case folding, no slash or
        # port normalization.
        return if metadata.issuer.is_a?(String) && metadata.issuer == issuer.to_s

        raise MCPClient::Errors::ConnectionError,
              "Authorization server metadata rejected: its issuer #{safe_error_text(metadata.issuer.to_s).inspect} " \
              "is not the identifier it was fetched for (#{safe_error_text(issuer.to_s)})"
      end

      # Non-raising server-metadata fetch used while iterating candidates.
      def try_fetch_server_metadata(url)
        fetch_server_metadata(url)
      rescue MCPClient::Errors::ConnectionError => e
        logger.debug("Authorization server metadata candidate failed (#{url}): #{e.message}")
        nil
      end

      # Verify the authorization server supports PKCE S256 (RFC 8414 / MCP).
      # Per MCP 2025-11-25, "If code_challenge_methods_supported is absent,
      # the authorization server does not support PKCE and MCP clients MUST
      # refuse to proceed" — absence is a hard stop, not a warning, because
      # proceeding would defeat the authorization-code downgrade protection.
      # @param server_metadata [ServerMetadata]
      # @raise [MCPClient::Errors::ConnectionError] if PKCE S256 support cannot be verified
      def verify_pkce_support!(server_metadata)
        methods = server_metadata.code_challenge_methods_supported
        if methods.nil?
          raise MCPClient::Errors::ConnectionError,
                'Authorization server metadata omits code_challenge_methods_supported; ' \
                'the server does not support PKCE and the client must refuse to proceed'
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
              "Protected resource metadata resource (#{safe_error_text(resource_metadata.resource.to_s)}) " \
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
        raise MCPClient::Errors::ConnectionError, "Invalid resource URL: #{safe_error_text(url.to_s)}"
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
        raise MCPClient::Errors::ConnectionError, 'Invalid resource metadata: not a JSON object' unless data.is_a?(Hash)

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
        raise MCPClient::Errors::ConnectionError, 'Invalid server metadata: not a JSON object' unless data.is_a?(Hash)

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
        # 1. Pre-registered or previously registered client info from storage,
        # provided it belongs to the authorization server in use.
        if (client_info = stored_client_info) && !client_info.client_secret_expired?
          bound = client_info_for_issuer(client_info, server_metadata.issuer, server_metadata)
          if bound
            logger.debug("Using cached OAuth client for #{server_url}")
            return bound
          end
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

      # MCP 2026-07-28 "Authorization Server Binding": credentials are keyed
      # by the issuer that produced them. A Client ID Metadata Document
      # client id is portable; unbound credentials are bound to the current
      # issuer on first use; pre-registered credentials for another issuer
      # are an error rather than silently reused; a dynamic registration for
      # another issuer is discarded so the caller re-registers.
      # @param client_info [ClientInfo] the cached credentials
      # @param issuer [String] the issuer of the authorization server in use
      # @return [ClientInfo, nil] usable credentials, or nil when a new registration is needed
      # @raise [MCPClient::Errors::ConnectionError] for pre-registered credentials of another issuer
      # @param server_metadata [ServerMetadata, nil] the authorization server in use
      def client_info_for_issuer(client_info, issuer, server_metadata = nil)
        return client_info unless client_info.respond_to?(:issuer)

        if portable_client?(client_info)
          # A portable id is only usable where Client ID Metadata Documents
          # are accepted; elsewhere the caller registers or reports that no
          # credentials exist.
          return nil if server_metadata && !server_metadata.supports_client_id_metadata_documents?
          # A Client ID Metadata Document client persisted before the type
          # was recorded is migrated so later checks need no inference.
          return client_info if client_info.registration_type == 'cimd'

          migrated = client_info.with_issuer(client_info.issuer, registration_type: 'cimd')
          storage.set_client_info(server_url, migrated)
          return migrated
        end

        if client_info.issuer.nil?
          bound = client_info.with_issuer(issuer, registration_type: resolved_registration_type(client_info))
          storage.set_client_info(server_url, bound)
          return bound
        end
        return client_info if client_info.issuer == issuer

        if client_info.pre_registered?
          raise MCPClient::Errors::ConnectionError,
                'Pre-registered OAuth client credentials belong to authorization server ' \
                "#{safe_error_text(client_info.issuer)}, but the server now uses #{safe_error_text(issuer)}; " \
                'register the client with the new authorization server'
        end

        logger.warn("Discarding the OAuth client registered with #{safe_error_text(client_info.issuer)}: " \
                    "the authorization server is now #{safe_error_text(issuer)}")
        delete_client_info
        delete_token(bind_to: client_info.issuer)
        nil
      end

      # Forget the stored token (the authorization server it came from is no
      # longer the one in use). Storage backends may implement the optional
      # delete_token(server_url); otherwise set_token(server_url, nil) is
      # attempted, and a backend that accepts neither is reported.
      # @return [void]
      # @param bind_to [String, nil] the issuer the token belonged to (or Token::RETIRED_ISSUER): a token
      #   that records no issuer is first re-stored bound to it, so a backend that cannot delete still
      #   keeps it away from another authorization server after a restart
      def delete_token(bind_to: nil)
        # Whatever the backend manages, this token is never presented again.
        current = stored_token
        if current.respond_to?(:access_token) && current.access_token
          # Opaque tokens are unique only within an issuer: the marker names
          # the issuer the bytes were retired for, so another provider
          # sharing the storage may store the same bytes for a new server.
          (@retired_tokens ||= {})[retirement_key(current, bind_to)] = true
        end
        if bind_to && current.respond_to?(:with_issuer) && (current.issuer.nil? || bind_to == Token::RETIRED_ISSUER)
          begin
            storage.set_token(server_url, current.with_issuer(bind_to))
          rescue StandardError => e
            logger.debug("Could not bind the retired token to its issuer in storage: #{e.class}")
          end
        end
        if storage.respond_to?(:delete_token)
          storage.delete_token(server_url)
        else
          storage.set_token(server_url, nil)
        end
      rescue StandardError => e
        logger.warn('The OAuth token for the previous authorization server could not be removed from storage ' \
                    "(#{e.class}); implement delete_token(server_url) on the storage backend. The token is " \
                    'ignored while the authorization server differs from its issuer.')
      end

      # Storage backends may persist plain hashes (the FileTokenStorage
      # example does); records are normalized before any field is read.
      # @return [ServerMetadata, nil]
      def stored_server_metadata
        normalize_record(storage.get_server_metadata(server_url), ServerMetadata) || @discovered_server_metadata
      end

      # @return [ClientInfo, nil]
      def stored_client_info
        normalize_record(storage.get_client_info(server_url), ClientInfo)
      end

      # @return [PKCE, nil]
      def stored_pkce
        normalize_record(storage.get_pkce(server_url), PKCE)
      end

      # @return [Token, nil]
      def stored_token
        normalize_record(storage.get_token(server_url), Token)
      end

      # @param record [Object, Hash, nil]
      # @param klass [Class] a record class responding to from_h
      # @return [Object, nil]
      def normalize_record(record, klass)
        record.is_a?(Hash) ? klass.from_h(record) : record
      end

      # Persist a token the authorization server just issued. Opaque tokens
      # are unique only within an issuer, so a new server may legitimately
      # issue the same bytes as a token retired at the previous one: the
      # fresh, issuer-bound token is never mistaken for the retired one.
      # @param token [Token]
      # @return [void]
      def store_token(token)
        storage.set_token(server_url, token)
        # Only a persisted replacement lifts the marker: if the write failed,
        # the stale record still in storage stays retired.
        @retired_tokens&.delete(retirement_key(token, nil)) if token.respond_to?(:access_token)
      end

      # Whether a token was retired in this process: a bound token when its
      # bytes were retired for its issuer, an unbound one when its bytes
      # were retired for any issuer (it cannot say which one it came from).
      # @param token [Token]
      # @return [Boolean]
      def retired_token?(token)
        return true if token.respond_to?(:retired?) && token.retired?
        return false unless token.respond_to?(:access_token) && @retired_tokens

        issuer = token.respond_to?(:issuer) ? token.issuer : nil
        return @retired_tokens.key?([issuer, token.access_token]) if issuer

        @retired_tokens.keys.any? { |_issuer, bytes| bytes == token.access_token }
      end

      # The in-process retirement marker of a token: its bytes together with
      # the issuer they were retired for (the recorded issuer, else the
      # issuer the token was bound to at retirement).
      # @param token [Token]
      # @param bind_to [String, nil]
      # @return [Array(String, String)]
      def retirement_key(token, bind_to)
        issuer = token.respond_to?(:issuer) ? token.issuer : nil
        [issuer || bind_to || Token::RETIRED_ISSUER, token.access_token]
      end

      # Whether a stored token belongs to the authorization server currently
      # known for this resource. While that server is unknown (no cached
      # metadata) nothing is presented: the next challenge discovers it.
      # @param token [Token]
      # @return [Boolean]
      def token_for_current_issuer?(token)
        return false if retired_token?(token)
        return true unless token.respond_to?(:issuer)

        current = current_issuer_for_tokens
        !current.nil? && current == token.issuer
      end

      # The authorization server tokens are judged against: a validated
      # challenge received since the metadata was cached is authoritative
      # (discovery treats it so), else the cached metadata's issuer.
      # @return [String, nil]
      def current_issuer_for_tokens
        advertised = Array(@challenge_resource_metadata&.authorization_servers).first
        return advertised if advertised.is_a?(String)
        # An unresolved challenge URL means the current server is unknown.
        return nil if @challenge_metadata_url

        stored_server_metadata&.issuer
      end

      # A token persisted before issuers were recorded was obtained from the
      # authorization server cached alongside it (a server change always
      # retires or binds the token first), so it is bound to that server on
      # first use; while no server is known it is not presented.
      # @param token [Token]
      # @return [Token, nil] the bound token, or nil when it cannot be bound yet
      def bind_token_issuer(token)
        return token unless token.respond_to?(:issuer) && token.issuer.nil? && token.respond_to?(:with_issuer)

        current = stored_server_metadata&.issuer
        return nil unless current

        bound = token.with_issuer(current)
        begin
          storage.set_token(server_url, bound)
        rescue StandardError => e
          logger.debug("The stored OAuth token could not be re-stored with its issuer (#{e.class})")
        end
        bound
      end

      # The registration type of stored credentials, recognizing a Client
      # ID Metadata Document client persisted before the type was recorded
      # by its client id (the configured metadata URL).
      # @param client_info [ClientInfo]
      # @return [String]
      def resolved_registration_type(client_info)
        return client_info.registration_type if client_info.registration_type
        return 'cimd' if client_id_metadata_url && client_info.client_id == client_id_metadata_url

        client_info.effective_registration_type
      end

      # @param client_info [ClientInfo]
      # @return [Boolean] whether the client id is portable across authorization servers
      def portable_client?(client_info)
        resolved_registration_type(client_info) == 'cimd'
      end

      # @return [void]
      def delete_client_info
        # Prefer an explicit delete; fall back to the always-available
        # set_client_info(nil) so custom storage backends are handled too.
        # A backend that refuses either must not stop the authorization
        # server switch: the credentials stay bound to the previous issuer
        # and are discarded again by the next flow.
        if storage.respond_to?(:delete_client_info)
          storage.delete_client_info(server_url)
        else
          storage.set_client_info(server_url, nil)
        end
      rescue StandardError => e
        logger.warn('The OAuth client registration for the previous authorization server could not be removed ' \
                    "from storage (#{e.class}); implement delete_client_info(server_url) on the storage backend.")
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

        client_info = ClientInfo.new(client_id: client_id_metadata_url, metadata: metadata, registration_type: 'cimd')

        # Persist so complete_authorization_flow and token refresh can find it
        storage.set_client_info(server_url, client_info)

        client_info
      end

      # Validate a Client ID Metadata Document URL (SEP-991): "The client_id
      # URL MUST use the 'https' scheme and contain a path component, e.g.
      # https://example.com/client.json". Per the Client ID Metadata Document
      # draft the URL must also have a host and must not contain userinfo,
      # a fragment, or single-/double-dot path segments.
      # @param url [String] Candidate metadata URL
      # @return [String] The validated URL
      # @raise [ArgumentError] if the URL is invalid, not HTTPS, lacks a host or path
      #   component, or contains userinfo, a fragment, or dot path segments
      def validate_client_id_metadata_url(url)
        uri = URI.parse(url)
        raise ArgumentError, "client_id_metadata_url must be an HTTPS URL: #{url.inspect}" unless uri.is_a?(URI::HTTPS)

        raise ArgumentError, "client_id_metadata_url must include a host: #{url.inspect}" if uri.host.to_s.empty?

        raise ArgumentError, "client_id_metadata_url must not contain userinfo: #{url.inspect}" if uri.userinfo

        raise ArgumentError, "client_id_metadata_url must not contain a fragment: #{url.inspect}" if uri.fragment

        if uri.path.to_s.empty? || uri.path == '/'
          raise ArgumentError,
                'client_id_metadata_url must contain a path component ' \
                "(e.g. https://example.com/client.json): #{url.inspect}"
        end

        if uri.path.split('/').intersect?(['.', '..'])
          raise ArgumentError,
                "client_id_metadata_url must not contain '.' or '..' path segments: #{url.inspect}"
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
        logger.warn('Dynamic Client Registration is deprecated in MCP 2026-07-28; prefer a Client ID Metadata ' \
                    'Document (client_id_metadata_url) or pre-registered credentials')
        logger.debug("Registering OAuth client at: #{server_metadata.registration_endpoint}")

        app_type = resolved_application_type
        response = post_registration(server_metadata, app_type)

        # "Clients MAY retry registration with an adjusted application_type"
        # when an OIDC server rejects the redirect URI for the type derived
        # here (never for one the host chose explicitly).
        if !response.success? && application_type.nil? &&
           registration_error(response)[:error] == 'invalid_redirect_uri'
          alternate = app_type == 'native' ? 'web' : 'native'
          logger.warn("Client registration rejected the redirect URI for application_type #{app_type}; " \
                      "retrying as #{alternate}")
          app_type = alternate
          response = post_registration(server_metadata, app_type)
        end

        raise_registration_failure!(response) unless response.success?

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
          contacts: data['contacts'],
          application_type: data['application_type'] || app_type
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
          metadata: registered_metadata,
          # Bound to the authorization server that issued the credentials
          issuer: server_metadata.issuer,
          registration_type: 'dynamic'
        )

        # Store client info
        storage.set_client_info(server_url, client_info)

        client_info
      rescue JSON::ParserError => e
        raise MCPClient::Errors::ConnectionError, "Invalid client registration response: #{e.message}"
      rescue Faraday::Error => e
        raise MCPClient::Errors::ConnectionError, "Network error during client registration: #{e.message}"
      end

      # One Dynamic Client Registration request.
      # @param server_metadata [ServerMetadata]
      # @param app_type [String] the application_type to declare
      # @return [Faraday::Response]
      def post_registration(server_metadata, app_type)
        metadata = ClientMetadata.new(
          redirect_uris: [redirect_uri],
          token_endpoint_auth_method: 'none', # Public client
          grant_types: %w[authorization_code refresh_token],
          response_types: ['code'],
          scope: resolved_scope,
          application_type: app_type,
          **@extra_client_metadata
        )

        @http_client.post(server_metadata.registration_endpoint) do |req|
          req.headers['Content-Type'] = 'application/json'
          req.headers['Accept'] = 'application/json'
          req.body = metadata.to_h.to_json
        end
      end

      # "When a registration request is rejected, clients SHOULD surface a
      # meaningful error": the RFC 7591 error and description, when given.
      # @param response [Faraday::Response] the failed registration response
      # @raise [MCPClient::Errors::ConnectionError]
      def raise_registration_failure!(response)
        error = registration_error(response)
        detail = [error[:error], error[:error_description]].compact.join(': ')
        raise MCPClient::Errors::ConnectionError,
              "Client registration failed: HTTP #{response.status}#{" (#{detail})" unless detail.empty?}"
      end

      # The application_type to register: the host's explicit choice, else
      # 'native' for loopback and custom-scheme redirect URIs (desktop, CLI,
      # mobile, locally hosted apps) and 'web' for a remote redirect URI
      # (MCP 2026-07-28 "Application Type and Redirect URI Constraints").
      # @return [String]
      def resolved_application_type
        return application_type if application_type

        uri = URI.parse(redirect_uri.to_s)
        return 'native' unless %w[http https].include?(uri.scheme.to_s.downcase)

        loopback_host?(uri.host) ? 'native' : 'web'
      rescue URI::InvalidURIError
        'native'
      end

      # Whether a redirect URI host is a loopback interface: localhost or any
      # loopback address (127.0.0.0/8, ::1, in any spelling).
      # @param host [String, nil]
      # @return [Boolean]
      def loopback_host?(host)
        host = host.to_s.downcase.delete_prefix('[').delete_suffix(']')
        return true if LOOPBACK_HOSTS.include?(host)

        IPAddr.new(host).loopback?
      rescue ArgumentError # IPAddr::Error included
        false
      end

      # The RFC 7591 error of a failed registration response, sanitized for
      # a log line or exception message.
      # @param response [Faraday::Response]
      # @return [Hash] :error and :error_description (nil when absent)
      def registration_error(response)
        body = JSON.parse(response.body.to_s)
        return {} unless body.is_a?(Hash)

        { error: safe_error_text(body['error']), error_description: safe_error_text(body['error_description']) }
      rescue JSON::ParserError
        {}
      end

      # @param value [Object] peer-supplied text
      # @return [String, nil] printable, bounded text
      def safe_error_text(value)
        return nil unless value.is_a?(String)

        value.gsub(/[[:cntrl:]]/, ' ')[0, 200]
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

        # The redirect_uri the authorization request was made with (recorded
        # with the PKCE record), else the registered one
        registered_redirect_uri = (pkce.respond_to?(:redirect_uri) && pkce.redirect_uri) ||
                                  client_info.metadata.redirect_uris.first

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
          refresh_token: data['refresh_token'],
          issuer: server_metadata.issuer
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
        client_info = stored_client_info

        return nil unless server_metadata && client_info
        return nil unless refresh_permitted?(token, client_info, server_metadata)

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
          refresh_token: data['refresh_token'] || token.refresh_token,
          issuer: server_metadata.issuer
        )

        store_token(new_token)
        new_token
      rescue JSON::ParserError => e
        logger.warn("Invalid token refresh response: #{describe_parse_error(e)}")
        nil
      rescue Faraday::Error => e
        logger.warn("Network error during token refresh: #{e.message}")
        nil
      end

      # A refresh token (and a client secret) is only ever presented to the
      # authorization server that issued it (MCP 2026-07-28: registration
      # state and tokens are per authorization server).
      # @return [Boolean]
      def refresh_permitted?(token, client_info, server_metadata)
        issuer = token.respond_to?(:issuer) ? token.issuer : nil
        if issuer && issuer != server_metadata.issuer
          logger.warn('Not refreshing the token: the authorization server changed since it was issued')
          return false
        end
        # A token that does not say where it came from is not refreshed once
        # the authorization server is known to have changed.
        if issuer.nil? && @authorization_server_switched
          logger.warn('Not refreshing the token: it records no issuer and the authorization server changed')
          return false
        end
        if client_info.respond_to?(:issuer) && client_info.issuer && !client_info.portable? &&
           client_info.issuer != server_metadata.issuer
          logger.warn('Not refreshing the token: the client credentials belong to another authorization server')
          return false
        end
        true
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
