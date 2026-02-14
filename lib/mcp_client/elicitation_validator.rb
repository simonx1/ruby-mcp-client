# frozen_string_literal: true

module MCPClient
  # Validates elicitation schemas and content per MCP 2025-11-25 spec.
  # Schemas are restricted to flat objects with primitive property types:
  #   string (with optional enum, pattern, format, minLength, maxLength)
  #   number / integer (with optional minimum, maximum)
  #   boolean
  #   array (multi-select enum only, with items containing enum or anyOf)
  module ElicitationValidator
    # Allowed primitive types for schema properties
    PRIMITIVE_TYPES = %w[string number integer boolean].freeze

    # Allowed string formats per MCP spec
    STRING_FORMATS = %w[email uri date date-time].freeze

    # Validate that a requestedSchema conforms to MCP elicitation constraints.
    # Returns an array of error messages (empty if valid).
    # @param schema [Hash] the requestedSchema
    # @return [Array<String>] validation errors
    def self.validate_schema(schema)
      errors = []
      return errors unless schema.is_a?(Hash)

      unless schema['type'] == 'object'
        errors << "Schema type must be 'object', got '#{schema['type']}'"
        return errors
      end

      properties = schema['properties']
      return errors unless properties.is_a?(Hash)

      properties.each do |name, prop|
        errors.concat(validate_property(name, prop))
      end

      errors
    end

    # Validate a single property definition.
    # @param name [String] property name
    # @param prop [Hash] property schema
    # @return [Array<String>] validation errors
    def self.validate_property(name, prop)
      errors = []
      return errors unless prop.is_a?(Hash)

      type = prop['type']

      if type == 'array'
        errors.concat(validate_array_property(name, prop))
      elsif PRIMITIVE_TYPES.include?(type)
        errors.concat(validate_primitive_property(name, prop))
      else
        errors << "Property '#{name}' has unsupported type '#{type}'"
      end

      errors
    end

    # Validate a primitive property (string, number, integer, boolean).
    # @param name [String] property name
    # @param prop [Hash] property schema
    # @return [Array<String>] validation errors
    def self.validate_primitive_property(name, prop)
      errors = []
      type = prop['type']

      case type
      when 'string'
        if prop['format'] && !STRING_FORMATS.include?(prop['format'])
          errors << "Property '#{name}' has unsupported format '#{prop['format']}'"
        end
        if prop['enum'] && !prop['enum'].is_a?(Array)
          errors << "Property '#{name}' enum must be an array"
        end
      when 'number', 'integer'
        if prop.key?('minimum') && !prop['minimum'].is_a?(Numeric)
          errors << "Property '#{name}' minimum must be numeric"
        end
        if prop.key?('maximum') && !prop['maximum'].is_a?(Numeric)
          errors << "Property '#{name}' maximum must be numeric"
        end
      end

      errors
    end

    # Validate an array property (multi-select enum only).
    # @param name [String] property name
    # @param prop [Hash] property schema
    # @return [Array<String>] validation errors
    def self.validate_array_property(name, prop)
      errors = []
      items = prop['items']

      unless items.is_a?(Hash)
        errors << "Property '#{name}' array type requires 'items' definition"
        return errors
      end

      has_enum = items['enum'].is_a?(Array)
      has_any_of = items['anyOf'].is_a?(Array)

      unless has_enum || has_any_of
        errors << "Property '#{name}' array items must have 'enum' or 'anyOf'"
      end

      errors
    end

    # Validate content against a requestedSchema.
    # Returns an array of error messages (empty if valid).
    # @param content [Hash] the response content
    # @param schema [Hash] the requestedSchema
    # @return [Array<String>] validation errors
    def self.validate_content(content, schema)
      errors = []
      return errors unless content.is_a?(Hash) && schema.is_a?(Hash)

      properties = schema['properties'] || {}
      required = schema['required'] || []

      # Check required fields
      required.each do |field|
        field_s = field.to_s
        unless content.key?(field_s) || content.key?(field_s.to_sym)
          errors << "Missing required field '#{field_s}'"
        end
      end

      # Validate each provided field
      content.each do |field, value|
        prop = properties[field.to_s]
        next unless prop.is_a?(Hash)

        errors.concat(validate_value(field.to_s, value, prop))
      end

      errors
    end

    # Validate a single value against its property schema.
    # @param field [String] field name
    # @param value [Object] the value to validate
    # @param prop [Hash] property schema
    # @return [Array<String>] validation errors
    def self.validate_value(field, value, prop)
      errors = []
      type = prop['type']

      case type
      when 'string'
        errors.concat(validate_string_value(field, value, prop))
      when 'number', 'integer'
        errors.concat(validate_number_value(field, value, prop))
      when 'boolean'
        errors << "Field '#{field}' must be a boolean" unless [true, false].include?(value)
      when 'array'
        errors.concat(validate_array_value(field, value, prop))
      end

      errors
    end

    # Validate a string value against its property schema.
    # @param field [String] field name
    # @param value [Object] the value
    # @param prop [Hash] property schema
    # @return [Array<String>] validation errors
    def self.validate_string_value(field, value, prop)
      errors = []

      unless value.is_a?(String)
        errors << "Field '#{field}' must be a string"
        return errors
      end

      if prop['enum'].is_a?(Array) && !prop['enum'].include?(value)
        errors << "Field '#{field}' must be one of: #{prop['enum'].join(', ')}"
      end

      if prop['oneOf'].is_a?(Array)
        allowed = prop['oneOf'].map { |o| o['const'] }
        unless allowed.include?(value)
          errors << "Field '#{field}' must be one of: #{allowed.join(', ')}"
        end
      end

      if prop['pattern']
        begin
          unless value.match?(Regexp.new(prop['pattern']))
            errors << "Field '#{field}' must match pattern '#{prop['pattern']}'"
          end
        rescue RegexpError
          # Skip pattern validation if the pattern is invalid
        end
      end

      if prop['minLength'] && value.length < prop['minLength']
        errors << "Field '#{field}' must be at least #{prop['minLength']} characters"
      end

      if prop['maxLength'] && value.length > prop['maxLength']
        errors << "Field '#{field}' must be at most #{prop['maxLength']} characters"
      end

      errors
    end

    # Validate a number value against its property schema.
    # @param field [String] field name
    # @param value [Object] the value
    # @param prop [Hash] property schema
    # @return [Array<String>] validation errors
    def self.validate_number_value(field, value, prop)
      errors = []

      unless value.is_a?(Numeric)
        errors << "Field '#{field}' must be a number"
        return errors
      end

      if prop['type'] == 'integer' && !value.is_a?(Integer)
        errors << "Field '#{field}' must be an integer"
      end

      if prop['minimum'] && value < prop['minimum']
        errors << "Field '#{field}' must be >= #{prop['minimum']}"
      end

      if prop['maximum'] && value > prop['maximum']
        errors << "Field '#{field}' must be <= #{prop['maximum']}"
      end

      errors
    end

    # Validate an array value against its property schema (multi-select enum).
    # @param field [String] field name
    # @param value [Object] the value
    # @param prop [Hash] property schema
    # @return [Array<String>] validation errors
    def self.validate_array_value(field, value, prop)
      errors = []

      unless value.is_a?(Array)
        errors << "Field '#{field}' must be an array"
        return errors
      end

      items = prop['items'] || {}
      allowed = if items['enum'].is_a?(Array)
                  items['enum']
                elsif items['anyOf'].is_a?(Array)
                  items['anyOf'].map { |o| o['const'] }
                end

      if allowed
        value.each do |v|
          unless allowed.include?(v)
            errors << "Field '#{field}' contains invalid value '#{v}'"
          end
        end
      end

      if prop['minItems'] && value.length < prop['minItems']
        errors << "Field '#{field}' must have at least #{prop['minItems']} items"
      end

      if prop['maxItems'] && value.length > prop['maxItems']
        errors << "Field '#{field}' must have at most #{prop['maxItems']} items"
      end

      errors
    end
  end
end
