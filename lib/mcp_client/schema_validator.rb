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
  # - items, minItems, maxItems (arrays)
  # - minLength, maxLength, pattern (strings)
  # - minimum, maximum, exclusiveMinimum, exclusiveMaximum (numbers)
  # - allOf, anyOf, oneOf, not, if/then/else (composition)
  # - $ref to a location inside the same schema document (`#`, `#/$defs/x`,
  #   `#/definitions/x`, any JSON pointer), with $defs / definitions
  # - boolean schemas (true / false)
  #
  # MCP 2026-07-28 rules honoured here:
  # - a schema without `$schema` is 2020-12; the dialects in
  #   SUPPORTED_DIALECTS are accepted and any other declared dialect is an
  #   error (not a permissive pass);
  # - `$ref` values that do not point inside the document (network URIs,
  #   relative documents, urn:, file:) are never dereferenced, and a schema
  #   carrying one is rejected rather than treated as permissive;
  # - resource bounds: schema nesting depth, total subschema count, `$ref`
  #   chain length and a per-validation time budget.
  #
  # The rest of the 2020-12 vocabulary (additionalProperties, format
  # assertions, unevaluated*, ...) is out of scope: unrecognized keywords are
  # ignored rather than misapplied, so validation is best-effort — it may
  # accept data a full validator would reject, but it does not reject data
  # that conforms to the schema. So that this gap is never silent,
  # {.unsupported_keywords} reports which unapplied validation keywords a
  # schema uses; callers surface them as a warning.
  module SchemaValidator
    # The default dialect (basic "JSON Schema Usage": "When a schema does not
    # include a $schema field, it defaults to JSON Schema 2020-12").
    DEFAULT_DIALECT = 'https://json-schema.org/draft/2020-12/schema'

    # Dialects this validator accepts: the keywords it evaluates have the
    # same meaning in all three. Any other declared dialect is reported as
    # unsupported ("MUST handle unsupported dialects gracefully by returning
    # an appropriate error indicating the dialect is not supported").
    SUPPORTED_DIALECTS = [
      DEFAULT_DIALECT,
      'https://json-schema.org/draft/2019-09/schema',
      'http://json-schema.org/draft-07/schema'
    ].freeze

    # Resource bounds ("Composition-Keyword Resource Use": implementations
    # SHOULD apply a maximum schema depth, a cap on the total number of
    # subschemas, or a per-validation time budget). A schema comes from the
    # remote server, so all three apply.
    MAX_SCHEMA_DEPTH = 64
    MAX_SUBSCHEMAS = 2000
    MAX_REF_DEPTH = 32

    # JSON Schema 2020-12 keywords that affect validation but that this
    # validator does not evaluate: assertion keywords (multipleOf,
    # uniqueItems, contains bounds, property-count bounds, dependentRequired),
    # the remaining applicators, and format (asserted by full validators in
    # format-assertion mode). Their presence means validation is partial:
    # data may pass here that a full validator would reject.
    UNSUPPORTED_KEYWORDS = %w[
      $dynamicRef
      additionalProperties patternProperties propertyNames dependentSchemas
      prefixItems contains minContains maxContains uniqueItems
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

    # Keywords whose value is a single subschema to walk.
    SUBSCHEMA_KEYWORDS = %w[
      items contains additionalProperties propertyNames not if then else
      unevaluatedItems unevaluatedProperties
    ].freeze

    # Keywords whose value is a map of name => subschema.
    SUBSCHEMA_MAP_KEYWORDS = %w[properties patternProperties $defs definitions dependentSchemas].freeze

    # Keywords whose value is an array of subschemas.
    SUBSCHEMA_ARRAY_KEYWORDS = %w[allOf anyOf oneOf prefixItems].freeze

    # Per-validation state: the root document ($ref targets), the deadline
    # and the number of $ref hops taken on the current path.
    Context = Struct.new(:root, :deadline, keyword_init: true)

    # The dialect a schema declares, or the default.
    # @param schema [Object] the schema
    # @return [String] the `$schema` value (without a trailing `#`), or DEFAULT_DIALECT
    def self.dialect(schema)
      return DEFAULT_DIALECT unless schema.is_a?(Hash)

      declared = schema['$schema'] || schema[:$schema]
      return DEFAULT_DIALECT unless declared.is_a?(String) && !declared.empty?

      declared.sub(/#\z/, '')
    end

    # Whether a declared dialect is one this validator evaluates. The
    # scheme is not significant (both http and https forms circulate).
    # @param uri [String]
    # @return [Boolean]
    def self.supported_dialect?(uri)
      canonical = uri.sub(/#\z/, '').sub(%r{\Ahttps?://}, '')
      SUPPORTED_DIALECTS.any? { |d| d.sub(%r{\Ahttps?://}, '') == canonical }
    end

    # Check that a schema can be used at all: it is an object, its dialect
    # is supported, it stays within the resource bounds, and every `$ref`
    # resolves inside the document (a network or otherwise external `$ref`
    # is never dereferenced and makes the schema unusable rather than
    # permissive).
    # @param schema [Object] the schema (string or symbol keys)
    # @return [Array<String>] problems (empty when the schema is usable)
    def self.check_schema(schema)
      return ["schema must be an object, got #{json_type(schema)}"] unless schema.is_a?(Hash)

      root = deep_stringify(schema)
      declared = dialect(root)
      unless supported_dialect?(declared)
        return ["schema dialect #{declared.inspect} is not supported (supported: #{SUPPORTED_DIALECTS.join(', ')})"]
      end

      problems = []
      walk_schema(root, root, 0, { count: 0 }, problems)
      problems.uniq
    end

    # Walk every subschema position, checking bounds and references.
    # @return [void]
    def self.walk_schema(schema, root, depth, counter, problems)
      return unless schema.is_a?(Hash)
      return unless problems.empty?

      if depth > MAX_SCHEMA_DEPTH
        problems << "schema nesting depth exceeds #{MAX_SCHEMA_DEPTH}"
        return
      end
      counter[:count] += 1
      if counter[:count] > MAX_SUBSCHEMAS
        problems << "schema has more than #{MAX_SUBSCHEMAS} subschemas"
        return
      end

      check_ref(schema['$ref'], root, problems) if schema.key?('$ref')
      schema.each do |keyword, value|
        if SUBSCHEMA_KEYWORDS.include?(keyword)
          walk_schema(value, root, depth + 1, counter, problems)
        elsif SUBSCHEMA_MAP_KEYWORDS.include?(keyword) && value.is_a?(Hash)
          value.each_value { |subschema| walk_schema(subschema, root, depth + 1, counter, problems) }
        elsif SUBSCHEMA_ARRAY_KEYWORDS.include?(keyword) && value.is_a?(Array)
          value.each { |subschema| walk_schema(subschema, root, depth + 1, counter, problems) }
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
        problems << "external $ref #{ref.inspect} is not dereferenced (only references inside the schema " \
                    'document are resolved; network $ref resolution is disabled)'
      elsif resolve_pointer(root, ref).equal?(UNRESOLVED)
        problems << "unresolvable local $ref #{ref.inspect}"
      end
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
    # percent-encoding) within the root document.
    # @param root [Hash] the root schema (string keys)
    # @param ref [String] the `$ref` value
    # @return [Object] the referenced value, or UNRESOLVED
    def self.resolve_pointer(root, ref)
      fragment = ref.delete_prefix('#')
      fragment = URI.decode_www_form_component(fragment) rescue fragment # rubocop:disable Style/RescueModifier
      return root if fragment.empty?
      return UNRESOLVED unless fragment.start_with?('/')

      fragment[1..].split('/', -1).reduce(root) do |node, token|
        key = token.gsub('~1', '/').gsub('~0', '~')
        case node
        when Hash
          return UNRESOLVED unless node.key?(key)

          node[key]
        when Array
          return UNRESOLVED unless key.match?(/\A\d+\z/) && key.to_i < node.length

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
      collect_unsupported_keywords(schema, found)
      found.uniq
    end

    # Recursively collect unsupported keywords from a schema.
    # @param schema [Object] a (sub)schema; non-Hash values are ignored
    # @param found [Array<String>] accumulator
    # @return [void]
    def self.collect_unsupported_keywords(schema, found)
      return unless schema.is_a?(Hash)

      schema = schema.transform_keys(&:to_s)
      found.concat(schema.keys & UNSUPPORTED_KEYWORDS)
      schema.each do |keyword, value|
        if SUBSCHEMA_KEYWORDS.include?(keyword)
          collect_unsupported_keywords(value, found)
        elsif SUBSCHEMA_MAP_KEYWORDS.include?(keyword) && value.is_a?(Hash)
          value.each_value { |subschema| collect_unsupported_keywords(subschema, found) }
        elsif SUBSCHEMA_ARRAY_KEYWORDS.include?(keyword) && value.is_a?(Array)
          value.each { |subschema| collect_unsupported_keywords(subschema, found) }
        end
      end
    end

    # Validate data against a schema. An unusable schema (see
    # {.check_schema}) is reported as validation errors, never as a pass.
    # Schema and data hashes may use string or symbol keys.
    # @param data [Object] the value to validate
    # @param schema [Hash] the JSON schema
    # @param path [String] JSON-pointer-style location used in error messages
    # @param deadline [Float, nil] monotonic deadline for the whole validation
    # @return [Array<String>] human-readable validation errors (empty if valid)
    def self.validate(data, schema, path: '#', deadline: nil)
      problems = check_schema(schema)
      return problems.map { |problem| "#{path}: #{problem}" } unless problems.empty?

      # One deadline covers the entire (recursive) validation.
      deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + PATTERN_MATCH_TIMEOUT
      root = deep_stringify(schema)
      validate_node(data, root, path, Context.new(root: root, deadline: deadline), 0)
    end

    # Validate one value against one (sub)schema.
    # @param data [Object] the value
    # @param schema [Object] a subschema (Hash or boolean)
    # @param path [String] location for error messages
    # @param ctx [Context] the validation context
    # @param ref_depth [Integer] $ref hops taken to reach this schema
    # @return [Array<String>] validation errors
    def self.validate_node(data, schema, path, ctx, ref_depth)
      return [] if schema == true
      return ["#{path}: schema false accepts no value"] if schema == false
      return [] unless schema.is_a?(Hash)
      return ["#{path}: validation time budget exhausted"] if pattern_budget_remaining(ctx.deadline).zero?

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
      errors
    end

    # Apply a local $ref (2020-12: alongside the sibling keywords).
    # @return [Array<String>] validation errors
    def self.validate_ref(data, ref, path, ctx, ref_depth)
      return ["#{path}: external $ref #{ref.inspect} is not dereferenced"] if !ref.is_a?(String) || external_ref?(ref)
      if ref_depth >= MAX_REF_DEPTH
        return ["#{path}: $ref chain exceeds #{MAX_REF_DEPTH} hops (cycle?) at #{ref.inspect}"]
      end

      target = resolve_pointer(ctx.root, ref)
      return ["#{path}: unresolvable local $ref #{ref.inspect}"] if target.equal?(UNRESOLVED)

      validate_node(data, target, path, ctx, ref_depth + 1)
    end

    # allOf / anyOf / oneOf / not / if-then-else.
    # @return [Array<String>] validation errors
    def self.validate_composition(data, schema, path, ctx, ref_depth)
      errors = []
      if schema['allOf'].is_a?(Array)
        schema['allOf'].each_with_index do |sub, idx|
          sub_errors = validate_node(data, sub, path, ctx, ref_depth)
          errors << "#{path}: does not satisfy allOf/#{idx} (#{sub_errors.join('; ')})" unless sub_errors.empty?
        end
      end
      if schema['anyOf'].is_a?(Array) &&
         schema['anyOf'].none? { |sub| validate_node(data, sub, path, ctx, ref_depth).empty? }
        errors << "#{path}: does not satisfy any schema in anyOf"
      end
      if schema['oneOf'].is_a?(Array)
        matches = schema['oneOf'].count { |sub| validate_node(data, sub, path, ctx, ref_depth).empty? }
        errors << "#{path}: satisfies #{matches} schemas in oneOf, expected exactly one" unless matches == 1
      end
      if schema.key?('not') && validate_node(data, schema['not'], path, ctx, ref_depth).empty?
        errors << "#{path}: value satisfies the schema in not"
      end
      errors.concat(validate_conditional(data, schema, path, ctx, ref_depth))
      errors
    end

    # if / then / else.
    # @return [Array<String>] validation errors
    def self.validate_conditional(data, schema, path, ctx, ref_depth)
      return [] unless schema.key?('if')

      branch = validate_node(data, schema['if'], path, ctx, ref_depth).empty? ? 'then' : 'else'
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

      ["#{path}: expected type #{types.join(' or ')}, got #{json_type(data)}"]
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

    # Validate enum/const membership.
    # @param data [Object] the value
    # @param schema [Hash] string-keyed schema
    # @param path [String] location for error messages
    # @return [Array<String>] validation errors
    def self.validate_enum(data, schema, path)
      errors = []
      if schema['enum'].is_a?(Array) && !schema['enum'].include?(data)
        errors << "#{path}: value #{data.inspect} is not in enum #{schema['enum'].inspect}"
      end
      if schema.key?('const') && schema['const'] != data
        errors << "#{path}: value #{data.inspect} does not equal const #{schema['const'].inspect}"
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
        errors << "#{path}: missing required property '#{name}'" unless data.key?(name) || data.key?(name.to_sym)
      end
      properties = schema['properties']
      return errors unless properties.is_a?(Hash)

      properties.each do |raw_name, prop_schema|
        next unless prop_schema.is_a?(Hash) || [true, false].include?(prop_schema)

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

    # Validate an array against items/minItems/maxItems.
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
      if items.is_a?(Hash) || [true, false].include?(items)
        data.each_with_index do |item, idx|
          errors.concat(validate_node(item, items, "#{path}/#{idx}", ctx, ref_depth))
        end
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
    # calling thread. A match that exceeds the budget is reported as a
    # validation error rather than silently accepted — the value was never
    # shown to satisfy the schema.
    # @param data [String] the string
    # @param pattern [Object] the pattern keyword value
    # @param path [String] location for error messages
    # @param deadline [Float, nil] monotonic deadline for the whole validation
    # @return [Array<String>] validation errors
    def self.validate_pattern(data, pattern, path, deadline = nil)
      return [] unless pattern.is_a?(String)

      remaining = pattern_budget_remaining(deadline)
      return ["#{path}: pattern matching budget exhausted before #{pattern.inspect}"] if remaining.zero?

      return [] if data.match?(Regexp.new(pattern, timeout: remaining))

      ["#{path}: string does not match pattern #{pattern.inspect}"]
    rescue Regexp::TimeoutError
      ["#{path}: pattern #{pattern.inspect} exceeded the #{PATTERN_MATCH_TIMEOUT}s matching budget"]
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

    # A copy of the schema with every Hash key as a String, so keyword
    # lookups and JSON pointers see one key form. Values (enum members,
    # const, defaults) are left as they are.
    # @param node [Object]
    # @return [Object]
    def self.deep_stringify(node)
      case node
      when Hash then node.to_h { |key, value| [key.to_s, deep_stringify(value)] }
      when Array then node.map { |value| deep_stringify(value) }
      else node
      end
    end
  end
end
