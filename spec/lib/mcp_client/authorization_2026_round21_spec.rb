# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twenty-first round: a token that is still
# valid is presented even when its early refresh cannot run, and a refresh
# never lets a discovery failure escape access_token.
RSpec.describe 'MCP 2026-07-28 authorization — round 21' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

  def as_meta(issuer:)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'])
  end

  def provider_with(storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: 'http://localhost:1/cb',
                                       logger: logger, storage: storage)
  end

  def challenge(provider, issuer)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => [issuer] }.to_json)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
  end

  it 'presents a near-expiry token bound to the advertised server when discovery fails' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'new', expires_in: 60, refresh_token: 'r',
                                                             issuer: 'https://auth.example.com'))
    provider = provider_with(storage)
    allow(provider).to receive(:fetch_server_metadata).and_return(nil)
    challenge(provider, 'https://auth.example.com')

    expect(provider.access_token&.access_token).to eq('new')
    expect(storage.get_client_info(server_url)).to be_nil
  end

  it 'falls back to the still-valid token when the refresh request fails' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://auth.example.com'))
    storage.set_client_info(server_url, MCPClient::Auth::ClientInfo.new(
                                          client_id: 'c', registration_type: 'pre_registered',
                                          issuer: 'https://auth.example.com',
                                          metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: ['http://localhost:1/cb'])
                                        ))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'soon', expires_in: 60, refresh_token: 'r',
                                                             issuer: 'https://auth.example.com'))
    stub_request(:post, 'https://auth.example.com/token').to_return(status: 503)
    provider = provider_with(storage)

    expect(provider.access_token&.access_token).to eq('soon')
  end

  it 'still returns nil for an expired token whose refresh fails' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://auth.example.com'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'gone', expires_in: 0, refresh_token: 'r',
                                                             issuer: 'https://auth.example.com'))
    stub_request(:post, 'https://auth.example.com/token').to_return(status: 503)
    provider = provider_with(storage)

    expect(provider.access_token).to be_nil
  end
end
