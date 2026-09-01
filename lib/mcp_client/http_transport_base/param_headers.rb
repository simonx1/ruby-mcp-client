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

      # MCP 2026-07-28 "Custom Headers from Tool Parameters": after a
      # HeaderMismatch the client SHOULD re-fetch tools/list (the tool's
      # inputSchema may have changed its x-mcp-header annotations) and retry
      # the original request once with the appropriate headers. The server
      # rejected the request before executing it, so the retry cannot
      # duplicate a side effect. A refresh that fails re-raises the rejection:
      # that is the actionable error.
      # @param error [MCPClient::Errors::HeaderMismatchError] the rejection
      # @return [void]
      def refresh_tools_after_header_mismatch(error)
        @logger.warn("#{sanitize_log_text(error.message)}; refreshing tools/list and retrying tools/call once")
        refresh_tools_cache
      rescue MCPClient::Errors::MCPError => e
        @logger.warn("tools/list refresh after HeaderMismatch failed: #{sanitize_log_text(e.message)}")
        raise error
      end

      # The Mcp-Param-* headers for a tools/call request (MCP 2026-07-28
      # "Custom Headers from Tool Parameters"): the annotated arguments of the
      # tool, looked up in this transport's tool list (fetched on demand so a
      # call issued before tools/list still carries them).
      # @param request [Hash] the JSON-RPC request
      # @return [Hash{String => String}]
      # @raise [MCPClient::Errors::ValidationError] when an annotated argument cannot be mirrored
      def mcp_param_headers(request)
        return {} unless request['method'] == 'tools/call'

        params = request['params']
        return {} unless params.is_a?(Hash)

        name = (params['name'] || params[:name]).to_s
        tool = known_tools_for_headers.find { |t| t.name.to_s == name }
        return {} unless tool

        MCPClient::HeaderParams.headers_for(tool.schema, params['arguments'] || params[:arguments])
      end

      # The tool list used for header extraction, fetched on demand. Mirroring
      # is a MUST, so a list that cannot be fetched fails the call rather than
      # letting it go out without the headers an intermediary may route on.
      # @return [Array<MCPClient::Tool>]
      def known_tools_for_headers
        fresh_list_value(:tools) { @mutex.synchronize { @tools } } || list_tools
      end
    end
  end
end
