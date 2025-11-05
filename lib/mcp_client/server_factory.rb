# frozen_string_literal: true

module MCPClient
  # Factory for creating MCP server instances based on configuration
  class ServerFactory
    # Create a server instance based on configuration
    # @param config [Hash] server configuration
    # @param logger [Logger, nil] optional logger to use for the server
    # @return [MCPClient::ServerBase] server instance
    def self.create(config, logger: nil)
      logger_to_use = config[:logger] || logger

      case config[:type]
      when 'stdio'
        create_stdio_server(config, logger_to_use)
      when 'sse'
        create_sse_server(config, logger_to_use)
      when 'http'
        create_http_server(config, logger_to_use)
      when 'streamable_http'
        create_streamable_http_server(config, logger_to_use)
      else
        raise ArgumentError, "Unknown server type: #{config[:type]}"
      end
    end

    # Create a stdio-based server
    # @param config [Hash] server configuration
    # @param logger [Logger, nil] logger to use
    # @return [MCPClient::ServerStdio] server instance
    def self.create_stdio_server(config, logger)
      cmd = prepare_command(config)

      MCPClient::ServerStdio.new(
        command: cmd,
        retries: config[:retries] || 0,
        retry_backoff: config[:retry_backoff] || 1,
        read_timeout: config[:read_timeout] || MCPClient::ServerStdio::READ_TIMEOUT,
        name: config[:name],
        logger: logger,
        env: config[:env] || {}
      )
    end

    # Create an SSE-based server
    # @param config [Hash] server configuration
    # @param logger [Logger, nil] logger to use
    # @return [MCPClient::ServerSSE] server instance
    def self.create_sse_server(config, logger)
      # Handle both :url and :base_url (config parser uses :url)
      base_url = config[:base_url] || config[:url]
      MCPClient::ServerSSE.new(
        base_url: base_url,
        headers: config[:headers] || {},
        read_timeout: config[:read_timeout] || 30,
        ping: config[:ping] || 10,
        retries: config[:retries] || 0,
        retry_backoff: config[:retry_backoff] || 1,
        name: config[:name],
        logger: logger
      )
    end

    # Create an HTTP-based server
    # @param config [Hash] server configuration
    # @param logger [Logger, nil] logger to use
    # @return [MCPClient::ServerHTTP] server instance
    def self.create_http_server(config, logger)
      # Handle both :url and :base_url (config parser uses :url)
      base_url = config[:base_url] || config[:url]
      MCPClient::ServerHTTP.new(
        base_url: base_url,
        endpoint: config[:endpoint] || '/rpc',
        headers: config[:headers] || {},
        read_timeout: config[:read_timeout] || 30,
        retries: config[:retries] || 3,
        retry_backoff: config[:retry_backoff] || 1,
        name: config[:name],
        logger: logger,
        oauth_provider: config[:oauth_provider]
      )
    end

    # Create a Streamable HTTP-based server
    # @param config [Hash] server configuration
    # @param logger [Logger, nil] logger to use
    # @return [MCPClient::ServerStreamableHTTP] server instance
    def self.create_streamable_http_server(config, logger)
      # Handle both :url and :base_url (config parser uses :url)
      base_url = config[:base_url] || config[:url]
      MCPClient::ServerStreamableHTTP.new(
        base_url: base_url,
        endpoint: config[:endpoint] || '/rpc',
        headers: config[:headers] || {},
        read_timeout: config[:read_timeout] || 30,
        retries: config[:retries] || 3,
        retry_backoff: config[:retry_backoff] || 1,
        name: config[:name],
        logger: logger,
        oauth_provider: config[:oauth_provider]
      )
    end

    # Prepare command by combining command and args
    # @param config [Hash] server configuration
    # @return [String, Array] prepared command
    def self.prepare_command(config)
      if config[:args] && !config[:args].empty?
        [config[:command]] + Array(config[:args])
      else
        config[:command]
      end
    end
  end
end
