# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Client, 'Sampling (MCP 2025-11-25)' do
  let(:mock_server) { instance_double(MCPClient::ServerStdio, name: 'stdio-server') }

  before do
    allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
    allow(mock_server).to receive(:on_notification)
    allow(mock_server).to receive(:respond_to?).with(:on_elicitation_request).and_return(true)
    allow(mock_server).to receive(:respond_to?).with(:on_roots_list_request).and_return(true)
    allow(mock_server).to receive(:respond_to?).with(:on_sampling_request).and_return(true)
    allow(mock_server).to receive(:on_elicitation_request)
    allow(mock_server).to receive(:on_roots_list_request)
    allow(mock_server).to receive(:on_sampling_request)
  end

  describe '#initialize' do
    context 'when sampling_handler is provided' do
      it 'stores the sampling handler' do
        handler = ->(_messages) { { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Hello' } } }
        client = described_class.new(sampling_handler: handler)

        expect(client.instance_variable_get(:@sampling_handler)).to eq(handler)
      end

      it 'registers sampling handler on servers that support it' do
        handler = ->(_messages) { { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Hello' } } }
        expect(mock_server).to receive(:on_sampling_request)

        described_class.new(
          mcp_server_configs: [{ type: 'stdio', command: 'test' }],
          sampling_handler: handler
        )
      end
    end

    context 'when sampling_handler is not provided' do
      it 'still registers handler on servers (for error response)' do
        expect(mock_server).to receive(:on_sampling_request)

        described_class.new(
          mcp_server_configs: [{ type: 'stdio', command: 'test' }]
        )
      end
    end

    context 'when server does not support sampling' do
      before do
        allow(mock_server).to receive(:respond_to?).with(:on_sampling_request).and_return(false)
      end

      it 'skips registration on servers that do not support sampling' do
        expect(mock_server).not_to receive(:on_sampling_request)

        described_class.new(
          mcp_server_configs: [{ type: 'stdio', command: 'test' }]
        )
      end
    end
  end

  describe '#handle_sampling_request' do
    let(:request_id) { 123 }
    let(:params) do
      {
        'messages' => [
          { 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hello, Claude!' } }
        ],
        'modelPreferences' => {
          'hints' => [{ 'name' => 'claude-3-sonnet' }],
          'costPriority' => 0.3,
          'speedPriority' => 0.8,
          'intelligencePriority' => 0.5
        },
        'systemPrompt' => 'You are a helpful assistant.',
        'maxTokens' => 1024,
        'includeContext' => 'thisServer',
        'temperature' => 0.7,
        'stopSequences' => ['END'],
        'metadata' => { 'requestId' => 'abc-123' }
      }
    end

    context 'when no sampling handler is configured' do
      let(:client) { described_class.new }

      it 'returns error response' do
        result = client.send(:handle_sampling_request, request_id, params)

        expect(result).to include('error')
        expect(result['error']['message']).to include('Sampling not supported')
      end
    end

    context 'when sampling handler is configured' do
      it 'calls the handler with messages (arity 1)' do
        handler_called = false
        handler = lambda do |messages|
          handler_called = true
          expect(messages).to be_an(Array)
          expect(messages.first['role']).to eq('user')
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Hello!' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, params)

        expect(handler_called).to be true
      end

      it 'calls the handler with messages and model preferences (arity 2)' do
        handler_called = false
        handler = lambda do |messages, model_prefs|
          handler_called = true
          expect(messages).to be_an(Array)
          expect(model_prefs['hints'].first['name']).to eq('claude-3-sonnet')
          expect(model_prefs['costPriority']).to eq(0.3)
          expect(model_prefs['speedPriority']).to eq(0.8)
          expect(model_prefs['intelligencePriority']).to eq(0.5)
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Hello!' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, params)

        expect(handler_called).to be true
      end

      it 'calls the handler with messages, model preferences, and system prompt (arity 3)' do
        handler_called = false
        handler = lambda do |messages, model_prefs, system_prompt|
          handler_called = true
          expect(messages).to be_an(Array)
          expect(model_prefs['hints'].first['name']).to eq('claude-3-sonnet')
          expect(system_prompt).to eq('You are a helpful assistant.')
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Hello!' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, params)

        expect(handler_called).to be true
      end

      it 'calls the handler with all core parameters (arity 4)' do
        handler_called = false
        handler = lambda do |messages, model_prefs, system_prompt, max_tokens|
          handler_called = true
          expect(messages).to be_an(Array)
          expect(model_prefs['hints'].first['name']).to eq('claude-3-sonnet')
          expect(system_prompt).to eq('You are a helpful assistant.')
          expect(max_tokens).to eq(1024)
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Hello!' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, params)

        expect(handler_called).to be true
      end

      it 'calls the handler with extended parameters (arity 5+)' do
        handler_called = false
        handler = lambda do |messages, model_prefs, system_prompt, max_tokens, extra|
          handler_called = true
          expect(messages).to be_an(Array)
          expect(model_prefs['hints'].first['name']).to eq('claude-3-sonnet')
          expect(system_prompt).to eq('You are a helpful assistant.')
          expect(max_tokens).to eq(1024)
          expect(extra['includeContext']).to eq('thisServer')
          expect(extra['temperature']).to eq(0.7)
          expect(extra['stopSequences']).to eq(['END'])
          expect(extra['metadata']).to eq({ 'requestId' => 'abc-123' })
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Hello!' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, params)

        expect(handler_called).to be true
      end

      it 'formats valid response correctly' do
        handler = lambda do |_messages|
          {
            'role' => 'assistant',
            'content' => { 'type' => 'text', 'text' => 'Test response' },
            'model' => 'claude-3-sonnet-20241022',
            'stopReason' => 'endTurn'
          }
        end

        client = described_class.new(sampling_handler: handler)
        result = client.send(:handle_sampling_request, request_id, params)

        expect(result['role']).to eq('assistant')
        expect(result['content']['text']).to eq('Test response')
        expect(result['model']).to eq('claude-3-sonnet-20241022')
        expect(result['stopReason']).to eq('endTurn')
      end

      it 'adds default values for missing fields' do
        handler = lambda do |_messages|
          { 'content' => { 'type' => 'text', 'text' => 'Test response' } }
        end

        client = described_class.new(sampling_handler: handler)
        result = client.send(:handle_sampling_request, request_id, params)

        expect(result['role']).to eq('assistant')
        expect(result['model']).to eq('unknown')
        expect(result['stopReason']).to eq('endTurn')
      end

      it 'converts string content to proper format' do
        handler = lambda do |_messages|
          { 'content' => 'Plain text response' }
        end

        client = described_class.new(sampling_handler: handler)
        result = client.send(:handle_sampling_request, request_id, params)

        expect(result['content']).to eq({ 'type' => 'text', 'text' => 'Plain text response' })
      end

      it 'converts symbol keys to string keys' do
        handler = lambda do |_messages|
          {
            role: 'assistant',
            content: { type: 'text', text: 'Test response' },
            model: 'claude-3-sonnet',
            stopReason: 'endTurn'
          }
        end

        client = described_class.new(sampling_handler: handler)
        result = client.send(:handle_sampling_request, request_id, params)

        expect(result['role']).to eq('assistant')
        expect(result['content'][:text]).to eq('Test response')
      end
    end

    context 'when handler returns nil' do
      it 'returns error response' do
        handler = ->(_messages) {}

        client = described_class.new(sampling_handler: handler)
        result = client.send(:handle_sampling_request, request_id, params)

        expect(result).to include('error')
        expect(result['error']['message']).to include('Sampling rejected')
      end
    end

    context 'when handler raises an exception' do
      it 'catches the exception and returns error' do
        handler = ->(_messages) { raise StandardError, 'Handler error' }

        client = described_class.new(sampling_handler: handler)
        result = client.send(:handle_sampling_request, request_id, params)

        expect(result).to include('error')
        expect(result['error']['message']).to include('Sampling error')
      end
    end
  end

  describe '#normalize_model_preferences' do
    let(:client) { described_class.new }

    it 'returns nil for nil input' do
      result = client.send(:normalize_model_preferences, nil)
      expect(result).to be_nil
    end

    it 'returns nil for non-hash input' do
      result = client.send(:normalize_model_preferences, 'invalid')
      expect(result).to be_nil
    end

    it 'normalizes hints array with name fields' do
      prefs = { 'hints' => [{ 'name' => 'claude-3-sonnet' }, { 'name' => 'gpt-4' }] }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['hints']).to eq([{ 'name' => 'claude-3-sonnet' }, { 'name' => 'gpt-4' }])
    end

    it 'filters out hints without name' do
      prefs = { 'hints' => [{ 'name' => 'claude-3-sonnet' }, { 'other' => 'value' }, 'invalid'] }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['hints']).to eq([{ 'name' => 'claude-3-sonnet' }])
    end

    it 'converts hint name to string' do
      prefs = { 'hints' => [{ 'name' => :claude_sonnet }] }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['hints']).to eq([{ 'name' => 'claude_sonnet' }])
    end

    it 'normalizes costPriority within 0.0 to 1.0' do
      prefs = { 'costPriority' => 0.5 }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['costPriority']).to eq(0.5)
    end

    it 'clamps costPriority above 1.0 to 1.0' do
      prefs = { 'costPriority' => 1.5 }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['costPriority']).to eq(1.0)
    end

    it 'clamps costPriority below 0.0 to 0.0' do
      prefs = { 'costPriority' => -0.5 }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['costPriority']).to eq(0.0)
    end

    it 'normalizes speedPriority' do
      prefs = { 'speedPriority' => 0.8 }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['speedPriority']).to eq(0.8)
    end

    it 'normalizes intelligencePriority' do
      prefs = { 'intelligencePriority' => 0.9 }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['intelligencePriority']).to eq(0.9)
    end

    it 'sets non-numeric priority to nil' do
      prefs = { 'costPriority' => 'high' }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['costPriority']).to be_nil
    end

    it 'handles all priority fields together' do
      prefs = {
        'hints' => [{ 'name' => 'claude-3-opus' }],
        'costPriority' => 0.2,
        'speedPriority' => 0.7,
        'intelligencePriority' => 1.0
      }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['hints']).to eq([{ 'name' => 'claude-3-opus' }])
      expect(result['costPriority']).to eq(0.2)
      expect(result['speedPriority']).to eq(0.7)
      expect(result['intelligencePriority']).to eq(1.0)
    end

    it 'handles integer priority values by converting to float' do
      prefs = { 'costPriority' => 1 }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result['costPriority']).to eq(1.0)
      expect(result['costPriority']).to be_a(Float)
    end

    it 'omits priority keys not present in input' do
      prefs = { 'hints' => [{ 'name' => 'model-a' }] }
      result = client.send(:normalize_model_preferences, prefs)

      expect(result).not_to have_key('costPriority')
      expect(result).not_to have_key('speedPriority')
      expect(result).not_to have_key('intelligencePriority')
    end
  end

  describe 'extended sampling parameters' do
    let(:request_id) { 123 }

    context 'with includeContext parameter' do
      it 'passes includeContext in extra params for arity 5+ handlers' do
        received_extra = nil
        handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, extra|
          received_extra = extra
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, {
                      'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }],
                      'includeContext' => 'allServers'
                    })

        expect(received_extra['includeContext']).to eq('allServers')
      end
    end

    context 'with temperature parameter' do
      it 'passes temperature in extra params' do
        received_extra = nil
        handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, extra|
          received_extra = extra
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, {
                      'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }],
                      'temperature' => 0.9
                    })

        expect(received_extra['temperature']).to eq(0.9)
      end
    end

    context 'with stopSequences parameter' do
      it 'passes stopSequences in extra params' do
        received_extra = nil
        handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, extra|
          received_extra = extra
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, {
                      'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }],
                      'stopSequences' => %w[STOP END]
                    })

        expect(received_extra['stopSequences']).to eq(%w[STOP END])
      end
    end

    context 'with metadata parameter' do
      it 'passes metadata in extra params' do
        received_extra = nil
        handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, extra|
          received_extra = extra
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, {
                      'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }],
                      'metadata' => { 'source' => 'test', 'priority' => 'high' }
                    })

        expect(received_extra['metadata']).to eq({ 'source' => 'test', 'priority' => 'high' })
      end
    end

    context 'when extended params are absent' do
      it 'passes nil values in extra params hash' do
        received_extra = nil
        handler = lambda do |_messages, _model_prefs, _system_prompt, _max_tokens, extra|
          received_extra = extra
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, {
                      'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }]
                    })

        expect(received_extra['includeContext']).to be_nil
        expect(received_extra['temperature']).to be_nil
        expect(received_extra['stopSequences']).to be_nil
        expect(received_extra['metadata']).to be_nil
      end
    end
  end

  describe 'systemPrompt handling' do
    let(:request_id) { 123 }

    it 'passes systemPrompt to arity-3 handler' do
      received_prompt = nil
      handler = lambda do |_messages, _model_prefs, system_prompt|
        received_prompt = system_prompt
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
      end

      client = described_class.new(sampling_handler: handler)
      client.send(:handle_sampling_request, request_id, {
                    'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }],
                    'systemPrompt' => 'Be concise and accurate.'
                  })

      expect(received_prompt).to eq('Be concise and accurate.')
    end

    it 'passes nil systemPrompt when not provided' do
      received_prompt = :not_set
      handler = lambda do |_messages, _model_prefs, system_prompt|
        received_prompt = system_prompt
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
      end

      client = described_class.new(sampling_handler: handler)
      client.send(:handle_sampling_request, request_id, {
                    'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }]
                  })

      expect(received_prompt).to be_nil
    end
  end

  describe 'sampling handler integration with servers' do
    it 'forwards handler method reference to server' do
      handler = ->(_messages) { { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Hello' } } }

      registered_callback = nil
      allow(mock_server).to receive(:on_sampling_request) do |&block|
        registered_callback = block
      end

      described_class.new(
        mcp_server_configs: [{ type: 'stdio', command: 'test' }],
        sampling_handler: handler
      )

      # Verify a callback was registered
      expect(registered_callback).not_to be_nil

      # Simulate server calling the registered callback
      result = registered_callback.call(456, {
                                          'messages' => [{
                                            'role' => 'user',
                                            'content' => { 'type' => 'text', 'text' => 'Hi' }
                                          }]
                                        })

      expect(result['role']).to eq('assistant')
      expect(result['content']['text']).to eq('Hello')
    end

    it 'passes full params including modelPreferences through server callback' do
      received_prefs = nil
      handler = lambda do |_messages, model_prefs|
        received_prefs = model_prefs
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'OK' } }
      end

      registered_callback = nil
      allow(mock_server).to receive(:on_sampling_request) do |&block|
        registered_callback = block
      end

      described_class.new(
        mcp_server_configs: [{ type: 'stdio', command: 'test' }],
        sampling_handler: handler
      )

      registered_callback.call(789, {
                                 'messages' => [{ 'role' => 'user',
                                                  'content' => { 'type' => 'text', 'text' => 'Hi' } }],
                                 'modelPreferences' => {
                                   'hints' => [{ 'name' => 'claude-3-opus' }],
                                   'costPriority' => 0.1,
                                   'speedPriority' => 0.3,
                                   'intelligencePriority' => 0.9
                                 }
                               })

      expect(received_prefs['hints']).to eq([{ 'name' => 'claude-3-opus' }])
      expect(received_prefs['costPriority']).to eq(0.1)
      expect(received_prefs['speedPriority']).to eq(0.3)
      expect(received_prefs['intelligencePriority']).to eq(0.9)
    end
  end
end
