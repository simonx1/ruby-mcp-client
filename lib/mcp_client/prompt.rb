# frozen_string_literal: true

module MCPClient
  # Representation of an MCP prompt
  class Prompt
    # @!attribute [r] name
    #   @return [String] the name of the prompt
    # @!attribute [r] title
    #   @return [String, nil] optional human-readable name of the prompt for display purposes
    # @!attribute [r] description
    #   @return [String] the description of the prompt
    # @!attribute [r] arguments
    #   @return [Hash] the JSON arguments for the prompt
    # @!attribute [r] icons
    #   @return [Array<Hash>, nil] optional icons for display in user interfaces (MCP 2025-11-25, SEP-973)
    # @!attribute [r] meta
    #   @return [Hash, nil] optional `_meta` metadata attached to the prompt (MCP 2025-11-25)
    # @!attribute [r] server
    #   @return [MCPClient::ServerBase, nil] the server this prompt belongs to
    attr_reader :name, :title, :description, :arguments, :icons, :meta, :server

    # Initialize a new prompt
    # @param name [String] the name of the prompt
    # @param description [String] the description of the prompt
    # @param arguments [Hash] the JSON arguments for the prompt
    # @param title [String, nil] optional human-readable name of the prompt for display purposes
    # @param icons [Array<Hash>, nil] optional icons for display in user interfaces (MCP 2025-11-25)
    # @param meta [Hash, nil] optional `_meta` metadata attached to the prompt (MCP 2025-11-25)
    # @param server [MCPClient::ServerBase, nil] the server this prompt belongs to
    def initialize(name:, description:, arguments: {}, title: nil, icons: nil, meta: nil, server: nil)
      @name = name
      @title = title
      @description = description
      @arguments = arguments
      @icons = icons
      @meta = meta
      @server = server
    end

    # Create a Prompt instance from JSON data
    # @param data [Hash] JSON data from MCP server
    # @param server [MCPClient::ServerBase, nil] the server this prompt belongs to
    # @return [MCPClient::Prompt] prompt instance
    def self.from_json(data, server: nil)
      new(
        name: data['name'],
        title: data['title'],
        description: data['description'],
        arguments: data['arguments'] || {},
        icons: data['icons'],
        meta: data['_meta'],
        server: server
      )
    end
  end
end
