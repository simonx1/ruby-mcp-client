# frozen_string_literal: true

module MCPClient
  # MCP 2026-07-28 Streamable HTTP "Custom Headers from Tool Parameters"
  # (SEP-2243). A tool's inputSchema may annotate a property with
  # `x-mcp-header`; on the Streamable HTTP transport the client mirrors the
  # argument value into an `Mcp-Param-{name}` request header so that
  # intermediaries can route on it without parsing the body.
  #
  # This module validates the annotations (clients MUST reject tool
  # definitions that violate the constraints) and extracts the header values
  # for a call (clients MUST mirror the designated values, omitting a header
  # whose argument is absent or null).
  module HeaderParams
    ANNOTATION = 'x-mcp-header'
    HEADER_PREFIX = 'Mcp-Param-'

    # HTTP field-name token: 1*tchar (RFC 9110 Section 5.6.2)
    TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

    # The only JSON Schema types an annotated property may have.
    PRIMITIVE_TYPES = %w[string integer boolean].freeze

    # Integer values must fit IEEE754 double precision exactly.
    SAFE_INTEGER_MAX = (2**53) - 1
    SAFE_INTEGER_MIN = -SAFE_INTEGER_MAX

    # Header value that may travel as-is: visible ASCII (0x21-0x7E), spaces
    # and tabs only in the interior (RFC 9110 field values; MCP 2026-07-28
    # Streamable HTTP "Value Encoding").
    HEADER_SAFE_VALUE = /\A[\x21-\x7E](?:[\x20-\x7E\t]*[\x21-\x7E])?\z/

    # The Base64 sentinel format; a plain value matching it must itself be
    # encoded to avoid ambiguity.
    BASE64_SENTINEL = /\A=\?base64\?.*\?=\z/m

    module_function

    # Check every `x-mcp-header` annotation in an inputSchema against the
    # transport's constraints.
    # @param schema [Hash, nil] the tool's inputSchema
    # @return [Array<String>] violations (empty when the schema is acceptable)
    def validate_schema(schema)
      return [] unless schema.is_a?(Hash)

      errors = []
      walk(schema, [], root: true, reachable: false, errors: errors, seen: {}, found: [])
      errors
    end

    # The statically reachable annotated properties of an inputSchema.
    # @param schema [Hash, nil] the tool's inputSchema
    # @return [Array<Array(Array<String>, String)>] [property path, header name] pairs
    def annotations(schema)
      return [] unless schema.is_a?(Hash)

      found = []
      walk(schema, [], root: true, reachable: false, errors: [], seen: {}, found: found)
      found
    end

    # The `Mcp-Param-*` headers for one tools/call.
    # @param schema [Hash, nil] the tool's inputSchema
    # @param arguments [Hash, nil] the call arguments (String or Symbol keys)
    # @return [Hash{String => String}] header name => encoded value
    # @raise [MCPClient::Errors::ValidationError] when an annotated argument cannot be mirrored
    def headers_for(schema, arguments)
      annotations(schema).each_with_object({}) do |(path, name), headers|
        value = dig_argument(arguments, path)
        next if value.nil?

        headers["#{HEADER_PREFIX}#{name}"] = encode_value(value, path)
      end
    end

    # Encode a parameter value for an MCP request header (Mcp-Name,
    # Mcp-Param-*): strings as-is when header-safe, integers in decimal,
    # booleans lowercase; anything not safely representable — non-ASCII,
    # control characters, leading/trailing whitespace, an empty string, or a
    # value that looks like the sentinel — as `=?base64?<b64 of UTF-8>?=`.
    # @param value [String, Integer, true, false] the parameter value
    # @return [String] the header value
    def encode_header_value(value)
      text = value.to_s
      return text if text.match?(HEADER_SAFE_VALUE) && !text.match?(BASE64_SENTINEL)

      "=?base64?#{[text.encode('UTF-8')].pack('m0')}?="
    end

    # Encode one mirrored argument, enforcing the primitive-type and safe
    # integer constraints.
    # @param value [Object] the argument value
    # @param path [Array<String>] the property path (for messages)
    # @return [String]
    # @raise [MCPClient::Errors::ValidationError]
    def encode_value(value, path)
      case value
      when Integer
        unless value.between?(SAFE_INTEGER_MIN, SAFE_INTEGER_MAX)
          raise MCPClient::Errors::ValidationError,
                "Argument #{path.join('.')} is mirrored into an HTTP header and must be within the safe " \
                "integer range (#{SAFE_INTEGER_MIN}..#{SAFE_INTEGER_MAX})"
        end
        value.to_s
      when String, true, false
        encode_header_value(value)
      else
        raise MCPClient::Errors::ValidationError,
              "Argument #{path.join('.')} is mirrored into an HTTP header and must be a primitive " \
              "(string, integer or boolean), got #{value.class}"
      end
    end

    # Read the argument at an exact property path, accepting String or
    # Symbol keys at each step.
    # @return [Object, nil] the value, nil when absent (or explicitly null)
    def dig_argument(arguments, path)
      path.reduce(arguments) do |node, key|
        return nil unless node.is_a?(Hash)

        node.key?(key) ? node[key] : node[key.to_sym]
      end
    end

    # JSON Schema 2020-12 keywords whose value is one subschema.
    SCHEMA_KEYWORDS = %w[additionalProperties items contains not if then else propertyNames
                         unevaluatedProperties unevaluatedItems additionalItems].freeze
    # Keywords whose value is a map of subschemas.
    SCHEMA_MAP_KEYWORDS = %w[properties patternProperties $defs definitions dependentSchemas].freeze
    # Keywords whose value is an array of subschemas.
    SCHEMA_ARRAY_KEYWORDS = %w[allOf anyOf oneOf prefixItems].freeze

    # Recursive schema walk over schema-bearing keywords only (instance data
    # such as `default`, `examples`, `enum` or `const` is never a schema). A
    # node is a *reachable property* when the chain from the root to it
    # consists solely of `properties` keys; annotations anywhere else (items,
    # composition and conditional keywords, $defs, $ref targets, the root
    # itself) invalidate the tool.
    # @api private
    def walk(node, path, root:, reachable:, errors:, seen:, found:)
      return unless node.is_a?(Hash)

      ctx = { errors: errors, seen: seen, found: found }
      check_annotation(node, path, reachable, errors, seen, found) if annotated?(node)
      node.each do |key, value|
        key_name = key.to_s
        if key_name == 'properties' && value.is_a?(Hash)
          value.each { |name, prop| walk(prop, path + [name.to_s], root: false, reachable: root || reachable, **ctx) }
        else
          subschemas(key_name, value).each { |sub| walk(sub, path + [key_name], root: false, reachable: false, **ctx) }
        end
      end
    end

    # The subschemas held by a keyword's value (none for instance data such
    # as default, examples, enum or const).
    # @api private
    def subschemas(key_name, value)
      if SCHEMA_MAP_KEYWORDS.include?(key_name)
        value.is_a?(Hash) ? value.values : []
      elsif SCHEMA_ARRAY_KEYWORDS.include?(key_name) || (key_name == 'items' && value.is_a?(Array))
        Array(value)
      elsif SCHEMA_KEYWORDS.include?(key_name)
        [value]
      else
        []
      end
    end

    # @api private
    def annotated?(node)
      node.key?(ANNOTATION) || node.key?(ANNOTATION.to_sym)
    end

    # @api private
    def check_annotation(node, path, reachable, errors, seen, found)
      value = node.key?(ANNOTATION) ? node[ANNOTATION] : node[ANNOTATION.to_sym]
      where = path.empty? ? 'the schema root' : path.join('.')

      unless value.is_a?(String)
        errors << "#{ANNOTATION} at #{where} must be a string"
        return
      end
      errors << "#{ANNOTATION} at #{where} must not be empty" if value.empty?
      if !value.empty? && !value.match?(TOKEN)
        errors << "#{ANNOTATION} at #{where} must be an HTTP field-name token (#{value.inspect})"
      end
      unless reachable
        errors << "#{ANNOTATION} at #{where} is not statically reachable via properties keys from the schema root"
      end

      type = node.key?('type') ? node['type'] : node[:type]
      unless type.is_a?(String) && PRIMITIVE_TYPES.include?(type)
        errors << "#{ANNOTATION} at #{where} must be on a primitive property (integer, string or boolean)"
      end

      key = value.downcase
      if seen.key?(key)
        errors << "#{ANNOTATION} values must be case-insensitively unique: #{value.inspect} at #{where} " \
                  "duplicates #{seen[key]}"
      else
        seen[key] = where
      end

      found << [path, value] if reachable && errors.empty?
    end
  end
end
