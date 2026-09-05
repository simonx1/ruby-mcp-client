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
        'minimum' => :number, 'maximum' => :number,
        'multipleOf' => :positive_number, 'uniqueItems' => :boolean,
        'minContains' => :non_negative_integer, 'maxContains' => :non_negative_integer,
        'minProperties' => :non_negative_integer, 'maxProperties' => :non_negative_integer,
        'dependentRequired' => :dependent_required
      }.freeze

      # The JSON Schema type names (2020-12 Validation Section 6.1.1).
      JSON_TYPE_NAMES = %w[array boolean integer null number object string].freeze

      # Check the assertion keyword values a schema object carries. A keyword
      # the dialect does not define (`minContains` under draft-07) is an
      # unknown one there: ignored, never malformed.
      # @return [void]
      def check_assertion_shapes(schema, dialect, problems)
        schema.each do |keyword, value|
          next unless keyword_known?(keyword, dialect)

          problem = assertion_shape_problem(keyword, value)
          problems << problem if problem
        end
      end

      # @return [String, nil] why an assertion value is malformed
      def assertion_shape_problem(keyword, value)
        shape = ASSERTION_SHAPES[keyword]
        return nil unless shape
        return type_shape_problem(value) if shape == :type_names
        return dependent_required_shape_problem(keyword, value) if shape == :dependent_required

        requirement = shape_requirement(shape, value)
        "#{keyword} must be #{requirement}" if requirement
      end

      # Each simple assertion shape: the predicate that admits a value, and
      # how the requirement reads in a problem.
      VALUE_SHAPES = {
        array: [:array_value?, 'an array'],
        property_names: [:property_names?, 'an array of distinct property names'],
        string: [:string_value?, 'a string'],
        non_negative_integer: [:non_negative_integer?, 'a non-negative integer'],
        number: [:number_value?, 'a number'],
        positive_number: [:positive_number?, 'a number greater than zero'],
        boolean: [:boolean_value?, 'a boolean']
      }.freeze

      # @return [String, nil] what a malformed value should have been
      def shape_requirement(shape, value)
        predicate, requirement = VALUE_SHAPES[shape]
        requirement unless predicate.nil? || send(predicate, value)
      end

      # @return [Boolean]
      def array_value?(value)
        value.is_a?(Array)
      end

      # @return [Boolean]
      def string_value?(value)
        value.is_a?(String)
      end

      # @return [Boolean]
      def number_value?(value)
        value.is_a?(Numeric)
      end

      # @return [Boolean]
      def positive_number?(value)
        value.is_a?(Numeric) && value.positive?
      end

      # @return [Boolean]
      def non_negative_integer?(value)
        integer?(value) && !value.negative?
      end

      # @return [Boolean]
      def boolean_value?(value)
        [true, false].include?(value)
      end

      # `dependentRequired` maps a property name to the names it requires
      # (JSON Schema 2020-12 Validation Section 6.5.4).
      # @return [String, nil]
      def dependent_required_shape_problem(keyword, value)
        return if value.is_a?(Hash) && value.each_value.all? { |v| property_names?(v) }

        "#{keyword} must be an object of arrays of distinct property names"
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

      # JSON Schema 2020-12 Validation Sections 6.5.3 and 6.5.4: the elements
      # of `required` (and of a `dependentRequired` entry) are strings, and
      # they MUST be unique — a name written twice is a malformed keyword,
      # not the same assertion made again.
      # @param value [Object]
      # @return [Boolean] whether value is an array of distinct property names
      def property_names?(value)
        value.is_a?(Array) && value.all?(String) && value.uniq.size == value.size
      end

      # An identifier must have the shape its dialect defines: `$id` is a URI
      # reference without a non-empty fragment (JSON Schema 2020-12 Core
      # Section 8.2.1) — draft-07 additionally spells a plain-name identifier
      # as a bare fragment (Core Section 8.2.3) — and `$anchor` /
      # `$dynamicAnchor` hold a plain name (Core Section 8.2.2). An
      # identifier the validator cannot read names nothing, so a reference
      # written to it would silently resolve elsewhere.
      # @return [void]
      def check_identifier_shapes(schema, dialect, problems)
        id_problem = id_shape_problem(schema['$id'], dialect) if schema.key?('$id')
        problems << id_problem if id_problem
        %w[$anchor $dynamicAnchor].each do |keyword|
          next unless schema.key?(keyword) && keyword_known?(keyword, dialect)

          problems << "#{keyword} must be a plain name" unless anchor_name?(schema[keyword], dialect)
        end
      end

      # @return [String, nil] why an `$id` is malformed
      def id_shape_problem(id, dialect)
        return '$id must be a non-empty string' unless id.is_a?(String) && !id.empty?
        # draft-07 Core Section 8.2.3: an $id that is exactly a fragment
        # declares a plain name rather than a base URI.
        return nil if dialect == DRAFT_07 && id.start_with?('#')

        fragment = id.split('#', 2)[1]
        return nil if fragment.nil? || fragment.empty?

        "$id #{clip(id.inspect)} must not contain a non-empty fragment"
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
