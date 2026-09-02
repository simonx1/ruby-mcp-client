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
        raw = ref.delete_prefix('#')
        return resolve_adopted_pointer(resource, ref, index) if raw.empty? || raw.start_with?('/', '%2F', '%2f')

        # A plain-name fragment is percent-decoded like a pointer fragment
        # (RFC 3986 Section 2.1): "#foo%2Dbar" names the anchor "foo-bar".
        fragment = decoded_fragment(ref)
        return UNRESOLVED unless fragment&.match?(ANCHOR_NAME)

        index[:anchors].fetch(resource, {}).fetch(fragment, UNRESOLVED)
      end

      # The decoded fragment of a reference (RFC 3986 Section 2.1), or nil
      # when what the peer wrote does not decode to readable text: escapes
      # that are not valid UTF-8 name nothing in this document, and reading
      # them must never raise out of the validation.
      # @param ref [String] the `$ref` value
      # @return [String, nil]
      def decoded_fragment(ref)
        fragment = ref.delete_prefix('#')
        decoded = URI.decode_uri_component(fragment) rescue fragment # rubocop:disable Style/RescueModifier
        decoded if decoded.valid_encoding?
      end

      # Resolve a JSON pointer within a schema resource, adopting on the way
      # whatever subtree the pointer enters through a data keyword (`default`
      # and the rest): that subtree is normalized and indexed once — memoized
      # by the identity of the object the document holds — and the remaining
      # tokens are walked through the copy. So every pointer into it lands on
      # the objects the index already knows, with the resource, dialect and
      # subschema charge it gave them: a nested pointer is not a second copy
      # attributed to the referrer (JSON Schema 2020-12 Core Sections 8.1.1
      # and 8.2.1: a schema belongs to the resource of its nearest `$id`
      # ancestor, wherever a reference reached it from).
      # @param resource [Hash] the resource root the pointer starts at
      # @param ref [String] the `$ref` value
      # @param index [Hash] the anchor index
      # @return [Object] the referenced value, or UNRESOLVED
      def resolve_adopted_pointer(resource, ref, index)
        fragment = decoded_fragment(ref)
        return UNRESOLVED unless fragment
        return adopt_reached_target(resource, resource, index) if fragment.empty?
        return UNRESOLVED unless fragment.start_with?('/')

        node = resource
        mode = :schema
        fragment[1..].split('/', -1).each do |token|
          # RFC 6901 Section 3: "~" is only ever followed by "0" or "1".
          return UNRESOLVED if token.match?(/~(?![01])/)

          node, resource, mode = adopt_step(node, resource, index, mode)
          token = token.gsub('~1', '/').gsub('~0', '~')
          child = pointer_child(node, token)
          return UNRESOLVED if child.equal?(UNRESOLVED)

          mode = member_mode(token, child, mode)
          node = child
        end
        adopt_reached_target(node, resource, index, raw: mode == :data)
      end

      # Adopt the object a pointer is about to step through when the document
      # holds it as data, and follow the resource the index attributes it to.
      # @return [Array(Object, Hash, Symbol)] the node to step through, the
      #   resource it belongs to, and the mode it is read in
      def adopt_step(node, resource, index, mode)
        return [node, resource, mode] unless node.is_a?(Hash)

        if mode == :data
          node = adopt_reached_target(node, resource, index, raw: true)
          mode = :schema
        end
        [node, index[:resources][node] || resource, mode]
      end

      # A schema a pointer reaches outside every indexed position (inside
      # `default`, another data keyword or a vendor member) is still part of
      # the resource it was reached from: it (and what it holds) is indexed
      # on arrival, so a `$ref` written anywhere in it resolves within that
      # resource and its nested schemas follow the dialect it adopts, and
      # what the document holds as data is normalized like everywhere else
      # (values are kept as given for equality; a subtree resolved as a
      # schema gets one string-keyed copy, memoized by identity).
      # @param raw [Boolean] whether the document holds the target as data,
      #   so it still needs its string-keyed copy
      # @return [Object] the target (or its normalized copy)
      def adopt_reached_target(target, resource, index, raw: false)
        return target unless target.is_a?(Hash)

        # Copied under the same structural budget as the root document,
        # whatever key form it arrived in (over the wire every key is a
        # string): a data keyword may not hide an unbounded map behind a
        # pointer.
        target = normalized_copy(target, index) if raw && !index[:resources].key?(target)
        # An indexed position was already walked, charged and attributed.
        return target if index[:resources].key?(target)

        # The adopted target is indexed like any schema position, so its own
        # `$id` / `$schema` and the positions below it are seen: within the
        # bounds the index already runs under. It declares no names of its
        # own — `resource_root?` turns naming on where an `$id` really starts
        # a resource — since a data keyword is not a schema position and an
        # `$anchor` written inside one names nothing in the document (Core
        # Sections 8.2.2 and 4.3.1).
        index_positions(index, [[target, resource, 0, index[:dialects][resource], false]])
        target
      end

      # The one string-keyed copy of a subtree the document holds as data,
      # memoized by the identity of the object it holds.
      # @return [Hash]
      def normalized_copy(target, index)
        copies = (index[:normalized] ||= {}.compare_by_identity)
        index[:budget] ||= { objects: 0, deadline: nil }
        copies[target] ||= deep_stringify(target, 0, index[:budget])
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
                  dialects: {}.compare_by_identity, duplicates: [], visited: 0, truncated: false }
        index[:dialects][root] = dialect
        index_positions(index, [[root, root, 0, dialect, true]])
        index
      end

      # Index every schema position reachable from the pending seeds, within
      # the visit and depth bounds the whole index runs under (an adopted
      # pointer target is seeded here too, so it shares them).
      # @param index [Hash] the index being built
      # @param pending [Array<Array>] seeds: schema, resource, depth,
      #   dialect, whether the position may declare names
      # @return [void]
      def index_positions(index, pending)
        until pending.empty? || index[:visited] >= MAX_SUBSCHEMAS
          schema, resource, depth, dialect, named = pending.shift
          next unless schema.is_a?(Hash)
          next if index[:resources].key?(schema)
          # A schema below the depth bound is left unindexed just like one
          # beyond the visit bound: a reference from it (or an `$id` there)
          # would otherwise resolve under guesses.
          (index[:truncated] = true) && next if depth > MAX_SCHEMA_DEPTH

          index[:visited] += 1
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
      # same bound as one written in a schema position. Keywords are
      # classified by the dialect in force at each node (an embedded
      # resource's own `$schema` takes over when the pointer enters it). A
      # schema object whose depth the lexical index knows resets the count
      # to that depth — unless the pointer already passed through an opaque
      # keyword, after which every token counts (the index placed such an
      # object under another dialect's grammar).
      # @return [Integer, nil] nil when the pointer cannot be followed
      def referenced_position_depth(ref, root, dialect, counter, from)
        pointer_position(ref, root, dialect, counter, from)&.first
      end

      # @return [Array(Integer, Boolean), nil] the depth and whether the
      #   pointer crossed an opaque keyword; nil when it cannot be followed
      def pointer_position(ref, root, dialect, counter, from)
        tokens = pointer_tokens(ref)
        return nil unless tokens

        index = (counter[:anchors] ||= anchor_index(root, dialect))
        node = (from && index[:resources][from]) || root
        depths = counter[:depths] || {}
        walk = { index: index, depths: depths, dialect: index[:dialects][node] || dialect,
                 depth: depths[node] || 0, mode: :schema, opaque: false, visited: true }
        tokens.each do |token|
          child = pointer_child(node, token)
          return nil if child.equal?(UNRESOLVED)

          pointer_step(walk, node, token)
          node = child
        end
        [walk[:depth], walk[:opaque], walk[:visited]]
      end

      # Advance one pointer token: in schema mode the node's own dialect
      # and known depth apply and the keyword decides how the next token
      # counts; inside a map or array keyword the member is the step;
      # under an opaque keyword every token is a step.
      # @return [void]
      def pointer_step(walk, node, token)
        unless walk[:mode] == :schema
          walk[:depth] += 1
          walk[:mode] = :schema if %i[map array].include?(walk[:mode])
          return
        end
        if node.is_a?(Hash)
          walk[:depth] = walk[:depths][node] if !walk[:opaque] && walk[:depths].key?(node)
          walk[:dialect] = walk[:index][:dialects][node] || embedded_dialect(node, walk[:dialect]) || walk[:dialect]
        end
        walk[:mode] = pointer_step_mode(node, token, walk[:dialect])
        walk[:opaque] ||= walk[:mode] == :opaque
        # The preflight walk does not descend into an opaque keyword, nor
        # into anything beside a draft-07 $ref but its definitions.
        walk[:visited] &&= walk[:mode] != :opaque &&
                           !(walk[:dialect] == DRAFT_07 && node.is_a?(Hash) && node.key?('$ref') &&
                             token != 'definitions')
        walk[:depth] += 1 unless %i[map array].include?(walk[:mode])
      end

      # The decoded RFC 6901 tokens of a fragment pointer.
      # @return [Array<String>, nil] nil unless the reference is a pointer
      def pointer_tokens(ref)
        fragment = decoded_fragment(ref)
        return nil unless fragment&.start_with?('/')

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
      # A keyword the dialect in force does not define (`prefixItems` under
      # draft-07, `additionalItems` under 2020-12) is opaque data there.
      def pointer_step_mode(node, token, dialect)
        return :opaque unless node.is_a?(Hash) && keyword_known?(token, dialect)
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
    end
  end
end
