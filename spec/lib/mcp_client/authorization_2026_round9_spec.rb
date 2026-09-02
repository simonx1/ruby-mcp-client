# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, ninth review round: a persisted record
# without a registration type is a dynamic registration (RFC 7591's
# client_id_issued_at is optional, so its absence proves nothing);
# pre-registered credentials say so explicitly.
RSpec.describe 'MCP 2026-07-28 authorization — round 9' do
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

  def discovering(provider, meta)
    resource = MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [meta.issuer])
    allow(provider).to receive(:fetch_resource_metadata).and_return(resource)
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
  end

  def untyped_client(**opts)
    MCPClient::Auth::ClientInfo.new(client_id: 'legacy', client_secret: 'secret',
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  it 'treats a record without a registration type as a dynamic registration' do
    expect(untyped_client.effective_registration_type).to eq('dynamic')
    expect(untyped_client).not_to be_pre_registered
    expect(untyped_client(registration_type: 'pre_registered')).to be_pre_registered
  end

  it 'retires an untyped record without a timestamp when no authorization server was cached' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_client_info(server_url, untyped_client)
    provider = provider_for(storage)
    discovering(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    registration = stub_request(:post, 'https://auth.example.com/register')
                   .to_return(status: 201, headers: json, body: { client_id: 'dyn-new' }.to_json)

    url = provider.start_authorization_flow

    expect(registration).to have_been_requested
    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn-new')
  end

  it 're-registers an untyped record after a cached authorization server switch' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, untyped_client)
    provider = provider_for(storage)
    provider.instance_variable_set(
      :@challenge_resource_metadata,
      MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: ['https://auth.example.com'])
    )
    allow(provider).to receive(:fetch_server_metadata)
      .and_return(as_meta(registration_endpoint: 'https://auth.example.com/register'))
    registration = stub_request(:post, 'https://auth.example.com/register')
                   .to_return(status: 201, headers: json, body: { client_id: 'dyn-new' }.to_json)

    url = provider.start_authorization_flow

    expect(registration).to have_been_requested
    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn-new')
  end
end
