# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, forty-first review round: credentials that
# name no authorization server are never presented on a refresh, expired or
# not; a validated change of authorization server ends the authorization
# requests still pending with the previous one for every provider sharing
# the storage; and two refreshes of one rotating refresh token leave exactly
# one pair behind.
RSpec.describe 'MCP 2026-07-28 authorization — round 41' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer_a) { 'https://as-a.example.com' }
  let(:issuer_b) { 'https://as-b.example.com' }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def server_metadata(iss)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      code_challenge_methods_supported: ['S256']
    )
  end

  def client_info(id, iss, secret: nil, expires_at: nil)
    MCPClient::Auth::ClientInfo.new(
      client_id: id, client_secret: secret, client_secret_expires_at: expires_at,
      issuer: iss, registration_type: 'pre_registered',
      metadata: MCPClient::Auth::ClientMetadata.new(
        redirect_uris: [redirect_uri], token_endpoint_auth_method: secret ? 'client_secret_post' : 'none'
      )
    )
  end

  def token_for(iss, access_token, refresh: nil, expires_in: 3600)
    MCPClient::Auth::Token.new(access_token: access_token, expires_in: expires_in,
                               refresh_token: refresh, issuer: iss)
  end

  def token_body(access_token, refresh: nil)
    { status: 200, headers: json,
      body: { 'access_token' => access_token, 'token_type' => 'Bearer', 'expires_in' => 3600,
              'refresh_token' => refresh }.compact.to_json }
  end

  def authorization_header_for(provider)
    request = Faraday::Request.new
    request.headers = {}
    provider.apply_authorization(request)
    request.headers['Authorization']
  end

  def param_in(url, name)
    URI.decode_www_form(URI.parse(url).query).to_h[name]
  end

  # A validated 401 challenge naming B, handled by `provider` — and nothing
  # more: B's own metadata is neither fetched nor cached.
  def challenge_to_b(provider)
    stub_request(:get, prm_url).to_return(
      status: 200, headers: json, body: { 'resource' => server_url, 'authorization_servers' => [issuer_b] }.to_json
    )
    header = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: header))
  end

  # ------------------------------------------------------------- codex 1
  describe 'expired pre-registered credentials that name no authorization server' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_token(server_url, token_for(issuer_b, 'stale-b', refresh: 'refresh-b', expires_in: -1))
      storage.set_client_info(server_url, client_info('client-of-a', nil, secret: 'secret-of-a',
                                                                          expires_at: Time.now.to_i - 60))
    end

    it 'are not presented to the authorization server the refresh would go to' do
      refresh = stub_request(:post, "#{issuer_b}/token")

      expect(provider_for.access_token).to be_nil
      expect(refresh).not_to have_been_requested
    end

    it 'give way to the credentials kept under that server\'s own key' do
      provider = provider_for
      storage.set_client_info(provider.client_registration_key(issuer_b), client_info('client-of-b', issuer_b))
      refresh = stub_request(:post, "#{issuer_b}/token")
                .with(body: hash_including('client_id' => 'client-of-b', 'refresh_token' => 'refresh-b'))
                .to_return(token_body('fresh-b', refresh: 'refresh-b2'))

      expect(provider.access_token&.access_token).to eq('fresh-b')
      expect(refresh).to have_been_requested
    end
  end

  # ------------------------------------------------------------- codex 2
  describe 'a code exchange answered after another provider validated a switch to B' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      storage.set_token(server_url, token_for(issuer_a, 'token-a'))
    end

    it 'is refused before B was ever discovered, and nothing of A is stored or presented' do
      first = provider_for
      state = param_in(first.start_authorization_flow, 'state')
      stub_request(:post, "#{issuer_a}/token").to_return do
        challenge_to_b(provider_for)
        token_body('late-a')
      end

      expect { first.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed/)
      expect(storage.get_token(server_url)&.access_token).not_to eq('late-a')
      expect(storage.get_token(first.client_registration_key(issuer_a))&.access_token).not_to eq('late-a')
      expect(first.access_token).to be_nil
      expect(authorization_header_for(first)).to be_nil
    end

    it 'still completes a request the switch did not touch: one made with the server in use' do
      first = provider_for
      state = param_in(first.start_authorization_flow, 'state')
      stub_request(:post, "#{issuer_a}/token").to_return(token_body('exchanged-a'))

      expect(first.complete_authorization_flow('code', state).access_token).to eq('exchanged-a')
      expect(authorization_header_for(first)).to eq('Bearer exchanged-a')
    end
  end

  # ------------------------------------------------------------- codex coverage
  describe 'two refreshes of one rotating refresh token answered in reverse order' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      storage.set_token(server_url, token_for(issuer_a, 'old', refresh: 'r1', expires_in: 60))
    end

    it 'keeps exactly the pair that landed first, and both callers present it' do
      slow = provider_for
      fast = provider_for
      nested = false
      posted = []
      stub_request(:post, "#{issuer_a}/token").to_return do |request|
        posted << URI.decode_www_form(request.body).to_h['refresh_token']
        if nested
          token_body('t2', refresh: 'r2')
        else
          nested = true
          expect(authorization_header_for(fast)).to eq('Bearer t2')
          token_body('t3', refresh: 'r3')
        end
      end

      expect(authorization_header_for(slow)).to eq('Bearer t2')
      expect(posted).to eq(%w[r1 r1])
      stored = storage.get_token(server_url)
      expect([stored.access_token, stored.refresh_token]).to eq(%w[t2 r2])
      expect(authorization_header_for(fast)).to eq('Bearer t2')
    end
  end

  # ------------------------------------------------------------- grok 1 & 2
  # A 403 insufficient_scope is a step-up: the token in hand is still valid
  # and the challenge's scope is authoritative (MCP 2026-07-28 step-up
  # authorization) — whatever its resource_metadata is worth. A document that
  # is fetched and refused, an empty authorization_servers list, or an
  # unacceptable metadata URL says nothing about the authorization server in
  # use: the known server stays, the valid token stays presented, and the
  # step-up requests the union of what was granted and what was challenged.
  describe 'a 403 insufficient_scope challenge whose resource metadata is refused' do
    let(:as_a) { 'https://auth.example.com' }

    def step_up(url = prm_url)
      header = { 'WWW-Authenticate' => 'Bearer error="insufficient_scope", scope="files:write", ' \
                                       "resource_metadata=\"#{url}\"" }
      instance_double(Faraday::Response, headers: header)
    end

    def stepped_up(provider, challenge)
      provider.handle_unauthorized_response(challenge)
    rescue MCPClient::Errors::ConnectionError
      # the transport surfaces the challenge as InsufficientScopeError
    end

    def expect_step_up_from(provider)
      expect(provider.challenge_scope).to eq('files:write')
      expect(provider.access_token&.access_token).to eq('valid')
      expect(authorization_header_for(provider)).to eq('Bearer valid')
      stub_request(:get, "#{as_a}/.well-known/oauth-authorization-server")
        .to_return(status: 200, headers: json, body: server_metadata(as_a).to_h.to_json)
      expect(param_in(provider.start_authorization_flow, 'scope').split).to contain_exactly('files:read', 'files:write')
    end

    before do
      storage.set_server_metadata(server_url, server_metadata(as_a))
      storage.set_client_info(server_url, client_info('client-a', as_a))
      storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'valid', expires_in: 3600,
                                                               scope: 'files:read', issuer: as_a))
    end

    it 'keeps the token and steps up when the document names another resource' do
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => 'https://mcp.example.com', 'authorization_servers' => [as_a] }.to_json
      )
      provider = provider_for
      stepped_up(provider, step_up)

      expect_step_up_from(provider)
    end

    it 'keeps the token and steps up when the document names no authorization server' do
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json, body: { 'resource' => server_url, 'authorization_servers' => [] }.to_json
      )
      provider = provider_for
      stepped_up(provider, step_up)

      expect_step_up_from(provider)
    end

    it 'keeps the token and steps up when the metadata URL itself is unacceptable' do
      provider = provider_for
      stepped_up(provider, step_up('http://mcp.example.com/.well-known/oauth-protected-resource/mcp'))

      expect_step_up_from(provider)
    end

    it 'still refuses the document for a challenge that is not a step-up' do
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => 'https://mcp.example.com', 'authorization_servers' => [as_a] }.to_json
      )
      provider = provider_for
      header = { 'WWW-Authenticate' => "Bearer error=\"invalid_token\", resource_metadata=\"#{prm_url}\"" }

      expect { provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: header)) }
        .to raise_error(MCPClient::Errors::ConnectionError)
      expect(provider.access_token).to be_nil
    end

    it 'counts the scope of a 2025-11-25 token that names no issuer, on a provider built afterwards' do
      storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'valid', expires_in: 3600,
                                                               scope: 'files:read'))
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json, body: { 'resource' => server_url, 'authorization_servers' => [as_a] }.to_json
      )
      provider = provider_for
      stepped_up(provider, step_up)

      # Authorizing BEFORE anything read (and bound) the legacy record: the
      # union must still count what that record says was granted.
      stub_request(:get, "#{as_a}/.well-known/oauth-authorization-server")
        .to_return(status: 200, headers: json, body: server_metadata(as_a).to_h.to_json)
      expect(param_in(provider.start_authorization_flow, 'scope').split).to contain_exactly('files:read', 'files:write')
      expect(authorization_header_for(provider)).to eq('Bearer valid')
    end
  end
end
