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

        return [] if data.match?(ecma_regexp(pattern, remaining))

        ["#{path}: string does not match pattern #{clip(pattern.inspect)}"]
      rescue Regexp::TimeoutError
        raise Aborted, "pattern #{clip(pattern.inspect)} exceeded the #{PATTERN_MATCH_TIMEOUT}s matching budget"
      rescue RegexpError
        []
      end

      # A `pattern` compiled with ECMAScript's semantics. JSON Schema
      # 2020-12 Core Section 4.3 requires patterns to be interpreted as
      # ECMA-262 regular expressions, and Ruby's differ from them in both
      # directions: what Ruby accepts that ECMAScript rejects makes the
      # validator accept a value the schema refuses, and the converse
      # rejects a conforming one (and, through `not` or
      # `additionalProperties: false`, flips both).
      # @param pattern [String] the peer's pattern
      # @param timeout [Float] seconds the match may take
      # @return [Regexp]
      # @raise [RegexpError] when the pattern is not a usable expression
      def ecma_regexp(pattern, timeout)
        Regexp.new(ecma_source(pattern), timeout: timeout)
      end

      # What each ECMA-262 anchor means in Ruby: the ends of the subject,
      # never a line boundary.
      ECMA_ANCHORS = { '^' => '\\A', '$' => '\\z' }.freeze

      # ECMA-262 `.` matches every character except the four line
      # terminators; Ruby's excludes only "\n".
      ECMA_DOT = '[^\\n\\r\\u2028\\u2029]'

      # The members of ECMA-262's `\s` (WhiteSpace plus LineTerminator):
      # Ruby's is `[ \t\r\n\f\v]` and knows none of the Unicode spaces, so a
      # non-breaking space failed a pattern ECMAScript satisfies.
      ECMA_SPACE_MEMBERS = '\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff'

      # A character class matching nothing, which is what ECMA-262 makes of
      # `[]` — Ruby cannot compile that at all, so the pattern used to be
      # dropped and every string satisfied it.
      ECMA_EMPTY_CLASS = '[^\\s\\S]'

      # Its complement: ECMA-262 `[^]` matches any character, line
      # terminators included.
      ECMA_ANY_CLASS = '[\\s\\S]'

      # The escapes ECMA-262 defines, which Ruby reads the same way:
      # the class escapes, the assertions, the control escapes, a hex,
      # Unicode or control-letter escape, a named back-reference, a Unicode
      # property, and the numeric back-references. `\s` / `\S` are defined
      # by both but over different sets, so they are rewritten rather than
      # kept.
      ECMA_KEPT_ESCAPES = 'bBdDwWfnrtv0123456789xuckpP'

      # Rewrite an ECMA-262 pattern as the Ruby expression that means the
      # same thing. Everything ECMA-262 defines is kept; what only Ruby
      # defines is read the way ECMA-262 reads it — an escape ECMA-262 does
      # not define is an identity escape there (Annex B.1.2), so `\A` is a
      # literal "A" and not the start of the subject.
      # @param pattern [String] the peer's pattern
      # @return [String] Ruby regexp source
      def ecma_source(pattern)
        out = +''
        index = 0
        while index < pattern.length
          index = if pattern[index] == '['
                    copy_character_class(pattern, index, out)
                  else
                    copy_ecma_token(pattern, index, out)
                  end
        end
        out
      end

      # Copy one token from outside a character class.
      # @return [Integer] the index the scan continues at
      def copy_ecma_token(pattern, index, out)
        char = pattern[index]
        if char == '\\'
          out << ecma_escape(pattern[index + 1], in_class: false)
          return index + 2
        end

        out << (ECMA_ANCHORS[char] || (char == '.' ? ECMA_DOT : char))
        index + 1
      end

      # One escape sequence's Ruby spelling. An escape ECMA-262 leaves
      # undefined is an identity escape: the character itself.
      # @param char [String, nil] what followed the backslash
      # @param in_class [Boolean] whether the escape sits in a character class
      # @return [String]
      def ecma_escape(char, in_class:)
        # A trailing backslash is no expression in either dialect; Ruby says so.
        return '\\' if char.nil?
        return in_class ? ECMA_SPACE_MEMBERS : "[#{ECMA_SPACE_MEMBERS}]" if char == 's'
        # Inside a class Ruby reads the nested one as a union, which is
        # what a member set complement means there.
        return "[^#{ECMA_SPACE_MEMBERS}]" if char == 'S'
        # `\B` asserts outside a class and is an identity escape inside one.
        return 'B' if in_class && char == 'B'
        return "\\#{char}" if ECMA_KEPT_ESCAPES.include?(char)

        # An identity escape: a letter stands for itself, and punctuation
        # keeps the backslash (which means the same in both dialects).
        char.match?(/[A-Za-z]/) ? char : "\\#{char}"
      end

      # Copy a character class, which ECMA-262 and Ruby read differently: an
      # empty class is legal there and matches nothing, and `[` and `&`
      # inside a class are literals rather than the openers of Ruby's nested
      # classes and set intersection.
      # @param index [Integer] the index of the opening bracket
      # @return [Integer] the index the scan continues at
      def copy_character_class(pattern, index, out)
        negated = pattern[index + 1] == '^'
        body = +''
        cursor = index + (negated ? 2 : 1)
        while cursor < pattern.length && pattern[cursor] != ']'
          if pattern[cursor] == '\\'
            body << ecma_escape(pattern[cursor + 1], in_class: true)
            cursor += 2
            next
          end

          body << class_member(pattern[cursor])
          cursor += 1
        end
        # Unterminated: no expression in either dialect, so it is copied as
        # written and Ruby refuses it.
        if cursor >= pattern.length
          out << pattern[index..]
          return pattern.length
        end

        out << class_source(body, negated)
        cursor + 1
      end

      # @return [String] the Ruby spelling of one unescaped class member
      def class_member(char)
        # Ruby reads a nested `[` as another class and `&&` as intersection;
        # ECMA-262 has neither, so both are literals there.
        ['[', '&'].include?(char) ? "\\#{char}" : char
      end

      # @param body [String] the translated members
      # @param negated [Boolean] whether the class was written with a `^`
      # @return [String] the Ruby character class
      def class_source(body, negated)
        return negated ? ECMA_ANY_CLASS : ECMA_EMPTY_CLASS if body.empty?

        negated ? "[^#{body}]" : "[#{body}]"
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
        factor = schema['multipleOf']
        if factor.is_a?(Numeric) && factor.positive? && !multiple_of?(data, factor)
          errors << "#{path}: value #{shown} is not a multiple of #{clip_value(factor)}"
        end
        errors
      end

      # Whether dividing the value by the factor gives an integer (JSON
      # Schema 2020-12 Validation Section 6.2.1). The division is exact:
      # 0.0075 is a multiple of 0.0001, which binary floating point says it
      # is not, so the decimal each number was written as decides.
      # @param data [Numeric] the instance
      # @param factor [Numeric] the multipleOf value
      # @return [Boolean]
      def multiple_of?(data, factor)
        return (data % factor).zero? if data.is_a?(Integer) && factor.is_a?(Integer)

        (Rational(data.to_s) / Rational(factor.to_s)).denominator == 1
      rescue ArgumentError, ZeroDivisionError, FloatDomainError, TypeError
        # A value no decimal describes (an infinity a Ruby caller passed in;
        # JSON carries none) falls back to the floating-point remainder.
        (data % factor).zero?
      end
    end
  end
end
