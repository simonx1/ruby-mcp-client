# frozen_string_literal: true

module MCPClient
  class Client
    # Listing across the client's servers: the per-server fetch loops that
    # fill the client's slices of a list cache, and the bookkeeping the
    # MCP 2026-07-28 caching rules put around them.
    #
    # A listing weighs its cache decision on the effective parameters the
    # fetch would carry, which evaluates the host's `request_meta` callable;
    # the transports hold that evaluation for the fetch the decision leads
    # to, so the request goes out with exactly what was weighed. That
    # reservation is opened here, for every server, and closed here from an
    # `ensure`: a fetch that raises during a reconnect, an authorization
    # error a caller catches, a server the loop never reaches -- none of them
    # can leave an evaluation on this worker thread for some later, unrelated
    # request to send.
    module ListAggregation
      private

      # Reserve, on every server, the evaluation of the host `request_meta`
      # for the request this listing leads to -- for the listing and no
      # longer.
      # @param method [String] the JSON-RPC method the listing's fetch sends
      # @yield the listing
      # @return [Object] the block's value
      def holding_request_meta(method)
        holders = servers.select { |server| server.respond_to?(:open_request_meta_hold, true) }
        holders.each { |server| server.send(:open_request_meta_hold, method) }
        begin
          yield
        ensure
          holders.each { |server| server.send(:close_request_meta_hold) }
        end
      end

      # A freshness check reads the parameters each server's next request
      # would carry, which evaluates a host `request_meta` callable; the
      # transports hold that evaluation for the fetch the check decides on.
      # Nothing is fetched after a snapshot is served, so the held metadata is
      # dropped instead of being sent by some later request.
      # @return [void]
      def release_held_request_meta
        servers.each do |server|
          server.send(:release_held_request_meta) if server.respond_to?(:release_held_request_meta, true)
        end
      end

      # The effective-parameter fingerprint a server's next request would
      # carry, read before a fetch so its slice of the cache is tagged with
      # the parameters of the list it holds (never with a leftover of whatever
      # request ran last on this thread).
      # @param server [MCPClient::ServerBase]
      # @return [String, nil]
      def params_fingerprint_for(server)
        return nil unless server.respond_to?(:current_params_fingerprint, true)

        server.send(:current_params_fingerprint)
      end

      # A forced refresh (`cache: false`) must really re-list. A transport
      # keeps a list the server bounded with a positive `ttlMs` and answers
      # from it without sending anything at all (MCP 2026-07-28
      # server/utilities/caching), so the entry that bounds it is dropped
      # first and the fetch reaches the server.
      # @param server [MCPClient::ServerBase]
      # @param kind [Symbol] :tools, :prompts or :resources
      # @return [void]
      def refresh_server_cache(server, kind)
        server.send(:invalidate_cache, kind) if server.respond_to?(:invalidate_cache, true)
        server.send(:invalidate_list_cache, kind) if server.respond_to?(:invalidate_list_cache, true)
      end

      # A call and the re-resolve that follows it share one slot for the
      # definition the request went out under, so a nested call (a listener
      # the response's notification dispatch runs) records into its own and
      # leaves this one alone.
      # @param server [MCPClient::ServerBase]
      # @yield the call and its validation
      # @return [Object] the block's value
      def with_called_tool_definition(server, &block)
        return block.call unless server.respond_to?(:recording_called_tool_definition, true)

        server.send(:recording_called_tool_definition, &block)
      end

      # @param cache [Boolean] whether a cached list may answer
      # @return [Array<MCPClient::Tool>]
      def collect_tools_from_servers(cache)
        tools = []
        connection_errors = []

        servers.each do |server|
          refresh_server_cache(server, :tools) unless cache
          # The parameters this fetch will carry are read before it goes out:
          # whatever request ran last on this thread says nothing about it.
          fingerprint = params_fingerprint_for(server)
          server_tools = server.list_tools
          # Replace this server's slice: an item the refreshed list no longer
          # carries must not linger from the previous fetch.
          replace_cached_slice(:tools, @tool_cache, server, fingerprint) do
            server_tools.each do |tool|
              @tool_cache[cache_key_for(server, tool.name)] = MCPClient::DeepCopy.copy(tool)
              tools << tool
            end
          end
        rescue MCPClient::Errors::ConnectionError => e
          # Fast-fail on authorization errors for better user experience
          # If this is the first server or we haven't collected any tools yet,
          # raise the auth error directly to avoid cascading error messages
          raise e if e.message.include?('Authorization failed') && tools.empty?

          # Store the error and try other servers
          connection_errors << e
          @logger.error("Server error: #{e.message}")
        end

        # If we didn't get any tools from any server but have servers configured, report failure
        if tools.empty? && !servers.empty?
          raise connection_errors.first if connection_errors.any?

          @logger.warn('No tools found from any server.')
        end

        tools
      end

      # @param cache [Boolean] whether a cached list may answer
      # @return [Array<MCPClient::Prompt>]
      def collect_prompts_from_servers(cache)
        prompts = []
        connection_errors = []

        servers.each do |server|
          refresh_server_cache(server, :prompts) unless cache
          fingerprint = params_fingerprint_for(server)
          server_prompts = server.list_prompts
          replace_cached_slice(:prompts, @prompt_cache, server, fingerprint) do
            server_prompts.each do |prompt|
              @prompt_cache[cache_key_for(server, prompt.name)] = MCPClient::DeepCopy.copy(prompt)
              prompts << prompt
            end
          end
        rescue MCPClient::Errors::ConnectionError => e
          # Fast-fail on authorization errors for better user experience
          raise e if e.message.include?('Authorization failed') && prompts.empty?

          connection_errors << e
          @logger.error("Server error: #{e.message}")
        end

        prompts
      end

      # @param cache [Boolean] whether a cached list may answer
      # @return [Hash] the aggregated resources result
      def collect_resources_from_servers(cache)
        resources = []
        connection_errors = []

        servers.each do |server|
          refresh_server_cache(server, :resources) unless cache
          fingerprint = params_fingerprint_for(server)
          result = server.list_resources
          resource_list = result['resources'] || []
          replace_cached_slice(:resources, @resource_cache, server, fingerprint) do
            resource_list.each do |resource|
              @resource_cache[cache_key_for(server, resource.uri)] = MCPClient::DeepCopy.copy(resource)
              resources << resource
            end
          end
        rescue MCPClient::Errors::ConnectionError => e
          # Fast-fail on authorization errors for better user experience
          raise e if e.message.include?('Authorization failed') && resources.empty?

          connection_errors << e
          @logger.error("Server error: #{e.message}")
        end

        # Return hash format consistent with server methods
        { 'resources' => resources, 'nextCursor' => nil }
      end
    end
  end
end
