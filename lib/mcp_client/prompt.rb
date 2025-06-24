# frozen_string_literal: true

module MCPClient
  # Representation of an MCP prompt
  class Prompt
    # @!attribute [r] name
    #   @return [String] the name of the prompt
    # @!attribute [r] description
    #   @return [String] the description of the prompt
    # @!attribute [r] server
    #   @return [MCPClient::ServerBase, nil] the server this prompt belongs to
    attr_reader :name, :description, :server

    # Initialize a new prompt
    # @param name [String] the name of the prompt
    # @param description [String] the description of the prompt
    # @param server [MCPClient::ServerBase, nil] the server this prompt belongs to
    def initialize(name:, description:, server: nil)
      @name = name
      @description = description
      @server = server
    end

    # Create a Prompt instance from JSON data
    # @param data [Hash] JSON data from MCP server
    # @param server [MCPClient::ServerBase, nil] the server this prompt belongs to
    # @return [MCPClient::Prompt] prompt instance
    def self.from_json(data, server: nil)
      new(
        name: data['name'],
        description: data['description'],
        server: server
      )
    end
  end
end
