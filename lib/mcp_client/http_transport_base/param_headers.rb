# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # MCP 2026-07-28 "Custom Headers from Tool Parameters" (SEP-2243): the
    # Mcp-Param-* headers a tools/call derives from its annotated arguments,
    # the clearing of that reserved namespace so a configured header cannot
    # stand in for an argument that was not sent, and the
    # refresh-tools-and-retry-once recovery a HeaderMismatch asks for.
    module ParamHeaders
      private

      # Attach the computed `Mcp-Param-*` headers (MCP 2026-07-28 "Custom
      # Headers from Tool Parameters"). On a modern session that namespace is
      # derived from the call's arguments and from nothing else -- the client
      # MUST omit the header for an argument that is absent or null -- so a
      # configured header of that name is cleared first: leaving it would let
      # it stand for an argument the extraction omitted, which no tools/list
      # refresh can correct. The clearing matches HTTP's case-insensitive field
      # names, whatever spelling the host configured.
      # @param req [Faraday::Request] the outgoing request
      # @param param_headers [Hash{String => String}] the computed headers
      # @return [void]
      def apply_param_headers(req, param_headers)
        if modern?
          # The names are collected before any is dropped: the header set is
          # being mutated.
          configured = req.headers.keys.select { |name| MCPClient::HeaderParams.mirrored_header?(name) }
          configured.each { |name| req.headers.delete(name) }
        end
        param_headers.each { |k, v| req.headers[k] = v }
      end
    end
  end
end
