# frozen_string_literal: true

module MCPClient
  # Deep copies for the objects a transport hands out of its caches: a
  # caller may change what it received without changing what is cached.
  # Copies every instance variable but the transport reference (@server).
  module DeepCopy
    # @param value [Object] JSON-like data (hashes, arrays, strings, scalars)
    # @return [Object] a copy sharing no mutable structure with the input
    def self.copy(value)
      # Iterative: a peer-supplied document may be nested deeper than the
      # Ruby stack allows, and a copy must never be what overflows it.
      root = shallow_copy(value)
      pending = [[value, root]]
      until pending.empty?
        source, target = pending.pop
        case source
        when Hash then source.each { |k, v| pending << [v, target[shallow_copy(k)] = shallow_copy(v)] }
        when Array then source.each_with_index { |v, i| pending << [v, target[i] = shallow_copy(v)] }
        end
      end
      root
    end

    # @param value [Object]
    # @return [Object] an empty container for a hash or array, else the
    #   leaf copy {.copy} would have made
    def self.shallow_copy(value)
      case value
      when Hash then {}
      when Array then Array.new(value.size)
      when String then value.frozen? ? value : value.dup
      when DeepCopy then value.dup
      else value
      end
    end

    # @param source [Object] the object being copied
    # @return [void]
    def initialize_copy(source)
      super
      source.instance_variables.each do |ivar|
        next if ivar == :@server

        instance_variable_set(ivar, DeepCopy.copy(source.instance_variable_get(ivar)))
      end
    end
  end
end
