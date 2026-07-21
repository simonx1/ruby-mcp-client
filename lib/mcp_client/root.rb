# frozen_string_literal: true

require 'uri'

module MCPClient
  # Represents an MCP Root - a URI that defines a boundary where servers can operate
  # Roots are declared by clients to inform servers about relevant resources and their locations
  class Root
    attr_reader :uri, :name, :meta

    # Create a new Root
    # @param uri [String] The URI for the root. Per the MCP specification this
    #   MUST be a file:// URI ("This **MUST** be a `file://` URI in the current
    #   specification" - client/roots.mdx, 2025-11-25)
    # @param name [String, nil] Optional human-readable name for display purposes
    # @param meta [Hash, nil] Optional _meta field attached to the root (schema.ts Root._meta)
    # @raise [ArgumentError] if uri is not a valid file:// URI or contains '..' path segments
    def initialize(uri:, name: nil, meta: nil)
      validate_uri!(uri)
      # Root._meta is an object of arbitrary keys per the schema
      raise ArgumentError, "Root _meta must be a Hash, got #{meta.class}" if meta && !meta.is_a?(Hash)

      @uri = uri
      @name = name
      @meta = meta
    end

    # Create a Root from a JSON hash
    # @param json [Hash] The JSON hash with 'uri' and optional 'name' and '_meta' keys
    # @return [Root]
    # @raise [ArgumentError] if the uri is missing or not a valid file:// URI
    def self.from_json(json)
      new(
        uri: json['uri'] || json[:uri],
        name: json['name'] || json[:name],
        meta: json['_meta'] || json[:_meta]
      )
    end

    # Convert to JSON-serializable hash
    # @return [Hash]
    def to_h
      result = { 'uri' => @uri }
      result['name'] = @name if @name
      result['_meta'] = @meta if @meta
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

      uri == other.uri && name == other.name && meta == other.meta
    end

    alias eql? ==

    def hash
      [uri, name, meta].hash
    end

    # String representation
    def to_s
      name ? "#{name} (#{uri})" : uri
    end

    def inspect
      "#<MCPClient::Root uri=#{uri.inspect} name=#{name.inspect}>"
    end

    private

    # Validate that the uri is a well-formed file:// URI without path traversal.
    # Spec (client/roots.mdx, 2025-11-25): the root uri "MUST be a `file://` URI
    # in the current specification", and clients "MUST ... Validate all root
    # URIs to prevent path traversal".
    # @param uri [Object] the uri to validate
    # @return [void]
    # @raise [ArgumentError] if the uri is invalid
    def validate_uri!(uri)
      raise ArgumentError, 'Root uri must be a String, got nil' if uri.nil?
      raise ArgumentError, "Root uri must be a String, got #{uri.class}" unless uri.is_a?(String)

      # The schema requires the literal file:// form ("must start with
      # file://"), not merely a file scheme — file:relative and file:/path
      # forms are rejected.
      unless uri.downcase.start_with?('file://')
        raise ArgumentError,
              "Root uri must be a file:// URI (MCP spec: 'This MUST be a file:// URI'), got: #{uri.inspect}"
      end

      parsed = parse_uri(uri)
      # Decode before the traversal check so percent-encoded segments
      # (%2e%2e) cannot smuggle a '..' past validation.
      decoded_path = URI::DEFAULT_PARSER.unescape(parsed.path.to_s)
      return unless decoded_path.split('/').include?('..')

      raise ArgumentError, "Root uri must not contain '..' path traversal segments, got: #{uri.inspect}"
    end

    # Parse a URI string, converting parse errors to ArgumentError
    # @param uri [String] the uri string to parse
    # @return [URI::Generic]
    # @raise [ArgumentError] if the uri cannot be parsed
    def parse_uri(uri)
      URI.parse(uri)
    rescue URI::InvalidURIError => e
      raise ArgumentError, "Root uri is not a valid URI: #{uri.inspect} (#{e.message})"
    end
  end
end
