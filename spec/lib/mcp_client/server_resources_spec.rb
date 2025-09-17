# frozen_string_literal: true

require 'spec_helper'

RSpec.shared_examples 'resource server methods' do
  let(:server) { described_class.new(**server_config) }

  describe '#list_resources' do
    context 'without pagination' do
      it 'returns a hash with resources array' do
        if server.is_a?(MCPClient::ServerStdio)
          # For ServerStdio, mock the lower-level request/response
          allow(server).to receive(:send_request)
          allow(server).to receive(:wait_response).and_return({
                                                                'result' => {
                                                                  'resources' => [
                                                                    { 'uri' => 'file:///test.txt',
                                                                      'name' => 'test.txt' },
                                                                    { 'uri' => 'file:///doc.md', 'name' => 'doc.md' }
                                                                  ]
                                                                }
                                                              })
        else
          allow(server).to receive(:rpc_request)
            .with('resources/list', {})
            .and_return({
                          'resources' => [
                            {
                              'uri' => 'file:///test.txt',
                              'name' => 'test.txt'
                            },
                            {
                              'uri' => 'file:///doc.md',
                              'name' => 'doc.md'
                            }
                          ]
                        })
        end

        result = server.list_resources
        expect(result).to be_a(Hash)
        expect(result['resources']).to be_an(Array)
        expect(result['resources'].size).to eq(2)
        expect(result['resources'].all? { |r| r.is_a?(MCPClient::Resource) }).to be true
        expect(result['nextCursor']).to be_nil
      end
    end

    context 'with pagination' do
      it 'includes cursor in request and returns nextCursor' do
        if server.is_a?(MCPClient::ServerStdio)
          allow(server).to receive(:send_request)
          allow(server).to receive(:wait_response).and_return({
                                                                'result' => {
                                                                  'resources' => [
                                                                    { 'uri' => 'file:///page2.txt',
                                                                      'name' => 'page2.txt' }
                                                                  ],
                                                                  'nextCursor' => 'def456'
                                                                }
                                                              })
        else
          allow(server).to receive(:rpc_request)
            .with('resources/list', { 'cursor' => 'abc123' })
            .and_return({
                          'resources' => [
                            {
                              'uri' => 'file:///page2.txt',
                              'name' => 'page2.txt'
                            }
                          ],
                          'nextCursor' => 'def456'
                        })
        end

        result = server.list_resources(cursor: 'abc123')
        expect(result['resources'].size).to eq(1)
        expect(result['nextCursor']).to eq('def456')
      end
    end
  end

  describe '#read_resource' do
    it 'returns array of ResourceContent objects' do
      if server.is_a?(MCPClient::ServerStdio)
        allow(server).to receive(:send_request)
        allow(server).to receive(:wait_response).and_return({
                                                              'result' => {
                                                                'contents' => [
                                                                  { 'uri' => 'file:///test.txt', 'name' => 'test.txt',
                                                                    'text' => 'Hello World' }
                                                                ]
                                                              }
                                                            })
      else
        allow(server).to receive(:rpc_request)
          .with('resources/read', { uri: 'file:///test.txt' })
          .and_return({
                        'contents' => [
                          {
                            'uri' => 'file:///test.txt',
                            'name' => 'test.txt',
                            'text' => 'Hello World'
                          }
                        ]
                      })
      end

      result = server.read_resource('file:///test.txt')
      expect(result).to be_an(Array)
      expect(result.size).to eq(1)
      expect(result.first).to be_a(MCPClient::ResourceContent)
      expect(result.first.text).to eq('Hello World')
    end

    it 'handles binary content' do
      blob_data = Base64.strict_encode64('binary_data')
      if server.is_a?(MCPClient::ServerStdio)
        allow(server).to receive(:send_request)
        allow(server).to receive(:wait_response).and_return({
                                                              'result' => {
                                                                'contents' => [
                                                                  { 'uri' => 'file:///image.png',
                                                                    'name' => 'image.png', 'blob' => blob_data }
                                                                ]
                                                              }
                                                            })
      else
        allow(server).to receive(:rpc_request)
          .with('resources/read', { uri: 'file:///image.png' })
          .and_return({
                        'contents' => [
                          {
                            'uri' => 'file:///image.png',
                            'name' => 'image.png',
                            'blob' => blob_data
                          }
                        ]
                      })
      end

      result = server.read_resource('file:///image.png')
      expect(result.first).to be_a(MCPClient::ResourceContent)
      expect(result.first.blob).to eq(blob_data)
      expect(result.first.binary?).to be true
    end
  end

  describe '#list_resource_templates' do
    context 'without pagination' do
      it 'returns a hash with resourceTemplates array' do
        if server.is_a?(MCPClient::ServerStdio)
          allow(server).to receive(:send_request)
          allow(server).to receive(:wait_response).and_return({
                                                                'result' => {
                                                                  'resourceTemplates' => [
                                                                    { 'uriTemplate' => 'file:///{path}',
                                                                      'name' => 'Project Files' }
                                                                  ]
                                                                }
                                                              })
        else
          allow(server).to receive(:rpc_request)
            .with('resources/templates/list', {})
            .and_return({
                          'resourceTemplates' => [
                            {
                              'uriTemplate' => 'file:///{path}',
                              'name' => 'Project Files'
                            }
                          ]
                        })
        end

        result = server.list_resource_templates
        expect(result).to be_a(Hash)
        expect(result['resourceTemplates']).to be_an(Array)
        expect(result['resourceTemplates'].size).to eq(1)
        expect(result['resourceTemplates'].first).to be_a(MCPClient::ResourceTemplate)
        expect(result['resourceTemplates'].first.uri_template).to eq('file:///{path}')
      end
    end

    context 'with pagination' do
      it 'includes cursor in request' do
        if server.is_a?(MCPClient::ServerStdio)
          allow(server).to receive(:send_request)
          allow(server).to receive(:wait_response).and_return({
                                                                'result' => {
                                                                  'resourceTemplates' => [],
                                                                  'nextCursor' => nil
                                                                }
                                                              })
        else
          allow(server).to receive(:rpc_request)
            .with('resources/templates/list', { 'cursor' => 'xyz789' })
            .and_return({
                          'resourceTemplates' => [],
                          'nextCursor' => nil
                        })
        end

        result = server.list_resource_templates(cursor: 'xyz789')
        expect(result['resourceTemplates']).to eq([])
        expect(result['nextCursor']).to be_nil
      end
    end
  end

  describe '#subscribe_resource' do
    it 'sends subscription request and returns true on success' do
      if server.is_a?(MCPClient::ServerStdio)
        allow(server).to receive(:send_request)
        allow(server).to receive(:wait_response).and_return({ 'result' => {} })
      else
        allow(server).to receive(:rpc_request).with('resources/subscribe',
                                                    { uri: 'file:///watched.txt' }).and_return({})
      end

      result = server.subscribe_resource('file:///watched.txt')
      expect(result).to be true
    end

    it 'raises ResourceReadError on failure' do
      if server.is_a?(MCPClient::ServerStdio)
        allow(server).to receive(:send_request)
        allow(server).to receive(:wait_response).and_raise(StandardError.new('Network error'))
      else
        allow(server).to receive(:rpc_request).and_raise(StandardError.new('Network error'))
      end

      expect do
        server.subscribe_resource('file:///error.txt')
      end.to raise_error(MCPClient::Errors::ResourceReadError, /Error subscribing to resource/)
    end
  end

  describe '#unsubscribe_resource' do
    it 'sends unsubscription request and returns true on success' do
      if server.is_a?(MCPClient::ServerStdio)
        allow(server).to receive(:send_request)
        allow(server).to receive(:wait_response).and_return({ 'result' => {} })
      else
        allow(server).to receive(:rpc_request).with('resources/unsubscribe',
                                                    { uri: 'file:///watched.txt' }).and_return({})
      end

      result = server.unsubscribe_resource('file:///watched.txt')
      expect(result).to be true
    end

    it 'raises ResourceReadError on failure' do
      if server.is_a?(MCPClient::ServerStdio)
        allow(server).to receive(:send_request)
        allow(server).to receive(:wait_response).and_raise(StandardError.new('Network error'))
      else
        allow(server).to receive(:rpc_request).and_raise(StandardError.new('Network error'))
      end

      expect do
        server.unsubscribe_resource('file:///error.txt')
      end.to raise_error(MCPClient::Errors::ResourceReadError, /Error unsubscribing from resource/)
    end
  end

  describe '#capabilities' do
    it 'returns server capabilities' do
      expected_capabilities = {
        'resources' => {
          'subscribe' => true,
          'listChanged' => true
        }
      }

      # For stdio, capabilities are stored as instance variable
      if server.is_a?(MCPClient::ServerStdio)
        server.instance_variable_set(:@capabilities, expected_capabilities)
      else
        # For SSE/HTTP servers, capabilities are already exposed via attr_reader
        allow(server).to receive(:capabilities).and_return(expected_capabilities)
      end

      expect(server.capabilities).to eq(expected_capabilities)
    end
  end
end

# Apply tests to each server type
RSpec.describe MCPClient::ServerStdio do
  let(:server_config) { { command: ['echo'], name: 'test_stdio' } }

  before do
    allow_any_instance_of(described_class).to receive(:ensure_initialized)
    allow_any_instance_of(described_class).to receive(:send_request)
    allow_any_instance_of(described_class).to receive(:wait_response) do |_, id|
      # Return a proper response based on the request
      { 'id' => id, 'result' => {} }
    end
  end

  it_behaves_like 'resource server methods'
end

RSpec.describe MCPClient::ServerSSE do
  let(:server_config) { { base_url: 'http://example.com/sse', name: 'test_sse' } }

  before do
    allow_any_instance_of(described_class).to receive(:ensure_initialized)
  end

  it_behaves_like 'resource server methods'
end

RSpec.describe MCPClient::ServerStreamableHTTP do
  let(:server_config) { { base_url: 'http://example.com', endpoint: '/rpc', name: 'test_streamable' } }

  before do
    allow_any_instance_of(described_class).to receive(:ensure_connected)
  end

  it_behaves_like 'resource server methods'
end
