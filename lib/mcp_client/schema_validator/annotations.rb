# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # What the schemas applied to one instance value evaluated of it: the
    # annotation results `unevaluatedProperties` and `unevaluatedItems` read
    # (JSON Schema 2020-12 Core Sections 11.2 and 11.3). One is kept per
    # application of a schema to an object or an array, filled in by the
    # keywords the node evaluates itself (`properties`, `patternProperties`,
    # `additionalProperties`, `prefixItems`, `items`, `contains` and the two
    # keywords themselves) and merged from every in-place applicator whose
    # subschema passed — a failed subschema annotates nothing, and a cousin
    # (a sibling branch of the same composition) never sees it.
    class Evaluated
      def initialize
        @all = false
        @names = {}
        @prefix = 0
        @indices = {}
      end

      # @return [Boolean] whether every member or item was evaluated
      def all?
        @all
      end

      # Every member or item is evaluated (an `items` schema, an
      # `additionalProperties` schema, or the unevaluated keyword itself).
      # @return [void]
      def all!
        @all = true
      end

      # @param name [Object] a property name (either key form)
      # @return [void]
      def name!(name)
        @names[name.to_s] = true unless @all
      end

      # @param count [Integer] how many leading items a tuple evaluated
      # @return [void]
      def prefix!(count)
        @prefix = count if count > @prefix
      end

      # @param index [Integer] an item `contains` matched
      # @return [void]
      def index!(index)
        @indices[index] = true unless @all
      end

      # @param name [Object] a property name (either key form)
      # @return [Boolean] whether the member was evaluated
      def property?(name)
        @all || @names.key?(name.to_s)
      end

      # @param index [Integer]
      # @return [Boolean] whether the item was evaluated
      def item?(index)
        @all || index < @prefix || @indices.key?(index)
      end

      # Take over what a passed subschema evaluated of the same value.
      # @param other [Evaluated, nil]
      # @return [Evaluated] self
      def merge!(other)
        return self if other.nil?
        return all! || self if other.all?

        @names.merge!(other.names)
        @prefix = other.prefix if other.prefix > @prefix
        @indices.merge!(other.indices)
        self
      end

      protected

      attr_reader :names, :prefix, :indices
    end
  end
end
