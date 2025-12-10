# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Client, 'Elicitation (MCP 2025-06-18)' do
  let(:mock_stdio_server) { instance_double(MCPClient::ServerStdio, name: 'stdio-server') }
  let(:mock_sse_server) { instance_double(MCPClient::ServerSSE, name: 'sse-server') }
  let(:mock_http_server) { instance_double(MCPClient::ServerHTTP, name: 'http-server') }

  before do
    # Mock server creation
    allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_stdio_server)

    # Mock notification callbacks (required for initialization)
    allow(mock_stdio_server).to receive(:on_notification)
    allow(mock_sse_server).to receive(:on_notification)
    allow(mock_http_server).to receive(:on_notification)
  end

  describe '#initialize' do
    context 'when elicitation_handler is provided' do
      it 'stores the elicitation handler' do
        handler = ->(_message, _schema) { { 'action' => 'accept' } }
        client = described_class.new(elicitation_handler: handler)

        expect(client.instance_variable_get(:@elicitation_handler)).to eq(handler)
      end

      it 'registers elicitation handler on servers that support it' do
        handler = ->(_message, _schema) { { 'action' => 'accept' } }

        # Server supports elicitation, roots, and sampling
        allow(mock_stdio_server).to receive(:respond_to?).with(:on_elicitation_request).and_return(true)
        allow(mock_stdio_server).to receive(:respond_to?).with(:on_roots_list_request).and_return(true)
        allow(mock_stdio_server).to receive(:respond_to?).with(:on_sampling_request).and_return(true)
        allow(mock_stdio_server).to receive(:on_roots_list_request)
        allow(mock_stdio_server).to receive(:on_sampling_request)
        expect(mock_stdio_server).to receive(:on_elicitation_request)

        described_class.new(
          mcp_server_configs: [{ type: 'stdio', command: 'test' }],
          elicitation_handler: handler
        )
      end

      it 'skips registration on servers that do not support elicitation' do
        handler = ->(_message, _schema) { { 'action' => 'accept' } }

        # Use a generic double instead of instance_double to avoid method checking
        non_elicitation_server = double('non-elicitation-server', name: 'http-server')

        # Server does not support elicitation, roots, or sampling (e.g., HTTP)
        allow(non_elicitation_server).to receive(:respond_to?).with(:on_elicitation_request).and_return(false)
        allow(non_elicitation_server).to receive(:respond_to?).with(:on_roots_list_request).and_return(false)
        allow(non_elicitation_server).to receive(:respond_to?).with(:on_sampling_request).and_return(false)
        allow(non_elicitation_server).to receive(:on_notification)
        allow(MCPClient::ServerFactory).to receive(:create).and_return(non_elicitation_server)

        # Should not attempt to register
        expect(non_elicitation_server).not_to receive(:on_elicitation_request)

        described_class.new(
          mcp_server_configs: [{ type: 'http', base_url: 'http://example.com' }],
          elicitation_handler: handler
        )
      end

      it 'registers on multiple servers' do
        handler = ->(_message, _schema) { { 'action' => 'accept' } }

        servers = [mock_stdio_server, mock_sse_server]
        call_count = 0

        allow(MCPClient::ServerFactory).to receive(:create) do
          server = servers[call_count]
          call_count += 1
          server
        end

        # Both servers support elicitation, roots, and sampling
        [mock_stdio_server, mock_sse_server].each do |server|
          allow(server).to receive(:respond_to?).with(:on_elicitation_request).and_return(true)
          allow(server).to receive(:respond_to?).with(:on_roots_list_request).and_return(true)
          allow(server).to receive(:respond_to?).with(:on_sampling_request).and_return(true)
          allow(server).to receive(:on_roots_list_request)
          allow(server).to receive(:on_sampling_request)
          expect(server).to receive(:on_elicitation_request)
        end

        described_class.new(
          mcp_server_configs: [
            { type: 'stdio', command: 'test1' },
            { type: 'sse', base_url: 'http://example.com' }
          ],
          elicitation_handler: handler
        )
      end
    end

    context 'when elicitation_handler is not provided' do
      it 'still registers handler on servers (for decline behavior)' do
        # Even without handler, we register the method so we can auto-decline
        allow(mock_stdio_server).to receive(:respond_to?).with(:on_elicitation_request).and_return(true)
        allow(mock_stdio_server).to receive(:respond_to?).with(:on_roots_list_request).and_return(true)
        allow(mock_stdio_server).to receive(:respond_to?).with(:on_sampling_request).and_return(true)
        allow(mock_stdio_server).to receive(:on_roots_list_request)
        allow(mock_stdio_server).to receive(:on_sampling_request)
        expect(mock_stdio_server).to receive(:on_elicitation_request)

        described_class.new(
          mcp_server_configs: [{ type: 'stdio', command: 'test' }]
        )
      end
    end
  end

  describe '#handle_elicitation_request' do
    let(:request_id) { 123 }
    let(:params) do
      {
        'message' => 'Enter your name:',
        'requestedSchema' => {
          'type' => 'object',
          'properties' => {
            'name' => { 'type' => 'string', 'description' => 'Your full name' }
          },
          'required' => ['name']
        }
      }
    end

    context 'when no elicitation handler is configured' do
      it 'declines the request' do
        client = described_class.new

        result = client.send(:handle_elicitation_request, request_id, params)

        expect(result).to eq({ 'action' => 'decline' })
      end

      it 'logs a warning' do
        client = described_class.new
        logger = client.instance_variable_get(:@logger)

        expect(logger).to receive(:warn).with('Received elicitation request but no handler configured, declining')

        client.send(:handle_elicitation_request, request_id, params)
      end
    end

    context 'when elicitation handler is configured' do
      let(:handler_response) { { 'action' => 'accept', 'content' => { 'name' => 'Alice' } } }
      let(:handler) do
        lambda do |message, schema|
          expect(message).to eq('Enter your name:')
          expect(schema).to eq(params['requestedSchema'])
          handler_response
        end
      end

      it 'calls the handler with message and schema' do
        client = described_class.new(elicitation_handler: handler)

        result = client.send(:handle_elicitation_request, request_id, params)

        expect(result).to eq({
                               'action' => 'accept',
                               'content' => { 'name' => 'Alice' }
                             })
      end

      it 'formats accept response correctly' do
        accept_handler = lambda do |_message, _schema|
          { 'action' => 'accept', 'content' => { 'name' => 'Bob' } }
        end

        client = described_class.new(elicitation_handler: accept_handler)
        result = client.send(:handle_elicitation_request, request_id, params)

        expect(result['action']).to eq('accept')
        expect(result['content']).to eq({ 'name' => 'Bob' })
      end

      it 'formats decline response correctly' do
        decline_handler = lambda do |_message, _schema|
          { 'action' => 'decline' }
        end

        client = described_class.new(elicitation_handler: decline_handler)
        result = client.send(:handle_elicitation_request, request_id, params)

        expect(result).to eq({ 'action' => 'decline' })
      end

      it 'formats cancel response correctly' do
        cancel_handler = lambda do |_message, _schema|
          { 'action' => 'cancel' }
        end

        client = described_class.new(elicitation_handler: cancel_handler)
        result = client.send(:handle_elicitation_request, request_id, params)

        expect(result).to eq({ 'action' => 'cancel' })
      end
    end

    context 'when handler raises an exception' do
      let(:error_handler) do
        lambda do |_message, _schema|
          raise StandardError, 'Handler error'
        end
      end

      it 'catches the exception and declines' do
        client = described_class.new(elicitation_handler: error_handler)

        result = client.send(:handle_elicitation_request, request_id, params)

        expect(result).to eq({ 'action' => 'decline' })
      end

      it 'logs the error' do
        client = described_class.new(elicitation_handler: error_handler)
        logger = client.instance_variable_get(:@logger)

        expect(logger).to receive(:error).with('Elicitation handler error: Handler error')

        client.send(:handle_elicitation_request, request_id, params)
      end
    end

    context 'with complex schema' do
      let(:complex_params) do
        {
          'message' => 'Enter deployment details:',
          'requestedSchema' => {
            'type' => 'object',
            'properties' => {
              'environment' => {
                'type' => 'string',
                'enum' => %w[development staging production],
                'description' => 'Target environment'
              },
              'version' => {
                'type' => 'string',
                'pattern' => '^v\\d+\\.\\d+\\.\\d+$',
                'description' => 'Version to deploy'
              },
              'confirmed' => {
                'type' => 'boolean',
                'default' => false,
                'description' => 'Confirm deployment'
              }
            },
            'required' => %w[environment version]
          }
        }
      end

      it 'passes complete schema to handler' do
        handler_called = false
        complex_handler = lambda do |message, schema|
          handler_called = true
          expect(message).to eq('Enter deployment details:')
          expect(schema['properties']['environment']['enum']).to eq(%w[development staging production])
          expect(schema['properties']['version']['pattern']).to eq('^v\\d+\\.\\d+\\.\\d+$')
          expect(schema['properties']['confirmed']['default']).to eq(false)
          expect(schema['required']).to eq(%w[environment version])
          { 'action' => 'accept',
            'content' => { 'environment' => 'staging', 'version' => 'v1.2.3', 'confirmed' => true } }
        end

        client = described_class.new(elicitation_handler: complex_handler)
        client.send(:handle_elicitation_request, request_id, complex_params)

        expect(handler_called).to be true
      end
    end
  end

  describe 'elicitation handler integration with servers' do
    it 'forwards handler method reference to server' do
      handler = ->(_message, _schema) { { 'action' => 'accept' } }

      allow(mock_stdio_server).to receive(:respond_to?).with(:on_elicitation_request).and_return(true)
      allow(mock_stdio_server).to receive(:respond_to?).with(:on_roots_list_request).and_return(true)
      allow(mock_stdio_server).to receive(:respond_to?).with(:on_sampling_request).and_return(true)
      allow(mock_stdio_server).to receive(:on_roots_list_request)
      allow(mock_stdio_server).to receive(:on_sampling_request)

      registered_callback = nil
      allow(mock_stdio_server).to receive(:on_elicitation_request) do |&block|
        registered_callback = block
      end

      described_class.new(
        mcp_server_configs: [{ type: 'stdio', command: 'test' }],
        elicitation_handler: handler
      )

      # Verify a callback was registered
      expect(registered_callback).not_to be_nil

      # Simulate server calling the registered callback
      result = registered_callback.call(456, {
                                          'message' => 'Test message',
                                          'requestedSchema' => {
                                            'type' => 'object',
                                            'properties' => {
                                              'test' => { 'type' => 'string' }
                                            }
                                          }
                                        })

      # Should receive the handler's response
      expect(result['action']).to eq('accept')
    end
  end
end
