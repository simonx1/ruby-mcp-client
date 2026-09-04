# frozen_string_literal: true

require 'logger'

module MCPClient
  # Deprecation notices for the features listed as Deprecated by the MCP
  # 2026-07-28 deprecated features registry (feature lifecycle policy,
  # SEP-2596): they keep working during their deprecation window, but new
  # integrations should not adopt them. `earliest_removal` carries the
  # registry's own "Earliest removal" wording
  # (https://modelcontextprotocol.io/specification/2026-07-28/deprecated)
  # rather than a paraphrase of the policy floor: what the features
  # 2026-07-28 deprecates wait for is the first revision RELEASED on or after
  # 2027-07-28, which may fall well after that date, so a host must not plan
  # around 2027-07-28 as a removal date. The includeContext values follow
  # Sampling, and only the HTTP+SSE transport has a clock of its own. The
  # earliest removal marks when a feature becomes eligible for removal; the
  # actual removal is a Core Maintainer decision. The client logs one notice
  # per feature per process, on the first use, and names both the earliest
  # removal and the suggested migration.
  #
  # Notices can be silenced with `MCPClient::Deprecations.enabled = false`.
  module Deprecations
    # The "Earliest removal" the registry gives Roots, Sampling, Logging and
    # Dynamic Client Registration. It names a revision, not a date: the
    # release on or after 2027-07-28 may itself be later than 2027-07-28.
    REVISION_AFTER_2027_07_28 = 'the first revision released on or after 2027-07-28'

    # Every feature the 2026-07-28 deprecated features registry lists, keyed
    # by the identifier passed to {.warn}. `since` is the protocol revision
    # in which the feature entered the Deprecated state; `earliest_removal`
    # is the registry's "Earliest removal" cell verbatim, so features that
    # share a window carry the identical string.
    REGISTRY = {
      roots: {
        feature: 'Roots',
        since: '2026-07-28',
        reference: 'SEP-2577',
        earliest_removal: REVISION_AFTER_2027_07_28,
        migration: 'pass directories or files through tool parameters, resource URIs or server configuration'
      },
      sampling: {
        feature: 'Sampling',
        since: '2026-07-28',
        reference: 'SEP-2577',
        earliest_removal: REVISION_AFTER_2027_07_28,
        migration: 'integrate directly with the LLM provider API instead of serving sampling/createMessage'
      },
      logging: {
        feature: 'Logging',
        since: '2026-07-28',
        reference: 'SEP-2577',
        earliest_removal: REVISION_AFTER_2027_07_28,
        migration: 'have the server log to stderr (stdio) or use OpenTelemetry instead of notifications/message'
      },
      http_sse_transport: {
        feature: 'The HTTP+SSE transport',
        since: '2025-03-26',
        reference: 'reclassified by SEP-2596 in 2026-07-28',
        earliest_removal: 'three months after SEP-2596 reaches Final',
        migration: 'migrate the server to Streamable HTTP (MCPClient::ServerStreamableHTTP)'
      },
      include_context: {
        feature: 'The includeContext values "thisServer" and "allServers"',
        since: '2025-11-25',
        reference: 'reclassified by SEP-2596 in 2026-07-28',
        earliest_removal: 'follows Sampling (SEP-2577)',
        migration: 'servers should omit includeContext or send "none"; the values are removed no later than Sampling'
      },
      dynamic_client_registration: {
        feature: 'OAuth 2.0 Dynamic Client Registration (RFC 7591)',
        since: '2026-07-28',
        reference: 'MCP PR #2858',
        earliest_removal: REVISION_AFTER_2027_07_28,
        migration: 'prefer a Client ID Metadata Document (client_id_metadata_url) or pre-registered credentials'
      }
    }.freeze

    # Longest peer-supplied detail quoted in a notice.
    MAX_DETAIL_LENGTH = 200

    # Marks a thread that is between claiming a feature's notice and coming
    # back out of the logger. A thread-level variable, not a fiber-local
    # one: what it guards is a claim this thread holds, which every fiber of
    # the thread holds with it.
    EMITTING_KEY = :mcp_client_deprecation_emitting

    # A notice claimed by a caller that is inside the logger right now, as
    # opposed to {EMITTED} for one the logger took.
    WRITING = :writing

    # A notice that went out.
    EMITTED = :emitted

    @enabled = true
    @notices = {}
    @mutex = Mutex.new
    @owner_pid = Process.pid

    class << self
      # @return [Boolean] whether notices are logged (default true)
      attr_writer :enabled

      # @return [Boolean] whether notices are logged
      def enabled?
        @enabled
      end

      # Log the notice for a deprecated feature once per process. The notice
      # counts as emitted only once the logger accepted it: a logger that
      # drops warnings (level above WARN), writes nowhere (`Logger.new(nil)`),
      # fails to report its level or raises leaves it for a later use, and so
      # do a nested attempt from inside another notice's logger and a caller
      # that finds the notice already in flight (see {.emit_once}).
      # Never raises for a logger failure: the deprecated feature
      # keeps working whatever the log does (feature lifecycle policy).
      #
      # A notice costs its caller what one `logger.warn` costs it, and no
      # more. That is not a promise that it never waits: every other
      # `logger.warn` in this library blocks its caller the same way, so a
      # logger that blocks forever blocks the library everywhere, not only
      # here, and this path claims no exemption the rest of the code cannot
      # claim. What it does promise is that the waiting is the logger's: no
      # caller ever waits for a lock of THIS module, which is never held
      # while calling out, so a notice in flight never delays another
      # feature's notice, another caller, {.emitted?} or {.reset!}.
      # @param feature [Symbol] a {REGISTRY} key
      # @param logger [Logger, nil] where the notice goes (a nil logger emits nothing)
      # @param detail [String, nil] peer-supplied context quoted in the notice
      #   (control characters are escaped and the text is bounded)
      # @return [Boolean] true when a notice was written, false when it was
      #   already emitted or in flight, notices are disabled, the logger drops
      #   warnings or failed
      # @raise [ArgumentError] for an unknown feature
      def warn(feature, logger, detail: nil)
        entry = REGISTRY[feature] or raise ArgumentError, "unknown deprecated feature: #{feature.inspect}"
        return false unless enabled? && logger
        return false unless accepts_warnings?(logger)

        emit_once(feature, logger) { logger.warn(message(entry, detail)) }
      end

      # @param feature [Symbol] a {REGISTRY} key
      # @return [Boolean] whether a notice for the feature actually went out.
      #   A caller currently inside `logger.warn` has not emitted one: it may
      #   yet fail, which leaves the notice owed.
      def emitted?(feature)
        @mutex.synchronize { notice_states[feature] == EMITTED }
      end

      # Forget which notices were emitted (each feature warns again on its
      # next use). Intended for tests.
      # @return [void]
      def reset!
        @mutex.synchronize do
          @owner_pid = Process.pid
          @notices.clear
        end
      end

      private

      # Run the emission at most once per feature per process, and count it
      # only once it came back without raising.
      #
      # Emitting is what spends the notice, not attempting to: marking the
      # feature spent before the logger had said anything could lose the
      # notice outright, since a first use that fails inside a broken logger
      # would leave every later use looking at a spent slot. So an attempt
      # is a CLAIM (see {.claim}), released again when the logger did not
      # take the notice, and the feature is marked emitted only afterwards.
      #
      # Nothing is ever waited for. A caller that finds the notice in flight
      # stands down at once and leaves it to a later use, exactly as a
      # dropped one is left — it does not queue behind the emission, and it
      # does not take it over. Queueing is what buys a lock-order inversion,
      # and no rule about who may queue can avoid it, because the waiter
      # cannot know what it is holding: `logger.warn` is host code that
      # serializes its writes (as ::Logger does behind its device lock) and
      # that may reach a deprecated feature from a formatter, a log
      # subscriber or an audit hook. A thread writing an ORDINARY log line
      # holds that device lock and is not inside a notice at all; let it
      # queue for a notice held by a thread that is waiting for the same
      # device lock and both stop, taking the sampling request, the log
      # level or the SSE `connect` behind the notice with them. A claim is
      # a mark under @mutex instead, taken and released without ever calling
      # out of this module, so a lock of ours is never held across host code
      # and never acquired behind one of theirs.
      #
      # Standing down loses nothing that was there to lose: whoever holds
      # the claim is writing that notice, and if their logger fails the
      # claim is released, so the next use of the feature attempts it again.
      # A thread already inside a notice stands down too, which keeps a
      # logger callback from re-entering the host's logger under this
      # module's own name.
      #
      # The logger is asked one more time whether it keeps warnings, next to
      # the write rather than at the top of {.warn}: `Logger#warn` returns
      # true whether it wrote or filtered, so a level that went up in
      # between would otherwise spend the process's one notice on a warning
      # nobody can read. A level that changes DURING the write is beyond
      # reach — that race is the host's own, and the same one two of its
      # threads have with each other.
      # @param feature [Symbol] a {REGISTRY} key
      # @param logger [Logger, #warn] the logger the emission writes to
      # @yield the emission, called with no lock of this module held
      # @return [Boolean] whether this call emitted the notice
      def emit_once(feature, logger)
        return false if emitting?
        return false unless claim(feature)

        written = false
        begin
          mark_emitting(true)
          if accepts_warnings?(logger)
            yield
            written = true
          end
        rescue StandardError
          written = false
        ensure
          mark_emitting(false)
          settle(feature, written)
        end
        written
      end

      # Reserve this process's notice for the caller. The claim is a mark in
      # the same map that records emitted notices, so a feature is claimable
      # only while it is neither emitted nor being written right now, and
      # taking it costs @mutex for the length of a hash lookup.
      # @param feature [Symbol] a {REGISTRY} key
      # @return [Boolean] whether the caller may write the notice
      def claim(feature)
        @mutex.synchronize do
          states = notice_states
          return false if states.key?(feature)

          states[feature] = WRITING
          true
        end
      end

      # Close a claim: spend the notice, or hand it back to a later use.
      # @param feature [Symbol] a {REGISTRY} key
      # @param written [Boolean] whether the logger took the notice
      # @return [void]
      def settle(feature, written)
        @mutex.synchronize do
          states = notice_states
          written ? states[feature] = EMITTED : states.delete(feature)
        end
      end

      # @return [Boolean] whether this thread is already inside a notice
      def emitting?
        Thread.current.thread_variable_get(EMITTING_KEY) ? true : false
      end

      # @param value [Boolean] whether this thread is inside a notice
      # @return [void]
      def mark_emitting(value)
        Thread.current.thread_variable_set(EMITTING_KEY, value)
      end

      # What this process knows about each feature's notice: {WRITING} while
      # a caller is inside the logger, {EMITTED} once one came back having
      # written it, absent otherwise. A prefork server (Puma, Unicorn) that
      # warned while preloading would hand every worker an already-spent map
      # and silence the worker's own first use, so an inherited map is
      # dropped the first time the owning PID no longer matches — including
      # any claim held by a thread that did not survive the fork, which no
      # one in the child will ever settle. Callers hold @mutex.
      # @return [Hash{Symbol => Symbol}]
      def notice_states
        if @owner_pid != Process.pid
          @owner_pid = Process.pid
          @notices = {}
        end
        @notices
      end

      # Whether the logger would keep a warning. Asking is itself protected:
      # a Logger subclass whose `level` accessor raises must not abort the
      # deprecated operation, so the failure is treated as "would not keep
      # it" and the notice slot stays free for a later, working logger.
      # @param logger [Logger, #warn] the candidate logger
      # @return [Boolean] false when the logger drops warnings or asking failed
      def accepts_warnings?(logger)
        return false if logger.is_a?(::Logger) && logger.level > ::Logger::WARN

        !no_output_device?(logger)
      rescue StandardError
        false
      end

      # `Logger.new(nil)` is the documented no-output logger: it keeps every
      # level, so the level check passes, and `warn` returns successfully
      # having written nothing. Counting that as the notice would spend it on
      # a reader that does not exist and silence every later use — including
      # one holding a logger that does write. A logger has no device only
      # when it was built without one: `logger` 1.7 also folds
      # `Logger.new(File::NULL)` into that (it opens no file), earlier
      # versions give it a real device, and either reading is safe here —
      # the notice is written or it stays owed.
      # @param logger [Logger, #warn] the candidate logger
      # @return [Boolean] whether the logger provably writes nowhere
      def no_output_device?(logger)
        logger.is_a?(::Logger) &&
          logger.instance_variable_defined?(:@logdev) &&
          logger.instance_variable_get(:@logdev).nil?
      end

      # @return [String] the notice text
      def message(entry, detail)
        text = "#{entry[:feature]} is deprecated since MCP #{entry[:since]} (#{entry[:reference]}); " \
               'it keeps working during its deprecation window. Earliest removal: ' \
               "#{entry[:earliest_removal]}. Migration: #{entry[:migration]}."
        detail ? "#{text} Received: #{sanitize(detail)}" : text
      end

      # @return [String] the detail with control characters (and the Unicode
      #   line and paragraph separators) escaped and its length bounded
      def sanitize(detail)
        escaped = detail.to_s.gsub(/[[:cntrl:]\u0085\u2028\u2029]/) { |c| format('\\u%04X', c.ord) }
        escaped.length <= MAX_DETAIL_LENGTH ? escaped : "#{escaped[0, MAX_DETAIL_LENGTH]}..."
      end
    end
  end
end
