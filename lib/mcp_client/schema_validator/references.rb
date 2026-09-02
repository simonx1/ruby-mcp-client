# frozen_string_literal: true

require 'uri'

module MCPClient
  module SchemaValidator
    # Resolution of local `$ref` values: JSON pointer fragments (RFC 6901)
    # and plain-name fragments naming an anchor. Nothing here ever fetches:
    # a reference outside the document is reported as external. Extended
    # into SchemaValidator, so the methods are its own.
    #
    # Plain names are scoped to their schema resource (JSON Schema 2020-12
    # Core Sections 8.2.1 and 8.2.2): a subschema whose `$id` is a URI
    # starts a new resource, and `#name` names an anchor of the resource the
    # referencing schema belongs to — never one of an embedded resource, and
    # never one of the enclosing document from inside an embedded resource.
    module References
      # A reference that does not point inside this document: an absolute URI
      # (http, https, urn, file, ...), a relative document, or anything that
      # is not a bare fragment. None of these is ever fetched.
      # @param ref [String]
      # @return [Boolean]
      def external_ref?(ref)
        !ref.start_with?('#')
      end

      # Resolve a local reference: a JSON pointer fragment, or a plain-name
      # fragment naming an anchor. Both are relative to the schema resource
      # the referencing schema belongs to (JSON Schema 2020-12 Core Section
      # 8.2.1): inside an embedded resource `#` is that resource and
      # `#/$defs/x` its own definitions, never the enclosing document's.
      # @param root [Hash] the root schema (string keys)
      # @param ref [String] the `$ref` value
      # @param dialect [String, nil] the canonical dialect
      # @param resolver [Hash, Context] holder of the memoized anchor index
      # @param from [Hash, nil] the schema object holding the reference
      # @return [Object] the referenced value, or UNRESOLVED
      def resolve_reference(root, ref, dialect, resolver, from: nil)
        index = (resolver[:anchors] ||= anchor_index(root, dialect))
        # A referring schema the index never reached has no known resource:
        # resolving against the document root would apply the wrong `#`.
        return UNRESOLVED if from.is_a?(Hash) && !index[:resources].key?(from)

        resource = (from && index[:resources][from]) || root
        fragment = ref.delete_prefix('#')
        return resolve_pointer(resource, ref) if fragment.empty? || fragment.start_with?('/', '%2F', '%2f')

        # A plain-name fragment is percent-decoded like a pointer fragment
        # (RFC 3986 Section 2.1): "#foo%2Dbar" names the anchor "foo-bar".
        fragment = URI.decode_uri_component(fragment) rescue fragment # rubocop:disable Style/RescueModifier
        return UNRESOLVED unless fragment.match?(ANCHOR_NAME)

        index[:anchors].fetch(resource, {}).fetch(fragment, UNRESOLVED)
      end

      # Every plain-name anchor in the document, per schema resource:
      # `$anchor` (and `$dynamicAnchor`) in 2019-09 / 2020-12, `$id: "#name"`
      # in draft-07. The walk is bounded like the preflight walk and follows
      # the dialect of each resource (an embedded resource may declare its
      # own `$schema`). Identifiers are taken only from schema positions the
      # dialect walks (JSON Schema 2020-12 Core Sections 8.2.2 and 4.3.1: an
      # identifier belongs to a schema object, and the value of a keyword
      # the dialect does not define is not a schema): a definition bag the
      # dialect does not define stays reachable through JSON pointers, and
      # its objects are attributed to their lexical resource, but it is
      # never a source of names — nor is anything beside a draft-07 `$ref`
      # apart from its `definitions`.
      # @return [Hash] :resources (schema object => its resource root, by
      #   identity), :anchors (resource root => name => subschema, first
      #   occurrence, by identity), :dialects (resource root => dialect) and
      #   :duplicates (names declared more than once within one resource)
      def anchor_index(root, dialect)
        index = { resources: {}.compare_by_identity, anchors: {}.compare_by_identity,
                  dialects: {}.compare_by_identity, duplicates: [] }
        index[:dialects][root] = dialect
        pending = [[root, root, 0, dialect, true]]
        visited = 0
        index[:truncated] = false
        until pending.empty? || visited >= MAX_SUBSCHEMAS
          schema, resource, depth, dialect, named = pending.shift
          next unless schema.is_a?(Hash)
          next if index[:resources].key?(schema)
          # A schema below the depth bound is left unindexed just like one
          # beyond the visit bound: a reference from it (or an `$id` there)
          # would otherwise resolve under guesses.
          (index[:truncated] = true) && next if depth > MAX_SCHEMA_DEPTH

          visited += 1
          if resource_root?(schema, dialect)
            # A resource is a schema wherever it sits: one reached through
            # a bag the dialect does not walk names its own anchors, though
            # nothing outside it can see them.
            resource = schema
            dialect = embedded_dialect(schema, dialect) || dialect
            index[:dialects][resource] = dialect
            named = true
          end
          index[:resources][schema] = resource
          if named && !(dialect == DRAFT_07 && schema.key?('$ref'))
            record_anchor_names(index, resource, schema,
                                dialect)
          end
          each_walked_position(schema, dialect) { |sub| pending << [sub, resource, depth + 1, dialect, named] }
          each_foreign_definition(schema, dialect) { |sub| pending << [sub, resource, depth + 1, dialect, false] }
        end
        # Objects left unindexed at the bound would resolve and validate
        # under guesses; the index says so and the schema is unusable.
        index[:truncated] ||= pending.any? { |schema, *| schema.is_a?(Hash) && !index[:resources].key?(schema) }
        index
      end

      # Record the plain names a schema object declares for its resource; a
      # name already bound to another object of the same resource is a
      # duplicate (anchor names are unique within a resource).
      # @return [void]
      def record_anchor_names(index, resource, schema, dialect)
        names = (index[:anchors][resource] ||= {})
        anchor_names(schema, dialect).each do |name|
          index[:duplicates] << name if names.key?(name) && !names[name].equal?(schema)
          names[name] ||= schema
        end
      end

      # Yield the schema positions the dialect walks under a schema object:
      # under a draft-07 `$ref` only the `definitions` bag, else every
      # subschema (the dialect's definition bag included).
      # @return [void]
      def each_walked_position(schema, dialect, &)
        if dialect == DRAFT_07 && schema.key?('$ref')
          each_definition(schema, dialect, &)
        else
          each_subschema(schema, dialect, &)
        end
      end

      # The dialect the memoized anchor index recorded for a schema object's
      # resource, or nil when the object was not indexed.
      # @param schema [Hash]
      # @param resolver [Hash, Context] holder of the memoized anchor index
      # @return [String, nil]
      def indexed_dialect(schema, resolver)
        index = resolver[:anchors]
        return nil unless index

        resource = index[:resources][schema]
        resource && index[:dialects][resource]
      end

      # Whether a schema object starts a new schema resource: its `$id` is a
      # URI rather than a bare fragment (a draft-07 `$id: "#name"` is a
      # plain-name identifier, not a base).
      # @param schema [Hash]
      # @return [Boolean]
      def resource_start?(schema)
        id = schema['$id']
        id.is_a?(String) && !id.empty? && !id.start_with?('#')
      end

      # {#resource_start?} in the dialect in force: under draft-07 a `$ref`
      # replaces its whole schema object, `$id` and `$schema` included, so
      # nothing beside it starts a resource.
      # @param schema [Hash]
      # @param dialect [String, nil]
      # @return [Boolean]
      def resource_root?(schema, dialect)
        return false if dialect == DRAFT_07 && schema.key?('$ref')

        resource_start?(schema)
      end

      # @return [Array<String>] the plain names a schema object declares
      def anchor_names(schema, dialect)
        names = if dialect == DRAFT_07
                  # draft-07 Core Section 8.2.3: only an $id that is exactly a
                  # fragment is a plain-name identifier.
                  id = schema['$id']
                  [id.is_a?(String) && id.start_with?('#') ? id.delete_prefix('#') : nil]
                else
                  %w[$anchor $dynamicAnchor].map { |k| schema[k] if keyword_known?(k, dialect) }
                end
        names.select { |name| name.is_a?(String) && name.match?(ANCHOR_NAME) }
      end

      # The lexical nesting depth of every schema object reachable from the
      # root (subschema positions, definition bags of any dialect), so a
      # referenced target is bounded by where it is written, not by where it
      # is referenced from: neither member order nor reference fan-out can
      # change the verdict.
      # @return [Hash{Hash => Integer}] identity-keyed
      def lexical_depths(root, dialect)
        depths = {}.compare_by_identity
        pending = [[root, 0, dialect]]
        while (schema, depth, current = pending.shift)
          next unless schema.is_a?(Hash) && !depths.key?(schema)

          depths[schema] = depth
          break if depths.size > MAX_SUBSCHEMAS * 2

          # An embedded resource's positions follow its own dialect.
          current = embedded_dialect(schema, current) || current
          each_subschema(schema, current) { |sub| pending << [sub, depth + 1, current] }
          each_foreign_definition(schema, current) { |sub| pending << [sub, depth + 1, current] }
        end
        depths
      end

      # The lexical depth of the value a pointer reference reaches, counted
      # in schema steps along the (percent-decoded) pointer from its resource
      # root: a keyword holding one subschema is one step, a map or array of
      # subschemas is one step per member (`#/properties/b` and `#/allOf/0`
      # are both one below the enclosing schema), and every token under a
      # data or unknown keyword is a step, so a document hidden inside
      # `default`, `enum`, `const`, `examples` or a vendor keyword obeys the
      # same bound as one written in a schema position. A schema object whose
      # depth the lexical index knows resets the count to that depth.
      # @return [Integer, nil] nil when the pointer cannot be followed
      def referenced_position_depth(ref, root, dialect, counter, from)
        tokens = pointer_tokens(ref)
        return nil unless tokens

        index = (counter[:anchors] ||= anchor_index(root, dialect))
        node = (from && index[:resources][from]) || root
        depths = counter[:depths] || {}
        depth = depths[node] || 0
        mode = :schema
        tokens.each do |token|
          child = pointer_child(node, token)
          return nil if child.equal?(UNRESOLVED)

          if mode == :schema
            depth = depths[node] if node.is_a?(Hash) && depths.key?(node)
            mode = pointer_step_mode(node, token)
            depth += 1 unless %i[map array].include?(mode)
          else
            depth += 1
            mode = :schema if %i[map array].include?(mode)
          end
          node = child
        end
        depth
      end

      # The decoded RFC 6901 tokens of a fragment pointer.
      # @return [Array<String>, nil] nil unless the reference is a pointer
      def pointer_tokens(ref)
        fragment = ref.delete_prefix('#')
        fragment = URI.decode_uri_component(fragment) rescue fragment # rubocop:disable Style/RescueModifier
        return nil unless fragment.start_with?('/')

        fragment[1..].split('/', -1).map { |token| token.gsub('~1', '/').gsub('~0', '~') }
      end

      # @return [Object] the member a pointer token selects, or UNRESOLVED
      def pointer_child(node, token)
        case node
        when Hash then node.key?(token) ? node[token] : UNRESOLVED
        when Array then token.match?(/\A(0|[1-9]\d*)\z/) && token.to_i < node.length ? node[token.to_i] : UNRESOLVED
        else UNRESOLVED
        end
      end

      # How a keyword of a schema object holds what its pointer token reaches.
      # @return [Symbol] :schema (one subschema), :map, :array, or :opaque
      #   (data or unknown keyword: every token below is a step)
      def pointer_step_mode(node, token)
        return :opaque unless node.is_a?(Hash)
        return :map if SUBSCHEMA_MAP_KEYWORDS.include?(token)
        return :array if SUBSCHEMA_ARRAY_KEYWORDS.include?(token) || (token == 'items' && node[token].is_a?(Array))
        return :schema if SUBSCHEMA_KEYWORDS.include?(token)

        :opaque
      end

      # Yield the definitions held in the bag the dialect does not define
      # (`definitions` under 2019-09 / 2020-12, `$defs` under draft-07):
      # unknown to the dialect, but pointer-addressable all the same.
      # @return [void]
      def each_foreign_definition(schema, dialect, &block)
        %w[$defs definitions].each do |keyword|
          next if keyword_known?(keyword, dialect)

          schema[keyword].each_value(&block) if schema[keyword].is_a?(Hash)
        end
      end

      # Resolve a fragment JSON pointer (`#`, `#/$defs/x`, `#/a~1b`, with
      # percent-encoding per RFC 6901 Section 6) within a schema resource.
      # @param root [Hash] the resource root (string keys)
      # @param ref [String] the `$ref` value
      # @return [Object] the referenced value, or UNRESOLVED
      def resolve_pointer(root, ref)
        fragment = ref.delete_prefix('#')
        fragment = URI.decode_uri_component(fragment) rescue fragment # rubocop:disable Style/RescueModifier
        return root if fragment.empty?
        return UNRESOLVED unless fragment.start_with?('/')

        fragment[1..].split('/', -1).reduce(root) do |node, token|
          # RFC 6901 Section 3: "~" is only ever followed by "0" or "1".
          return UNRESOLVED if token.match?(/~(?![01])/)

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
    end
  end
end
