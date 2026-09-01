# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, third review round: credentials persisted
# before the binding fields belong to the authorization server that was
# known at the time, tokens without an issuer are never refreshed after a
# switch, the response-parameter flag is recorded with the request, issuer
# comparison is byte for byte, and peer-controlled issuers are sanitized.
RSpec.describe 'MCP 2026-07-28 authorization — round 3' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def provider_for(**opts)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: storage, **opts)
  end

  def stub_discovery(provider, meta, advertised: meta.issuer)
    resource = MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [advertised])
    allow(provider).to receive(:fetch_resource_metadata).and_return(resource)
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
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

  def stub_token_endpoint(issuer)
    stub_request(:post, "#{issuer}/token")
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: { access_token: 'tok', token_type: 'Bearer', expires_in: 3600, refresh_token: 'r' }.to_json)
  end

  it 'binds unbound credentials to the authorization server they were stored under, not the new one' do
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(client_id: 'from-old'))
    provider = provider_for
    switch_authorization_server(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    registration = stub_request(:post, 'https://auth.example.com/register')

    expect { provider.start_authorization_flow }
      .to raise_error(MCPClient::Errors::ConnectionError, %r{https://old\.example\.com.*https://auth\.example\.com})
    expect(registration).not_to have_been_requested
    expect(storage.get_client_info(server_url).issuer).to eq('https://old.example.com')
  end

  it 'recognizes a persisted Client ID Metadata Document client as portable' do
    cimd_url = 'https://app.example.com/oauth/client-metadata.json'
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(client_id: cimd_url))
    provider = provider_for(client_id_metadata_url: cimd_url)
    switch_authorization_server(provider, as_meta(client_id_metadata_document_supported: true))

    url = provider.start_authorization_flow

    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq(cimd_url)
    expect(storage.get_client_info(server_url).registration_type).to eq('cimd')
  end

  it 'never refreshes a token that carries no issuer once the authorization server changed' do
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(registration_type: 'cimd'))
    legacy = MCPClient::Auth::Token.new(access_token: 'old', expires_in: 0, refresh_token: 'r')
    storage.set_token(server_url, legacy)
    provider = provider_for
    switch_authorization_server(provider, as_meta)
    provider.start_authorization_flow
    storage.set_token(server_url, legacy) # a backend that could not delete it
    refresh = stub_token_endpoint('https://auth.example.com')

    expect(provider.access_token).to be_nil
    expect(refresh).not_to have_been_requested
  end

  it 'does not refresh a token when the current authorization server is unknown' do
    token = MCPClient::Auth::Token.new(access_token: 'old', expires_in: 0, refresh_token: 'r',
                                       issuer: 'https://auth.example.com')
    storage.set_token(server_url, token)
    storage.set_client_info(server_url, client_info(registration_type: 'cimd'))
    provider = provider_for
    allow(provider).to receive(:discover_authorization_server).and_return(nil)

    expect(provider.access_token).to be_nil
  end

  it 'stops presenting a token whose issuer a 401 challenge has replaced' do
    storage.set_server_metadata(server_url, as_meta)
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'alice', expires_in: 3600,
                                                             issuer: 'https://auth.example.com'))
    provider = provider_for
    prm = { 'resource' => server_url, 'authorization_servers' => ['https://other.example.com'] }
    stub_request(:get, 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp')
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: prm.to_json)
    challenge = 'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp"'
    response = instance_double(Faraday::Response, status: 401, headers: { 'WWW-Authenticate' => challenge })

    provider.handle_unauthorized_response(response)

    expect(provider.access_token).to be_nil
  end

  it 'records the iss advertisement with the request and applies it to error responses' do
    storage.set_client_info(server_url, client_info(registration_type: 'cimd'))
    provider = provider_for
    stub_discovery(provider, as_meta(authorization_response_iss_parameter_supported: true))
    provider.start_authorization_flow
    state = storage.get_state(server_url)
    expect(storage.get_pkce(server_url).iss_parameter_supported).to be(true)
    expect(MCPClient::Auth::PKCE.from_h(storage.get_pkce(server_url).to_h).iss_parameter_supported).to be(true)
    # The cache now says otherwise (another AS), but the request's own record rules.
    storage.set_server_metadata(server_url, as_meta(authorization_response_iss_parameter_supported: false))

    expect { provider.authorization_error_message('error' => 'access_denied', 'state' => state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /iss/)
  end

  it 'compares metadata issuers byte for byte' do
    storage.set_client_info(server_url, client_info)
    provider = provider_for
    stub_discovery(provider, as_meta(issuer: 'https://auth.example.com'), advertised: 'https://auth.example.com/')

    expect { provider.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError, /issuer/)
  end

  it 'sanitizes a rejected metadata issuer before it reaches the error' do
    storage.set_client_info(server_url, client_info)
    provider = provider_for
    forged = ['https://honest.example', 'INFO stolen'].join("\n")
    stub_discovery(provider, as_meta(issuer: forged), advertised: 'https://attacker.example')

    expect { provider.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError) { |e|
      expect(e.message).not_to include("\nINFO stolen")
    }
  end
end
