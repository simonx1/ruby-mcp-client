# frozen_string_literal: true

require 'spec_helper'

# Tool calling in sampling (MCP 2025-11-25, SEP-1577) and sampling error codes.
#
# client/sampling.mdx § Tools in Sampling:
#   "Clients MUST declare support for tool use via the `sampling.tools`
#    capability to receive tool-enabled sampling requests."
# schema.ts CreateMessageRequestParams.tools / .toolChoice:
#   "The client MUST return an error if this field is provided but
#    ClientCapabilities.sampling.tools is not declared."
# client/sampling.mdx § Error Handling:
#   "Clients SHOULD return errors for common failure cases:
#    - User rejected sampling request: -1"
#   (so -1 is reserved for genuine rejections, not internal failures)
RSpec.describe 'Sampling tool use (MCP 2025-11-25, SEP-1577)' do
  let(:request_id) { 42 }
  let(:tools) do
    [
      {
        'name' => 'get_weather',
        'description' => 'Get current weather for a city',
        'inputSchema' => {
          'type' => 'object',
          'properties' => { 'city' => { 'type' => 'string' } },
          'required' => ['city']
        }
      }
    ]
  end
  let(:tool_params) do
    {
      'messages' => [
        { 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Weather in Paris and London?' } }
      ],
      'tools' => tools,
      'toolChoice' => { 'mode' => 'auto' },
      'maxTokens' => 1000
    }
  end

  describe 'capability declaration (sampling.tools)' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

    it 'declares plain sampling {} when tool use is not opted into' do
      server.on_sampling_request { |_id, _params| {} }

      caps = server.send(:initialization_params)['capabilities']
      expect(caps['sampling']).to eq({})
    end

    it 'declares sampling.tools when the transport opted into tool use' do
      server.on_sampling_request { |_id, _params| {} }
      server.declare_sampling_tools

      caps = server.send(:initialization_params)['capabilities']
      expect(caps['sampling']).to eq({ 'tools' => {} })
    end

    it 'does not declare sampling at all without a registered sampling callback' do
      server.declare_sampling_tools

      caps = server.send(:initialization_params)['capabilities']
      expect(caps).not_to have_key('sampling')
    end

    it 'declares sampling.tools when Client.new is given sampling_supports_tools: true' do
      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'echo test' }],
        sampling_handler: ->(_messages) { {} },
        sampling_supports_tools: true
      )

      caps = client.servers.first.send(:initialization_params)['capabilities']
      expect(caps['sampling']).to eq({ 'tools' => {} })
    end

    it 'declares plain sampling {} from Client.new without the opt-in' do
      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'echo test' }],
        sampling_handler: ->(_messages) { {} }
      )

      caps = client.servers.first.send(:initialization_params)['capabilities']
      expect(caps['sampling']).to eq({})
    end
  end

  describe 'rejecting tool-enabled requests without sampling.tools' do
    # schema.ts: "The client MUST return an error if this field is provided
    # but ClientCapabilities.sampling.tools is not declared." The matching
    # error code per sampling.mdx § Error Handling is -32602 (Invalid params).
    it 'returns -32602 when tools are present but tool use was not opted into' do
      handler_called = false
      handler = lambda do |_messages|
        handler_called = true
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'ignored tools' } }
      end
      client = MCPClient::Client.new(sampling_handler: handler)

      result = client.send(:handle_sampling_request, request_id, tool_params)

      expect(result['error']['code']).to eq(-32_602)
      expect(result['error']['message']).to match(/sampling\.tools/)
      expect(handler_called).to be(false)
    end

    it 'returns -32602 when only toolChoice is provided without the capability' do
      client = MCPClient::Client.new(sampling_handler: ->(_messages) { {} })

      params = {
        'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }],
        'toolChoice' => { 'mode' => 'none' },
        'maxTokens' => 100
      }
      result = client.send(:handle_sampling_request, request_id, params)

      expect(result['error']['code']).to eq(-32_602)
    end

    it 'does not reject tool-free requests' do
      client = MCPClient::Client.new(
        sampling_handler: ->(_messages) { { 'content' => { 'type' => 'text', 'text' => 'Hello' } } }
      )

      params = {
        'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }],
        'maxTokens' => 100
      }
      result = client.send(:handle_sampling_request, request_id, params)

      expect(result).not_to have_key('error')
      expect(result['content']).to eq({ 'type' => 'text', 'text' => 'Hello' })
    end
  end

  describe 'forwarding tool params to the sampling handler' do
    it 'passes tools and toolChoice through to arity-5 handlers when supported' do
      received_extra = nil
      handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, extra|
        received_extra = extra
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
      end
      client = MCPClient::Client.new(sampling_handler: handler, sampling_supports_tools: true)

      client.send(:handle_sampling_request, request_id, tool_params)

      expect(received_extra['tools']).to eq(tools)
      expect(received_extra['toolChoice']).to eq({ 'mode' => 'auto' })
    end

    it 'passes the complete params hash (including _meta and future fields) to the handler' do
      received_extra = nil
      handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, extra|
        received_extra = extra
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
      end
      client = MCPClient::Client.new(sampling_handler: handler, sampling_supports_tools: true)

      client.send(:handle_sampling_request, request_id,
                  tool_params.merge('_meta' => { 'traceId' => 'trace-1' }, 'temperature' => 0.4))

      expect(received_extra['_meta']).to eq({ 'traceId' => 'trace-1' })
      expect(received_extra['temperature']).to eq(0.4)
      expect(received_extra['messages']).to eq(tool_params['messages'])
      expect(received_extra['maxTokens']).to eq(1000)
    end

    # Ruby reports negative arity for optional parameters, and normalizing it
    # to the minimum required count would starve an optional fifth parameter
    # of the raw params (including SEP-1577 tools/toolChoice).
    it 'passes the full params to a lambda with an optional fifth parameter' do
      received_extra = :not_called
      handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, extra = nil|
        received_extra = extra
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
      end
      client = MCPClient::Client.new(sampling_handler: handler, sampling_supports_tools: true)

      client.send(:handle_sampling_request, request_id, tool_params)

      expect(received_extra).to be_a(Hash)
      expect(received_extra['tools']).to eq(tools)
      expect(received_extra['toolChoice']).to eq({ 'mode' => 'auto' })
    end

    it 'passes the full five-argument list to a variadic handler' do
      received_args = nil
      handler = lambda do |messages, *rest|
        received_args = [messages, *rest]
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
      end
      client = MCPClient::Client.new(sampling_handler: handler, sampling_supports_tools: true)

      client.send(:handle_sampling_request, request_id, tool_params)

      expect(received_args.length).to eq(5)
      expect(received_args.first).to eq(tool_params['messages'])
      expect(received_args.last['tools']).to eq(tools)
    end

    it 'sizes optional-arity handlers by their acceptable count, not their required minimum' do
      received_max_tokens = :not_called
      handler = lambda do |_messages, _model_prefs, _system_prompt, max_tokens = :missing|
        received_max_tokens = max_tokens
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
      end
      client = MCPClient::Client.new(sampling_handler: handler)

      client.send(:handle_sampling_request, request_id, {
                    'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }],
                    'maxTokens' => 512
                  })

      expect(received_max_tokens).to eq(512)
    end

    it 'keeps the historical extra keys for tool-free requests' do
      received_extra = nil
      handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, extra|
        received_extra = extra
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
      end
      client = MCPClient::Client.new(sampling_handler: handler)

      client.send(:handle_sampling_request, request_id, {
                    'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }],
                    'includeContext' => 'thisServer',
                    'temperature' => 0.7,
                    'stopSequences' => ['END'],
                    'metadata' => { 'requestId' => 'abc-123' }
                  })

      expect(received_extra['includeContext']).to eq('thisServer')
      expect(received_extra['temperature']).to eq(0.7)
      expect(received_extra['stopSequences']).to eq(['END'])
      expect(received_extra['metadata']).to eq({ 'requestId' => 'abc-123' })
    end
  end

  describe 'tool-use responses (CreateMessageResult with ToolUseContent)' do
    let(:tool_use_content) do
      [
        { 'type' => 'tool_use', 'id' => 'call_abc123', 'name' => 'get_weather', 'input' => { 'city' => 'Paris' } },
        { 'type' => 'tool_use', 'id' => 'call_def456', 'name' => 'get_weather', 'input' => { 'city' => 'London' } }
      ]
    end

    it 'passes a tool_use content array through faithfully with stopReason toolUse' do
      handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, _extra|
        {
          'role' => 'assistant',
          'content' => tool_use_content,
          'model' => 'claude-3-sonnet-20240307',
          'stopReason' => 'toolUse'
        }
      end
      client = MCPClient::Client.new(sampling_handler: handler, sampling_supports_tools: true)

      result = client.send(:handle_sampling_request, request_id, tool_params)

      expect(result['role']).to eq('assistant')
      expect(result['content']).to eq(tool_use_content)
      expect(result['model']).to eq('claude-3-sonnet-20240307')
      expect(result['stopReason']).to eq('toolUse')
    end

    it 'defaults stopReason to toolUse when the handler returns tool_use content without one' do
      handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, _extra|
        { 'role' => 'assistant', 'content' => tool_use_content, 'model' => 'test-model' }
      end
      client = MCPClient::Client.new(sampling_handler: handler, sampling_supports_tools: true)

      result = client.send(:handle_sampling_request, request_id, tool_params)

      expect(result['stopReason']).to eq('toolUse')
    end

    it 'still defaults stopReason to endTurn for plain text content' do
      handler = ->(_messages) { { 'content' => { 'type' => 'text', 'text' => 'done' } } }
      client = MCPClient::Client.new(sampling_handler: handler)

      result = client.send(:handle_sampling_request, request_id, {
                             'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }]
                           })

      expect(result['stopReason']).to eq('endTurn')
    end
  end

  describe 'sampling error codes (F42)' do
    # sampling.mdx § Error Handling reserves -1 for "User rejected sampling
    # request"; an exception inside the host handler is not a user action, so
    # it must surface as -32603 (Internal error) instead.
    it 'reports a sampling handler exception as -32603, not -1' do
      handler = ->(_messages) { raise StandardError, 'boom' }
      client = MCPClient::Client.new(sampling_handler: handler)

      result = client.send(:handle_sampling_request, request_id, {
                             'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }]
                           })

      expect(result['error']['code']).to eq(-32_603)
      expect(result['error']['message']).to include('boom')
    end

    it 'reports the no-handler fallback as -32601 (method not found), not -1' do
      client = MCPClient::Client.new

      result = client.send(:handle_sampling_request, request_id, {
                             'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }]
                           })

      expect(result['error']['code']).to eq(-32_601)
      expect(result['error']['message']).to include('Sampling not supported')
    end

    it 'keeps -1 for a genuine host rejection (handler returns nil)' do
      client = MCPClient::Client.new(sampling_handler: ->(_messages) {})

      result = client.send(:handle_sampling_request, request_id, {
                             'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }]
                           })

      expect(result['error']['code']).to eq(-1)
      expect(result['error']['message']).to include('Sampling rejected')
    end
  end
end
