# frozen_string_literal: true

module MCPClient
  # Representation of an MCP tool
  class Tool
    # @!attribute [r] name
    #   @return [String] the name of the tool
    # @!attribute [r] title
    #   @return [String, nil] optional human-readable name of the tool for display purposes
    # @!attribute [r] description
    #   @return [String] the description of the tool
    # @!attribute [r] schema
    #   @return [Hash] the JSON schema for the tool inputs
    # @!attribute [r] output_schema
    #   @return [Hash, nil] optional JSON schema for structured tool outputs (MCP 2025-06-18)
    # @!attribute [r] annotations
    #   @return [Hash, nil] optional annotations describing tool behavior (e.g., readOnly, destructive)
    # @!attribute [r] server
    #   @return [MCPClient::ServerBase, nil] the server this tool belongs to
    attr_reader :name, :title, :description, :schema, :output_schema, :annotations, :server

    # Initialize a new Tool
    # @param name [String] the name of the tool
    # @param description [String] the description of the tool
    # @param schema [Hash] the JSON schema for the tool inputs
    # @param title [String, nil] optional human-readable name of the tool for display purposes
    # @param output_schema [Hash, nil] optional JSON schema for structured tool outputs (MCP 2025-06-18)
    # @param annotations [Hash, nil] optional annotations describing tool behavior
    # @param server [MCPClient::ServerBase, nil] the server this tool belongs to
    def initialize(name:, description:, schema:, title: nil, output_schema: nil, annotations: nil, server: nil)
      @name = name
      @title = title
      @description = description
      @schema = schema
      @output_schema = output_schema
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
      output_schema = data['outputSchema'] || data[:outputSchema]
      annotations = data['annotations'] || data[:annotations]
      title = data['title'] || data[:title]
      new(
        name: data['name'] || data[:name],
        description: data['description'] || data[:description],
        schema: schema,
        title: title,
        output_schema: output_schema,
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

    # Check if the tool is marked as read-only (legacy annotation field)
    # @return [Boolean] true if the tool is read-only
    # @see #read_only_hint? for MCP 2025-11-25 annotation
    def read_only?
      !!(@annotations && @annotations['readOnly'] == true)
    end

    # Check if the tool is marked as destructive (legacy annotation field)
    # @return [Boolean] true if the tool is destructive
    # @see #destructive_hint? for MCP 2025-11-25 annotation
    def destructive?
      !!(@annotations && @annotations['destructive'] == true)
    end

    # Check if the tool requires confirmation before execution
    # @return [Boolean] true if the tool requires confirmation
    def requires_confirmation?
      !!(@annotations && @annotations['requiresConfirmation'] == true)
    end

    # Check the readOnlyHint annotation (MCP 2025-11-25)
    # When true, the tool does not modify its environment.
    # @return [Boolean] defaults to true when not specified
    def read_only_hint?
      return true unless @annotations

      fetch_annotation_hint('readOnlyHint', :readOnlyHint, true)
    end

    # Check the destructiveHint annotation (MCP 2025-11-25)
    # When true, the tool may perform destructive updates.
    # Only meaningful when readOnlyHint is false.
    # @return [Boolean] defaults to false when not specified
    def destructive_hint?
      return false unless @annotations

      fetch_annotation_hint('destructiveHint', :destructiveHint, false)
    end

    # Check the idempotentHint annotation (MCP 2025-11-25)
    # When true, calling the tool repeatedly with the same arguments has no additional effect.
    # Only meaningful when readOnlyHint is false.
    # @return [Boolean] defaults to false when not specified
    def idempotent_hint?
      return false unless @annotations

      fetch_annotation_hint('idempotentHint', :idempotentHint, false)
    end

    # Check the openWorldHint annotation (MCP 2025-11-25)
    # When true, the tool may interact with the "open world" (external entities).
    # @return [Boolean] defaults to true when not specified
    def open_world_hint?
      return true unless @annotations

      fetch_annotation_hint('openWorldHint', :openWorldHint, true)
    end

    # Check the readOnlyHint annotation (MCP 2025-11-25)
    # When true, the tool does not modify its environment.
    # @return [Boolean] defaults to true when not specified
    def read_only_hint?
      return true unless @annotations

      fetch_annotation_hint('readOnlyHint', :readOnlyHint, true)
    end

    # Check the destructiveHint annotation (MCP 2025-11-25)
    # When true, the tool may perform destructive updates.
    # Only meaningful when readOnlyHint is false.
    # @return [Boolean] defaults to false when not specified
    def destructive_hint?
      return false unless @annotations

      fetch_annotation_hint('destructiveHint', :destructiveHint, false)
    end

    # Check the idempotentHint annotation (MCP 2025-11-25)
    # When true, calling the tool repeatedly with the same arguments has no additional effect.
    # Only meaningful when readOnlyHint is false.
    # @return [Boolean] defaults to false when not specified
    def idempotent_hint?
      return false unless @annotations

      fetch_annotation_hint('idempotentHint', :idempotentHint, false)
    end

    # Check the openWorldHint annotation (MCP 2025-11-25)
    # When true, the tool may interact with the "open world" (external entities).
    # @return [Boolean] defaults to true when not specified
    def open_world_hint?
      return true unless @annotations

      fetch_annotation_hint('openWorldHint', :openWorldHint, true)
    end

    # Check if the tool supports structured outputs (MCP 2025-06-18)
    # @return [Boolean] true if the tool has an output schema defined
    def structured_output?
      !@output_schema.nil? && !@output_schema.empty?
    end

    private

    # Fetch a boolean annotation hint, checking both string and symbol keys.
    # Uses Hash#key? to correctly handle false values.
    # @param str_key [String] the string key to check
    # @param sym_key [Symbol] the symbol key to check
    # @param default [Boolean] the default value when the key is not present
    # @return [Boolean] the annotation value, or the default
    def fetch_annotation_hint(str_key, sym_key, default)
      return default unless @annotations.is_a?(Hash)

      if @annotations.key?(str_key)
        @annotations[str_key]
      elsif @annotations.key?(sym_key)
        @annotations[sym_key]
      else
        default
      end
    end

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
