# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 Streamable HTTP session management:
# - "The session ID ... MUST only contain visible ASCII characters (ranging
#   from 0x21 to 0x7E)" — e.g. "a securely generated UUID, a JWT, or a
#   cryptographic hash"; clients MUST echo whatever the server assigned.
# - "When a client receives HTTP 404 in response to a request containing an
#   MCP-Session-Id, it MUST start a new session by sending a new
#   InitializeRequest without a session ID attached."
RSpec.describe 'Streamable HTTP session lifecycle (MCP 2025-11-25)' do
  describe 'session ID acceptance' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: 'https://example.com') }

    it 'accepts spec-valid session IDs the server may assign' do
      [
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c', # JWT
        'c2Vzc2lvbi1pZCsvPQ==', # base64 with + / =
        '1234',                 # short id
        'a' * 200               # long hash
      ].each do |id|
        expect(server.valid_session_id?(id)).to be(true), "expected #{id.inspect} to be accepted"
      end
    end

    it 'rejects ids outside the visible-ASCII range' do
      ['', 'session id', "tab\tid", 'sessão-1', "newline\nid"].each do |id|
        expect(server.valid_session_id?(id)).to be(false), "expected #{id.inspect} to be rejected"
      end
    end

    it 'accepts very long ids (the spec imposes no length limit)' do
      expect(server.valid_session_id?('a' * 2048)).to be(true)
    end
  end

  describe '404 recovery with raise_error middleware' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/rpc' }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(
        base_url: base_url, endpoint: endpoint, retries: 0, name: 'raise-test',
        faraday_config: ->(conn) { conn.response :raise_error }
      )
    end

    after { server.cleanup }

    it 'still starts a new session on 404 when raise_error is configured' do
      init_bodies = []
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return do |request|
          init_bodies << request
          { status: 200,
            body: "event: message\ndata: #{JSON.generate(
              jsonrpc: '2.0', id: 1,
              result: { protocolVersion: MCPClient::PROTOCOL_VERSION, capabilities: {},
                        serverInfo: { name: 's', version: '1' } }
            )}\n\n",
            headers: { 'Content-Type' => 'text/event-stream',
                       'Mcp-Session-Id' => "sess-#{init_bodies.size}" } }
        end
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, body: '')
      stub_request(:get, "#{base_url}#{endpoint}").to_return(status: 200, body: '')

      list_count = 0
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'tools/list'))
        .to_return do |_request|
          list_count += 1
          if list_count == 1
            { status: 404, body: '' }
          else
            { status: 200,
              body: "event: message\ndata: #{JSON.generate(jsonrpc: '2.0', id: 2, result: { tools: [] })}\n\n",
              headers: { 'Content-Type' => 'text/event-stream' } }
          end
        end

      server.connect
      expect(server.rpc_request('tools/list', {})).to eq({ 'tools' => [] })
      expect(init_bodies.size).to eq(2)
    end
  end

  describe '404 session expiry recovery' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/rpc' }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, name: 'sess-test')
    end

    after { server.cleanup }

    def init_body
      "event: message\ndata: #{JSON.generate(
        jsonrpc: '2.0', id: 1,
        result: { protocolVersion: MCPClient::PROTOCOL_VERSION, capabilities: {},
                  serverInfo: { name: 's', version: '1' } }
      )}\n\n"
    end

    def tools_body
      "event: message\ndata: #{JSON.generate(
        jsonrpc: '2.0', id: 2, result: { tools: [] }
      )}\n\n"
    end

    it 'starts a new session (initialize without session id) and resends the request' do
      init_requests = []
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return do |request|
          init_requests << request
          { status: 200, body: init_body,
            headers: { 'Content-Type' => 'text/event-stream',
                       'Mcp-Session-Id' => "sess-#{init_requests.size}" } }
        end
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, body: '')
      stub_request(:get, "#{base_url}#{endpoint}").to_return(status: 200, body: '')

      list_requests = []
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'tools/list'))
        .to_return do |request|
          list_requests << request
          if list_requests.size == 1
            { status: 404, body: '' }
          else
            { status: 200, body: tools_body, headers: { 'Content-Type' => 'text/event-stream' } }
          end
        end

      server.connect
      result = server.rpc_request('tools/list', {})

      expect(result).to eq({ 'tools' => [] })
      expect(init_requests.size).to eq(2)
      expect(init_requests.last.headers).not_to have_key('Mcp-Session-Id')
      expect(list_requests.size).to eq(2)
      expect(list_requests.first.headers['Mcp-Session-Id']).to eq('sess-1')
      expect(list_requests.last.headers['Mcp-Session-Id']).to eq('sess-2')
    end

    it 'skips re-initialization when another caller already restarted the session' do
      init_count = 0
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return do |_request|
          init_count += 1
          { status: 200, body: init_body,
            headers: { 'Content-Type' => 'text/event-stream', 'Mcp-Session-Id' => "sess-#{init_count}" } }
        end
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, body: '')
      stub_request(:get, "#{base_url}#{endpoint}").to_return(status: 200, body: '')

      list_requests = []
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'tools/list'))
        .to_return do |request|
          list_requests << request
          { status: 200, body: tools_body, headers: { 'Content-Type' => 'text/event-stream' } }
        end

      server.connect

      # Simulate the race: this caller saw a 404 against sess-1, but while it
      # waited for the monitor another caller already restarted the session
      # and obtained sess-2. The stale expired id must not trigger a third
      # session; the request is simply resent against the fresh session.
      server.instance_variable_set(:@session_id, 'sess-2')
      request = { 'jsonrpc' => '2.0', 'id' => 42, 'method' => 'tools/list', 'params' => {} }
      server.send(:restart_session_and_resend, request, 'sess-1')

      expect(init_count).to eq(1) # only the initial connect, no second initialize POST
      expect(list_requests.size).to eq(1)
      expect(list_requests.first.headers['Mcp-Session-Id']).to eq('sess-2')
      expect(server.instance_variable_get(:@session_id)).to eq('sess-2')
    end

    it 'does not loop when the resent request also gets 404' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(status: 200, body: init_body,
                   headers: { 'Content-Type' => 'text/event-stream', 'Mcp-Session-Id' => 'sess-1' })
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, body: '')
      stub_request(:get, "#{base_url}#{endpoint}").to_return(status: 200, body: '')

      list_stub = stub_request(:post, "#{base_url}#{endpoint}")
                  .with(body: hash_including('method' => 'tools/list'))
                  .to_return(status: 404, body: '')

      server.connect

      expect { server.rpc_request('tools/list', {}) }.to raise_error(
        MCPClient::Errors::ServerError, /404/
      )
      expect(list_stub).to have_been_requested.twice
    end
  end
end
