# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, fifth review round: serialized storage
# records are normalized before their issuer is read, a portable client is
# refused where Client ID Metadata Documents are not accepted even when no
# registration is offered, and a freshly issued token is accepted even when
# it reuses the bytes of a retired one.
RSpec.describe 'MCP 2026-07-28 authorization — round 5' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def provider_for(storage, **opts)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: storage, **opts)
  end

  def switch_authorization_server(provider, meta)
    provider.instance_variable_set(
      :@challenge_resource_metadata,
      MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [meta.issuer])
    )
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
  end

  def client_info(client_id: 'pre-registered', **opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  # A backend that persists plain hashes, like the FileTokenStorage example.
  def serializing_storage
    Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
      def set_server_metadata(url, metadata) = super(url, metadata.to_h)
      def set_pkce(url, pkce) = super(url, pkce.to_h)
      def set_token(url, token) = super(url, token&.to_h)
    end.new
  end

  it 'reads the issuer of serialized server metadata and tokens' do
    storage = serializing_storage
    storage.set_server_metadata(server_url, as_meta)
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'alice', expires_in: 3600,
                                                             issuer: 'https://auth.example.com'))
    provider = provider_for(storage)

    expect(provider.access_token&.access_token).to eq('alice')
  end

  it 'starts and completes a flow with serialized metadata and PKCE records' do
    storage = serializing_storage
    storage.set_server_metadata(server_url, as_meta)
    storage.set_client_info(server_url, client_info)
    provider = provider_for(storage)
    stub_request(:post, 'https://auth.example.com/token')
      .to_return(status: 200, headers: json,
                 body: { access_token: 'fresh', token_type: 'Bearer', expires_in: 3600 }.to_json)

    url = provider.start_authorization_flow
    state = URI.decode_www_form(URI.parse(url).query).to_h['state']
    token = provider.complete_authorization_flow('code', state)

    expect(token.access_token).to eq('fresh')
    expect(provider.access_token&.access_token).to eq('fresh')
  end

  it 'refuses a portable client where Client ID Metadata Documents are not accepted and no registration exists' do
    cimd_url = 'https://app.example.com/oauth/client-metadata.json'
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(client_id: cimd_url, registration_type: 'cimd'))
    provider = provider_for(storage, client_id_metadata_url: cimd_url)
    switch_authorization_server(provider, as_meta)

    expect { provider.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError) { |e|
      expect(e.message).not_to include(cimd_url)
    }
  end

  it 'accepts a freshly issued token that reuses the bytes of a retired one' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(issuer: 'https://old.example.com',
                                                    registration_type: 'dynamic'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'dev-token', expires_in: 3600,
                                                             issuer: 'https://old.example.com'))
    provider = provider_for(storage)
    switch_authorization_server(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    stub_request(:post, 'https://auth.example.com/register')
      .to_return(status: 201, headers: json, body: { client_id: 'dyn' }.to_json)
    stub_request(:post, 'https://auth.example.com/token')
      .to_return(status: 200, headers: json,
                 body: { access_token: 'dev-token', token_type: 'Bearer', expires_in: 3600 }.to_json)

    url = provider.start_authorization_flow
    expect(provider.access_token).to be_nil
    state = URI.decode_www_form(URI.parse(url).query).to_h['state']
    provider.complete_authorization_flow('code', state)

    expect(provider.access_token&.access_token).to eq('dev-token')
    expect(storage.get_token(server_url).issuer).to eq('https://auth.example.com')
  end
end
