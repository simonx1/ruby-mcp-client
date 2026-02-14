# frozen_string_literal: true

# Load all MCPClient components
require_relative 'mcp_client/errors'
require_relative 'mcp_client/tool'
require_relative 'mcp_client/prompt'
require_relative 'mcp_client/resource'
require_relative 'mcp_client/resource_template'
require_relative 'mcp_client/resource_content'
require_relative 'mcp_client/root'
require_relative 'mcp_client/elicitation_validator'
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
  # Simplified connection API - auto-detects transport and returns connected client
  #
  # @param target [String, Array<String>] URL(s) or command for connection
  #   - URLs ending in /sse -> SSE transport
  #   - URLs ending in /mcp -> Streamable HTTP transport
  #   - stdio://command or Array commands -> stdio transport
  #   - Commands starting with npx, node, python, ruby, etc. -> stdio transport
  #   - Other HTTP URLs -> Try Streamable HTTP, fallback to SSE, then HTTP
  # Accepts keyword arguments for connection options:
  # - headers [Hash] HTTP headers for remote transports
  # - read_timeout [Integer] Request timeout in seconds (default: 30)
  # - retries [Integer] Retry attempts
  # - retry_backoff [Numeric] Backoff delay (default: 1)
  # - name [String] Optional server name
  # - logger [Logger] Optional logger
  # - env [Hash] Environment variables for stdio
  # - ping [Integer] Ping interval for SSE (default: 10)
  # - endpoint [String] JSON-RPC endpoint path (default: '/rpc')
  # - transport [Symbol] Force transport type (:stdio, :sse, :http, :streamable_http)
  # - sampling_handler [Proc] Handler for sampling requests
  # @yield [Faraday::Connection] Optional block for Faraday customization
  # @return [MCPClient::Client] Connected client ready to use
  # @raise [MCPClient::Errors::ConnectionError] if connection fails
  # @raise [MCPClient::Errors::TransportDetectionError] if transport cannot be determined
  #
  # @example Connect to SSE server
  #   client = MCPClient.connect('http://localhost:8000/sse')
  #
  # @example Connect to Streamable HTTP server
  #   client = MCPClient.connect('http://localhost:8000/mcp')
  #
  # @example Connect with options
  #   client = MCPClient.connect('http://api.example.com/mcp',
  #     headers: { 'Authorization' => 'Bearer token' },
  #     read_timeout: 60
  #   )
  #
  # @example Connect to stdio server
  #   client = MCPClient.connect('npx -y @modelcontextprotocol/server-filesystem /home')
  #   # or with Array
  #   client = MCPClient.connect(['npx', '-y', '@modelcontextprotocol/server-filesystem', '/home'])
  #
  # @example Connect to multiple servers
  #   client = MCPClient.connect(['http://server1/mcp', 'http://server2/sse'])
  #
  # @example Force transport type
  #   client = MCPClient.connect('http://custom-server.com', transport: :streamable_http)
  #
  # @example With Faraday customization
  #   client = MCPClient.connect('https://internal.server.com/mcp') do |faraday|
  #     faraday.ssl.cert_store = custom_cert_store
  #   end
  def self.connect(target, **, &)
    # Handle array targets: either a single stdio command or multiple server URLs
    if target.is_a?(Array)
      # Check if it's a stdio command array (elements are command parts, not URLs)
      if stdio_command_array?(target)
        connect_single(target, **, &)
      else
        # It's an array of server URLs/commands
        connect_multiple(target, **, &)
      end
    else
      connect_single(target, **, &)
    end
  end

  class << self
    private

    # Connect to a single server
    def connect_single(target, **options, &)
      transport = options[:transport]&.to_sym || detect_transport(target)

      case transport
      when :stdio
        connect_stdio(target, **options)
      when :sse
        connect_sse(target, **options)
      when :http
        connect_http(target, **options, &)
      when :streamable_http
        connect_streamable_http(target, **options, &)
      when :auto
        connect_with_fallback(target, **options, &)
      else
        raise Errors::TransportDetectionError, "Unknown transport: #{transport}"
      end
    end

    # Connect to multiple servers
    def connect_multiple(targets, **options, &faraday_config)
      configs = targets.map.with_index do |t, idx|
        server_name = options[:name] ? "#{options[:name]}_#{idx}" : "server_#{idx}"
        build_config_for_target(t, **options.merge(name: server_name), &faraday_config)
      end

      client = Client.new(
        mcp_server_configs: configs,
        logger: options[:logger],
        sampling_handler: options[:sampling_handler]
      )

      # Connect all servers
      client.servers.each(&:connect)
      client
    end

    # Connect via stdio transport
    def connect_stdio(target, **options)
      command = parse_stdio_command(target)
      config = stdio_config(command: command, **extract_stdio_options(options))
      create_and_connect_client(config, options)
    end

    # Connect via SSE transport
    def connect_sse(url, **options)
      config = sse_config(base_url: url.to_s, **extract_sse_options(options))
      create_and_connect_client(config, options)
    end

    # Connect via HTTP transport
    def connect_http(url, **options, &)
      config = http_config(base_url: url.to_s, **extract_http_options(options), &)
      create_and_connect_client(config, options)
    end

    # Connect via Streamable HTTP transport
    def connect_streamable_http(url, **options, &)
      config = streamable_http_config(base_url: url.to_s, **extract_http_options(options), &)
      create_and_connect_client(config, options)
    end

    # Create client and connect to server
    def create_and_connect_client(config, options)
      client = Client.new(
        mcp_server_configs: [config],
        logger: options[:logger],
        sampling_handler: options[:sampling_handler]
      )
      client.servers.first.connect
      client
    end

    # Try transports in order until one succeeds
    def connect_with_fallback(url, **options, &)
      require 'logger'
      logger = options[:logger] || Logger.new($stderr, level: Logger::WARN)
      errors = []

      # Try Streamable HTTP first (most modern)
      begin
        logger.debug("MCPClient.connect: Attempting Streamable HTTP connection to #{url}")
        return connect_streamable_http(url, **options, &)
      rescue Errors::ConnectionError, Errors::TransportError => e
        errors << "Streamable HTTP: #{e.message}"
        logger.debug("MCPClient.connect: Streamable HTTP failed: #{e.message}")
      end

      # Try SSE second
      begin
        logger.debug("MCPClient.connect: Attempting SSE connection to #{url}")
        return connect_sse(url, **options)
      rescue Errors::ConnectionError, Errors::TransportError => e
        errors << "SSE: #{e.message}"
        logger.debug("MCPClient.connect: SSE failed: #{e.message}")
      end

      # Try plain HTTP last
      begin
        logger.debug("MCPClient.connect: Attempting HTTP connection to #{url}")
        return connect_http(url, **options, &)
      rescue Errors::ConnectionError, Errors::TransportError => e
        errors << "HTTP: #{e.message}"
        logger.debug("MCPClient.connect: HTTP failed: #{e.message}")
      end

      raise Errors::ConnectionError,
            "Failed to connect to #{url}. Tried all transports:\n  #{errors.join("\n  ")}"
    end

    # Detect transport type from target
    def detect_transport(target)
      return :stdio if target.is_a?(Array) && stdio_command_array?(target)
      return :stdio if stdio_target?(target)

      uri = begin
        URI.parse(target.to_s)
      rescue URI::InvalidURIError
        raise Errors::TransportDetectionError, "Invalid URL: #{target}"
      end

      unless http_url?(uri)
        raise Errors::TransportDetectionError,
              "Cannot detect transport for non-HTTP URL: #{target}. " \
              'Use transport: option to specify explicitly.'
      end

      path = uri.path.to_s.downcase
      return :sse if path.end_with?('/sse')
      return :streamable_http if path.end_with?('/mcp')

      # Ambiguous HTTP URL - use fallback strategy
      :auto
    end

    # Check if target is a stdio command (string form)
    def stdio_target?(target)
      return false if target.is_a?(Array) # Arrays handled separately by stdio_command_array?

      target_str = target.to_s
      return true if target_str.start_with?('stdio://')
      return true if target_str.match?(/^(npx|node|python|python3|ruby|php|java|cargo|go run)\b/)

      false
    end

    # Check if an array represents a single stdio command (vs multiple server URLs)
    # A stdio command array has elements that are command parts, not URLs
    def stdio_command_array?(arr)
      return false unless arr.is_a?(Array) && arr.any?

      first = arr.first.to_s
      # If the first element looks like a URL, it's not a stdio command array
      return false if first.match?(%r{^https?://})
      return false if first.start_with?('stdio://')

      # If the first element is a known command executable, it's a stdio command array
      return true if first.match?(/^(npx|node|python|python3|ruby|php|java|cargo|go)$/)

      # If none of the elements look like URLs, assume it's a command array
      arr.none? { |el| el.to_s.match?(%r{^https?://}) }
    end

    # Check if URI is HTTP/HTTPS
    def http_url?(uri)
      %w[http https].include?(uri.scheme&.downcase)
    end

    # Parse stdio command from various formats
    def parse_stdio_command(target)
      return target if target.is_a?(Array)

      target_str = target.to_s
      if target_str.start_with?('stdio://')
        target_str.sub('stdio://', '')
      else
        target_str
      end
    end

    # Extract common options shared by all transports
    def extract_common_options(options)
      {
        name: options[:name],
        logger: options[:logger],
        read_timeout: options[:read_timeout],
        retries: options[:retries],
        retry_backoff: options[:retry_backoff]
      }.compact
    end

    # Extract HTTP transport specific options
    def extract_http_options(options)
      extract_common_options(options).merge({
        headers: options[:headers] || {},
        endpoint: options[:endpoint]
      }.compact)
    end

    # Extract SSE transport specific options
    def extract_sse_options(options)
      extract_common_options(options).merge({
        headers: options[:headers] || {},
        ping: options[:ping]
      }.compact)
    end

    # Extract stdio transport specific options
    def extract_stdio_options(options)
      extract_common_options(options).merge({
        env: options[:env] || {}
      }.compact)
    end

    # Build config hash for a target
    def build_config_for_target(target, **options, &)
      transport = options[:transport]&.to_sym || detect_transport(target)

      case transport
      when :stdio
        command = parse_stdio_command(target)
        stdio_config(command: command, **extract_stdio_options(options))
      when :sse
        sse_config(base_url: target.to_s, **extract_sse_options(options))
      when :http
        http_config(base_url: target.to_s, **extract_http_options(options), &)
      when :streamable_http, :auto
        # For multi-server, default to streamable_http without fallback
        streamable_http_config(base_url: target.to_s, **extract_http_options(options), &)
      else
        raise Errors::TransportDetectionError, "Unknown transport: #{transport}"
      end
    end
  end

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
  # @yieldparam faraday [Faraday::Connection] the configured connection instance for additional customization
  #   (e.g., SSL settings, custom middleware). The block is called after default configuration is applied.
  # @return [Hash] server configuration
  def self.http_config(base_url:, endpoint: '/rpc', headers: {}, read_timeout: 30, retries: 3, retry_backoff: 1,
                       name: nil, logger: nil, &faraday_config)
    {
      type: 'http',
      base_url: base_url,
      endpoint: endpoint,
      headers: headers,
      read_timeout: read_timeout,
      retries: retries,
      retry_backoff: retry_backoff,
      name: name,
      logger: logger,
      faraday_config: faraday_config
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
  # @yieldparam faraday [Faraday::Connection] the configured connection instance for additional customization
  #   (e.g., SSL settings, custom middleware). The block is called after default configuration is applied.
  # @return [Hash] server configuration
  def self.streamable_http_config(base_url:, endpoint: '/rpc', headers: {}, read_timeout: 30, retries: 3,
                                  retry_backoff: 1, name: nil, logger: nil, &faraday_config)
    {
      type: 'streamable_http',
      base_url: base_url,
      endpoint: endpoint,
      headers: headers,
      read_timeout: read_timeout,
      retries: retries,
      retry_backoff: retry_backoff,
      name: name,
      logger: logger,
      faraday_config: faraday_config
    }
  end
end
