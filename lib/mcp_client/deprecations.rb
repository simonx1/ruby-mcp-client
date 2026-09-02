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

    @enabled = true
    @notices = {}
    @gates = {}
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
      # drops warnings (level above WARN), fails to report its level or
      # raises leaves it for a later use. Never raises for a logger failure:
      # the deprecated feature keeps working whatever the log does (feature
      # lifecycle policy).
      #
      # A notice costs its caller what one `logger.warn` costs it, and no
      # more. That is not a promise that it never waits: every other
      # `logger.warn` in this library blocks its caller the same way, so a
      # logger that blocks forever blocks the library everywhere, not only
      # here, and this path claims no exemption the rest of the code cannot
      # claim. Where it does hold back is the module itself: the logger is
      # called outside @mutex and under a gate held only for the feature
      # being logged, so a notice in flight never delays another feature's
      # notice, {.emitted?} or {.reset!}.
      # @param feature [Symbol] a {REGISTRY} key
      # @param logger [Logger, nil] where the notice goes (a nil logger emits nothing)
      # @param detail [String, nil] peer-supplied context quoted in the notice
      #   (control characters are escaped and the text is bounded)
      # @return [Boolean] true when a notice was written, false when it was
      #   already emitted, notices are disabled, the logger drops warnings or failed
      # @raise [ArgumentError] for an unknown feature
      def warn(feature, logger, detail: nil)
        entry = REGISTRY[feature] or raise ArgumentError, "unknown deprecated feature: #{feature.inspect}"
        return false unless enabled? && logger
        return false unless accepts_warnings?(logger)

        emit_once(feature) { logger.warn(message(entry, detail)) }
      end

      # @param feature [Symbol] a {REGISTRY} key
      # @return [Boolean] whether a notice for the feature actually went out.
      #   A caller currently inside `logger.warn` has not emitted one: it may
      #   yet fail, which leaves the notice owed.
      def emitted?(feature)
        @mutex.synchronize { notice_states.key?(feature) }
      end

      # Forget which notices were emitted (each feature warns again on its
      # next use). Intended for tests.
      # @return [void]
      def reset!
        @mutex.synchronize do
          @owner_pid = Process.pid
          @notices.clear
          @gates.clear
        end
      end

      private

      # Run the emission at most once per feature per process, and count it
      # only once it came back without raising.
      #
      # Emitting is what spends the notice, not attempting to: marking the
      # feature spent before the logger had said anything could lose the
      # notice outright, since two first uses racing with different loggers
      # would have the first one fail inside a broken logger while the
      # second — holding a logger that works — saw the slot taken and stood
      # down. So the attempt is serialized on a gate held only for the
      # feature being logged, and a caller that arrives while another is
      # inside the logger either finds the notice emitted (and stands down)
      # or takes it over (the earlier attempt failed). Nothing is timed:
      # a caller waits on the gate exactly as long as it would have waited
      # on a shared logger's own lock, and never comes away from that wait
      # with the notice neither emitted nor its own to write.
      # @param feature [Symbol] a {REGISTRY} key
      # @yield the emission, called with no lock of this module held
      # @return [Boolean] whether this call emitted the notice
      def emit_once(feature)
        gate = gate_for(feature)
        return false unless gate

        gate.synchronize do
          return false if emitted?(feature)

          yield
          mark_emitted(feature)
          true
        end
      rescue StandardError
        false
      end

      # @param feature [Symbol] a {REGISTRY} key
      # @return [Mutex, nil] the feature's emission gate, or nil when its
      #   notice has already gone out and no attempt is needed
      def gate_for(feature)
        @mutex.synchronize do
          return nil if notice_states.key?(feature)

          @gates[feature] ||= Mutex.new
        end
      end

      # Record that the feature's notice went out and retire its gate.
      # @param feature [Symbol] a {REGISTRY} key
      # @return [void]
      def mark_emitted(feature)
        @mutex.synchronize do
          notice_states[feature] = true
          @gates.delete(feature)
        end
      end

      # Which features have had their notice logged IN THIS PROCESS. A
      # prefork server (Puma, Unicorn) that warned while preloading would
      # hand every worker an already-spent map and silence the worker's own
      # first use, so an inherited map is dropped the first time the owning
      # PID no longer matches — along with the gates, whose Mutexes may have
      # been left locked by a thread that did not survive the fork. Callers
      # hold @mutex.
      # @return [Hash{Symbol => true}]
      def notice_states
        if @owner_pid != Process.pid
          @owner_pid = Process.pid
          @notices = {}
          @gates = {}
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
        !(logger.is_a?(::Logger) && logger.level > ::Logger::WARN)
      rescue StandardError
        false
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
