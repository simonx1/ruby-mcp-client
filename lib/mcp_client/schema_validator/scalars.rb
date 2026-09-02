# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # The string and number keywords, and the budget a peer-supplied pattern
    # is matched under. Both a pattern and the values it runs against come
    # from the remote peer, so matching is bounded by the validation-wide
    # deadline. Extended into SchemaValidator, so the methods are its own.
    module Scalars
      # Validate a string against minLength/maxLength/pattern.
      # @param data [String] the string
      # @param schema [Hash] string-keyed schema
      # @param path [String] location for error messages
      # @return [Array<String>] validation errors
      def validate_string(data, schema, path, deadline = nil)
        errors = []
        min_length = schema['minLength']
        max_length = schema['maxLength']
        if min_length.is_a?(Numeric) && data.length < min_length
          errors << "#{path}: string is shorter than minLength #{min_length}"
        end
        if max_length.is_a?(Numeric) && data.length > max_length
          errors << "#{path}: string is longer than maxLength #{max_length}"
        end
        errors.concat(validate_pattern(data, schema['pattern'], path, deadline))
        errors
      end

      # Validate a string against a regular-expression pattern.
      # Invalid patterns are not enforced.
      #
      # The pattern comes from the tool's outputSchema, i.e. from the remote
      # server, so matching runs against the validation-wide deadline: neither a
      # single expensive expression nor many cheap-looking ones can pin the
      # calling thread. A match that exceeds the budget aborts the validation
      # rather than silently accepting the value — the value was never shown
      # to satisfy the schema.
      # @param data [String] the string
      # @param pattern [Object] the pattern keyword value
      # @param path [String] location for error messages
      # @param deadline [Float, nil] monotonic deadline for the whole validation
      # @return [Array<String>] validation errors
      # @raise [Aborted] when the budget is exhausted
      def validate_pattern(data, pattern, path, deadline = nil)
        return [] unless pattern.is_a?(String)

        remaining = pattern_budget_remaining(deadline)
        raise Aborted, "validation time budget exhausted before pattern #{clip(pattern.inspect)}" if remaining.zero?

        return [] if data.match?(Regexp.new(pattern, timeout: remaining))

        ["#{path}: string does not match pattern #{clip(pattern.inspect)}"]
      rescue Regexp::TimeoutError
        raise Aborted, "pattern #{clip(pattern.inspect)} exceeded the #{PATTERN_MATCH_TIMEOUT}s matching budget"
      rescue RegexpError
        []
      end

      # Time left in the validation-wide budget.
      # @param deadline [Float, nil] monotonic deadline, or nil for a lone match
      # @return [Float] seconds available; 0.0 when exhausted
      def pattern_budget_remaining(deadline)
        return PATTERN_MATCH_TIMEOUT unless deadline

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return 0.0 if remaining <= 0

        [remaining, MIN_PATTERN_MATCH_TIMEOUT].max
      end

      # Validate a number against its bounds. `minimum` / `maximum` and
      # `exclusiveMinimum` / `exclusiveMaximum` are four independent numeric
      # assertions in every supported dialect (draft-07 validation Sections
      # 6.2.2-6.2.5); each present one is applied.
      # @param data [Numeric] the number
      # @param schema [Hash] string-keyed schema
      # @param path [String] location for error messages
      # @return [Array<String>] validation errors
      def validate_number(data, schema, path, _dialect = nil)
        errors = []
        minimum = schema['minimum']
        maximum = schema['maximum']
        exclusive_min = schema['exclusiveMinimum']
        exclusive_max = schema['exclusiveMaximum']
        shown = clip_value(data)
        if minimum.is_a?(Numeric) && data < minimum
          errors << "#{path}: value #{shown} is less than minimum #{clip_value(minimum)}"
        end
        if maximum.is_a?(Numeric) && data > maximum
          errors << "#{path}: value #{shown} is greater than maximum #{clip_value(maximum)}"
        end
        if exclusive_min.is_a?(Numeric) && data <= exclusive_min
          errors << "#{path}: value #{shown} must be greater than exclusiveMinimum #{clip_value(exclusive_min)}"
        end
        if exclusive_max.is_a?(Numeric) && data >= exclusive_max
          errors << "#{path}: value #{shown} must be less than exclusiveMaximum #{clip_value(exclusive_max)}"
        end
        errors
      end
    end
  end
end
