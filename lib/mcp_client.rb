# frozen_string_literal: true

# Load all MCPClient components
require_relative 'mcp_client/errors'
require_relative 'mcp_client/tool'
require_relative 'mcp_client/prompt'
require_relative 'mcp_client/server_base'
require_relative 'mcp_client/server_stdio'
require_relative 'mcp_client/server_sse'
require_relative 'mcp_client/server_http'
require_relative 'mcp_client/server_streamable_http'
require_relative 'mcp_client/server_factory'
require_relative 'mcp_client/client'
require_relative 'mcp_client/version'
require_relative 'mcp_client/config_parser'
require_relative 'mcp_client/auth'
require_relative 'mcp_client/oauth_client'

# Model Context Protocol (MCP) Client module
# Provides a standardized way for agents to communicate with external tools and services
# through a protocol-based approach
module MCPClient
  # Create a new MCPClient client
  # @param mcp_server_configs [Array<Hash>] configurations for MCP servers
  # @param server_definition_file [String, nil] optional path to a JSON file defining server configurations
  #   The JSON may be a single server object or an array of server objects.
  # @param logger [Logger, nil] optional logger for client operations
  # @return [MCPClient::Client] new client instance
  def self.create_client(mcp_server_configs: [], server_definition_file: nil, logger: nil)
    require 'json'
    # Start with any explicit configs provided
    configs = Array(mcp_server_configs)
    # Load additional configs from a JSON file if specified
    if server_definition_file
      # Parse JSON definitions into clean config hashes
      parser = MCPClient::ConfigParser.new(server_definition_file, logger: logger)
      parsed = parser.parse
      parsed.each_value do |cfg|
        case cfg[:type].to_s
        when 'stdio'
          cmd_list = [cfg[:command]] + Array(cfg[:args])
          configs << MCPClient.stdio_config(
            command: cmd_list,
            name: cfg[:name],
            logger: logger,
            env: cfg[:env]
          )
        when 'sse'
          configs << MCPClient.sse_config(base_url: cfg[:url], headers: cfg[:headers] || {}, name: cfg[:name],
                                          logger: logger)
        when 'http'
          configs << MCPClient.http_config(base_url: cfg[:url], endpoint: cfg[:endpoint],
                                           headers: cfg[:headers] || {}, name: cfg[:name], logger: logger)
        when 'streamable_http'
          configs << MCPClient.streamable_http_config(base_url: cfg[:url], endpoint: cfg[:endpoint],
                                                      headers: cfg[:headers] || {}, name: cfg[:name], logger: logger)
        end
      end
    end
    MCPClient::Client.new(mcp_server_configs: configs, logger: logger)
  end

  # Create a standard server configuration for stdio
  # @param command [String, Array<String>] command to execute
  # @param name [String, nil] optional name for this server
  # @param logger [Logger, nil] optional logger for server operations
  # @return [Hash] server configuration
  def self.stdio_config(command:, name: nil, logger: nil, env: {})
    {
      type: 'stdio',
      command: command,
      name: name,
      logger: logger,
      env: env || {}
    }
  end

  # Create a standard server configuration for SSE
  # @param base_url [String] base URL for the server
  # @param headers [Hash] HTTP headers to include in requests
  # @param read_timeout [Integer] read timeout in seconds (default: 30)
  # @param ping [Integer] time in seconds after which to send ping if no activity (default: 10)
  # @param retries [Integer] number of retry attempts (default: 0)
  # @param retry_backoff [Integer] backoff delay in seconds (default: 1)
  # @param name [String, nil] optional name for this server
  # @param logger [Logger, nil] optional logger for server operations
  # @return [Hash] server configuration
  def self.sse_config(base_url:, headers: {}, read_timeout: 30, ping: 10, retries: 0, retry_backoff: 1,
                      name: nil, logger: nil)
    {
      type: 'sse',
      base_url: base_url,
      headers: headers,
      read_timeout: read_timeout,
      ping: ping,
      retries: retries,
      retry_backoff: retry_backoff,
      name: name,
      logger: logger
    }
  end

  # Create a standard server configuration for HTTP
  # @param base_url [String] base URL for the server
  # @param endpoint [String] JSON-RPC endpoint path (default: '/rpc')
  # @param headers [Hash] HTTP headers to include in requests
  # @param read_timeout [Integer] read timeout in seconds (default: 30)
  # @param retries [Integer] number of retry attempts (default: 3)
  # @param retry_backoff [Integer] backoff delay in seconds (default: 1)
  # @param name [String, nil] optional name for this server
  # @param logger [Logger, nil] optional logger for server operations
  # @return [Hash] server configuration
  def self.http_config(base_url:, endpoint: '/rpc', headers: {}, read_timeout: 30, retries: 3, retry_backoff: 1,
                       name: nil, logger: nil)
    {
      type: 'http',
      base_url: base_url,
      endpoint: endpoint,
      headers: headers,
      read_timeout: read_timeout,
      retries: retries,
      retry_backoff: retry_backoff,
      name: name,
      logger: logger
    }
  end

  # Create configuration for Streamable HTTP transport
  # This transport uses HTTP POST requests but expects Server-Sent Event formatted responses
  # @param base_url [String] Base URL of the MCP server
  # @param endpoint [String] JSON-RPC endpoint path (default: '/rpc')
  # @param headers [Hash] Additional headers to include in requests
  # @param read_timeout [Integer] Read timeout in seconds (default: 30)
  # @param retries [Integer] Number of retry attempts on transient errors (default: 3)
  # @param retry_backoff [Integer] Backoff delay in seconds (default: 1)
  # @param name [String, nil] Optional name for this server
  # @param logger [Logger, nil] Optional logger for server operations
  # @return [Hash] server configuration
  def self.streamable_http_config(base_url:, endpoint: '/rpc', headers: {}, read_timeout: 30, retries: 3,
                                  retry_backoff: 1, name: nil, logger: nil)
    {
      type: 'streamable_http',
      base_url: base_url,
      endpoint: endpoint,
      headers: headers,
      read_timeout: read_timeout,
      retries: retries,
      retry_backoff: retry_backoff,
      name: name,
      logger: logger
    }
  end
end
