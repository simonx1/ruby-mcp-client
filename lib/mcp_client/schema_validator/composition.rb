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
        (schema.keys & applicable).any? { |keyword| keyword_known?(keyword, dialect) }
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

      # The verdicts of every branch. Uncertainty is kept only when it can
      # change the outcome: once the composition is decided the count is
      # restored to what it was before the branches ran.
      # @return [Array<Symbol>]
      def branch_verdicts(data, subs, path, ctx, ref_depth, decided:)
        before = ctx.undecided
        verdicts = subs.map { |sub| verdict(data, sub, path, ctx, ref_depth) }
        ctx.undecided = before if decided.call(verdicts)
        verdicts
      end

      # allOf / anyOf / oneOf / not / if-then-else.
      # @return [Array<String>] validation errors
      def validate_composition(data, schema, path, ctx, ref_depth)
        errors = []
        if schema['allOf'].is_a?(Array)
          schema['allOf'].each_with_index do |sub, idx|
            sub_errors = validate_node(data, sub, path, ctx, ref_depth)
            errors << "#{path}: does not satisfy allOf/#{idx} (#{clip(sub_errors.first.to_s)})" unless sub_errors.empty?
          end
        end
        # anyOf is monotonic: a definite pass decides it whatever the other
        # branches, and only undecided branches leave it undecided.
        if schema['anyOf'].is_a?(Array)
          verdicts = branch_verdicts(data, schema['anyOf'], path, ctx, ref_depth,
                                     decided: ->(vs) { vs.include?(:pass) || vs.all?(:fail) })
          errors << "#{path}: does not satisfy any schema in anyOf" if verdicts.all?(:fail)
        end
        if schema['oneOf'].is_a?(Array)
          # Two definite passes decide it; with an undecided branch and at
          # most one pass, "exactly one" cannot be told either way.
          verdicts = branch_verdicts(data, schema['oneOf'], path, ctx, ref_depth,
                                     decided: ->(vs) { vs.count(:pass) > 1 || vs.none?(:undecided) })
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
