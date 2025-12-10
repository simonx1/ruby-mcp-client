# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Client, 'Roots (MCP 2025-06-18)' do
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
    allow(mock_server).to receive(:rpc_notify)
  end

  describe '#initialize' do
    context 'when roots are provided' do
      it 'stores Root objects' do
        root = MCPClient::Root.new(uri: 'file:///path', name: 'Test')
        client = described_class.new(roots: [root])

        expect(client.roots).to eq([root])
      end

      it 'converts Hash roots to Root objects' do
        client = described_class.new(roots: [
                                       { uri: 'file:///path1', name: 'Root1' },
                                       { 'uri' => 'file:///path2', 'name' => 'Root2' }
                                     ])

        expect(client.roots.length).to eq(2)
        expect(client.roots[0]).to be_a(MCPClient::Root)
        expect(client.roots[0].uri).to eq('file:///path1')
        expect(client.roots[0].name).to eq('Root1')
        expect(client.roots[1].uri).to eq('file:///path2')
        expect(client.roots[1].name).to eq('Root2')
      end

      it 'raises error for invalid root types' do
        expect do
          described_class.new(roots: ['invalid'])
        end.to raise_error(ArgumentError, /Invalid root type/)
      end
    end

    context 'when roots are not provided' do
      it 'initializes with empty roots array' do
        client = described_class.new
        expect(client.roots).to eq([])
      end
    end

    context 'when server supports roots' do
      it 'registers roots list handler on servers' do
        expect(mock_server).to receive(:on_roots_list_request)

        described_class.new(
          mcp_server_configs: [{ type: 'stdio', command: 'test' }]
        )
      end
    end
  end

  describe '#roots=' do
    let(:client) do
      described_class.new(
        mcp_server_configs: [{ type: 'stdio', command: 'test' }]
      )
    end

    it 'updates the roots' do
      new_roots = [MCPClient::Root.new(uri: 'file:///new/path', name: 'New Root')]
      client.roots = new_roots

      expect(client.roots).to eq(new_roots)
    end

    it 'converts Hash roots to Root objects' do
      client.roots = [{ uri: 'file:///path', name: 'Test' }]

      expect(client.roots.first).to be_a(MCPClient::Root)
      expect(client.roots.first.uri).to eq('file:///path')
    end

    it 'sends roots/list_changed notification to servers' do
      expect(mock_server).to receive(:rpc_notify).with('notifications/roots/list_changed', {})

      client.roots = [{ uri: 'file:///path' }]
    end
  end

  describe '#handle_roots_list_request' do
    let(:root1) { MCPClient::Root.new(uri: 'file:///path1', name: 'Root1') }
    let(:root2) { MCPClient::Root.new(uri: 'file:///path2') }
    let(:client) { described_class.new(roots: [root1, root2]) }

    it 'returns roots as hash format' do
      result = client.send(:handle_roots_list_request, 123, {})

      expect(result).to eq({
                             'roots' => [
                               { 'uri' => 'file:///path1', 'name' => 'Root1' },
                               { 'uri' => 'file:///path2' }
                             ]
                           })
    end

    it 'returns empty roots when none are set' do
      client_without_roots = described_class.new

      result = client_without_roots.send(:handle_roots_list_request, 123, {})

      expect(result).to eq({ 'roots' => [] })
    end
  end
end
