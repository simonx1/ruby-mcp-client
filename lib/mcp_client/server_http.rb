# frozen_string_literal: true

require 'uri'
require 'json'
require 'monitor'
require 'logger'
require 'faraday'
require 'faraday/retry'
require 'faraday/follow_redirects'

module MCPClient
  # Implementation of MCP server that communicates via HTTP requests/responses
  # Useful for communicating with MCP servers that support HTTP-based transport
  # without Server-Sent Events streaming
  #
  # @note Elicitation Support (MCP 2025-06-18)
  #   This transport does NOT support server-initiated elicitation requests.
  #   The HTTP transport uses a pure request-response architecture where only the client
  #   can initiate requests. For elicitation support, use one of these transports instead:
  #   - ServerStdio: Full bidirectional JSON-RPC over stdin/stdout
  #   - ServerSSE: Server requests via SSE stream, client responses via HTTP POST
  #   - ServerStreamableHTTP: Server requests via SSE-formatted responses, client responses via HTTP POST
  class ServerHTTP < ServerBase
    require_relative 'server_http/json_rpc_transport'

    include JsonRpcTransport

    # Default values for connection settings
    DEFAULT_READ_TIMEOUT = 30
    DEFAULT_MAX_RETRIES = 3

    # @!attribute [r] base_url
    #   @return [String] The base URL of the MCP server
    # @!attribute [r] endpoint
    #   @return [String] The JSON-RPC endpoint path
    # @!attribute [r] tools
    #   @return [Array<MCPClient::Tool>, nil] List of available tools (nil if not fetched yet)
    attr_reader :base_url, :endpoint, :tools

    # Server information from initialize response
    # @return [Hash, nil] Server information
    attr_reader :server_info

    # Server capabilities from initialize response
    # @return [Hash, nil] Server capabilities
    attr_reader :capabilities

    # @param base_url [String] The base URL of the MCP server
    # @param options [Hash] Server configuration options
    # @option options [String] :endpoint JSON-RPC endpoint path (default: '/rpc')
    # @option options [Hash] :headers Additional headers to include in requests
    # @option options [Integer] :read_timeout Read timeout in seconds (default: 30)
    # @option options [Integer] :retries Retry attempts on transient errors (default: 3)
    # @option options [Numeric] :retry_backoff Base delay for exponential backoff (default: 1)
    # @option options [String, nil] :name Optional name for this server
    # @option options [Logger, nil] :logger Optional logger
    # @option options [MCPClient::Auth::OAuthProvider, nil] :oauth_provider Optional OAuth provider
    # @option options [Proc, nil] :faraday_config Optional block to customize the Faraday connection
    def initialize(base_url:, **options)
      opts = default_options.merge(options)
      super(name: opts[:name])
      initialize_logger(opts[:logger])

      @max_retries = opts[:retries]
      @retry_backoff = opts[:retry_backoff]

      # Validate and normalize base_url
      raise ArgumentError, "Invalid or insecure server URL: #{base_url}" unless valid_server_url?(base_url)

      # Normalize base_url and handle cases where full endpoint is provided in base_url
      uri = URI.parse(base_url.chomp('/'))

      # Helper to build base URL without default ports
      build_base_url = lambda do |parsed_uri|
        port_part = if parsed_uri.port &&
                       !((parsed_uri.scheme == 'http' && parsed_uri.port == 80) ||
                         (parsed_uri.scheme == 'https' && parsed_uri.port == 443))
                      ":#{parsed_uri.port}"
                    else
                      ''
                    end
        "#{parsed_uri.scheme}://#{parsed_uri.host}#{port_part}"
      end

      @base_url = build_base_url.call(uri)
      @endpoint = if uri.path && !uri.path.empty? && uri.path != '/' && opts[:endpoint] == '/rpc'
                    # If base_url contains a path and we're using default endpoint,
                    # treat the path as the endpoint and use the base URL without path
                    uri.path
                  else
                    # Standard case: base_url is just scheme://host:port, endpoint is separate
                    opts[:endpoint]
                  end

      # Set up headers for HTTP requests
      @headers = opts[:headers].merge({
                                        'Content-Type' => 'application/json',
                                        'Accept' => 'application/json',
                                        'User-Agent' => "ruby-mcp-client/#{MCPClient::VERSION}"
                                      })

      @read_timeout = opts[:read_timeout]
      @faraday_config = opts[:faraday_config]
      @tools = nil
      @tools_data = nil
      @request_id = 0
      @mutex = Monitor.new
      @connection_established = false
      @initialized = false
      @http_conn = nil
      @session_id = nil
      @oauth_provider = opts[:oauth_provider]
    end

    # Connect to the MCP server over HTTP
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      return true if @mutex.synchronize { @connection_established }

      begin
        @mutex.synchronize do
          @connection_established = false
          @initialized = false
        end

        # Test connectivity with a simple HTTP request
        test_connection

        # Perform MCP initialization handshake
        perform_initialize

        @mutex.synchronize do
          @connection_established = true
          @initialized = true
        end

        true
      rescue MCPClient::Errors::ConnectionError => e
        cleanup
        raise e
      rescue StandardError => e
        cleanup
        raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server at #{@base_url}: #{e.message}"
      end
    end

    # List all tools available from the MCP server
    # @return [Array<MCPClient::Tool>] list of available tools
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool listing
    def list_tools
      @mutex.synchronize do
        return @tools if @tools
      end

      begin
        ensure_connected

        tools_data = request_tools_list
        @mutex.synchronize do
          @tools = tools_data.map do |tool_data|
            MCPClient::Tool.from_json(tool_data, server: self)
          end
        end

        @mutex.synchronize { @tools }
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        # Re-raise these errors directly
        raise
      rescue StandardError => e
        raise MCPClient::Errors::ToolCallError, "Error listing tools: #{e.message}"
      end
    end

    # Call a tool with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool execution
    # @raise [MCPClient::Errors::ConnectionError] if server is disconnected
    def call_tool(tool_name, parameters)
      rpc_request('tools/call', {
                    name: tool_name,
                    arguments: parameters
                  })
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      # Re-raise connection/transport errors directly to match test expectations
      raise
    rescue StandardError => e
      # For all other errors, wrap in ToolCallError
      raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
    end

    # Override apply_request_headers to add session headers for MCP protocol
    def apply_request_headers(req, request)
      super

      # Add session header if we have one (for non-initialize requests)
      return unless @session_id && request['method'] != 'initialize'

      req.headers['Mcp-Session-Id'] = @session_id
      @logger.debug("Adding session header: Mcp-Session-Id: #{@session_id}")
    end

    # Override handle_successful_response to capture session ID
    def handle_successful_response(response, request)
      super

      # Capture session ID from initialize response with validation
      return unless request['method'] == 'initialize' && response.success?

      session_id = response.headers['mcp-session-id'] || response.headers['Mcp-Session-Id']
      if session_id
        if valid_session_id?(session_id)
          @session_id = session_id
          @logger.debug("Captured session ID: #{@session_id}")
        else
          @logger.warn("Invalid session ID format received: #{session_id.inspect}")
        end
      else
        @logger.warn('No session ID found in initialize response headers')
      end
    end

    # List all prompts available from the MCP server
    # @return [Array<MCPClient::Prompt>] list of available prompts
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::PromptGetError] for other errors during prompt listing
    def list_prompts
      @mutex.synchronize do
        return @prompts if @prompts
      end

      begin
        ensure_connected

        prompts_data = rpc_request('prompts/list')
        prompts = prompts_data['prompts'] || []

        @mutex.synchronize do
          @prompts = prompts.map do |prompt_data|
            MCPClient::Prompt.from_json(prompt_data, server: self)
          end
        end

        @mutex.synchronize { @prompts }
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        raise
      rescue StandardError => e
        raise MCPClient::Errors::PromptGetError, "Error listing prompts: #{e.message}"
      end
    end

    # Get a prompt with the given parameters
    # @param prompt_name [String] the name of the prompt to get
    # @param parameters [Hash] the parameters to pass to the prompt
    # @return [Object] the result of the prompt interpolation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::TransportError] if response isn't valid JSON
    # @raise [MCPClient::Errors::PromptGetError] for other errors during prompt interpolation
    def get_prompt(prompt_name, parameters)
      rpc_request('prompts/get', {
                    name: prompt_name,
                    arguments: parameters
                  })
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::PromptGetError, "Error getting prompt '#{prompt_name}': #{e.message}"
    end

    # List all resources available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resources array and optional nextCursor
    # @raise [MCPClient::Errors::ResourceReadError] if resources list retrieval fails
    def list_resources(cursor: nil)
      @mutex.synchronize do
        return @resources_result if @resources_result && !cursor
      end

      begin
        ensure_connected

        params = {}
        params['cursor'] = cursor if cursor
        result = rpc_request('resources/list', params)

        resources = (result['resources'] || []).map do |resource_data|
          MCPClient::Resource.from_json(resource_data, server: self)
        end

        resources_result = { 'resources' => resources, 'nextCursor' => result['nextCursor'] }

        @mutex.synchronize do
          @resources_result = resources_result unless cursor
        end

        resources_result
      rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
        raise
      rescue StandardError => e
        raise MCPClient::Errors::ResourceReadError, "Error listing resources: #{e.message}"
      end
    end

    # Read a resource by its URI
    # @param uri [String] the URI of the resource to read
    # @return [Array<MCPClient::ResourceContent>] array of resource contents
    # @raise [MCPClient::Errors::ResourceReadError] if resource reading fails
    def read_resource(uri)
      result = rpc_request('resources/read', { uri: uri })
      contents = result['contents'] || []
      contents.map { |content| MCPClient::ResourceContent.from_json(content) }
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error reading resource '#{uri}': #{e.message}"
    end

    # List all resource templates available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resourceTemplates array and optional nextCursor
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during resource template listing
    def list_resource_templates(cursor: nil)
      params = {}
      params['cursor'] = cursor if cursor
      result = rpc_request('resources/templates/list', params)

      templates = (result['resourceTemplates'] || []).map do |template_data|
        MCPClient::ResourceTemplate.from_json(template_data, server: self)
      end

      { 'resourceTemplates' => templates, 'nextCursor' => result['nextCursor'] }
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error listing resource templates: #{e.message}"
    end

    # Subscribe to resource updates
    # @param uri [String] the URI of the resource to subscribe to
    # @return [Boolean] true if subscription successful
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during subscription
    def subscribe_resource(uri)
      rpc_request('resources/subscribe', { uri: uri })
      true
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error subscribing to resource '#{uri}': #{e.message}"
    end

    # Unsubscribe from resource updates
    # @param uri [String] the URI of the resource to unsubscribe from
    # @return [Boolean] true if unsubscription successful
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during unsubscription
    def unsubscribe_resource(uri)
      rpc_request('resources/unsubscribe', { uri: uri })
      true
    rescue MCPClient::Errors::ConnectionError, MCPClient::Errors::TransportError, MCPClient::Errors::ServerError
      raise
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error unsubscribing from resource '#{uri}': #{e.message}"
    end

    # Stream tool call (default implementation returns single-value stream)
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Enumerator] stream of results
    def call_tool_streaming(tool_name, parameters)
      Enumerator.new do |yielder|
        yielder << call_tool(tool_name, parameters)
      end
    end

    # Terminate the current session (if any)
    # @return [Boolean] true if termination was successful or no session exists
    def terminate_session
      @mutex.synchronize do
        return true unless @session_id

        super
      end
    end

    # Clean up the server connection
    # Properly closes HTTP connections and clears cached state
    def cleanup
      @mutex.synchronize do
        # Attempt to terminate session before cleanup
        terminate_session if @session_id

        @connection_established = false
        @initialized = false

        @logger.debug('Cleaning up HTTP connection')

        # Close HTTP connection if it exists
        @http_conn = nil
        @session_id = nil

        @tools = nil
        @tools_data = nil
      end
    end

    private

    # Default options for server initialization
    # @return [Hash] Default options
    def default_options
      {
        endpoint: '/rpc',
        headers: {},
        read_timeout: DEFAULT_READ_TIMEOUT,
        retries: DEFAULT_MAX_RETRIES,
        retry_backoff: 1,
        name: nil,
        logger: nil,
        oauth_provider: nil,
        faraday_config: nil
      }
    end

    # Test basic connectivity to the HTTP endpoint
    # @return [void]
    # @raise [MCPClient::Errors::ConnectionError] if connection test fails
    def test_connection
      create_http_connection

      # Simple connectivity test - we'll use the actual initialize call
      # since there's no standard HTTP health check endpoint
    rescue Faraday::ConnectionFailed => e
      raise MCPClient::Errors::ConnectionError, "Cannot connect to server at #{@base_url}: #{e.message}"
    rescue Faraday::UnauthorizedError, Faraday::ForbiddenError => e
      error_status = e.response ? e.response[:status] : 'unknown'
      raise MCPClient::Errors::ConnectionError, "Authorization failed: HTTP #{error_status}"
    rescue Faraday::Error => e
      raise MCPClient::Errors::ConnectionError, "HTTP connection error: #{e.message}"
    end

    # Ensure connection is established
    # @return [void]
    # @raise [MCPClient::Errors::ConnectionError] if connection is not established
    def ensure_connected
      return if @mutex.synchronize { @connection_established && @initialized }

      @logger.debug('Connection not active, attempting to reconnect before request')
      cleanup
      connect
    end

    # Request the tools list using JSON-RPC
    # @return [Array<Hash>] the tools data
    # @raise [MCPClient::Errors::ToolCallError] if tools list retrieval fails
    def request_tools_list
      @mutex.synchronize do
        return @tools_data if @tools_data
      end

      result = rpc_request('tools/list')

      if result && result['tools']
        @mutex.synchronize do
          @tools_data = result['tools']
        end
        return @mutex.synchronize { @tools_data.dup }
      elsif result
        @mutex.synchronize do
          @tools_data = result
        end
        return @mutex.synchronize { @tools_data.dup }
      end

      raise MCPClient::Errors::ToolCallError, 'Failed to get tools list from JSON-RPC request'
    end
  end
end
