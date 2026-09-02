# frozen_string_literal: true

require 'uri'
require_relative 'schema_validator/dialects'
require_relative 'schema_validator/normalization'
require_relative 'schema_validator/references'
require_relative 'schema_validator/keyword_scan'

module MCPClient
  # Self-contained JSON Schema validator used to check a tool call result's
  # structuredContent against the tool's declared outputSchema (MCP server/tools
  # spec: "Clients SHOULD validate structured results against this schema";
  # the default schema dialect is JSON Schema 2020-12 per basic "JSON Schema
  # Usage").
  #
  # Supported keywords:
  # - type (single value or array of values), enum, const
  # - properties, required (objects)
  # - items, prefixItems (2020-12) / tuple-form items (draft-07, 2019-09),
  #   minItems, maxItems (arrays)
  # - minLength, maxLength, pattern (strings)
  # - minimum, maximum, exclusiveMinimum, exclusiveMaximum (numbers)
  # - allOf, anyOf, oneOf, not, if/then/else (composition)
  # - $ref to a location inside the same schema document (`#`, `#/$defs/x`,
  #   `#/definitions/x`, any JSON pointer, or a plain-name fragment `#name`
  #   naming an `$anchor` / a draft-07 `$id: "#name"` of the referencing
  #   schema's own resource — a subschema whose `$id` is a URI starts a new
  #   resource), with $defs (2019-09, 2020-12) / definitions (draft-07);
  #   under draft-07 a $ref replaces its siblings, under 2019-09 and 2020-12
  #   it applies alongside them
  # - boolean schemas (true / false), at the root or as subschemas
  #
  # MCP 2026-07-28 rules honoured here:
  # - a schema without `$schema` is 2020-12; the dialects in
  #   SUPPORTED_DIALECTS are accepted and any other declared dialect is an
  #   error (not a permissive pass); the keyword grammar follows the dialect
  #   (DIALECT_KEYWORDS): a keyword the dialect does not define is ignored,
  #   neither shape-checked nor reported;
  # - `$ref` (and `$dynamicRef` / `$recursiveRef`) values that do not point
  #   inside the document (network URIs, relative documents, urn:, file:)
  #   are never dereferenced, and a schema carrying one is rejected rather
  #   than treated as permissive;
  # - resource bounds: schema nesting depth, total subschema count, `$ref`
  #   chain length, number of nodes visited, number of errors produced and a
  #   per-validation time budget. Hitting a bound aborts the validation with
  #   one error: an aborted validation never reads as a pass.
  #
  # The rest of the vocabulary (additionalProperties, format assertions,
  # unevaluated*, additionalItems, dependencies, ...) is out of scope:
  # unrecognized keywords are ignored rather than misapplied, so validation is
  # best-effort — it may accept data a full validator would reject, but it
  # does not reject data that conforms to the schema. So that this gap is
  # never silent, {.unsupported_keywords} reports which unapplied validation
  # keywords a schema uses; callers surface them as a warning.
  module SchemaValidator
    extend Dialects
    extend Normalization
    extend References
    extend KeywordScan

    # Raised inside a validation to abandon it (time budget, resource bound).
    class Aborted < StandardError; end

    # The default dialect (basic "JSON Schema Usage": "When a schema does not
    # include a $schema field, it defaults to JSON Schema 2020-12").
    DEFAULT_DIALECT = 'https://json-schema.org/draft/2020-12/schema'
    DRAFT_2019_09 = 'https://json-schema.org/draft/2019-09/schema'
    DRAFT_07 = 'http://json-schema.org/draft-07/schema'

    # Dialects this validator accepts. Any other declared dialect is
    # reported as unsupported ("MUST handle unsupported dialects gracefully
    # by returning an appropriate error indicating the dialect is not
    # supported").
    SUPPORTED_DIALECTS = [DEFAULT_DIALECT, DRAFT_2019_09, DRAFT_07].freeze

    # Resource bounds ("Composition-Keyword Resource Use": implementations
    # SHOULD apply a maximum schema depth, a cap on the total number of
    # subschemas, or a per-validation time budget). A schema comes from the
    # remote server, so all of them apply.
    MAX_SCHEMA_DEPTH = 64
    MAX_SUBSCHEMAS = 2000
    MAX_REF_DEPTH = 32
    MAX_NODE_VISITS = 100_000
    MAX_ERRORS = 100
    MAX_VALUE_INSPECT = 64

    # JSON Schema keywords that affect validation but that this validator
    # does not evaluate: assertion keywords (multipleOf, uniqueItems,
    # contains bounds, property-count bounds, dependentRequired), the
    # remaining applicators, draft-specific keywords, and format (asserted by
    # full validators in format-assertion mode). Their presence means
    # validation is partial: data may pass here that a full validator would
    # reject.
    UNSUPPORTED_KEYWORDS = %w[
      $dynamicRef $recursiveRef
      additionalProperties patternProperties propertyNames dependentSchemas dependencies
      additionalItems contains minContains maxContains uniqueItems contentSchema
      multipleOf format dependentRequired minProperties maxProperties
      unevaluatedProperties unevaluatedItems
    ].freeze

    # Wall-clock budget for a single validate call (pattern matching and the
    # walk itself). Schemas come from the remote server, so an expensive
    # expression or a huge composition must not be able to monopolize the
    # calling thread.
    #
    # The budget is for the whole operation, not per match: a per-match limit
    # multiplies, since the server also controls how many strings it sends
    # (N array items under one pathological items.pattern costs N x limit).
    PATTERN_MATCH_TIMEOUT = 1.0

    # Floor for an individual match's timeout, so a nearly-exhausted budget
    # still makes progress rather than failing every remaining pattern.
    MIN_PATTERN_MATCH_TIMEOUT = 0.01

    # Keywords whose value is a single subschema to walk (or, for `items`,
    # an array of positional subschemas in draft-07 / 2019-09).
    SUBSCHEMA_KEYWORDS = %w[
      items contains additionalProperties additionalItems propertyNames not if then else
      unevaluatedItems unevaluatedProperties contentSchema
    ].freeze

    # Keywords whose value is a map of name => subschema.
    SUBSCHEMA_MAP_KEYWORDS = %w[properties patternProperties $defs definitions dependentSchemas dependencies].freeze

    # Keywords whose value is an array of subschemas.
    SUBSCHEMA_ARRAY_KEYWORDS = %w[allOf anyOf oneOf prefixItems].freeze

    # Keywords whose value is data, not schema: never walked, never re-keyed.
    DATA_KEYWORDS = %w[enum const default examples].freeze

    # Keywords that exist only in some dialects, with the dialects that
    # define them. A keyword absent from this table exists in every
    # supported dialect. Under a dialect that does not define a keyword the
    # keyword is an unknown one: ignored, never shape-checked, walked,
    # evaluated or reported as unsupported.
    DIALECT_KEYWORDS = {
      'prefixItems' => [DEFAULT_DIALECT],
      '$dynamicRef' => [DEFAULT_DIALECT],
      '$dynamicAnchor' => [DEFAULT_DIALECT],
      '$recursiveRef' => [DRAFT_2019_09],
      '$recursiveAnchor' => [DRAFT_2019_09],
      'additionalItems' => [DRAFT_2019_09, DRAFT_07],
      'dependencies' => [DRAFT_07],
      'dependentSchemas' => [DEFAULT_DIALECT, DRAFT_2019_09],
      'dependentRequired' => [DEFAULT_DIALECT, DRAFT_2019_09],
      'unevaluatedItems' => [DEFAULT_DIALECT, DRAFT_2019_09],
      'unevaluatedProperties' => [DEFAULT_DIALECT, DRAFT_2019_09],
      'contentSchema' => [DEFAULT_DIALECT, DRAFT_2019_09],
      'minContains' => [DEFAULT_DIALECT, DRAFT_2019_09],
      'maxContains' => [DEFAULT_DIALECT, DRAFT_2019_09],
      '$anchor' => [DEFAULT_DIALECT, DRAFT_2019_09],
      '$defs' => [DEFAULT_DIALECT, DRAFT_2019_09],
      'definitions' => [DRAFT_07]
    }.freeze

    # Plain-name fragment syntax (JSON Schema 2020-12 Section 8.2.2).
    ANCHOR_NAME = /\A[A-Za-z_][-A-Za-z0-9._]*\z/

    # @param keyword [String]
    # @param dialect [String, nil] a canonical dialect, or nil for "any"
    # @return [Boolean] whether the dialect defines the keyword
    def self.keyword_known?(keyword, dialect)
      dialect.nil? || !DIALECT_KEYWORDS.key?(keyword) || DIALECT_KEYWORDS[keyword].include?(dialect)
    end

    # Per-validation state.
    Context = Struct.new(:root, :deadline, :dialect, :visits, :errors, :speculative, :anchors, keyword_init: true)

    # Raised while normalizing a schema whose structure exceeds the bounds,
    # so a peer-supplied document is never copied whole.
    class TooLarge < StandardError; end

    # Structural elements (schemas, the keyword maps holding them, and array
    # members — boolean subschemas included) a schema document may contain
    # before it is rejected unread. A usable schema has at most
    # MAX_SUBSCHEMAS subschemas, each with a handful of keyword maps at
    # most, so this bound only ever stops documents the preflight would
    # reject anyway.
    MAX_STRUCTURAL_OBJECTS = MAX_SUBSCHEMAS * 4

    # Check that a schema can be used at all: it is an object or a boolean,
    # its dialect is supported, it stays within the resource bounds, and
    # every `$ref` resolves inside the document to a schema (a network or
    # otherwise external reference is never dereferenced and makes the
    # schema unusable rather than permissive).
    # @param schema [Object] the schema (string or symbol keys)
    # @return [Array<String>] problems (empty when the schema is usable)
    def self.check_schema(schema)
      check_normalized(normalize_schema(schema))
    rescue TooLarge => e
      [e.message]
    end

    # A bounded, string-keyed copy of a schema (booleans pass through).
    # @param schema [Object]
    # @return [Object]
    # @raise [TooLarge] when the document exceeds MAX_STRUCTURAL_OBJECTS
    def self.normalize_schema(schema)
      schema.is_a?(Hash) ? deep_stringify(schema, 0, { objects: 0 }) : schema
    end

    # {.check_schema} on an already normalized schema.
    # @return [Array<String>] problems
    def self.check_normalized(root)
      return [] if [true, false].include?(root)
      return ["schema must be an object or a boolean, got #{json_type(root)}"] unless root.is_a?(Hash)

      declared = dialect(root)
      return ['$schema must be a non-empty string naming the dialect'] if declared.nil?
      unless supported_dialect?(declared)
        return ["schema dialect #{clip(declared.inspect)} is not supported " \
                "(supported: #{SUPPORTED_DIALECTS.join(', ')})"]
      end

      problems = []
      counter = { count: 0, dialect: canonical_dialect(declared), walked: {}.compare_by_identity }
      walk_schema(root, root, 0, counter, problems)
      problems.concat(duplicate_anchor_problems(root, counter)) if problems.empty?
      problems.uniq
    end

    # Anchor names must be unique within a schema resource (JSON Schema
    # 2020-12 Core Section 8.2.2): a name declared twice would bind a
    # reference to whichever declaration the walk met first, so the schema
    # is unusable instead.
    # @param resolver [Hash] holder of the memoized anchor index
    # @return [Array<String>]
    def self.duplicate_anchor_problems(root, resolver)
      index = (resolver[:anchors] ||= anchor_index(root, resolver[:dialect]))
      index[:duplicates].map { |name| "anchor #{clip(name.inspect)} is declared more than once in a schema resource" }
    end

    # Walk every subschema position, checking bounds and references. A
    # schema object is walked once, however many positions or references
    # lead to it, so a recursive schema stays within the bounds. The dialect
    # follows the resource: an embedded resource declaring `$schema` is
    # walked under its own dialect.
    # @return [void]
    def self.walk_schema(schema, root, depth, counter, problems, dialect = counter[:dialect])
      return unless problems.empty? && schema_value?(schema)
      return unless admit_schema?(schema, depth, counter, problems)

      if resource_start?(schema) && schema.key?('$schema')
        problem = embedded_dialect_problem(schema)
        return problems << problem if problem

        dialect = embedded_dialect(schema, dialect)
      end
      check_ref(schema, root, depth, problems, dialect, counter) if schema.key?('$ref')
      # draft-07: the $ref replaces its siblings, so the applicators next to
      # it are never applied and are not preflighted either; definitions are
      # a bag of reusable schemas, not applicators, and stay reachable
      # through references.
      if dialect == DRAFT_07 && schema.key?('$ref')
        each_definition(schema, dialect) { |sub| walk_schema(sub, root, depth + 1, counter, problems, dialect) }
        return
      end

      %w[$dynamicRef $recursiveRef].each do |keyword|
        next unless schema.key?(keyword) && keyword_known?(keyword, dialect)

        check_dynamic_ref(keyword, schema[keyword], problems)
      end
      if dialect == DEFAULT_DIALECT && schema['items'].is_a?(Array)
        problems << 'items must be a schema in JSON Schema 2020-12 (positional schemas go in prefixItems)'
      end
      check_applicator_shapes(schema, dialect, problems)
      check_exclusive_bounds(schema, dialect, problems)
      each_subschema(schema, dialect) { |sub| walk_schema(sub, root, depth + 1, counter, problems, dialect) }
    end

    # Account for a schema object about to be walked: once per object, and
    # within the subschema and nesting bounds.
    # @return [Boolean] whether the object's keywords are to be walked
    def self.admit_schema?(schema, depth, counter, problems)
      return false if schema.is_a?(Hash) && counter[:walked].key?(schema)

      counter[:walked][schema] = true if schema.is_a?(Hash)
      counter[:count] += 1
      if counter[:count] > MAX_SUBSCHEMAS
        problems << "schema has more than #{MAX_SUBSCHEMAS} subschemas"
        return false
      end
      return false unless schema.is_a?(Hash)

      if depth > MAX_SCHEMA_DEPTH
        problems << "schema nesting depth exceeds #{MAX_SCHEMA_DEPTH}"
        return false
      end
      true
    end

    # Every applicator value must be a schema (object or boolean), an array
    # of schemas or a map of schemas; anything else is not silently read as
    # "true". Keywords the dialect does not define are ignored.
    # @return [void]
    def self.check_applicator_shapes(schema, dialect, problems)
      schema.each do |keyword, value|
        next unless keyword_known?(keyword, dialect)

        problem = applicator_shape_problem(keyword, value)
        problems << problem if problem
      end
    end

    # @return [String, nil] why an applicator value is malformed
    def self.applicator_shape_problem(keyword, value)
      if SUBSCHEMA_KEYWORDS.include?(keyword)
        tuple = keyword == 'items' && all_schemas?(value)
        "#{keyword} must be a schema" unless schema_value?(value) || tuple
      elsif keyword == 'dependencies'
        dependencies_shape_problem(value)
      elsif SUBSCHEMA_MAP_KEYWORDS.include?(keyword) && !%w[$defs definitions].include?(keyword)
        # $defs / definitions are a bag of reusable values: an entry that is
        # not a schema only matters once a $ref points at it.
        "#{keyword} must be an object of schemas" unless value.is_a?(Hash) && all_schemas?(value.values)
      elsif SUBSCHEMA_ARRAY_KEYWORDS.include?(keyword)
        "#{keyword} must be an array of schemas" unless all_schemas?(value)
      end
    end

    # draft-07: each dependencies entry is a schema or an array of property
    # names.
    # @return [String, nil]
    def self.dependencies_shape_problem(value)
      return if value.is_a?(Hash) && value.each_value.all? { |v| schema_value?(v) || property_names?(v) }

      'dependencies entries must be schemas or arrays of property names'
    end

    # @param value [Object]
    # @return [Boolean] whether value is an array of property names
    def self.property_names?(value)
      value.is_a?(Array) && value.all?(String)
    end

    # exclusiveMinimum / exclusiveMaximum are numbers in every supported
    # dialect (draft-07 validation Sections 6.2.3 and 6.2.5, kept by 2019-09
    # and 2020-12); the boolean modifier form belongs to draft-04, which is
    # not supported, and is not silently ignored (it would turn a bound
    # into a pass).
    # @return [void]
    def self.check_exclusive_bounds(schema, _dialect, problems)
      %w[exclusiveMinimum exclusiveMaximum].each do |keyword|
        next if !schema.key?(keyword) || schema[keyword].is_a?(Numeric)

        problems << "#{keyword} must be a number (the draft-04 boolean form is not supported)"
      end
    end

    # @param values [Object]
    # @return [Boolean] whether values is an array of schemas
    def self.all_schemas?(values)
      values.is_a?(Array) && values.all? { |v| schema_value?(v) }
    end

    # Yield every subschema directly under a schema object (skipping the
    # keywords the dialect does not define; nil applies no dialect).
    # @return [void]
    def self.each_subschema(schema, dialect = nil, &block)
      schema.each do |keyword, value|
        next if DATA_KEYWORDS.include?(keyword) || !keyword_known?(keyword, dialect)

        subschemas_under(keyword, value).each(&block)
      end
    end

    # The subschema positions one keyword holds.
    # @return [Array<Object>]
    def self.subschemas_under(keyword, value)
      if SUBSCHEMA_KEYWORDS.include?(keyword)
        value.is_a?(Array) ? value : [value]
      elsif keyword == 'dependencies'
        # Property-name arrays are data; only the schema entries are walked.
        value.is_a?(Hash) ? value.values.select { |v| schema_value?(v) } : []
      elsif SUBSCHEMA_MAP_KEYWORDS.include?(keyword)
        value.is_a?(Hash) ? value.values : []
      elsif SUBSCHEMA_ARRAY_KEYWORDS.include?(keyword)
        value.is_a?(Array) ? value : []
      else
        []
      end
    end

    # Yield the reusable schemas under the definition bag(s) the dialect
    # defines (`$defs` in 2019-09 / 2020-12, `definitions` in draft-07; both
    # when no dialect is given).
    # @return [void]
    def self.each_definition(schema, dialect = nil, &block)
      %w[$defs definitions].each do |keyword|
        next unless keyword_known?(keyword, dialect)

        schema[keyword].each_value(&block) if schema[keyword].is_a?(Hash)
      end
    end

    # Check the `$ref` of a schema object and preflight what it reaches: a
    # pointer may lead into a bag the dialect does not walk (`definitions`
    # under 2020-12), and what a reference applies must be usable too.
    # @return [void]
    def self.check_ref(schema, root, depth, problems, dialect, counter)
      ref = schema['$ref']
      unless ref.is_a?(String)
        problems << "$ref must be a string, got #{json_type(ref)}"
        return
      end
      if external_ref?(ref)
        problems << "external $ref #{clip(ref.inspect)} is not dereferenced (only references inside the schema " \
                    'document are resolved; network $ref resolution is disabled)'
        return
      end

      problem = ref_chain_problem(ref, root, counter[:dialect], counter, from: schema) do |target|
        # What a reference reaches is walked under its own resource's dialect.
        walk_schema(target, root, depth + 1, counter, problems, indexed_dialect(target, counter) || dialect)
      end
      problems << problem if problem
    end

    # A `$dynamicRef` / `$recursiveRef` is not evaluated, but one pointing
    # outside the document would need a fetch, which never happens: the
    # schema is unusable.
    # @return [void]
    def self.check_dynamic_ref(keyword, ref, problems)
      return unless ref.is_a?(String) && external_ref?(ref)

      problems << "external #{keyword} #{clip(ref.inspect)} is not dereferenced"
    end

    # Follow a local reference (and the references it leads to) at
    # preflight: every hop must resolve to a schema, the chain must not
    # cycle, and it must stay within MAX_REF_DEPTH. Once the whole chain
    # checks out, every target it reached is yielded so the caller can
    # preflight what the reference applies.
    # @param resolver [Hash, Context] holder of the memoized anchor index
    # @param from [Hash] the schema object holding the reference
    # @return [String, nil] the problem, if any
    def self.ref_chain_problem(ref, root, dialect, resolver, from:, &block)
      targets = []
      problem = follow_ref_chain(ref, root, dialect, resolver, from) { |target| targets << target }
      targets.each(&block) if problem.nil? && block
      problem
    end

    # @return [String, nil] the problem, if any; each resolved target is yielded
    def self.follow_ref_chain(ref, root, dialect, resolver, from)
      # A cycle is a chain returning to a schema it already reached: hops
      # are told apart by where they land, not by their fragment text,
      # since the same fragment means something else in another resource.
      seen = {}.compare_by_identity
      current = ref
      loop do
        return "$ref chain #{clip(ref.inspect)} exceeds #{MAX_REF_DEPTH} hops" if seen.size >= MAX_REF_DEPTH

        target = resolve_reference(root, current, dialect, resolver, from: from)
        return "unresolvable local $ref #{clip(current.inspect)}" if target.equal?(UNRESOLVED)
        return "$ref #{clip(current.inspect)} does not point at a schema" unless schema_value?(target)
        return "$ref chain #{clip(ref.inspect)} cycles" if target.is_a?(Hash) && seen.key?(target)

        seen[target] = true if target.is_a?(Hash)
        yield target
        return nil unless target.is_a?(Hash) && target.key?('$ref')

        from = target
        current = target['$ref']
        return "$ref must be a string, got #{json_type(current)}" unless current.is_a?(String)
        return "external $ref #{clip(current.inspect)} is not dereferenced" if external_ref?(current)
      end
    end

    # @param value [Object]
    # @return [Boolean] whether the value is a schema (object or boolean)
    def self.schema_value?(value)
      value.is_a?(Hash) || value == true || value == false
    end

    # Marker for a pointer that does not resolve (nil is a valid schema
    # value position, so it cannot serve as the marker).
    UNRESOLVED = Object.new.freeze

    # Validate data against a schema. An unusable schema (see
    # {.check_schema}) is reported as validation errors, never as a pass,
    # and so is a validation that hit a resource bound.
    # Schema and data hashes may use string or symbol keys.
    # @param data [Object] the value to validate
    # @param schema [Hash, Boolean] the JSON schema
    # @param path [String] JSON-pointer-style location used in error messages
    # @param deadline [Float, nil] monotonic deadline for the whole validation
    # @return [Array<String>] human-readable validation errors (empty if valid)
    def self.validate(data, schema, path: '#', deadline: nil)
      root = normalize_schema(schema)
      problems = check_normalized(root)
      return problems.map { |problem| "#{path}: #{problem}" } unless problems.empty?

      # One deadline covers the entire (recursive) validation.
      deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + PATTERN_MATCH_TIMEOUT
      ctx = Context.new(root: root, deadline: deadline, dialect: canonical_dialect(dialect(root)),
                        visits: 0, errors: 0, speculative: 0, anchors: nil)
      validate_node(data, root, path, ctx, 0)
    rescue TooLarge => e
      ["#{path}: #{e.message}"]
    rescue Aborted => e
      ["#{path}: validation aborted: #{e.message}"]
    end

    # Validate one value against one (sub)schema.
    # @param data [Object] the value
    # @param schema [Object] a subschema (Hash or boolean)
    # @param path [String] location for error messages
    # @param ctx [Context] the validation context
    # @param ref_depth [Integer] $ref hops taken to reach this schema
    # @return [Array<String>] validation errors
    # @raise [Aborted] when a bound is hit
    def self.validate_node(data, schema, path, ctx, ref_depth)
      count_visit(ctx)
      return [] if schema == true
      return count_errors(ctx, ["#{path}: schema false accepts no value"]) if schema == false
      return [] unless schema.is_a?(Hash)

      # draft-07: "$ref" replaces the schema it appears in; later drafts
      # apply it alongside the sibling keywords. The dialect is the one of
      # the schema resource the node belongs to.
      dialect = node_dialect(schema, ctx)
      return validate_ref(data, schema, path, ctx, ref_depth) if schema.key?('$ref') && dialect == DRAFT_07

      errors = []
      counted_before = ctx.errors
      errors.concat(validate_ref(data, schema, path, ctx, ref_depth)) if schema.key?('$ref')
      errors.concat(validate_type(data, schema['type'], path)) if schema.key?('type')
      errors.concat(validate_enum(data, schema, path))
      case data
      when Hash then errors.concat(validate_object(data, schema, path, ctx, ref_depth))
      when Array then errors.concat(validate_array(data, schema, path, ctx, ref_depth, dialect))
      when String then errors.concat(validate_string(data, schema, path, ctx.deadline))
      when Numeric then errors.concat(validate_number(data, schema, path, dialect))
      end
      errors.concat(validate_composition(data, schema, path, ctx, ref_depth))
      # Errors raised by nested nodes were counted when they were produced;
      # only this node's own errors are new.
      count_errors(ctx, errors, already_counted: ctx.errors - counted_before)
    end

    # The dialect in force at a schema object during validation: the one
    # recorded for its resource by the anchor index (built once per
    # validation), else the root's.
    # @return [String, nil]
    def self.node_dialect(schema, ctx)
      ctx.anchors ||= anchor_index(ctx.root, ctx.dialect)
      indexed_dialect(schema, ctx) || ctx.dialect
    end

    # Run a branch whose errors are only a verdict (anyOf/oneOf candidates,
    # not, if): they never count toward MAX_ERRORS. Bounds that abort the
    # whole validation still propagate.
    # @return [Object] the block's value
    def self.speculative(ctx)
      ctx.speculative += 1
      yield
    ensure
      ctx.speculative -= 1
    end

    # Account for one node visit (boolean schemas included, so a huge array
    # under `items: true` still runs into the bounds).
    # @raise [Aborted]
    def self.count_visit(ctx)
      ctx.visits += 1
      raise Aborted, "more than #{MAX_NODE_VISITS} schema nodes visited" if ctx.visits > MAX_NODE_VISITS
      raise Aborted, 'validation time budget exhausted' if budget_exhausted?(ctx.deadline)
    end

    # Account for produced errors against MAX_ERRORS. Errors inside a
    # speculative branch are a verdict, not output, and do not count.
    # @return [Array<String>] the errors
    # @raise [Aborted]
    def self.count_errors(ctx, errors, already_counted: 0)
      return errors if ctx.speculative.positive?

      ctx.errors += errors.size - already_counted
      raise Aborted, "more than #{MAX_ERRORS} validation errors (output truncated)" if ctx.errors > MAX_ERRORS

      errors
    end

    # @return [Boolean] whether the validation-wide deadline has passed
    def self.budget_exhausted?(deadline)
      deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end

    # Apply the local $ref of a schema object.
    # @param schema [Hash] the schema object holding the `$ref`
    # @return [Array<String>] validation errors
    def self.validate_ref(data, schema, path, ctx, ref_depth)
      ref = schema['$ref']
      if !ref.is_a?(String) || external_ref?(ref)
        return count_errors(ctx, ["#{path}: external $ref #{clip(ref.inspect)} is not dereferenced"])
      end
      if ref_depth >= MAX_REF_DEPTH
        raise Aborted, "$ref chain exceeds #{MAX_REF_DEPTH} hops (cycle?) at #{clip(ref.inspect)}"
      end

      target = resolve_reference(ctx.root, ref, ctx.dialect, ctx, from: schema)
      return count_errors(ctx, ["#{path}: unresolvable local $ref #{clip(ref.inspect)}"]) if target.equal?(UNRESOLVED)
      unless schema_value?(target)
        return count_errors(ctx, ["#{path}: $ref #{clip(ref.inspect)} does not point at a schema"])
      end

      validate_node(data, target, path, ctx, ref_depth + 1)
    end

    # allOf / anyOf / oneOf / not / if-then-else.
    # @return [Array<String>] validation errors
    def self.validate_composition(data, schema, path, ctx, ref_depth)
      errors = []
      if schema['allOf'].is_a?(Array)
        schema['allOf'].each_with_index do |sub, idx|
          sub_errors = validate_node(data, sub, path, ctx, ref_depth)
          errors << "#{path}: does not satisfy allOf/#{idx} (#{clip(sub_errors.first.to_s)})" unless sub_errors.empty?
        end
      end
      if schema['anyOf'].is_a?(Array) &&
         schema['anyOf'].none? { |sub| speculative(ctx) { validate_node(data, sub, path, ctx, ref_depth).empty? } }
        errors << "#{path}: does not satisfy any schema in anyOf"
      end
      if schema['oneOf'].is_a?(Array)
        matches = schema['oneOf'].count do |sub|
          speculative(ctx) do
            validate_node(data, sub, path, ctx, ref_depth).empty?
          end
        end
        errors << "#{path}: satisfies #{matches} schemas in oneOf, expected exactly one" unless matches == 1
      end
      if schema.key?('not') && speculative(ctx) { validate_node(data, schema['not'], path, ctx, ref_depth).empty? }
        errors << "#{path}: value satisfies the schema in not"
      end
      errors.concat(validate_conditional(data, schema, path, ctx, ref_depth))
      errors
    end

    # if / then / else.
    # @return [Array<String>] validation errors
    def self.validate_conditional(data, schema, path, ctx, ref_depth)
      # An `if` without `then` or `else` asserts nothing (JSON Schema 2020-12
      # Section 10.2.2.1) and is not evaluated.
      return [] unless schema.key?('if') && (schema.key?('then') || schema.key?('else'))

      branch = speculative(ctx) { validate_node(data, schema['if'], path, ctx, ref_depth).empty? } ? 'then' : 'else'
      return [] unless schema.key?(branch)

      validate_node(data, schema[branch], path, ctx, ref_depth)
    end

    # Validate the JSON type of a value.
    # @param data [Object] the value
    # @param type [String, Symbol, Array<String, Symbol>] expected type(s)
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_type(data, type, path)
      types = (type.is_a?(Array) ? type : [type]).map(&:to_s)
      return [] if types.any? { |t| type_match?(t, data) }

      ["#{path}: expected type #{clip(types.join(' or '))}, got #{json_type(data)}"]
    end

    # Whether a value matches a JSON Schema type name.
    # Unknown type names are not enforced (returns true).
    # @param type [String] the JSON Schema type name
    # @param data [Object] the value
    # @return [Boolean]
    def self.type_match?(type, data)
      case type
      when 'object' then data.is_a?(Hash)
      when 'array' then data.is_a?(Array)
      when 'string' then data.is_a?(String)
      when 'boolean' then data.equal?(true) || data.equal?(false)
      when 'null' then data.nil?
      when 'number' then data.is_a?(Numeric)
      when 'integer' then integer?(data)
      else true
      end
    end

    # Whether a value is a JSON Schema integer. Per JSON Schema 2020-12 a
    # number with a zero fractional part (e.g. 2.0) is a valid integer.
    # @param data [Object] the value
    # @return [Boolean]
    def self.integer?(data)
      return true if data.is_a?(Integer)
      return false unless data.is_a?(Numeric)

      (data % 1).zero?
    end

    # The JSON type name of a Ruby value (for error messages).
    # @param data [Object] the value
    # @return [String]
    def self.json_type(data)
      case data
      when nil then 'null'
      when true, false then 'boolean'
      when Integer then 'integer'
      when Numeric then 'number'
      when String then 'string'
      when Array then 'array'
      when Hash then 'object'
      else data.class.name
      end
    end

    # Validate enum/const membership. Symbol- and string-keyed objects are
    # compared as given on both sides (the schema's data values are never
    # re-keyed).
    # @param data [Object] the value
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_enum(data, schema, path)
      errors = []
      if schema['enum'].is_a?(Array) && !schema['enum'].include?(data)
        errors << "#{path}: value #{clip_value(data)} is not in enum #{clip_value(schema['enum'])}"
      end
      if schema.key?('const') && schema['const'] != data
        errors << "#{path}: value #{clip_value(data)} does not equal const #{clip_value(schema['const'])}"
      end
      errors
    end

    # Validate an object against required/properties.
    # @param data [Hash] the object
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_object(data, schema, path, ctx, ref_depth)
      errors = []
      Array(schema['required']).each do |raw_name|
        name = raw_name.to_s
        errors << "#{path}: missing required property '#{clip(name)}'" unless data.key?(name) || data.key?(name.to_sym)
      end
      properties = schema['properties']
      return errors unless properties.is_a?(Hash)

      properties.each do |raw_name, prop_schema|
        next unless schema_value?(prop_schema)

        name = raw_name.to_s
        key = if data.key?(name)
                name
              elsif data.key?(name.to_sym)
                name.to_sym
              end
        next if key.nil?

        errors.concat(validate_node(data[key], prop_schema, "#{path}/#{name}", ctx, ref_depth))
      end
      errors
    end

    # Validate an array against items/prefixItems/minItems/maxItems.
    # 2020-12 puts positional schemas in `prefixItems` and the rest under
    # `items`; draft-07 and 2019-09 put positional schemas in an `items`
    # array. Both forms are honoured.
    # @param data [Array] the array
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_array(data, schema, path, ctx, ref_depth, dialect = ctx.dialect)
      errors = []
      min_items = schema['minItems']
      max_items = schema['maxItems']
      if min_items.is_a?(Numeric) && data.length < min_items
        errors << "#{path}: expected at least #{min_items} items, got #{data.length}"
      end
      if max_items.is_a?(Numeric) && data.length > max_items
        errors << "#{path}: expected at most #{max_items} items, got #{data.length}"
      end
      items = schema['items']
      # 2020-12 puts positional schemas in prefixItems (items must be a
      # schema); draft-07 and 2019-09 put them in an items array and know no
      # prefixItems.
      positional = if dialect == DEFAULT_DIALECT
                     schema['prefixItems'].is_a?(Array) ? schema['prefixItems'] : []
                   else
                     items.is_a?(Array) ? items : []
                   end
      data.each_with_index do |item, idx|
        item_schema = if idx < positional.length
                        positional[idx]
                      elsif !items.is_a?(Array)
                        items
                      end
        next unless schema_value?(item_schema)

        errors.concat(validate_node(item, item_schema, "#{path}/#{idx}", ctx, ref_depth))
      end
      errors
    end

    # Validate a string against minLength/maxLength/pattern.
    # @param data [String] the string
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_string(data, schema, path, deadline = nil)
      errors = []
      min_length = schema['minLength']
      max_length = schema['maxLength']
      if min_length.is_a?(Numeric) && data.length < min_length
        errors << "#{path}: string is shorter than minLength #{min_length}"
      end
      if max_length.is_a?(Numeric) && data.length > max_length
        errors << "#{path}: string is longer than maxLength #{max_length}"
      end
      errors.concat(validate_pattern(data, schema['pattern'], path, deadline))
      errors
    end

    # Validate a string against a regular-expression pattern.
    # Invalid patterns are not enforced.
    #
    # The pattern comes from the tool's outputSchema, i.e. from the remote
    # server, so matching runs against the validation-wide deadline: neither a
    # single expensive expression nor many cheap-looking ones can pin the
    # calling thread. A match that exceeds the budget aborts the validation
    # rather than silently accepting the value — the value was never shown
    # to satisfy the schema.
    # @param data [String] the string
    # @param pattern [Object] the pattern keyword value
    # @param path [String] location for error messages
    # @param deadline [Float, nil] monotonic deadline for the whole validation
    # @return [Array<String>] validation errors
    # @raise [Aborted] when the budget is exhausted
    def self.validate_pattern(data, pattern, path, deadline = nil)
      return [] unless pattern.is_a?(String)

      remaining = pattern_budget_remaining(deadline)
      raise Aborted, "validation time budget exhausted before pattern #{clip(pattern.inspect)}" if remaining.zero?

      return [] if data.match?(Regexp.new(pattern, timeout: remaining))

      ["#{path}: string does not match pattern #{clip(pattern.inspect)}"]
    rescue Regexp::TimeoutError
      raise Aborted, "pattern #{clip(pattern.inspect)} exceeded the #{PATTERN_MATCH_TIMEOUT}s matching budget"
    rescue RegexpError
      []
    end

    # Time left in the validation-wide budget.
    # @param deadline [Float, nil] monotonic deadline, or nil for a lone match
    # @return [Float] seconds available; 0.0 when exhausted
    def self.pattern_budget_remaining(deadline)
      return PATTERN_MATCH_TIMEOUT unless deadline

      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return 0.0 if remaining <= 0

      [remaining, MIN_PATTERN_MATCH_TIMEOUT].max
    end

    # Validate a number against its bounds. `minimum` / `maximum` and
    # `exclusiveMinimum` / `exclusiveMaximum` are four independent numeric
    # assertions in every supported dialect (draft-07 validation Sections
    # 6.2.2-6.2.5); each present one is applied.
    # @param data [Numeric] the number
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_number(data, schema, path, _dialect = nil)
      errors = []
      minimum = schema['minimum']
      maximum = schema['maximum']
      exclusive_min = schema['exclusiveMinimum']
      exclusive_max = schema['exclusiveMaximum']
      shown = clip_value(data)
      if minimum.is_a?(Numeric) && data < minimum
        errors << "#{path}: value #{shown} is less than minimum #{clip_value(minimum)}"
      end
      if maximum.is_a?(Numeric) && data > maximum
        errors << "#{path}: value #{shown} is greater than maximum #{clip_value(maximum)}"
      end
      if exclusive_min.is_a?(Numeric) && data <= exclusive_min
        errors << "#{path}: value #{shown} must be greater than exclusiveMinimum #{clip_value(exclusive_min)}"
      end
      if exclusive_max.is_a?(Numeric) && data >= exclusive_max
        errors << "#{path}: value #{shown} must be less than exclusiveMaximum #{clip_value(exclusive_max)}"
      end
      errors
    end

    # Bound a piece of peer-derived text destined for a message.
    # @param text [String]
    # @return [String]
    def self.clip(text)
      text = text.to_s
      text.length > MAX_VALUE_INSPECT ? "#{text[0, MAX_VALUE_INSPECT]}..." : text
    end

    # A short rendering of a value for a message that never inspects a
    # large value whole.
    # @param value [Object]
    # @return [String]
    def self.clip_value(value)
      case value
      when String then clip(value[0, MAX_VALUE_INSPECT].inspect)
      when Array then "array(#{value.length} items)"
      when Hash then "object(#{value.length} keys)"
      else clip(value.inspect)
      end
    end
  end
end
