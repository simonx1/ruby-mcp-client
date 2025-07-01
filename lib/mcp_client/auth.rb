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
        "#{@token_type} #{@access_token}"
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
      attr_reader :redirect_uris, :token_endpoint_auth_method, :grant_types, :response_types, :scope

      # @param redirect_uris [Array<String>] List of valid redirect URIs
      # @param token_endpoint_auth_method [String] Authentication method for token endpoint
      # @param grant_types [Array<String>] Supported grant types
      # @param response_types [Array<String>] Supported response types
      # @param scope [String, nil] Requested scope
      def initialize(redirect_uris:, token_endpoint_auth_method: 'none',
                     grant_types: %w[authorization_code refresh_token],
                     response_types: ['code'], scope: nil)
        @redirect_uris = redirect_uris
        @token_endpoint_auth_method = token_endpoint_auth_method
        @grant_types = grant_types
        @response_types = response_types
        @scope = scope
      end

      # Convert to hash for HTTP requests
      # @return [Hash] Hash representation
      def to_h
        {
          redirect_uris: @redirect_uris,
          token_endpoint_auth_method: @token_endpoint_auth_method,
          grant_types: @grant_types,
          response_types: @response_types,
          scope: @scope
        }.compact
      end
    end

    # Registered OAuth client information
    class ClientInfo
      attr_reader :client_id, :client_secret, :client_id_issued_at, :client_secret_expires_at, :metadata

      # @param client_id [String] OAuth client ID
      # @param client_secret [String, nil] OAuth client secret (for confidential clients)
      # @param client_id_issued_at [Integer, nil] Unix timestamp when client ID was issued
      # @param client_secret_expires_at [Integer, nil] Unix timestamp when client secret expires
      # @param metadata [ClientMetadata] Client metadata
      def initialize(client_id:, metadata:, client_secret: nil, client_id_issued_at: nil,
                     client_secret_expires_at: nil)
        @client_id = client_id
        @client_secret = client_secret
        @client_id_issued_at = client_id_issued_at
        @client_secret_expires_at = client_secret_expires_at
        @metadata = metadata
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
          metadata: @metadata.to_h
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
          metadata: metadata
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
          scope: metadata_data[:scope] || metadata_data['scope']
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
                  :scopes_supported, :response_types_supported, :grant_types_supported

      # @param issuer [String] Issuer identifier URL
      # @param authorization_endpoint [String] Authorization endpoint URL
      # @param token_endpoint [String] Token endpoint URL
      # @param registration_endpoint [String, nil] Client registration endpoint URL
      # @param scopes_supported [Array<String>, nil] Supported OAuth scopes
      # @param response_types_supported [Array<String>, nil] Supported response types
      # @param grant_types_supported [Array<String>, nil] Supported grant types
      def initialize(issuer:, authorization_endpoint:, token_endpoint:, registration_endpoint: nil,
                     scopes_supported: nil, response_types_supported: nil, grant_types_supported: nil)
        @issuer = issuer
        @authorization_endpoint = authorization_endpoint
        @token_endpoint = token_endpoint
        @registration_endpoint = registration_endpoint
        @scopes_supported = scopes_supported
        @response_types_supported = response_types_supported
        @grant_types_supported = grant_types_supported
      end

      # Check if dynamic client registration is supported
      # @return [Boolean] true if registration endpoint is available
      def supports_registration?
        !@registration_endpoint.nil?
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
          grant_types_supported: @grant_types_supported
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
          grant_types_supported: data[:grant_types_supported] || data['grant_types_supported']
        )
      end
    end

    # Protected resource metadata for authorization server discovery
    class ResourceMetadata
      attr_reader :resource, :authorization_servers

      # @param resource [String] Resource server identifier
      # @param authorization_servers [Array<String>] List of authorization server URLs
      def initialize(resource:, authorization_servers:)
        @resource = resource
        @authorization_servers = authorization_servers
      end

      # Convert to hash
      # @return [Hash] Hash representation
      def to_h
        {
          resource: @resource,
          authorization_servers: @authorization_servers
        }
      end

      # Create resource metadata from hash
      # @param data [Hash] Resource metadata
      # @return [ResourceMetadata] New resource metadata instance
      def self.from_h(data)
        new(
          resource: data[:resource] || data['resource'],
          authorization_servers: data[:authorization_servers] || data['authorization_servers']
        )
      end
    end

    # PKCE (Proof Key for Code Exchange) helper
    class PKCE
      attr_reader :code_verifier, :code_challenge, :code_challenge_method

      # Generate PKCE parameters
      def initialize
        @code_verifier = generate_code_verifier
        @code_challenge = generate_code_challenge(@code_verifier)
        @code_challenge_method = 'S256'
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
