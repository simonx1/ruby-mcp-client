# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, eighteenth review round: accepting a new
# challenge metadata URL forgets the previous document and refusal before
# the fetch, so a failed fetch leaves the flow waiting on the URL the
# current WWW-Authenticate header named.
RSpec.describe 'MCP 2026-07-28 authorization — round 18' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:first_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:second_url) { 'https://mcp.example.com/prm-v2.json' }

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
                                         storage: storage).tap do |p|
        allow(p).to receive(:fetch_server_metadata).and_return(as_meta)
      end
    end
  end

  def challenge(url, status: 200, prm: nil)
    stub_request(:get, url).to_return(status: status, headers: json, body: prm.to_json)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
  rescue MCPClient::Errors::ConnectionError
    nil
  end

  it 'forgets the previous document when a new challenge URL cannot be fetched' do
    url = provider.start_authorization_flow
    state = URI.decode_www_form(URI.parse(url).query).to_h['state']
    challenge(first_url, prm: { 'resource' => server_url, 'authorization_servers' => ['https://auth.example.com'] })
    challenge(second_url, status: 502)

    expect(provider.instance_variable_get(:@challenge_resource_metadata)).to be_nil
    expect { provider.validate_authorization_response!(state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /challenge/)

    stub_request(:get, second_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => ['https://other.example.com'] }.to_json)
    expect(provider.send(:challenge_or_well_known_resource_metadata).authorization_servers)
      .to eq(['https://other.example.com'])
  end

  it 'lets a new challenge URL supersede a refusal even when its first fetch fails' do
    challenge(first_url, prm: { 'resource' => 'https://other.example.com/mcp',
                                'authorization_servers' => ['https://other.example.com'] })
    expect(provider.instance_variable_get(:@challenge_error)).to be_a(String)

    challenge(second_url, status: 502)
    expect(provider.instance_variable_get(:@challenge_error)).to be_nil

    stub_request(:get, second_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => ['https://auth.example.com'] }.to_json)
    expect { provider.start_authorization_flow }.not_to raise_error
  end
end
