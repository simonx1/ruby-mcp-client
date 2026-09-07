# frozen_string_literal: true

require_relative 'errors'

module MCPClient
  # Fulfilment of the input requests an `input_required` result carries
  # (MCP 2026-07-28 multi-round tool requests). Mixed into
  # {MCPClient::JsonRpcCommon}, whose host supplies the registered handlers.
  module InputRoundTrips
    # Input request methods and the transport callback that fulfils each.
    INPUT_REQUEST_HANDLERS = {
      'elicitation/create' => :@elicitation_request_callback,
      'sampling/createMessage' => :@sampling_request_callback,
      'roots/list' => :@roots_list_request_callback
    }.freeze

    # Fulfil every input request through the handler registered for its
    # method. There is no per-key error channel in InputResponses, so any
    # request this client cannot honour fails the whole round trip.
    #
    # The answers produced before the failure travel with the error
    # ({MCPClient::Errors::InputRequiredError#answered_so_far}): a request the
    # host already answered has been put to a person, and a caller that can
    # keep it — the tasks extension's poll loop — must not ask them again.
    # @param input_requests [Hash] the InputRequests map
    # @param result [Hash] the InputRequiredResult (for error data)
    # @return [Hash] the InputResponses map
    # @raise [MCPClient::Errors::InputRequiredError]
    def fulfil_input_requests(input_requests, result)
      unless input_requests.is_a?(Hash)
        raise MCPClient::Errors::InputRequiredError.new('Malformed InputRequiredResult: inputRequests is not an object',
                                                        data: result)
      end

      responses = {}
      input_requests.each do |key, request|
        responses[key] = fulfil_input_request(key, request, result)
      rescue MCPClient::Errors::InputRequiredError => e
        raise e.with_answered_so_far(responses)
      end
      responses
    end

    # @param key [String] the server-assigned request key
    # @param request [Hash] the input request ({ 'method' => ..., 'params' => ... })
    # @param result [Hash] the InputRequiredResult (for error data)
    # @return [Hash] the handler's result
    # @raise [MCPClient::Errors::InputRequiredError]
    def fulfil_input_request(key, request, result)
      shown_key = sanitize_log_text(key.to_s.inspect)
      unless request.is_a?(Hash) && request['method'].is_a?(String) &&
             (request['params'].nil? || request['params'].is_a?(Hash))
        raise MCPClient::Errors::InputRequiredError.new("Malformed input request #{shown_key} (method/params)",
                                                        data: result)
      end

      request_method = request['method']
      shown_method = sanitize_log_text(request_method.inspect)
      handler_ivar = INPUT_REQUEST_HANDLERS[request_method]
      unless handler_ivar
        raise MCPClient::Errors::InputRequiredError.new(
          "Unsupported input request method #{shown_method} for key #{shown_key}", data: result
        )
      end
      unless registered_callback?(handler_ivar)
        raise MCPClient::Errors::InputRequiredError.new(
          "Server requested #{shown_method} (key #{shown_key}) but no handler is registered for it " \
          '(the capability was not declared)', data: result
        )
      end

      if undeclared_sampling_tool_use?(request_method, request['params'])
        raise MCPClient::Errors::InputRequiredError.new(
          "Server requested tool-enabled #{shown_method} (key #{shown_key}) but the sampling.tools " \
          'capability was not declared', data: result
        )
      end

      begin
        response = instance_variable_get(handler_ivar).call(key, request['params'] || {})
      rescue StandardError => e
        # The exception text is host-internal; it stays in the local log.
        @logger.error("Handler for #{shown_method} (key #{shown_key}) raised: #{e.message}")
        raise MCPClient::Errors::InputRequiredError.new(
          "Handler for #{shown_method} (key #{shown_key}) failed", data: result
        )
      end
      unless response.is_a?(Hash)
        raise MCPClient::Errors::InputRequiredError.new(
          "Handler for #{shown_method} (key #{shown_key}) returned #{response.class}, expected a result object",
          data: result
        )
      end
      if (error = response['error'] || response[:error])
        message = error.is_a?(Hash) ? (error['message'] || error[:message]) : error
        raise MCPClient::Errors::InputRequiredError.new(
          "Handler for #{shown_method} (key #{shown_key}) failed: #{sanitize_log_text(message)}", data: result
        )
      end

      response
    end

    # SEP-1577 (sampling tool calling): a server MUST NOT send `tools` or
    # `toolChoice` to a client that did not declare the sampling.tools
    # sub-capability. On a server-initiated request the client answers -32602;
    # InputResponses has no per-request error channel, so on the multi
    # round-trip path the whole round trip fails instead — the sampler is
    # never invoked with a request this client never advertised support for.
    # @param method [String] the input request method
    # @param params [Hash, nil] the input request params
    # @return [Boolean] whether this is tool-enabled sampling without the declaration
    def undeclared_sampling_tool_use?(method, params)
      return false unless method == 'sampling/createMessage' && !sampling_tools_supported?

      params.is_a?(Hash) && (params.key?('tools') || params.key?('toolChoice'))
    end
  end
end
