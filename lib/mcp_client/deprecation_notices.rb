# frozen_string_literal: true

require_relative 'deprecations'

module MCPClient
  # The 2026-07-28 deprecation notices raised from the TRANSPORT, so a host
  # that drives a `ServerStdio`, `ServerSSE`, `ServerHTTP` or
  # `ServerStreamableHTTP` object directly still sees them. Constructing a
  # {MCPClient::Client} is not the only way to negotiate and serve Roots,
  # Sampling or Logging: `on_roots_list_request`, `on_sampling_request` and
  # `on_notification` are public transport APIs, and a notice tied to the
  # Client constructor never fires for a caller that uses them.
  #
  # Mixed into {MCPClient::JsonRpcCommon}, so every transport has it.
  module DeprecationNotices
    # Serving a roots/list request means the host declared, and is using, the
    # deprecated Roots capability.
    # @return [void]
    def warn_roots_deprecated
      MCPClient::Deprecations.warn(:roots, @logger)
    end

    # Serving a sampling/createMessage request. SEP-2596 also deprecated the
    # includeContext values "thisServer" and "allServers", which arrive on
    # the very same request, so both notices belong here.
    # @param params [Hash, nil] the sampling/createMessage params
    # @return [void]
    def warn_sampling_deprecated(params = nil)
      MCPClient::Deprecations.warn(:sampling, @logger)
      value = params.is_a?(Hash) ? params['includeContext'] : nil
      return unless %w[thisServer allServers].include?(value)

      MCPClient::Deprecations.warn(:include_context, @logger, detail: "includeContext #{value}")
    end

    # Receiving or setting a log level over MCP: the whole Logging page is
    # Deprecated (SEP-2577).
    # @return [void]
    def warn_logging_deprecated
      MCPClient::Deprecations.warn(:logging, @logger)
    end

    # The notice for an input request fulfilled through the multi round-trip
    # pattern, whose handler is the same callback the legacy
    # server-initiated request would have reached.
    # @param method [String] the input request's JSON-RPC method
    # @param params [Hash, nil] the input request's params
    # @return [void]
    def warn_input_request_deprecated(method, params)
      case method
      when 'roots/list' then warn_roots_deprecated
      when 'sampling/createMessage' then warn_sampling_deprecated(params)
      end
    end
  end
end
