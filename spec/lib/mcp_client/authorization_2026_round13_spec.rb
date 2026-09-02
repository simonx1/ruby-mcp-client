# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, thirteenth review round: a challenge retires
# the stored token only once its metadata passed the checks discovery
# applies, and Token#to_h keeps its legacy keys.
RSpec.describe 'MCP 2026-07-28 authorization — round 13' do
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

  def provider_with_token
    storage.set_server_metadata(server_url, as_meta)
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'alice', expires_in: 3600,
                                                             issuer: 'https://auth.example.com'))
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: storage)
  end

  def challenge(provider, prm)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: prm.to_json)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    response = instance_double(Faraday::Response, status: 401, headers: headers)
    provider.handle_unauthorized_response(response)
  rescue MCPClient::Errors::ConnectionError
    nil
  end

  it 'keeps the token when the challenge metadata names another resource' do
    provider = provider_with_token
    challenge(provider, { 'resource' => 'https://other.example.com/mcp',
                          'authorization_servers' => ['https://other.example.com'] })

    expect(provider.access_token&.access_token).to eq('alice')
  end

  it 'keeps the token when the advertised authorization server is not an acceptable URL' do
    provider = provider_with_token
    challenge(provider, { 'resource' => server_url, 'authorization_servers' => ['http://10.0.0.1/'] })

    expect(provider.access_token&.access_token).to eq('alice')
  end

  it 'retires the token when validated metadata names another authorization server' do
    provider = provider_with_token
    challenge(provider, { 'resource' => server_url, 'authorization_servers' => ['https://other.example.com'] })

    expect(provider.access_token).to be_nil
  end

  it 'keeps every legacy key in Token#to_h and adds the issuer only when set' do
    bare = MCPClient::Auth::Token.new(access_token: 'a')
    expect(bare.to_h.keys).to contain_exactly(:access_token, :token_type, :expires_in, :scope, :refresh_token,
                                              :expires_at)
    expect(bare.to_h[:refresh_token]).to be_nil

    bound = MCPClient::Auth::Token.new(access_token: 'a', issuer: 'https://auth.example.com')
    expect(bound.to_h[:issuer]).to eq('https://auth.example.com')
    expect(MCPClient::Auth::Token.from_h(bound.to_h).issuer).to eq('https://auth.example.com')
  end
end
