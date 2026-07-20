# frozen_string_literal: true

module MCPClient
  # Self-contained JSON Schema validator used to check a tool call result's
  # structuredContent against the tool's declared outputSchema (MCP 2025-11-25
  # server/tools spec: "Clients SHOULD validate structured results against this
  # schema"; the default schema dialect is JSON Schema 2020-12 per SEP-1613).
  #
  # Only the common JSON Schema keywords are supported:
  # - type (single value or array of values), enum, const
  # - properties, required (objects)
  # - items, minItems, maxItems (arrays)
  # - minLength, maxLength, pattern (strings)
  # - minimum, maximum, exclusiveMinimum, exclusiveMaximum (numbers)
  #
  # The full JSON Schema 2020-12 vocabulary ($ref/$defs, allOf/anyOf/oneOf/not,
  # conditional keywords, additionalProperties, format assertions, ...) is out
  # of scope: unrecognized keywords are ignored rather than misapplied, so
  # validation is best-effort — it may accept data a full validator would
  # reject, but it does not reject data that conforms to the schema.
  module SchemaValidator
    # Validate data against a JSON Schema subset.
    # Schema and data hashes may use string or symbol keys.
    # @param data [Object] the value to validate
    # @param schema [Hash] the JSON schema
    # @param path [String] JSON-pointer-style location used in error messages
    # @return [Array<String>] human-readable validation errors (empty if valid)
    def self.validate(data, schema, path: '#')
      return [] unless schema.is_a?(Hash)

      schema = schema.transform_keys(&:to_s)
      errors = []
      errors.concat(validate_type(data, schema['type'], path)) if schema.key?('type')
      errors.concat(validate_enum(data, schema, path))
      case data
      when Hash then errors.concat(validate_object(data, schema, path))
      when Array then errors.concat(validate_array(data, schema, path))
      when String then errors.concat(validate_string(data, schema, path))
      when Numeric then errors.concat(validate_number(data, schema, path))
      end
      errors
    end

    # Validate the JSON type of a value.
    # @param data [Object] the value
    # @param type [String, Symbol, Array<String, Symbol>] expected type(s)
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_type(data, type, path)
      types = (type.is_a?(Array) ? type : [type]).map(&:to_s)
      return [] if types.any? { |t| type_match?(t, data) }

      ["#{path}: expected type #{types.join(' or ')}, got #{json_type(data)}"]
    end

    # Whether a value matches a JSON Schema type name.
    # Unknown type names are not enforced (returns true).
    # @param type [String] the JSON Schema type name
    # @param data [Object] the value
    # @return [Boolean]
    def self.type_match?(type, data)
      case type
      when 'object' then data.is_a?(Hash)
      when 'array' then data.is_a?(Array)
      when 'string' then data.is_a?(String)
      when 'boolean' then data.equal?(true) || data.equal?(false)
      when 'null' then data.nil?
      when 'number' then data.is_a?(Numeric)
      when 'integer' then integer?(data)
      else true
      end
    end

    # Whether a value is a JSON Schema integer. Per JSON Schema 2020-12 a
    # number with a zero fractional part (e.g. 2.0) is a valid integer.
    # @param data [Object] the value
    # @return [Boolean]
    def self.integer?(data)
      return true if data.is_a?(Integer)
      return false unless data.is_a?(Numeric)

      (data % 1).zero?
    end

    # The JSON type name of a Ruby value (for error messages).
    # @param data [Object] the value
    # @return [String]
    def self.json_type(data)
      case data
      when nil then 'null'
      when true, false then 'boolean'
      when Integer then 'integer'
      when Numeric then 'number'
      when String then 'string'
      when Array then 'array'
      when Hash then 'object'
      else data.class.name
      end
    end

    # Validate enum/const membership.
    # @param data [Object] the value
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_enum(data, schema, path)
      errors = []
      if schema['enum'].is_a?(Array) && !schema['enum'].include?(data)
        errors << "#{path}: value #{data.inspect} is not in enum #{schema['enum'].inspect}"
      end
      if schema.key?('const') && schema['const'] != data
        errors << "#{path}: value #{data.inspect} does not equal const #{schema['const'].inspect}"
      end
      errors
    end

    # Validate an object against required/properties.
    # @param data [Hash] the object
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_object(data, schema, path)
      errors = []
      Array(schema['required']).each do |raw_name|
        name = raw_name.to_s
        errors << "#{path}: missing required property '#{name}'" unless data.key?(name) || data.key?(name.to_sym)
      end
      properties = schema['properties']
      return errors unless properties.is_a?(Hash)

      properties.each do |raw_name, prop_schema|
        next unless prop_schema.is_a?(Hash)

        name = raw_name.to_s
        key = if data.key?(name)
                name
              elsif data.key?(name.to_sym)
                name.to_sym
              end
        next if key.nil?

        errors.concat(validate(data[key], prop_schema, path: "#{path}/#{name}"))
      end
      errors
    end

    # Validate an array against items/minItems/maxItems.
    # @param data [Array] the array
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_array(data, schema, path)
      errors = []
      min_items = schema['minItems']
      max_items = schema['maxItems']
      if min_items.is_a?(Numeric) && data.length < min_items
        errors << "#{path}: expected at least #{min_items} items, got #{data.length}"
      end
      if max_items.is_a?(Numeric) && data.length > max_items
        errors << "#{path}: expected at most #{max_items} items, got #{data.length}"
      end
      items = schema['items']
      if items.is_a?(Hash)
        data.each_with_index { |item, idx| errors.concat(validate(item, items, path: "#{path}/#{idx}")) }
      end
      errors
    end

    # Validate a string against minLength/maxLength/pattern.
    # @param data [String] the string
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_string(data, schema, path)
      errors = []
      min_length = schema['minLength']
      max_length = schema['maxLength']
      if min_length.is_a?(Numeric) && data.length < min_length
        errors << "#{path}: string is shorter than minLength #{min_length}"
      end
      if max_length.is_a?(Numeric) && data.length > max_length
        errors << "#{path}: string is longer than maxLength #{max_length}"
      end
      errors.concat(validate_pattern(data, schema['pattern'], path))
      errors
    end

    # Validate a string against a regular-expression pattern.
    # Invalid patterns are not enforced.
    # @param data [String] the string
    # @param pattern [Object] the pattern keyword value
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_pattern(data, pattern, path)
      return [] unless pattern.is_a?(String)
      return [] if data.match?(Regexp.new(pattern))

      ["#{path}: string does not match pattern #{pattern.inspect}"]
    rescue RegexpError
      []
    end

    # Validate a number against inclusive/exclusive bounds.
    # @param data [Numeric] the number
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_number(data, schema, path)
      errors = []
      minimum = schema['minimum']
      maximum = schema['maximum']
      exclusive_min = schema['exclusiveMinimum']
      exclusive_max = schema['exclusiveMaximum']
      errors << "#{path}: value #{data} is less than minimum #{minimum}" if minimum.is_a?(Numeric) && data < minimum
      errors << "#{path}: value #{data} is greater than maximum #{maximum}" if maximum.is_a?(Numeric) && data > maximum
      if exclusive_min.is_a?(Numeric) && data <= exclusive_min
        errors << "#{path}: value #{data} must be greater than exclusiveMinimum #{exclusive_min}"
      end
      if exclusive_max.is_a?(Numeric) && data >= exclusive_max
        errors << "#{path}: value #{data} must be less than exclusiveMaximum #{exclusive_max}"
      end
      errors
    end
  end
end
