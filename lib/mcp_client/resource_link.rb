# frozen_string_literal: true

module MCPClient
  # Representation of an MCP resource link in tool result content
  # A resource link references a server resource that can be read separately.
  # Used in tool results to point clients to available resources (MCP 2025-11-25).
  class ResourceLink
    # @!attribute [r] uri
    #   @return [String] URI of the linked resource
    # @!attribute [r] name
    #   @return [String] the name of the linked resource
    # @!attribute [r] description
    #   @return [String, nil] optional human-readable description
    # @!attribute [r] mime_type
    #   @return [String, nil] optional MIME type of the resource
    # @!attribute [r] annotations
    #   @return [Hash, nil] optional annotations that provide hints to clients
    attr_reader :uri, :name, :description, :mime_type, :annotations

    # Initialize a resource link
    # @param uri [String] URI of the linked resource
    # @param name [String] the name of the linked resource
    # @param description [String, nil] optional human-readable description
    # @param mime_type [String, nil] optional MIME type of the resource
    # @param annotations [Hash, nil] optional annotations that provide hints to clients
    def initialize(uri:, name:, description: nil, mime_type: nil, annotations: nil)
      @uri = uri
      @name = name
      @description = description
      @mime_type = mime_type
      @annotations = annotations
    end

    # Create a ResourceLink instance from JSON data
    # @param data [Hash] JSON data from MCP server (content item with type 'resource_link')
    # @return [MCPClient::ResourceLink] resource link instance
    def self.from_json(data)
      new(
        uri: data['uri'],
        name: data['name'],
        description: data['description'],
        mime_type: data['mimeType'],
        annotations: data['annotations']
      )
    end

    # The content type identifier for this content type
    # @return [String] 'resource_link'
    def type
      'resource_link'
    end
  end
end
