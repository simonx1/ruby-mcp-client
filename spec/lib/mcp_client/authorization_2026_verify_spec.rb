# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'mcp_client/auth/browser_oauth'

# MCP 2026-07-28 authorization — verification pass over the whole series.
#
# Every earlier round hardened a decision the client makes at ONE point in
# time. This pass is about the time in between.
#
# A refresh is two events, not one: the request goes to the authorization
# server the token came from, and the response arrives — possibly much later —
# at a client whose authorization server may have changed meanwhile. Between
# the two, updated protected-resource metadata (or a 401 challenge) can select
# another server, retire the token that is being refreshed and store a token of
# the new server. The response of the old server then arrived at a client that
# accepted it, wrote it over the new server's token and presented it: the
# `refresh_permitted?` check made before the request was never repeated after
# it. Both halves need the check — refusing to present the bytes would still
# leave the new server's token overwritten in storage.
#
# Registration state is per authorization server (SEP-2352), and the client
# said so on the record while keeping every registration in ONE slot keyed by
# the resource URL. Two authorization servers behind one MCP server therefore
# could not both have credentials: configuring the second replaced the first,
# and selecting the first again produced "these credentials belong to another
# authorization server" instead of finding its registration.
#
# A callback is parsed into a Hash, where the last value of a repeated
# parameter silently wins. RFC 6749 Section 3.1 forbids a parameter more than
# once precisely because two readers then disagree about which value counts, so
# `?iss=attacker&iss=recorded` was accepted as if the attacker's value had never
# been sent.
#
# And RFC 6749 Section 7.1: "the client MUST NOT use an access token if it does
# not understand the token type". A DPoP or MAC token is not a bearer
# credential, and this client can only form a bearer header out of it — so it
# is refused wherever a token is issued, read back or presented, exactly as a
# record without token bytes is.
RSpec.describe 'MCP 2026-07-28 authorization — verification pass' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer_a) { 'https://as-a.example.com' }
  let(:issuer_b) { 'https://as-b.example.com' }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:state) { 'state-value' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def server_metadata(iss, registration: nil)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      registration_endpoint: registration, code_challenge_methods_supported: ['S256'],
      authorization_response_iss_parameter_supported: false
    )
  end

  def client_info(id, iss, type: 'pre_registered')
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: type,
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri],
                                                    token_endpoint_auth_method: 'none')
    )
  end

  def token_for(iss, access_token, refresh: nil, expires_in: 3600)
    MCPClient::Auth::Token.new(access_token: access_token, expires_in: expires_in,
                               refresh_token: refresh, issuer: iss)
  end

  def authorization_header_for(provider)
    request = Faraday::Request.new
    request.headers = {}
    provider.apply_authorization(request)
    request.headers['Authorization']
  end

  # A token of A that is still valid but inside the five-minute early-refresh
  # window, with everything a refresh at A needs.
  def store_refreshable_token(store = storage)
    store.set_server_metadata(server_url, server_metadata(issuer_a))
    store.set_client_info(server_url, client_info('client-a', issuer_a))
    store.set_token(server_url, token_for(issuer_a, 'token-a', refresh: 'refresh-a', expires_in: 60))
  end

  def challenge_headers(url)
    { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{url}\"" }
  end

  def prm_document(issuer)
    { 'resource' => server_url, 'authorization_servers' => [issuer] }
  end

  # ---------------------------------------------------------------- finding 1

  describe 'a refresh response that arrives after the authorization server switched' do
    # The interleaving, made deterministic: the stub answers A's refresh only
    # after the switch to B has happened, which is exactly what a refresh
    # request outstanding across the switch does.
    def switch_to_b
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_client_info(server_url, client_info('client-b', issuer_b))
      storage.set_token(server_url, token_for(issuer_b, 'token-b'))
    end

    def refresh_answers_after_the_switch
      stub_request(:post, "#{issuer_a}/token").to_return do
        switch_to_b
        { status: 200, headers: json,
          body: { 'access_token' => 'refreshed-a', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json }
      end
    end

    before { store_refreshable_token }

    # The request that triggers the refresh is the one the header is built
    # for: the refreshed token goes out on it without ever being asked which
    # authorization server it belongs to.
    it 'never presents the refreshed token of the authorization server that is no longer in use' do
      refresh_answers_after_the_switch
      provider = provider_for

      expect(authorization_header_for(provider)).not_to eq('Bearer refreshed-a')
      expect(authorization_header_for(provider)).to eq('Bearer token-b')
    end

    it 'leaves the token of the authorization server now in use in storage' do
      refresh_answers_after_the_switch

      provider_for.access_token

      expect(storage.get_token(server_url).access_token).to eq('token-b')
      expect(storage.get_token(server_url).issuer).to eq(issuer_b)
    end

    it 'hands the caller nothing rather than a token of the previous authorization server' do
      refresh_answers_after_the_switch

      expect(provider_for.access_token).to be_nil
    end

    it 'says why the refresh response was discarded' do
      refresh_answers_after_the_switch

      provider_for.access_token

      expect(log_output.string).to match(/authorization server changed/i)
    end

    it 'does not resurrect a token a challenge retired while the refresh was outstanding' do
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json, body: prm_document(issuer_b).to_json)
      provider = provider_for
      stub_request(:post, "#{issuer_a}/token").to_return do
        provider.handle_unauthorized_response(
          instance_double(Faraday::Response, headers: challenge_headers(prm_url))
        )
        { status: 200, headers: json,
          body: { 'access_token' => 'refreshed-a', 'token_type' => 'Bearer' }.to_json }
      end

      provider.access_token

      expect(storage.get_token(server_url)&.access_token).not_to eq('refreshed-a')
      expect(authorization_header_for(provider)).to be_nil
    end
  end

  # `refresh_permitted?` decides whether a refresh token — a credential in its
  # own right, and the one that mints new access tokens — may be sent at all.
  # Each of its three refusals is driven here, and each is pinned by the
  # refusal it logs: a token that never leaves because `access_token` exits
  # earlier would pass an example that only looks at the HTTP stub.
  describe 'the checks a refresh makes before a refresh token leaves the client' do
    it 'presents nothing at all when the stored token belongs to another authorization server' do
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_client_info(server_url, client_info('client-b', issuer_b))
      storage.set_token(server_url, token_for(issuer_a, 'token-a', refresh: 'refresh-a', expires_in: 60))
      at_a = stub_request(:post, "#{issuer_a}/token")
      at_b = stub_request(:post, "#{issuer_b}/token")

      expect(provider_for.access_token).to be_nil
      expect(at_a).not_to have_been_requested
      expect(at_b).not_to have_been_requested
    end

    it 'refuses the refresh itself when the token belongs to another authorization server' do
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_client_info(server_url, client_info('client-b', issuer_b))
      at_b = stub_request(:post, "#{issuer_b}/token")
      provider = provider_for

      refreshed = provider.send(:refresh_token, token_for(issuer_a, 'token-a', refresh: 'refresh-a', expires_in: 60))

      expect(refreshed).to be_nil
      expect(at_b).not_to have_been_requested
      expect(log_output.string).to match(/authorization server changed since it was issued/)
    end

    it 'never presents client credentials of another authorization server at a token endpoint' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-b', issuer_b))
      storage.set_token(server_url, token_for(issuer_a, 'token-a', refresh: 'refresh-a', expires_in: 60))
      at_a = stub_request(:post, "#{issuer_a}/token")

      expect(provider_for.access_token&.access_token).to eq('token-a')
      expect(at_a).not_to have_been_requested
      expect(log_output.string).to match(/credentials belong to another authorization server/)
    end

    it 'does not refresh a token that records no issuer once the authorization server changed' do
      stub_request(:get, prm_url).to_return(status: 200, headers: json, body: prm_document(issuer_b).to_json)
      stub_request(:get, "#{issuer_b}/.well-known/oauth-authorization-server")
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => issuer_b, 'authorization_endpoint' => "#{issuer_b}/authorize",
                           'token_endpoint' => "#{issuer_b}/token",
                           'code_challenge_methods_supported' => ['S256'] }.to_json)
      at_b = stub_request(:post, "#{issuer_b}/token")
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      provider = provider_for
      provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: challenge_headers(prm_url)))

      unbound = MCPClient::Auth::Token.new(access_token: 'legacy', expires_in: 60, refresh_token: 'refresh-legacy')
      expect(provider.send(:refresh_token, unbound)).to be_nil
      expect(at_b).not_to have_been_requested
      expect(log_output.string).to match(/records no issuer and the authorization server changed/)
    end
  end

  # ---------------------------------------------------------------- finding 2

  describe 'registration state for two authorization servers behind one resource' do
    it 'keeps the credentials of each authorization server under its own key' do
      provider = provider_for
      storage.set_client_info(provider.client_registration_key(issuer_a), client_info('client-a', issuer_a))
      storage.set_client_info(provider.client_registration_key(issuer_b), client_info('client-b', issuer_b))

      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      expect(provider_for.start_authorization_flow).to include('client_id=client-a')

      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      expect(provider_for.start_authorization_flow).to include('client_id=client-b')
    end

    it 'finds a registration another authorization server displaced from the resource slot' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      expect(provider_for.start_authorization_flow).to include('client_id=client-a')

      # The host configures B's pre-registered credentials for the same
      # resource: they take the one resource-keyed slot.
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_client_info(server_url, client_info('client-b', issuer_b))
      expect(provider_for.start_authorization_flow).to include('client_id=client-b')

      # Back at A, A's registration is found rather than reported as a
      # mismatch (SEP-2352: registration state is per authorization server).
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      expect(provider_for.start_authorization_flow).to include('client_id=client-a')
    end

    it 'keeps a dynamic registration made with an authorization server for a later return to it' do
      stub_request(:get, prm_url).to_return(status: 200, headers: json, body: prm_document(issuer_b).to_json)
      stub_request(:get, "#{issuer_b}/.well-known/oauth-authorization-server")
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => issuer_b, 'authorization_endpoint' => "#{issuer_b}/authorize",
                           'token_endpoint' => "#{issuer_b}/token",
                           'registration_endpoint' => "#{issuer_b}/register",
                           'code_challenge_methods_supported' => ['S256'] }.to_json)
      stub_request(:post, "#{issuer_b}/register")
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-b', 'redirect_uris' => [redirect_uri] }.to_json)
      at_a = stub_request(:post, "#{issuer_a}/register")
             .to_return(status: 201, headers: json,
                        body: { 'client_id' => 'dyn-a', 'redirect_uris' => [redirect_uri] }.to_json)
      storage.set_server_metadata(server_url, server_metadata(issuer_a, registration: "#{issuer_a}/register"))

      provider = provider_for
      expect(provider.start_authorization_flow).to include('client_id=dyn-a')

      # A 401 challenge moves the resource to B, which discards the
      # resource-slot registration of A and registers with B.
      provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: challenge_headers(prm_url)))
      expect(provider.start_authorization_flow).to include('client_id=dyn-b')
      expect(storage.get_client_info(server_url).client_id).to eq('dyn-b')

      # Back at A: the registration made with A is still there.
      storage.set_server_metadata(server_url, server_metadata(issuer_a, registration: "#{issuer_a}/register"))
      expect(provider_for.start_authorization_flow).to include('client_id=dyn-a')
      expect(at_a).to have_been_requested.once
    end

    # The per-issuer copy is a fallback, never an override: the resource slot
    # is where a host writes credentials, and rotating them there must not be
    # undone by the copy kept when the previous ones were used.
    it 'lets credentials rotated in the resource slot overrule the older copy kept for that server' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a1', issuer_a))
      expect(provider_for.start_authorization_flow).to include('client_id=client-a1')

      storage.set_client_info(server_url, client_info('client-a2', issuer_a))

      expect(provider_for.start_authorization_flow).to include('client_id=client-a2')
      key = provider_for.client_registration_key(issuer_a)
      expect(storage.get_client_info(key).client_id).to eq('client-a2')
    end

    it 'still reports pre-registered credentials of another authorization server when none exist for this one' do
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))

      expect { provider_for.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /belong to authorization server/)
    end
  end

  # ---------------------------------------------------------------- finding 3

  describe 'a callback that includes a parameter more than once' do
    def callback_result(query)
      store_pending_flow
      browser = MCPClient::Auth::BrowserOAuth.new(provider_for, callback_port: 1, callback_path: '/cb',
                                                                logger: logger)
      result = {}
      socket = instance_double('TCPSocket')
      allow(socket).to receive(:setsockopt)
      allow(socket).to receive(:print)
      allow(socket).to receive(:close)
      allow(socket).to receive(:gets).and_return("GET /cb?#{query} HTTP/1.1\r\n", "\r\n", nil)
      browser.send(:handle_http_request, socket, result, Mutex.new, ConditionVariable.new)
      result
    end

    def store_pending_flow
      metadata = server_metadata(issuer_a)
      storage.set_server_metadata(server_url, metadata)
      storage.set_state(server_url, state)
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      storage.set_pkce(server_url,
                       MCPClient::Auth::PKCE.new(issuer: issuer_a, iss_parameter_supported: false,
                                                 client_id: 'client-a', redirect_uri: redirect_uri))
    end

    it 'accepts a callback that carries each parameter once' do
      result = callback_result("code=the-code&state=#{state}&iss=#{CGI.escape(issuer_a)}")

      expect(result[:error]).to be_nil
      expect(result[:code]).to eq('the-code')
    end

    {
      'iss' => 'code=c&state=%<state>s&iss=https%%3A%%2F%%2Fevil.example.com&iss=%<issuer>s',
      'state' => 'code=c&state=other&state=%<state>s&iss=%<issuer>s',
      'code' => 'code=attacker&code=c&state=%<state>s&iss=%<issuer>s'
    }.each do |parameter, query|
      it "rejects a callback whose #{parameter} parameter is included twice" do
        result = callback_result(format(query, state: state, issuer: CGI.escape(issuer_a)))

        expect(result[:error]).to match(/more than once/)
        expect(result[:code]).to be_nil
      end
    end

    it 'rejects an error callback that carries a repeated parameter too' do
      result = callback_result("error=access_denied&error=server_error&state=#{state}")

      expect(result[:error]).to match(/more than once/)
    end
  end

  # ------------------------------------------------- RFC 6749 Section 7.1

  describe 'an access token of a type this client cannot present' do
    %w[DPoP mac Basic].each do |token_type|
      it "keeps the still-valid token when a refresh answers with a #{token_type} token" do
        store_refreshable_token
        stub_request(:post, "#{issuer_a}/token")
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => token_type }.to_json)
        provider = provider_for

        expect { provider.access_token }.not_to raise_error
        expect(authorization_header_for(provider)).to eq('Bearer token-a')
        expect(storage.get_token(server_url).access_token).to eq('token-a')
      end

      it "fails the code exchange rather than storing a #{token_type} token" do
        storage.set_server_metadata(server_url, server_metadata(issuer_a))
        storage.set_state(server_url, state)
        storage.set_client_info(server_url, client_info('client-a', issuer_a))
        storage.set_pkce(server_url,
                         MCPClient::Auth::PKCE.new(issuer: issuer_a, iss_parameter_supported: false,
                                                   client_id: 'client-a', redirect_uri: redirect_uri))
        stub_request(:post, "#{issuer_a}/token")
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => token_type }.to_json)
        provider = provider_for

        expect { provider.complete_authorization_flow('code', state) }
          .to raise_error(MCPClient::Errors::ConnectionError, /token_type/)
        expect(storage.get_token(server_url)).to be_nil
      end

      it "presents no stored record whose token_type is #{token_type}" do
        storage.set_server_metadata(server_url, server_metadata(issuer_a))
        storage.set_token(server_url,
                          { 'access_token' => 'stored', 'token_type' => token_type, 'issuer' => issuer_a })
        provider = provider_for

        expect(provider.access_token).to be_nil
        expect(authorization_header_for(provider)).to be_nil
      end
    end

    it 'still accepts the bearer type in any capitalization' do
      %w[Bearer bearer BEARER].each do |token_type|
        store = MCPClient::Auth::OAuthProvider::MemoryStorage.new
        store.set_server_metadata(server_url, server_metadata(issuer_a))
        store.set_token(server_url,
                        { 'access_token' => 'stored', 'token_type' => token_type, 'issuer' => issuer_a })
        provider = provider_for(store)

        expect(provider.access_token&.access_token).to eq('stored'), token_type
        expect(authorization_header_for(provider)).to eq('Bearer stored'), token_type
      end
    end

    # RFC 6749 Section 5.1 makes token_type REQUIRED and gives it no default,
    # and Section 7.1 forbids using a token whose type the client does not
    # understand — which is exactly what a response that names no type leaves
    # this client. So an omitted type is a failed refresh, not a bearer token
    # by assumption: the still-valid token stays.
    it 'refuses an omitted token_type rather than assuming the bearer type' do
      store_refreshable_token
      stub_request(:post, "#{issuer_a}/token")
        .to_return(status: 200, headers: json, body: { 'access_token' => 'fresh' }.to_json)
      provider = provider_for

      expect(provider.access_token&.access_token).to eq('token-a')
      expect(authorization_header_for(provider)).to eq('Bearer token-a')
      expect(log_output.string).to match(/token_type/)
    end
  end
end
