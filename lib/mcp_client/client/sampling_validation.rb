# frozen_string_literal: true

module MCPClient
  class Client
    # The client's own handling of a server's sampling request: the shape the
    # 2026-07-28 specification requires of a message history before the host's
    # sampler is asked for a completion, and the refusal when it is not met.
    # Mixed into {MCPClient::Client}; every method is private there.
    module SamplingValidation
      private

      # Handle sampling/createMessage request from server (MCP 2025-11-25)
      # @param _request_id [String, Integer] the JSON-RPC request ID (unused, kept for callback signature)
      # @param params [Hash] the sampling parameters
      # @return [Hash] the sampling response (role, content, model, stopReason)
      def handle_sampling_request(_request_id, params)
        # Without a handler the sampling capability was never declared, so the
        # request targets an unsupported method: answer -32601 (Method not
        # found) rather than -1, which sampling.mdx § Error Handling reserves
        # for "User rejected sampling request".
        unless @sampling_handler
          @logger.warn('Received sampling request but no sampling handler is configured')
          return jsonrpc_error_result(-32_601, 'Sampling not supported: no sampling handler configured')
        end

        # SEP-1577 (schema.ts CreateMessageRequestParams.tools/.toolChoice):
        # "The client MUST return an error if this field is provided but
        # ClientCapabilities.sampling.tools is not declared." -32602 is the
        # Invalid params code used by sampling.mdx § Error Handling.
        if (params.key?('tools') || params.key?('toolChoice')) && !@sampling_supports_tools
          @logger.warn('Rejecting tool-enabled sampling request: sampling.tools capability not declared')
          return jsonrpc_error_result(-32_602,
                                      'Invalid params: tools/toolChoice provided but the sampling.tools ' \
                                      'capability was not declared')
        end

        messages = params['messages'] || []
        # Both parties SHOULD validate message content (sampling.mdx
        # "Security Considerations"): the role, the content, a user message of
        # tool results carrying nothing else, and every assistant tool use
        # answered by the message that follows it.
        if (problem = sampling_history_problem(messages))
          @logger.warn("Rejecting sampling request with a malformed history: #{problem}")
          return jsonrpc_error_result(-32_602, "Invalid params: #{problem}")
        end

        model_preferences = normalize_model_preferences(params['modelPreferences'])
        system_prompt = params['systemPrompt']
        max_tokens = params['maxTokens']

        begin
          # Call the user-defined handler with parameters based on arity
          result = call_sampling_handler(messages, model_preferences, system_prompt, max_tokens, params)

          # Validate and format response
          validate_sampling_response(result)
        rescue StandardError => e
          @logger.error("Sampling handler error: #{e.message}")
          @logger.debug(e.backtrace.join("\n"))
          # A handler exception is an internal client failure (-32603), not a
          # user rejection: sampling.mdx § Error Handling reserves -1 for
          # "User rejected sampling request". The exception message itself is
          # host-internal (file paths, connection strings, library internals)
          # and stays in the local log rather than crossing to the server.
          jsonrpc_error_result(-32_603, 'Sampling error')
        end
      end

      # What is wrong with a sampling history, if anything, by the rules of
      # MCP 2026-07-28 client/sampling: every message has a role of "user" or
      # "assistant" and content; a user message containing tool results
      # contains only tool results; every assistant message with tool uses is
      # followed by a user message consisting entirely of the matching tool
      # results before any other message.
      # @param messages [Array<Hash>] the sampling messages
      # @return [String, nil] the problem, nil when the history is well formed
      def sampling_history_problem(messages)
        return 'messages must be an array' unless messages.is_a?(Array)

        pending = nil
        messages.each_with_index do |message, index|
          problem, pending = sampling_message_problem(message, index, pending)
          return problem if problem
        end
        return "the last message leaves its tool uses (#{pending.join(', ')}) unanswered" if pending

        nil
      end

      # @param message [Object] a sampling message
      # @param index [Integer] its position
      # @param pending [Array<String>, nil] the tool use ids the previous message left to answer
      # @return [Array(String, nil), Array(nil, Array<String>)] the problem, or the tool uses now pending
      def sampling_message_problem(message, index, pending)
        blocks = sampling_message_blocks(message)
        return [sampling_shape_problem(message, index), nil] unless blocks

        role = message['role'] || message[:role]
        uses = blocks.select { |block| sampling_block_type(block) == 'tool_use' }
        results = blocks.select { |block| sampling_block_type(block) == 'tool_result' }
        return ["message #{index} carries tool uses in a #{role} message", nil] if uses.any? && role != 'assistant'

        if pending
          problem = sampling_tool_results_problem(index, role, blocks, results, pending)
          return [problem, nil] if problem
        elsif results.any? && results.size != blocks.size
          # The spec forbids the mixing, not a results-only message on its own:
          # a server may hand over the results without the history before them.
          return ["message #{index} mixes tool results with other content", nil]
        end
        [nil, (uses.map { |block| (block['id'] || block[:id]).to_s } if uses.any?)]
      end

      # @param index [Integer] the position of the message answering the tool uses
      # @param role [String] its role
      # @param blocks [Array<Hash>] its content blocks
      # @param results [Array<Hash>] the tool results among them
      # @param pending [Array<String>] the tool use ids to answer
      # @return [String, nil] the problem, nil when the message answers exactly those uses
      def sampling_tool_results_problem(index, role, blocks, results, pending)
        unless role == 'user' && results.size == blocks.size
          return "message #{index} must consist only of the tool results answering message #{index - 1}"
        end

        ids = results.map { |block| (block['toolUseId'] || block[:toolUseId]).to_s }
        return nil if ids.sort == pending.sort

        "message #{index} tool results do not match the tool uses of message #{index - 1}"
      end

      # Which half of the message's shape is wrong, so the host is told what to
      # look at: the envelope, or a content block that carries no meaning.
      # @param message [Object] a sampling message
      # @param index [Integer] its position
      # @return [String] the problem
      def sampling_shape_problem(message, index)
        blocks = message.is_a?(Hash) ? (message['content'] || message[:content]) : nil
        blocks = [blocks] if blocks.is_a?(Hash)
        if blocks.is_a?(Array)
          bad = blocks.find { |block| !sampling_block_well_formed?(block) }
          if bad
            type = sampling_block_type(bad)
            named = type ? "a #{type.inspect} content block" : 'a content block'
            return "message #{index} carries #{named} without the fields its type requires"
          end
        end
        "message #{index} must be an object with a role of \"user\" or \"assistant\" and content"
      end

      # @param message [Object] a sampling message
      # @return [Array<Hash>, nil] its content blocks, nil unless the message is well formed
      def sampling_message_blocks(message)
        return nil unless message.is_a?(Hash) && %w[user assistant].include?(message['role'] || message[:role])

        blocks = message['content'] || message[:content]
        blocks = [blocks] if blocks.is_a?(Hash)
        return nil unless blocks.is_a?(Array) && !blocks.empty?
        return nil unless blocks.all? { |block| sampling_block_well_formed?(block) }

        blocks
      end

      # The fields a content block of a known type must carry for the message
      # rules to mean anything: the text of a text block, the payload of an
      # image or audio block, and — the reason the correlation rules can be
      # checked at all — the identifier of a tool use and of the tool result
      # answering it. A type this client does not know is the host's to read,
      # not this client's to refuse: refusing it would break a session with a
      # server using a content type added after this release.
      # @param block [Object] a content block
      # @return [Boolean] whether the block can be handed to the host
      def sampling_block_well_formed?(block)
        type = sampling_block_type(block)
        return false unless type

        case type
        when 'text' then sampling_block_string?(block, 'text')
        when 'image', 'audio' then sampling_block_string?(block, 'data') && sampling_block_string?(block, 'mimeType')
        when 'tool_use' then sampling_block_string?(block, 'id')
        when 'tool_result' then sampling_block_string?(block, 'toolUseId')
        else true
        end
      end

      # @param block [Hash] a content block
      # @param field [String] the field it must carry
      # @return [Boolean] whether the field is a non-empty String
      def sampling_block_string?(block, field)
        value = block[field] || block[field.to_sym]
        value.is_a?(String) && !value.empty?
      end
    end
  end
end
