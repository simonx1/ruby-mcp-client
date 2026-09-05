# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # Applying schemas to one instance value, without recursing per schema.
    # Extended into SchemaValidator, so the methods are its own.
    #
    # A validation walks two things at once: down the instance, and — at each
    # value — through the schemas that apply to it. Only the first nests the
    # data, and only the first is counted by MAX_NODE_DEPTH; the second is a
    # `$ref` hop or a composition branch applied to the *same* value, bounded
    # by MAX_REF_DEPTH and the node-visit cap instead.
    #
    # A schema composed through a handful of `$defs` mixins applies several
    # of those per instance level, so if each of them cost a Ruby frame the
    # stack would grow with the product of the instance depth and the mixin
    # count — and a conforming result would abort on a transport reader
    # thread's stack, which is where a tool call is validated. So the
    # same-instance applications run on an explicit stack here (this
    # module's `pending` list) rather than on the interpreter's: a step is
    # requested by returning `[:apply, schema, ref_depth, speculative,
    # continuation]` and finished by returning `[:done, errors]`, and
    # {SchemaValidator.validate_node} drives the two until the outermost
    # application is done. A Ruby frame is then spent only on a step into a
    # child value ({SchemaValidator.validate_child}), which is exactly what
    # MAX_NODE_DEPTH bounds.
    module Evaluation
      # One (sub)schema being applied to one value: the instance and the
      # context are fixed for a whole trampoline (the same value throughout),
      # the rest is what this application accumulates.
      # @!attribute errors
      #   @return [Array<String>] this node's own errors so far
      # @!attribute counted_before
      #   @return [Integer] ctx.errors when the application began, so only
      #     this node's own errors are charged to MAX_ERRORS
      Application = Struct.new(:data, :path, :ctx, :schema, :dialect, :ref_depth, :errors, :counted_before,
                               keyword_init: true)

      # The composition keywords, in the order they are applied. Each step
      # takes the application and a continuation, and returns a step.
      COMPOSITION_STEPS = %i[compose_all_of compose_any_of compose_one_of compose_not compose_conditional
                             compose_dependent_schemas].freeze

      # Begin applying one (sub)schema to the value, under the bound on the
      # walk itself: one more node visited.
      # @param data [Object] the value
      # @param schema [Object] a subschema (Hash or boolean)
      # @param path [String] location for error messages
      # @param ctx [Context] the validation context
      # @param ref_depth [Integer] $ref hops taken to reach this schema
      # @return [Array] a step: [:done, errors] or [:apply, ...]
      # @raise [Aborted] when a bound is hit
      def start_node(data, schema, path, ctx, ref_depth)
        count_visit(ctx)
        return [:done, []] if schema == true
        return [:done, count_errors(ctx, ["#{path}: schema false accepts no value"])] if schema == false
        return [:done, []] unless schema.is_a?(Hash)

        app = Application.new(data: data, path: path, ctx: ctx, schema: schema,
                              dialect: node_dialect(schema, ctx), ref_depth: ref_depth,
                              errors: [], counted_before: ctx.errors)
        schema.key?('$ref') ? apply_ref(app) : apply_keywords(app)
      end

      # Apply the local `$ref` of a schema object. draft-07: "$ref" replaces
      # the schema it appears in; later drafts apply it alongside the sibling
      # keywords.
      # @param app [Application]
      # @return [Array] a step
      def apply_ref(app)
        replaces = app.dialect == DRAFT_07
        kind, target = ref_target(app)
        if kind == :errors
          return [:done, target] if replaces

          app.errors.concat(target)
          return apply_keywords(app)
        end

        [:apply, target, app.ref_depth + 1, false, lambda do |errors|
          next [:done, errors] if replaces

          app.errors.concat(errors)
          apply_keywords(app)
        end]
      end

      # Resolve the reference a schema object carries.
      # @param app [Application]
      # @return [Array(Symbol, Object)] [:target, schema] or [:errors, errors]
      # @raise [Aborted] when the hop budget is exhausted
      def ref_target(app)
        ctx = app.ctx
        ref = app.schema['$ref']
        if unusable_ref?(ref, ctx, app.schema)
          return ref_problem(app, "external $ref #{clip(ref.inspect)} is not dereferenced")
        end
        if app.ref_depth >= MAX_REF_DEPTH
          raise Aborted, "$ref chain exceeds #{MAX_REF_DEPTH} hops (cycle?) at #{clip(ref.inspect)}"
        end

        target = resolve_reference(ctx.root, ref, ctx.dialect, ctx, from: app.schema)
        return ref_problem(app, "unresolvable local $ref #{clip(ref.inspect)}") if target.equal?(UNRESOLVED)
        return ref_problem(app, "$ref #{clip(ref.inspect)} does not point at a schema") unless schema_value?(target)

        [:target, target]
      end

      # @param ref [Object] the `$ref` value
      # @param ctx [Context] the validation context
      # @param from [Hash] the schema object holding the reference
      # @return [Boolean] whether it is a reference this validator never follows
      def unusable_ref?(ref, ctx, from)
        !ref.is_a?(String) || external_ref?(ref, ctx.root, ctx.dialect, ctx, from: from)
      end

      # @param app [Application]
      # @param message [String] the problem, without the location
      # @return [Array(Symbol, Array<String>)]
      def ref_problem(app, message)
        [:errors, count_errors(app.ctx, ["#{app.path}: #{message}"])]
      end

      # Apply the assertions this validator evaluates for the value's own
      # type, then hand over to the composition keywords. A step into a child
      # value happens here, and is the one place a Ruby frame is spent.
      # @param app [Application]
      # @return [Array] a step
      def apply_keywords(app)
        data = app.data
        schema = app.schema
        errors = app.errors
        errors.concat(validate_type(data, schema['type'], app.path)) if schema.key?('type')
        # A node its own `type` already rejected is decided: the keywords for
        # the value's actual type could only add detail, and evaluating them
        # would spend the peer's `patternProperties` expressions and item
        # schemas on a value this schema has refused.
        return compose(app) unless errors.empty?

        errors.concat(validate_enum(data, schema, app.path))
        case data
        when Hash then errors.concat(validate_object(data, schema, app.path, app.ctx, app.dialect))
        when Array then errors.concat(validate_array(data, schema, app.path, app.ctx, app.dialect))
        when String then errors.concat(validate_string(data, schema, app.path, app.ctx.deadline))
        when Numeric then errors.concat(validate_number(data, schema, app.path, app.dialect))
        end
        compose(app)
      end

      # Run the composition keywords in order, each handed the step that
      # continues with the next.
      # @param app [Application]
      # @param index [Integer] the composition keyword to apply
      # @return [Array] a step
      def compose(app, index = 0)
        return finish_node(app) if index >= COMPOSITION_STEPS.length

        send(COMPOSITION_STEPS[index], app) { compose(app, index + 1) }
      end

      # Finish an application: a keyword the validator does not evaluate
      # makes this node's verdict partial, so a pass here is not a proof for
      # not / oneOf / if. A node its supported assertions already rejected is
      # decided whatever else it holds, and pays for no such measurement.
      # Errors raised by nested nodes were counted when they were produced;
      # only this node's own errors are new.
      # @param app [Application]
      # @return [Array] a step
      def finish_node(app)
        ctx = app.ctx
        ctx.undecided += 1 if app.errors.empty? && partial_keywords?(app.schema, app.dialect, app.data, ctx.deadline)
        [:done, count_errors(ctx, app.errors, already_counted: ctx.errors - app.counted_before)]
      end

      # The schema half of a dependency: `dependentSchemas` in 2019-09 and
      # 2020-12, and the schema entries of draft-07's `dependencies` (JSON
      # Schema 2020-12 Core Section 10.2.2.4, draft-07 Section 6.5.7). Each
      # dependency whose trigger the instance carries applies its schema to
      # that same instance, so — like allOf — it runs on the trampoline
      # rather than on the interpreter's stack.
      # @param app [Application]
      # @return [Array] a step
      def compose_dependent_schemas(app, &cont)
        return cont.call unless app.data.is_a?(Hash)

        subs = triggered_dependencies(app)
        return cont.call if subs.empty?

        dependency_branch(app, subs, 0, cont)
      end

      # @param app [Application]
      # @return [Array<Array(String, Object)>] the trigger and schema of every
      #   dependency the instance turns on, in document order
      def triggered_dependencies(app)
        subs = []
        %w[dependentSchemas dependencies].each do |keyword|
          map = app.schema[keyword] if keyword_known?(keyword, app.dialect)
          next unless map.is_a?(Hash)

          map.each do |trigger, sub|
            subs << [trigger.to_s, sub] if schema_value?(sub) && property_present?(app.data, trigger)
          end
        end
        subs
      end

      # @param app [Application]
      # @param subs [Array] the triggered dependencies
      # @param idx [Integer] the dependency to apply
      # @param cont [Proc] what follows
      # @return [Array] a step
      def dependency_branch(app, subs, idx, cont)
        return cont.call if idx >= subs.length

        trigger, sub = subs[idx]
        [:apply, sub, app.ref_depth, false, lambda do |errors|
          next dependency_branch(app, subs, idx + 1, cont) if errors.empty?

          app.errors << "#{app.path}: does not satisfy the schema required by property " \
                        "'#{clip(trigger)}' (#{clip(errors.first.to_s)})"
          dependency_branch(app, subs, idx + 1, cont)
        end]
      end

      # allOf: the first failing branch decides it, and later branches are
      # not evaluated (they cannot change the outcome, but could abort it).
      # @param app [Application]
      # @return [Array] a step
      def compose_all_of(app, &cont)
        subs = app.schema['allOf']
        return cont.call unless subs.is_a?(Array)

        all_of_branch(app, subs, 0, cont)
      end

      # @param app [Application]
      # @param subs [Array] the allOf branches
      # @param idx [Integer] the branch to evaluate
      # @param cont [Proc] what follows allOf
      # @return [Array] a step
      def all_of_branch(app, subs, idx, cont)
        return cont.call if idx >= subs.length

        [:apply, subs[idx], app.ref_depth, false, lambda do |errors|
          next all_of_branch(app, subs, idx + 1, cont) if errors.empty?

          app.errors << "#{app.path}: does not satisfy allOf/#{idx} (#{clip(errors.first.to_s)})"
          cont.call
        end]
      end

      # anyOf is monotonic: a definite pass decides it whatever the other
      # branches, and only undecided branches leave it undecided.
      # @param app [Application]
      # @return [Array] a step
      def compose_any_of(app, &cont)
        subs = app.schema['anyOf']
        return cont.call unless subs.is_a?(Array)

        branch_verdicts(app, subs, stop: ->(vs) { vs.include?(:pass) },
                                   decided: ->(vs) { vs.all?(:fail) }) do |verdicts|
          app.errors << "#{app.path}: does not satisfy any schema in anyOf" if verdicts.all?(:fail)
          cont.call
        end
      end

      # oneOf: two definite passes decide it; with an undecided branch and at
      # most one pass, "exactly one" cannot be told either way.
      # @param app [Application]
      # @return [Array] a step
      def compose_one_of(app, &cont)
        subs = app.schema['oneOf']
        return cont.call unless subs.is_a?(Array)

        branch_verdicts(app, subs, stop: ->(vs) { vs.count(:pass) > 1 },
                                   decided: ->(vs) { vs.none?(:undecided) }) do |verdicts|
          matches = verdicts.count(:pass)
          if matches > 1 || (verdicts.none?(:undecided) && matches != 1)
            app.errors << "#{app.path}: satisfies #{matches} schemas in oneOf, expected exactly one"
          end
          cont.call
        end
      end

      # @param app [Application]
      # @return [Array] a step
      def compose_not(app, &cont)
        return cont.call unless app.schema.key?('not')

        branch_verdict(app, app.schema['not']) do |verdict|
          app.errors << "#{app.path}: value satisfies the schema in not" if verdict == :pass
          cont.call
        end
      end

      # if / then / else. An `if` without `then` or `else` asserts nothing
      # (JSON Schema 2020-12 Section 10.2.2.1) and is not evaluated; an
      # undecided condition applies neither branch, but may still be settled
      # by the branches agreeing ({#unconditional_conditional}).
      # @param app [Application]
      # @return [Array] a step
      def compose_conditional(app, &cont)
        schema = app.schema
        return cont.call unless schema.key?('if') && (schema.key?('then') || schema.key?('else'))

        branch_verdict(app, schema['if']) do |verdict|
          branch = { pass: 'then', fail: 'else' }[verdict]
          next unconditional_conditional(app, cont) if branch.nil?
          next cont.call unless schema.key?(branch)

          [:apply, schema[branch], app.ref_depth, false, lambda do |errors|
            app.errors.concat(errors)
            cont.call
          end]
        end
      end

      # A condition this validator cannot decide still settles the instance
      # when both outcomes reject it: exactly one of `then` and `else` is
      # applied (JSON Schema 2020-12 Section 10.2.2.2 and 10.2.2.3), so a
      # value both of them reject is invalid whichever way the condition
      # goes. Reporting nothing there would turn a definite failure into a
      # pass — and, under :strict, accept a result the schema rejects. Only
      # a definite rejection counts on each side; what a branch could not
      # evaluate leaves the conditional undecided as before.
      # @param app [Application]
      # @param cont [Proc] what follows the conditional
      # @return [Array] a step
      def unconditional_conditional(app, cont)
        schema = app.schema
        return cont.call unless schema.key?('then') && schema.key?('else')

        undecided = app.ctx.undecided
        [:apply, schema['then'], app.ref_depth, true, lambda do |then_errors|
          next resume_conditional(app, undecided, cont) if then_errors.empty?

          [:apply, schema['else'], app.ref_depth, true, lambda do |else_errors|
            unless else_errors.empty?
              app.errors << "#{app.path}: fails both then and else of an if this validator cannot decide " \
                            "(#{clip(then_errors.first.to_s)})"
            end
            resume_conditional(app, undecided, cont)
          end]
        end]
      end

      # Resume after measuring the branches: what they could not evaluate is
      # not this node's uncertainty (the condition's already is).
      # @return [Array] a step
      def resume_conditional(app, undecided, cont)
        app.ctx.undecided = undecided
        cont.call
      end

      # The verdicts of a keyword's branches. Evaluation stops as soon as the
      # branches seen so far settle the composition (`stop`): a branch that
      # cannot change the outcome is not evaluated, so it cannot abort a
      # decided validation. Once the composition is decided — early, or after
      # every branch (`decided`) — the uncertainty count is restored to what
      # it was before the branches ran.
      # @param app [Application]
      # @param subs [Array] the branches
      # @return [Array] a step
      def branch_verdicts(app, subs, stop:, decided:, &cont)
        before = app.ctx.undecided
        verdicts = []
        advance = nil
        advance = lambda do
          if verdicts.length >= subs.length || stop.call(verdicts)
            app.ctx.undecided = before if stop.call(verdicts) || decided.call(verdicts)
            next cont.call(verdicts)
          end

          branch_verdict(app, subs[verdicts.length]) do |verdict|
            verdicts << verdict
            advance.call
          end
        end
        advance.call
      end

      # The verdict of a branch evaluated speculatively (its errors are a
      # verdict, not output): :fail when a supported assertion rejected the
      # value, :pass when every assertion was evaluated and accepted it,
      # :undecided when it was accepted only as far as the validator could
      # evaluate. Non-monotonic compositions (not, oneOf, if) never treat
      # :undecided as a match. A definite verdict leaves no uncertainty
      # behind: what a failing branch could not evaluate does not matter once
      # it failed.
      # @param app [Application]
      # @param sub [Object] the branch schema
      # @return [Array] a step
      def branch_verdict(app, sub, &cont)
        ctx = app.ctx
        before = ctx.undecided
        [:apply, sub, app.ref_depth, true, lambda do |errors|
          unless errors.empty?
            ctx.undecided = before
            next cont.call(:fail)
          end

          cont.call(ctx.undecided == before ? :pass : :undecided)
        end]
      end
    end
  end
end
