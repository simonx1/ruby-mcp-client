# frozen_string_literal: true

module MCPClient
  # Representation of MCP audio content (MCP 2025-11-25)
  # Used for base64-encoded audio data in messages and tool results
  class AudioContent
    # @!attribute [r] data
    #   @return [String] base64-encoded audio data
    # @!attribute [r] mime_type
    #   @return [String] MIME type of the audio (e.g., 'audio/wav', 'audio/mpeg', 'audio/ogg')
    # @!attribute [r] annotations
    #   @return [Hash, nil] optional annotations that provide hints to clients
    attr_reader :data, :mime_type, :annotations

    # Initialize audio content
    # @param data [String] base64-encoded audio data
    # @param mime_type [String] MIME type of the audio
    # @param annotations [Hash, nil] optional annotations that provide hints to clients
    def initialize(data:, mime_type:, annotations: nil)
      raise ArgumentError, 'AudioContent requires data' if data.nil? || data.empty?
      raise ArgumentError, 'AudioContent requires mime_type' if mime_type.nil? || mime_type.empty?

      @data = data
      @mime_type = mime_type
      @annotations = annotations
    end

    # Create an AudioContent instance from JSON data
    # @param data [Hash] JSON data from MCP server
    # @return [MCPClient::AudioContent] audio content instance
    def self.from_json(json_data)
      new(
        data: json_data['data'],
        mime_type: json_data['mimeType'],
        annotations: json_data['annotations']
      )
    end

    # Get the decoded audio content
    # @return [String] decoded binary audio data
    def content
      require 'base64'
      Base64.decode64(@data)
    end
  end
end
