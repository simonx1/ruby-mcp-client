# frozen_string_literal: true

module MCPClient
  # Represents an MCP Root - a URI that defines a boundary where servers can operate
  # Roots are declared by clients to inform servers about relevant resources and their locations
  class Root
    attr_reader :uri, :name

    # Create a new Root
    # @param uri [String] The URI for the root (typically file:// URI)
    # @param name [String, nil] Optional human-readable name for display purposes
    def initialize(uri:, name: nil)
      @uri = uri
      @name = name
    end

    # Create a Root from a JSON hash
    # @param json [Hash] The JSON hash with 'uri' and optional 'name' keys
    # @return [Root]
    def self.from_json(json)
      new(
        uri: json['uri'] || json[:uri],
        name: json['name'] || json[:name]
      )
    end

    # Convert to JSON-serializable hash
    # @return [Hash]
    def to_h
      result = { 'uri' => @uri }
      result['name'] = @name if @name
      result
    end

    # Convert to JSON string
    # @return [String]
    def to_json(*)
      to_h.to_json(*)
    end

    # Check equality
    def ==(other)
      return false unless other.is_a?(Root)

      uri == other.uri && name == other.name
    end

    alias eql? ==

    def hash
      [uri, name].hash
    end

    # String representation
    def to_s
      name ? "#{name} (#{uri})" : uri
    end

    def inspect
      "#<MCPClient::Root uri=#{uri.inspect} name=#{name.inspect}>"
    end
  end
end
