# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, seventeenth review round: an authorization
# server switch removes only records that are unbound or bound to the
# previous server, and the code is redeemed with the redirect URI the
# authorization request was made with.
RSpec.describe 'MCP 2026-07-28 authorization — round 17' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }
  let(:json) { { 'Content-Type' => 'application/json' } }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def client_info(client_id: 'dyn', issuer: 'https://auth.example.com', redirect: redirect_uri, **opts)
    opts = { registration_type: 'dynamic', client_id_issued_at: 1 }.merge(opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id, issuer: issuer,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect]), **opts)
  end

  def provider_for(store = storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: store)
  end

  it 'keeps a token and a registration already bound to the new authorization server' do
    # Cached metadata still names the old server, but another provider sharing
    # the storage already finished the switch.
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info)
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'new', expires_in: 3600,
                                                             issuer: 'https://auth.example.com'))
    provider = provider_for
    provider.instance_variable_set(
      :@challenge_resource_metadata,
      MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: ['https://auth.example.com'])
    )
    allow(provider).to receive(:fetch_server_metadata).and_return(as_meta)
    registration = stub_request(:post, 'https://auth.example.com/register')

    url = provider.start_authorization_flow

    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn')
    expect(registration).not_to have_been_requested
    expect(provider.access_token&.access_token).to eq('new')
  end

  it 'redeems the code with the redirect URI the authorization request was made with' do
    storage.set_server_metadata(server_url, as_meta)
    storage.set_client_info(server_url, client_info)
    provider = provider_for
    url = provider.start_authorization_flow
    state = URI.decode_www_form(URI.parse(url).query).to_h['state']
    expect(storage.get_pkce(server_url).redirect_uri).to eq(redirect_uri)

    # Shared storage swaps the registration's redirect metadata mid-flow.
    storage.set_client_info(server_url, client_info(redirect: 'http://localhost:9999/other'))
    token_endpoint = stub_request(:post, 'https://auth.example.com/token')
                     .with(body: hash_including('redirect_uri' => redirect_uri))
                     .to_return(status: 200, headers: json,
                                body: { access_token: 'fresh', token_type: 'Bearer', expires_in: 3600 }.to_json)

    expect(provider.complete_authorization_flow('code', state).access_token).to eq('fresh')
    expect(token_endpoint).to have_been_requested
  end
end
