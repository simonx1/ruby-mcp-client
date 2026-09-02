# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # allOf / anyOf / oneOf / not / if-then-else evaluation. Extended into
    # SchemaValidator, so the methods are its own.
    #
    # A branch is evaluated speculatively (its errors are a verdict, not
    # output). anyOf and allOf are monotonic, so a branch that passes as far
    # as the validator can evaluate it is accepted; not, oneOf and if are
    # not, so such a branch is :undecided and never a match.
    module Composition
      # Whether a schema object carries an assertion the validator does not
      # evaluate (in the dialect in force), so its verdict is only partial.
      # @return [Boolean]
      def partial_keywords?(schema, dialect)
        (schema.keys & UNSUPPORTED_KEYWORDS).any? { |keyword| keyword_known?(keyword, dialect) }
      end

      # The verdict of a branch evaluated speculatively: :fail when a
      # supported assertion rejected the value, :pass when every assertion
      # was evaluated and accepted it, :undecided when it was accepted only
      # as far as the validator could evaluate. Non-monotonic compositions
      # (not, oneOf, if) never treat :undecided as a match.
      # @return [Symbol]
      def verdict(data, sub, path, ctx, ref_depth)
        before = ctx.undecided
        passed = speculative(ctx) { validate_node(data, sub, path, ctx, ref_depth).empty? }
        return :fail unless passed

        ctx.undecided == before ? :pass : :undecided
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
        # anyOf is monotonic: a partial pass is the permissive direction.
        if schema['anyOf'].is_a?(Array) &&
           schema['anyOf'].all? { |sub| verdict(data, sub, path, ctx, ref_depth) == :fail }
          errors << "#{path}: does not satisfy any schema in anyOf"
        end
        if schema['oneOf'].is_a?(Array)
          verdicts = schema['oneOf'].map { |sub| verdict(data, sub, path, ctx, ref_depth) }
          matches = verdicts.count(:pass)
          # With an undecided branch "exactly one" cannot be told either way.
          if verdicts.none?(:undecided) && matches != 1
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
