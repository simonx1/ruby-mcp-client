# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # allOf / anyOf / oneOf / not / if-then-else evaluation. Extended into
    # SchemaValidator, so the methods are its own.
    #
    # A branch is evaluated speculatively (its errors are a verdict, not
    # output). anyOf and allOf are monotonic, so a branch that passes as far
    # as the validator can evaluate it is accepted; not, oneOf and if are
    # not, so a branch that still holds an unevaluated assertion applying to
    # the instance is :undecided and never a match, while one decided by its
    # evaluated keywords (or carrying only annotations) is a full verdict.
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
      # this instance: a keyword that has no effect without its companion
      # (minContains / maxContains without contains, additionalItems beside
      # a non-tuple items — JSON Schema 2020-12 Validation Sections
      # 6.4.4-6.4.5, draft-07 Section 9.3.1.2), one the instance never
      # reaches (additionalItems or unevaluatedItems when the tuple or an
      # items schema covers every item, additionalProperties or
      # unevaluatedProperties when every property is covered, uniqueItems
      # below two items, maxContains or maxProperties the instance cannot
      # exceed, minProperties it already satisfies, a dependency none of
      # whose triggers is present), one its companion switches off
      # (contains with minContains 0) or whose value cannot fail
      # (additionalProperties true, uniqueItems false, minProperties 0, an
      # empty dependency map) decides nothing.
      # @return [Boolean]
      def effective_assertion?(schema, keyword, data, dialect = nil, deadline = nil)
        value = schema[keyword]
        case keyword
        when 'contains', 'minContains', 'maxContains', 'additionalItems', 'unevaluatedItems', 'uniqueItems'
          effective_array_assertion?(schema, keyword, value, data, dialect)
        when 'additionalProperties', 'unevaluatedProperties', 'propertyNames', 'minProperties', 'maxProperties',
             'dependentRequired', 'dependentSchemas', 'dependencies', 'patternProperties'
          effective_object_assertion?(schema, keyword, value, data, dialect, deadline)
        when 'multipleOf' then value.is_a?(Numeric) && data.is_a?(Numeric)
        else true
        end
      end

      # The array assertions whose effect depends on a companion keyword or
      # on the instance's length. A companion the dialect does not define
      # (`minContains` under draft-07) changes nothing.
      # @return [Boolean]
      def effective_array_assertion?(schema, keyword, value, data, dialect = nil)
        return false unless data.is_a?(Array)

        case keyword
        when 'contains' then effective_contains?(schema, data, dialect)
        when 'minContains', 'maxContains' then effective_contains_bound?(schema, keyword, value, data, dialect)
        when 'uniqueItems' then value == true && data.length > 1
        else
          # additionalItems (beside a tuple only) / unevaluatedItems: only
          # items past what the tuple (or an items schema, which evaluates
          # every item) covers.
          return false if keyword == 'additionalItems' && !schema['items'].is_a?(Array)

          ![true, {}].include?(value) && data.length > evaluated_item_count(schema, keyword, dialect)
        end
      end

      # @return [Boolean] whether a contains schema in force matches every item
      def contains_everything?(schema, dialect)
        keyword_known?('contains', dialect) && [true, {}].include?(schema['contains'])
      end

      # @return [Boolean] whether a contains schema in force matches no item
      def contains_nothing?(schema, dialect)
        keyword_known?('contains', dialect) && schema['contains'] == false
      end

      # Whether the number of matching items is known without evaluating the
      # item schema: the array's own length when `contains` matches every
      # item, zero when it matches none.
      # @return [Boolean]
      def contains_count_known?(schema, dialect)
        contains_everything?(schema, dialect) || contains_nothing?(schema, dialect)
      end

      # The range the number of matching items lies in, read off the array's
      # length alone (JSON Schema 2020-12 Validation Section 6.4.4: the
      # count is between none and all of the items).
      # @return [Array(Integer, Integer)] the lowest and highest count
      def contains_count_range(data, schema, dialect)
        return [data.length, data.length] if contains_everything?(schema, dialect)
        return [0, 0] if contains_nothing?(schema, dialect)

        [0, data.length]
      end

      # Whether `contains` can still change the result: not when its
      # companion switches it off (minContains 0), not when the count is
      # known from the array's length (a tautological schema matches every
      # item, `false` none), and not when the array is too short to reach
      # minContains whatever its items are, since
      # {SchemaValidator.validate_contains} then decides the keyword outright.
      # @return [Boolean]
      def effective_contains?(schema, data, dialect)
        return false if contains_count_known?(schema, dialect)

        min = contains_min(schema, dialect)
        min.positive? && data.length >= min
      end

      # A `contains` bound asserts only beside a `contains` this validator
      # leaves unevaluated, and only where the array's length does not
      # already settle it: a lower bound that requires a match the array is
      # long enough to hold, an upper bound the instance can exceed.
      # @return [Boolean]
      def effective_contains_bound?(schema, keyword, value, data, dialect)
        return false unless schema.key?('contains') && value.is_a?(Numeric) &&
                            !contains_count_known?(schema, dialect)

        keyword == 'minContains' ? value.positive? && data.length >= value : data.length > value
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

      # Apply the part of `contains` the array's length alone decides. The
      # number of matching items is never more than the array holds and
      # never less than none, so a bound outside that range is an assertion
      # this validator settles whatever the item schema says (JSON Schema
      # 2020-12 Validation Sections 6.4.4-6.4.5: the default minContains is
      # 1, so any contains rejects the empty array). A tautological schema
      # (`true` / `{}`) matches every item and `false` none, which pins the
      # count exactly; a contains that has to be matched item by item leaves
      # only the bounds its length cannot reach decided, and the rest
      # unevaluated.
      # @param data [Array] the instance
      # @param schema [Hash] string-keyed schema
      # @param path [String] location for error messages
      # @param dialect [String, nil] the dialect in force
      # @return [Array<String>] validation errors
      def validate_contains(data, schema, path, dialect)
        return [] unless keyword_known?('contains', dialect) && schema_value?(schema['contains'])

        low, high = contains_count_range(data, schema, dialect)
        min = contains_min(schema, dialect)
        max = contains_max(schema, dialect)
        errors = []
        errors << "#{path}: expected at least #{min} items matching contains, got #{contains_seen(low, high, high)}" \
          if high < min
        errors << "#{path}: expected at most #{max} items matching contains, got #{contains_seen(low, high, low)}" \
          if max && low > max
        errors
      end

      # How the count reads in an error: the number itself when the array's
      # length pins it, else the bound the error rests on.
      # @return [String]
      def contains_seen(low, high, bound)
        return bound.to_s if low == high

        "#{bound == high ? 'at most' : 'at least'} #{bound}"
      end

      # How many leading items the tuple keywords in force evaluate, or
      # infinity when an items schema (or a contains schema matching every
      # item — JSON Schema 2020-12 Core Section 10.3.1.3) evaluates them all.
      # @return [Integer, Float]
      def evaluated_item_count(schema, keyword, dialect)
        tuple = schema['prefixItems'] if keyword_known?('prefixItems', dialect) && schema['prefixItems'].is_a?(Array)
        tuple ||= schema['items'] if schema['items'].is_a?(Array)
        if keyword == 'unevaluatedItems' && (schema_value?(schema['items']) || contains_everything?(schema, dialect))
          return Float::INFINITY
        end

        tuple ? tuple.length : 0
      end

      # The object assertions whose effect depends on the instance's
      # properties.
      # @return [Boolean]
      def effective_object_assertion?(schema, keyword, value, data, dialect = nil, deadline = nil)
        return false unless data.is_a?(Hash)

        case keyword
        when 'additionalProperties', 'unevaluatedProperties'
          ![true, {}].include?(value) && uncovered_property?(schema, keyword, data, dialect, deadline)
        when 'propertyNames' then ![true, {}].include?(value) && !data.empty?
        when 'minProperties' then value.is_a?(Numeric) && data.size < value
        when 'maxProperties' then value.is_a?(Numeric) && data.size > value
        when 'patternProperties' then effective_pattern_properties?(value, data, deadline)
        else
          # An instance may carry either key form, so a trigger is present
          # when either form is (like `required` and `properties`).
          value.is_a?(Hash) &&
            value.any? { |trigger, dep| property_present?(data, trigger) && dependency_can_fail?(dep, data) }
        end
      end

      # @param data [Hash] the instance
      # @param name [Object] the property name a schema keyword names
      # @return [Boolean] whether the instance carries the property in either
      #   key form
      def property_present?(data, name)
        name = name.to_s
        data.key?(name) || data.key?(name.to_sym)
      end

      # `patternProperties` asserts only through a pattern some property
      # name matches whose schema is not a tautology.
      # @return [Boolean]
      def effective_pattern_properties?(value, data, deadline = nil)
        return false unless value.is_a?(Hash) && data.is_a?(Hash)

        value.any? do |pattern, sub|
          ![true, {}].include?(sub) &&
            data.each_key.any? { |name| pattern_matches?(pattern.to_s, name.to_s, deadline) }
        end
      end

      # A dependency whose value cannot fail (a required list every name of
      # which the instance already carries — an empty list included — or a
      # schema of true / {}) decides nothing for a present trigger.
      # @param data [Hash] the instance
      # @return [Boolean]
      def dependency_can_fail?(dep, data)
        return dep.any? { |name| !property_present?(data, name) } if dep.is_a?(Array)

        ![true, {}].include?(dep)
      end

      # Whether the instance has a property the schema's own property
      # applicators leave to the keyword: one named in `properties` is
      # covered, one an `additionalProperties` schema evaluates is covered
      # for `unevaluatedProperties`, and one matching a `patternProperties`
      # pattern is covered (an unreadable pattern is assumed to match
      # nothing, keeping the branch undecided).
      # @return [Boolean]
      def uncovered_property?(schema, keyword, data, dialect, deadline = nil)
        return false if keyword == 'unevaluatedProperties' && schema.key?('additionalProperties') &&
                        keyword_known?('additionalProperties', dialect)

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
      # decides only whether a branch is undecided, and must not be able to
      # hold the calling thread for it.
      # @param deadline [Float, nil] monotonic deadline for the whole validation
      # @return [Boolean]
      # @raise [Aborted] when the budget is exhausted
      def pattern_matches?(pattern, name, deadline = nil)
        remaining = pattern_budget_remaining(deadline)
        raise Aborted, "validation time budget exhausted before pattern #{clip(pattern.inspect)}" if remaining.zero?

        Regexp.new(pattern, timeout: remaining).match?(name)
      rescue Regexp::TimeoutError
        raise Aborted, "pattern #{clip(pattern.inspect)} exceeded the #{PATTERN_MATCH_TIMEOUT}s matching budget"
      rescue RegexpError, TypeError
        false
      end

      # The verdict of a branch evaluated speculatively: :fail when a
      # supported assertion rejected the value, :pass when every assertion
      # was evaluated and accepted it, :undecided when it was accepted only
      # as far as the validator could evaluate. Non-monotonic compositions
      # (not, oneOf, if) never treat :undecided as a match. A definite
      # verdict leaves no uncertainty behind: what a failing branch could not
      # evaluate does not matter once it failed.
      # @return [Symbol]
      def verdict(data, sub, path, ctx, ref_depth)
        before = ctx.undecided
        passed = speculative(ctx) { validate_node(data, sub, path, ctx, ref_depth).empty? }
        unless passed
          ctx.undecided = before
          return :fail
        end

        ctx.undecided == before ? :pass : :undecided
      end

      # The verdicts of the branches. Evaluation stops as soon as the
      # branches seen so far settle the composition (`stop`): a branch that
      # cannot change the outcome is not evaluated, so it cannot abort a
      # decided validation. Once the composition is decided — early, or
      # after every branch (`decided`) — the uncertainty count is restored
      # to what it was before the branches ran.
      # @return [Array<Symbol>]
      def branch_verdicts(data, subs, path, ctx, ref_depth, stop:, decided:)
        before = ctx.undecided
        verdicts = []
        subs.each do |sub|
          verdicts << verdict(data, sub, path, ctx, ref_depth)
          break if stop.call(verdicts)
        end
        ctx.undecided = before if stop.call(verdicts) || decided.call(verdicts)
        verdicts
      end

      # allOf / anyOf / oneOf / not / if-then-else.
      # @return [Array<String>] validation errors
      def validate_composition(data, schema, path, ctx, ref_depth)
        errors = []
        if schema['allOf'].is_a?(Array)
          # The first failing branch decides allOf; later branches are not
          # evaluated (they cannot change the outcome, but could abort it).
          schema['allOf'].each_with_index do |sub, idx|
            sub_errors = validate_node(data, sub, path, ctx, ref_depth)
            next if sub_errors.empty?

            errors << "#{path}: does not satisfy allOf/#{idx} (#{clip(sub_errors.first.to_s)})"
            break
          end
        end
        # anyOf is monotonic: a definite pass decides it whatever the other
        # branches, and only undecided branches leave it undecided.
        if schema['anyOf'].is_a?(Array)
          verdicts = branch_verdicts(data, schema['anyOf'], path, ctx, ref_depth,
                                     stop: ->(vs) { vs.include?(:pass) }, decided: ->(vs) { vs.all?(:fail) })
          errors << "#{path}: does not satisfy any schema in anyOf" if verdicts.all?(:fail)
        end
        if schema['oneOf'].is_a?(Array)
          # Two definite passes decide it; with an undecided branch and at
          # most one pass, "exactly one" cannot be told either way.
          verdicts = branch_verdicts(data, schema['oneOf'], path, ctx, ref_depth,
                                     stop: ->(vs) { vs.count(:pass) > 1 }, decided: ->(vs) { vs.none?(:undecided) })
          matches = verdicts.count(:pass)
          if matches > 1 || (verdicts.none?(:undecided) && matches != 1)
            errors << "#{path}: satisfies #{matches} schemas in oneOf, expected exactly one"
          end
        end
        if schema.key?('not') && verdict(data, schema['not'], path, ctx, ref_depth) == :pass
          errors << "#{path}: value satisfies the schema in not"
        end
        errors.concat(validate_conditional(data, schema, path, ctx, ref_depth))
        errors
      end

      # if / then / else.
      # @return [Array<String>] validation errors
      def validate_conditional(data, schema, path, ctx, ref_depth)
        # An `if` without `then` or `else` asserts nothing (JSON Schema 2020-12
        # Section 10.2.2.1) and is not evaluated.
        return [] unless schema.key?('if') && (schema.key?('then') || schema.key?('else'))

        case verdict(data, schema['if'], path, ctx, ref_depth)
        when :pass then branch = 'then'
        when :fail then branch = 'else'
        else return [] # undecided: neither branch is known to apply
        end
        return [] unless schema.key?(branch)

        validate_node(data, schema[branch], path, ctx, ref_depth)
      end
    end
  end
end
