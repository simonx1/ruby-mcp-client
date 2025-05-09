# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'json'

RSpec.describe MCPClient do
  describe '.create_client' do
    it 'returns an MCPClient::Client instance' do
      client = MCPClient.create_client(mcp_server_configs: [])
      expect(client).to be_a(MCPClient::Client)
    end

    context 'with server_definition_file' do
      it 'loads a single server config from JSON file' do
        file = Tempfile.new('server.json')
        file.write({ type: 'stdio', command: 'echo hi' }.to_json)
        file.close
        client = MCPClient.create_client(server_definition_file: file.path)
        expect(client.servers.size).to eq(1)
        expect(client.servers.first).to be_a(MCPClient::ServerBase)
      ensure
        file.unlink
      end

      it 'loads multiple server configs from JSON file' do
        file = Tempfile.new('servers.json')
        configs = [
          { type: 'stdio', command: 'echo hi' },
          { type: 'sse', url: 'https://example.com', ping: 10, close_after: 25 }
        ]
        file.write(configs.to_json)
        file.close
        client = MCPClient.create_client(server_definition_file: file.path)
        expect(client.servers.size).to eq(2)
      ensure
        file.unlink
      end
    end
  end

  describe '.stdio_config' do
    it 'builds a stdio server config hash' do
      cmd = 'echo hi'
      cfg = MCPClient.stdio_config(command: cmd)
      expect(cfg).to eq(type: 'stdio', command: cmd)
    end
  end

  describe '.sse_config' do
    it 'builds an sse server config hash with base_url and headers' do
      url = 'https://example.com/'
      headers = { 'Authorization' => 'Bearer token' }
      cfg = MCPClient.sse_config(base_url: url, headers: headers)
      expect(cfg).to eq(type: 'sse', base_url: url, headers: headers, read_timeout: 30, ping: 10, retries: 0,
                        retry_backoff: 1)
    end
  end
end
