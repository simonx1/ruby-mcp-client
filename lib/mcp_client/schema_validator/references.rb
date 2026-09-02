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
      # in draft-07. The walk is bounded like the preflight walk. Both
      # definition bags are walked whatever the dialect: they are reachable
      # through JSON pointers, and an anchor's resource is lexical.
      # @return [Hash] :resources (schema object => its resource root, by
      #   identity) and :anchors (resource root => name => subschema, first
      #   occurrence, by identity)
      def anchor_index(root, dialect)
        index = { resources: {}.compare_by_identity, anchors: {}.compare_by_identity }
        pending = [[root, root, 0]]
        visited = 0
        until pending.empty? || visited >= MAX_SUBSCHEMAS
          schema, resource, depth = pending.shift
          next unless schema.is_a?(Hash) && depth <= MAX_SCHEMA_DEPTH

          visited += 1
          # draft-07: everything beside a $ref is ignored, identifiers
          # included; only the definitions bag stays reachable.
          if dialect == DRAFT_07 && schema.key?('$ref')
            index[:resources][schema] = resource
            each_definition(schema, nil) { |sub| pending << [sub, resource, depth + 1] }
            next
          end

          resource = schema if resource_start?(schema)
          index[:resources][schema] = resource
          names = (index[:anchors][resource] ||= {})
          anchor_names(schema, dialect).each { |name| names[name] ||= schema }
          each_subschema(schema, dialect) { |sub| pending << [sub, resource, depth + 1] }
          each_foreign_definition(schema, dialect) { |sub| pending << [sub, resource, depth + 1] }
        end
        index
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
