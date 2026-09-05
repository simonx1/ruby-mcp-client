# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, eleventh review round: an issuer-less record
# swapped in during the flow is a change of credentials, the callback
# precheck sees an authorization server switched by a challenge, and
# retirement markers are scoped by issuer.
RSpec.describe 'MCP 2026-07-28 authorization — round 11' do
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

  def provider_for(store = storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: store)
  end

  def started_flow
    storage.set_server_metadata(server_url, as_meta)
    storage.set_client_info(server_url, client_info)
    provider = provider_for
    url = provider.start_authorization_flow
    [provider, URI.decode_www_form(URI.parse(url).query).to_h['state']]
  end

  it 'treats an issuer-less record swapped in during the flow as changed credentials' do
    provider, state = started_flow
    storage.set_client_info(server_url, client_info(client_secret: 'foreign', issuer: nil, registration_type: nil))
    token_endpoint = stub_request(:post, 'https://auth.example.com/token')

    expect { provider.complete_authorization_flow('code', state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /changed during the flow/)
    expect(token_endpoint).not_to have_been_requested
  end

  it 'rejects a callback at the precheck once a challenge switched the authorization server' do
    provider, state = started_flow
    provider.instance_variable_set(
      :@challenge_resource_metadata,
      MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: ['https://other.example.com'])
    )

    expect { provider.validate_authorization_response!(state, iss: 'https://auth.example.com') }
      .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed/)
  end

  it 'rejects a callback at the precheck when the stored credentials changed' do
    provider, state = started_flow
    storage.set_client_info(server_url, client_info(client_id: 'swapped'))

    expect { provider.validate_authorization_response!(state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /changed during the flow/)
  end

  it 'scopes retirement markers by issuer so another issuer may reuse the bytes' do
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'same-bytes', expires_in: 3600,
                                                             issuer: 'https://old.example.com'))
    provider = provider_for
    provider.instance_variable_set(
      :@challenge_resource_metadata,
      MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: ['https://auth.example.com'])
    )
    allow(provider).to receive(:fetch_server_metadata)
      .and_return(as_meta(registration_endpoint: 'https://auth.example.com/register'))
    stub_request(:post, 'https://auth.example.com/register')
      .to_return(status: 201, headers: json, body: { client_id: 'dyn' }.to_json)
    provider.start_authorization_flow
    expect(provider.access_token).to be_nil

    # Another provider instance sharing the storage stores a legitimate token
    # of the new authorization server that happens to reuse the bytes.
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'same-bytes', expires_in: 3600,
                                                             issuer: 'https://auth.example.com'))

    expect(provider.access_token&.access_token).to eq('same-bytes')
  end
end
