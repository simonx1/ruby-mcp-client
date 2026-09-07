# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, forty-third review round: a challenge this
# client cannot act on leaves the recorded challenge state alone, and the
# credentials a refresh presents are the ones an authorization request would
# be made with — an expired secret is not resurrected by either path.
RSpec.describe 'MCP 2026-07-28 authorization — round 43' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer_a) { 'https://as-a.example.com' }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage, **opts)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store, **opts)
  end

  def server_metadata(iss, scopes: nil)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      code_challenge_methods_supported: ['S256'], scopes_supported: scopes
    )
  end

  def param_in(url, name)
    URI.decode_www_form(URI.parse(url).query).to_h[name]
  end

  def challenge(provider, header_value)
    provider.handle_unauthorized_response(
      instance_double(Faraday::Response, headers: { 'WWW-Authenticate' => header_value })
    )
  end

  # ------------------------------------------------------------- grok (challenge state)
  # The scope a Bearer challenge names is authoritative for the request it
  # answers, and a Bearer challenge carrying none resets it. A challenge of
  # some other scheme is not a Bearer challenge at all: this client cannot
  # act on it, so it says nothing about which scopes the resource wants and
  # must not erase what the Bearer challenge asked for.
  describe 'a WWW-Authenticate challenge of a scheme this client cannot act on' do
    before do
      storage.set_client_info(
        server_url,
        MCPClient::Auth::ClientInfo.new(
          client_id: 'client-a', issuer: issuer_a, registration_type: 'pre_registered',
          metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri],
                                                        token_endpoint_auth_method: 'none')
        )
      )
      stub_request(:get, "#{issuer_a}/.well-known/oauth-authorization-server").to_return(
        status: 200, headers: json, body: server_metadata(issuer_a, scopes: %w[files:read files:write]).to_h.to_json
      )
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => server_url, 'authorization_servers' => [issuer_a] }.to_json
      )
    end

    it 'leaves the scope an earlier Bearer challenge required' do
      provider = provider_for
      challenge(provider, 'Bearer error="insufficient_scope", scope="files:write"')

      challenge(provider, 'Basic realm="internal"')

      expect(param_in(provider.start_authorization_flow, 'scope').to_s.split).to include('files:write')
    end

    it 'is not taken for a step-up of its own' do
      provider = provider_for

      expect(challenge(provider, 'Basic realm="internal"')).to be_nil
    end

    # The reset itself is the Bearer challenge's to make: one that carries no
    # scope says this request needs none in particular.
    it 'still lets a later Bearer challenge without a scope reset it' do
      provider = provider_for
      challenge(provider, 'Bearer error="insufficient_scope", scope="files:write"')

      challenge(provider, 'Bearer error="invalid_token"')

      expect(param_in(provider.start_authorization_flow, 'scope').to_s.split).not_to include('files:write')
    end
  end

  # ------------------------------------------------------------- grok (expired secret)
  # "The credentials a refresh presents are the ones an authorization request
  # would be made with." An authorization request discards a record whose
  # secret has expired and registers again (registration_store.rb
  # #usable_client_info); the refresh path must not present the very secret
  # it filtered out for being expired.
  describe 'a stored registration whose client secret has expired' do
    let(:expired_client) do
      MCPClient::Auth::ClientInfo.new(
        client_id: 'client-a', client_secret: 'expired-secret',
        client_id_issued_at: Time.now.to_i - 7200, client_secret_expires_at: Time.now.to_i - 60,
        issuer: issuer_a, registration_type: 'dynamic',
        metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
      )
    end

    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, expired_client)
      storage.set_token(
        server_url,
        MCPClient::Auth::Token.new(access_token: 'stale', expires_in: -60, refresh_token: 'r-old',
                                   issuer: issuer_a)
      )
      stub_request(:get, "#{issuer_a}/.well-known/oauth-authorization-server").to_return(
        status: 200, headers: json, body: server_metadata(issuer_a).to_h.to_json
      )
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => server_url, 'authorization_servers' => [issuer_a] }.to_json
      )
    end

    it 'is never presented to the token endpoint by a refresh' do
      token_endpoint = stub_request(:post, "#{issuer_a}/token")
      provider = provider_for

      # The expired access token would be refreshed here if the credentials
      # allowed it; with none this client may present, nothing goes out and
      # the host is left to authorize again.
      expect(provider.access_token).to be_nil
      expect(token_endpoint).not_to have_been_requested
    end

    it 'is not what a still-valid secret does' do
      valid = MCPClient::Auth::ClientInfo.new(
        client_id: 'client-a', client_secret: 'live-secret',
        client_id_issued_at: Time.now.to_i - 7200, client_secret_expires_at: Time.now.to_i + 3600,
        issuer: issuer_a, registration_type: 'dynamic',
        metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
      )
      storage.set_client_info(server_url, valid)
      stub_request(:post, "#{issuer_a}/token")
        .to_return(status: 200, headers: json,
                   body: { access_token: 'fresh', token_type: 'Bearer', expires_in: 3600 }.to_json)

      expect(provider_for.access_token&.access_token).to eq('fresh')
      # RFC 7591's default authenticates at the token endpoint with HTTP
      # Basic, so the secret rides in the header rather than the body.
      basic = "Basic #{Base64.strict_encode64('client-a:live-secret')}"
      expect(a_request(:post, "#{issuer_a}/token").with(headers: { 'Authorization' => basic }))
        .to have_been_made
    end
  end
end
