# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # What an input schema requires of every instance, read through the
    # applicators that apply unconditionally: the root, what its `$ref`
    # chain reaches, and each `allOf` member (each of those recursively).
    # The tools specification says clients SHOULD follow `$ref` resolution
    # when validating tool inputs, and SEP-2106 made `$ref` and `allOf` legal
    # on an inputSchema: a `required` behind them is as required as one at
    # the root. A branch the instance may or may not satisfy (`anyOf`,
    # `oneOf`, `if`) decides nothing here and is left to the server, which
    # MUST validate the arguments anyway. Extended into SchemaValidator, so
    # the methods are its own.
    module InputRequirements
      # @param schema [Object] the input schema (string or symbol keys)
      # @return [Array(Array<String>, Hash{String => Object})] the required
      #   property names, and the declared properties by name (a property
      #   declared nearer the root wins)
      def input_requirements(schema)
        root = normalize_schema(schema)
        return [[], {}] unless root.is_a?(Hash)

        declared = dialect(root)
        scan = { count: 0, dialect: declared && canonical_dialect(declared), anchors: nil,
                 walked: {}.compare_by_identity, required: [], properties: {}, pending: [root] }
        read_requirement_positions(root, scan)
        [scan[:required].uniq, scan[:properties]]
      rescue TooLarge
        # Unusable anyway: the preflight reports it.
        [[], {}]
      end

      # Read every queued position, bounded like the preflight walk.
      # @return [void]
      def read_requirement_positions(root, scan)
        until scan[:pending].empty?
          node = scan[:pending].pop
          next unless node.is_a?(Hash) && !scan[:walked].key?(node)

          scan[:walked][node] = true
          scan[:count] += 1
          return if scan[:count] > MAX_SUBSCHEMAS

          read_requirements(node, root, scan)
        end
      end

      # One position's requirements, and what it applies next. Under draft-07
      # nothing beside a `$ref` is applied (draft-07 Core Section 8.3).
      # @return [void]
      def read_requirements(node, root, scan)
        ref = node['$ref']
        queue_referenced(node, ref, root, scan) if ref.is_a?(String)
        return if scan[:dialect] == DRAFT_07 && node.key?('$ref')

        scan[:required].concat(node['required'].map(&:to_s)) if node['required'].is_a?(Array)
        scan[:properties] = node['properties'].merge(scan[:properties]) if node['properties'].is_a?(Hash)
        scan[:pending].concat(node['allOf'].reverse) if node['allOf'].is_a?(Array)
      end

      # Queue what a local reference reaches (an external one is never
      # dereferenced, and an unresolvable one is the preflight's to report).
      # @return [void]
      def queue_referenced(node, ref, root, scan)
        return if external_ref?(ref, root, scan[:dialect], scan, from: node)

        target = resolve_reference(root, ref, scan[:dialect], scan, from: node)
        scan[:pending] << target unless target.equal?(UNRESOLVED)
      end
    end
  end
end
