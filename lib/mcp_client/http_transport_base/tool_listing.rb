# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # The tool list an HTTP transport keeps, and everything derived from it:
    # its generation counter (which tells a host that a mid-call refresh
    # changed the definitions), the fetch that fills it, the invalidation a
    # list_changed notification triggers, and the Mcp-Param-* headers a
    # tools/call carries (MCP 2026-07-28 "Custom Headers from Tool
    # Parameters") -- including the HeaderMismatch refresh-and-retry.
    module ToolListing
      private

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

      # MCP 2026-07-28 basic "Implementation Requirements": a client "MUST
      # handle unsupported dialects gracefully by returning an appropriate
      # error indicating the dialect is not supported" — and, having done
      # so, must not go on to act on the schema. MCPClient::Client refuses
      # the dialect of the definition a call is prepared from, but the
      # HeaderMismatch retry goes out under the definition the refresh
      # brought instead, which this client never resolved. The rejection
      # means the server did not execute the first attempt, so refusing the
      # retry keeps the invariant the check is for: the call is never sent
      # under a schema nothing could read.
      # @param params [Hash] the tools/call params being re-sent
      # @return [void]
      # @raise [MCPClient::Errors::ValidationError] when the refreshed input
      #   schema declares a dialect this client does not implement
      def reject_unreadable_refreshed_schema!(params)
        return unless params.is_a?(Hash)

        name = (params['name'] || params[:name]).to_s
        tool = known_tools_for_headers.find { |t| t.name.to_s == name }
        dialect = tool && MCPClient::SchemaValidator.unsupported_dialect(tool.schema)
        return unless dialect

        raise MCPClient::Errors::ValidationError,
              "Tool #{sanitize_log_text(name.inspect)} input schema declares the JSON Schema dialect " \
              "#{sanitize_log_text(dialect.inspect)[0, 128]}: that dialect is not supported " \
              "(supported: #{MCPClient::SchemaValidator::SUPPORTED_DIALECTS.join(', ')})"
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
        # The list the headers come from is the list this request goes out
        # under: a host re-resolving the tool after the call reads that
        # definition back instead of asking for a possibly newer one.
        note_called_tool_definition(name, tool)
        return {} unless tool

        MCPClient::HeaderParams.headers_for(tool.schema, params['arguments'] || params[:arguments])
      end

      # The tool list used for header extraction, fetched on demand. Mirroring
      # is a MUST, so a list that cannot be fetched fails the call rather than
      # letting it go out without the headers an intermediary may route on.
      #
      # That fetch is an exchange of its own, with a recovery of its own (its
      # one re-issue, its own with_retry attempts), and it runs inside the
      # call's recovery block: an error escaping it is marked so the call does
      # not mistake it for its own rejection or lost stream and spend the one
      # re-issue or refresh it has on a request that never went out.
      # @return [Array<MCPClient::Tool>]
      # @raise [MCPClient::Errors::MCPError] the list's own failure, marked NestedExchange
      def known_tools_for_headers
        fresh_list_value(:tools) { @mutex.synchronize { @tools } } || list_tools
      rescue StandardError => e
        e.extend(RequestRecovery::NestedExchange) unless e.frozen?
        raise
      end

      # Drop the cached tool list and re-fetch it. Hosts layered above the
      # transport (MCPClient::Client) keep their own tool cache, so the refresh
      # is announced the way the server itself would: as a tools/list_changed
      # notification.
      # @return [void]
      def refresh_tools_cache
        invalidate_tools_cache
        list_tools
      ensure
        announce_tools_list_changed
      end

      # Tell the host its own copy is gone. This runs whether or not the
      # re-fetch that followed the invalidation succeeded: the transport's
      # list is already dropped by then, so a host that kept its copy would go
      # on calling with definitions this client has thrown away, and it would
      # never learn otherwise -- the server sends no notification for a
      # refresh the client started. A listener that raises is the host's
      # problem, not the caller's: the rejection that started the refresh is
      # what the caller must see.
      # @return [void]
      def announce_tools_list_changed
        # Announced on both hooks, in the order routing uses them, so a host
        # whose cache invalidation runs ahead of subscription deliveries is
        # told here too (see {MCPClient::ServerBase#on_cache_invalidation}).
        notify_cache_invalidation('notifications/tools/list_changed', {})
        @notification_callback&.call('notifications/tools/list_changed', {})
      rescue StandardError => e
        @logger.warn("Tool list invalidation listener failed: #{sanitize_log_text("#{e.class}: #{e.message}")}")
      end

      # Forget the cached tool list. The generation counter lets a list fetch
      # that was already in flight recognise that it is stale and not
      # overwrite a fresher list.
      # @return [void]
      def invalidate_tools_cache
        @mutex.synchronize do
          @tools = nil
          @tools_data = nil
          @tools_generation = tools_generation + 1
        end
        # The cached entry (which carries the list too) is stale as well.
        invalidate_cache(:tools)
      end

      # @return [Integer] the current tool-list generation (bump on invalidation)
      def tools_generation
        @tools_generation ||= 0
      end
      public :tools_generation

      # Fetch and cache the tool list, re-fetching when the cache was
      # invalidated while the fetch was in flight (bounded).
      # @return [Array<MCPClient::Tool>]
      def fetch_tools_list
        3.times do
          generation = @mutex.synchronize { tools_generation }
          tools_data = request_tools_list
          # MCP 2026-07-28: tools with invalid x-mcp-header annotations are
          # excluded from the list on this transport.
          tools_data = reject_invalid_header_tools(tools_data) if modern?
          tools = tools_data.map { |tool_data| MCPClient::Tool.from_json(tool_data, server: self) }
          stored = store_tools(tools, generation)
          return stored if stored
        end
        raise MCPClient::Errors::TransportError, 'tools/list kept changing while it was being fetched'
      end

      # Store a freshly fetched tool list unless the cache was invalidated
      # while it was being fetched, in which case the fresher list wins.
      # @param tools [Array<MCPClient::Tool>] the fetched list
      # @param generation [Integer] tools_generation when the fetch started
      # @return [Array<MCPClient::Tool>] the list to hand to the caller
      def store_tools(tools, generation)
        @mutex.synchronize do
          if tools_generation == generation
            # A copy is kept only when its hint was attached (or the list
            # carried none): a fetch whose entry was cleared or replaced in
            # flight leaves nothing behind, so the next access fetches again.
            previous = @tools
            @tools = attach_list_value(:tools, tools) ? tools : nil
            # A re-fetch that brought different definitions (an expired ttlMs
            # during a tools/call) is a change the host must see: a client
            # re-resolves a tool for post-call validation only when the
            # generation moves, and would otherwise check the result against
            # the definition the call was not answered under.
            @tools_generation = tools_generation + 1 if tool_definitions_changed?(previous, tools)
            return tools
          end

          # Invalidated while in flight: this list is stale even if nothing
          # newer was stored yet, and whatever is current may be another
          # request's list — nil makes the caller fetch again.
          nil
        end
      end

      # Drop the transport's cached list of a kind, so a re-list after a change
      # (or the HeaderMismatch refresh) really fetches the new definitions.
      # @param kind [Symbol] :tools, :prompts, :resources or :templates
      # @return [void]
      def invalidate_list_cache(kind)
        case kind
        when :tools then invalidate_tools_cache
        when :prompts
          @mutex.synchronize do
            @prompts = nil
            @prompts_data = nil
          end
        when :resources
          @mutex.synchronize do
            @resources_result = nil
            @resources_data = nil
          end
        when :templates
          # resources/list_changed covers resources/templates/list too: the
          # old templates are stale, and holding them keeps a list the next
          # fetch will replace alive for the life of the connection.
          @mutex.synchronize { @templates_result = nil }
        end
      end

      # Exclude tool definitions whose x-mcp-header annotations violate the
      # transport constraints (MCP 2026-07-28: "Rejection means the client
      # MUST exclude the invalid tool from the result of tools/list"), logging
      # a warning with the tool name and the reason.
      # @param tools_data [Array<Hash>] raw tool definitions
      # @return [Array<Hash>] the acceptable definitions
      def reject_invalid_header_tools(tools_data)
        tools_data.reject do |data|
          schema = data['inputSchema'] || data[:inputSchema] || data['schema'] || data[:schema]
          errors = MCPClient::HeaderParams.validate_schema(schema)
          next false if errors.empty?

          name = data['name'] || data[:name]
          @logger.warn("Rejecting tool #{sanitize_log_text(name.to_s.inspect)}: invalid x-mcp-header annotation: " \
                       "#{sanitize_log_text(errors.join('; '))}")
          true
        end
      end
    end
  end
end
