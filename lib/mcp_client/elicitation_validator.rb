# frozen_string_literal: true

require 'uri'
require 'date'
require 'time'

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

    # Wall-clock budget for ALL pattern matching in a single validate_content
    # call. The requestedSchema comes from the remote server, so an expensive
    # expression must not be able to monopolize the calling thread.
    #
    # The budget covers the whole operation, not each match: a per-match limit
    # multiplies, since the server also controls how many fields it declares.
    PATTERN_MATCH_TIMEOUT = 1.0

    # Floor for an individual match, so a nearly-exhausted budget still makes
    # progress rather than failing every remaining field.
    MIN_PATTERN_MATCH_TIMEOUT = 0.01

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
        errors << "Property '#{name}' enum must be an array" if prop['enum'] && !prop['enum'].is_a?(Array)
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

      errors << "Property '#{name}' array items must have 'enum' or 'anyOf'" unless has_enum || has_any_of

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

      # One deadline covers every field's pattern in this call.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PATTERN_MATCH_TIMEOUT

      properties = schema['properties'] || {}
      required = Array(schema['required'])

      # Check required fields
      required.each do |field|
        field_s = field.to_s
        errors << "Missing required field '#{field_s}'" unless content.key?(field_s) || content.key?(field_s.to_sym)
      end

      # Validate each provided field
      content.each do |field, value|
        prop = properties[field.to_s]
        next unless prop.is_a?(Hash)

        errors.concat(validate_value(field.to_s, value, prop, deadline))
      end

      errors
    end

    # Validate a single value against its property schema.
    # @param field [String] field name
    # @param value [Object] the value to validate
    # @param prop [Hash] property schema
    # @return [Array<String>] validation errors
    def self.validate_value(field, value, prop, deadline = nil)
      errors = []
      type = prop['type']

      case type
      when 'string'
        errors.concat(validate_string_value(field, value, prop, deadline))
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
    def self.validate_string_value(field, value, prop, deadline = nil)
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
        errors << "Field '#{field}' must be one of: #{allowed.join(', ')}" unless allowed.include?(value)
      end

      errors.concat(validate_string_pattern(field, value, prop['pattern'], deadline)) if prop['pattern']

      if prop['minLength'] && value.length < prop['minLength']
        errors << "Field '#{field}' must be at least #{prop['minLength']} characters"
      end

      if prop['maxLength'] && value.length > prop['maxLength']
        errors << "Field '#{field}' must be at most #{prop['maxLength']} characters"
      end

      errors.concat(validate_string_format(field, value, prop['format']))

      errors
    end

    # Validate a string value against the schema's regular-expression pattern.
    # An invalid pattern is not enforced (unchanged behavior), but matching
    # runs under PATTERN_MATCH_TIMEOUT because the pattern comes from the
    # remote server. A match that exceeds the budget is reported as a
    # validation error rather than silently accepted — the value was never
    # shown to satisfy the constraint.
    # @param field [String] field name
    # @param value [String] the value
    # @param pattern [String] the declared pattern
    # @return [Array<String>] validation errors
    def self.validate_string_pattern(field, value, pattern, deadline = nil)
      remaining = pattern_budget_remaining(deadline)
      return ["Field '#{field}' pattern matching budget exhausted"] if remaining.zero?

      return [] if value.match?(Regexp.new(pattern, timeout: remaining))

      ["Field '#{field}' must match pattern '#{pattern}'"]
    rescue Regexp::TimeoutError
      ["Field '#{field}' pattern '#{pattern}' exceeded the #{PATTERN_MATCH_TIMEOUT}s matching budget"]
    rescue RegexpError
      # Skip pattern validation if the pattern is invalid
      []
    end

    # Time left in the validation-wide pattern budget.
    # @param deadline [Float, nil] monotonic deadline, or nil for a lone match
    # @return [Float] seconds available for the next match; 0.0 when exhausted
    def self.pattern_budget_remaining(deadline)
      return PATTERN_MATCH_TIMEOUT unless deadline

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return 0.0 if remaining <= 0

      [remaining, MIN_PATTERN_MATCH_TIMEOUT].max
    end

    # Validate a string value against the schema's format constraint.
    # The MCP elicitation schema supports email, uri, date, and date-time.
    # @param field [String] field name
    # @param value [String] the value
    # @param format [String, nil] declared format
    # @return [Array<String>] validation errors
    def self.validate_string_format(field, value, format)
      valid = case format
              when 'email' then value.match?(URI::MailTo::EMAIL_REGEXP)
              when 'uri' then valid_uri?(value)
              when 'date' then parseable?(Date, value)
              when 'date-time' then parseable?(Time, value)
              else true # No format declared, or an unknown format: not validated
              end

      valid ? [] : ["Field '#{field}' must be a valid #{format}"]
    end

    # @param value [String] candidate URI
    # @return [Boolean] whether the value is an absolute URI
    def self.valid_uri?(value)
      uri = URI.parse(value)
      !uri.scheme.nil?
    rescue URI::InvalidURIError
      false
    end

    # @param klass [Class] Date or Time
    # @param value [String] candidate ISO 8601 value
    # @return [Boolean] whether the value parses
    def self.parseable?(klass, value)
      klass.iso8601(value)
      true
    rescue ArgumentError
      false
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

      errors << "Field '#{field}' must be an integer" if prop['type'] == 'integer' && !value.is_a?(Integer)

      errors << "Field '#{field}' must be >= #{prop['minimum']}" if prop['minimum'] && value < prop['minimum']

      errors << "Field '#{field}' must be <= #{prop['maximum']}" if prop['maximum'] && value > prop['maximum']

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
          errors << "Field '#{field}' contains invalid value '#{v}'" unless allowed.include?(v)
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
