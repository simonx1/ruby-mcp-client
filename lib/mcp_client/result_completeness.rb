# frozen_string_literal: true

module MCPClient
  # The guard an operation runs before it projects a payload out of a result.
  #
  # An unfinished answer (MCP 2026-07-28 InputRequiredResult) that reaches
  # such an operation would lose the server's inputRequests and its opaque
  # requestState, and would be presented as an empty successful answer. The
  # resolver that wraps every request drives the round trips a modern server
  # asks for, so what reaches here is either finished or something no
  # resolver claims; this is the backstop for the latter.
  module ResultCompleteness
    private

    # @param result [Object] the JSON-RPC result
    # @param method [String] the request method, for the message
    # @return [Object] the result, when it is complete
    # @raise [MCPClient::Errors::InputRequiredError] when it is unfinished --
    #   the whole result rides on the error's `data`, so a host can drive the
    #   round trip itself
    # @raise [MCPClient::Errors::InvalidResultError] for any other
    #   discriminator this client cannot carry through
    def require_complete_result!(result, method)
      type = MCPClient::JsonRpcCommon.result_type(result)
      return result if type == 'complete'

      message = "#{method} answered with resultType #{type.to_s[0, 64].inspect}, which this " \
                'client cannot carry through'
      raise MCPClient::Errors::InputRequiredError.new(message, data: result) if type == 'input_required'

      raise MCPClient::Errors::InvalidResultError.new("Invalid result: #{message}", data: result)
    end
  end
end
