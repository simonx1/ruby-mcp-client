# frozen_string_literal: true

require 'logger'

module MCPClient
  # Deprecation notices for the features listed as Deprecated by the MCP
  # 2026-07-28 deprecated features registry (feature lifecycle policy,
  # SEP-2596): they keep working during their deprecation window, but new
  # integrations should not adopt them. The earliest removal of each feature
  # is set by the registry (https://modelcontextprotocol.io/specification/2026-07-28/deprecated);
  # the HTTP+SSE transport and the includeContext values were deprecated by
  # earlier revisions and may go sooner than the features 2026-07-28 itself
  # deprecates. The client logs one notice per feature per process, on the
  # first use, and names the suggested migration.
  #
  # Notices can be silenced with `MCPClient::Deprecations.enabled = false`.
  module Deprecations
    # Every feature the 2026-07-28 deprecated features registry lists, keyed
    # by the identifier passed to {.warn}. `since` is the protocol revision
    # in which the feature entered the Deprecated state.
    REGISTRY = {
      roots: {
        feature: 'Roots',
        since: '2026-07-28',
        reference: 'SEP-2577',
        migration: 'pass directories or files through tool parameters, resource URIs or server configuration'
      },
      sampling: {
        feature: 'Sampling',
        since: '2026-07-28',
        reference: 'SEP-2577',
        migration: 'integrate directly with the LLM provider API instead of serving sampling/createMessage'
      },
      logging: {
        feature: 'Logging',
        since: '2026-07-28',
        reference: 'SEP-2577',
        migration: 'have the server log to stderr (stdio) or use OpenTelemetry instead of notifications/message'
      },
      http_sse_transport: {
        feature: 'The HTTP+SSE transport',
        since: '2025-03-26',
        reference: 'reclassified by SEP-2596 in 2026-07-28; earliest removal three months after SEP-2596 is Final',
        migration: 'migrate the server to Streamable HTTP (MCPClient::ServerStreamableHTTP)'
      },
      include_context: {
        feature: 'The includeContext values "thisServer" and "allServers"',
        since: '2025-11-25',
        reference: 'reclassified by SEP-2596 in 2026-07-28',
        migration: 'servers should omit includeContext or send "none"; the values are removed no later than Sampling'
      },
      dynamic_client_registration: {
        feature: 'OAuth 2.0 Dynamic Client Registration (RFC 7591)',
        since: '2026-07-28',
        reference: 'MCP PR #2858',
        migration: 'prefer a Client ID Metadata Document (client_id_metadata_url) or pre-registered credentials'
      }
    }.freeze

    # Longest peer-supplied detail quoted in a notice.
    MAX_DETAIL_LENGTH = 200

    @enabled = true
    @emitted = Set.new
    @mutex = Mutex.new

    class << self
      # @return [Boolean] whether notices are logged (default true)
      attr_writer :enabled

      # @return [Boolean] whether notices are logged
      def enabled?
        @enabled
      end

      # Log the notice for a deprecated feature once per process. The notice
      # counts as emitted only once the logger accepted it: a logger that
      # drops warnings (level above WARN) or raises leaves it for a later
      # use. Never raises for a logger failure: the deprecated feature keeps
      # working whatever the log does (feature lifecycle policy). The slot is
      # reserved under the lock and the logger is called outside it.
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
        return false if logger.is_a?(::Logger) && logger.level > ::Logger::WARN
        return false unless @mutex.synchronize { @emitted.add?(feature) }

        begin
          logger.warn(message(entry, detail))
          true
        rescue StandardError
          @mutex.synchronize { @emitted.delete(feature) }
          false
        end
      end

      # @param feature [Symbol] a {REGISTRY} key
      # @return [Boolean] whether the notice for the feature was already logged
      def emitted?(feature)
        @mutex.synchronize { @emitted.include?(feature) }
      end

      # Forget which notices were emitted (each feature warns again on its
      # next use). Intended for tests.
      # @return [void]
      def reset!
        @mutex.synchronize { @emitted.clear }
      end

      private

      # @return [String] the notice text
      def message(entry, detail)
        text = "#{entry[:feature]} is deprecated since MCP #{entry[:since]} (#{entry[:reference]}); " \
               "it keeps working during its deprecation window. Migration: #{entry[:migration]}."
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
