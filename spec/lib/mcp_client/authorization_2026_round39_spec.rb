# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'mcp_client/auth/browser_oauth'

# MCP 2026-07-28 authorization, thirty-ninth review round: a token is bound
# to the RESOURCE its request named as much as to its issuer, a scope the
# token response omits is the scope that was requested, credentials seeded
# only under the authorization server key work as documented, a
# pre-registered record wins over a dynamic one sharing its client id, a
# completion's cleanup never deletes a newer flow's record, and a 403
# step-up challenge does not withhold a still-valid token.
RSpec.describe 'MCP 2026-07-28 authorization — round 39' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:other_url) { 'https://other-mcp.example.com/mcp' }
  let(:issuer) { 'https://auth.example.com' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

  def as_meta(issuer: self.issuer, **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def metadata(auth_method: 'none')
    MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri], token_endpoint_auth_method: auth_method)
  end

  def client_info(client_id: 'pre-registered', auth_method: 'none', **opts)
    opts = { registration_type: 'pre_registered', issuer: issuer }.merge(opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id, metadata: metadata(auth_method: auth_method), **opts)
  end

  def provider_for(store = storage, url: server_url, **opts)
    MCPClient::Auth::OAuthProvider.new(server_url: url, redirect_uri: redirect_uri, logger: logger,
                                       storage: store, **opts)
  end

  def seed(url, store = storage)
    store.set_server_metadata(url, as_meta)
    store.set_client_info(url, client_info)
  end

  def token_for(access_token, **extra)
    MCPClient::Auth::Token.new(access_token: access_token, expires_in: 3600, issuer: issuer, **extra)
  end

  def token_body(access_token, **extra)
    { access_token: access_token, token_type: 'Bearer', expires_in: 3600 }.merge(extra).to_json
  end

  def param_in(url, name)
    URI.decode_www_form(URI.parse(url).query).to_h[name]
  end

  def authorization_header(provider)
    request = Faraday::Request.create(:get) { |q| q.headers = {} }
    provider.apply_authorization(request)
    request.headers['Authorization']
  end

  def challenge(params)
    instance_double(Faraday::Response, headers: { 'WWW-Authenticate' => "Bearer #{params}" })
  end

  # ------------------------------------------------------------- finding 1
  describe 'a provider retargeted to another resource of the same authorization server mid-request' do
    before do
      seed(server_url)
      seed(other_url)
    end

    it 'refuses the code exchange rather than storing the token for the other resource' do
      provider = provider_for
      state = param_in(provider.start_authorization_flow, 'state')
      stub_request(:post, "#{issuer}/token").to_return do |_request|
        provider.server_url = other_url
        { status: 200, headers: json, body: token_body('issued-for-one') }
      end

      expect { provider.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /resource changed/)
      expect(storage.get_token(other_url)).to be_nil
      expect(storage.get_token(server_url)).to be_nil
      expect(authorization_header(provider)).to be_nil
    end

    it 'discards a refreshed token and presents nothing of the previous resource' do
      storage.set_token(server_url, token_for('stale', refresh_token: 'r').then do |t|
        MCPClient::Auth::Token.new(access_token: t.access_token, expires_in: 100, refresh_token: 'r', issuer: issuer)
      end)
      provider = provider_for
      stub_request(:post, "#{issuer}/token").to_return do |_request|
        provider.server_url = other_url
        { status: 200, headers: json, body: token_body('refreshed') }
      end

      expect(provider.access_token).to be_nil
      expect(storage.get_token(other_url)).to be_nil
      expect(authorization_header(provider)).to be_nil
      expect(storage.get_token(server_url).access_token).to eq('stale')
    end
  end

  # ------------------------------------------------------------- finding 2
  describe 'a token response that omits scope (RFC 6749 Section 5.1: identical to the requested one)' do
    it 'records the requested scope as granted, so a rebuilt provider steps up from it' do
      seed(server_url)
      provider = provider_for(scope: 'files:read')
      state = param_in(provider.start_authorization_flow, 'state')
      stub_request(:post, "#{issuer}/token").to_return(status: 200, headers: json, body: token_body('fresh'))

      expect(provider.complete_authorization_flow('code', state).scope).to eq('files:read')
      expect(storage.get_token(server_url).scope).to eq('files:read')

      rebuilt = provider_for
      rebuilt.instance_variable_set(:@challenge_scope, 'files:write')
      expect(param_in(rebuilt.start_authorization_flow, 'scope').split).to contain_exactly('files:read', 'files:write')
    end

    it 'keeps the scope of the token being refreshed' do
      seed(server_url)
      storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old', expires_in: 100, refresh_token: 'r',
                                                               scope: 'files:read', issuer: issuer))
      stub_request(:post, "#{issuer}/token").to_return(status: 200, headers: json, body: token_body('new'))

      expect(provider_for.access_token.scope).to eq('files:read')
      expect(storage.get_token(server_url).scope).to eq('files:read')
    end

    it 'steps up from the scope the token alone records when nothing is configured' do
      seed(server_url)
      storage.set_token(server_url, token_for('granted', scope: 'files:read'))
      provider = provider_for
      provider.instance_variable_set(:@challenge_scope, 'files:write')

      expect(param_in(provider.start_authorization_flow, 'scope').split).to contain_exactly('files:read', 'files:write')
    end
  end

  # ------------------------------------------------------------- finding 3
  describe 'credentials seeded only under the authorization server key' do
    it 'are used for that server, bound to it, without any registration' do
      storage.set_server_metadata(server_url, as_meta(registration_endpoint: "#{issuer}/register"))
      provider = provider_for
      storage.set_client_info(provider.client_registration_key(issuer), client_info(client_id: 'seeded', issuer: nil))
      registration = stub_request(:post, "#{issuer}/register")

      url = provider.start_authorization_flow

      expect(param_in(url, 'client_id')).to eq('seeded')
      expect(registration).not_to have_been_requested
      stored = storage.get_client_info(server_url)
      expect(stored.issuer).to eq(issuer)
      expect(stored).to be_pre_registered
    end
  end

  # ------------------------------------------------------------- finding 4
  describe 'a pre-registered record sharing a dynamic record client id' do
    it 'redeems the code with the pre-registered secret' do
      storage.set_server_metadata(server_url, as_meta)
      provider = provider_for
      storage.set_client_info(server_url, MCPClient::Auth::ClientInfo.new(
                                            client_id: 'shared', client_secret: 'old-secret', client_id_issued_at: 1,
                                            issuer: issuer, registration_type: 'dynamic',
                                            metadata: metadata(auth_method: 'client_secret_post')
                                          ))
      storage.set_client_info(provider.client_registration_key(issuer),
                              client_info(client_id: 'shared', client_secret: 'new-secret',
                                          auth_method: 'client_secret_post'))
      bodies = []
      stub_request(:post, "#{issuer}/token").to_return do |request|
        bodies << URI.decode_www_form(request.body).to_h
        { status: 200, headers: json, body: token_body('fresh') }
      end

      state = param_in(provider.start_authorization_flow, 'state')
      provider.complete_authorization_flow('code', state)

      expect(bodies.last['client_secret']).to eq('new-secret')
      expect(storage.get_client_info(server_url).client_secret).to eq('new-secret')
    end
  end

  # ------------------------------------------------------------- finding 5
  describe 'a completion whose cleanup races a newer flow of the same server' do
    # The newer flow starts AFTER cleanup has read the pending record and
    # BEFORE it deletes: the record it then deletes is the newer flow's.
    let(:barrier_storage) do
      Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        attr_accessor :on_get_pkce

        def get_pkce(url)
          record = super
          hook = @on_get_pkce
          @on_get_pkce = nil
          hook&.call
          record
        end
      end.new
    end

    it 'leaves the newer flow its PKCE record and state' do
      seed(server_url, barrier_storage)
      provider = provider_for(barrier_storage)
      first_state = param_in(provider.start_authorization_flow, 'state')
      second = nil
      stub_request(:post, "#{issuer}/token").to_return do |_request|
        if second.nil?
          barrier_storage.on_get_pkce = lambda {
            second = provider_for(barrier_storage).start_authorization_flow
          }
        end
        { status: 200, headers: json, body: token_body('first') }
      end

      expect(provider.complete_authorization_flow('code', first_state).access_token).to eq('first')
      expect(second).not_to be_nil
      expect(barrier_storage.get_state(server_url)).to eq(param_in(second, 'state'))
      expect(barrier_storage.get_pkce(server_url).code_challenge).to eq(param_in(second, 'code_challenge'))
      expect(provider_for(barrier_storage).complete_authorization_flow('code', param_in(second, 'state')).access_token)
        .to eq('first')
    end
  end

  # ------------------------------------------------------------- grok 1
  describe 'a 403 insufficient_scope challenge (step-up, not an authorization server change)' do
    let(:step_up) { challenge("error=\"insufficient_scope\", scope=\"files:write\", resource_metadata=\"#{prm_url}\"") }

    before do
      seed(server_url)
      storage.set_token(server_url, token_for('valid', scope: 'files:read'))
    end

    it 'keeps presenting the still-valid token when the resource metadata cannot be fetched' do
      stub_request(:get, prm_url).to_return(status: 503)
      provider = provider_for
      begin
        provider.handle_unauthorized_response(step_up)
      rescue MCPClient::Errors::ConnectionError
        # the transport swallows this: the challenge is surfaced as InsufficientScopeError
      end

      expect(provider.challenge_scope).to eq('files:write')
      expect(provider.access_token&.access_token).to eq('valid')
      expect(authorization_header(provider)).to eq('Bearer valid')
    end

    it 'keeps presenting the token when the metadata names the same server, and steps up from its scope' do
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json, body: { resource: server_url, authorization_servers: [issuer] }.to_json)
      stub_request(:get, "#{issuer}/.well-known/oauth-authorization-server")
        .to_return(status: 200, headers: json, body: as_meta.to_h.to_json)
      provider = provider_for
      provider.handle_unauthorized_response(step_up)

      expect(authorization_header(provider)).to eq('Bearer valid')
      expect(param_in(provider.start_authorization_flow, 'scope').split).to contain_exactly('files:read', 'files:write')
    end

    it 'still presents the token on the next transport request after the step-up error' do
      stub_request(:get, prm_url).to_return(status: 503)
      server = MCPClient::ServerHTTP.new(base_url: 'https://mcp.example.com', endpoint: '/mcp',
                                         oauth_provider: provider_for, logger: logger)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      authorizations = []
      answers = [
        { status: 403, headers: { 'WWW-Authenticate' => 'Bearer error="insufficient_scope", scope="files:write", ' \
                                                        "resource_metadata=\"#{prm_url}\"" }, body: '' },
        { status: 200, headers: json, body: { jsonrpc: '2.0', id: 1, result: { tools: [] } }.to_json }
      ]
      stub_request(:post, server_url).to_return do |request|
        authorizations << request.headers['Authorization']
        answers.shift
      end

      expect { server.rpc_request('tools/call', {}) }.to raise_error(MCPClient::Errors::InsufficientScopeError)
      begin
        server.rpc_request('tools/list', {})
      rescue MCPClient::Errors::MCPError
        # only the Authorization header of the second request matters here
      end

      expect(authorizations).to eq(['Bearer valid', 'Bearer valid'])
    end
  end

  # ------------------------------------------------------------- grok 3
  describe 'a challenge carrying a legacy resource= identifier and no resource_metadata' do
    it 'is not fetched as metadata, and discovery falls back to the well-known URIs' do
      storage.set_client_info(server_url, client_info)
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json, body: { resource: server_url, authorization_servers: [issuer] }.to_json)
      stub_request(:get, "#{issuer}/.well-known/oauth-authorization-server")
        .to_return(status: 200, headers: json, body: as_meta.to_h.to_json)
      provider = provider_for

      expect(provider.handle_unauthorized_response(challenge("realm=\"mcp\", resource=\"#{server_url}\""))).to be_nil
      expect(param_in(provider.start_authorization_flow, 'client_id')).to eq('pre-registered')
      expect(a_request(:get, server_url)).not_to have_been_made
      expect(a_request(:get, prm_url)).to have_been_made
    end

    it 'still honours a legacy resource= naming a protected resource metadata document' do
      legacy = 'https://mcp.example.com/.well-known/oauth-protected-resource'
      stub_request(:get, legacy)
        .to_return(status: 200, headers: json, body: { resource: server_url, authorization_servers: [issuer] }.to_json)

      expect(provider_for.handle_unauthorized_response(challenge("resource=\"#{legacy}\"")).authorization_servers)
        .to eq([issuer])
    end
  end

  # ------------------------------------------------------------- coverage
  describe 'authorization server metadata discovery' do
    it 'stops at the first well-known document naming the issuer' do
      storage.set_client_info(server_url, client_info)
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json, body: { resource: server_url, authorization_servers: [issuer] }.to_json)
      stub_request(:get, "#{issuer}/.well-known/oauth-authorization-server")
        .to_return(status: 200, headers: json, body: as_meta.to_h.to_json)
      oidc = stub_request(:get, "#{issuer}/.well-known/openid-configuration")

      provider_for.start_authorization_flow

      expect(oidc).not_to have_been_requested
    end
  end

  describe 'the dynamic registration application_type retry' do
    let(:registration_endpoint) { "#{issuer}/register" }
    let(:bodies) { [] }

    def registration(*answers)
      stub_request(:post, registration_endpoint).to_return do |request|
        bodies << JSON.parse(request.body)
        answers.shift
      end
    end

    before { storage.set_server_metadata(server_url, as_meta(registration_endpoint: registration_endpoint)) }

    it 'retries as native when the web type derived from an HTTPS redirect URI is rejected' do
      registration({ status: 400, headers: json, body: { error: 'invalid_redirect_uri' }.to_json },
                   { status: 201, headers: json, body: { client_id: 'dyn' }.to_json })

      provider_for(redirect_uri: 'https://app.example.com/callback').start_authorization_flow

      expect(bodies.map { |b| b['application_type'] }).to eq(%w[web native])
    end

    it 'reports the rejection after exactly two attempts when both types are refused' do
      registration({ status: 400, headers: json, body: { error: 'invalid_redirect_uri' }.to_json },
                   { status: 400, headers: json, body: { error: 'invalid_redirect_uri' }.to_json })

      expect { provider_for.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /invalid_redirect_uri/)
      expect(bodies.size).to eq(2)
    end
  end

  describe 'an error response of another issuer' do
    it 'shows none of error, error_description or error_uri, in the browser or the error' do
      storage.set_server_metadata(server_url, as_meta(authorization_response_iss_parameter_supported: true))
      storage.set_client_info(server_url, client_info)
      provider = provider_for
      browser = MCPClient::Auth::BrowserOAuth.new(provider, logger: logger)
      tcp_server = instance_double(TCPServer)
      client_socket = instance_double(TCPSocket)
      allow(TCPServer).to receive(:new).and_return(tcp_server)
      allow(tcp_server).to receive(:wait_readable).and_return(tcp_server)
      allow(tcp_server).to receive(:accept).and_return(client_socket)
      allow(tcp_server).to receive(:close)
      allow(client_socket).to receive(:setsockopt)
      allow(client_socket).to receive(:close)
      responses = []
      allow(client_socket).to receive(:print) { |data| responses << data }
      lines = nil
      allow(client_socket).to receive(:gets) do
        state = storage.get_state(server_url)
        query = 'error=SENTINEL-ERROR&error_description=SENTINEL-DESCRIPTION&error_uri=https%3A%2F%2Fevil.example%2F' \
                "SENTINEL-URI&state=#{state}&iss=https%3A%2F%2Fevil.example"
        lines ||= ["GET /callback?#{query} HTTP/1.1\r\n", "\r\n", nil]
        lines.shift
      end

      expect { browser.authenticate(timeout: 1, auto_open_browser: false) }
        .to raise_error(MCPClient::Errors::ConnectionError) { |e| expect(e.message).not_to include('SENTINEL') }
      expect(responses.join).not_to include('SENTINEL')
    end
  end

  describe 'a real provider behind the HTTP transport' do
    it 'presents the token bound to the discovered authorization server' do
      seed(server_url)
      storage.set_token(server_url, token_for('bound'))
      server = MCPClient::ServerHTTP.new(base_url: 'https://mcp.example.com', endpoint: '/mcp',
                                         oauth_provider: provider_for, logger: logger)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      authorizations = []
      stub_request(:post, server_url).to_return do |request|
        authorizations << request.headers['Authorization']
        { status: 200, headers: json, body: { jsonrpc: '2.0', id: 1, result: { tools: [] } }.to_json }
      end

      begin
        server.rpc_request('tools/list', {})
      rescue MCPClient::Errors::MCPError
        # only the Authorization header matters here
      end

      expect(authorizations).to eq(['Bearer bound'])
    end
  end

  describe MCPClient::Auth::Token do
    it 'reads a stored record without token_type back as a Bearer token' do
      expect(described_class.from_h('access_token' => 'stored', 'expires_in' => 3600).to_header).to eq('Bearer stored')
    end
  end
end
