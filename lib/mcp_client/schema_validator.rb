# frozen_string_literal: true

require 'uri'
require_relative 'schema_validator/dialects'
require_relative 'schema_validator/normalization'
require_relative 'schema_validator/uri_references'
require_relative 'schema_validator/references'
require_relative 'schema_validator/shapes'
require_relative 'schema_validator/keyword_scan'
require_relative 'schema_validator/composition'
require_relative 'schema_validator/evaluation'
require_relative 'schema_validator/scalars'
require_relative 'schema_validator/instances'

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
  #   resource), with $defs (2019-09, 2020-12) and definitions, which the
  #   modern dialects keep as the deprecated spelling of $defs;
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
  # - multipleOf (numbers), uniqueItems, contains with minContains /
  #   maxContains, additionalItems (draft-07, 2019-09) (arrays)
  # - minProperties, maxProperties, patternProperties, additionalProperties,
  #   propertyNames, dependentRequired / dependentSchemas (2019-09, 2020-12)
  #   and draft-07 dependencies (objects)
  #
  # What is left out is what cannot be decided without the annotations a
  # whole composition produces (unevaluatedItems, unevaluatedProperties) or
  # without a dynamic scope ($dynamicRef, $recursiveRef), plus the two
  # keywords that only annotate in the default dialect (format, which full
  # validators assert only in format-assertion mode, and contentSchema).
  # Those are ignored rather than misapplied, so validation is best-effort
  # there — it may accept data a full validator would reject, but it does not
  # reject data that conforms to the schema. So that this gap is never
  # silent, {.unsupported_keywords} reports which unapplied validation
  # keywords a schema uses; callers surface them as a warning.
  module SchemaValidator
    extend Dialects
    extend Normalization
    extend UriReferences
    extend References
    extend Shapes
    extend KeywordScan
    extend Composition
    extend Evaluation
    extend Scalars
    extend Instances

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

    # How deeply the walk may descend into the instance. The descent into a
    # child value is the walk's only recursion, so this is what drives the
    # interpreter's stack: the instance nests a level per array item or
    # property, and a recursive `$ref` follows it down without bound (the hop
    # budget restarts at every value, so that a recursive schema can describe
    # deep data at all). Counting the descent lets the deepest instance abort
    # with one error like any other exhausted budget.
    #
    # Only a step into a child value — an array item or a property value —
    # counts, and only such a step costs a frame. The schemas a node applies
    # to one value (a `$ref` hop, an allOf/anyOf/oneOf/not/if branch) neither
    # count nor recurse: a recursive schema composed through a few `$defs`
    # mixins applies several of them per instance level, and both counting
    # and recursing on those would scale with the mixin count, so data a peer
    # can legitimately send — its nesting under `JSON.parse`'s default limit
    # of 100 — would abort. {.validate_node} applies them iteratively (see
    # {Evaluation}), bounded by MAX_REF_DEPTH and MAX_NODE_VISITS, which is
    # what already stops a schema recursing on one value forever.
    #
    # The bound therefore sits well above the deepest instance a peer can
    # send, and below the number of levels the smallest stack this library
    # runs on (a transport's reader thread) carries — a figure that no longer
    # depends on how a schema is composed, since what one level costs is now
    # fixed. {.validate} still catches SystemStackError, as a backstop for a
    # stack smaller than any this has been measured on rather than for
    # anything a schema can provoke.
    MAX_NODE_DEPTH = 256

    # JSON Schema keywords that affect validation but that this validator
    # does not evaluate: the dynamic references (whose target depends on the
    # dynamic scope a validation was entered through), the two keywords
    # decided by annotations collected across a whole composition
    # (`unevaluatedItems` / `unevaluatedProperties`), and the two that only
    # annotate in the default dialect (`format`, asserted by full validators
    # in format-assertion mode, and `contentSchema`). Their presence means
    # validation is partial: data may pass here that a full validator would
    # reject.
    #
    # Every other standard keyword is evaluated. A standard assertion left
    # unevaluated is not a smaller report but a wrong verdict: it makes a
    # composition branch undecided, and an undecided branch is accepted
    # wherever the composition is monotonic (`allOf`, `anyOf`), so the
    # instance passes a schema that rejects it.
    UNSUPPORTED_KEYWORDS = %w[
      $dynamicRef $recursiveRef contentSchema format
      unevaluatedProperties unevaluatedItems
    ].freeze

    # Unsupported keywords that are annotations, not assertions (`format`
    # is annotation-only in the default 2020-12 vocabulary, `contentSchema`
    # only annotates): their presence decides nothing about an instance.
    ANNOTATION_KEYWORDS = %w[format contentSchema].freeze

    # Unsupported assertions by the instance type they apply to; an
    # assertion of another type is a no-op for the instance (JSON Schema
    # 2020-12 Validation Section 6: keywords apply only to their type), so
    # it cannot leave a branch undecided.
    UNSUPPORTED_ASSERTIONS_BY_TYPE = {
      Hash => %w[unevaluatedProperties],
      Array => %w[unevaluatedItems]
    }.freeze

    # Unsupported keywords that apply to every instance.
    UNSUPPORTED_ASSERTIONS_ANY_TYPE = %w[$dynamicRef $recursiveRef].freeze

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
      '$defs' => [DEFAULT_DIALECT, DRAFT_2019_09]
    }.freeze

    # Plain-name fragment syntax, per dialect: 2020-12 Core Section 8.2.2
    # admits a leading underscore and no colon, while 2019-09 Core Section
    # 8.2.3 and draft-07 Core Section 8.2.3 admit a colon and require a
    # leading letter. A name legal in one dialect is not one in the other,
    # and the dialect in force at the resource decides.
    ANCHOR_NAME_BY_DIALECT = {
      DEFAULT_DIALECT => /\A[A-Za-z_][-A-Za-z0-9._]*\z/,
      DRAFT_2019_09 => /\A[A-Za-z][-A-Za-z0-9.:_]*\z/,
      DRAFT_07 => /\A[A-Za-z][-A-Za-z0-9.:_]*\z/
    }.freeze

    # The 2020-12 plain-name syntax, the default when no dialect is known.
    ANCHOR_NAME = ANCHOR_NAME_BY_DIALECT.fetch(DEFAULT_DIALECT)

    # @param name [Object] the candidate plain name
    # @param dialect [String, nil] the canonical dialect in force
    # @return [Boolean] whether the dialect admits the name as a plain name
    def self.anchor_name?(name, dialect)
      name.is_a?(String) && name.match?(ANCHOR_NAME_BY_DIALECT.fetch(dialect, ANCHOR_NAME))
    end

    # @param keyword [String]
    # @param dialect [String, nil] a canonical dialect, or nil for "any"
    # @return [Boolean] whether the dialect defines the keyword
    def self.keyword_known?(keyword, dialect)
      dialect.nil? || !DIALECT_KEYWORDS.key?(keyword) || DIALECT_KEYWORDS[keyword].include?(dialect)
    end

    # Per-validation state.
    Context = Struct.new(:root, :deadline, :dialect, :visits, :errors, :speculative, :anchors, :undecided, :depth,
                         keyword_init: true)

    # Per-preflight state: the document, the counter the walk accounts to,
    # the problems it found, and the positions it has still to read (a
    # stack, so the walk needs no interpreter frame of its own).
    Walk = Struct.new(:root, :counter, :problems, :pending, keyword_init: true)

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
    # @param counter [Hash] filled in with the preflight state, so a caller
    #   can tell one kind of problem from another (`:unsupported_dialect`)
    # @return [Array<String>] problems (empty when the schema is usable)
    def self.check_schema(schema, counter = {})
      check_normalized(normalize_schema(schema), counter)
    rescue TooLarge => e
      [e.message]
    end

    # The dialect a schema declares (at its root or at an embedded resource
    # root) that this validator does not implement. MCP 2026-07-28 basic
    # "Implementation Requirements": a client "MUST handle unsupported
    # dialects gracefully by returning an appropriate error indicating the
    # dialect is not supported", which a caller can only do once it can tell
    # an unsupported dialect from every other reason a schema is unusable.
    # @param schema [Object] the schema (string or symbol keys)
    # @return [String, nil] the declared dialect, or nil when every dialect
    #   the document declares is supported
    def self.unsupported_dialect(schema)
      state = {}
      check_schema(schema, state)
      state[:unsupported_dialect]
    end

    # A bounded, string-keyed copy of a schema (booleans pass through).
    # @param schema [Object]
    # @param deadline [Float, nil] monotonic deadline the copy runs under
    # @return [Object]
    # @raise [TooLarge] when the document exceeds MAX_STRUCTURAL_OBJECTS
    # @raise [Aborted] when the deadline passed during the copy
    def self.normalize_schema(schema, deadline: nil)
      schema.is_a?(Hash) ? deep_stringify(schema, 0, { objects: 0, deadline: deadline }) : schema
    end

    # {.check_schema} on an already normalized schema.
    # @param counter [Hash] filled in with the preflight state (the memoized
    #   anchor index included), so a caller going on to validate reads the
    #   document the way the preflight read it
    # @return [Array<String>] problems
    def self.check_normalized(root, counter = {})
      return [] if [true, false].include?(root)
      return ["schema must be an object or a boolean, got #{json_type(root)}"] unless root.is_a?(Hash)

      declared = dialect(root)
      return ['$schema must be a non-empty string naming the dialect'] if declared.nil?

      unless supported_dialect?(declared)
        counter[:unsupported_dialect] = declared
        return ["schema dialect #{clip(declared.inspect)} is not supported " \
                "(supported: #{SUPPORTED_DIALECTS.join(', ')})"]
      end

      problems = []
      counter.update(count: 0, dialect: canonical_dialect(declared), walked: {}.compare_by_identity,
                     depths: lexical_depths(root, canonical_dialect(declared)))
      walk_schema(root, root, 0, counter, problems)
      problems.concat(anchor_index_problems(root, counter)) if problems.empty?
      problems.uniq
    end

    # Problems the anchor index reveals: anchor names must be unique within
    # a schema resource (JSON Schema 2020-12 Core Section 8.2.2) and a
    # resource URI unique within the document (Section 9.1.2) — either
    # declared twice would bind a reference to whichever declaration the
    # walk met first — and an index that stopped at its bound before
    # reaching every object leaves references and resource dialects
    # undecided, so either makes the schema unusable.
    # @param resolver [Hash] holder of the memoized anchor index
    # @return [Array<String>]
    def self.anchor_index_problems(root, resolver)
      index = (resolver[:anchors] ||= anchor_index(root, resolver[:dialect]))
      problems = index[:duplicates].map do |name|
        "anchor #{clip(name.inspect)} is declared more than once in a schema resource"
      end
      problems.concat(index[:duplicate_ids].uniq.map do |base|
        "schema resource #{clip(base.inspect)} is declared more than once"
      end)
      if index[:truncated]
        problems << 'schema has too many or too deeply nested objects to index its anchors ' \
                    "(more than #{MAX_SUBSCHEMAS}, or deeper than #{MAX_SCHEMA_DEPTH})"
      end
      problems
    end

    # Walk every subschema position, checking bounds and references. A
    # schema object is walked once, however many positions or references
    # lead to it, so a recursive schema stays within the bounds. The dialect
    # follows the resource: an embedded resource declaring `$schema` is
    # walked under its own dialect.
    # @return [void]
    def self.walk_schema(schema, root, depth, counter, problems, dialect = counter[:dialect])
      walk = Walk.new(root: root, counter: counter, problems: problems,
                      pending: [[schema, depth, dialect]])
      until walk.pending.empty?
        return unless problems.empty?

        walk_position(walk, *walk.pending.pop)
      end
    end

    # Walk one schema position and queue the positions it leads to. The
    # queue is a stack and children are pushed in reverse, so a document is
    # read depth-first and in document order, exactly as a recursive walk
    # would read it — but a `$ref` chain hundreds of schemas long costs
    # queue entries rather than interpreter frames, so a shallow document
    # whose references chain deeply can no longer overflow the (small) stack
    # of the thread a transport reads on. A reference is followed before the
    # position's own subschemas, so it is pushed last.
    # @return [void]
    def self.walk_position(walk, schema, depth, dialect)
      return unless schema_value?(schema)
      return unless admit_schema?(schema, depth, walk.counter, walk.problems)

      if resource_root?(schema, dialect) && schema.key?('$schema')
        problem = embedded_dialect_problem(schema)
        return record_embedded_dialect_problem(walk, schema, problem) if problem

        dialect = embedded_dialect(schema, dialect)
      end
      referenced = schema.key?('$ref') ? check_ref(walk, schema, depth, dialect) : []
      # draft-07: the $ref replaces its siblings, so the applicators next to
      # it are never applied and are not preflighted either; definitions are
      # a bag of reusable schemas, not applicators, and stay reachable
      # through references.
      return queue_definitions(walk, schema, depth, dialect, referenced) if dialect == DRAFT_07 && schema.key?('$ref')

      check_keyword_shapes(walk, schema, dialect)
      queue_subschemas(walk, schema, depth, dialect, referenced)
    end

    # @return [void]
    def self.record_embedded_dialect_problem(walk, schema, problem)
      declared = dialect(schema)
      walk.counter[:unsupported_dialect] ||= declared if declared && !supported_dialect?(declared)
      walk.problems << problem
    end

    # Queue the reusable schemas beside a draft-07 `$ref`, then what the
    # reference reaches (walked first, so pushed last).
    # @return [void]
    def self.queue_definitions(walk, schema, depth, dialect, referenced)
      positions = []
      each_definition(schema, dialect) { |sub| positions << [sub, depth + 1, dialect] }
      queue_positions(walk, positions, referenced)
    end

    # Queue every subschema position under a schema object, then what its
    # reference reaches.
    # @return [void]
    def self.queue_subschemas(walk, schema, depth, dialect, referenced)
      positions = []
      each_subschema(schema, dialect) { |sub| positions << [sub, depth + 1, dialect] }
      queue_positions(walk, positions, referenced)
    end

    # @return [void]
    def self.queue_positions(walk, positions, referenced)
      walk.pending.concat(positions.reverse)
      walk.pending.concat(referenced.reverse)
    end

    # Every check a schema object's own keywords get.
    # @return [void]
    def self.check_keyword_shapes(walk, schema, dialect)
      problems = walk.problems
      %w[$dynamicRef $recursiveRef].each do |keyword|
        next unless schema.key?(keyword) && keyword_known?(keyword, dialect)

        check_dynamic_ref(walk, schema, keyword, dialect)
      end
      if dialect == DEFAULT_DIALECT && schema['items'].is_a?(Array)
        problems << 'items must be a schema in JSON Schema 2020-12 (positional schemas go in prefixItems)'
      end
      check_applicator_shapes(schema, dialect, problems)
      check_assertion_shapes(schema, dialect, problems)
      check_exclusive_bounds(schema, dialect, problems)
      check_identifier_shapes(schema, dialect, problems)
    end

    # Account for a schema (object or boolean) about to be walked: once per
    # object, and within the subschema and nesting bounds — a boolean is a
    # subschema too and obeys the depth bound.
    # @return [Boolean] whether the object's keywords are to be walked
    def self.admit_schema?(schema, depth, counter, problems)
      return false if schema.is_a?(Hash) && counter[:walked].key?(schema)

      counter[:walked][schema] = true if schema.is_a?(Hash)
      counter[:count] += 1
      if counter[:count] > MAX_SUBSCHEMAS
        problems << "schema has more than #{MAX_SUBSCHEMAS} subschemas"
        return false
      end
      if depth > MAX_SCHEMA_DEPTH
        problems << "schema nesting depth exceeds #{MAX_SCHEMA_DEPTH}"
        return false
      end
      schema.is_a?(Hash)
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
    # defines: `definitions` everywhere (2020-12 Validation Appendix A keeps
    # it as the deprecated spelling of `$defs`) and `$defs` in 2019-09 and
    # 2020-12; both when no dialect is given.
    # @return [void]
    def self.each_definition(schema, dialect = nil, &block)
      %w[$defs definitions].each do |keyword|
        next unless keyword_known?(keyword, dialect)

        schema[keyword].each_value(&block) if schema[keyword].is_a?(Hash)
      end
    end

    # Check the `$ref` of a schema object and queue what it reaches: a
    # pointer may lead into a bag the dialect does not walk (`$defs` under
    # draft-07), and what a reference applies must be usable too.
    # @return [Array<Array>] the positions the reference reaches
    def self.check_ref(walk, schema, depth, dialect)
      root = walk.root
      counter = walk.counter
      problems = walk.problems
      ref = schema['$ref']
      unless ref.is_a?(String)
        problems << "$ref must be a string, got #{json_type(ref)}"
        return []
      end
      if external_ref?(ref, root, counter[:dialect], counter, from: schema)
        problems << "external $ref #{clip(ref.inspect)} is not dereferenced (only references inside the schema " \
                    'document are resolved; network $ref resolution is disabled)'
        return []
      end

      positions = []
      problem = ref_chain_problem(ref, root, counter[:dialect], counter, from: schema) do |target, hop, from|
        position = referenced_target_position(walk, target, hop, from, depth, dialect)
        positions << position if position
      end
      problems << problem if problem
      positions
    end

    # The position a reference's target is walked at: under its own
    # resource's dialect and at its own lexical depth. A boolean target
    # needs no preflight and is charged once per distinct position (not per
    # reference), and that position still obeys the depth bound.
    # @return [Array, nil] the position to walk, or nil for a boolean target
    def self.referenced_target_position(walk, target, hop, from, depth, dialect)
      counter = walk.counter
      position, opaque, visited = pointer_position(hop, walk.root, counter[:dialect], counter, from)
      unless target.is_a?(Hash)
        walk.problems << "schema nesting depth exceeds #{MAX_SCHEMA_DEPTH}" if position && position > MAX_SCHEMA_DEPTH
        # A boolean in a position the walk visits was admitted there; one
        # the walk never reaches (behind an opaque keyword, or beside a
        # draft-07 $ref) is charged here, once per position.
        charge_boolean_target(hop, walk.root, from, counter, walk.problems) unless visited
        return nil
      end

      lexical = (counter[:depths] || {})[target]
      target_depth = if opaque
                       [position, lexical].compact.max || (depth + 1)
                     else
                       lexical || position || (depth + 1)
                     end
      [target, target_depth, indexed_dialect(target, counter) || dialect]
    end

    # Count a boolean a reference reaches toward the subschema bound, once
    # per distinct position (resource and decoded pointer): a document may
    # not hide thousands of applied schemas behind pointer-addressable
    # booleans.
    # @return [void]
    def self.charge_boolean_target(hop, root, from, counter, problems)
      index = (counter[:anchors] ||= anchor_index(root, counter[:dialect]))
      resource, hop = pointer_origin(index, root, hop, from)
      return unless resource

      tokens = pointer_tokens(hop)
      return unless tokens

      key = [resource.object_id, tokens]
      seen = (counter[:boolean_targets] ||= {})
      return if seen.key?(key)

      seen[key] = true
      counter[:count] += 1
      problems << "schema has more than #{MAX_SUBSCHEMAS} subschemas" if counter[:count] > MAX_SUBSCHEMAS
    end

    # A `$dynamicRef` / `$recursiveRef` is not evaluated, but one pointing
    # outside the document would need a fetch, which never happens: the
    # schema is unusable.
    # @return [void]
    def self.check_dynamic_ref(walk, schema, keyword, _dialect)
      ref = schema[keyword]
      # A reference that is not a URI reference at all names nothing: it is
      # not silently ignored (a malformed keyword is not an absent one).
      return walk.problems << "#{keyword} must be a string, got #{json_type(ref)}" unless ref.is_a?(String)
      return unless external_ref?(ref, walk.root, walk.counter[:dialect], walk.counter, from: schema)

      walk.problems << "external #{keyword} #{clip(ref.inspect)} is not dereferenced"
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
      problem = follow_ref_chain(ref, root, dialect, resolver, from) { |*hop| targets << hop }
      targets.each { |target, used, origin| block.call(target, used, origin) } if problem.nil? && block
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
        yield target, current, from
        return nil unless target.is_a?(Hash) && target.key?('$ref')

        from = target
        current = target['$ref']
        return "$ref must be a string, got #{json_type(current)}" unless current.is_a?(String)
        if external_ref?(current, root, dialect, resolver, from: from)
          return "external $ref #{clip(current.inspect)} is not dereferenced"
        end
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
      # One deadline covers the entire validation, the copy of the peer's
      # document included.
      deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + PATTERN_MATCH_TIMEOUT
      root = normalize_schema(schema, deadline: deadline)
      # `preflight` comes back holding the state the check read the schema under.
      problems = check_normalized(root, preflight = {})
      return problems.map { |problem| "#{path}: #{problem}" } unless problems.empty?

      # The index the preflight built is the one this validation reads (the
      # resources, dialects and anchors a schema was accepted under, and the
      # subtrees its references adopted): a second one would make what a
      # reference resolves to depend on the order this instance applies them.
      ctx = Context.new(root: root, deadline: deadline, dialect: canonical_dialect(dialect(root)),
                        visits: 0, errors: 0, speculative: 0, anchors: preflight[:anchors], undecided: 0,
                        depth: 0)
      validate_node(data, root, path, ctx, 0)
    rescue TooLarge => e
      ["#{path}: #{e.message}"]
    rescue Aborted => e
      ["#{path}: validation aborted: #{e.message}"]
    rescue SystemStackError
      # A backstop, not a working bound: the `$ref` chain and the composition
      # branches a schema spends on one value are applied iteratively, so
      # what one instance level costs is fixed and MAX_NODE_DEPTH bounds the
      # stack. Should some stack still be smaller than that — the walk holds
      # no state outside `ctx` — the unwound stack leaves nothing behind, and
      # the validation ends the way an exhausted budget does, as one error,
      # never as a crash out of a tool call.
      ["#{path}: validation aborted: schema too deeply recursive for this stack"]
    end

    # Validate one value against one (sub)schema, and against every schema
    # that one leads to for the same value: a `$ref` hop, an
    # allOf/anyOf/oneOf/not/if branch, a then/else. Applying another schema
    # to the same value does not nest the instance, so it is the `$ref` hop
    # budget and the visit cap that bound it; {.validate_child} accounts for
    # the steps that do nest.
    #
    # Those same-instance applications run on the `pending` list here rather
    # than on the Ruby stack (see {Evaluation}): a schema composed through N
    # `$defs` mixins applies N of them to every instance level, and spending
    # a frame on each would make the stack grow with the product of the
    # instance depth and the mixin count — so data a peer can legitimately
    # send would overflow the small stack of a transport's reader thread. A
    # frame is spent only on the step into a child value, which is what
    # MAX_NODE_DEPTH bounds.
    # @param data [Object] the value
    # @param schema [Object] a subschema (Hash or boolean)
    # @param path [String] location for error messages
    # @param ctx [Context] the validation context
    # @param ref_depth [Integer] $ref hops taken to reach this schema
    # @return [Array<String>] validation errors
    # @raise [Aborted] when a bound is hit
    def self.validate_node(data, schema, path, ctx, ref_depth)
      pending = []
      step = start_node(data, schema, path, ctx, ref_depth)
      loop do
        if step[0] == :apply
          pending << step
          # A speculative application's errors are a verdict, not output, and
          # do not count toward MAX_ERRORS while it runs.
          ctx.speculative += 1 if step[3]
          step = start_node(data, step[1], path, ctx, step[2])
          next
        end

        errors = step[1]
        return errors if pending.empty?

        resumed = pending.pop
        ctx.speculative -= 1 if resumed[3]
        step = resumed[4].call(errors)
      end
    end

    # Validate a child of the value being validated — an array item or a
    # property value — against the subschema for it. This is the one step
    # that nests the instance, so it is where the walk's depth is counted and
    # where the `$ref` hop budget starts over (see {.validate_object}).
    # @param data [Object] the child value
    # @param schema [Object] the subschema for it (Hash or boolean)
    # @param path [String] location for error messages
    # @param ctx [Context] the validation context
    # @return [Array<String>] validation errors
    # @raise [Aborted] when a bound is hit
    def self.validate_child(data, schema, path, ctx)
      ctx.depth += 1
      raise Aborted, "instance nested deeper than #{MAX_NODE_DEPTH}" if ctx.depth > MAX_NODE_DEPTH

      validate_node(data, schema, path, ctx, 0)
    ensure
      ctx.depth -= 1
    end

    # The dialect in force at a schema object during validation: the one
    # recorded for its resource by the anchor index (built once per
    # validation), else the root's.
    # @return [String, nil]
    def self.node_dialect(schema, ctx)
      ctx.anchors ||= anchor_index(ctx.root, ctx.dialect)
      indexed_dialect(schema, ctx) || ctx.dialect
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
