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

    # How long a caller waits for another caller's in-flight notice to
    # resolve. A notice must never hold up the deprecated operation, so the
    # wait is bounded: a logger that blocks forever costs the contender this
    # much and no more, after which it gives up on the notice (the
    # reservation still belongs to its owner, which will either emit it or
    # release it for a later use).
    PENDING_WAIT_SECONDS = 0.25

    @enabled = true
    @notices = {}
    @mutex = Mutex.new
    @resolved = ConditionVariable.new
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
      # lifecycle policy). The slot is reserved under the lock and the logger
      # is called outside it.
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
        return false unless reserve(feature)

        begin
          logger.warn(message(entry, detail))
          settle(feature, :emitted)
          true
        rescue StandardError
          settle(feature, nil)
          false
        end
      end

      # @param feature [Symbol] a {REGISTRY} key
      # @return [Boolean] whether a notice for the feature actually went out.
      #   A reservation still in flight is not one: a caller is inside
      #   `logger.warn` and may yet fail, which puts the notice back.
      def emitted?(feature)
        @mutex.synchronize { notice_states[feature] == :emitted }
      end

      # Forget which notices were emitted (each feature warns again on its
      # next use). Intended for tests.
      # @return [void]
      def reset!
        @mutex.synchronize do
          @owner_pid = Process.pid
          @notices.clear
          @resolved.broadcast
        end
      end

      private

      # Claim the right to log a feature's notice. A feature is absent (never
      # attempted), `:pending` (a caller is inside `logger.warn` for it right
      # now) or `:emitted` (a notice went out). Only the caller that moves it
      # from absent to `:pending` may log.
      #
      # Reserving is not emitting: marking the feature spent before the logger
      # had said anything could lose the notice outright. Two first uses that
      # race with different loggers would have the reserving one block in a
      # broken logger while the contender — holding a logger that works — saw
      # the slot taken and gave up, and the reservation's later failure then
      # left the notice owed to a use that may never come. So a caller that
      # meets a reservation waits for its outcome, and takes the notice over
      # if that outcome is a failure. The wait is bounded by
      # {PENDING_WAIT_SECONDS}: a notice never holds up the deprecated
      # operation, so a reservation that hangs costs the contender the notice,
      # not its progress.
      # @param feature [Symbol] a {REGISTRY} key
      # @return [Boolean] whether this caller may log the notice
      def reserve(feature)
        deadline = nil
        @mutex.synchronize do
          loop do
            case notice_states[feature]
            when :emitted
              return false
            when :pending
              deadline ||= monotonic_time + PENDING_WAIT_SECONDS
              remaining = deadline - monotonic_time
              return false if remaining <= 0

              @resolved.wait(@mutex, remaining)
            else
              notice_states[feature] = :pending
              return true
            end
          end
        end
      end

      # Record how a reservation ended and wake whoever is waiting on it.
      # @param feature [Symbol] a {REGISTRY} key
      # @param state [Symbol, nil] `:emitted`, or nil to release the
      #   reservation so a contender or a later use can retry it
      # @return [void]
      def settle(feature, state)
        @mutex.synchronize do
          states = notice_states
          state ? states[feature] = state : states.delete(feature)
          @resolved.broadcast
        end
      end

      # @return [Float] a clock that cannot jump backwards
      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # What each feature's notice has reached IN THIS PROCESS: `:pending`
      # while a caller is inside `logger.warn` for it, `:emitted` once one
      # went out, absent otherwise. A prefork server (Puma, Unicorn) that
      # warns while preloading would hand every worker an already-spent map
      # and silence the worker's own first use, so an inherited map is
      # dropped the first time the owning PID no longer matches. Callers hold
      # @mutex.
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
