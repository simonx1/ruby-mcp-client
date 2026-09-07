# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # URI reference resolution (RFC 3986 Section 5), used to decide which
    # schema resource a `$ref` names. A JSON Schema document may bundle the
    # resources it uses (JSON Schema 2020-12 Core Section 9.3.1): a reference
    # written as an absolute URI, as a URI relative to the base an enclosing
    # `$id` established, or as the empty reference then names a resource the
    # document already carries, and resolving it needs no retrieval. Nothing
    # here fetches or normalizes anything beyond what RFC 3986 defines, and
    # nothing here raises: a reference a peer wrote that cannot be parsed
    # simply names no local resource. Extended into SchemaValidator, so the
    # methods are its own.
    module UriReferences
      # RFC 3986 Appendix B: the components of a URI reference.
      URI_REFERENCE = %r{
        \A
        (?:(?<scheme>[A-Za-z][A-Za-z0-9+\-.]*):)?
        (?://(?<authority>[^/?\#]*))?
        (?<path>[^?\#]*)
        (?:\?(?<query>[^\#]*))?
        (?:\#(?<fragment>.*))?
        \z
      }mx

      # Resolve a URI reference against a base URI (RFC 3986 Section 5.2.2),
      # dropping the fragment: what comes back identifies a resource, which
      # is what an `$id` declares and what a `$ref` selects before its
      # fragment is applied.
      # @param base [String] the base URI (may be empty when the document
      #   declares none: relative references still resolve consistently
      #   against each other)
      # @param ref [String] the reference to resolve
      # @return [String, nil] nil when either side is not a URI reference
      def merge_uri(base, ref)
        target = parse_uri_reference(ref)
        origin = parse_uri_reference(base)
        return nil unless target && origin
        return merge_relative_uri(origin, target) unless target[:scheme]

        compose_uri(target[:scheme], target[:authority], remove_dot_segments(target[:path]), target[:query])
      end

      # The RFC 3986 Section 5.2.2 branches for a reference without a scheme.
      # @param origin [Hash] the parsed base URI
      # @param target [Hash] the parsed reference
      # @return [String]
      def merge_relative_uri(origin, target)
        if target[:authority]
          compose_uri(origin[:scheme], target[:authority], remove_dot_segments(target[:path]), target[:query])
        elsif target[:path].empty?
          compose_uri(origin[:scheme], origin[:authority], origin[:path], target[:query] || origin[:query])
        elsif target[:path].start_with?('/')
          compose_uri(origin[:scheme], origin[:authority], remove_dot_segments(target[:path]), target[:query])
        else
          path = remove_dot_segments(merge_paths(origin, target[:path]))
          compose_uri(origin[:scheme], origin[:authority], path, target[:query])
        end
      end

      # @param uri [String]
      # @return [Hash, nil] :scheme, :authority, :query (each String or nil)
      #   and :path (always a String); nil when the text is not a URI
      #   reference (or is not readable text at all)
      def parse_uri_reference(uri)
        return nil unless uri.is_a?(String)

        match = URI_REFERENCE.match(uri)
        return nil unless match

        # A scheme is case-insensitive (RFC 3986 Section 3.1), so two
        # spellings of one resource identify the same one.
        { scheme: match[:scheme]&.downcase, authority: match[:authority], path: match[:path].to_s,
          query: match[:query] }
      rescue ArgumentError
        nil
      end

      # RFC 3986 Section 5.3.
      # @return [String]
      def compose_uri(scheme, authority, path, query)
        composed = +''
        composed << "#{scheme}:" if scheme
        composed << "//#{authority}" if authority
        composed << path
        composed << "?#{query}" if query
        composed
      end

      # RFC 3986 Section 5.2.3: a relative path is merged onto the base's.
      # @param origin [Hash] the parsed base URI
      # @param path [String] the reference's relative path
      # @return [String]
      def merge_paths(origin, path)
        return "/#{path}" if origin[:authority] && origin[:path].empty?

        "#{origin[:path].sub(%r{[^/]*\z}, '')}#{path}"
      end

      # RFC 3986 Section 5.2.4.
      # @param path [String]
      # @return [String]
      def remove_dot_segments(path)
        input = path
        output = []
        until input.empty?
          stripped = strip_leading_dots(input)
          unless stripped.equal?(input)
            input = stripped
            next
          end

          stepped = dot_segment_step(input, output)
          if stepped
            input = stepped
            next
          end

          segment = input[%r{\A/?[^/]*}]
          output << segment
          input = input[segment.length..]
        end
        output.join
      end

      # The RFC 3986 Section 5.2.4 A and B prefixes, which are simply dropped.
      # @return [String] the input itself when neither applies
      def strip_leading_dots(input)
        return input.sub(%r{\A\.\.?/}, '') if input.start_with?('../', './')
        return '' if ['.', '..'].include?(input)

        input
      end

      # The RFC 3986 Section 5.2.4 C and D prefixes, which also pop an
      # already-emitted segment for "..".
      # @return [String, false] the remaining input, or false when the
      #   prefix does not apply
      def dot_segment_step(input, output)
        return "/#{input[3..]}" if input.start_with?('/./')
        return '/' if input == '/.'

        if input.start_with?('/../') || input == '/..'
          output.pop
          return input == '/..' ? '/' : "/#{input[4..]}"
        end

        false
      end
    end
  end
end
