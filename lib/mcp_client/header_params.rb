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
    # HTTP field names are case-insensitive, so membership of the mirrored
    # namespace is decided on the lower-cased name.
    HEADER_PREFIX_DOWNCASE = HEADER_PREFIX.downcase.freeze

    # HTTP field-name token: 1*tchar (RFC 9110 Section 5.6.2)
    TOKEN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

    # The only JSON Schema types an annotated property may have.
    PRIMITIVE_TYPES = %w[string integer boolean].freeze

    # Integer values must fit IEEE754 double precision exactly.
    SAFE_INTEGER_MAX = (2**53) - 1
    SAFE_INTEGER_MIN = -SAFE_INTEGER_MAX

    # Header value that may travel as-is: visible ASCII (0x21-0x7E), spaces
    # and tabs only in the interior (RFC 9110 field values; MCP 2026-07-28
    # Streamable HTTP "Value Encoding"). RFC 9110 field values may also be
    # empty, so an empty string travels as an empty field value rather than
    # as an encoding of nothing.
    HEADER_SAFE_VALUE = /\A(?:[\x21-\x7E](?:[\x20-\x7E\t]*[\x21-\x7E])?)?\z/

    # The Base64 sentinel markers; a plain value that starts with the one and
    # ends with the other must itself be encoded to avoid ambiguity. The rule
    # is on the start and the end alone: "=?base64?=" is sentinel-shaped even
    # though its two markers overlap.
    BASE64_SENTINEL_START = '=?base64?'
    BASE64_SENTINEL_END = '?='

    module_function

    # Check every `x-mcp-header` annotation in an inputSchema against the
    # transport's constraints.
    # @param schema [Hash, nil] the tool's inputSchema
    # @return [Array<String>] violations (empty when the schema is acceptable)
    def validate_schema(schema)
      return [] unless schema.is_a?(Hash)

      errors = []
      walk(schema, [], root: true, reachable: false, document: schema, errors: errors, seen: {}, found: [])
      errors
    end

    # The statically reachable annotated properties of an inputSchema.
    # @param schema [Hash, nil] the tool's inputSchema
    # @return [Array<Array(Array<String>, String)>] [property path, header name] pairs
    def annotations(schema)
      return [] unless schema.is_a?(Hash)

      found = []
      walk(schema, [], root: true, reachable: false, document: schema, errors: [], seen: {}, found: found)
      found
    end

    # Whether an HTTP header name belongs to the mirrored namespace, which
    # the client owns on a modern session: its members are derived from the
    # call's arguments and from nothing else.
    # @param name [String, Symbol] an HTTP header name
    # @return [Boolean]
    def mirrored_header?(name)
      name.to_s.downcase.start_with?(HEADER_PREFIX_DOWNCASE)
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
    # control characters, leading/trailing whitespace, or a value that looks
    # like the sentinel — as `=?base64?<b64 of UTF-8>?=`.
    #
    # A Ruby String carries an encoding of its own, and the value being
    # mirrored is the one the JSON body carries: UTF-8. The conversion
    # therefore comes first — deciding header safety on, say, UTF-16 bytes
    # would be deciding it on a different string (and an ASCII pattern cannot
    # even be matched against one).
    # @param value [String, Integer, true, false] the parameter value
    # @return [String] the header value
    def encode_header_value(value)
      text = value.to_s.encode('UTF-8')
      return text if text.match?(HEADER_SAFE_VALUE) && !sentinel_shaped?(text)

      "=?base64?#{[text].pack('m0')}?="
    end

    # Encode one mirrored argument, enforcing the primitive-type and safe
    # integer constraints.
    # @param value [Object] the argument value
    # @param path [Array<String>] the property path (for messages)
    # @return [String]
    # @raise [MCPClient::Errors::ValidationError]
    def encode_value(value, path)
      # JSON has no integer type: a schema integer may be parsed as 42.0.
      value = value.to_i if value.is_a?(Float) && value.finite? && value == value.floor
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

    # @param text [String] a UTF-8 header value
    # @return [Boolean] whether the value would read as a Base64 sentinel
    def sentinel_shaped?(text)
      text.start_with?(BASE64_SENTINEL_START) && text.end_with?(BASE64_SENTINEL_END)
    end

    # Read the argument at an exact property path, accepting String or
    # Symbol keys at each step. A step given under both kinds of key with
    # different values is rejected: the JSON body serializes both, which one
    # the server reads is its business, and no header can agree with an
    # argument that is two values.
    # @return [Object, nil] the value, nil when absent (or explicitly null)
    # @raise [MCPClient::Errors::ValidationError] on conflicting String/Symbol keys
    def dig_argument(arguments, path)
      path.reduce(arguments) do |node, key|
        return nil unless node.is_a?(Hash)

        if node.key?(key) && node.key?(key.to_sym) && node[key] != node[key.to_sym]
          raise MCPClient::Errors::ValidationError,
                "Argument #{path.join('.')} is given under both a String and a Symbol key with different values"
        end
        node.key?(key) ? node[key] : node[key.to_sym]
      end
    end

    # JSON Schema 2020-12 keywords whose value is one subschema.
    SCHEMA_KEYWORDS = %w[additionalProperties items contains not if then else propertyNames
                         unevaluatedProperties unevaluatedItems additionalItems contentSchema].freeze
    # Keywords whose value is a map of subschemas (draft-07 `dependencies`
    # may hold schemas too).
    SCHEMA_MAP_KEYWORDS = %w[properties patternProperties $defs definitions dependentSchemas dependencies].freeze
    # Keywords whose value is an array of subschemas.
    SCHEMA_ARRAY_KEYWORDS = %w[allOf anyOf oneOf prefixItems].freeze

    # Recursive schema walk over schema-bearing keywords only (instance data
    # such as `default`, `examples`, `enum` or `const` is never a schema). A
    # node is a *reachable property* when the chain from the root to it
    # consists solely of `properties` keys; annotations anywhere else (items,
    # composition and conditional keywords, $defs, $ref targets, the root
    # itself) invalidate the tool.
    # @api private
    def walk(node, path, root:, reachable:, document:, errors:, seen:, found:)
      return unless node.is_a?(Hash)

      ctx = { document: document, errors: errors, seen: seen, found: found }
      check_annotation(node, path, reachable, document, errors, seen, found) if annotated?(node)
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

    # Whether a property schema declares exactly one of the primitive types.
    #
    # A type array naming the one type is the same declaration as the bare
    # string, and JSON Schema has no other way to spell a nullable primitive
    # than to union it with "null": the constraint is on the property's type,
    # while a null *value* has its own rule -- the header is omitted -- so
    # dropping the whole tool over `["string", "null"]` would reject a schema
    # the transport can mirror perfectly well.
    #
    # A property that states its type through a reference states it all the
    # same: JSON Schema 2020-12 evaluates `$ref` beside its siblings (Core
    # 8.2.3.1), so `{"$ref": "#/$defs/r", "x-mcp-header": "Region"}` is a
    # primitive property whenever the target is one. That is separate from
    # the reachability rule, which is about where the ANNOTATION sits and
    # still never passes through a reference.
    # @api private
    def primitive_type?(node, document = nil)
      node = typed_node(node, document)
      return false unless node.is_a?(Hash)

      type = node.key?('type') ? node['type'] : node[:type]
      declared = Array(type) - ['null']
      declared.size == 1 && declared.first.is_a?(String) && PRIMITIVE_TYPES.include?(declared.first)
    end

    # How many references the type lookup will follow before giving up.
    MAX_REF_HOPS = 8

    # The schema object that states this property's type: the node itself, or
    # what its local `$ref` chain leads to. A reference this client cannot
    # resolve on its own -- an external URI, a pointer into nothing, a cycle,
    # or a name whose pointer escapes are percent-encoded -- resolves to
    # nothing, and the property is treated as one whose type is unstated: the
    # tool is excluded rather than mirrored on a guess.
    # @api private
    def typed_node(node, document)
      hops = 0
      seen = []
      while node.is_a?(Hash) && !node.key?('type') && !node.key?(:type)
        ref = node.key?('$ref') ? node['$ref'] : node[:$ref]
        return nil unless ref.is_a?(String) && !seen.include?(ref) && (hops += 1) <= MAX_REF_HOPS

        seen << ref
        node = resolve_local_pointer(document, ref)
      end
      node
    end

    # Resolve a same-document JSON pointer (RFC 6901) given as a URI fragment.
    # @api private
    def resolve_local_pointer(document, ref)
      return nil unless document.is_a?(Hash) && ref.start_with?('#')

      pointer = ref[1..]
      return document if pointer.empty?
      return nil unless pointer.start_with?('/')

      pointer.split('/', -1).drop(1).reduce(document) do |node, token|
        return nil if token.include?('%')

        pointer_step(node, token.gsub('~1', '/').gsub('~0', '~'))
      end
    end

    # @api private
    def pointer_step(node, token)
      case node
      when Hash then node.key?(token) ? node[token] : node[token.to_sym]
      when Array then token.match?(/\A(?:0|[1-9][0-9]*)\z/) ? node[token.to_i] : nil
      end
    end

    # @api private
    def annotated?(node)
      node.key?(ANNOTATION) || node.key?(ANNOTATION.to_sym)
    end

    # @api private
    def check_annotation(node, path, reachable, document, errors, seen, found)
      value = node.key?(ANNOTATION) ? node[ANNOTATION] : node[ANNOTATION.to_sym]
      # Property names are peer-controlled: inspect escapes control characters.
      where = path.empty? ? 'the schema root' : path.join('.').inspect

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

      unless primitive_type?(node, document)
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
