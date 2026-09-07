# frozen_string_literal: true

module MCPClient
  # The tool definition a `tools/call` request went out under (MCP 2026-07-28
  # "Custom Headers from Tool Parameters"): the transport derives that
  # request's `Mcp-Param-*` headers from its tool list, so the definitions in
  # that list are the ones the call is made -- and answered -- under.
  #
  # A host that re-resolves the tool afterwards, to validate the result
  # against the definition the call actually carried, reads it from here
  # instead of listing again: on a list the server bounds with `ttlMs: 0` (or
  # one whose TTL expired during the call) another access re-fetches, and the
  # definition that comes back may not be the one the request went out with.
  #
  # Every call gets a slot of its own, so a nested exchange cannot overwrite
  # an outer call's definition: a Streamable HTTP response dispatches the
  # notifications it carries synchronously, and a listener may call another
  # tool on this very transport and thread before the outer call returns.
  #
  # The slots are kept per thread and per transport, in a stack named after
  # the transport's `object_id` so that
  # {MCPClient::ResultCaching#forget_transport_thread_state} drops it with
  # everything else a discarded transport left behind.
  module CalledToolDefinition
    private

    # Run one tools/call with a slot of its own for the definition its
    # request goes out under. What the call recorded is handed, when it
    # returns, to the caller still waiting for it -- never to an outer call
    # that already recorded its own -- and nothing is left on this thread
    # once the outermost call is over.
    # @yield the call
    # @return [Object] the block's value
    def recording_called_tool_definition
      stack = (Thread.current[called_tool_definition_key] ||= [])
      stack.push(nil)
      begin
        yield
      ensure
        finished = stack.pop
        stack[-1] = finished if finished && !stack.empty? && stack.last.nil?
        Thread.current[called_tool_definition_key] = nil if stack.empty?
      end
    end

    # The boundary a transport crosses when it hands control to host code: a
    # notification listener, a handler for a server-initiated request. A
    # `tools/call` that code issues -- the public `call_tool`, or a raw
    # `rpc_request('tools/call', ...)` naming the very tool the open call is
    # waiting on -- records into a slot of its own and nothing of it is handed
    # back out, so the call whose response is still being parsed keeps the
    # definition its own request went out under.
    # @yield the host code
    # @return [Object] the block's value
    def outside_called_tool_definition
      stack = (Thread.current[called_tool_definition_key] ||= [])
      stack.push(nil)
      begin
        yield
      ensure
        stack.pop
        Thread.current[called_tool_definition_key] = nil if stack.empty?
      end
    end

    # Remember the definition a tools/call request is going out under.
    # @param name [String] the tool named in the request
    # @param tool [MCPClient::Tool, nil] its definition in the list the
    #   request's headers were derived from (nil when that list no longer
    #   carries the tool at all)
    # @return [void]
    def note_called_tool_definition(name, tool)
      stack = (Thread.current[called_tool_definition_key] ||= [nil])
      stack[-1] = [name.to_s, tool]
    end

    # The definition the tools/call this caller is waiting on went out under.
    # Taken rather than read: it describes that one request, and leaving it
    # behind would keep a tool definition on this thread for as long as the
    # transport lives.
    # @param name [String] the tool being re-resolved
    # @return [Array(MCPClient::Tool, nil), nil] a one-element array holding
    #   the definition -- its element is nil when the list the request went
    #   out under no longer listed the tool -- or nil when no call of this
    #   caller's recorded a definition for that tool
    def take_called_tool_definition(name)
      stack = Thread.current[called_tool_definition_key]
      recorded = stack.is_a?(Array) ? stack.last : nil
      return nil unless recorded.is_a?(Array) && recorded.first == name.to_s

      stack[-1] = nil
      Thread.current[called_tool_definition_key] = nil if stack.size == 1
      [recorded.last]
    end

    # @return [Symbol] this transport's thread-local key for it
    def called_tool_definition_key
      :"mcp_client_called_tool_definition_#{object_id}"
    end

    # Pin the definition the HeaderMismatch retry was checked against, so
    # the retry's headers are derived from that very definition. Between
    # the check and the send the list would otherwise be looked up again,
    # and on a list the server bounds with `ttlMs: 0` another lookup is
    # another fetch — possibly of a definition the check never read.
    # @param name [String] the tool named in the retried request
    # @param tool [MCPClient::Tool, nil] the definition the check read (nil
    #   when the refreshed list no longer carries the tool)
    # @return [void]
    def pin_retry_definition(name, tool)
      Thread.current[pinned_retry_definition_key] = [name.to_s, tool]
    end

    # Take the pinned definition for a request, if the retry of that very
    # tool pinned one. Taken rather than read: it describes one send.
    # @param name [String] the tool named in the request being sent
    # @return [Array(MCPClient::Tool, nil), nil] a one-element array holding
    #   the definition, or nil when nothing is pinned for the tool
    def take_pinned_retry_definition(name)
      pinned = Thread.current[pinned_retry_definition_key]
      return nil unless pinned.is_a?(Array) && pinned.first == name.to_s

      Thread.current[pinned_retry_definition_key] = nil
      [pinned.last]
    end

    # Drop a pin the retry never consumed (it raised before sending).
    # @return [void]
    def clear_pinned_retry_definition
      Thread.current[pinned_retry_definition_key] = nil
    end

    # @return [Symbol] this transport's thread-local key for the pin
    def pinned_retry_definition_key
      :"mcp_client_pinned_retry_definition_#{object_id}"
    end
  end
end
