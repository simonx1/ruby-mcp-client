# frozen_string_literal: true

module MCPClient
  # Representation of an MCP tool
  class Tool
    attr_reader :name, :description, :schema

    def initialize(name:, description:, schema:)
      @name = name
      @description = description
      @schema = schema
    end

    # Create a Tool instance from JSON data
    # @param data [Hash] JSON data from MCP server
    # @return [MCPClient::Tool] tool instance
    def self.from_json(data)
      # Some servers (Playwright MCP CLI) use 'inputSchema' instead of 'schema'
      schema = data['inputSchema'] || data['schema']
      new(
        name: data['name'],
        description: data['description'],
        schema: schema
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

    def to_google_tool
      {
        name: @name,
        description: @description,
        parameters: @schema
      }
    end
  end
end
