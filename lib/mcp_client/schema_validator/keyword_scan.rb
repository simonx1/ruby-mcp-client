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
        canonical = declared && canonical_dialect(declared)
        scan = { count: 0, dialect: canonical, walked: {}.compare_by_identity, anchors: nil,
                 pending: [[root, 0, canonical]] }
        scan_positions(root, found, scan)
        found.uniq
      rescue TooLarge
        # Unusable anyway: check_schema reports it.
        found.uniq
      end

      # Read every queued position. Like the preflight walk, the scan runs on
      # a stack of its own rather than on the interpreter's: a shallow
      # document whose `$ref`s chain through hundreds of schemas is walked in
      # constant stack space, so scanning one cannot overflow the thread a
      # transport reads on.
      # @return [void]
      def scan_positions(root, found, scan)
        until scan[:pending].empty?
          schema, depth, dialect = scan[:pending].pop
          scan_position(schema, root, found, depth, scan, dialect)
        end
      end

      # Collect the unsupported keywords one schema position uses (keywords
      # the dialect does not define are unknown, not unsupported) and queue
      # what it leads to. What a local `$ref` applies is scanned too, wherever
      # it lives (a definition bag the dialect does not walk included); each
      # object is scanned once.
      # @param schema [Object] a (sub)schema; non-Hash values are ignored
      # @param root [Hash] the normalized root schema
      # @param found [Array<String>] accumulator
      # @param scan [Hash] :count of subschemas seen so far, the canonical
      #   :dialect, the :walked objects, the memoized :anchors index and the
      #   :pending positions
      # @return [void]
      def scan_position(schema, root, found, depth, scan, dialect = scan[:dialect])
        return unless schema.is_a?(Hash) && depth <= MAX_SCHEMA_DEPTH
        return if scan[:walked].key?(schema)

        scan[:walked][schema] = true
        scan[:count] += 1
        return if scan[:count] > MAX_SUBSCHEMAS

        # An embedded resource declaring its own $schema is scanned under it.
        dialect = embedded_dialect(schema, dialect) || dialect
        referenced = referenced_position(schema, root, depth, scan, dialect) if schema['$ref'].is_a?(String)
        if dialect == DRAFT_07 && schema.key?('$ref')
          # Nothing beside the $ref is applied; the definitions stay reachable.
          return queue_scan(scan, schema, depth, dialect, referenced, :each_definition)
        end

        found.concat((schema.keys & UNSUPPORTED_KEYWORDS).select { |k| keyword_known?(k, dialect) })
        queue_scan(scan, schema, depth, dialect, referenced, :each_subschema)
      end

      # Queue the positions under a schema object (in document order, the
      # stack being read from its end), then what its reference reaches.
      # @param walker [Symbol] :each_subschema or :each_definition
      # @return [void]
      def queue_scan(scan, schema, depth, dialect, referenced, walker)
        positions = []
        send(walker, schema, dialect) { |sub| positions << [sub, depth + 1, dialect] }
        scan[:pending].concat(positions.reverse)
        scan[:pending] << referenced if referenced
      end

      # The position what a local `$ref` applies is scanned at (unresolvable
      # or external references are the preflight's business).
      # @return [Array, nil]
      def referenced_position(schema, root, depth, scan, dialect)
        ref = schema['$ref']
        return nil if external_ref?(ref, root, scan[:dialect], scan, from: schema)

        target = resolve_reference(root, ref, scan[:dialect], scan, from: schema)
        return nil if target.equal?(UNRESOLVED)

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
        [target, target_depth, (target.is_a?(Hash) && indexed_dialect(target, scan)) || dialect]
      end
    end
  end
end
