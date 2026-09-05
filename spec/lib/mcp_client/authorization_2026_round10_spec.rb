# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, tenth review round: the client credentials
# used to redeem the code are the ones the authorization request was made
# with — a record swapped in storage during the flow is never sent to the
# token endpoint.
RSpec.describe 'MCP 2026-07-28 authorization — round 10' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def client_info(client_id: 'pre-registered', **opts)
    opts = { registration_type: 'pre_registered', issuer: 'https://auth.example.com' }.merge(opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  def started_flow
    storage.set_server_metadata(server_url, as_meta)
    storage.set_client_info(server_url, client_info)
    provider = MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                                  logger: logger, storage: storage)
    url = provider.start_authorization_flow
    [provider, URI.decode_www_form(URI.parse(url).query).to_h['state']]
  end

  it 'records the client the authorization request was made with' do
    started_flow

    expect(storage.get_pkce(server_url).client_id).to eq('pre-registered')
    expect(MCPClient::Auth::PKCE.from_h(storage.get_pkce(server_url).to_h).client_id).to eq('pre-registered')
  end

  # The client id is deliberately UNCHANGED: with a different one the
  # preceding identity check refuses the record on its own, and the issuer
  # guard is never exercised. Two authorization servers can issue the same
  # client id, and only the issuer recorded with the request tells them apart.
  it 'refuses to redeem the code with credentials bound to another authorization server' do
    provider, state = started_flow
    storage.set_client_info(server_url, client_info(client_id: 'pre-registered', client_secret: 'other-secret',
                                                    issuer: 'https://other.example.com'))
    token_endpoint = stub_request(:post, 'https://auth.example.com/token')

    expect { provider.complete_authorization_flow('code', state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /changed during the flow/)
    expect(token_endpoint).not_to have_been_requested
  end

  it 'refuses to redeem the code with a different client of the same authorization server' do
    provider, state = started_flow
    storage.set_client_info(server_url, client_info(client_id: 'swapped', client_secret: 's'))
    token_endpoint = stub_request(:post, 'https://auth.example.com/token')

    expect { provider.complete_authorization_flow('code', state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /changed during the flow/)
    expect(token_endpoint).not_to have_been_requested
  end

  it 'redeems the code with the recorded client' do
    provider, state = started_flow
    stub_request(:post, 'https://auth.example.com/token')
      .with(body: hash_including('client_id' => 'pre-registered'))
      .to_return(status: 200, headers: json,
                 body: { access_token: 'fresh', token_type: 'Bearer', expires_in: 3600 }.to_json)

    expect(provider.complete_authorization_flow('code', state).access_token).to eq('fresh')
  end
end
