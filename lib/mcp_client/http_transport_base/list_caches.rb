# frozen_string_literal: true

module MCPClient
  module HttpTransportBase
    # The transport's cached tool, prompt and resource lists: their
    # invalidation on the server's list-changed notifications (and on the
    # HeaderMismatch refresh), the generation counters that keep a fetch
    # already in flight when a list changed from putting its stale list
    # back, and the MCP 2026-07-28 exclusion of tools whose x-mcp-header
    # annotations are invalid.
    module ListCaches
      private

      # Drop the cached tool list and re-fetch it. Hosts layered above the
      # transport (MCPClient::Client) keep their own tool cache, so the refresh
      # is announced the way the server itself would: as a tools/list_changed
      # notification.
      # @return [void]
      def refresh_tools_cache
        invalidate_tools_cache
        list_tools
        @notification_callback&.call('notifications/tools/list_changed', {})
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
      end

      # @return [Integer] the current tool-list generation (bump on invalidation)
      def tools_generation
        @tools_generation ||= 0
      end

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
          return @tools = tools if tools_generation == generation

          # Invalidated while in flight: this list is stale even if nothing
          # newer was stored yet. Hand back whatever is current (nil makes the
          # caller fetch again).
          @tools
        end
      end

      # Keep the transport's list caches in step with the server's list-changed
      # notifications, so a re-list after a change (or the HeaderMismatch
      # refresh) really fetches the new definitions.
      # @param method [String] a notification method
      # @return [void]
      def invalidate_cache_for_notification(method)
        case method
        when 'notifications/tools/list_changed' then invalidate_tools_cache
        when 'notifications/prompts/list_changed' then invalidate_list_cache(:prompts)
        when 'notifications/resources/list_changed' then invalidate_list_cache(:resources)
        end
      end

      # Forget a cached prompt or resource list. Like the tool cache, each keeps
      # a generation counter so a fetch that was already in flight when the
      # list changed recognises that it is stale and does not put it back.
      # @param kind [Symbol] :prompts or :resources
      # @return [void]
      def invalidate_list_cache(kind)
        @mutex.synchronize do
          case kind
          when :prompts
            @prompts = nil
            @prompts_data = nil
          when :resources
            @resources_result = nil
            @resources_data = nil
          end
          list_generations[kind] += 1
        end
      end

      # @param kind [Symbol] :prompts or :resources
      # @return [Integer] the current generation of that list cache (call under @mutex)
      def list_generation(kind)
        list_generations[kind]
      end

      # @return [Hash{Symbol => Integer}] generation per list cache
      def list_generations
        @list_generations ||= Hash.new(0)
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
