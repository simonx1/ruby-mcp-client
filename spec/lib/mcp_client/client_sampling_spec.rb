# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Client, 'Sampling (MCP 2025-06-18)' do
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
        'modelPreferences' => { 'hints' => [{ 'name' => 'claude-3-sonnet' }] },
        'systemPrompt' => 'You are a helpful assistant.',
        'maxTokens' => 1024
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
      it 'calls the handler with messages' do
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
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Hello!' } }
        end

        client = described_class.new(sampling_handler: handler)
        client.send(:handle_sampling_request, request_id, params)

        expect(handler_called).to be true
      end

      it 'calls the handler with all parameters (arity 4)' do
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
        handler = ->(_messages) { nil }

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
                                          'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Hi' } }]
                                        })

      expect(result['role']).to eq('assistant')
      expect(result['content']['text']).to eq('Hello')
    end
  end
end
