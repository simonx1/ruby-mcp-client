# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 lifecycle: "Both parties MUST ... Only use capabilities that
# were successfully negotiated", and each client feature page requires:
# "Clients that support X MUST declare the X capability during initialization."
# Declared client capabilities must therefore reflect what the host actually
# registered, on every transport, instead of being hardcoded per transport.
RSpec.describe 'Client capability declaration (MCP 2025-11-25)' do
  describe 'transport-level derivation from registered callbacks' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

    it 'declares no feature capabilities when no callbacks are registered' do
      expect(server.send(:initialization_params)['capabilities']).to eq({})
    end

    it 'declares elicitation (with both modes) when an elicitation callback is registered' do
      server.on_elicitation_request { |_id, _params| { 'action' => 'decline' } }

      caps = server.send(:initialization_params)['capabilities']
      expect(caps).to eq({ 'elicitation' => { 'form' => {}, 'url' => {} } })
    end

    it 'declares roots and sampling when those callbacks are registered' do
      server.on_roots_list_request { |_id, _params| { 'roots' => [] } }
      server.on_sampling_request { |_id, _params| {} }

      caps = server.send(:initialization_params)['capabilities']
      expect(caps).to eq({
                           'roots' => { 'listChanged' => true },
                           'sampling' => {}
                         })
    end
  end

  describe 'Streamable HTTP wire declaration' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/rpc' }

    it 'declares registered capabilities in the initialize request' do
      server = MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, name: 'caps-test')
      server.send(:on_elicitation_request) { |_id, _params| { 'action' => 'decline' } }
      server.send(:on_roots_list_request) { |_id, _params| { 'roots' => [] } }
      server.send(:on_sampling_request) { |_id, _params| {} }

      init_body = nil
      stub_request(:post, "#{base_url}#{endpoint}")
        .with do |request|
          body = JSON.parse(request.body)
          init_body = body if body['method'] == 'initialize'
          true
        end
        .to_return(
          status: 200,
          body: "event: message\ndata: #{JSON.generate(
            jsonrpc: '2.0', id: 1,
            result: { protocolVersion: MCPClient::PROTOCOL_VERSION, capabilities: {},
                      serverInfo: { name: 's', version: '1' } }
          )}\n\n",
          headers: { 'Content-Type' => 'text/event-stream' }
        )
      stub_request(:get, "#{base_url}#{endpoint}").to_return(status: 200, body: '')

      server.connect
      server.cleanup

      expect(init_body['params']['capabilities']).to eq(
        'elicitation' => { 'form' => {}, 'url' => {} },
        'roots' => { 'listChanged' => true },
        'sampling' => {}
      )
    end
  end

  describe 'Client-level registration' do
    it 'registers only the roots channel when no handlers are configured' do
      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'echo test' }]
      )

      caps = client.servers.first.send(:initialization_params)['capabilities']
      expect(caps).to eq({ 'roots' => { 'listChanged' => true } })
    end

    it 'declares elicitation and sampling when the host configured handlers' do
      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'echo test' }],
        elicitation_handler: ->(_m, _s) { { 'action' => 'decline' } },
        sampling_handler: ->(_p) { {} }
      )

      caps = client.servers.first.send(:initialization_params)['capabilities']
      expect(caps).to eq({
                           'elicitation' => { 'form' => {}, 'url' => {} },
                           'roots' => { 'listChanged' => true },
                           'sampling' => {}
                         })
    end
  end

  describe 'roots list_changed gating' do
    it 'only notifies servers that support the roots request channel' do
      with_roots = double('stdio-like', rpc_notify: nil, on_roots_list_request: nil)
      without_roots = double('plain-http', rpc_notify: nil)

      client = MCPClient::Client.new
      client.instance_variable_set(:@servers, [with_roots, without_roots])

      client.roots = [{ 'uri' => 'file:///workspace', 'name' => 'ws' }]

      expect(with_roots).to have_received(:rpc_notify).with('notifications/roots/list_changed', {})
      expect(without_roots).not_to have_received(:rpc_notify)
    end
  end
end
