# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 version negotiation (basic/lifecycle + InitializeResult
# schema): the server responds with the protocol version it wants to use —
# "If the client cannot support this version, it MUST disconnect."
RSpec.describe 'Protocol version negotiation (MCP 2025-11-25)' do
  it 'defines the set of supported protocol versions, including the current one' do
    expect(MCPClient::SUPPORTED_PROTOCOL_VERSIONS).to include(MCPClient::PROTOCOL_VERSION)
  end

  def init_sse_body(result)
    "event: message\ndata: #{JSON.generate(jsonrpc: '2.0', id: 1, result: result)}\n\n"
  end

  describe MCPClient::ServerStreamableHTTP do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/rpc' }
    let(:server) { described_class.new(base_url: base_url, endpoint: endpoint, name: 'ver-test') }

    after { server.cleanup }

    def stub_initialize(result)
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(status: 200, body: init_sse_body(result),
                   headers: { 'Content-Type' => 'text/event-stream' })
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, body: '')
      stub_request(:get, "#{base_url}#{endpoint}").to_return(status: 200, body: '')
    end

    it 'disconnects when the server negotiates an unsupported version' do
      stub_initialize({ protocolVersion: '1999-01-01', capabilities: {},
                        serverInfo: { name: 's', version: '1' } })

      expect { server.connect }.to raise_error(
        MCPClient::Errors::ConnectionError, /protocol version.*1999-01-01/i
      )
    end

    it 'disconnects when the initialize result carries no protocol version' do
      stub_initialize({ capabilities: {}, serverInfo: { name: 's', version: '1' } })

      expect { server.connect }.to raise_error(
        MCPClient::Errors::ConnectionError, /protocol version/i
      )
    end

    it 'disconnects when the initialize result is not an object' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(status: 200,
                   body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"ok\"}\n\n",
                   headers: { 'Content-Type' => 'text/event-stream' })
      stub_request(:get, "#{base_url}#{endpoint}").to_return(status: 200, body: '')

      expect { server.connect }.to raise_error(
        MCPClient::Errors::ConnectionError, /initialize result/i
      )
    end

    it 'accepts a supported older version and records it' do
      stub_initialize({ protocolVersion: '2025-06-18', capabilities: {},
                        serverInfo: { name: 's', version: '1' } })

      expect(server.connect).to be true
      expect(server.instance_variable_get(:@protocol_version)).to eq('2025-06-18')
    end
  end

  describe MCPClient::ServerStdio do
    let(:server) { described_class.new(command: 'echo test') }

    it 'disconnects when the server negotiates an unsupported version' do
      allow(server).to receive(:next_id).and_return(1)
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response).and_return(
        { 'result' => { 'protocolVersion' => '1999-01-01', 'capabilities' => {} } }
      )
      expect(server).to receive(:cleanup)

      expect { server.send(:perform_initialize) }.to raise_error(
        MCPClient::Errors::ConnectionError, /protocol version.*1999-01-01/i
      )
    end

    it 'records a supported negotiated version' do
      allow(server).to receive(:next_id).and_return(1)
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response).and_return(
        { 'result' => { 'protocolVersion' => '2024-11-05', 'capabilities' => {},
                        'serverInfo' => { 'name' => 's' } } }
      )
      server.instance_variable_set(:@stdin, double('stdin', puts: nil))

      server.send(:perform_initialize)

      expect(server.instance_variable_get(:@protocol_version)).to eq('2024-11-05')
    end
  end

  describe MCPClient::ServerSSE do
    let(:server) { described_class.new(base_url: 'https://example.com/sse') }

    it 'disconnects when the server negotiates an unsupported version' do
      allow(server).to receive(:send_jsonrpc_request).and_return(
        { 'protocolVersion' => '1999-01-01', 'capabilities' => {} }
      )
      expect(server).to receive(:cleanup)

      expect { server.send(:perform_initialize) }.to raise_error(
        MCPClient::Errors::ConnectionError, /protocol version.*1999-01-01/i
      )
    end

    it 'records a supported negotiated version' do
      allow(server).to receive(:send_jsonrpc_request).and_return(
        { 'protocolVersion' => '2024-11-05', 'capabilities' => {},
          'serverInfo' => { 'name' => 's' } }
      )
      allow(server).to receive(:post_json_rpc_request)
      allow(server).to receive(:sleep)

      server.send(:perform_initialize)

      expect(server.instance_variable_get(:@protocol_version)).to eq('2024-11-05')
    end
  end
end
