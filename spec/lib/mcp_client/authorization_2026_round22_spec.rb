# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twenty-second round: the still-valid token a
# failed refresh falls back to must still be current after the discovery
# that refresh ran, and non-object metadata bodies are a discovery failure.
RSpec.describe 'MCP 2026-07-28 authorization — round 22' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

  def as_meta(issuer:)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'])
  end

  def dynamic_client(issuer)
    MCPClient::Auth::ClientInfo.new(client_id: 'dyn', issuer: issuer, registration_type: 'dynamic',
                                    client_id_issued_at: 1,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: ['http://localhost:1/cb']))
  end

  def provider_with(storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: 'http://localhost:1/cb',
                                       logger: logger, storage: storage)
  end

  it 'does not present a token that the discovery a refresh ran just retired' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, dynamic_client('https://old.example.com'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old-tok', expires_in: 60,
                                                             refresh_token: 'r', issuer: 'https://old.example.com'))
    provider = provider_with(storage)
    # A challenge whose metadata URL failed at first: the URL stays pending.
    stub_request(:get, prm_url).to_return(status: 502)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    begin
      provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
    rescue MCPClient::Errors::ConnectionError
      nil
    end
    # The retry now names another authorization server.
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => ['https://auth.example.com'] }.to_json)
    allow(provider).to receive(:fetch_server_metadata).and_return(as_meta(issuer: 'https://auth.example.com'))
    request = instance_double(Faraday::Request, headers: {})

    provider.apply_authorization(request)

    expect(request.headers['Authorization']).to be_nil
    expect(provider.access_token).to be_nil
  end

  it 'treats a non-object authorization server metadata body as a discovery failure' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'new', expires_in: 60, refresh_token: 'r',
                                                             issuer: 'https://auth.example.com'))
    provider = provider_with(storage)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => ['https://auth.example.com'] }.to_json)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
    ['[]', 'null', '"x"'].each do |body|
      stub_request(:get, %r{https://auth\.example\.com/\.well-known/}).to_return(status: 200, headers: json, body: body)
      request = instance_double(Faraday::Request, headers: {})

      expect { provider.apply_authorization(request) }.not_to raise_error
      expect(request.headers['Authorization']).to eq('Bearer new')
    end
  end
end
