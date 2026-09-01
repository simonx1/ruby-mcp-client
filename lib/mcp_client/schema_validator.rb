# frozen_string_literal: true

require 'uri'

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
  #   `#/definitions/x`, any JSON pointer), with $defs / definitions; under
  #   draft-07 a $ref replaces its siblings, under 2019-09 and 2020-12 it
  #   applies alongside them
  # - boolean schemas (true / false), at the root or as subschemas
  #
  # MCP 2026-07-28 rules honoured here:
  # - a schema without `$schema` is 2020-12; the dialects in
  #   SUPPORTED_DIALECTS are accepted and any other declared dialect is an
  #   error (not a permissive pass);
  # - `$ref` (and `$dynamicRef`) values that do not point inside the document
  #   (network URIs, relative documents, urn:, file:) are never dereferenced,
  #   and a schema carrying one is rejected rather than treated as permissive;
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
      additionalItems contains minContains maxContains uniqueItems
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
      unevaluatedItems unevaluatedProperties
    ].freeze

    # Keywords whose value is a map of name => subschema.
    SUBSCHEMA_MAP_KEYWORDS = %w[properties patternProperties $defs definitions dependentSchemas dependencies].freeze

    # Keywords whose value is an array of subschemas.
    SUBSCHEMA_ARRAY_KEYWORDS = %w[allOf anyOf oneOf prefixItems].freeze

    # Keywords whose value is data, not schema: never walked, never re-keyed.
    DATA_KEYWORDS = %w[enum const default examples].freeze

    # Per-validation state.
    Context = Struct.new(:root, :deadline, :dialect, :visits, :errors, keyword_init: true)

    # The dialect a schema declares, or the default.
    # @param schema [Object] the schema
    # @return [String] the `$schema` value (without a trailing `#`), or DEFAULT_DIALECT
    def self.dialect(schema)
      return DEFAULT_DIALECT unless schema.is_a?(Hash)
      return DEFAULT_DIALECT unless schema.key?('$schema') || schema.key?(:$schema)

      declared = schema.key?('$schema') ? schema['$schema'] : schema[:$schema]
      # A declaration that is present but unusable is not the default.
      return nil unless declared.is_a?(String) && !declared.empty?

      declared.sub(/#\z/, '')
    end

    # The supported dialect a declared URI stands for (scheme-insensitive),
    # or nil.
    # @param uri [String]
    # @return [String, nil]
    def self.canonical_dialect(uri)
      canonical = uri.sub(/#\z/, '').sub(%r{\Ahttps?://}, '')
      SUPPORTED_DIALECTS.find { |d| d.sub(%r{\Ahttps?://}, '') == canonical }
    end

    # @param uri [String]
    # @return [Boolean]
    def self.supported_dialect?(uri)
      !canonical_dialect(uri).nil?
    end

    # Check that a schema can be used at all: it is an object or a boolean,
    # its dialect is supported, it stays within the resource bounds, and
    # every `$ref` resolves inside the document to a schema (a network or
    # otherwise external reference is never dereferenced and makes the
    # schema unusable rather than permissive).
    # @param schema [Object] the schema (string or symbol keys)
    # @return [Array<String>] problems (empty when the schema is usable)
    def self.check_schema(schema)
      return [] if [true, false].include?(schema)
      return ["schema must be an object or a boolean, got #{json_type(schema)}"] unless schema.is_a?(Hash)

      root = deep_stringify(schema)
      declared = dialect(root)
      return ['$schema must be a non-empty string naming the dialect'] if declared.nil?
      unless supported_dialect?(declared)
        return ["schema dialect #{clip(declared.inspect)} is not supported " \
                "(supported: #{SUPPORTED_DIALECTS.join(', ')})"]
      end

      problems = []
      walk_schema(root, root, 0, { count: 0, dialect: canonical_dialect(declared) }, problems)
      problems.uniq
    end

    # Walk every subschema position, checking bounds and references.
    # @return [void]
    def self.walk_schema(schema, root, depth, counter, problems)
      return unless problems.empty?
      return unless schema_value?(schema)

      counter[:count] += 1
      if counter[:count] > MAX_SUBSCHEMAS
        problems << "schema has more than #{MAX_SUBSCHEMAS} subschemas"
        return
      end
      return unless schema.is_a?(Hash)

      if depth > MAX_SCHEMA_DEPTH
        problems << "schema nesting depth exceeds #{MAX_SCHEMA_DEPTH}"
        return
      end

      check_ref(schema['$ref'], root, problems) if schema.key?('$ref')
      check_dynamic_ref(schema['$dynamicRef'], problems) if schema.key?('$dynamicRef')
      if counter[:dialect] == DEFAULT_DIALECT && schema['items'].is_a?(Array)
        problems << 'items must be a schema in JSON Schema 2020-12 (positional schemas go in prefixItems)'
      end
      each_subschema(schema) { |sub| walk_schema(sub, root, depth + 1, counter, problems) }
    end

    # Yield every subschema directly under a schema object.
    # @return [void]
    def self.each_subschema(schema, &block)
      schema.each do |keyword, value|
        next if DATA_KEYWORDS.include?(keyword)

        if SUBSCHEMA_KEYWORDS.include?(keyword)
          value.is_a?(Array) ? value.each(&block) : yield(value)
        elsif SUBSCHEMA_MAP_KEYWORDS.include?(keyword) && value.is_a?(Hash)
          value.each_value(&block)
        elsif SUBSCHEMA_ARRAY_KEYWORDS.include?(keyword) && value.is_a?(Array)
          value.each(&block)
        end
      end
    end

    # @return [void]
    def self.check_ref(ref, root, problems)
      unless ref.is_a?(String)
        problems << "$ref must be a string, got #{json_type(ref)}"
        return
      end
      if external_ref?(ref)
        problems << "external $ref #{clip(ref.inspect)} is not dereferenced (only references inside the schema " \
                    'document are resolved; network $ref resolution is disabled)'
        return
      end

      problem = ref_chain_problem(ref, root)
      problems << problem if problem
    end

    # A `$dynamicRef` is not evaluated, but one pointing outside the document
    # would need a fetch, which never happens: the schema is unusable.
    # @return [void]
    def self.check_dynamic_ref(ref, problems)
      return unless ref.is_a?(String) && external_ref?(ref)

      problems << "external $dynamicRef #{clip(ref.inspect)} is not dereferenced"
    end

    # Follow a local reference (and the references it leads to) at
    # preflight: every hop must resolve to a schema, the chain must not
    # cycle, and it must stay within MAX_REF_DEPTH.
    # @return [String, nil] the problem, if any
    def self.ref_chain_problem(ref, root)
      seen = []
      current = ref
      loop do
        return "$ref chain #{clip(ref.inspect)} cycles" if seen.include?(current)
        return "$ref chain #{clip(ref.inspect)} exceeds #{MAX_REF_DEPTH} hops" if seen.size >= MAX_REF_DEPTH

        seen << current
        target = resolve_pointer(root, current)
        return "unresolvable local $ref #{clip(current.inspect)}" if target.equal?(UNRESOLVED)
        return "$ref #{clip(current.inspect)} does not point at a schema" unless schema_value?(target)
        return nil unless target.is_a?(Hash) && target.key?('$ref')

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

    # A reference that does not point inside this document: an absolute URI
    # (http, https, urn, file, ...), a relative document, or anything that
    # is not a bare fragment. None of these is ever fetched.
    # @param ref [String]
    # @return [Boolean]
    def self.external_ref?(ref)
      !ref.start_with?('#')
    end

    # Marker for a pointer that does not resolve (nil is a valid schema
    # value position, so it cannot serve as the marker).
    UNRESOLVED = Object.new.freeze

    # Resolve a fragment JSON pointer (`#`, `#/$defs/x`, `#/a~1b`, with
    # percent-encoding per RFC 6901 Section 6) within the root document.
    # @param root [Hash] the root schema (string keys)
    # @param ref [String] the `$ref` value
    # @return [Object] the referenced value, or UNRESOLVED
    def self.resolve_pointer(root, ref)
      fragment = ref.delete_prefix('#')
      fragment = URI.decode_uri_component(fragment) rescue fragment # rubocop:disable Style/RescueModifier
      return root if fragment.empty?
      return UNRESOLVED unless fragment.start_with?('/')

      fragment[1..].split('/', -1).reduce(root) do |node, token|
        key = token.gsub('~1', '/').gsub('~0', '~')
        case node
        when Hash
          return UNRESOLVED unless node.key?(key)

          node[key]
        when Array
          return UNRESOLVED unless key.match?(/\A(0|[1-9]\d*)\z/) && key.to_i < node.length

          node[key.to_i]
        else
          return UNRESOLVED
        end
      end
    end

    # List the unsupported JSON Schema keywords a schema uses (anywhere: at the
    # top level or nested in subschemas). Property names that merely look like
    # keywords (e.g. a property called 'not') are not reported, and
    # data-carrying keywords (enum/const/default/examples) are not scanned.
    # @param schema [Object] the JSON schema (string or symbol keys)
    # @return [Array<String>] unique unsupported keywords, in discovery order
    def self.unsupported_keywords(schema)
      found = []
      collect_unsupported_keywords(schema, found, 0)
      found.uniq
    end

    # Recursively collect unsupported keywords from a schema.
    # @param schema [Object] a (sub)schema; non-Hash values are ignored
    # @param found [Array<String>] accumulator
    # @return [void]
    def self.collect_unsupported_keywords(schema, found, depth)
      return unless schema.is_a?(Hash) && depth <= MAX_SCHEMA_DEPTH

      schema = schema.transform_keys(&:to_s)
      found.concat(schema.keys & UNSUPPORTED_KEYWORDS)
      each_subschema(schema) { |sub| collect_unsupported_keywords(sub, found, depth + 1) }
    end

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
      problems = check_schema(schema)
      return problems.map { |problem| "#{path}: #{problem}" } unless problems.empty?

      # One deadline covers the entire (recursive) validation.
      deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + PATTERN_MATCH_TIMEOUT
      root = schema.is_a?(Hash) ? deep_stringify(schema) : schema
      ctx = Context.new(root: root, deadline: deadline, dialect: canonical_dialect(dialect(root)),
                        visits: 0, errors: 0)
      validate_node(data, root, path, ctx, 0)
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
      return [] if schema == true
      return count_errors(ctx, ["#{path}: schema false accepts no value"]) if schema == false
      return [] unless schema.is_a?(Hash)

      ctx.visits += 1
      raise Aborted, "more than #{MAX_NODE_VISITS} schema nodes visited" if ctx.visits > MAX_NODE_VISITS
      raise Aborted, 'validation time budget exhausted' if budget_exhausted?(ctx.deadline)

      # draft-07: "$ref" replaces the schema it appears in; later drafts
      # apply it alongside the sibling keywords.
      return validate_ref(data, schema['$ref'], path, ctx, ref_depth) if schema.key?('$ref') && ctx.dialect == DRAFT_07

      errors = []
      errors.concat(validate_ref(data, schema['$ref'], path, ctx, ref_depth)) if schema.key?('$ref')
      errors.concat(validate_type(data, schema['type'], path)) if schema.key?('type')
      errors.concat(validate_enum(data, schema, path))
      case data
      when Hash then errors.concat(validate_object(data, schema, path, ctx, ref_depth))
      when Array then errors.concat(validate_array(data, schema, path, ctx, ref_depth))
      when String then errors.concat(validate_string(data, schema, path, ctx.deadline))
      when Numeric then errors.concat(validate_number(data, schema, path))
      end
      errors.concat(validate_composition(data, schema, path, ctx, ref_depth))
      count_errors(ctx, errors)
    end

    # Run a branch whose errors are only a verdict (anyOf/oneOf candidates,
    # not, if): they never count toward MAX_ERRORS. Bounds that abort the
    # whole validation still propagate.
    # @return [Object] the block's value
    def self.speculative(ctx)
      before = ctx.errors
      yield
    ensure
      ctx.errors = before
    end

    # Account for produced errors against MAX_ERRORS.
    # @return [Array<String>] the errors
    # @raise [Aborted]
    def self.count_errors(ctx, errors)
      ctx.errors += errors.size
      raise Aborted, "more than #{MAX_ERRORS} validation errors (output truncated)" if ctx.errors > MAX_ERRORS

      errors
    end

    # @return [Boolean] whether the validation-wide deadline has passed
    def self.budget_exhausted?(deadline)
      deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    end

    # Apply a local $ref.
    # @return [Array<String>] validation errors
    def self.validate_ref(data, ref, path, ctx, ref_depth)
      if !ref.is_a?(String) || external_ref?(ref)
        return count_errors(ctx, ["#{path}: external $ref #{clip(ref.inspect)} is not dereferenced"])
      end
      if ref_depth >= MAX_REF_DEPTH
        raise Aborted, "$ref chain exceeds #{MAX_REF_DEPTH} hops (cycle?) at #{clip(ref.inspect)}"
      end

      target = resolve_pointer(ctx.root, ref)
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
      return [] unless schema.key?('if')

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
        errors << "#{path}: value #{clip(data.inspect)} is not in enum #{clip(schema['enum'].inspect)}"
      end
      if schema.key?('const') && schema['const'] != data
        errors << "#{path}: value #{clip(data.inspect)} does not equal const #{clip(schema['const'].inspect)}"
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
    def self.validate_array(data, schema, path, ctx, ref_depth)
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
      positional = if ctx.dialect == DEFAULT_DIALECT
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

    # Validate a number against inclusive/exclusive bounds.
    # @param data [Numeric] the number
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_number(data, schema, path)
      errors = []
      minimum = schema['minimum']
      maximum = schema['maximum']
      exclusive_min = schema['exclusiveMinimum']
      exclusive_max = schema['exclusiveMaximum']
      errors << "#{path}: value #{data} is less than minimum #{minimum}" if minimum.is_a?(Numeric) && data < minimum
      errors << "#{path}: value #{data} is greater than maximum #{maximum}" if maximum.is_a?(Numeric) && data > maximum
      if exclusive_min.is_a?(Numeric) && data <= exclusive_min
        errors << "#{path}: value #{data} must be greater than exclusiveMinimum #{exclusive_min}"
      end
      if exclusive_max.is_a?(Numeric) && data >= exclusive_max
        errors << "#{path}: value #{data} must be less than exclusiveMaximum #{exclusive_max}"
      end
      errors
    end

    # A copy of the schema with every structural Hash key as a String, so
    # keyword lookups and JSON pointers see one key form. Data-carrying
    # keywords (enum, const, default, examples) are left exactly as given,
    # and the walk stops at the nesting bound.
    # @param node [Object]
    # @param depth [Integer]
    # @return [Object]
    def self.deep_stringify(node, depth = 0)
      return node if depth > MAX_SCHEMA_DEPTH + 1

      case node
      when Hash
        node.to_h do |key, value|
          name = key.to_s
          [name, DATA_KEYWORDS.include?(name) ? value : deep_stringify(value, depth + 1)]
        end
      when Array then node.map { |value| deep_stringify(value, depth + 1) }
      else node
      end
    end

    # Bound a piece of peer-derived text destined for a message.
    # @param text [String]
    # @return [String]
    def self.clip(text)
      text = text.to_s
      text.length > MAX_VALUE_INSPECT ? "#{text[0, MAX_VALUE_INSPECT]}..." : text
    end
  end
end
