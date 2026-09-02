# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # The bounded, string-keyed copy of a peer-supplied schema document.
    # Extended into SchemaValidator, so the methods are its own.
    module Normalization
      # A copy of the schema with every structural Hash key as a String, so
      # keyword lookups and JSON pointers see one key form. Data-carrying
      # keywords (enum, const, default, examples) are left exactly as given,
      # the walk stops at the nesting bound, and — given a budget — the copy
      # stops as soon as the document holds more structural elements (objects,
      # their entries and array members, boolean subschemas included) than
      # MAX_STRUCTURAL_OBJECTS, before the rest is ever read, or as soon as
      # the validation deadline has passed.
      # @param node [Object]
      # @param depth [Integer]
      # @param budget [Hash, nil] :objects copied so far, :deadline (optional)
      # @return [Object]
      # @raise [TooLarge] when the budget is exceeded, or the document is
      #   nested beyond what MAX_SCHEMA_DEPTH schema levels can hold (a
      #   subtree is never kept unread)
      # @raise [Aborted] when the deadline passed
      def deep_stringify(node, depth = 0, budget = nil)
        # Each schema level takes at most two document levels (a keyword map
        # or array, then the subschema), so a deeper document holds more
        # schema levels than the preflight walk admits.
        raise TooLarge, "schema nesting depth exceeds #{MAX_SCHEMA_DEPTH}" if depth > (MAX_SCHEMA_DEPTH * 2) + 2

        case node
        when Hash
          charge_structure(budget, node.size + 1)
          node.to_h do |key, value|
            name = key.to_s
            [name, DATA_KEYWORDS.include?(name) ? value : deep_stringify(value, depth + 1, budget)]
          end
        when Array
          charge_structure(budget, node.length + 1)
          node.map { |value| deep_stringify(value, depth + 1, budget) }
        else node
        end
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
