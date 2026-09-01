# frozen_string_literal: true

require 'uri'

module MCPClient
  module SchemaValidator
    # Resolution of local `$ref` values: JSON pointer fragments (RFC 6901)
    # and plain-name fragments naming an anchor. Nothing here ever fetches:
    # a reference outside the document is reported as external. Extended
    # into SchemaValidator, so the methods are its own.
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
      # fragment naming an anchor.
      # @param root [Hash] the root schema (string keys)
      # @param ref [String] the `$ref` value
      # @param dialect [String, nil] the canonical dialect
      # @param resolver [Hash, Context] holder of the memoized anchor index
      # @return [Object] the referenced value, or UNRESOLVED
      def resolve_reference(root, ref, dialect, resolver)
        fragment = ref.delete_prefix('#')
        return resolve_pointer(root, ref) if fragment.empty? || fragment.start_with?('/', '%2F', '%2f')

        # A plain-name fragment is percent-decoded like a pointer fragment
        # (RFC 3986 Section 2.1): "#foo%2Dbar" names the anchor "foo-bar".
        fragment = URI.decode_uri_component(fragment) rescue fragment # rubocop:disable Style/RescueModifier
        return UNRESOLVED unless fragment.match?(ANCHOR_NAME)

        resolver[:anchors] ||= anchor_index(root, dialect)
        resolver[:anchors].fetch(fragment, UNRESOLVED)
      end

      # Every plain-name anchor in the document: `$anchor` (and
      # `$dynamicAnchor`) in 2019-09 / 2020-12, `$id: "#name"` in draft-07.
      # The walk is bounded like the preflight walk.
      # @return [Hash{String => Object}] name => subschema (first occurrence)
      def anchor_index(root, dialect)
        anchors = {}
        pending = [[root, 0]]
        visited = 0
        until pending.empty? || visited >= MAX_SUBSCHEMAS
          schema, depth = pending.shift
          next unless schema.is_a?(Hash) && depth <= MAX_SCHEMA_DEPTH

          visited += 1
          anchor_names(schema, dialect).each { |name| anchors[name] ||= schema }
          each_subschema(schema, dialect) { |sub| pending << [sub, depth + 1] }
        end
        anchors
      end

      # @return [Array<String>] the plain names a schema object declares
      def anchor_names(schema, dialect)
        names = if dialect == DRAFT_07
                  [schema['$id'].is_a?(String) ? schema['$id'].delete_prefix('#') : nil]
                else
                  %w[$anchor $dynamicAnchor].map { |k| schema[k] if keyword_known?(k, dialect) }
                end
        names.select { |name| name.is_a?(String) && name.match?(ANCHOR_NAME) }
      end

      # Resolve a fragment JSON pointer (`#`, `#/$defs/x`, `#/a~1b`, with
      # percent-encoding per RFC 6901 Section 6) within the root document.
      # @param root [Hash] the root schema (string keys)
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
