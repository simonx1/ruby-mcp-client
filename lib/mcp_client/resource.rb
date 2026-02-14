# frozen_string_literal: true

module MCPClient
  # Representation of an MCP resource
  class Resource
    # @!attribute [r] uri
    #   @return [String] unique identifier for the resource
    # @!attribute [r] name
    #   @return [String] the name of the resource
    # @!attribute [r] title
    #   @return [String, nil] optional human-readable name of the resource for display purposes
    # @!attribute [r] description
    #   @return [String, nil] optional description
    # @!attribute [r] mime_type
    #   @return [String, nil] optional MIME type
    # @!attribute [r] size
    #   @return [Integer, nil] optional size in bytes
    # @!attribute [r] annotations
    #   @return [Hash, nil] optional annotations that provide hints to clients
    # @!attribute [r] server
    #   @return [MCPClient::ServerBase, nil] the server this resource belongs to
    attr_reader :uri, :name, :title, :description, :mime_type, :size, :annotations, :server

    # Initialize a new resource
    # @param uri [String] unique identifier for the resource
    # @param name [String] the name of the resource
    # @param title [String, nil] optional human-readable name of the resource for display purposes
    # @param description [String, nil] optional description
    # @param mime_type [String, nil] optional MIME type
    # @param size [Integer, nil] optional size in bytes
    # @param annotations [Hash, nil] optional annotations that provide hints to clients
    # @param server [MCPClient::ServerBase, nil] the server this resource belongs to
    def initialize(uri:, name:, title: nil, description: nil, mime_type: nil, size: nil, annotations: nil, server: nil)
      @uri = uri
      @name = name
      @title = title
      @description = description
      @mime_type = mime_type
      @size = size
      @annotations = annotations
      @server = server
    end

    # Return the lastModified annotation value (ISO 8601 timestamp string)
    # @return [String, nil] the lastModified timestamp, or nil if not set
    def last_modified
      @annotations && @annotations['lastModified']
    end

    # Create a Resource instance from JSON data
    # @param data [Hash] JSON data from MCP server
    # @param server [MCPClient::ServerBase, nil] the server this resource belongs to
    # @return [MCPClient::Resource] resource instance
    def self.from_json(data, server: nil)
      new(
        uri: data['uri'],
        name: data['name'],
        title: data['title'],
        description: data['description'],
        mime_type: data['mimeType'],
        size: data['size'],
        annotations: data['annotations'],
        server: server
      )
    end
  end
end
