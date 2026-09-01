# frozen_string_literal: true

module MCPClient
  # Representation of MCP resource content
  # Resources can contain either text or binary data
  class ResourceContent
    # @!attribute [r] uri
    #   @return [String] unique identifier for the resource
    # @!attribute [r] name
    #   @return [String] the name of the resource
    # @!attribute [r] title
    #   @return [String, nil] optional human-readable name for display purposes
    # @!attribute [r] mime_type
    #   @return [String, nil] optional MIME type
    # @!attribute [r] text
    #   @return [String, nil] text content (mutually exclusive with blob)
    # @!attribute [r] blob
    #   @return [String, nil] base64-encoded binary content (mutually exclusive with text)
    # @!attribute [r] annotations
    #   @return [Hash, nil] optional annotations that provide hints to clients
    # @!attribute [r] meta
    #   @return [Hash, nil] optional `_meta` metadata attached to the resource contents (MCP 2025-11-25)
    attr_reader :uri, :name, :title, :mime_type, :text, :blob, :annotations, :meta

    # Initialize resource content
    # @param uri [String] unique identifier for the resource
    # @param name [String] the name of the resource
    # @param title [String, nil] optional human-readable name for display purposes
    # @param mime_type [String, nil] optional MIME type
    # @param text [String, nil] text content (mutually exclusive with blob)
    # @param blob [String, nil] base64-encoded binary content (mutually exclusive with text)
    # @param annotations [Hash, nil] optional annotations that provide hints to clients
    # @param meta [Hash, nil] optional `_meta` metadata attached to the resource contents (MCP 2025-11-25)
    def initialize(uri:, name:, title: nil, mime_type: nil, text: nil, blob: nil, annotations: nil, meta: nil)
      raise ArgumentError, 'ResourceContent cannot have both text and blob' if text && blob
      raise ArgumentError, 'ResourceContent must have either text or blob' if !text && !blob

      @uri = uri
      @name = name
      @title = title
      @mime_type = mime_type
      @text = text
      @blob = blob
      @annotations = annotations
      @meta = meta
    end

    # A copy that shares nothing mutable with the original (cached contents
    # are handed out as copies, so a caller's edits stay its own).
    # @param source [ResourceContent]
    # @return [void]
    def initialize_copy(source)
      super
      @text = source.text.dup if source.text
      @blob = source.blob.dup if source.blob
      @annotations = deep_copy(source.annotations)
      @meta = deep_copy(source.meta)
    end

    # Create a ResourceContent instance from JSON data
    # @param data [Hash] JSON data from MCP server
    # @return [MCPClient::ResourceContent] resource content instance
    def self.from_json(data)
      new(
        uri: data['uri'],
        name: data['name'],
        title: data['title'],
        mime_type: data['mimeType'],
        text: data['text'],
        blob: data['blob'],
        annotations: data['annotations'],
        meta: data['_meta']
      )
    end

    # Check if content is text
    # @return [Boolean] true if content is text
    def text?
      !@text.nil?
    end

    # Check if content is binary
    # @return [Boolean] true if content is binary
    def binary?
      !@blob.nil?
    end

    # Get the content (text or decoded blob)
    # @return [String] the content
    def content
      return @text if text?

      require 'base64'
      Base64.decode64(@blob)
    end

    private

    # @param value [Object] a JSON-like value
    # @return [Object] an independent copy
    def deep_copy(value)
      case value
      when Hash then value.to_h { |k, v| [k, deep_copy(v)] }
      when Array then value.map { |v| deep_copy(v) }
      when String then value.dup
      else value
      end
    end
  end
end
