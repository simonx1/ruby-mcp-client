# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Completion (MCP 2025-06-18)' do
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

  describe MCPClient::Client do
    describe '#complete' do
      let(:client) do
        described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }])
      end

      let(:ref) { { 'type' => 'ref/prompt', 'name' => 'my_prompt' } }
      let(:argument) { { 'name' => 'language', 'value' => 'py' } }
      let(:completion_result) do
        {
          'values' => %w[python pytho],
          'total' => 2,
          'hasMore' => false
        }
      end

      it 'delegates to the server' do
        allow(mock_server).to receive(:complete).and_return(completion_result)

        result = client.complete(ref: ref, argument: argument)

        expect(mock_server).to have_received(:complete).with(ref: ref, argument: argument)
        expect(result['values']).to eq(%w[python pytho])
      end

      it 'allows specifying a server' do
        allow(mock_server).to receive(:complete).and_return(completion_result)

        client.complete(ref: ref, argument: argument, server: 0)

        expect(mock_server).to have_received(:complete)
      end

      context 'when no server is available' do
        let(:empty_client) { described_class.new(mcp_server_configs: []) }

        it 'raises ServerNotFound' do
          expect do
            empty_client.complete(ref: ref, argument: argument)
          end.to raise_error(MCPClient::Errors::ServerNotFound)
        end
      end
    end
  end

  describe MCPClient::ServerStdio do
    describe '#complete' do
      let(:server) do
        described_class.new(command: 'test-command', logger: Logger.new(nil))
      end

      let(:ref) { { 'type' => 'ref/prompt', 'name' => 'my_prompt' } }
      let(:argument) { { 'name' => 'language', 'value' => 'py' } }

      before do
        allow(server).to receive(:ensure_initialized)
        allow(server).to receive(:next_id).and_return(1)
        allow(server).to receive(:send_request)
        allow(server).to receive(:wait_response).and_return({
                                                              'id' => 1,
                                                              'result' => {
                                                                'completion' => {
                                                                  'values' => %w[python pytho],
                                                                  'total' => 2,
                                                                  'hasMore' => false
                                                                }
                                                              }
                                                            })
      end

      it 'sends completion/complete request' do
        result = server.complete(ref: ref, argument: argument)

        expect(server).to have_received(:send_request).with(
          hash_including('method' => 'completion/complete')
        )
        expect(result['values']).to eq(%w[python pytho])
      end

      it 'returns empty values when completion is nil' do
        allow(server).to receive(:wait_response).and_return({ 'id' => 1, 'result' => {} })

        result = server.complete(ref: ref, argument: argument)

        expect(result['values']).to eq([])
      end

      it 'raises ServerError on error response' do
        allow(server).to receive(:wait_response).and_return({
                                                              'id' => 1,
                                                              'error' => { 'message' => 'Completion failed' }
                                                            })

        expect do
          server.complete(ref: ref, argument: argument)
        end.to raise_error(MCPClient::Errors::ServerError)
      end
    end
  end

  describe MCPClient::ServerSSE do
    describe '#complete' do
      let(:server) do
        described_class.new(base_url: 'http://example.com/sse', logger: Logger.new(nil))
      end

      let(:ref) { { 'type' => 'ref/resource', 'uri' => 'file:///path' } }
      let(:argument) { { 'name' => 'path', 'value' => '/home/user/' } }

      before do
        allow(server).to receive(:rpc_request).and_return({
                                                            'completion' => {
                                                              'values' => ['/home/user/documents', '/home/user/downloads'],
                                                              'hasMore' => true
                                                            }
                                                          })
      end

      it 'calls rpc_request with correct parameters' do
        result = server.complete(ref: ref, argument: argument)

        expect(server).to have_received(:rpc_request).with(
          'completion/complete',
          { ref: ref, argument: argument }
        )
        expect(result['values']).to eq(['/home/user/documents', '/home/user/downloads'])
        expect(result['hasMore']).to be true
      end

      it 'returns empty values when completion is nil' do
        allow(server).to receive(:rpc_request).and_return({})

        result = server.complete(ref: ref, argument: argument)

        expect(result['values']).to eq([])
      end
    end
  end

  describe MCPClient::ServerStreamableHTTP do
    describe '#complete' do
      let(:server) do
        described_class.new(base_url: 'http://example.com/mcp', logger: Logger.new(nil))
      end

      let(:ref) { { 'type' => 'ref/prompt', 'name' => 'greeting' } }
      let(:argument) { { 'name' => 'style', 'value' => 'for' } }

      before do
        allow(server).to receive(:rpc_request).and_return({
                                                            'completion' => {
                                                              'values' => %w[formal friendly],
                                                              'total' => 2
                                                            }
                                                          })
      end

      it 'calls rpc_request with correct parameters' do
        result = server.complete(ref: ref, argument: argument)

        expect(server).to have_received(:rpc_request).with(
          'completion/complete',
          { ref: ref, argument: argument }
        )
        expect(result['values']).to eq(%w[formal friendly])
        expect(result['total']).to eq(2)
      end

      it 'returns empty values when completion is nil' do
        allow(server).to receive(:rpc_request).and_return({})

        result = server.complete(ref: ref, argument: argument)

        expect(result['values']).to eq([])
      end
    end
  end
end
