# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # The shape every keyword value must have before a schema can be used:
    # an applicator must hold schemas, and an assertion this validator reads
    # must hold what its keyword is defined to hold. A value of the wrong
    # shape is neither ignored (that would turn an assertion into a pass)
    # nor read as written (that would fail every instance): the schema is
    # unusable, and the preflight says which keyword is at fault. Extended
    # into SchemaValidator, so the methods are its own.
    module Shapes
      # Every applicator value must be a schema (object or boolean), an array
      # of schemas or a map of schemas; anything else is not silently read as
      # "true". Keywords the dialect does not define are ignored.
      # @return [void]
      def check_applicator_shapes(schema, dialect, problems)
        schema.each do |keyword, value|
          next unless keyword_known?(keyword, dialect)

          problem = applicator_shape_problem(keyword, value)
          problems << problem if problem
        end
      end

      # @return [String, nil] why an applicator value is malformed
      def applicator_shape_problem(keyword, value)
        if SUBSCHEMA_KEYWORDS.include?(keyword)
          tuple = keyword == 'items' && all_schemas?(value)
          "#{keyword} must be a schema" unless schema_value?(value) || tuple
        elsif keyword == 'dependencies'
          dependencies_shape_problem(value)
        elsif SUBSCHEMA_MAP_KEYWORDS.include?(keyword)
          # A definition bag holds reusable schemas, whatever a reference ends
          # up pointing at (JSON Schema 2020-12 Core Section 8.2.4).
          "#{keyword} must be an object of schemas" unless value.is_a?(Hash) && all_schemas?(value.values)
        elsif SUBSCHEMA_ARRAY_KEYWORDS.include?(keyword)
          # allOf / anyOf / oneOf / prefixItems: "MUST be a non-empty array".
          "#{keyword} must be a non-empty array of schemas" unless all_schemas?(value) && !value.empty?
        end
      end

      # Assertion keywords whose value shape this validator reads, with what
      # each must be. A malformed value is not silently ignored (that would
      # turn an assertion into a pass) nor read as data (that would fail every
      # instance): the schema is unusable, and the caller is told why.
      ASSERTION_SHAPES = {
        'type' => :type_names, 'enum' => :array, 'required' => :property_names, 'pattern' => :string,
        'minLength' => :non_negative_integer, 'maxLength' => :non_negative_integer,
        'minItems' => :non_negative_integer, 'maxItems' => :non_negative_integer,
        'minimum' => :number, 'maximum' => :number
      }.freeze

      # The JSON Schema type names (2020-12 Validation Section 6.1.1).
      JSON_TYPE_NAMES = %w[array boolean integer null number object string].freeze

      # Check the assertion keyword values a schema object carries. Every one
      # of these keywords exists in all supported dialects, so no dialect test
      # is needed.
      # @return [void]
      def check_assertion_shapes(schema, problems)
        schema.each do |keyword, value|
          problem = assertion_shape_problem(keyword, value)
          problems << problem if problem
        end
      end

      # @return [String, nil] why an assertion value is malformed
      def assertion_shape_problem(keyword, value)
        case ASSERTION_SHAPES[keyword]
        when :type_names then type_shape_problem(value)
        when :array then "#{keyword} must be an array" unless value.is_a?(Array)
        when :property_names then "#{keyword} must be an array of property names" unless property_names?(value)
        when :string then "#{keyword} must be a string" unless value.is_a?(String)
        when :non_negative_integer
          "#{keyword} must be a non-negative integer" unless integer?(value) && !value.negative?
        when :number then "#{keyword} must be a number" unless value.is_a?(Numeric)
        end
      end

      # @return [String, nil] why a `type` value is malformed
      def type_shape_problem(value)
        names = value.is_a?(Array) ? value : [value]
        known = !names.empty? && names.all? do |name|
          (name.is_a?(String) || name.is_a?(Symbol)) && JSON_TYPE_NAMES.include?(name.to_s)
        end
        return nil if known && (!value.is_a?(Array) || names.uniq.size == names.size)

        "type must be one of #{JSON_TYPE_NAMES.join(', ')}, or a non-empty array of distinct such names"
      end

      # draft-07: each dependencies entry is a schema or an array of property
      # names.
      # @return [String, nil]
      def dependencies_shape_problem(value)
        return if value.is_a?(Hash) && value.each_value.all? { |v| schema_value?(v) || property_names?(v) }

        'dependencies entries must be schemas or arrays of property names'
      end

      # @param value [Object]
      # @return [Boolean] whether value is an array of property names
      def property_names?(value)
        value.is_a?(Array) && value.all?(String)
      end

      # exclusiveMinimum / exclusiveMaximum are numbers in every supported
      # dialect (draft-07 validation Sections 6.2.3 and 6.2.5, kept by 2019-09
      # and 2020-12); the boolean modifier form belongs to draft-04, which is
      # not supported, and is not silently ignored (it would turn a bound
      # into a pass).
      # @return [void]
      def check_exclusive_bounds(schema, _dialect, problems)
        %w[exclusiveMinimum exclusiveMaximum].each do |keyword|
          next if !schema.key?(keyword) || schema[keyword].is_a?(Numeric)

          problems << "#{keyword} must be a number (the draft-04 boolean form is not supported)"
        end
      end

      # @param values [Object]
      # @return [Boolean] whether values is an array of schemas
      def all_schemas?(values)
        values.is_a?(Array) && values.all? { |v| schema_value?(v) }
      end
    end
  end
end
