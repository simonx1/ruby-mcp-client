# frozen_string_literal: true

module MCPClient
  # Deep copies for the objects a transport hands out of its caches: a
  # caller may change what it received without changing what is cached.
  # Copies every instance variable but the transport reference (@server).
  module DeepCopy
    # @param value [Object] JSON-like data (hashes, arrays, strings, scalars)
    # @return [Object] a copy sharing no mutable structure with the input
    def self.copy(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), h| h[copy(k)] = copy(v) }
      when Array then value.map { |v| copy(v) }
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
