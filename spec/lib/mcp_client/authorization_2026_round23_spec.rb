# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twenty-third round: while a challenge's
# metadata URL is pending and unresolved, no cached token is presented; the
# next access retries that URL first.
RSpec.describe 'MCP 2026-07-28 authorization — round 23' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

  def as_meta(issuer:)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'])
  end

  def provider_with_long_lived_token
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old-tok', expires_in: 3600,
                                                             issuer: 'https://old.example.com'))
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: 'http://localhost:1/cb',
                                       logger: logger, storage: storage)
  end

  def failed_challenge(provider)
    stub_request(:get, prm_url).to_return(status: 502)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
  rescue MCPClient::Errors::ConnectionError
    nil
  end

  it 'presents no cached token while the challenge metadata is unresolved' do
    provider = provider_with_long_lived_token
    failed_challenge(provider)
    request = instance_double(Faraday::Request, headers: {})

    provider.apply_authorization(request)

    expect(request.headers['Authorization']).to be_nil
    expect(provider.access_token).to be_nil
  end

  it 'retries the pending URL on access and retires the token when it names another server' do
    provider = provider_with_long_lived_token
    failed_challenge(provider)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => ['https://auth.example.com'] }.to_json)
    prm_fetches = 0
    allow(provider).to receive(:fetch_resource_metadata).and_wrap_original do |m, *args, **kw|
      prm_fetches += 1
      m.call(*args, **kw)
    end

    expect(provider.access_token).to be_nil
    expect(prm_fetches).to eq(1)
    expect(provider.instance_variable_get(:@challenge_resource_metadata)&.authorization_servers)
      .to eq(['https://auth.example.com'])
    expect(provider.instance_variable_get(:@challenge_metadata_url)).not_to be_nil
  end

  it 'presents the token again once the retried URL names its own server' do
    provider = provider_with_long_lived_token
    failed_challenge(provider)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => ['https://old.example.com'] }.to_json)

    expect(provider.access_token&.access_token).to eq('old-tok')
  end
end
