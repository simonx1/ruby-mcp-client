# frozen_string_literal: true

module MCPClient
  # The operations a transport may make a cache decision for, each wrapped in
  # a scope that reserves the evaluation of the host's `request_meta` for the
  # request the operation leads to (MCP 2026-07-28 server/utilities/caching:
  # a decision is weighed on the parameters the request will carry, and a
  # host callable that vends a one-time value is read once for the two).
  #
  # Prepended to the transports, so the reservation is a property of the
  # operation rather than of any path through it:
  #
  # * it is spent by the request the operation sends and by nothing else --
  #   a reconnect's handshake, the `subscriptions/listen` a reconnect
  #   re-opens, a `notifications/cancelled` for an abandoned request and a
  #   nested request a notification listener issues all read the host afresh
  #   ({MCPClient::JsonRpcCommon#request_meta_claim});
  # * it never outlives the operation, whichever way that ends -- a value
  #   returned, a reconnect or an initialization that raised, an error a
  #   caller swallowed -- because the scope drops it from an `ensure`.
  module RequestMetaScope
    # Each operation and the JSON-RPC method of the request it leads to.
    SCOPED_OPERATIONS = {
      list_tools: 'tools/list',
      list_prompts: 'prompts/list',
      list_resources: 'resources/list',
      list_resource_templates: 'resources/templates/list',
      read_resource: 'resources/read',
      get_prompt: 'prompts/get',
      call_tool: 'tools/call'
    }.freeze

    SCOPED_OPERATIONS.each do |operation, request_method|
      next if operation == :call_tool

      define_method(operation) do |*args, **kwargs, &block|
        holding_request_meta(request_method) { super(*args, **kwargs, &block) }
      end
    end

    # A call also gets a slot of its own for the tool definition its request
    # goes out under, so a nested exchange records into its own
    # ({MCPClient::CalledToolDefinition}).
    define_method(:call_tool) do |*args, **kwargs, &block|
      holding_request_meta(SCOPED_OPERATIONS[:call_tool]) do
        recording_called_tool_definition { super(*args, **kwargs, &block) }
      end
    end
  end
end
