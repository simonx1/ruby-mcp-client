# frozen_string_literal: true

module MCPClient
  # Representation of an MCP tool
  class Tool
    # @!attribute [r] name
    #   @return [String] the name of the tool
    # @!attribute [r] description
    #   @return [String] the description of the tool
    # @!attribute [r] schema
    #   @return [Hash] the JSON schema for the tool
    # @!attribute [r] annotations
    #   @return [Hash, nil] optional annotations describing tool behavior (e.g., readOnly, destructive)
    # @!attribute [r] server
    #   @return [MCPClient::ServerBase, nil] the server this tool belongs to
    attr_reader :name, :description, :schema, :annotations, :server

    # Initialize a new Tool
    # @param name [String] the name of the tool
    # @param description [String] the description of the tool
    # @param schema [Hash] the JSON schema for the tool
    # @param annotations [Hash, nil] optional annotations describing tool behavior
    # @param server [MCPClient::ServerBase, nil] the server this tool belongs to
    def initialize(name:, description:, schema:, annotations: nil, server: nil)
      @name = name
      @description = description
      @schema = schema
      @annotations = annotations
      @server = server
    end

    # Create a Tool instance from JSON data
    # @param data [Hash] JSON data from MCP server
    # @param server [MCPClient::ServerBase, nil] the server this tool belongs to
    # @return [MCPClient::Tool] tool instance
    def self.from_json(data, server: nil)
      # Some servers (Playwright MCP CLI) use 'inputSchema' instead of 'schema'
      # Handle both string and symbol keys
      schema = data['inputSchema'] || data[:inputSchema] || data['schema'] || data[:schema]
      annotations = data['annotations'] || data[:annotations]
      new(
        name: data['name'] || data[:name],
        description: data['description'] || data[:description],
        schema: schema,
        annotations: annotations,
        server: server
      )
    end

    # Convert tool to OpenAI function specification format
    # @return [Hash] OpenAI function specification
    def to_openai_tool
      {
        type: 'function',
        function: {
          name: @name,
          description: @description,
          parameters: @schema
        }
      }
    end

    # Convert tool to Anthropic Claude tool specification format
    # @return [Hash] Anthropic Claude tool specification
    def to_anthropic_tool
      {
        name: @name,
        description: @description,
        input_schema: @schema
      }
    end

    # Convert tool to Google Vertex AI tool specification format
    # @return [Hash] Google Vertex AI tool specification with cleaned schema
    def to_google_tool
      {
        name: @name,
        description: @description,
        parameters: cleaned_schema(@schema)
      }
    end

    # Check if the tool is marked as read-only
    # @return [Boolean] true if the tool is read-only
    def read_only?
      @annotations && @annotations['readOnly'] == true
    end

    # Check if the tool is marked as destructive
    # @return [Boolean] true if the tool is destructive
    def destructive?
      @annotations && @annotations['destructive'] == true
    end

    # Check if the tool requires confirmation before execution
    # @return [Boolean] true if the tool requires confirmation
    def requires_confirmation?
      @annotations && @annotations['requiresConfirmation'] == true
    end

    private

    # Recursively remove "$schema" keys that are not accepted by Vertex AI
    # @param obj [Object] schema element (Hash/Array/other)
    # @return [Object] cleaned schema without "$schema" keys
    def cleaned_schema(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), h|
          next if k == '$schema'

          h[k] = cleaned_schema(v)
        end
      when Array
        obj.map { |v| cleaned_schema(v) }
      else
        obj
      end
    end
  end
end
