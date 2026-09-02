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
      # @return [Boolean]
      def partial_keywords?(schema, dialect, data)
        applicable = UNSUPPORTED_ASSERTIONS_ANY_TYPE +
                     UNSUPPORTED_ASSERTIONS_BY_TYPE.select { |type, _| data.is_a?(type) }.values.flatten
        # draft-07 `format` asserts (Validation Section 7.2); the validator
        # does not evaluate formats, so a string branch carrying one is
        # undecided there, while 2019-09 / 2020-12 only annotate.
        applicable += ['format'] if dialect == DRAFT_07 && data.is_a?(String)
        (schema.keys & applicable).any? do |keyword|
          keyword_known?(keyword, dialect) && effective_assertion?(schema, keyword, data, dialect)
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
      def effective_assertion?(schema, keyword, data, dialect = nil)
        value = schema[keyword]
        case keyword
        when 'contains', 'minContains', 'maxContains', 'additionalItems', 'unevaluatedItems', 'uniqueItems'
          effective_array_assertion?(schema, keyword, value, data, dialect)
        when 'additionalProperties', 'unevaluatedProperties', 'propertyNames', 'minProperties', 'maxProperties',
             'dependentRequired', 'dependentSchemas', 'dependencies', 'patternProperties'
          effective_object_assertion?(schema, keyword, value, data, dialect)
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
        when 'contains' then !(keyword_known?('minContains', dialect) && schema['minContains'].eql?(0))
        when 'minContains' then schema.key?('contains') && value.is_a?(Numeric) && value.positive?
        when 'maxContains' then schema.key?('contains') && value.is_a?(Numeric) && data.length > value
        when 'uniqueItems' then value == true && data.length > 1
        else
          # additionalItems (beside a tuple only) / unevaluatedItems: only
          # items past what the tuple (or an items schema, which evaluates
          # every item) covers.
          return false if keyword == 'additionalItems' && !schema['items'].is_a?(Array)

          ![true, {}].include?(value) && data.length > evaluated_item_count(schema, keyword, dialect)
        end
      end

      # How many leading items the tuple keywords in force evaluate, or
      # infinity when an items schema evaluates them all.
      # @return [Integer, Float]
      def evaluated_item_count(schema, keyword, dialect)
        tuple = schema['prefixItems'] if keyword_known?('prefixItems', dialect) && schema['prefixItems'].is_a?(Array)
        tuple ||= schema['items'] if schema['items'].is_a?(Array)
        return Float::INFINITY if keyword == 'unevaluatedItems' && schema_value?(schema['items'])

        tuple ? tuple.length : 0
      end

      # The object assertions whose effect depends on the instance's
      # properties.
      # @return [Boolean]
      def effective_object_assertion?(schema, keyword, value, data, dialect = nil)
        return false unless data.is_a?(Hash)

        case keyword
        when 'additionalProperties', 'unevaluatedProperties'
          ![true, {}].include?(value) && uncovered_property?(schema, keyword, data, dialect)
        when 'propertyNames' then ![true, {}].include?(value) && !data.empty?
        when 'minProperties' then value.is_a?(Numeric) && data.size < value
        when 'maxProperties' then value.is_a?(Numeric) && data.size > value
        when 'patternProperties' then value.is_a?(Hash) && !value.empty? && !data.empty?
        else
          value.is_a?(Hash) && value.keys.any? { |trigger| data.key?(trigger.to_s) }
        end
      end

      # Whether the instance has a property the schema's own property
      # applicators leave to the keyword: one named in `properties` is
      # covered, one an `additionalProperties` schema evaluates is covered
      # for `unevaluatedProperties`, and one matching a `patternProperties`
      # pattern is covered (an unreadable pattern is assumed to match
      # nothing, keeping the branch undecided).
      # @return [Boolean]
      def uncovered_property?(schema, keyword, data, dialect)
        return false if keyword == 'unevaluatedProperties' && schema.key?('additionalProperties') &&
                        keyword_known?('additionalProperties', dialect)

        named = schema['properties'].is_a?(Hash) ? schema['properties'].keys.map(&:to_s) : []
        patterns = schema['patternProperties'].is_a?(Hash) ? schema['patternProperties'].keys.map(&:to_s) : []
        data.each_key.any? do |name|
          name = name.to_s
          next false if named.include?(name)

          patterns.none? { |pattern| pattern_matches?(pattern, name) }
        end
      end

      # @return [Boolean]
      def pattern_matches?(pattern, name)
        Regexp.new(pattern).match?(name)
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
