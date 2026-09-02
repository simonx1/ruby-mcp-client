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
    # Serving a roots/list request. The Roots capability counts as USED only
    # when the answer actually carries a root: a transport's roots handler is
    # registered independently of whether the host ever configured a root —
    # {MCPClient::Client} registers one on every server so a later `roots=`
    # is served, and answers with an empty list until a root is set — so a
    # registered handler is no evidence the host adopted the feature, while a
    # non-empty answer is. A host that never opted in must not be told it is
    # using a deprecated feature.
    # @param result [Hash, nil] the roots/list result about to be served
    # @return [void]
    def warn_roots_deprecated(result)
      roots = result.is_a?(Hash) ? (result['roots'] || result[:roots]) : nil
      return unless roots.is_a?(Array) && !roots.empty?

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
    # server-initiated request would have reached. Asking for a sample IS the
    # use of Sampling, so its notice is raised before the handler runs; Roots
    # is only used once the answer carries a root, so its notice waits for
    # {#warn_input_request_answer_deprecated}.
    # @param method [String] the input request's JSON-RPC method
    # @param params [Hash, nil] the input request's params
    # @return [void]
    def warn_input_request_deprecated(method, params)
      warn_sampling_deprecated(params) if method == 'sampling/createMessage'
    end

    # The half of the input-request notice that needs the handler's answer:
    # Roots is deprecated, but answering roots/list with no roots is not use
    # of it (see {#warn_roots_deprecated}).
    # @param method [String] the input request's JSON-RPC method
    # @param result [Hash, nil] the handler's result
    # @return [void]
    def warn_input_request_answer_deprecated(method, result)
      warn_roots_deprecated(result) if method == 'roots/list'
    end
  end
end
