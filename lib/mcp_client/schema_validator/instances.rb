# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # The keywords that apply to one instance value's own type: the object
    # and array vocabularies, and the bookkeeping they need. Extended into
    # SchemaValidator, so the methods are its own; {Evaluation} calls them
    # once per schema position and {Composition} reads what they left
    # undecided.
    #
    # Everything here is decided by the instance and this schema object
    # alone, which is why it can be evaluated at all. What the keywords
    # evaluate of the value is recorded on the application's {Evaluated} as
    # they go, and `unevaluatedItems` / `unevaluatedProperties` read that
    # record once every applicator has run ({Evaluation#apply_unevaluated}).
    module Instances
      # Validate an object against the keywords that apply to it: `required`,
      # the property-count bounds, the required half of a dependency, the
      # `properties` schemas, and the schemas that decide the members those do
      # not name (`patternProperties`, `additionalProperties`, `propertyNames`).
      # @param data [Hash] the object
      # @param schema [Hash] string-keyed schema
      # @param path [String] location for error messages
      # @param evaluated [Evaluated, nil] where the members the keywords
      #   evaluate are recorded
      # @return [Array<String>] validation errors
      def validate_object(data, schema, path, ctx, dialect = ctx.dialect, evaluated = nil)
        errors = []
        Array(schema['required']).each do |raw_name|
          name = raw_name.to_s
          errors << "#{path}: missing required property '#{clip(name)}'" unless property_present?(data, name)
        end
        errors.concat(validate_property_counts(data, schema, path))
        errors.concat(validate_dependent_required(data, schema, path, dialect))
        errors.concat(validate_named_properties(data, schema, path, ctx, evaluated))
        errors.concat(validate_other_properties(data, schema, path, ctx, dialect, evaluated))
      end

      # `unevaluatedProperties` (JSON Schema 2020-12 Core Section 11.3): the
      # keyword's schema applies to every member nothing applied to the
      # value evaluated — not this node's own property keywords, not any
      # applicator that passed. The members are as many as the peer sent, so
      # the sweep consults the deadline as it goes.
      # @param app [Evaluation::Application] the finished application
      # @param sub [Object] the keyword's schema
      # @return [Array<String>] validation errors
      def unevaluated_property_errors(app, sub)
        data = app.data
        ctx = app.ctx
        path = app.path
        data.flat_map do |key, value|
          check_deadline(ctx)
          next [] if app.evaluated.property?(key)

          name = key.to_s
          unevaluated_errors(value, sub, "#{path}/#{name}", ctx,
                             "#{path}: property '#{clip(name)}' is not allowed (unevaluatedProperties is false)")
        end
      end

      # What one member or item left unevaluated costs: the keyword's schema
      # applied to it, or — where that schema is `false` — one error.
      # @return [Array<String>] validation errors
      def unevaluated_errors(value, sub, path, ctx, refusal)
        if sub == false
          count_visit(ctx)
          return [refusal]
        end

        validate_child(value, sub, path, ctx)
      end

      # minProperties / maxProperties (JSON Schema 2020-12 Validation Sections
      # 6.5.1-6.5.2).
      # @return [Array<String>] validation errors
      def validate_property_counts(data, schema, path)
        errors = []
        min = schema['minProperties']
        max = schema['maxProperties']
        if min.is_a?(Numeric) && data.size < min
          errors << "#{path}: object has #{data.size} properties, fewer than minProperties #{min}"
        end
        if max.is_a?(Numeric) && data.size > max
          errors << "#{path}: object has #{data.size} properties, more than maxProperties #{max}"
        end
        errors
      end

      # The required half of a dependency: `dependentRequired` in 2019-09 and
      # 2020-12, and the property-name arrays of draft-07's `dependencies`
      # (JSON Schema 2020-12 Validation Section 6.5.4, draft-07 Section 6.5.7).
      # @return [Array<String>] validation errors
      def validate_dependent_required(data, schema, path, dialect)
        errors = []
        %w[dependentRequired dependencies].each do |keyword|
          map = schema[keyword] if keyword_known?(keyword, dialect)
          next unless map.is_a?(Hash)

          map.each do |trigger, dependents|
            next unless dependents.is_a?(Array) && property_present?(data, trigger)

            dependents.each do |name|
              next if property_present?(data, name)

              errors << "#{path}: property '#{clip(trigger.to_s)}' requires property '#{clip(name.to_s)}'"
            end
          end
        end
        errors
      end

      # The `properties` schemas, applied in the order the schema names them.
      # Each member the keyword names is evaluated by it (its annotation).
      # @return [Array<String>] validation errors
      def validate_named_properties(data, schema, path, ctx, evaluated = nil)
        properties = schema['properties']
        return [] unless properties.is_a?(Hash)

        errors = []
        properties.each do |raw_name, prop_schema|
          next unless schema_value?(prop_schema)

          name = raw_name.to_s
          key = data.key?(name) ? name : (name.to_sym if data.key?(name.to_sym))
          next if key.nil?

          evaluated&.name!(name)
          # A property is a smaller instance, so the hops taken to reach this
          # schema cannot repeat forever below it: the budget counts a chain
          # of references applied to one value, not how deep the data nests.
          # The step down is what the depth bound counts.
          errors.concat(validate_child(data[key], prop_schema, "#{path}/#{name}", ctx))
        end
        errors
      end

      # The property applicators that decide members `properties` does not
      # name: every name is checked against `propertyNames`, a member whose
      # name matches a `patternProperties` pattern is validated against each
      # matching schema, and one left over by both goes to
      # `additionalProperties` (JSON Schema 2020-12 Core Sections 10.3.2.1-3).
      # @return [Array<String>] validation errors
      def validate_other_properties(data, schema, path, ctx, dialect, evaluated = nil)
        patterns = schema['patternProperties'] if keyword_known?('patternProperties', dialect)
        patterns = nil unless patterns.is_a?(Hash)
        names = schema_value?(schema['propertyNames']) ? schema['propertyNames'] : nil
        additional = schema['additionalProperties'] if schema_value?(schema['additionalProperties'])
        return [] if patterns.nil? && names.nil? && additional.nil?

        named = schema['properties'].is_a?(Hash) ? schema['properties'].keys.map(&:to_s) : []
        data.flat_map do |key, value|
          # How wide this sweep is the peer's choice, not the schema's, and a
          # member the applicators decide without descending into it visits no
          # node of its own: the deadline is consulted here so a huge object
          # cannot run the walk past the budget between two nodes it visits.
          check_deadline(ctx)
          property_errors(key.to_s, value, path, ctx, evaluated,
                          names: names, patterns: patterns, additional: additional, named: named)
        end
      end

      # One member's errors under the property applicators. A member a
      # pattern matched or `additionalProperties` applied to is evaluated by
      # that keyword (its annotation); `propertyNames` evaluates the name,
      # never the member.
      # @return [Array<String>] validation errors
      def property_errors(name, value, path, ctx, evaluated, names:, patterns:, additional:, named:)
        errors = names.nil? ? [] : property_name_errors(name, names, path, ctx)
        matched = false
        patterns&.each do |pattern, sub|
          next unless schema_value?(sub) && pattern_matches?(pattern.to_s, name, ctx.deadline)

          matched = true
          evaluated&.name!(name)
          errors.concat(validate_child(value, sub, "#{path}/#{name}", ctx))
        end
        return errors if matched || named.include?(name) || additional.nil?

        # A rejected member costs an error rather than a descent, so it is
        # charged here: the count is what stops a peer-sized object.
        if additional == false
          count_visit(ctx)
          return errors.push("#{path}: property '#{clip(name)}' is not allowed (additionalProperties is false)")
        end

        evaluated&.name!(name)
        errors.concat(validate_child(value, additional, "#{path}/#{name}", ctx))
      end

      # `propertyNames` applies its schema to each property *name* (a string),
      # so what it rejects is reported as one error about the name rather than
      # as a type error about a value the instance does not hold there.
      # @return [Array<String>] validation errors
      def property_name_errors(name, sub, path, ctx)
        errors = speculatively(ctx) { validate_child(name, sub, "#{path}/#{name}", ctx) }
        return [] if errors.empty?

        ["#{path}: property name '#{clip(name)}' does not satisfy propertyNames (#{clip(errors.first.to_s)})"]
      end

      # Run a block whose errors are a verdict rather than output, so they are
      # not charged to MAX_ERRORS (only what the caller reports is).
      # @return [Object] the block's value
      def speculatively(ctx)
        ctx.speculative += 1
        yield
      ensure
        ctx.speculative -= 1
      end

      # Validate an array against items/prefixItems/minItems/maxItems.
      # 2020-12 puts positional schemas in `prefixItems` and the rest under
      # `items`; draft-07 and 2019-09 put positional schemas in an `items`
      # array and send what follows the tuple to `additionalItems`. Both forms
      # are honoured.
      # @param data [Array] the array
      # @param schema [Hash] string-keyed schema
      # @param path [String] location for error messages
      # @param evaluated [Evaluated, nil] where the items the keywords
      #   evaluate are recorded
      # @return [Array<String>] validation errors
      def validate_array(data, schema, path, ctx, dialect = ctx.dialect, evaluated = nil)
        errors = []
        min_items = schema['minItems']
        max_items = schema['maxItems']
        if min_items.is_a?(Numeric) && data.length < min_items
          errors << "#{path}: expected at least #{min_items} items, got #{data.length}"
        end
        if max_items.is_a?(Numeric) && data.length > max_items
          errors << "#{path}: expected at most #{max_items} items, got #{data.length}"
        end
        errors.concat(validate_unique_items(data, schema, path, ctx))
        errors.concat(validate_items(data, schema, path, ctx, dialect, evaluated))
        errors.concat(validate_contains(data, schema, path, ctx, dialect, evaluated))
      end

      # `unevaluatedItems` (JSON Schema 2020-12 Core Section 11.2): the
      # keyword's schema applies to every item nothing applied to the value
      # evaluated — not the tuple keywords, not `contains`, not any
      # applicator that passed.
      # @param app [Evaluation::Application] the finished application
      # @param sub [Object] the keyword's schema
      # @return [Array<String>] validation errors
      def unevaluated_item_errors(app, sub)
        data = app.data
        ctx = app.ctx
        path = app.path
        errors = []
        data.each_index do |idx|
          check_deadline(ctx)
          next if app.evaluated.item?(idx)

          errors.concat(unevaluated_errors(data[idx], sub, "#{path}/#{idx}", ctx,
                                           "#{path}: item #{idx} is not allowed (unevaluatedItems is false)"))
        end
        errors
      end

      # The item schemas: the positional ones first, then the schema that
      # covers what follows them. The tuple evaluates the leading items it
      # covers and a schema for the rest evaluates every item (their
      # annotations).
      # @return [Array<String>] validation errors
      def validate_items(data, schema, path, ctx, dialect, evaluated = nil)
        items = schema['items']
        # 2020-12 puts positional schemas in prefixItems (items must be a
        # schema); draft-07 and 2019-09 put them in an items array and know no
        # prefixItems.
        positional = if dialect == DEFAULT_DIALECT
                       schema['prefixItems'].is_a?(Array) ? schema['prefixItems'] : []
                     else
                       items.is_a?(Array) ? items : []
                     end
        # Past a draft-07 / 2019-09 tuple it is `additionalItems` that applies.
        rest = if items.is_a?(Array)
                 schema['additionalItems'] if keyword_known?('additionalItems', dialect)
               else
                 items
               end
        return [] if positional.empty? && !schema_value?(rest)

        note_evaluated_items(evaluated, positional, rest, data)
        errors = []
        data.each_with_index do |item, idx|
          # As in {.validate_other_properties}: the array's length is the
          # peer's, and an item the tuple tail rejects visits no node.
          check_deadline(ctx)
          item_schema = idx < positional.length ? positional[idx] : rest
          next unless schema_value?(item_schema)

          if item_schema == false && idx >= positional.length && items.is_a?(Array)
            count_visit(ctx)
            errors << "#{path}: item #{idx} is not allowed (additionalItems is false)"
            next
          end

          # An item is a smaller instance: the hop budget starts over and the
          # depth bound counts the step, so a recursive schema describes data
          # of any depth up to it (see {.validate_named_properties}).
          errors.concat(validate_child(item, item_schema, "#{path}/#{idx}", ctx))
        end
        errors
      end

      # The tuple evaluates the leading items it covers; a schema for the
      # rest evaluates every item (their annotations).
      # @return [void]
      def note_evaluated_items(evaluated, positional, rest, data)
        return unless evaluated

        evaluated.prefix!([positional.length, data.length].min)
        evaluated.all! if schema_value?(rest)
      end

      # uniqueItems (JSON Schema 2020-12 Validation Section 6.4.3). Equality is
      # JSON's, not Ruby's: 1 and 1.0 are the same number and two objects with
      # the same members are equal whatever order they were written in, so the
      # items are compared by a canonical form rather than by identity or by
      # `eql?`.
      # @return [Array<String>] validation errors
      # @raise [Aborted] when a bound is hit
      def validate_unique_items(data, schema, path, ctx)
        return [] unless schema['uniqueItems'] == true

        seen = {}
        data.each_with_index do |item, idx|
          count_visit(ctx)
          key = comparable_value(item, 0, ctx)
          first = seen[key]
          unless first.nil?
            return ["#{path}: items #{first} and #{idx} are equal, but uniqueItems requires every item to differ"]
          end

          seen[key] = idx
        end
        []
      end

      # A value in the form JSON equality compares: numbers as exact rationals
      # (so 1 and 1.0 agree), objects as their members sorted by name and with
      # either Ruby key form read as the same name.
      #
      # The form carries the JSON type, because JSON equality begins with it:
      # an object is never equal to an array, however their members line up
      # (JSON Schema 2020-12 Core Section 4.2.2). Encoding both as a bare
      # Ruby Array made `[{}, []]` and `[{"a": 1}, [["a", 1]]]` read as
      # duplicates, so :strict rejected a conforming result — and, through
      # `not`, accepted one the schema rejects.
      #
      # Canonicalizing a value walks all of it, and the value came from the
      # peer, so every node is accounted for like any other the walk visits.
      # @param value [Object] the instance value
      # @param depth [Integer] how far into the value this is
      # @param ctx [Context] the validation context
      # @return [Object] a value that hashes and compares as JSON equality does
      # @raise [Aborted] when the value nests beyond the bound, or a budget is hit
      def comparable_value(value, depth, ctx)
        raise Aborted, "instance nested deeper than #{MAX_NODE_DEPTH}" if depth > MAX_NODE_DEPTH

        count_visit(ctx)
        case value
        when Hash then [:object, value.map { |k, v| [k.to_s, comparable_value(v, depth + 1, ctx)] }.sort_by(&:first)]
        when Array then [:array, value.map { |v| comparable_value(v, depth + 1, ctx) }]
        when Numeric then [:number, exact_number(value)]
        when String then [:string, value]
        else value
        end
      end

      # @return [Object] the number as an exact rational, or as written when
      #   no rational describes it (an infinity a Ruby caller passed in)
      def exact_number(value)
        value.to_r
      rescue RangeError, NoMethodError
        value
      end

      # `contains` (JSON Schema 2020-12 Validation Sections 6.4.4-6.4.5): the
      # items are matched one by one and counted, and the count must lie
      # between `minContains` (1 by default) and `maxContains`. An item the
      # validator could only partly evaluate is neither a match nor a
      # non-match: it widens the range the count may lie in, and where the
      # bounds do not settle the keyword either way the node's verdict is
      # partial, exactly as an unevaluated assertion makes it.
      # @param data [Array] the instance
      # @param schema [Hash] string-keyed schema
      # @param path [String] location for error messages
      # @param dialect [String, nil] the dialect in force
      # @param evaluated [Evaluated, nil] where the items `contains` matched
      #   are recorded (its annotation, 2020-12 Core Section 10.3.1.3)
      # @return [Array<String>] validation errors
      def validate_contains(data, schema, path, ctx, dialect, evaluated = nil)
        return [] unless keyword_known?('contains', dialect) && schema_value?(schema['contains'])

        min = contains_min(schema, dialect)
        max = contains_max(schema, dialect)
        # Bounds that cannot overlap admit no count at all, so the keyword
        # fails before an item is ever matched against the schema.
        if max && min > max
          return ["#{path}: contains requires between #{min} and #{max} matching items, which no count satisfies"]
        end

        # 2020-12 Core Section 10.3.1.3 gives `contains` the item annotation
        # `unevaluatedItems` reads; 2019-09 does not (its Section 9.3.1.3
        # gives `unevaluatedItems` the annotations of `items` and
        # `additionalItems` alone), so there a matched item stays unevaluated
        # and the keyword still has to answer for it.
        annotating = evaluated if contains_annotates?(dialect)
        hits, unsure = count_contains_matches(data, schema['contains'], path, ctx, annotating)
        errors = []
        errors << "#{path}: expected at least #{min} items matching contains, got #{hits}" if hits + unsure < min
        errors << "#{path}: expected at most #{max} items matching contains, got #{hits}" if max && hits > max
        ctx.undecided += 1 if errors.empty? && unsure.positive? && (hits < min || (max && hits + unsure > max))
        errors
      end

      # Whether the dialect gives `contains` the item annotation that
      # `unevaluatedItems` consumes: 2020-12 does, 2019-09 does not, and
      # draft-07 has neither keyword.
      # @param dialect [String, nil] the dialect in force
      # @return [Boolean]
      def contains_annotates?(dialect)
        dialect != DRAFT_2019_09 && dialect != DRAFT_07
      end

      # Match a `contains` schema against every item. The matches are a
      # verdict, not output, so they are evaluated speculatively and what they
      # could not evaluate is not left behind as this node's uncertainty.
      # @return [Array(Integer, Integer)] the items that matched, and those the
      #   validator could not decide
      def count_contains_matches(data, sub, path, ctx, evaluated = nil)
        hits = 0
        unsure = 0
        data.each_with_index do |item, idx|
          before = ctx.undecided
          errors = speculatively(ctx) { validate_child(item, sub, "#{path}/#{idx}", ctx) }
          if errors.empty? && ctx.undecided > before
            unsure += 1
          elsif errors.empty?
            hits += 1
            evaluated&.index!(idx)
          end
          ctx.undecided = before
        end
        [hits, unsure]
      end
    end
  end
end
