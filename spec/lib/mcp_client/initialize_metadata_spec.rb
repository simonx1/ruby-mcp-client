# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 lifecycle: the initialize exchange carries Implementation
# info both ways (clientInfo supports name/version plus the 2025-11-25
# fields title, description, websiteUrl, icons) and the server MAY return
# an `instructions` field ("a system prompt"-style hint for the host).
# The client hardcoded its own gem identity as clientInfo and silently
# dropped instructions on every transport.
RSpec.describe 'Initialize metadata (MCP 2025-11-25)' do
  describe 'custom clientInfo' do
    it 'lets the host provide its own Implementation info' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      server.client_info = {
        'name' => 'my-host-app',
        'version' => '2.0.0',
        'title' => 'My Host',
        'description' => 'An MCP-powered IDE'
      }

      info = server.send(:initialization_params)['clientInfo']
      expect(info).to eq(
        'name' => 'my-host-app',
        'version' => '2.0.0',
        'title' => 'My Host',
        'description' => 'An MCP-powered IDE'
      )
    end

    it 'defaults to the gem identity' do
      server = MCPClient::ServerStdio.new(command: 'echo test')

      info = server.send(:initialization_params)['clientInfo']
      expect(info).to eq('name' => 'ruby-mcp-client', 'version' => MCPClient::VERSION)
    end

    it 'requires name and version' do
      server = MCPClient::ServerStdio.new(command: 'echo test')

      expect { server.client_info = { 'name' => 'x' } }.to raise_error(ArgumentError, /version/)
      expect { server.client_info = { 'version' => '1' } }.to raise_error(ArgumentError, /name/)
    end

    it 'is configurable for all servers through the Client' do
      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'echo test' }],
        client_info: { 'name' => 'host', 'version' => '3.1.4' }
      )

      info = client.servers.first.send(:initialization_params)['clientInfo']
      expect(info).to eq('name' => 'host', 'version' => '3.1.4')
    end
  end

  describe 'server instructions exposure' do
    it 'stores and exposes instructions on Streamable HTTP' do
      base_url = 'https://example.com'
      server = MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: '/rpc')
      stub_request(:post, "#{base_url}/rpc")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(
          status: 200,
          body: "event: message\ndata: #{JSON.generate(
            jsonrpc: '2.0', id: 1,
            result: { protocolVersion: MCPClient::PROTOCOL_VERSION, capabilities: {},
                      serverInfo: { name: 's', version: '1' },
                      instructions: 'Use the search tool before answering.' }
          )}\n\n",
          headers: { 'Content-Type' => 'text/event-stream' }
        )
      stub_request(:post, "#{base_url}/rpc")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, body: '')
      stub_request(:get, "#{base_url}/rpc").to_return(status: 200, body: '')

      server.connect
      expect(server.instructions).to eq('Use the search tool before answering.')
      server.cleanup
    end

    it 'stores and exposes instructions on stdio' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      allow(server).to receive(:next_id).and_return(1)
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response).and_return(
        { 'result' => { 'protocolVersion' => MCPClient::PROTOCOL_VERSION,
                        'capabilities' => {}, 'serverInfo' => { 'name' => 's' },
                        'instructions' => 'Be gentle.' } }
      )
      server.instance_variable_set(:@stdin, double('stdin', puts: nil))

      server.send(:perform_initialize)

      expect(server.instructions).to eq('Be gentle.')
    end

    it 'stores and exposes instructions on legacy SSE' do
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
      allow(server).to receive(:send_jsonrpc_request).and_return(
        { 'protocolVersion' => MCPClient::PROTOCOL_VERSION, 'capabilities' => {},
          'serverInfo' => { 'name' => 's' }, 'instructions' => 'Read the docs.' }
      )
      allow(server).to receive(:post_json_rpc_request)
      allow(server).to receive(:sleep)

      server.send(:perform_initialize)

      expect(server.instructions).to eq('Read the docs.')
    end
  end
end
