# frozen_string_literal: true

module MCPClient
  # Deprecation notices for the features MCP 2026-07-28 placed in the
  # Deprecated state of its feature lifecycle policy (SEP-2596): they keep
  # working for at least the twelve-month deprecation window, but new
  # integrations should not adopt them. The client logs one notice per
  # feature per process, on the first use, and names the suggested migration.
  #
  # Notices can be silenced with `MCPClient::Deprecations.enabled = false`.
  module Deprecations
    # Every feature the 2026-07-28 revision lists in its deprecated features
    # registry, keyed by the identifier passed to {.warn}.
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
        since: '2026-07-28',
        reference: 'SEP-2596 (deprecated since protocol version 2025-03-26)',
        migration: 'migrate the server to Streamable HTTP (MCPClient::ServerStreamableHTTP)'
      },
      include_context: {
        feature: 'The includeContext values "thisServer" and "allServers"',
        since: '2026-07-28',
        reference: 'SEP-2596 (soft-deprecated since protocol version 2025-11-25)',
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

      # Log the notice for a deprecated feature once per process.
      # @param feature [Symbol] a {REGISTRY} key
      # @param logger [Logger, nil] where the notice goes (a nil logger emits nothing)
      # @param detail [String, nil] peer-supplied context quoted in the notice
      #   (control characters are escaped and the text is bounded)
      # @return [Boolean] true when a notice was written, false when it was
      #   already emitted or notices are disabled
      # @raise [ArgumentError] for an unknown feature
      def warn(feature, logger, detail: nil) # rubocop:disable Naming/PredicateMethod
        entry = REGISTRY[feature] or raise ArgumentError, "unknown deprecated feature: #{feature.inspect}"
        return false unless enabled? && logger

        emitted = @mutex.synchronize { @emitted.add?(feature) }
        return false unless emitted

        logger.warn(message(entry, detail))
        true
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
        text = "#{entry[:feature]} is deprecated in MCP #{entry[:since]} (#{entry[:reference]}); " \
               "it keeps working during the deprecation window. Migration: #{entry[:migration]}."
        detail ? "#{text} Received: #{sanitize(detail)}" : text
      end

      # @return [String] the detail with control characters escaped and its length bounded
      def sanitize(detail)
        escaped = detail.to_s.gsub(/[[:cntrl:]]/) { |c| format('\\x%02X', c.ord) }
        escaped.length <= MAX_DETAIL_LENGTH ? escaped : "#{escaped[0, MAX_DETAIL_LENGTH]}..."
      end
    end
  end
end
