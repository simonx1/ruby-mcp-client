# frozen_string_literal: true

require 'uri'
require 'json'
require 'base64'
require 'digest'
require 'securerandom'
require 'time'

module MCPClient
  # OAuth 2.1 implementation for MCP client authentication
  module Auth
    # OAuth token model representing access/refresh tokens
    class Token
      attr_reader :access_token, :token_type, :expires_in, :scope, :refresh_token, :expires_at

      # @param access_token [String] The access token
      # @param token_type [String] Token type (default: "Bearer")
      # @param expires_in [Integer, nil] Token lifetime in seconds
      # @param scope [String, nil] Token scope
      # @param refresh_token [String, nil] Refresh token for renewal
      def initialize(access_token:, token_type: 'Bearer', expires_in: nil, scope: nil, refresh_token: nil)
        @access_token = access_token
        @token_type = token_type
        @expires_in = expires_in
        @scope = scope
        @refresh_token = refresh_token
        @expires_at = expires_in ? Time.now + expires_in : nil
      end

      # Check if the token is expired
      # @return [Boolean] true if token is expired
      def expired?
        return false unless @expires_at

        Time.now >= @expires_at
      end

      # Check if the token is close to expiring (within 5 minutes)
      # @return [Boolean] true if token expires soon
      def expires_soon?
        return false unless @expires_at

        Time.now >= (@expires_at - 300) # 5 minutes buffer
      end

      # Convert token to authorization header value
      # @return [String] Authorization header value
      def to_header
        "#{@token_type.capitalize} #{@access_token}"
      end

      # Convert to hash for serialization
      # @return [Hash] Hash representation
      def to_h
        {
          access_token: @access_token,
          token_type: @token_type,
          expires_in: @expires_in,
          scope: @scope,
          refresh_token: @refresh_token,
          expires_at: @expires_at&.iso8601
        }
      end

      # Create token from hash
      # @param data [Hash] Token data
      # @return [Token] New token instance
      def self.from_h(data)
        token = new(
          access_token: data[:access_token] || data['access_token'],
          token_type: data[:token_type] || data['token_type'] || 'Bearer',
          expires_in: data[:expires_in] || data['expires_in'],
          scope: data[:scope] || data['scope'],
          refresh_token: data[:refresh_token] || data['refresh_token']
        )

        # Set expires_at if provided
        if (expires_at_str = data[:expires_at] || data['expires_at'])
          token.instance_variable_set(:@expires_at, Time.parse(expires_at_str))
        end

        token
      end
    end

    # OAuth client metadata for registration and authorization
    class ClientMetadata
      attr_reader :redirect_uris, :token_endpoint_auth_method, :grant_types, :response_types, :scope,
                  :client_name, :client_uri, :logo_uri, :tos_uri, :policy_uri, :contacts, :application_type

      # @param redirect_uris [Array<String>] List of valid redirect URIs
      # @param token_endpoint_auth_method [String] Authentication method for token endpoint
      # @param grant_types [Array<String>] Supported grant types
      # @param response_types [Array<String>] Supported response types
      # @param scope [String, nil] Requested scope
      # @param client_name [String, nil] Human-readable client name
      # @param client_uri [String, nil] URL of the client home page
      # @param logo_uri [String, nil] URL of the client logo
      # @param tos_uri [String, nil] URL of the client terms of service
      # @param policy_uri [String, nil] URL of the client privacy policy
      # @param contacts [Array<String>, nil] List of contact emails for the client
      # @param application_type [String, nil] OIDC application type ('native' or 'web'), required in
      #   Dynamic Client Registration by MCP 2026-07-28
      def initialize(redirect_uris:, token_endpoint_auth_method: 'none',
                     grant_types: %w[authorization_code refresh_token],
                     response_types: ['code'], scope: nil,
                     client_name: nil, client_uri: nil, logo_uri: nil,
                     tos_uri: nil, policy_uri: nil, contacts: nil, application_type: nil)
        @redirect_uris = redirect_uris
        @token_endpoint_auth_method = token_endpoint_auth_method
        @grant_types = grant_types
        @response_types = response_types
        @scope = scope
        @client_name = client_name
        @client_uri = client_uri
        @logo_uri = logo_uri
        @tos_uri = tos_uri
        @policy_uri = policy_uri
        @contacts = contacts
        @application_type = application_type
      end

      # Convert to hash for HTTP requests
      # @return [Hash] Hash representation
      def to_h
        {
          redirect_uris: @redirect_uris,
          token_endpoint_auth_method: @token_endpoint_auth_method,
          grant_types: @grant_types,
          response_types: @response_types,
          scope: @scope,
          client_name: @client_name,
          client_uri: @client_uri,
          logo_uri: @logo_uri,
          tos_uri: @tos_uri,
          policy_uri: @policy_uri,
          contacts: @contacts,
          application_type: @application_type
        }.compact
      end
    end

    # Registered OAuth client information
    class ClientInfo
      # How the client id was obtained (MCP 2026-07-28 client registration):
      # 'pre_registered' credentials belong to one authorization server and
      # must not be reused with another; 'dynamic' registrations are redone
      # for a new authorization server; 'cimd' (Client ID Metadata Document)
      # client ids are portable across authorization servers.
      REGISTRATION_TYPES = %w[pre_registered dynamic cimd].freeze

      attr_reader :client_id, :client_secret, :client_id_issued_at, :client_secret_expires_at, :metadata,
                  :issuer, :registration_type

      # @param client_id [String] OAuth client ID
      # @param client_secret [String, nil] OAuth client secret (for confidential clients)
      # @param client_id_issued_at [Integer, nil] Unix timestamp when client ID was issued
      # @param client_secret_expires_at [Integer, nil] Unix timestamp when client secret expires
      # @param metadata [ClientMetadata] Client metadata
      # @param issuer [String, nil] issuer identifier of the authorization server these credentials
      #   belong to (MCP 2026-07-28 "Authorization Server Binding")
      # @param registration_type [String, nil] one of REGISTRATION_TYPES (nil: unknown, treated like a
      #   dynamic registration)
      def initialize(client_id:, metadata:, client_secret: nil, client_id_issued_at: nil,
                     client_secret_expires_at: nil, issuer: nil, registration_type: nil)
        unless registration_type.nil? || REGISTRATION_TYPES.include?(registration_type)
          raise ArgumentError, "registration_type must be one of #{REGISTRATION_TYPES.join(', ')}"
        end

        @client_id = client_id
        @client_secret = client_secret
        @client_id_issued_at = client_id_issued_at
        @client_secret_expires_at = client_secret_expires_at
        @metadata = metadata
        @issuer = issuer
        @registration_type = registration_type
      end

      # @return [Boolean] whether the client id is portable across authorization servers
      def portable?
        @registration_type == 'cimd'
      end

      # @return [Boolean] whether these are pre-registered (static) credentials
      def pre_registered?
        @registration_type == 'pre_registered'
      end

      # A copy bound to an authorization server.
      # @param issuer [String] the issuer identifier
      # @return [ClientInfo]
      def with_issuer(issuer)
        self.class.new(client_id: @client_id, metadata: @metadata, client_secret: @client_secret,
                       client_id_issued_at: @client_id_issued_at, client_secret_expires_at: @client_secret_expires_at,
                       issuer: issuer, registration_type: @registration_type)
      end

      # Check if client secret is expired
      # @return [Boolean] true if client secret is expired
      def client_secret_expired?
        return false unless @client_secret_expires_at

        Time.now.to_i >= @client_secret_expires_at
      end

      # Convert to hash for serialization
      # @return [Hash] Hash representation
      def to_h
        {
          client_id: @client_id,
          client_secret: @client_secret,
          client_id_issued_at: @client_id_issued_at,
          client_secret_expires_at: @client_secret_expires_at,
          metadata: @metadata.to_h,
          issuer: @issuer,
          registration_type: @registration_type
        }.compact
      end

      # Create client info from hash
      # @param data [Hash] Client info data
      # @return [ClientInfo] New client info instance
      def self.from_h(data)
        metadata_data = data[:metadata] || data['metadata'] || {}
        metadata = build_metadata_from_hash(metadata_data)

        new(
          client_id: data[:client_id] || data['client_id'],
          client_secret: data[:client_secret] || data['client_secret'],
          client_id_issued_at: data[:client_id_issued_at] || data['client_id_issued_at'],
          client_secret_expires_at: data[:client_secret_expires_at] || data['client_secret_expires_at'],
          metadata: metadata,
          issuer: data[:issuer] || data['issuer'],
          registration_type: data[:registration_type] || data['registration_type']
        )
      end

      # Build ClientMetadata from hash data
      # @param metadata_data [Hash] Metadata hash
      # @return [ClientMetadata] Client metadata instance
      def self.build_metadata_from_hash(metadata_data)
        ClientMetadata.new(
          redirect_uris: metadata_data[:redirect_uris] || metadata_data['redirect_uris'] || [],
          token_endpoint_auth_method: extract_auth_method(metadata_data),
          grant_types: metadata_data[:grant_types] || metadata_data['grant_types'] ||
                       %w[authorization_code refresh_token],
          response_types: metadata_data[:response_types] || metadata_data['response_types'] || ['code'],
          scope: metadata_data[:scope] || metadata_data['scope'],
          client_name: metadata_data[:client_name] || metadata_data['client_name'],
          client_uri: metadata_data[:client_uri] || metadata_data['client_uri'],
          logo_uri: metadata_data[:logo_uri] || metadata_data['logo_uri'],
          tos_uri: metadata_data[:tos_uri] || metadata_data['tos_uri'],
          policy_uri: metadata_data[:policy_uri] || metadata_data['policy_uri'],
          contacts: metadata_data[:contacts] || metadata_data['contacts'],
          application_type: metadata_data[:application_type] || metadata_data['application_type']
        )
      end

      # Extract token endpoint auth method from metadata
      # @param metadata_data [Hash] Metadata hash
      # @return [String] Authentication method
      def self.extract_auth_method(metadata_data)
        metadata_data[:token_endpoint_auth_method] ||
          metadata_data['token_endpoint_auth_method'] || 'none'
      end
    end

    # OAuth authorization server metadata
    class ServerMetadata
      attr_reader :issuer, :authorization_endpoint, :token_endpoint, :registration_endpoint,
                  :scopes_supported, :response_types_supported, :grant_types_supported,
                  :code_challenge_methods_supported, :client_id_metadata_document_supported,
                  :authorization_response_iss_parameter_supported

      # @param issuer [String] Issuer identifier URL
      # @param authorization_endpoint [String] Authorization endpoint URL
      # @param token_endpoint [String] Token endpoint URL
      # @param registration_endpoint [String, nil] Client registration endpoint URL
      # @param scopes_supported [Array<String>, nil] Supported OAuth scopes
      # @param response_types_supported [Array<String>, nil] Supported response types
      # @param grant_types_supported [Array<String>, nil] Supported grant types
      # @param code_challenge_methods_supported [Array<String>, nil] Supported PKCE code challenge methods (RFC 8414)
      # @param client_id_metadata_document_supported [Boolean, nil] Whether the server accepts
      #   Client ID Metadata Document client IDs (MCP 2025-11-25 / SEP-991)
      # @param authorization_response_iss_parameter_supported [Boolean, nil] Whether the server includes
      #   the `iss` parameter in authorization responses (RFC 9207 Section 2.3, MCP 2026-07-28)
      def initialize(issuer:, authorization_endpoint:, token_endpoint:, registration_endpoint: nil,
                     scopes_supported: nil, response_types_supported: nil, grant_types_supported: nil,
                     code_challenge_methods_supported: nil, client_id_metadata_document_supported: nil,
                     authorization_response_iss_parameter_supported: nil)
        @issuer = issuer
        @authorization_endpoint = authorization_endpoint
        @token_endpoint = token_endpoint
        @registration_endpoint = registration_endpoint
        @scopes_supported = scopes_supported
        @response_types_supported = response_types_supported
        @grant_types_supported = grant_types_supported
        @code_challenge_methods_supported = code_challenge_methods_supported
        @client_id_metadata_document_supported = client_id_metadata_document_supported
        @authorization_response_iss_parameter_supported = authorization_response_iss_parameter_supported
      end

      # Whether the server advertises the RFC 9207 `iss` authorization
      # response parameter; when it does, a response without `iss` MUST be
      # rejected (MCP 2026-07-28 "Authorization Response Validation").
      # @return [Boolean]
      def iss_parameter_supported?
        @authorization_response_iss_parameter_supported == true
      end

      # Check if dynamic client registration is supported
      # @return [Boolean] true if registration endpoint is available
      def supports_registration?
        !@registration_endpoint.nil?
      end

      # Check if the server accepts clients using Client ID Metadata Documents
      # (MCP 2025-11-25 / SEP-991), i.e. HTTPS URLs as client identifiers
      # @return [Boolean] true if client_id_metadata_document_supported is true
      def supports_client_id_metadata_documents?
        @client_id_metadata_document_supported == true
      end

      # Convert to hash
      # @return [Hash] Hash representation
      def to_h
        {
          issuer: @issuer,
          authorization_endpoint: @authorization_endpoint,
          token_endpoint: @token_endpoint,
          registration_endpoint: @registration_endpoint,
          scopes_supported: @scopes_supported,
          response_types_supported: @response_types_supported,
          grant_types_supported: @grant_types_supported,
          code_challenge_methods_supported: @code_challenge_methods_supported,
          client_id_metadata_document_supported: @client_id_metadata_document_supported,
          authorization_response_iss_parameter_supported: @authorization_response_iss_parameter_supported
        }.compact
      end

      # Create server metadata from hash
      # @param data [Hash] Server metadata
      # @return [ServerMetadata] New server metadata instance
      def self.from_h(data)
        new(
          issuer: data[:issuer] || data['issuer'],
          authorization_endpoint: data[:authorization_endpoint] || data['authorization_endpoint'],
          token_endpoint: data[:token_endpoint] || data['token_endpoint'],
          registration_endpoint: data[:registration_endpoint] || data['registration_endpoint'],
          scopes_supported: data[:scopes_supported] || data['scopes_supported'],
          response_types_supported: data[:response_types_supported] || data['response_types_supported'],
          grant_types_supported: data[:grant_types_supported] || data['grant_types_supported'],
          code_challenge_methods_supported: data[:code_challenge_methods_supported] ||
            data['code_challenge_methods_supported'],
          client_id_metadata_document_supported: fetch_boolean(data, :client_id_metadata_document_supported),
          authorization_response_iss_parameter_supported:
            fetch_boolean(data, :authorization_response_iss_parameter_supported)
        )
      end

      # Fetch a possibly-false value from a hash by symbol or string key.
      # Unlike the `||` chains above, this preserves an explicit false.
      # @param data [Hash] Source hash
      # @param key [Symbol] Key to fetch
      # @return [Object, nil] The value, or nil when absent under both keys
      def self.fetch_boolean(data, key)
        return data[key] if data.key?(key)

        data[key.to_s]
      end
      private_class_method :fetch_boolean
    end

    # Protected resource metadata for authorization server discovery
    class ResourceMetadata
      attr_reader :resource, :authorization_servers, :scopes_supported

      # @param resource [String] Resource server identifier
      # @param authorization_servers [Array<String>] List of authorization server URLs
      # @param scopes_supported [Array<String>, nil] Scopes the resource supports (RFC 9728);
      #   per MCP, the default scope set when a challenge provides none
      def initialize(resource:, authorization_servers:, scopes_supported: nil)
        @resource = resource
        @authorization_servers = authorization_servers
        @scopes_supported = scopes_supported
      end

      # Convert to hash
      # @return [Hash] Hash representation
      def to_h
        {
          resource: @resource,
          authorization_servers: @authorization_servers,
          scopes_supported: @scopes_supported
        }.compact
      end

      # Create resource metadata from hash
      # @param data [Hash] Resource metadata
      # @return [ResourceMetadata] New resource metadata instance
      def self.from_h(data)
        new(
          resource: data[:resource] || data['resource'],
          authorization_servers: data[:authorization_servers] || data['authorization_servers'],
          scopes_supported: data[:scopes_supported] || data['scopes_supported']
        )
      end
    end

    # PKCE (Proof Key for Code Exchange) helper
    class PKCE
      attr_reader :code_verifier, :code_challenge, :code_challenge_method, :issuer

      # Generate PKCE parameters
      # @param code_verifier [String, nil] Existing code verifier (for deserialization)
      # @param code_challenge [String, nil] Existing code challenge (for deserialization)
      # @param code_challenge_method [String] Challenge method (default: 'S256')
      # @param issuer [String, nil] the selected authorization server's issuer, recorded with this
      #   per-request record for RFC 9207 validation of the authorization response (MCP 2026-07-28)
      def initialize(code_verifier: nil, code_challenge: nil, code_challenge_method: nil, issuer: nil)
        @code_verifier = code_verifier || generate_code_verifier
        @code_challenge = code_challenge || generate_code_challenge(@code_verifier)
        @code_challenge_method = code_challenge_method || 'S256'
        @issuer = issuer
      end

      # Convert to hash for serialization
      # @return [Hash] Hash representation
      def to_h
        hash = {
          code_verifier: @code_verifier,
          code_challenge: @code_challenge,
          code_challenge_method: @code_challenge_method
        }
        hash[:issuer] = @issuer if @issuer
        hash
      end

      # Create PKCE instance from hash
      # @param data [Hash] Hash with PKCE parameters (symbol or string keys)
      # @return [PKCE] New PKCE instance
      # @raise [ArgumentError] If required parameters are missing
      # @note code_challenge_method is optional and defaults to 'S256'.
      #   The code_challenge is not re-validated against code_verifier;
      #   callers are expected to provide values from a prior to_h round-trip.
      def self.from_h(data)
        verifier = data[:code_verifier] || data['code_verifier']
        challenge = data[:code_challenge] || data['code_challenge']
        method = data[:code_challenge_method] || data['code_challenge_method']
        issuer = data[:issuer] || data['issuer']

        raise ArgumentError, 'Missing code_verifier' unless verifier
        raise ArgumentError, 'Missing code_challenge' unless challenge

        new(code_verifier: verifier, code_challenge: challenge, code_challenge_method: method, issuer: issuer)
      end

      private

      # Generate a cryptographically random code verifier
      # @return [String] Base64url-encoded code verifier
      def generate_code_verifier
        # Generate 32 random bytes (256 bits) and base64url encode
        Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
      end

      # Generate code challenge from verifier using SHA256
      # @param verifier [String] Code verifier
      # @return [String] Base64url-encoded SHA256 hash
      def generate_code_challenge(verifier)
        digest = Digest::SHA256.digest(verifier)
        Base64.urlsafe_encode64(digest, padding: false)
      end
    end
  end
end
