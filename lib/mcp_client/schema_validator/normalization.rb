# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # The bounded, string-keyed copy of a peer-supplied schema document.
    # Extended into SchemaValidator, so the methods are its own.
    module Normalization
      # A copy of the schema with every structural Hash key as a String, so
      # keyword lookups and JSON pointers see one key form. The value of a
      # data-carrying keyword (enum, const, default, examples) of a schema
      # object is left exactly as given, the walk stops at the nesting bound,
      # and — given a budget — the copy stops as soon as the document holds
      # more structural elements (objects, their entries and array members,
      # boolean subschemas included) than MAX_STRUCTURAL_OBJECTS, before the
      # rest is ever read, or as soon as the validation deadline has passed.
      # @param node [Object]
      # @param depth [Integer]
      # @param budget [Hash, nil] :objects copied so far, :deadline (optional)
      # @param mode [Symbol] how this position is read ({#member_mode})
      # @return [Object]
      # @raise [TooLarge] when the budget is exceeded, or the document is
      #   nested beyond what MAX_SCHEMA_DEPTH schema levels can hold (a
      #   subtree is never kept unread)
      # @raise [Aborted] when the deadline passed
      def deep_stringify(node, depth = 0, budget = nil, mode = :schema)
        # Each schema level takes at most two document levels (a keyword map
        # or array, then the subschema), so a deeper document holds more
        # schema levels than the preflight walk admits.
        raise TooLarge, "schema nesting depth exceeds #{MAX_SCHEMA_DEPTH}" if depth > (MAX_SCHEMA_DEPTH * 2) + 2

        case node
        when Hash
          charge_structure(budget, node.size + 1)
          node.to_h do |key, value|
            name = key.to_s
            [name, stringify_member(name, value, depth, budget, mode)]
          end
        when Array
          charge_structure(budget, node.length + 1)
          node.map.with_index do |value, idx|
            deep_stringify(value, depth + 1, budget, member_mode(idx.to_s, value, mode))
          end
        else node
        end
      end

      # The copy of one member: what a schema object holds under a data
      # keyword is kept as given (its key form is the instance's, and it is
      # compared for equality as written), everything else is copied in the
      # mode its position implies.
      # @return [Object]
      def stringify_member(name, value, depth, budget, mode)
        member = member_mode(name, value, mode)
        return value if member == :data

        deep_stringify(value, depth + 1, budget, member)
      end

      # How the member a name selects is read: :data (a data keyword of a
      # schema object, kept as given), :list (a map or array of subschemas),
      # :schema, or :plain (anything else — copied, never read as a schema).
      # Only a schema object has keywords: a property, definition or pattern
      # named `enum`, `const`, `default` or `examples` is a schema position
      # like any other (JSON Schema 2020-12 Core Section 4.3.1), and so is
      # everything under a keyword no dialect defines.
      # @return [Symbol]
      def member_mode(name, value, mode)
        return :data if mode == :data
        return :schema if mode == :list
        return :plain unless mode == :schema
        return :data if DATA_KEYWORDS.include?(name)
        return :list if list_member?(name, value)

        SUBSCHEMA_KEYWORDS.include?(name) ? :schema : :plain
      end

      # @return [Boolean] whether a keyword holds a map or array of
      #   subschemas in the form it was written (draft-07 / 2019-09 read an
      #   `items` array positionally)
      def list_member?(name, value)
        (SUBSCHEMA_MAP_KEYWORDS.include?(name) && value.is_a?(Hash)) ||
          ((SUBSCHEMA_ARRAY_KEYWORDS.include?(name) || name == 'items') && value.is_a?(Array))
      end

      # Account for structural elements about to be copied.
      # @raise [TooLarge] when the budget is exceeded
      # @raise [Aborted] when the deadline passed
      def charge_structure(budget, count)
        return unless budget

        budget[:objects] += count
        if budget[:objects] > MAX_STRUCTURAL_OBJECTS
          raise TooLarge,
                "schema has more than #{MAX_STRUCTURAL_OBJECTS} structural elements"
        end

        deadline = budget[:deadline]
        return unless deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        raise Aborted, 'time budget exhausted while reading the schema'
      end
    end
  end
end
