# frozen_string_literal: true

require 'open3'
require 'json'
require_relative 'version'
require 'logger'

module MCPClient
  # JSON-RPC implementation of MCP server over stdio.
  class ServerStdio < ServerBase
    require_relative 'server_stdio/json_rpc_transport'

    include JsonRpcTransport

    # @!attribute [r] command
    #   @return [String, Array] the command used to launch the server
    # @!attribute [r] env
    #   @return [Hash] environment variables for the subprocess
    attr_reader :command, :env

    # Timeout in seconds for responses
    READ_TIMEOUT = 15

    # Initialize a new ServerStdio instance
    # @param command [String, Array] the stdio command to launch the MCP JSON-RPC server
    #   For improved security, passing an Array is recommended to avoid shell injection issues
    # @param retries [Integer] number of retry attempts on transient errors
    # @param retry_backoff [Numeric] base delay in seconds for exponential backoff
    # @param read_timeout [Numeric] timeout in seconds for reading responses
    # @param name [String, nil] optional name for this server
    # @param logger [Logger, nil] optional logger
    # @param env [Hash] optional environment variables for the subprocess
    def initialize(command:, retries: 0, retry_backoff: 1, read_timeout: READ_TIMEOUT, name: nil, logger: nil, env: {})
      super(name: name)
      @command_array = command.is_a?(Array) ? command : nil
      @command = command.is_a?(Array) ? command.join(' ') : command
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @next_id = 1
      @pending = {}
      @initialized = false
      @server_info = nil
      @capabilities = nil
      initialize_logger(logger)
      @max_retries   = retries
      @retry_backoff = retry_backoff
      @read_timeout  = read_timeout
      @env           = env || {}
    end

    # Server info from the initialize response
    # @return [Hash, nil] Server information
    attr_reader :server_info

    # Server capabilities from the initialize response
    # @return [Hash, nil] Server capabilities
    attr_reader :capabilities

    # Connect to the MCP server by launching the command process via stdin/stdout
    # @return [Boolean] true if connection was successful
    # @raise [MCPClient::Errors::ConnectionError] if connection fails
    def connect
      if @command_array
        if @env.any?
          @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@env, *@command_array)
        else
          @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(*@command_array)
        end
      elsif @env.any?
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@env, @command)
      else
        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(@command)
      end
      true
    rescue StandardError => e
      raise MCPClient::Errors::ConnectionError, "Failed to connect to MCP server: #{e.message}"
    end

    # Spawn a reader thread to collect JSON-RPC responses
    # @return [Thread] the reader thread
    def start_reader
      @reader_thread = Thread.new do
        @stdout.each_line do |line|
          handle_line(line)
        end
      rescue StandardError
        # Reader thread aborted unexpectedly
      end
    end

    # Handle a line of output from the stdio server
    # Parses JSON-RPC messages and adds them to pending responses
    # @param line [String] line of output to parse
    # @return [void]
    def handle_line(line)
      msg = JSON.parse(line)
      @logger.debug("Received line: #{line.chomp}")
      # Dispatch JSON-RPC notifications (no id, has method)
      if msg['method'] && !msg.key?('id')
        @notification_callback&.call(msg['method'], msg['params'])
        return
      end
      # Handle standard JSON-RPC responses
      id = msg['id']
      return unless id

      @mutex.synchronize do
        @pending[id] = msg
        @cond.broadcast
      end
    rescue JSON::ParserError
      # Skip non-JSONRPC lines in the output stream
    end

    # List all prompts available from the MCP server
    # @return [Array<MCPClient::Prompt>] list of available prompts
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::PromptGetError] for other errors during prompt listing
    def list_prompts
      ensure_initialized
      req_id = next_id
      req = { 'jsonrpc' => '2.0', 'id' => req_id, 'method' => 'prompts/list', 'params' => {} }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      (res.dig('result', 'prompts') || []).map { |td| MCPClient::Prompt.from_json(td, server: self) }
    rescue StandardError => e
      raise MCPClient::Errors::PromptGetError, "Error listing prompts: #{e.message}"
    end

    # Get a prompt with the given parameters
    # @param prompt_name [String] the name of the prompt to get
    # @param parameters [Hash] the parameters to pass to the prompt
    # @return [Object] the result of the prompt interpolation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::PromptGetError] for other errors during prompt interpolation
    def get_prompt(prompt_name, parameters)
      ensure_initialized
      req_id = next_id
      # JSON-RPC method for getting a prompt
      req = {
        'jsonrpc' => '2.0',
        'id' => req_id,
        'method' => 'prompts/get',
        'params' => { 'name' => prompt_name, 'arguments' => parameters }
      }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      res['result']
    rescue StandardError => e
      raise MCPClient::Errors::PromptGetError, "Error calling prompt '#{prompt_name}': #{e.message}"
    end

    # List all resources available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resources array and optional nextCursor
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during resource listing
    def list_resources(cursor: nil)
      ensure_initialized
      req_id = next_id
      params = {}
      params['cursor'] = cursor if cursor
      req = { 'jsonrpc' => '2.0', 'id' => req_id, 'method' => 'resources/list', 'params' => params }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      result = res['result'] || {}
      resources = (result['resources'] || []).map { |td| MCPClient::Resource.from_json(td, server: self) }
      { 'resources' => resources, 'nextCursor' => result['nextCursor'] }
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error listing resources: #{e.message}"
    end

    # Read a resource by its URI
    # @param uri [String] the URI of the resource to read
    # @return [Array<MCPClient::ResourceContent>] array of resource contents
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during resource reading
    def read_resource(uri)
      ensure_initialized
      req_id = next_id
      # JSON-RPC method for reading a resource
      req = {
        'jsonrpc' => '2.0',
        'id' => req_id,
        'method' => 'resources/read',
        'params' => { 'uri' => uri }
      }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      result = res['result'] || {}
      contents = result['contents'] || []
      contents.map { |content| MCPClient::ResourceContent.from_json(content) }
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error reading resource '#{uri}': #{e.message}"
    end

    # List all resource templates available from the MCP server
    # @param cursor [String, nil] optional cursor for pagination
    # @return [Hash] result containing resourceTemplates array and optional nextCursor
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during resource template listing
    def list_resource_templates(cursor: nil)
      ensure_initialized
      req_id = next_id
      params = {}
      params['cursor'] = cursor if cursor
      req = { 'jsonrpc' => '2.0', 'id' => req_id, 'method' => 'resources/templates/list', 'params' => params }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      result = res['result'] || {}
      templates = (result['resourceTemplates'] || []).map { |td| MCPClient::ResourceTemplate.from_json(td, server: self) }
      { 'resourceTemplates' => templates, 'nextCursor' => result['nextCursor'] }
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error listing resource templates: #{e.message}"
    end

    # Subscribe to resource updates
    # @param uri [String] the URI of the resource to subscribe to
    # @return [Boolean] true if subscription successful
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during subscription
    def subscribe_resource(uri)
      ensure_initialized
      req_id = next_id
      req = {
        'jsonrpc' => '2.0',
        'id' => req_id,
        'method' => 'resources/subscribe',
        'params' => { 'uri' => uri }
      }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      true
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error subscribing to resource '#{uri}': #{e.message}"
    end

    # Unsubscribe from resource updates
    # @param uri [String] the URI of the resource to unsubscribe from
    # @return [Boolean] true if unsubscription successful
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ResourceReadError] for other errors during unsubscription
    def unsubscribe_resource(uri)
      ensure_initialized
      req_id = next_id
      req = {
        'jsonrpc' => '2.0',
        'id' => req_id,
        'method' => 'resources/unsubscribe',
        'params' => { 'uri' => uri }
      }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      true
    rescue StandardError => e
      raise MCPClient::Errors::ResourceReadError, "Error unsubscribing from resource '#{uri}': #{e.message}"
    end

    # List all tools available from the MCP server
    # @return [Array<MCPClient::Tool>] list of available tools
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool listing
    def list_tools
      ensure_initialized
      req_id = next_id
      # JSON-RPC method for listing tools
      req = { 'jsonrpc' => '2.0', 'id' => req_id, 'method' => 'tools/list', 'params' => {} }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      (res.dig('result', 'tools') || []).map { |td| MCPClient::Tool.from_json(td, server: self) }
    rescue StandardError => e
      raise MCPClient::Errors::ToolCallError, "Error listing tools: #{e.message}"
    end

    # Call a tool with the given parameters
    # @param tool_name [String] the name of the tool to call
    # @param parameters [Hash] the parameters to pass to the tool
    # @return [Object] the result of the tool invocation
    # @raise [MCPClient::Errors::ServerError] if server returns an error
    # @raise [MCPClient::Errors::ToolCallError] for other errors during tool execution
    def call_tool(tool_name, parameters)
      ensure_initialized
      req_id = next_id
      # JSON-RPC method for calling a tool
      req = {
        'jsonrpc' => '2.0',
        'id' => req_id,
        'method' => 'tools/call',
        'params' => { 'name' => tool_name, 'arguments' => parameters }
      }
      send_request(req)
      res = wait_response(req_id)
      if (err = res['error'])
        raise MCPClient::Errors::ServerError, err['message']
      end

      res['result']
    rescue StandardError => e
      raise MCPClient::Errors::ToolCallError, "Error calling tool '#{tool_name}': #{e.message}"
    end

    # Clean up the server connection
    # Closes all stdio handles and terminates any running processes and threads
    # @return [void]
    def cleanup
      return unless @stdin

      @stdin.close unless @stdin.closed?
      @stdout.close unless @stdout.closed?
      @stderr.close unless @stderr.closed?
      if @wait_thread&.alive?
        Process.kill('TERM', @wait_thread.pid)
        @wait_thread.join(1)
      end
      @reader_thread&.kill
    rescue StandardError
      # Clean up resources during unexpected termination
    ensure
      @stdin = @stdout = @stderr = @wait_thread = @reader_thread = nil
    end
  end
end
