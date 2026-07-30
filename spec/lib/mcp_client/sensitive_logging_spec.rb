# frozen_string_literal: true

require 'spec_helper'

# Logs are routinely shipped to lower-trust destinations (aggregators, CI
# artifacts, support bundles), so neither credentials nor request/response
# payloads may be written verbatim just because DEBUG is enabled.
RSpec.describe 'Sensitive data in logs' do
  let(:log_output) { StringIO.new }
  let(:logger) do
    Logger.new(log_output).tap { |l| l.level = Logger::DEBUG }
  end

  describe 'server configuration logging' do
    it 'redacts headers and environment values when logging a server config' do
      MCPClient::Client.new(
        mcp_server_configs: [
          {
            type: 'streamable_http',
            base_url: 'https://example.com',
            endpoint: '/rpc',
            headers: { 'Authorization' => 'Bearer super-secret-token' }
          }
        ],
        logger: logger
      )

      expect(log_output.string).not_to include('super-secret-token')
      expect(log_output.string).to include('[REDACTED]')
    end

    it 'redacts stdio subprocess environment secrets' do
      MCPClient::Client.new(
        mcp_server_configs: [
          { type: 'stdio', command: 'echo', env: { 'OPENAI_API_KEY' => 'sk-live-secret' } }
        ],
        logger: logger
      )

      expect(log_output.string).not_to include('sk-live-secret')
      expect(log_output.string).to include('[REDACTED]')
    end

    it 'still logs non-sensitive configuration fields' do
      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'echo' }],
        logger: logger
      )

      expect(log_output.string).to include('stdio')
    end
  end

  describe 'JSON-RPC payload logging' do
    let(:server) do
      MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/rpc', logger: logger)
    end

    it 'omits outbound request params, logging only the method and id' do
      request = {
        'jsonrpc' => '2.0', 'id' => 7, 'method' => 'tools/call',
        'params' => { 'name' => 'send_email', 'arguments' => { 'body' => 'patient record 12345' } }
      }
      allow(server).to receive(:send_http_request).and_raise(MCPClient::Errors::TransportError, 'stop here')

      expect { server.send(:send_jsonrpc_request, request) }.to raise_error(MCPClient::Errors::TransportError)

      expect(log_output.string).not_to include('patient record 12345')
      expect(log_output.string).to include('tools/call')
      expect(log_output.string).to include('id=7')
    end

    it 'omits response bodies, logging only the status and size' do
      response = instance_double(Faraday::Response, status: 200, body: '{"result":{"ssn":"123-45-6789"}}')

      server.send(:log_response, response)

      expect(log_output.string).not_to include('123-45-6789')
      expect(log_output.string).to include('200')
      expect(log_output.string).to include('32 bytes')
    end
  end
end
