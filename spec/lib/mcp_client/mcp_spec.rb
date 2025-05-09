# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient do
  describe '.create_client' do
    it 'returns an MCPClient::Client instance' do
      client = MCPClient.create_client(mcp_server_configs: [])
      expect(client).to be_a(MCPClient::Client)
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

    it 'builds an sse server config hash with custom parameters' do
      url = 'https://example.com/'
      headers = { 'Authorization' => 'Bearer token' }
      cfg = MCPClient.sse_config(base_url: url, headers: headers, read_timeout: 60, ping: 15, retries: 3,
                                 retry_backoff: 2)
      expect(cfg).to eq(type: 'sse', base_url: url, headers: headers, read_timeout: 60, ping: 15, retries: 3,
                        retry_backoff: 2)
    end

    it 'allows overriding the default ping value' do
      url = 'https://example.com/'
      cfg = MCPClient.sse_config(base_url: url, ping: 5)
      expect(cfg[:ping]).to eq(5)
    end
  end
end
