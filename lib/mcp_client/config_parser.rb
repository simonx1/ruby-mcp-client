# frozen_string_literal: true

require 'json'
require 'logger'

module MCPClient
  # Parses MCP server definition JSON files into configuration hashes
  class ConfigParser
    # Reserved JSON keys that shouldn't be included in final config
    RESERVED_KEYS = %w[comment description].freeze

    # @param file_path [String] path to JSON file containing 'mcpServers' definitions
    # @param logger [Logger, nil] optional logger for warnings
    def initialize(file_path, logger: nil)
      @file_path = file_path
      @logger = logger || Logger.new($stdout, level: Logger::WARN)
    end

    # Parse the JSON config and return a mapping of server names to clean config hashes
    # @return [Hash<String, Hash>] server name => config hash with symbol keys
    def parse
      content = File.read(@file_path)
      data = JSON.parse(content)

      servers_data = extract_servers_data(data)
      servers_data = filter_reserved_keys(servers_data)

      result = {}
      servers_data.each do |server_name, config|
        next unless validate_server_config(config, server_name)

        server_config = process_server_config(config, server_name)
        next unless server_config

        # Add server name to the config
        server_config[:name] = server_name
        result[server_name] = server_config
      end

      result
    rescue Errno::ENOENT
      raise Errno::ENOENT, "Server definition file not found: #{@file_path}"
    rescue JSON::ParserError => e
      raise JSON::ParserError, "Invalid JSON in #{@file_path}: #{e.message}"
    end

    # Extract server data from parsed JSON
    # @param data [Object] parsed JSON data
    # @return [Hash] normalized server data
    def extract_servers_data(data)
      if data.is_a?(Hash) && data.key?('mcpServers') && data['mcpServers'].is_a?(Hash)
        data['mcpServers']
      elsif data.is_a?(Array)
        h = {}
        data.each_with_index { |cfg, idx| h[idx.to_s] = cfg }
        h
      elsif data.is_a?(Hash)
        { '0' => data }
      else
        @logger.warn("Invalid root JSON structure in #{@file_path}: #{data.class}")
        {}
      end
    end

    # Validate server configuration is a hash
    # @param config [Object] server configuration to validate
    # @param server_name [String] name of the server
    # @return [Boolean] true if valid, false otherwise
    def validate_server_config(config, server_name)
      return true if config.is_a?(Hash)

      @logger.warn("Configuration for server '#{server_name}' is not an object; skipping.")
      false
    end

    # Process a single server configuration
    # @param config [Hash] server configuration to process
    # @param server_name [String] name of the server
    # @return [Hash, nil] processed configuration or nil if invalid
    def process_server_config(config, server_name)
      type = determine_server_type(config, server_name)
      return nil unless type

      clean = { type: type.to_s }
      case type.to_s
      when 'stdio'
        parse_stdio_config(clean, config, server_name)
      when 'sse'
        return nil unless parse_sse_config(clean, config, server_name)
      when 'streamable_http'
        return nil unless parse_streamable_http_config(clean, config, server_name)
      when 'http'
        return nil unless parse_http_config(clean, config, server_name)
      else
        @logger.warn("Unrecognized type '#{type}' for server '#{server_name}'; skipping.")
        return nil
      end

      clean
    end

    # Determine the type of server from its configuration
    # @param config [Hash] server configuration
    # @param server_name [String] name of the server for logging
    # @return [String, nil] determined server type or nil if cannot be determined
    def determine_server_type(config, server_name)
      type = config['type']
      return type if type

      inferred_type = if config.key?('command') || config.key?('args') || config.key?('env')
                        'stdio'
                      elsif config.key?('url')
                        # Default to streamable_http unless URL contains "sse"
                        url = config['url'].to_s.downcase
                        url.include?('sse') ? 'sse' : 'streamable_http'
                      end

      if inferred_type
        @logger.warn("'type' not specified for server '#{server_name}', inferring as '#{inferred_type}'.")
        return inferred_type
      end

      @logger.warn("Could not determine type for server '#{server_name}' (missing 'command' or 'url'); skipping.")
      nil
    end

    private

    # Parse stdio-specific configuration
    # @param clean [Hash] clean configuration hash to update
    # @param config [Hash] raw configuration from JSON
    # @param server_name [String] name of the server for error reporting
    def parse_stdio_config(clean, config, server_name)
      # Command is required
      cmd = config['command']
      unless cmd.is_a?(String)
        @logger.warn("'command' for server '#{server_name}' is not a string; converting to string.")
        cmd = cmd.to_s
      end

      # Args are optional
      args = config['args']
      if args.is_a?(Array)
        args = args.map(&:to_s)
      elsif args
        @logger.warn("'args' for server '#{server_name}' is not an array; treating as single argument.")
        args = [args.to_s]
      else
        args = []
      end

      # Environment variables are optional
      env = config['env']
      env = env.is_a?(Hash) ? env.transform_keys(&:to_s) : {}

      # Update clean config
      clean[:command] = cmd
      clean[:args] = args
      clean[:env] = env
    end

    # Parse SSE-specific configuration
    # @param clean [Hash] clean configuration hash to update
    # @param config [Hash] raw configuration from JSON
    # @param server_name [String] name of the server for error reporting
    # @return [Boolean] true if parsing succeeded, false if required elements are missing
    def parse_sse_config(clean, config, server_name)
      # URL is required
      source = config['url']
      unless source
        @logger.warn("SSE server '#{server_name}' is missing required 'url' property; skipping.")
        return false
      end

      unless source.is_a?(String)
        @logger.warn("'url' for server '#{server_name}' is not a string; converting to string.")
        source = source.to_s
      end

      # Headers are optional
      headers = config['headers']
      headers = headers.is_a?(Hash) ? headers.transform_keys(&:to_s) : {}

      # Update clean config
      clean[:url] = source
      clean[:headers] = headers
      true
    end

    # Parse Streamable HTTP-specific configuration
    # @param clean [Hash] clean configuration hash to update
    # @param config [Hash] raw configuration from JSON
    # @param server_name [String] name of the server for error reporting
    # @return [Boolean] true if parsing succeeded, false if required elements are missing
    def parse_streamable_http_config(clean, config, server_name)
      # URL is required
      source = config['url']
      unless source
        @logger.warn("Streamable HTTP server '#{server_name}' is missing required 'url' property; skipping.")
        return false
      end

      unless source.is_a?(String)
        @logger.warn("'url' for server '#{server_name}' is not a string; converting to string.")
        source = source.to_s
      end

      # Headers are optional
      headers = config['headers']
      headers = headers.is_a?(Hash) ? headers.transform_keys(&:to_s) : {}

      # Endpoint is optional (defaults to '/rpc' in the transport)
      endpoint = config['endpoint']
      endpoint = endpoint.to_s if endpoint && !endpoint.is_a?(String)

      # Update clean config
      clean[:url] = source
      clean[:headers] = headers
      clean[:endpoint] = endpoint if endpoint
      true
    end

    # Parse HTTP-specific configuration
    # @param clean [Hash] clean configuration hash to update
    # @param config [Hash] raw configuration from JSON
    # @param server_name [String] name of the server for error reporting
    # @return [Boolean] true if parsing succeeded, false if required elements are missing
    def parse_http_config(clean, config, server_name)
      # URL is required
      source = config['url']
      unless source
        @logger.warn("HTTP server '#{server_name}' is missing required 'url' property; skipping.")
        return false
      end

      unless source.is_a?(String)
        @logger.warn("'url' for server '#{server_name}' is not a string; converting to string.")
        source = source.to_s
      end

      # Headers are optional
      headers = config['headers']
      headers = headers.is_a?(Hash) ? headers.transform_keys(&:to_s) : {}

      # Endpoint is optional (defaults to '/rpc' in the transport)
      endpoint = config['endpoint']
      endpoint = endpoint.to_s if endpoint && !endpoint.is_a?(String)

      # Update clean config
      clean[:url] = source
      clean[:headers] = headers
      clean[:endpoint] = endpoint if endpoint
      true
    end

    # Filter out reserved keys from configuration objects
    # @param data [Hash] configuration data
    # @return [Hash] filtered configuration data
    def filter_reserved_keys(data)
      return data unless data.is_a?(Hash)

      result = {}
      data.each do |key, value|
        # Skip reserved keys at server level
        next if RESERVED_KEYS.include?(key)

        # If value is a hash, recursively filter its keys too
        if value.is_a?(Hash)
          filtered_value = value.dup
          RESERVED_KEYS.each { |reserved| filtered_value.delete(reserved) }
          result[key] = filtered_value
        else
          result[key] = value
        end
      end
      result
    end
  end
end
