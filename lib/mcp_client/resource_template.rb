# frozen_string_literal: true

module MCPClient
  # Representation of an MCP resource template
  # Resource templates allow servers to expose parameterized resources using URI templates
  class ResourceTemplate
    # @!attribute [r] uri_template
    #   @return [String] URI template following RFC 6570
    # @!attribute [r] name
    #   @return [String] the name of the resource template
    # @!attribute [r] title
    #   @return [String, nil] optional human-readable name for display purposes
    # @!attribute [r] description
    #   @return [String, nil] optional description
    # @!attribute [r] mime_type
    #   @return [String, nil] optional MIME type for resources created from this template
    # @!attribute [r] annotations
    #   @return [Hash, nil] optional annotations that provide hints to clients
    # @!attribute [r] server
    #   @return [MCPClient::ServerBase, nil] the server this resource template belongs to
    attr_reader :uri_template, :name, :title, :description, :mime_type, :annotations, :server

    # Initialize a new resource template
    # @param uri_template [String] URI template following RFC 6570
    # @param name [String] the name of the resource template
    # @param title [String, nil] optional human-readable name for display purposes
    # @param description [String, nil] optional description
    # @param mime_type [String, nil] optional MIME type
    # @param annotations [Hash, nil] optional annotations that provide hints to clients
    # @param server [MCPClient::ServerBase, nil] the server this resource template belongs to
    def initialize(uri_template:, name:, title: nil, description: nil, mime_type: nil, annotations: nil, server: nil)
      @uri_template = uri_template
      @name = name
      @title = title
      @description = description
      @mime_type = mime_type
      @annotations = annotations
      @server = server
    end

    # Create a ResourceTemplate instance from JSON data
    # @param data [Hash] JSON data from MCP server
    # @param server [MCPClient::ServerBase, nil] the server this resource template belongs to
    # @return [MCPClient::ResourceTemplate] resource template instance
    def self.from_json(data, server: nil)
      new(
        uri_template: data['uriTemplate'],
        name: data['name'],
        title: data['title'],
        description: data['description'],
        mime_type: data['mimeType'],
        annotations: data['annotations'],
        server: server
      )
    end
  end
end
