# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # The bounded scan for keywords the validator does not evaluate, so the
    # client can say when its validation is only partial. Extended into
    # SchemaValidator, so the methods are its own.
    module KeywordScan
      # List the unsupported JSON Schema keywords a schema uses (anywhere: at the
      # top level or nested in subschemas). Property names that merely look like
      # keywords (e.g. a property called 'not') are not reported, and
      # data-carrying keywords (enum/const/default/examples) are not scanned.
      # The scan stops at the same bounds as {.check_schema} (a schema beyond
      # them is unusable anyway), so a huge server-supplied schema is never
      # walked whole.
      # @param schema [Object] the JSON schema (string or symbol keys)
      # @return [Array<String>] unique unsupported keywords, in discovery order
      def unsupported_keywords(schema)
        found = []
        root = normalize_schema(schema)
        declared = dialect(root)
        scan = { count: 0, dialect: declared && canonical_dialect(declared), walked: {}.compare_by_identity,
                 anchors: nil }
        collect_unsupported_keywords(root, root, found, 0, scan)
        found.uniq
      rescue TooLarge
        # Unusable anyway: check_schema reports it.
        found.uniq
      end

      # Recursively collect unsupported keywords from a schema (keywords the
      # dialect does not define are unknown, not unsupported). What a local
      # `$ref` applies is scanned too, wherever it lives (a definition bag the
      # dialect does not walk included); each object is scanned once.
      # @param schema [Object] a (sub)schema; non-Hash values are ignored
      # @param root [Hash] the normalized root schema
      # @param found [Array<String>] accumulator
      # @param scan [Hash] :count of subschemas seen so far, the canonical
      #   :dialect, the :walked objects and the memoized :anchors index
      # @return [void]
      def collect_unsupported_keywords(schema, root, found, depth, scan, dialect = scan[:dialect])
        return unless schema.is_a?(Hash) && depth <= MAX_SCHEMA_DEPTH
        return if scan[:walked].key?(schema)

        scan[:walked][schema] = true
        scan[:count] += 1
        return if scan[:count] > MAX_SUBSCHEMAS

        # An embedded resource declaring its own $schema is scanned under it.
        dialect = embedded_dialect(schema, dialect) || dialect
        collect_referenced_keywords(schema, root, found, depth, scan, dialect) if schema['$ref'].is_a?(String)
        if dialect == DRAFT_07 && schema.key?('$ref')
          # Nothing beside the $ref is applied; the definitions stay reachable.
          each_definition(schema, dialect) do |sub|
            collect_unsupported_keywords(sub, root, found, depth + 1, scan, dialect)
          end
          return
        end

        found.concat((schema.keys & UNSUPPORTED_KEYWORDS).select { |k| keyword_known?(k, dialect) })
        each_subschema(schema, dialect) do |sub|
          collect_unsupported_keywords(sub, root, found, depth + 1, scan, dialect)
        end
      end

      # Scan what a local `$ref` applies (unresolvable or external references
      # are the preflight's business).
      # @return [void]
      def collect_referenced_keywords(schema, root, found, depth, scan, dialect)
        ref = schema['$ref']
        return if external_ref?(ref)

        target = resolve_reference(root, ref, scan[:dialect], scan, from: schema)
        return if target.equal?(UNRESOLVED)

        # What a reference reaches is scanned under its own resource's dialect
        # and at its own lexical depth, so member order and reference fan-out
        # cannot hide its keywords. A target that is not a schema object has
        # no lexical depth at all — nil, never `false`, so the depth the
        # opaque-pointer branch compares stays a number.
        scan[:depths] ||= lexical_depths(root, scan[:dialect])
        lexical = scan[:depths][target] if target.is_a?(Hash)
        position, opaque = pointer_position(ref, root, scan[:dialect], scan, schema)
        target_depth = if opaque
                         [position, lexical].compact.max || (depth + 1)
                       else
                         lexical || position || (depth + 1)
                       end
        collect_unsupported_keywords(target, root, found, target_depth, scan,
                                     (target.is_a?(Hash) && indexed_dialect(target, scan)) || dialect)
      end
    end
  end
end
