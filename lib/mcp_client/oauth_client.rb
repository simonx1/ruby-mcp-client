# frozen_string_literal: true

require_relative 'auth/oauth_provider'
require_relative 'server_http'
require_relative 'server_streamable_http'

module MCPClient
  # Utility class for creating OAuth-enabled MCP clients
  class OAuthClient
    # Create an OAuth-enabled HTTP server
    # @param server_url [String] The MCP server URL
    # @param options [Hash] Configuration options
    # @option options [String] :redirect_uri OAuth redirect URI (default: 'http://localhost:8080/callback')
    # @option options [String, nil] :scope OAuth scope
    # @option options [String] :endpoint JSON-RPC endpoint path (default: '/rpc')
    # @option options [Hash] :headers Additional headers to include in requests
    # @option options [Integer] :read_timeout Read timeout in seconds (default: 30)
    # @option options [Integer] :retries Retry attempts on transient errors (default: 3)
    # @option options [Numeric] :retry_backoff Base delay for exponential backoff (default: 1)
    # @option options [String, nil] :name Optional name for this server
    # @option options [Logger, nil] :logger Optional logger
    # @option options [Object, nil] :storage Storage backend for OAuth tokens and client info
    # @return [ServerHTTP] OAuth-enabled HTTP server
    def self.create_http_server(server_url:, **options)
      opts = default_server_options.merge(options)

      oauth_provider = Auth::OAuthProvider.new(
        server_url: server_url,
        redirect_uri: opts[:redirect_uri],
        scope: opts[:scope],
        logger: opts[:logger],
        storage: opts[:storage]
      )

      ServerHTTP.new(
        base_url: server_url,
        endpoint: opts[:endpoint],
        headers: opts[:headers],
        read_timeout: opts[:read_timeout],
        retries: opts[:retries],
        retry_backoff: opts[:retry_backoff],
        name: opts[:name],
        logger: opts[:logger],
        oauth_provider: oauth_provider
      )
    end

    # Create an OAuth-enabled Streamable HTTP server
    # @param server_url [String] The MCP server URL
    # @param options [Hash] Configuration options (same as create_http_server)
    # @return [ServerStreamableHTTP] OAuth-enabled Streamable HTTP server
    def self.create_streamable_http_server(server_url:, **options)
      opts = default_server_options.merge(options)

      oauth_provider = Auth::OAuthProvider.new(
        server_url: server_url,
        redirect_uri: opts[:redirect_uri],
        scope: opts[:scope],
        logger: opts[:logger],
        storage: opts[:storage]
      )

      ServerStreamableHTTP.new(
        base_url: server_url,
        endpoint: opts[:endpoint],
        headers: opts[:headers],
        read_timeout: opts[:read_timeout],
        retries: opts[:retries],
        retry_backoff: opts[:retry_backoff],
        name: opts[:name],
        logger: opts[:logger],
        oauth_provider: oauth_provider
      )
    end

    # Perform OAuth authorization flow for a server
    # This is a helper method that can be used to manually perform the OAuth flow
    # @param server [ServerHTTP, ServerStreamableHTTP] The OAuth-enabled server
    # @return [String] Authorization URL to redirect user to
    # @raise [ArgumentError] if server doesn't have OAuth provider
    def self.start_oauth_flow(server)
      oauth_provider = server.instance_variable_get(:@oauth_provider)
      raise ArgumentError, 'Server does not have OAuth provider configured' unless oauth_provider

      oauth_provider.start_authorization_flow
    end

    # Complete OAuth authorization flow with authorization code
    # @param server [ServerHTTP, ServerStreamableHTTP] The OAuth-enabled server
    # @param code [String] Authorization code from callback
    # @param state [String] State parameter from callback
    # @return [Auth::Token] Access token
    # @raise [ArgumentError] if server doesn't have OAuth provider
    def self.complete_oauth_flow(server, code, state)
      oauth_provider = server.instance_variable_get(:@oauth_provider)
      raise ArgumentError, 'Server does not have OAuth provider configured' unless oauth_provider

      oauth_provider.complete_authorization_flow(code, state)
    end

    # Check if server has a valid OAuth access token
    # @param server [ServerHTTP, ServerStreamableHTTP] The OAuth-enabled server
    # @return [Boolean] true if server has valid access token
    def self.valid_token?(server)
      oauth_provider = server.instance_variable_get(:@oauth_provider)
      return false unless oauth_provider

      token = oauth_provider.access_token
      !!(token && !token.expired?)
    end

    private_class_method def self.default_server_options
      {
        redirect_uri: 'http://localhost:8080/callback',
        scope: nil,
        endpoint: '/rpc',
        headers: {},
        read_timeout: 30,
        retries: 3,
        retry_backoff: 1,
        name: nil,
        logger: nil,
        storage: nil
      }
    end
  end
end
