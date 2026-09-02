# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, fourteenth review round: a challenge whose
# metadata discovery would reject is refused outright (never half-applied),
# and the browser precheck sees every pending challenge condition the flow
# completion checks.
RSpec.describe 'MCP 2026-07-28 authorization — round 14' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def client_info
    MCPClient::Auth::ClientInfo.new(client_id: 'pre-registered', registration_type: 'pre_registered',
                                    issuer: 'https://auth.example.com',
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]))
  end

  def provider
    @provider ||= begin
      storage.set_server_metadata(server_url, as_meta)
      storage.set_client_info(server_url, client_info)
      MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                         storage: storage)
    end
  end

  def challenge(prm_status: 200, prm: nil)
    stub_request(:get, prm_url)
      .to_return(status: prm_status, headers: { 'Content-Type' => 'application/json' }, body: prm.to_json)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
  end

  def started_state
    url = provider.start_authorization_flow
    URI.decode_www_form(URI.parse(url).query).to_h['state']
  end

  it 'refuses a challenge naming an unacceptable authorization server and keeps nothing of it' do
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'alice', expires_in: 3600,
                                                             issuer: 'https://auth.example.com'))
    expect { challenge(prm: { 'resource' => server_url, 'authorization_servers' => ['http://10.0.0.1/'] }) }
      .to raise_error(MCPClient::Errors::ConnectionError, /HTTPS/)

    expect(provider.instance_variable_get(:@challenge_resource_metadata)).to be_nil
    expect(provider.access_token&.access_token).to eq('alice')
  end

  it 'refuses a challenge whose metadata names another resource' do
    expect do
      challenge(prm: { 'resource' => 'https://other.example.com/mcp',
                       'authorization_servers' => ['https://other.example.com'] })
    end
      .to raise_error(MCPClient::Errors::ConnectionError, /resource/)

    expect(provider.instance_variable_get(:@challenge_resource_metadata)).to be_nil
  end

  it 'rejects a callback at the precheck while a refused challenge is outstanding' do
    state = started_state
    begin
      challenge(prm: { 'resource' => server_url, 'authorization_servers' => ['http://10.0.0.1/'] })
    rescue MCPClient::Errors::ConnectionError
      nil
    end

    expect { provider.validate_authorization_response!(state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /challenge/)
  end

  it 'rejects a callback at the precheck while a challenge metadata fetch is pending' do
    state = started_state
    begin
      challenge(prm_status: 502)
    rescue MCPClient::Errors::ConnectionError
      nil
    end

    expect { provider.validate_authorization_response!(state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /challenge/)
  end
end
