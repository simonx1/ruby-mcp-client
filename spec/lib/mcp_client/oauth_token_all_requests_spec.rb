# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 basic/authorization — Access Token Usage:
# "Note that authorization MUST be included in every HTTP request from
# client to server, even if they are part of the same logical session."
RSpec.describe 'OAuth token on every Streamable HTTP request (MCP 2025-11-25)' do
  let(:base_url) { 'https://mcp.example.com' }
  let(:endpoint) { '/rpc' }

  # A minimal OAuth provider that stamps a recognizable Authorization header
  let(:oauth_provider) do
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) do |req|
      req.headers['Authorization'] = 'Bearer audit-token'
    end
    provider
  end

  let(:server) do
    MCPClient::ServerStreamableHTTP.new(
      base_url: base_url, endpoint: endpoint, name: 'auth-test', oauth_provider: oauth_provider
    )
  end

  after { server.cleanup }

  it 'sends the token on the GET events stream' do
    get_stub = stub_request(:get, "#{base_url}#{endpoint}")
               .with(headers: { 'Authorization' => 'Bearer audit-token' })
               .to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/event-stream' })

    server.instance_variable_set(:@connection_established, true)
    server.send(:start_events_connection)
    deadline = Time.now + 2
    sleep 0.05 until get_stub.to_s.include?('was requested') || Time.now > deadline

    expect(get_stub).to have_been_requested.at_least_once
  end

  it 'sends the token on the session termination DELETE' do
    server.instance_variable_set(:@session_id, 'sess-123')
    delete_stub = stub_request(:delete, "#{base_url}#{endpoint}")
                  .with(headers: { 'Authorization' => 'Bearer audit-token' })
                  .to_return(status: 200, body: '')

    expect(server.terminate_session).to be true
    expect(delete_stub).to have_been_requested.once
  end

  it 'sends the token on pong responses to server pings' do
    pong_stub = stub_request(:post, "#{base_url}#{endpoint}")
                .with(headers: { 'Authorization' => 'Bearer audit-token' },
                      body: hash_including('id' => 'ping-9'))
                .to_return(status: 200, body: '')

    server.send(:handle_ping_request, 'ping-9')
    deadline = Time.now + 2
    sleep 0.05 until pong_stub.to_s.include?('was requested') || Time.now > deadline

    expect(pong_stub).to have_been_requested.once
  end

  it 'sends the token on responses to server-initiated requests' do
    response_stub = stub_request(:post, "#{base_url}#{endpoint}")
                    .with(headers: { 'Authorization' => 'Bearer audit-token' },
                          body: hash_including('id' => 42))
                    .to_return(status: 200, body: '')

    server.send(:post_jsonrpc_response, { 'jsonrpc' => '2.0', 'id' => 42, 'result' => { 'roots' => [] } })
    deadline = Time.now + 2
    sleep 0.05 until response_stub.to_s.include?('was requested') || Time.now > deadline

    expect(response_stub).to have_been_requested.once
  end

  it 'sends the token on the plain HTTP transport DELETE as well' do
    http_server = MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, oauth_provider: oauth_provider)
    http_server.instance_variable_set(:@session_id, 'sess-456')
    delete_stub = stub_request(:delete, "#{base_url}#{endpoint}")
                  .with(headers: { 'Authorization' => 'Bearer audit-token' })
                  .to_return(status: 200, body: '')

    expect(http_server.terminate_session).to be true
    expect(delete_stub).to have_been_requested.once
  end
end
