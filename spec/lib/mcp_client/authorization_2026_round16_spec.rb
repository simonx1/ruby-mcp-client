# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, sixteenth review round: a successful same-
# server challenge during a flow does not fail the callback precheck, a
# refused challenge does not latch the provider against a later valid one,
# and peer-controlled metadata values are sanitized in refusals.
RSpec.describe 'MCP 2026-07-28 authorization — round 16' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:json) { { 'Content-Type' => 'application/json' } }

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

  def challenge(prm)
    stub_request(:get, prm_url).to_return(status: 200, headers: json, body: prm.to_json)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
  end

  def started_state
    url = provider.start_authorization_flow
    URI.decode_www_form(URI.parse(url).query).to_h['state']
  end

  it 'accepts the callback after a successful challenge naming the same authorization server' do
    state = started_state
    challenge({ 'resource' => server_url, 'authorization_servers' => ['https://auth.example.com'] })
    stub_request(:post, 'https://auth.example.com/token')
      .to_return(status: 200, headers: json,
                 body: { access_token: 'fresh', token_type: 'Bearer', expires_in: 3600 }.to_json)

    expect { provider.validate_authorization_response!(state) }.not_to raise_error
    expect(provider.complete_authorization_flow('code', state).access_token).to eq('fresh')
  end

  it 'refuses a challenge whose metadata advertises no authorization server' do
    expect { challenge({ 'resource' => server_url, 'authorization_servers' => [] }) }
      .to raise_error(MCPClient::Errors::ConnectionError, /authorization_servers/)
    expect(provider.instance_variable_get(:@challenge_resource_metadata)).to be_nil
  end

  it 'recovers from a refused challenge when a later valid one arrives' do
    begin
      challenge({ 'resource' => 'https://other.example.com/mcp',
                  'authorization_servers' => ['https://other.example.com'] })
    rescue MCPClient::Errors::ConnectionError
      nil
    end
    expect(provider.instance_variable_get(:@resource_metadata)).to be_nil

    challenge({ 'resource' => server_url, 'authorization_servers' => ['https://auth.example.com'] })

    expect { provider.start_authorization_flow }.not_to raise_error
  end

  it 'sanitizes peer-controlled metadata values in a refusal' do
    forged = ['http://evil.example/', 'WARN stolen'].join("\n")
    expect { challenge({ 'resource' => server_url, 'authorization_servers' => [forged] }) }
      .to raise_error(MCPClient::Errors::ConnectionError) { |e| expect(e.message).not_to include("\nWARN") }

    forged_resource = ['https://other.example.com/mcp', 'WARN stolen'].join("\n")
    expect { challenge({ 'resource' => forged_resource, 'authorization_servers' => ['https://auth.example.com'] }) }
      .to raise_error(MCPClient::Errors::ConnectionError) { |e| expect(e.message).not_to include("\nWARN") }
  end
end
