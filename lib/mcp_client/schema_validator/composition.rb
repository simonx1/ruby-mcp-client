# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # How complete a verdict on one value is. Extended into SchemaValidator,
    # so the methods are its own; {Evaluation} applies the composition
    # keywords themselves and reads the answers here.
    #
    # A composition branch is evaluated speculatively (its errors are a
    # verdict, not output). anyOf and allOf are monotonic, so a branch that
    # passes as far as the validator can evaluate it is accepted; not, oneOf
    # and if are not, so a branch that still holds an unevaluated assertion
    # applying to the instance is :undecided and never a match, while one
    # decided by its evaluated keywords (or carrying only annotations) is a
    # full verdict.
    #
    # Every standard assertion whose verdict this validator can reach is
    # evaluated ({SchemaValidator.validate_object},
    # {SchemaValidator.validate_array}, {SchemaValidator.validate_number}),
    # so what is left here is only what genuinely cannot be decided: the two
    # keywords read off the annotations a whole composition produces, the
    # dynamic references, and `format` where it asserts.
    module Composition
      # Whether a schema object carries an assertion the validator does not
      # evaluate (in the dialect in force) that applies to this instance, so
      # its verdict is only partial. Annotations (`format`, `contentSchema`)
      # and assertions of another instance type decide nothing and leave the
      # verdict whole.
      # @param deadline [Float, nil] monotonic deadline the checks run under
      #   (the coverage checks match server-controlled patterns)
      # @return [Boolean]
      def partial_keywords?(schema, dialect, data, deadline = nil)
        applicable = UNSUPPORTED_ASSERTIONS_ANY_TYPE +
                     UNSUPPORTED_ASSERTIONS_BY_TYPE.select { |type, _| data.is_a?(type) }.values.flatten
        # draft-07 `format` asserts (Validation Section 7.2); the validator
        # does not evaluate formats, so a string branch carrying one is
        # undecided there, while 2019-09 / 2020-12 only annotate.
        applicable += ['format'] if dialect == DRAFT_07 && data.is_a?(String)
        (schema.keys & applicable).any? do |keyword|
          keyword_known?(keyword, dialect) && effective_assertion?(schema, keyword, data, dialect, deadline)
        end
      end

      # Whether an unevaluated assertion can still change the result for
      # this instance. `unevaluatedItems` and `unevaluatedProperties` are
      # decided by the annotations a whole composition produces, so they
      # assert only where the schema's own applicators leave the instance
      # uncovered (a tuple, an `items` schema or an `additionalItems` beside
      # a tuple evaluates every item; a named, pattern-matched or
      # `additionalProperties`-covered member every property) and only where
      # their value can fail at all. The dynamic references and a draft-07
      # `format` always can.
      # @return [Boolean]
      def effective_assertion?(schema, keyword, data, dialect = nil, deadline = nil)
        value = schema[keyword]
        case keyword
        when 'unevaluatedItems' then effective_unevaluated_items?(schema, value, data, dialect)
        when 'unevaluatedProperties'
          data.is_a?(Hash) && ![true, {}].include?(value) && uncovered_property?(schema, data, deadline)
        else true
        end
      end

      # @return [Boolean] whether `unevaluatedItems` can still reject an item
      def effective_unevaluated_items?(schema, value, data, dialect)
        return false unless data.is_a?(Array)

        ![true, {}].include?(value) && data.length > evaluated_item_count(schema, dialect)
      end

      # @return [Boolean] whether a contains schema in force matches every item
      def contains_everything?(schema, dialect)
        keyword_known?('contains', dialect) && [true, {}].include?(schema['contains'])
      end

      # The number of matching items `contains` requires: its companion
      # where the dialect defines one and gives it a number, else the
      # default of 1 (JSON Schema 2020-12 Validation Section 6.4.4).
      # @return [Numeric]
      def contains_min(schema, dialect)
        min = schema['minContains'] if keyword_known?('minContains', dialect)
        min.is_a?(Numeric) ? min : 1
      end

      # @return [Numeric, nil] the number of matching items `contains`
      #   allows, when the dialect defines the companion and it is a number
      def contains_max(schema, dialect)
        max = schema['maxContains'] if keyword_known?('maxContains', dialect)
        max if max.is_a?(Numeric)
      end

      # How many leading items the tuple keywords in force evaluate, or
      # infinity when an items schema, an `additionalItems` beside the tuple
      # or a contains schema matching every item (JSON Schema 2020-12 Core
      # Section 10.3.1.3) evaluates them all.
      # @return [Integer, Float]
      def evaluated_item_count(schema, dialect)
        tuple = schema['prefixItems'] if keyword_known?('prefixItems', dialect) && schema['prefixItems'].is_a?(Array)
        tuple ||= schema['items'] if schema['items'].is_a?(Array)
        return Float::INFINITY if schema_value?(schema['items']) || contains_everything?(schema, dialect) ||
                                  (tuple && keyword_known?('additionalItems', dialect) &&
                                   schema_value?(schema['additionalItems']))

        tuple ? tuple.length : 0
      end

      # @param data [Hash] the instance
      # @param name [Object] the property name a schema keyword names
      # @return [Boolean] whether the instance carries the property in either
      #   key form
      def property_present?(data, name)
        name = name.to_s
        data.key?(name) || data.key?(name.to_sym)
      end

      # Whether the instance has a property the schema's own property
      # applicators leave to `unevaluatedProperties`: one named in
      # `properties` is covered, one an `additionalProperties` schema
      # evaluates is covered, and one matching a `patternProperties` pattern
      # is covered (an unreadable pattern is assumed to match nothing,
      # keeping the branch undecided).
      # @return [Boolean]
      def uncovered_property?(schema, data, deadline = nil)
        return false if schema.key?('additionalProperties') && schema_value?(schema['additionalProperties'])

        named = schema['properties'].is_a?(Hash) ? schema['properties'].keys.map(&:to_s) : []
        patterns = schema['patternProperties'].is_a?(Hash) ? schema['patternProperties'].keys.map(&:to_s) : []
        data.each_key.any? do |name|
          name = name.to_s
          next false if named.include?(name)

          patterns.none? { |pattern| pattern_matches?(pattern, name, deadline) }
        end
      end

      # Match a server-supplied pattern against a property name. Both come
      # from the peer, so — exactly like {.validate_pattern} — the match runs
      # under the validation-wide deadline: a backtracking expression here
      # must not be able to hold the calling thread.
      # @param deadline [Float, nil] monotonic deadline for the whole validation
      # @return [Boolean]
      # @raise [Aborted] when the budget is exhausted
      def pattern_matches?(pattern, name, deadline = nil)
        remaining = pattern_budget_remaining(deadline)
        raise Aborted, "validation time budget exhausted before pattern #{clip(pattern.inspect)}" if remaining.zero?

        ecma_regexp(pattern, remaining).match?(name)
      rescue Regexp::TimeoutError
        raise Aborted, "pattern #{clip(pattern.inspect)} exceeded the #{PATTERN_MATCH_TIMEOUT}s matching budget"
      rescue RegexpError, TypeError
        false
      end
    end
  end
end
