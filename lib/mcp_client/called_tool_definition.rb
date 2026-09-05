# frozen_string_literal: true

module MCPClient
  # The tool definition a `tools/call` request went out under (MCP 2026-07-28
  # Streamable HTTP "Custom Headers from Tool Parameters"): the transport
  # derives that request's `Mcp-Param-*` headers from its tool list, so the
  # definition in that list is the one the call is made -- and answered --
  # under. A HeaderMismatch rejection re-derives them from a refreshed list,
  # which is why the answering definition may not be the one the host resolved
  # before the call.
  #
  # A host that re-resolves the tool afterwards, to validate the result
  # against the definition the call actually carried, reads it from here
  # rather than looking at the transport's current list: a
  # `notifications/tools/list_changed` that merely raced the call has already
  # replaced that list, and the server never saw the replacement.
  #
  # Every call gets a slot of its own, so a nested exchange cannot overwrite
  # an outer call's definition: a Streamable HTTP response dispatches the
  # server messages it carries synchronously, and a listener may call another
  # tool on this very transport and thread before the outer call returns.
  #
  # The slots are kept per thread and per transport, in a stack named after
  # the transport's `object_id`, and nothing is left on the thread once the
  # outermost slot is closed.
  module CalledToolDefinition
    private

    # Open a slot of its own for the definition a `tools/call` request goes
    # out under. Used at both ends of the boundary a transport crosses when
    # it hands control to host code:
    #
    # * around one call, so what the call records describes its own request
    #   -- the last attempt of it, which is the one the result answers;
    # * around a notification listener or a handler for a server-initiated
    #   request, so a `tools/call` that code issues while a response is still
    #   being parsed records into a slot of its own and nothing of it reaches
    #   the call that is waiting for that response.
    # @yield the call, or the host code
    # @return [Object] the block's value
    def called_tool_definition_slot
      stack = (Thread.current[called_tool_definition_key] ||= [])
      stack.push(nil)
      begin
        yield
      ensure
        stack.pop
        Thread.current[called_tool_definition_key] = nil if stack.empty?
      end
    end

    # Remember the definition a `tools/call` request is going out under. A
    # no-op when no caller opened a slot: nobody is waiting to read it.
    # @param name [String] the tool named in the request
    # @param tool [MCPClient::Tool, nil] its definition in the list the
    #   request's headers were derived from (nil when that list does not
    #   carry the tool at all)
    # @return [void]
    def note_called_tool_definition(name, tool)
      stack = Thread.current[called_tool_definition_key]
      return unless stack.is_a?(Array) && !stack.empty?

      stack[-1] = [name.to_s, tool]
    end

    # The definition the `tools/call` this caller is waiting on went out
    # under. Taken rather than read: it describes that one request, and
    # leaving it behind would keep a tool definition on this thread for as
    # long as the slot is open.
    # @param name [String] the tool being re-resolved
    # @return [Array(MCPClient::Tool, nil), nil] a one-element array holding
    #   the definition -- its element is nil when the list the request went
    #   out under did not carry the tool -- or nil when nothing was recorded
    #   for that tool in this caller's slot
    def take_called_tool_definition(name)
      stack = Thread.current[called_tool_definition_key]
      recorded = stack.is_a?(Array) ? stack.last : nil
      return nil unless recorded.is_a?(Array) && recorded.first == name.to_s

      stack[-1] = nil
      [recorded.last]
    end

    # @return [Symbol] this transport's thread-local key for the slot stack
    def called_tool_definition_key
      :"mcp_client_called_tool_definition_#{object_id}"
    end
  end
end
