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
    # {SchemaValidator.validate_array}, {SchemaValidator.validate_number},
    # and the unevaluated keywords from the annotations {Evaluation}
    # collects), so what is left here is only what genuinely cannot be
    # decided: a dynamic reference whose target the dynamic scope could
    # re-bind, and `format` where it asserts.
    module Composition
      # Whether a schema object carries an assertion the validator does not
      # evaluate (in the dialect in force) that applies to this instance, so
      # its verdict is only partial. Annotations (`format` in 2019-09 and
      # 2020-12, `contentSchema`) decide nothing and leave the verdict whole;
      # draft-07 `format` asserts (Validation Section 7.2), and the validator
      # does not evaluate formats, so a string branch carrying one is
      # undecided there.
      # @param schema [Hash] the schema object
      # @param dialect [String, nil] the dialect in force at it
      # @param data [Object] the instance
      # @param ctx [Context] the validation context
      # @return [Boolean]
      def partial_keywords?(schema, dialect, data, ctx)
        return true if dialect == DRAFT_07 && data.is_a?(String) && schema.key?('format')

        DYNAMIC_REFERENCE_KEYWORDS.any? do |keyword|
          schema.key?(keyword) && keyword_known?(keyword, dialect) &&
            dynamic_reference?(schema, keyword, ctx.root, ctx.dialect, ctx)
        end
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

      # @param data [Hash] the instance
      # @param name [Object] the property name a schema keyword names
      # @return [Boolean] whether the instance carries the property in either
      #   key form
      def property_present?(data, name)
        name = name.to_s
        data.key?(name) || data.key?(name.to_sym)
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

        ecma_regexp(pattern, remaining, deadline).match?(name)
      rescue Regexp::TimeoutError
        raise Aborted, "pattern #{clip(pattern.inspect)} exceeded the #{PATTERN_MATCH_TIMEOUT}s matching budget"
      rescue RegexpError, TypeError
        false
      end
    end
  end
end
