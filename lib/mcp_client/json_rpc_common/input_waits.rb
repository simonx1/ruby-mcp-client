# frozen_string_literal: true

module MCPClient
  module JsonRpcCommon
    # The host's hand on a multi round-trip request that waits on an
    # interaction happening out of band (MCP 2026-07-28 client/elicitation
    # "URL Mode": "Clients SHOULD provide manual controls that let the user
    # retry or cancel the original request"): the pause before each retry of
    # a requestState-only answer is the host's to steer, it never runs past
    # the request timeout, and a stopped request resumes from the
    # continuation its error carries. Mixed into {MCPClient::JsonRpcCommon}.
    module InputWaits
      # What the host is told before each paced retry of a continuation that
      # asked for nothing (an out-of-band interaction still in progress): the
      # request, how many round trips it has taken, the pause about to be
      # taken, the server's requestState, the InputRequiredResult itself and
      # the seconds spent waiting so far.
      InputRequiredWait = Struct.new(:rpc_method, :round_trip, :delay, :request_state, :result, :elapsed,
                                     keyword_init: true)

      # Register the host's control over an out-of-band wait (MCP 2026-07-28
      # client/elicitation "URL Mode": "Clients SHOULD provide manual controls
      # that let the user retry or cancel the original request"). The block is
      # called with an {InputRequiredWait} before each paced retry of a
      # continuation that asked for nothing; it returns `:retry` to retry at
      # once, `:cancel` to stop with an {MCPClient::Errors::InputRequiredError}
      # the host can hand to {#resume_input_required} later, or anything else
      # to wait the pace and retry.
      # @param block [Proc] callback that receives an InputRequiredWait
      # @return [void]
      # An InputRequiredResult is defined only for tools/call, resources/read
      # and prompts/get (MCP 2026-07-28 basic/patterns/mrtr "Supported
      # Requests"). server/discover is not one of them, so an input_required
      # discover answer is invalid and MUST NOT be applied or cached: the probe
      # would otherwise adopt a protocol version out of an unfinished result
      # and hand that result back as the first heartbeat. The rejection is a
      # ModernServerError, not an InvalidResultError, because a server
      # answering server/discover with a 2026-07-28-only discriminator is
      # modern: the era is settled, so it must never be retried with the
      # initialize handshake, and MCPClient.connect must not send it on to the
      # legacy SSE and HTTP+POST transports either.
      # @param result [Hash] the server/discover result
      # @return [void]
      # @raise [MCPClient::Errors::ModernServerError] if the result is an InputRequiredResult
      def reject_input_required_discover!(result)
        return unless MCPClient::JsonRpcCommon.result_type(result) == 'input_required'

        raise MCPClient::Errors::ModernServerError,
              'Server answered server/discover with an input_required result; multi round-trip requests are ' \
              "only valid for #{MRTR_METHODS.join(', ')}"
      end

      def on_input_required_wait(&block)
        @input_required_wait_callback = block
      end

      # Resume a multi round-trip request from the continuation an
      # {MCPClient::Errors::InputRequiredError} carries: the original request
      # goes out again as a new request with the server's requestState echoed
      # and no inputResponses, and the round trip continues from there.
      # @param error [MCPClient::Errors::InputRequiredError] a resumable error
      # @param timeout [Numeric, nil] per-request timeout for the resumed request
      # @return [Object] the final (complete) result
      # @raise [ArgumentError] if the error carries no continuation
      def resume_input_required(error, timeout: nil)
        unless error.is_a?(MCPClient::Errors::InputRequiredError) && error.resumable?
          raise ArgumentError, 'the error carries no continuation to resume'
        end

        params = error.request_params.is_a?(Hash) ? error.request_params.dup : {}
        %w[inputResponses requestState].each do |key|
          params.delete(key)
          params.delete(key.to_sym)
        end
        params['requestState'] = error.request_state unless error.request_state.nil?
        ensure_initialized if respond_to?(:ensure_initialized, true)
        rpc_request(error.request_method, params, timeout: timeout)
      end

      private

      # The params for a multi round-trip retry: the original params plus the
      # fulfilled inputResponses and the server's requestState. Both fields
      # affect only this retry; the caller's params are not mutated.
      # @param params [Hash] the original params
      # @param result [Hash] the InputRequiredResult
      # @return [Hash]
      def retry_params_for(params, result)
        retry_params = (params.is_a?(Hash) ? params.dup : {})
        retry_params.delete('inputResponses')
        retry_params.delete(:inputResponses)
        retry_params.delete('requestState')
        retry_params.delete(:requestState)

        if result.key?('inputRequests')
          retry_params['inputResponses'] = fulfil_input_requests(result['inputRequests'], result)
        end
        state = result['requestState']
        retry_params['requestState'] = state unless state.nil?
        retry_params
      end

      # One pause of a continuation that asked for nothing, as the host steers
      # it. Returns the pace for the next such pause.
      # @param wait [InputRequiredWait] what the host is told
      # @param deadline [Float, nil] the request timeout on the wait clock
      # @param now [Float] the wait clock when the answer arrived
      # @return [Numeric] the next delay
      # @raise [MCPClient::Errors::InputRequiredError] cancelled, or the pause would pass the timeout
      def pace_input_round_trip(wait, deadline, now)
        decision = @input_required_wait_callback&.call(wait)
        return wait.delay if decision == :retry

        if decision == :cancel
          raise MCPClient::Errors::InputRequiredError.new(
            "#{wait.rpc_method} cancelled by the host while waiting for out-of-band input " \
            "(round trip #{wait.round_trip})", data: wait.result
          )
        end
        if deadline && now + wait.delay > deadline
          raise MCPClient::Errors::InputRequiredError.new(
            "#{wait.rpc_method} is still waiting for out-of-band input at the request timeout " \
            "(round trip #{wait.round_trip}); resume it from the continuation", data: wait.result
          )
        end

        sleep(wait.delay)
        [wait.delay * 2, INPUT_RETRY_MAX_DELAY].min
      end

      # @return [Float] the monotonic clock, in seconds, the out-of-band waits are bounded by
      def input_wait_clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
