# frozen_string_literal: true

module MCPClient
  module SchemaValidator
    # The rewrite of an ECMA-262 pattern as the Ruby expression that means
    # the same thing. JSON Schema 2020-12 Core Section 4.3 requires patterns
    # to be interpreted as ECMA-262 regular expressions, and Ruby's differ
    # from them in both directions: what Ruby accepts that ECMA-262 rejects
    # makes the validator accept a value the schema refuses, and the
    # converse rejects a conforming one (and, through `not` or
    # `additionalProperties: false`, flips both). Extended into
    # SchemaValidator, so the methods are its own.
    #
    # A pattern comes from the remote peer and is as long as the peer made
    # it, so the translation is one linear pass over its characters that
    # consults the validation-wide deadline as it goes, and a pattern past
    # MAX_PATTERN_LENGTH is refused before it is read at all.
    module EcmaPatterns
      # A pattern that is no ECMA-262 expression: syntax ECMA-262 does not
      # define (Ruby's inline flags, possessive quantifiers, atomic groups,
      # comments) or an expression neither dialect accepts. A RegexpError,
      # so every caller that rescues an unreadable expression sees it.
      class SyntaxError < RegexpError; end

      # A pattern that IS an ECMA-262 expression but whose meaning Ruby's
      # engine cannot be made to reproduce, so translating it would answer
      # some instances wrongly. The two engines differ in two ways no
      # rewriting bridges:
      #
      # - ECMA-262 clears the captures inside a quantified group at the start
      #   of every iteration (a back-reference to a group the last iteration
      #   did not enter matches the empty string); Ruby keeps whatever the
      #   last iteration that entered it captured. `^(a|(b))*\2$` accepts
      #   "aba" and refuses "abab" there, and exactly the opposite here.
      # - ECMA-262 lookbehind is variable-length (ES2018); Ruby's is not.
      #
      # Refusing the schema is the only honest answer left: a verdict from
      # the other engine's rules would accept structured content the schema
      # forbids as readily as it would refuse conforming content.
      class Untranslatable < RegexpError; end

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

      # The escapes ECMA-262 defines, which Ruby reads the same way: the
      # class escapes, the control escapes, a hex or control-letter escape
      # and a Unicode property. `\s` / `\S` are defined by both but over
      # different sets, `\b` / `\B` over different word characters, the
      # digits are back-references or legacy octal escapes, `\u` may spell
      # a surrogate pair and `\k` a named back-reference, so those are
      # rewritten rather than kept.
      ECMA_KEPT_ESCAPES = 'dDwWfnrtvxcpP'

      # ECMA-262's word characters: `\w` is [A-Za-z0-9_] there, and its
      # word-boundary assertions are defined over exactly those, while Ruby's
      # `\b` knows every Unicode letter — so "é" has a boundary in Ruby and
      # none in ECMA-262.
      ECMA_WORD = '[A-Za-z0-9_]'

      # `\b`: a word character on exactly one side.
      ECMA_WORD_BOUNDARY = "(?:(?<=#{ECMA_WORD})(?!#{ECMA_WORD})|(?<!#{ECMA_WORD})(?=#{ECMA_WORD}))".freeze

      # `\B`: word characters on both sides, or on neither.
      ECMA_NON_BOUNDARY = "(?:(?<=#{ECMA_WORD})(?=#{ECMA_WORD})|(?<!#{ECMA_WORD})(?!#{ECMA_WORD}))".freeze

      # The characters that may follow `(?` in ECMA-262: a non-capturing
      # group, a lookahead, and (after `<`) a lookbehind or a named group.
      # Anything else Ruby reads as an inline option, an atomic group, a
      # comment or its own named-group syntax, none of which ECMA-262 has.
      ECMA_GROUP_OPENERS = ':=!<'

      # How many characters the translation reads between two looks at the
      # deadline.
      TRANSLATION_CHECK_INTERVAL = 256

      # The Ruby expression an ECMA-262 pattern means.
      # @param pattern [String] the peer's pattern
      # @param timeout [Float] seconds the match may take
      # @param deadline [Float, nil] monotonic deadline the translation runs under
      # @return [Regexp]
      # @raise [RegexpError] when the pattern is not a usable expression
      # @raise [Untranslatable] when it is one Ruby cannot reproduce
      # @raise [Aborted] when the deadline passes during the translation
      def ecma_regexp(pattern, timeout, deadline = nil)
        Regexp.new(ecma_source(pattern, deadline), timeout: timeout)
      rescue RegexpError => e
        # ECMA-262 lookbehind has been variable-length since ES2018 and
        # Ruby's never has been: the pattern is a good expression this
        # engine cannot be given, not a bad one.
        raise Untranslatable, "variable-length lookbehind cannot be evaluated faithfully (#{e.message})" if
          e.message.include?('look-behind')

        raise
      end

      # Rewrite an ECMA-262 pattern as Ruby regexp source. Everything
      # ECMA-262 defines is kept; what only Ruby defines is either read the
      # way ECMA-262 reads it — an escape ECMA-262 does not define is an
      # identity escape there (Annex B.1.2), so `\A` is a literal "A" and not
      # the start of the subject — or refused where ECMA-262 refuses it.
      # @param pattern [String] the peer's pattern
      # @param deadline [Float, nil] monotonic deadline the translation runs under
      # @return [String] Ruby regexp source
      # @raise [SyntaxError] for syntax ECMA-262 does not define
      # @raise [Aborted] when the deadline passes during the translation
      def ecma_source(pattern, deadline = nil)
        raise SyntaxError, "pattern is longer than #{MAX_PATTERN_LENGTH} characters" if
          pattern.length > MAX_PATTERN_LENGTH

        chars = pattern.chars
        scan = { chars: chars, index: 0, out: +'', deadline: deadline, read: 0, last: :none, opened: 0 }
        scan[:order] = count_capture_groups(chars)
        scan[:groups] = scan[:order].length
        scan[:names] = scan[:order].compact
        scan[:repeated] = repeated_capture_groups(chars)
        scan[:generated] = generated_name_prefix(scan[:names])
        while scan[:index] < chars.length
          note_translation_progress(scan)
          chars[scan[:index]] == '[' ? copy_character_class(scan) : copy_ecma_token(scan)
        end
        scan[:out]
      end

      # Consult the deadline every TRANSLATION_CHECK_INTERVAL characters.
      # @raise [Aborted]
      def note_translation_progress(scan)
        scan[:read] += 1
        return unless (scan[:read] % TRANSLATION_CHECK_INTERVAL).zero?

        raise Aborted, 'validation time budget exhausted while translating a pattern' if
          budget_exhausted?(scan[:deadline])
      end

      # The capturing groups a pattern declares, in order and in one pass:
      # what a numeric escape refers to depends on how many there are (Annex
      # B.1.4: a number past the count is a legacy octal escape) and on which
      # one it names — ECMA-262 numbers named and unnamed groups alike,
      # left to right, while Ruby stops capturing unnamed groups once a
      # named one exists, so the numbering is kept here and every group is
      # written as a named one there ({#copy_group_opener}).
      # @return [Array<String, nil>] each group's name, nil for an unnamed one
      def count_capture_groups(chars)
        order = []
        index = 0
        in_class = false
        while index < chars.length
          char = chars[index]
          if char == '\\'
            index += 2
            next
          end
          in_class = true if char == '['
          in_class = false if char == ']' && in_class
          if char == '(' && !in_class
            order << nil if chars[index + 1] != '?'
            name = group_name_at(chars, index + 2)
            order << name if name
          end
          index += 1
        end
        order
      end

      # The Ruby name of a capturing group, by its ECMA-262 number: its own
      # where it has one, a generated one otherwise.
      # @param number [Integer] the group's number, from 1
      # @return [String]
      def group_name_for(scan, number)
        scan[:order][number - 1] || "#{scan[:generated]}#{number}"
      end

      # A prefix for the generated names that none of the pattern's own
      # names begins with, so a written `(?<__mcp_g1>` can never be the
      # group a numeric back-reference is rewritten to name.
      # @param names [Array<String>] the names the pattern wrote
      # @return [String]
      def generated_name_prefix(names)
        prefix = +'__mcp_g'
        prefix << '_' while names.any? { |name| name.start_with?(prefix) }
        prefix
      end

      # The name of a `(?<name>` group opening at the index of its `<`.
      # @return [String, nil]
      def group_name_at(chars, index)
        return nil unless chars[index] == '<' && !'=!'.include?(chars[index + 1].to_s)

        close = index + 1
        close += 1 while close < chars.length && chars[close] != '>'
        chars[(index + 1)...close].join if close < chars.length
      end

      # Copy one token from outside a character class.
      # @return [void]
      def copy_ecma_token(scan)
        char = scan[:chars][scan[:index]]
        case char
        when '\\' then copy_escape(scan, in_class: false)
        when '(' then copy_group_opener(scan)
        when '*', '+', '?' then copy_quantifier(scan, char)
        when '{' then copy_brace(scan)
        else copy_plain_token(scan, char)
        end
      end

      # A character that is neither an escape, a group opener nor a
      # quantifier.
      # @return [void]
      def copy_plain_token(scan, char)
        scan[:index] += 1
        case char
        when '^', '$'
          emit(scan, ECMA_ANCHORS[char], :none)
        when '.' then emit(scan, ECMA_DOT, :atom)
        when '|' then emit(scan, char, :none)
        # A `]` or `}` that closes nothing is a literal in ECMA-262 (Annex
        # B.1.4); Ruby reads a bare `}` the same way but is spared the guess.
        when ']', '}' then emit(scan, "\\#{char}", :atom)
        else emit(scan, char, :atom)
        end
      end

      # Append translated source and record what kind of token it was.
      # @return [void]
      def emit(scan, source, kind)
        scan[:out] << source
        scan[:last] = kind
      end

      # A `(`: a capturing group, or `(?` followed by one of the openers
      # ECMA-262 defines. Ruby's other `(?` forms are refused.
      # @return [void]
      def copy_group_opener(scan)
        chars = scan[:chars]
        index = scan[:index]
        if chars[index + 1] != '?'
          scan[:index] += 1
          scan[:opened] += 1
          # Beside a named group Ruby would not capture this one at all.
          return emit(scan, scan[:names].empty? ? '(' : "(?<#{group_name_for(scan, scan[:opened])}>", :none)
        end

        opener = chars[index + 2].to_s
        unless ECMA_GROUP_OPENERS.include?(opener) && !opener.empty?
          raise SyntaxError,
                "invalid group at index #{index}"
        end

        if opener == '<' && !'=!'.include?(chars[index + 3].to_s)
          raise SyntaxError, "invalid group name at index #{index}" unless group_name_at(chars, index + 2)

          scan[:opened] += 1
        end

        scan[:index] += 3
        emit(scan, "(?#{opener}", :none)
      end

      # A `*`, `+` or `?`: a quantifier on the preceding atom, or the lazy
      # marker on the preceding quantifier. ECMA-262 has nothing else for
      # them to be: on nothing, or on a quantifier (Ruby's possessive `++`,
      # nested `+*`), they are a syntax error ("Nothing to repeat").
      # @return [void]
      def copy_quantifier(scan, char)
        scan[:index] += 1
        case scan[:last]
        when :atom then emit(scan, char, :quantifier)
        when :quantifier
          raise SyntaxError, "nothing to repeat at index #{scan[:index] - 1}" unless char == '?'

          emit(scan, char, :lazy)
        else
          raise SyntaxError, "nothing to repeat at index #{scan[:index] - 1}"
        end
      end

      # A `{`: a counted quantifier when it spells one (`{n}`, `{n,}`,
      # `{n,m}`), else a literal brace (Annex B.1.4). Ruby also reads `{,m}`
      # as a quantifier, so a literal is escaped rather than copied.
      # @return [void]
      def copy_brace(scan)
        chars = scan[:chars]
        index = scan[:index]
        close = index + 1
        close += 1 while close < chars.length && chars[close] != '}' && close - index <= 32
        body = chars[(index + 1)...close].join
        unless chars[close] == '}' && body.match?(/\A\d+(,\d*)?\z/)
          scan[:index] += 1
          return emit(scan, '\\{', :atom)
        end

        raise SyntaxError, "nothing to repeat at index #{index}" unless scan[:last] == :atom

        scan[:index] = close + 1
        emit(scan, "{#{body}}", :quantifier)
      end

      # One escape sequence, outside or inside a character class.
      # @return [void]
      def copy_escape(scan, in_class:)
        chars = scan[:chars]
        char = chars[scan[:index] + 1]
        # A trailing backslash is no expression in either dialect; Ruby says so.
        if char.nil?
          scan[:index] += 1
          return emit(scan, '\\', :atom)
        end

        scan[:index] += 2
        case char
        when '0'..'9' then copy_numeric_escape(scan, char, in_class: in_class)
        when 'u' then copy_unicode_escape(scan)
        when 'k' then copy_named_reference(scan, in_class: in_class)
        else emit(scan, ecma_escape(char, in_class: in_class), 'bB'.include?(char) && !in_class ? :none : :atom)
        end
      end

      # One escape's Ruby spelling. An escape ECMA-262 leaves undefined is
      # an identity escape: the character itself.
      # @param char [String] what followed the backslash
      # @param in_class [Boolean] whether the escape sits in a character class
      # @return [String]
      def ecma_escape(char, in_class:)
        return in_class ? ECMA_SPACE_MEMBERS : "[#{ECMA_SPACE_MEMBERS}]" if char == 's'
        # Inside a class Ruby reads the nested one as a union, which is
        # what a member set complement means there.
        return "[^#{ECMA_SPACE_MEMBERS}]" if char == 'S'
        # `\b` is a backspace inside a class and a word boundary outside it;
        # `\B` asserts outside a class and is an identity escape inside one.
        return in_class ? '\\b' : ECMA_WORD_BOUNDARY if char == 'b'
        return in_class ? 'B' : ECMA_NON_BOUNDARY if char == 'B'
        return "\\#{char}" if ECMA_KEPT_ESCAPES.include?(char)

        # An identity escape: a letter stands for itself, and punctuation
        # keeps the backslash (which means the same in both dialects).
        char.match?(/[A-Za-z]/) ? char : "\\#{char}"
      end

      # A `\` followed by digits: a back-reference to a group the pattern
      # declares, else (Annex B.1.4) a legacy octal escape of up to three
      # octal digits, or the identity escapes `8` and `9`. A back-reference
      # to a group that did not participate matches the empty string in
      # ECMA-262 and fails in Ruby, so it is written as the conditional Ruby
      # reads that way.
      # @return [void]
      def copy_numeric_escape(scan, first, in_class:)
        chars = scan[:chars]
        digits = +first
        (digits << chars[scan[:index]]) && scan[:index] += 1 while chars[scan[:index]].to_s.match?(/\d/)
        number = digits.to_i
        if number.positive? && number <= scan[:groups] && !in_class
          reject_repeated_reference(scan, number)
          return emit(scan, "(?(#{number})\\#{number}|)", :atom) if scan[:names].empty?

          name = group_name_for(scan, number)
          return emit(scan, "(?(<#{name}>)\\k<#{name}>|)", :atom)
        end

        octal = digits.match(/\A[0-7]{1,3}/)&.to_s
        octal = octal[0, 2] if octal && octal.length == 3 && octal.to_i(8) > 255
        if octal.nil?
          # `8` and `9` stand for themselves; the digits after them too.
          return emit(scan, digits, :atom)
        end

        emit(scan, format('\\x%02X', octal.to_i(8)) + digits[octal.length..], :atom)
      end

      # `\uXXXX`: a code unit, which Ruby reads as a code point. A surrogate
      # pair (ECMA-262 without the `u` flag matches the two units of one
      # character) is joined into the character it encodes; a lone
      # surrogate is no character any string carries, so it matches
      # nothing. A `\u` that spells no code unit is an identity escape.
      # @return [void]
      def copy_unicode_escape(scan)
        high = hex_code_unit(scan, scan[:index])
        return emit(scan, 'u', :atom) unless high

        scan[:index] += 4
        low = nil
        if high.between?(0xD800, 0xDBFF) && scan[:chars][scan[:index]] == '\\' && scan[:chars][scan[:index] + 1] == 'u'
          low = hex_code_unit(scan, scan[:index] + 2)
          low = nil unless low&.between?(0xDC00, 0xDFFF)
        end
        if low
          scan[:index] += 6
          return emit(scan, format('\\u{%X}', 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)), :atom)
        end
        return emit(scan, ECMA_EMPTY_CLASS, :atom) if high.between?(0xD800, 0xDFFF)

        emit(scan, format('\\u%04X', high), :atom)
      end

      # @return [Integer, nil] the four hex digits at an index, as a number
      def hex_code_unit(scan, index)
        text = scan[:chars][index, 4]&.join.to_s
        text.match?(/\A\h{4}\z/) ? text.to_i(16) : nil
      end

      # `\k<name>`: a named back-reference where the pattern declares named
      # groups (with the same empty-match rule as a numbered one); with none
      # declared it is an identity escape for "k" (Annex B.1.2).
      # @return [void]
      def copy_named_reference(scan, in_class:)
        return emit(scan, 'k', :atom) if scan[:names].empty? || in_class

        name = group_name_at(scan[:chars], scan[:index])
        unless name && scan[:names].include?(name)
          raise SyntaxError,
                "invalid named reference at index #{scan[:index] - 2}"
        end

        scan[:index] += name.length + 2
        reject_repeated_reference(scan, scan[:order].index(name) + 1)
        emit(scan, "(?(<#{name}>)\\k<#{name}>|)", :atom)
      end

      # A back-reference to a group a quantifier may repeat reads one way in
      # ECMA-262 (cleared at each iteration) and another in Ruby (kept), and
      # the difference decides instances either way round, so the pattern is
      # refused rather than answered.
      # @param number [Integer] the group the reference names
      # @return [void]
      # @raise [Untranslatable]
      def reject_repeated_reference(scan, number)
        return unless scan[:repeated].include?(number)

        raise Untranslatable,
              "a back-reference to group #{number}, which a quantifier repeats, cannot be evaluated faithfully " \
              "(ECMA-262 clears the group's capture at each repetition and Ruby keeps it)"
      end

      # The capturing groups a quantifier may repeat: those inside (or being)
      # a group followed by a quantifier that allows a second iteration.
      # `?` and `{0,1}` allow only one, so nothing is ever cleared between
      # iterations there and the existing "did the group participate"
      # conditional already reads the way ECMA-262 does. Read in one pass,
      # skipping escapes and character classes, so a `(` written as a
      # literal opens nothing.
      # @param chars [Array<String>] the pattern
      # @return [Array<Integer>] the group numbers
      def repeated_capture_groups(chars)
        state = { open: [], repeated: [], number: 0, index: 0, in_class: false }
        while state[:index] < chars.length
          char = chars[state[:index]]
          state[:index] += 1
          next state[:index] += 1 if char == '\\'
          next state[:in_class] = true if char == '[' && !state[:in_class]
          next state[:in_class] = false if char == ']' && state[:in_class]
          next if state[:in_class]

          open_repeat_group(state, chars) if char == '('
          close_repeat_group(state, chars) if char == ')'
        end
        state[:repeated]
      end

      # @return [void]
      def open_repeat_group(state, chars)
        capturing = chars[state[:index]] != '?' || group_name_at(chars, state[:index] + 1).to_s != ''
        number = capturing ? (state[:number] += 1) : nil
        state[:open] << { number: number, inner: [] }
      end

      # @return [void]
      def close_repeat_group(state, chars)
        group = state[:open].pop
        return unless group

        members = group[:inner] + [group[:number]].compact
        state[:repeated].concat(members) if quantifier_at?(chars, state[:index])
        parent = state[:open].last
        parent ? parent[:inner].concat(members) : nil
      end

      # @return [Boolean] whether the quantifier at an index admits a second
      #   iteration, which is when ECMA-262's per-iteration clearing of the
      #   captures inside it can be seen at all
      def quantifier_at?(chars, index)
        char = chars[index]
        return true if ['*', '+'].include?(char)
        return false unless char == '{'

        bounds = chars[index..].join[/\A\{(\d+)(,(\d*))?\}/, 0]
        return false unless bounds

        repeated_bounds?(Regexp.last_match(1).to_i, Regexp.last_match(2), Regexp.last_match(3))
      end

      # @param least [Integer] the `{n` of the quantifier
      # @param comma [String, nil] its `,`, when it has one
      # @param most [String, nil] its `m`, when it has one
      # @return [Boolean] whether it admits two iterations
      def repeated_bounds?(least, comma, most)
        return least >= 2 if comma.nil?
        return true if most.nil? || most.empty?

        most.to_i >= 2
      end

      # Copy a character class, which ECMA-262 and Ruby read differently: an
      # empty class is legal there and matches nothing, and `[` and `&`
      # inside a class are literals rather than the openers of Ruby's nested
      # classes and set intersection.
      # @return [void]
      def copy_character_class(scan)
        chars = scan[:chars]
        opening = scan[:index]
        negated = chars[opening + 1] == '^'
        scan[:index] = opening + (negated ? 2 : 1)
        outer = scan[:out]
        scan[:out] = +''
        while scan[:index] < chars.length && chars[scan[:index]] != ']'
          note_translation_progress(scan)
          if chars[scan[:index]] == '\\'
            copy_escape(scan, in_class: true)
          else
            emit(scan, class_member(chars[scan[:index]]), :atom)
            scan[:index] += 1
          end
        end
        body = scan[:out]
        scan[:out] = outer
        # Unterminated: no expression in either dialect.
        raise SyntaxError, "unterminated character class at index #{opening}" if scan[:index] >= chars.length

        scan[:index] += 1
        emit(scan, class_source(body, negated), :atom)
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
    end
  end
end
