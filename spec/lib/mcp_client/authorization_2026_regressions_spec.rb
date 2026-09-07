# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'mcp_client/auth/browser_oauth'
require 'webmock/rspec'

# MCP 2026-07-28 authorization: regression suite.
#
# These examples were written one adversarial review round at a time, each
# pinning a defect that round found. They are gathered here by subject
# rather than by the round that produced them; the round is noted on each
# section only because the review notes refer to it. Every example here
# covers production code no other spec reaches.

# --- verify ----------------------------------------------------------------

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

    # Round 40: what is in use NOW is presented on the very call whose refresh
    # was discarded, not on the next one — and it is the new server's token,
    # never the previous server's.
    it 'hands the caller the token of the authorization server now in use, not the previous one' do
      refresh_answers_after_the_switch

      token = provider_for.access_token

      expect(token.access_token).to eq('token-b')
      expect(token.issuer).to eq(issuer_b)
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

# --- round3 ----------------------------------------------------------------

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

  # Every authorization server here accepts Client ID Metadata Documents
  # unless a test says otherwise (a portable client is reused only there).
  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'],
                                        client_id_metadata_document_supported: true, **extra)
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

  # Host-provided credentials say they are pre-registered (an untyped
  # record counts as a dynamic registration since round 9) AND which
  # authorization server issued them: since round 38 credentials that name
  # none are not bound to whichever server discovery happens to find.
  def client_info(client_id: 'pre-registered', **opts)
    opts = { registration_type: 'pre_registered', issuer: 'https://auth.example.com' }.merge(opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  def stub_token_endpoint(issuer)
    stub_request(:post, "#{issuer}/token")
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: { access_token: 'tok', token_type: 'Bearer', expires_in: 3600, refresh_token: 'r' }.to_json)
  end

  it 'reports credentials of another authorization server instead of reusing them at the new one' do
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(client_id: 'from-old', issuer: 'https://old.example.com'))
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
    storage.set_client_info(server_url, client_info(client_id: cimd_url, registration_type: nil))
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

  # The inverse: the request was made when the server advertised no iss, the
  # cache says it does now (another server, or a rotated document), and the
  # callback carries none — the request's own record rules, so both the
  # error and the success callback are accepted.
  it 'applies a recorded "not advertised" over a cache that now says advertised, on the error callback' do
    storage.set_client_info(server_url, client_info(registration_type: 'cimd'))
    provider = provider_for
    stub_discovery(provider, as_meta(authorization_response_iss_parameter_supported: false))
    provider.start_authorization_flow
    state = storage.get_state(server_url)
    expect(storage.get_pkce(server_url).iss_parameter_supported).to be(false)
    storage.set_server_metadata(server_url, as_meta(authorization_response_iss_parameter_supported: true))

    expect(provider.authorization_error_message('error' => 'access_denied', 'state' => state))
      .to include('access_denied')
  end

  it 'applies a recorded "not advertised" over a cache that now says advertised, on the success callback' do
    storage.set_client_info(server_url, client_info(registration_type: 'cimd'))
    provider = provider_for
    stub_discovery(provider, as_meta(authorization_response_iss_parameter_supported: false))
    provider.start_authorization_flow
    state = storage.get_state(server_url)
    storage.set_server_metadata(server_url, as_meta(authorization_response_iss_parameter_supported: true))
    stub_request(:post, 'https://auth.example.com/token')
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: { access_token: 'fresh', token_type: 'Bearer', expires_in: 3600 }.to_json)

    expect(provider.complete_authorization_flow('code', state).access_token).to eq('fresh')
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

# --- round6 ----------------------------------------------------------------

# MCP 2026-07-28 authorization, sixth review round: an authorization server
# switch lands even when storage refuses to forget the dynamic client, an
# issuer-less token is bound to the authorization server it was stored
# under on first read, and a bound token is not presented while the
# authorization server is unknown.
RSpec.describe 'MCP 2026-07-28 authorization — round 6' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def provider_for(storage, **opts)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: storage, **opts)
  end

  def switch_authorization_server(provider, meta)
    provider.instance_variable_set(
      :@challenge_resource_metadata,
      MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [meta.issuer])
    )
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
  end

  def client_info(client_id: 'dyn-old', **opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id, client_id_issued_at: Time.now.to_i - 60,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  # A backend with the documented interface only, which refuses nil records.
  def sticky_storage
    Class.new do
      def initialize
        @data = Hash.new { |h, k| h[k] = {} }
      end

      def get_token(url) = @data[:token][url]

      def set_token(url, token)
        raise ArgumentError, 'token required' if token.nil?

        @data[:token][url] = token
      end

      def get_client_info(url) = @data[:client][url]

      def set_client_info(url, info)
        raise ArgumentError, 'client info required' if info.nil?

        @data[:client][url] = info
      end

      def get_server_metadata(url) = @data[:metadata][url]
      def set_server_metadata(url, metadata) = @data[:metadata][url] = metadata
      def get_pkce(url) = @data[:pkce][url]
      def set_pkce(url, pkce) = @data[:pkce][url] = pkce
      def delete_pkce(url) = @data[:pkce].delete(url)
      def get_state(url) = @data[:state][url]
      def set_state(url, state) = @data[:state][url] = state
      def delete_state(url) = @data[:state].delete(url)
    end.new
  end

  it 'lands the authorization server switch when storage refuses to forget the dynamic client' do
    storage = sticky_storage
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(issuer: 'https://old.example.com', registration_type: 'dynamic'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old', expires_in: 3600,
                                                             issuer: 'https://old.example.com'))
    provider = provider_for(storage)
    switch_authorization_server(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    stub_request(:post, 'https://auth.example.com/register')
      .to_return(status: 201, headers: json, body: { client_id: 'dyn-new' }.to_json)

    url = provider.start_authorization_flow

    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn-new')
    expect(storage.get_server_metadata(server_url).issuer).to eq('https://auth.example.com')
    expect(provider_for(storage).access_token).to be_nil
  end

  it 'binds an issuer-less token to the authorization server it was stored under on first read' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta)
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'legacy', expires_in: 3600))

    expect(provider_for(storage).access_token&.access_token).to eq('legacy')
    expect(storage.get_token(server_url).issuer).to eq('https://auth.example.com')

    storage.set_server_metadata(server_url, as_meta(issuer: 'https://other.example.com'))
    expect(provider_for(storage).access_token).to be_nil
  end

  it 'rejects an error response when no state is stored for a flow' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta)
    provider = provider_for(storage)

    expect { provider.authorization_error_message('error' => 'access_denied', 'error_description' => 'forged') }
      .to raise_error(MCPClient::Errors::ConnectionError, /state/)
  end

  it 'does not present a bound token while the authorization server is unknown' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'bound', expires_in: 3600,
                                                             issuer: 'https://auth.example.com'))
    refresh = stub_request(:post, 'https://auth.example.com/token')

    expect(provider_for(storage).access_token).to be_nil
    expect(refresh).not_to have_been_requested

    storage.set_server_metadata(server_url, as_meta)
    expect(provider_for(storage).access_token&.access_token).to eq('bound')
  end
end

# --- round9 ----------------------------------------------------------------

# MCP 2026-07-28 authorization, ninth review round: a persisted record
# without a registration type is a dynamic registration (RFC 7591's
# client_id_issued_at is optional, so its absence proves nothing);
# pre-registered credentials say so explicitly.
RSpec.describe 'MCP 2026-07-28 authorization — round 9' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def provider_for(storage, **opts)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: storage, **opts)
  end

  def discovering(provider, meta)
    resource = MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [meta.issuer])
    allow(provider).to receive(:fetch_resource_metadata).and_return(resource)
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
  end

  def untyped_client(**opts)
    MCPClient::Auth::ClientInfo.new(client_id: 'legacy', client_secret: 'secret',
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  it 'treats a record without a registration type as a dynamic registration' do
    expect(untyped_client.effective_registration_type).to eq('dynamic')
    expect(untyped_client).not_to be_pre_registered
    expect(untyped_client(registration_type: 'pre_registered')).to be_pre_registered
  end

  it 'retires an untyped record without a timestamp when no authorization server was cached' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_client_info(server_url, untyped_client)
    provider = provider_for(storage)
    discovering(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    registration = stub_request(:post, 'https://auth.example.com/register')
                   .to_return(status: 201, headers: json, body: { client_id: 'dyn-new' }.to_json)

    url = provider.start_authorization_flow

    expect(registration).to have_been_requested
    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn-new')
  end

  it 're-registers an untyped record after a cached authorization server switch' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, untyped_client)
    provider = provider_for(storage)
    provider.instance_variable_set(
      :@challenge_resource_metadata,
      MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: ['https://auth.example.com'])
    )
    allow(provider).to receive(:fetch_server_metadata)
      .and_return(as_meta(registration_endpoint: 'https://auth.example.com/register'))
    registration = stub_request(:post, 'https://auth.example.com/register')
                   .to_return(status: 201, headers: json, body: { client_id: 'dyn-new' }.to_json)

    url = provider.start_authorization_flow

    expect(registration).to have_been_requested
    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn-new')
  end
end

# --- round12 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, twelfth review round: a PKCE record that
# names no client cannot bind the callback to the credentials the request
# was made with, so the flow fails closed like one without an issuer.
RSpec.describe 'MCP 2026-07-28 authorization — round 12' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def client_info(client_id: 'pre-registered', **opts)
    opts = { registration_type: 'pre_registered', issuer: 'https://auth.example.com' }.merge(opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  it 'refuses to redeem the code when the PKCE record names no client' do
    storage.set_server_metadata(server_url, as_meta)
    storage.set_client_info(server_url, client_info)
    provider = MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                                  logger: logger, storage: storage)
    url = provider.start_authorization_flow
    state = URI.decode_www_form(URI.parse(url).query).to_h['state']
    # A record persisted by an earlier version, or by a backend that kept
    # the issuer but not the client id.
    legacy = MCPClient::Auth::PKCE.from_h(storage.get_pkce(server_url).to_h.except(:client_id))
    storage.set_pkce(server_url, legacy)
    storage.set_client_info(server_url, client_info(client_id: 'swapped', client_secret: 's'))
    token_endpoint = stub_request(:post, 'https://auth.example.com/token')

    expect { provider.validate_authorization_response!(state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /no client was recorded/)
    expect { provider.complete_authorization_flow('code', state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /no client was recorded/)
    expect(token_endpoint).not_to have_been_requested
  end
end

# --- round16 ---------------------------------------------------------------

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

# --- round21 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, twenty-first round: a token that is still
# valid is presented even when its early refresh cannot run, and a refresh
# never lets a discovery failure escape access_token.
RSpec.describe 'MCP 2026-07-28 authorization — round 21' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

  def as_meta(issuer:)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'])
  end

  def provider_with(storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: 'http://localhost:1/cb',
                                       logger: logger, storage: storage)
  end

  def challenge(provider, issuer)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => [issuer] }.to_json)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
  end

  it 'presents a near-expiry token bound to the advertised server when discovery fails' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'new', expires_in: 60, refresh_token: 'r',
                                                             issuer: 'https://auth.example.com'))
    provider = provider_with(storage)
    allow(provider).to receive(:fetch_server_metadata).and_return(nil)
    challenge(provider, 'https://auth.example.com')

    expect(provider.access_token&.access_token).to eq('new')
    expect(storage.get_client_info(server_url)).to be_nil
  end

  it 'falls back to the still-valid token when the refresh request fails' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://auth.example.com'))
    storage.set_client_info(server_url, MCPClient::Auth::ClientInfo.new(
                                          client_id: 'c', registration_type: 'pre_registered',
                                          issuer: 'https://auth.example.com',
                                          metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: ['http://localhost:1/cb'])
                                        ))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'soon', expires_in: 60, refresh_token: 'r',
                                                             issuer: 'https://auth.example.com'))
    stub_request(:post, 'https://auth.example.com/token').to_return(status: 503)
    provider = provider_with(storage)

    expect(provider.access_token&.access_token).to eq('soon')
  end

  # Without client credentials the refresh exits before it ever reaches the
  # token endpoint, and the example would pass on a code path that has
  # nothing to do with a failing refresh. The registration is seeded, and the
  # request the refresh makes is asserted.
  it 'still returns nil for an expired token whose refresh fails' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://auth.example.com'))
    storage.set_client_info(server_url, MCPClient::Auth::ClientInfo.new(
                                          client_id: 'c', registration_type: 'pre_registered',
                                          issuer: 'https://auth.example.com',
                                          metadata: MCPClient::Auth::ClientMetadata.new(
                                            redirect_uris: ['http://localhost:1/cb']
                                          )
                                        ))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'gone', expires_in: 0, refresh_token: 'r',
                                                             issuer: 'https://auth.example.com'))
    refresh = stub_request(:post, 'https://auth.example.com/token').to_return(status: 503)
    provider = provider_with(storage)

    expect(provider.access_token).to be_nil
    expect(refresh).to have_been_requested
  end
end

# --- round23 ---------------------------------------------------------------

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

# --- round25 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, twenty-fifth round: a refusal that came from
# speculative well-known discovery does not poison the provider for good, and
# an authorization code is redeemed with the redirect URI the authorization
# request recorded (RFC 6749 Section 4.1.3) rather than one a token-endpoint
# error body named.
RSpec.describe 'MCP 2026-07-28 authorization — round 25' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }

  def provider_for(storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: storage)
  end

  def stub_prm(authorization_server)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => [authorization_server] }.to_json)
  end

  describe 'a refused well-known document' do
    it 'is fetched again on the next discovery once the server is fixed' do
      storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
      provider = provider_for(storage)
      stub_prm('http://auth.example.com')

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)

      # The operator fixes the document; the very same provider must retry it.
      stub_prm('https://auth.example.com')
      stub_request(:get, 'https://auth.example.com/.well-known/oauth-authorization-server')
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => 'https://auth.example.com',
                           'authorization_endpoint' => 'https://auth.example.com/authorize',
                           'token_endpoint' => 'https://auth.example.com/token',
                           'code_challenge_methods_supported' => ['S256'] }.to_json)

      metadata = provider.send(:discover_authorization_server)
      expect(metadata.issuer).to eq('https://auth.example.com')
    end

    it 'still fails closed for a refused 401 challenge' do
      provider = provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new)
      headers = { 'WWW-Authenticate' => 'Bearer resource_metadata="http://169.254.169.254/meta"' }

      expect { provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: headers)) }
        .to raise_error(MCPClient::Errors::ConnectionError)
      # No well-known stub is registered: a fetch here would fail the example.
      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /HTTPS|loopback or private/)
    end
  end

  describe 'an authority-less authorization server URL' do
    it 'is refused before the stored token is retired' do
      storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
      storage.set_server_metadata(server_url,
                                  MCPClient::Auth::ServerMetadata.new(
                                    issuer: 'https://old.example.com',
                                    authorization_endpoint: 'https://old.example.com/authorize',
                                    token_endpoint: 'https://old.example.com/token',
                                    code_challenge_methods_supported: ['S256']
                                  ))
      storage.set_token(server_url,
                        MCPClient::Auth::Token.new(access_token: 'tok', expires_in: 3600,
                                                   issuer: 'https://old.example.com'))
      provider = provider_for(storage)
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => ['https:foo'] }.to_json)
      headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }

      expect { provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: headers)) }
        .to raise_error(MCPClient::Errors::ConnectionError, /must name a host/)

      stored = storage.get_token(server_url)
      expect(stored&.access_token).to eq('tok')
      expect(stored.issuer).to eq('https://old.example.com')
    end
  end

  describe 'redeeming the authorization code' do
    let(:token_endpoint) { 'https://auth.example.com/token' }
    let(:server_metadata) do
      MCPClient::Auth::ServerMetadata.new(issuer: 'https://auth.example.com',
                                          authorization_endpoint: 'https://auth.example.com/authorize',
                                          token_endpoint: token_endpoint,
                                          code_challenge_methods_supported: ['S256'])
    end
    let(:client_info) do
      MCPClient::Auth::ClientInfo.new(
        client_id: 'client123',
        metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
      )
    end
    let(:mismatch_body) do
      { error: 'unauthorized_client',
        error_description: "You sent #{redirect_uri}, and we expected https://attacker.example/cb" }.to_json
    end

    it 'never substitutes a redirect_uri the token error body named' do
      provider = provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new)
      pkce = MCPClient::Auth::PKCE.new(code_verifier: 'verifier123', code_challenge: 'challenge',
                                       code_challenge_method: 'S256', issuer: 'https://auth.example.com',
                                       client_id: 'client123', redirect_uri: redirect_uri)
      request = stub_request(:post, token_endpoint).to_return(status: 400, headers: json, body: mismatch_body)

      expect { provider.send(:exchange_authorization_code, server_metadata, client_info, 'auth-code', pkce) }
        .to raise_error(MCPClient::Errors::ConnectionError, /redirect_uri/)

      expect(request).to have_been_requested.once
      expect(WebMock).not_to have_requested(:post, token_endpoint)
        .with(body: /attacker\.example/)
    end
  end
end

# --- round28 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, twenty-eighth round: a peer-advertised host is
# percent-decoded before it is classified, so the encoded spellings of a
# loopback, private or link-local target ('169.254.169.254%2e',
# '127%2e0%2e0%2e1', '%31%32%37.0.0.1') are refused rather than dialled; a host
# that is still not a hostname after decoding is refused too; and application
# type inference reads a redirect URI's loopback host the way the resolver
# does, so '127.1' and '127.0.0.1.' register as native.
RSpec.describe 'MCP 2026-07-28 authorization — round 28' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def deliver_challenge(provider, url)
    provider.handle_unauthorized_response(
      instance_double(Faraday::Response, headers: { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{url}\"" })
    )
  end

  describe 'a peer-advertised host whose local address is percent-encoded' do
    let(:provider) { provider_for }

    # URI#hostname does not decode, but the HTTP client dials the decoded
    # name: every one of these reaches the address the plain spelling reaches.
    [
      'https://169.254.169.254%2e/latest/meta-data/',
      'https://127.0.0.1%2e/meta',
      'https://10.0.0.1%2e/meta',
      'https://192.168.1.1%2e/meta',
      'https://127%2e0%2e0%2e1/meta',
      'https://169%2e254%2e169%2e254/meta',
      'https://%31%32%37.0.0.1/meta',
      'https://%31%32%37%2e%30%2e%30%2e%31/meta',
      'https://127%2e1/meta',
      'https://localhost%2e/meta',
      'https://%6cocalhost/meta',
      'https://%6c%6f%63%61%6c%68%6f%73%74/meta',
      'https://foo%2elocal%2e/meta',
      'https://vault%2einternal/meta',
      # Doubly encoded: decoding runs until the host stops changing.
      'https://127.0.0.1%252e/meta'
    ].each do |url|
      it "refuses #{url}" do
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      end
    end

    it 'still accepts a public host, encoded or not' do
      ['https://auth.example.com/meta', 'https://auth%2eexample%2ecom/meta',
       'https://8.8.8.8%2e/meta', 'https://%38%2e%38%2e%38%2e%38/meta'].each do |url|
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }.not_to raise_error
      end
    end

    it 'refuses a host that is still not a hostname after decoding' do
      ['https://ex%00ample.com/meta', 'https://%2f%2f169.254.169.254/meta'].each do |url|
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .to raise_error(MCPClient::Errors::ConnectionError, /valid host/)
      end
    end
  end

  describe 'a 401 challenge naming the metadata endpoint with an encoded host' do
    it 'is refused before the endpoint is fetched' do
      provider = provider_for
      expect { deliver_challenge(provider, 'https://169.254.169.254%2e/latest/meta-data/') }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      expect(WebMock).not_to have_requested(:get, %r{//169\.254\.169\.254})
    end
  end

  describe 'protected resource metadata advertising an encoded private address' do
    it 'is refused before the authorization server is probed' do
      provider = provider_for
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => ['https://10%2e0%2e0%2e1'] }.to_json)

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      expect(WebMock).not_to have_requested(:get, %r{//10\.0\.0\.1})
    end
  end

  describe 'the application type of a redirect URI on a loopback interface' do
    let(:provider) { provider_for }

    # The resolver reads all of these as 127.0.0.1 or ::1; a client whose
    # callback is loopback is native, however the host is spelled.
    ['http://127.1/cb', 'http://127.0.1/cb', 'http://0177.0.0.1/cb', 'http://0x7f.0.0.1/cb',
     'http://2130706433/cb', 'http://127.0.0.1./cb', 'http://localhost./cb',
     'http://[::ffff:127.0.0.1]/cb', 'http://[::127.0.0.1]/cb'].each do |uri|
      it "registers #{uri} as native" do
        provider.redirect_uri = uri
        expect(provider.send(:resolved_application_type)).to eq('native')
      end
    end

    it 'still registers a remote redirect URI as web' do
      ['https://app.example.com/cb', 'https://8.8.8.8/cb'].each do |uri|
        provider.redirect_uri = uri
        expect(provider.send(:resolved_application_type)).to eq('web')
      end
    end
  end
end

# --- round30 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, thirtieth round: when the callback precheck
# rediscovers the authorization server to learn whether it advertises RFC 9207
# `iss` (a legacy PKCE record recorded no answer), a rediscovery that names
# ANOTHER authorization server is not an answer about `iss` — it is the same
# "the authorization server changed during the flow" that
# {OAuthProvider#complete_authorization_flow} rejects. The precheck and the
# error-response path now reject it too, so a browser callback never shows a
# success page for a flow the completion refuses. The same round closes three
# more holes: a discovered authorization/token/registration endpoint is
# classified exactly like a peer-advertised URL (so an authorization server
# document can no longer send the code to a local vhost or an internal
# address unless the configured MCP server is itself loopback); a protected
# resource document rejected as not this resource's stops supplying the
# scopes of a later flow; and a token record a hash-persisting storage
# backend left behind after a delete is no token at all.
RSpec.describe 'MCP 2026-07-28 authorization — round 30' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:old_issuer) { 'https://old.example.com' }
  let(:new_issuer) { 'https://new.example.com' }
  let(:new_as_url) { 'https://new.example.com/.well-known/oauth-authorization-server' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:state) { 'state-value' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage, url = server_url)
    MCPClient::Auth::OAuthProvider.new(server_url: url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  describe 'a callback whose rediscovery names another authorization server' do
    before do
      # A PKCE record from before iss_parameter_supported was recorded, so the
      # precheck has to rediscover to answer the `iss` question at all.
      storage.set_pkce(server_url,
                       MCPClient::Auth::PKCE.new(issuer: old_issuer, client_id: 'client-1',
                                                 redirect_uri: redirect_uri).to_h)
      storage.set_state(server_url, state)
      storage.set_client_info(server_url,
                              MCPClient::Auth::ClientInfo.new(
                                client_id: 'client-1', issuer: old_issuer, registration_type: 'pre_registered',
                                metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                              ))
      # The resource now delegates to a different authorization server.
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [new_issuer] }.to_json)
      stub_request(:get, new_as_url)
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => new_issuer, 'authorization_endpoint' => "#{new_issuer}/authorize",
                           'token_endpoint' => "#{new_issuer}/token",
                           'code_challenge_methods_supported' => ['S256'],
                           'authorization_response_iss_parameter_supported' => true }.to_json)
    end

    it 'rejects a success response carrying the recorded issuer, as the completion does' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state, iss: old_issuer) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
      expect { provider.complete_authorization_flow('code', state, iss: old_issuer) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
      expect(WebMock).not_to have_requested(:post, "#{old_issuer}/token")
      expect(WebMock).not_to have_requested(:post, "#{new_issuer}/token")
    end

    it 'withholds the error text of an error response carrying the recorded issuer' do
      provider = provider_for
      params = { 'state' => state, 'error' => 'access_denied', 'iss' => old_issuer }
      expect { provider.authorization_error_message(params) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
    end

    it 'names the recorded issuer in the rejection' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state, iss: old_issuer) }
        .to raise_error(MCPClient::Errors::ConnectionError, /#{Regexp.escape(old_issuer)}/)
    end

    context 'with a metadata record persisted before RFC 9207 was read' do
      before do
        # Same issuer as the request, so nothing before the `iss` question
        # rejects the response — but no recorded answer, so the precheck
        # rediscovers and finds the server replaced.
        storage.set_server_metadata(server_url,
                                    { issuer: old_issuer, authorization_endpoint: "#{old_issuer}/authorize",
                                      token_endpoint: "#{old_issuer}/token",
                                      code_challenge_methods_supported: ['S256'] })
      end

      it 'rejects the callback instead of assuming the iss advertisement' do
        provider = provider_for
        expect { provider.validate_authorization_response!(state, iss: old_issuer) }
          .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
      end
    end
  end

  describe 'a callback whose rediscovery still names the recorded authorization server' do
    before do
      storage.set_pkce(server_url,
                       MCPClient::Auth::PKCE.new(issuer: old_issuer, client_id: 'client-1',
                                                 redirect_uri: redirect_uri).to_h)
      storage.set_state(server_url, state)
      storage.set_client_info(server_url,
                              MCPClient::Auth::ClientInfo.new(
                                client_id: 'client-1', issuer: old_issuer, registration_type: 'pre_registered',
                                metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                              ))
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [old_issuer] }.to_json)
      stub_request(:get, 'https://old.example.com/.well-known/oauth-authorization-server')
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => old_issuer, 'authorization_endpoint' => "#{old_issuer}/authorize",
                           'token_endpoint' => "#{old_issuer}/token",
                           'code_challenge_methods_supported' => ['S256'],
                           'authorization_response_iss_parameter_supported' => true }.to_json)
    end

    it 'still accepts a response carrying that issuer' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state, iss: old_issuer) }.not_to raise_error
      params = { 'state' => state, 'error' => 'access_denied', 'iss' => old_issuer }
      expect(provider.authorization_error_message(params)).to eq('access_denied')
    end

    it 'still rejects a response without iss' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /advertises the iss parameter/)
    end
  end

  describe 'a callback whose rediscovery fails outright' do
    before do
      storage.set_pkce(server_url,
                       MCPClient::Auth::PKCE.new(issuer: old_issuer, client_id: 'client-1',
                                                 redirect_uri: redirect_uri).to_h)
      storage.set_state(server_url, state)
      storage.set_client_info(server_url,
                              MCPClient::Auth::ClientInfo.new(
                                client_id: 'client-1', issuer: old_issuer, registration_type: 'pre_registered',
                                metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                              ))
      stub_request(:get, prm_url).to_return(status: 500)
      stub_request(:get, 'https://mcp.example.com/.well-known/oauth-protected-resource')
        .to_return(status: 500)
      stub_request(:get, 'https://mcp.example.com/.well-known/oauth-authorization-server')
        .to_return(status: 500)
      stub_request(:get, 'https://mcp.example.com/.well-known/openid-configuration')
        .to_return(status: 500)
    end

    # An answer that cannot be obtained is unknown, not "the server changed":
    # the advertisement is still assumed, so a missing `iss` is refused and a
    # response carrying the recorded issuer is accepted.
    it 'is unknown rather than a changed authorization server' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /advertises the iss parameter/)
      expect { provider.validate_authorization_response!(state, iss: old_issuer) }.not_to raise_error
    end
  end
  describe 'a discovered endpoint for a remote MCP server' do
    # The endpoints come out of peer-controlled authorization server metadata,
    # so they are classified exactly like a peer-advertised URL: the
    # plain-HTTP exception needs a loopback configured server too.
    let(:provider) { provider_for }

    ['http://localhost:3000/steal', 'http://app.localhost:3000/steal', 'http://127.1/token',
     'http://127.0.0.1.:9292/token', 'http://[::1]:9292/token',
     'http://[::ffff:127.0.0.1]/token'].each do |url|
      it "refuses the plain-HTTP local vhost #{url}" do
        expect { provider.send(:enforce_https!, url, 'token endpoint') }
          .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)
      end
    end

    ['https://169.254.169.254/token', 'https://10.0.0.5/token', 'https://127.0.0.1/token',
     'https://vault.internal/token', 'https://printer.local/token'].each do |url|
      it "refuses the internal target #{url}" do
        expect { provider.send(:enforce_https!, url, 'token endpoint') }
          .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      end
    end

    it 'refuses metadata whose token endpoint collects the code at a local vhost' do
      metadata = MCPClient::Auth::ServerMetadata.new(
        issuer: 'https://attacker.example',
        authorization_endpoint: 'https://attacker.example/authorize',
        token_endpoint: 'http://app.localhost:3000/steal',
        code_challenge_methods_supported: ['S256']
      )
      expect { provider.send(:validate_server_metadata!, metadata) }
        .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)
    end

    it 'still accepts public HTTPS endpoints' do
      expect { provider.send(:enforce_https!, 'https://auth.example.com/token', 'token endpoint') }
        .not_to raise_error
    end
  end

  describe 'a discovered endpoint for a loopback MCP server' do
    let(:provider) { provider_for(storage, 'http://localhost:9292/mcp') }

    it 'still accepts the local stack' do
      ['http://127.0.0.1:9292/token', 'http://app.localhost:9292/token', 'http://[::1]:9292/token',
       'http://127.1:9292/token'].each do |url|
        expect { provider.send(:enforce_https!, url, 'token endpoint') }.not_to raise_error
      end
    end

    it 'still refuses another private address' do
      expect { provider.send(:enforce_https!, 'https://169.254.169.254/token', 'token endpoint') }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
    end
  end

  describe 'a protected resource document that is not this resource' do
    it 'no longer supplies the scopes of the next flow' do
      provider = provider_for
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => 'https://other.example.com/mcp', 'scopes_supported' => ['admin:all'],
                           'authorization_servers' => ['https://auth.example.com'] }.to_json)

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /does not match the server URL/)

      expect(provider.send(:resolved_scope)).to be_nil
    end

    it 'no longer supplies them when it advertises no authorization server either' do
      provider = provider_for
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'scopes_supported' => ['admin:all'] }.to_json)

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /does not advertise any authorization_servers/)

      expect(provider.send(:resolved_scope)).to be_nil
    end
  end

  describe 'a token record a hash-persisting storage backend left behind' do
    # `set_token(server_url, nil)` is what a backend without `delete_token`
    # gets, and a backend that persists `token.to_h` writes `nil.to_h` — `{}`.
    # Read back, that is not a token: presenting it would send "Bearer ",
    # attributed to whatever authorization server is current now.
    before do
      storage.set_server_metadata(server_url,
                                  MCPClient::Auth::ServerMetadata.new(
                                    issuer: old_issuer, authorization_endpoint: "#{old_issuer}/authorize",
                                    token_endpoint: "#{old_issuer}/token",
                                    code_challenge_methods_supported: ['S256']
                                  ))
    end

    it 'is no token at all' do
      storage.set_token(server_url, {})
      provider = provider_for

      expect(provider.access_token).to be_nil
      request = Faraday::Request.new
      request.headers = {}
      provider.apply_authorization(request)
      expect(request.headers).not_to have_key('Authorization')
    end

    it 'still reads a persisted hash that carries token bytes' do
      storage.set_token(server_url,
                        MCPClient::Auth::Token.new(access_token: 'tok', expires_in: 3600,
                                                   issuer: old_issuer).to_h)
      provider = provider_for
      expect(provider.access_token&.access_token).to eq('tok')
    end
  end
end

# --- round31 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, thirty-first round: a token response is only a
# token response when it carries an access token. RFC 6749 Section 5.1 makes
# `access_token` REQUIRED in a successful response, so a `200 {}` from the
# token endpoint is a protocol error, not a credential: the code exchange
# fails instead of storing an empty token and reporting success, and a refresh
# fails instead of replacing a still-valid token with bytes that would go out
# as a bare "Bearer ". The same round closes two more holes: the error-response
# path applies the pending-challenge and issuer-mismatch checks the success
# path applies, so the `error_description` of authorization server A is never
# displayed after the flow moved to B; and a stored client record without
# client-ID bytes — what a hash-persisting backend reads back after a
# `set_client_info(server_url, nil)` delete — is no client at all, so a new
# dynamic registration is made instead of an authorization request with an
# empty `client_id`.
RSpec.describe 'MCP 2026-07-28 authorization — round 31' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer) { 'https://auth.example.com' }
  let(:other_issuer) { 'https://other.example.com' }
  let(:token_endpoint) { "#{issuer}/token" }
  let(:registration_endpoint) { "#{issuer}/register" }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:state) { 'state-value' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def server_metadata(iss = issuer, registration: nil)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      registration_endpoint: registration, code_challenge_methods_supported: ['S256'],
      authorization_response_iss_parameter_supported: false
    )
  end

  def client_info(id = 'client-1', iss = issuer)
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: 'pre_registered',
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
    )
  end

  def authorization_header_for(provider)
    request = Faraday::Request.new
    request.headers = {}
    provider.apply_authorization(request)
    request.headers['Authorization']
  end

  describe 'a 200 token response that carries no access_token' do
    before { storage.set_server_metadata(server_url, server_metadata) }

    describe 'on a refresh' do
      before do
        storage.set_client_info(server_url, client_info)
        # Still valid, but inside the five-minute early-refresh window.
        storage.set_token(server_url,
                          MCPClient::Auth::Token.new(access_token: 'still-valid', expires_in: 60,
                                                     refresh_token: 'refresh-1', issuer: issuer))
      end

      [{}, { 'token_type' => 'Bearer', 'expires_in' => 3600 },
       { 'access_token' => '', 'token_type' => 'Bearer' }].each do |body|
        it "keeps the still-valid token for #{body.to_json}" do
          stub_request(:post, token_endpoint).to_return(status: 200, headers: json, body: body.to_json)
          provider = provider_for

          expect(provider.access_token&.access_token).to eq('still-valid')
          expect(authorization_header_for(provider)).to eq('Bearer still-valid')
          expect(storage.get_token(server_url).access_token).to eq('still-valid')
        end
      end

      it 'never presents a bare "Bearer "' do
        stub_request(:post, token_endpoint).to_return(status: 200, headers: json, body: '{}')
        provider = provider_for

        expect(authorization_header_for(provider)).not_to eq('Bearer ')
      end

      it 'still accepts a refresh response that carries an access token' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json)
        provider = provider_for

        expect(provider.access_token&.access_token).to eq('fresh')
        expect(storage.get_token(server_url).access_token).to eq('fresh')
      end
    end

    describe 'on the code exchange' do
      before do
        storage.set_state(server_url, state)
        storage.set_client_info(server_url, client_info)
        storage.set_pkce(server_url,
                         MCPClient::Auth::PKCE.new(issuer: issuer, iss_parameter_supported: false,
                                                   client_id: 'client-1', redirect_uri: redirect_uri))
      end

      [{}, { 'token_type' => 'Bearer', 'expires_in' => 3600 },
       { 'access_token' => '', 'token_type' => 'Bearer' }].each do |body|
        it "fails the flow for #{body.to_json} instead of storing an empty token" do
          stub_request(:post, token_endpoint).to_return(status: 200, headers: json, body: body.to_json)
          provider = provider_for

          expect { provider.complete_authorization_flow('code', state) }
            .to raise_error(MCPClient::Errors::ConnectionError, /no access_token/)
          expect(storage.get_token(server_url)).to be_nil
          expect(provider.access_token).to be_nil
          expect(authorization_header_for(provider)).to be_nil
        end
      end

      it 'still completes when the response carries an access token' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json)
        provider = provider_for

        expect(provider.complete_authorization_flow('code', state).access_token).to eq('fresh')
        expect(storage.get_token(server_url).access_token).to eq('fresh')
      end
    end
  end

  describe 'an error response after the authorization server changed' do
    # The PKCE record answers the RFC 9207 `iss` question outright, so the
    # error path reaches the issuer check without rediscovering anything: only
    # the checks the success path makes can catch the switch.
    before do
      storage.set_state(server_url, state)
      storage.set_client_info(server_url, client_info)
      storage.set_pkce(server_url,
                       MCPClient::Auth::PKCE.new(issuer: issuer, iss_parameter_supported: true,
                                                 client_id: 'client-1', redirect_uri: redirect_uri))
    end

    let(:params) { { 'state' => state, 'error' => 'access_denied', 'error_description' => 'nope', 'iss' => issuer } }

    it 'withholds the error text when shared storage names another authorization server' do
      storage.set_server_metadata(server_url, server_metadata(other_issuer))
      provider = provider_for

      expect { provider.validate_authorization_response!(state, iss: issuer) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
      expect { provider.authorization_error_message(params) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
    end

    it 'withholds the error text while a challenge is still unresolved' do
      storage.set_server_metadata(server_url, server_metadata)
      stub_request(:get, 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp')
        .to_return(status: 500)
      provider = provider_for
      begin
        provider.handle_unauthorized_response(
          instance_double(Faraday::Response,
                          headers: { 'WWW-Authenticate' => 'Bearer resource_metadata=' \
                                                           '"https://mcp.example.com/.well-known/' \
                                                           'oauth-protected-resource/mcp"' })
        )
      rescue MCPClient::Errors::ConnectionError
        nil
      end

      expect { provider.validate_authorization_response!(state, iss: issuer) }
        .to raise_error(MCPClient::Errors::ConnectionError, /challenge received during the flow/)
      expect { provider.authorization_error_message(params) }
        .to raise_error(MCPClient::Errors::ConnectionError, /challenge received during the flow/)
    end

    it 'withholds the error text after a refused challenge' do
      storage.set_server_metadata(server_url, server_metadata)
      stub_request(:get, 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp')
        .to_return(status: 200, headers: json,
                   body: { 'resource' => 'https://elsewhere.example.com/mcp',
                           'authorization_servers' => [other_issuer] }.to_json)
      provider = provider_for
      begin
        provider.handle_unauthorized_response(
          instance_double(Faraday::Response,
                          headers: { 'WWW-Authenticate' => 'Bearer resource_metadata=' \
                                                           '"https://mcp.example.com/.well-known/' \
                                                           'oauth-protected-resource/mcp"' })
        )
      rescue MCPClient::Errors::ConnectionError
        nil
      end

      expect { provider.authorization_error_message(params) }
        .to raise_error(MCPClient::Errors::ConnectionError, /challenge received during the flow/)
    end

    it 'withholds the error text when a resolved challenge names another authorization server' do
      storage.set_server_metadata(server_url, server_metadata)
      stub_request(:get, 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp')
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [other_issuer] }.to_json)
      provider = provider_for
      provider.handle_unauthorized_response(
        instance_double(Faraday::Response,
                        headers: { 'WWW-Authenticate' => 'Bearer resource_metadata=' \
                                                         '"https://mcp.example.com/.well-known/' \
                                                         'oauth-protected-resource/mcp"' })
      )

      expect { provider.authorization_error_message(params) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
    end

    it 'still shows the error text while the authorization server is unchanged' do
      storage.set_server_metadata(server_url, server_metadata)
      provider = provider_for

      expect(provider.authorization_error_message(params)).to eq('nope')
    end
  end

  describe 'a client record a hash-persisting storage backend left behind' do
    # `set_client_info(server_url, nil)` is what a backend without
    # `delete_client_info` gets for the issuer-less dynamic client the first
    # post-upgrade discovery discards; a backend that persists `to_h` writes
    # `{}`. Read back, that is not a client: binding and reusing it would send
    # an authorization request with an empty `client_id`.
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer, registration: registration_endpoint))
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-client', 'redirect_uris' => [redirect_uri] }.to_json)
    end

    [{}, { 'client_id' => '' }].each do |record|
      it "registers a new client instead of reusing #{record.to_json}" do
        storage.set_client_info(server_url, record)
        provider = provider_for

        url = provider.start_authorization_flow
        expect(WebMock).to have_requested(:post, registration_endpoint)
        expect(url).to include('client_id=dyn-client')
        expect(storage.get_client_info(server_url).client_id).to eq('dyn-client')
      end
    end

    it 'is no client at all when read back' do
      storage.set_client_info(server_url, {})
      expect(provider_for.send(:stored_client_info)).to be_nil
    end

    it 'still reads a persisted hash that carries client-ID bytes' do
      storage.set_client_info(server_url, client_info.to_h)
      expect(provider_for.send(:stored_client_info)&.client_id).to eq('client-1')
    end
  end
end

# --- round32 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, thirty-second round: the checks round 31 added
# ask their question of whatever JSON came back, so they only hold for the
# shapes they expected. A token endpoint answering `200 []` or `200 null`
# indexed an Array (or nil) with a String, and `{"access_token": ["x"]}` passed
# the "has bytes" test and went out as `Authorization: Bearer ["x"]`. The same
# hole sat on the registration side, where a `201` without a usable `client_id`
# was accepted and only failed after the user had been sent to the
# authorization endpoint. A token response carries an access token only when it
# is a JSON object with a non-empty `access_token` string; a registration
# response names a client only when it is a JSON object with a non-empty
# `client_id` string.
#
# The round also stops one provider serving another server's discovery: the
# in-process metadata fallback (and the challenge, scope and switch state
# beside it) describes the URL it was discovered for, so retargeting the
# public `server_url=` setter forgets all of it instead of pointing the new
# server's authorization, registration and token requests at the old server's
# endpoints.
RSpec.describe 'MCP 2026-07-28 authorization — round 32' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer) { 'https://auth.example.com' }
  let(:token_endpoint) { "#{issuer}/token" }
  let(:registration_endpoint) { "#{issuer}/register" }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:state) { 'state-value' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  # A token endpoint response that is not a JSON object, or whose access_token
  # is not a non-empty string, carries no credential at all.
  let(:token_bodies_without_bytes) do
    ['[]', 'null', '"access_token"', '{"access_token": ["x"]}', '{"access_token": {"a": 1}}',
     '{"access_token": 12345}', '{"access_token": true}', '{"access_token": null}']
  end

  def provider_for(store = storage, url: server_url)
    MCPClient::Auth::OAuthProvider.new(server_url: url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def server_metadata(iss = issuer, registration: nil)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      registration_endpoint: registration, code_challenge_methods_supported: ['S256'],
      authorization_response_iss_parameter_supported: false
    )
  end

  def client_info(id = 'client-1', iss = issuer)
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: 'pre_registered',
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
    )
  end

  def authorization_header_for(provider)
    request = Faraday::Request.new
    request.headers = {}
    provider.apply_authorization(request)
    request.headers['Authorization']
  end

  describe 'a token response whose access_token is not a string' do
    before { storage.set_server_metadata(server_url, server_metadata) }

    describe 'on a refresh' do
      before do
        storage.set_client_info(server_url, client_info)
        # Still valid, but inside the five-minute early-refresh window.
        storage.set_token(server_url,
                          MCPClient::Auth::Token.new(access_token: 'still-valid', expires_in: 60,
                                                     refresh_token: 'refresh-1', issuer: issuer))
      end

      it 'keeps the still-valid token instead of raising or presenting the value' do
        token_bodies_without_bytes.each do |body|
          stub_request(:post, token_endpoint).to_return(status: 200, headers: json, body: body)
          provider = provider_for

          expect { provider.access_token }.not_to raise_error
          expect(provider.access_token&.access_token).to eq('still-valid'), "body: #{body}"
          expect(authorization_header_for(provider)).to eq('Bearer still-valid'), "body: #{body}"
          expect(storage.get_token(server_url).access_token).to eq('still-valid'), "body: #{body}"
        end
      end

      it 'never presents a JSON array as bearer credentials' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json, body: '{"access_token": ["x"], "token_type": "Bearer"}')
        provider = provider_for

        expect(authorization_header_for(provider)).not_to include('["x"]')
      end
    end

    describe 'on the code exchange' do
      before do
        storage.set_state(server_url, state)
        storage.set_client_info(server_url, client_info)
        storage.set_pkce(server_url,
                         MCPClient::Auth::PKCE.new(issuer: issuer, iss_parameter_supported: false,
                                                   client_id: 'client-1', redirect_uri: redirect_uri))
      end

      it 'fails the flow instead of storing the value' do
        token_bodies_without_bytes.each do |body|
          stub_request(:post, token_endpoint).to_return(status: 200, headers: json, body: body)
          provider = provider_for

          expect { provider.complete_authorization_flow('code', state) }
            .to raise_error(MCPClient::Errors::ConnectionError, /no access_token/), "body: #{body}"
          expect(storage.get_token(server_url)).to be_nil, "body: #{body}"
          expect(authorization_header_for(provider)).to be_nil, "body: #{body}"
        end
      end
    end

    it 'is no token when a hash-persisting backend reads one back' do
      [['x'], { 'a' => 1 }, 12_345, true].each do |bytes|
        storage.set_token(server_url, { 'access_token' => bytes, 'token_type' => 'Bearer', 'issuer' => issuer })
        expect(provider_for.access_token).to be_nil, "access_token: #{bytes.inspect}"
        expect(authorization_header_for(provider_for)).to be_nil, "access_token: #{bytes.inspect}"
      end
    end
  end

  describe 'a registration response that names no client' do
    before { storage.set_server_metadata(server_url, server_metadata(issuer, registration: registration_endpoint)) }

    [nil, '', 12_345, ['dyn-client'], { 'id' => 'dyn-client' }, true].each do |client_id|
      it "fails before the browser is opened for client_id #{client_id.inspect}" do
        body = { 'redirect_uris' => [redirect_uri] }
        body['client_id'] = client_id unless client_id.nil?
        stub_request(:post, registration_endpoint).to_return(status: 201, headers: json, body: body.to_json)
        provider = provider_for

        expect { provider.start_authorization_flow }
          .to raise_error(MCPClient::Errors::ConnectionError, /client_id/)
        expect(storage.get_client_info(server_url)).to be_nil
        expect(storage.get_pkce(server_url)).to be_nil
        expect(storage.get_state(server_url)).to be_nil
      end
    end

    ['[]', 'null', '"dyn-client"'].each do |body|
      it "fails for a registration body that is not a JSON object (#{body})" do
        stub_request(:post, registration_endpoint).to_return(status: 201, headers: json, body: body)
        provider = provider_for

        expect { provider.start_authorization_flow }
          .to raise_error(MCPClient::Errors::ConnectionError, /client_id/)
        expect(storage.get_client_info(server_url)).to be_nil
      end
    end

    it 'still registers when the response names a client' do
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-client', 'redirect_uris' => [redirect_uri] }.to_json)
      provider = provider_for

      expect(provider.start_authorization_flow).to include('client_id=dyn-client')
      expect(storage.get_client_info(server_url).client_id).to eq('dyn-client')
    end
  end

  describe 'a provider retargeted through server_url=' do
    let(:url_a) { 'https://a.example.com/mcp' }
    let(:url_b) { 'https://b.example.com/mcp' }
    let(:issuer_a) { 'https://auth-a.example.com' }
    let(:issuer_b) { 'https://auth-b.example.com' }
    # A backend that persists tokens but not discovered metadata: exactly the
    # case the in-process fallback exists for.
    let(:forgetful_storage) do
      Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        def get_server_metadata(_server_url)
          nil
        end
      end.new
    end

    def stub_discovery(resource_url, iss, scopes)
      prm_url = "#{URI.parse(resource_url).origin}/.well-known/oauth-protected-resource/mcp"
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => resource_url, 'authorization_servers' => [iss] }.to_json)
      stub_request(:get, "#{iss}/.well-known/oauth-authorization-server")
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => iss, 'authorization_endpoint' => "#{iss}/authorize",
                           'token_endpoint' => "#{iss}/token", 'registration_endpoint' => "#{iss}/register",
                           'code_challenge_methods_supported' => ['S256'], 'scopes_supported' => scopes,
                           'authorization_response_iss_parameter_supported' => true }.to_json)
    end

    before do
      stub_discovery(url_a, issuer_a, ['a.read'])
      stub_discovery(url_b, issuer_b, ['b.read'])
    end

    it 'discovers the new server rather than serving the previous one’s metadata' do
      provider = provider_for(forgetful_storage, url: url_a)
      expect(provider.send(:discover_authorization_server).issuer).to eq(issuer_a)

      provider.server_url = url_b

      expect(provider.send(:discover_authorization_server).issuer).to eq(issuer_b)
      expect(WebMock).to have_requested(:get, "#{issuer_b}/.well-known/oauth-authorization-server")
    end

    it 'sends the authorization request to the new server’s endpoints' do
      stub_request(:post, "#{issuer_a}/register")
        .to_return(status: 201, headers: json, body: { 'client_id' => 'a-client' }.to_json)
      stub_request(:post, "#{issuer_b}/register")
        .to_return(status: 201, headers: json, body: { 'client_id' => 'b-client' }.to_json)
      provider = provider_for(forgetful_storage, url: url_a)
      provider.start_authorization_flow

      provider.server_url = url_b
      url = provider.start_authorization_flow

      expect(url).to start_with("#{issuer_b}/authorize")
      expect(url).to include('client_id=b-client')
    end

    it 'forgets the scopes the previous server advertised' do
      provider = provider_for(forgetful_storage, url: url_a)
      expect(provider.supported_scopes).to eq(['a.read'])

      provider.server_url = url_b

      expect(provider.supported_scopes).to eq(['b.read'])
    end

    it 'forgets a refused challenge latched for the previous server' do
      stub_request(:get, 'https://a.example.com/.well-known/oauth-protected-resource/other')
        .to_return(status: 200, headers: json,
                   body: { 'resource' => 'https://elsewhere.example.com/mcp',
                           'authorization_servers' => [issuer_a] }.to_json)
      provider = provider_for(forgetful_storage, url: url_a)
      begin
        provider.handle_unauthorized_response(
          instance_double(Faraday::Response,
                          headers: { 'WWW-Authenticate' => 'Bearer resource_metadata=' \
                                                           '"https://a.example.com/.well-known/' \
                                                           'oauth-protected-resource/other"' })
        )
      rescue MCPClient::Errors::ConnectionError
        nil
      end
      expect { provider.send(:discover_authorization_server) }.to raise_error(MCPClient::Errors::ConnectionError)

      provider.server_url = url_b

      expect(provider.send(:discover_authorization_server).issuer).to eq(issuer_b)
    end

    it 'forgets a pending challenge URL of the previous server' do
      stub_request(:get, 'https://a.example.com/.well-known/oauth-protected-resource/other')
        .to_return(status: 500)
      provider = provider_for(forgetful_storage, url: url_a)
      begin
        provider.handle_unauthorized_response(
          instance_double(Faraday::Response,
                          headers: { 'WWW-Authenticate' => 'Bearer resource_metadata=' \
                                                           '"https://a.example.com/.well-known/' \
                                                           'oauth-protected-resource/other"' })
        )
      rescue MCPClient::Errors::ConnectionError
        nil
      end

      provider.server_url = url_b

      expect(provider.send(:discover_authorization_server).issuer).to eq(issuer_b)
      expect(WebMock).not_to have_requested(:get, 'https://a.example.com/.well-known/oauth-protected-resource/other')
        .times(2)
    end

    it 'keeps retirement markers, which name an issuer rather than a resource URL' do
      # Two MCP servers behind one authorization server: bytes retired for
      # that issuer are still retired after the provider is retargeted.
      provider = provider_for(forgetful_storage, url: url_a)
      retired = MCPClient::Auth::Token.new(access_token: 'shared-bytes', issuer: issuer_a)
      forgetful_storage.set_token(url_a, retired)
      provider.send(:delete_token, bind_to: issuer_a)

      provider.server_url = url_b

      expect(provider.send(:retired_token?, retired)).to be(true)
    end

    it 'is unaffected by a setter call that does not change the URL' do
      provider = provider_for(forgetful_storage, url: url_a)
      expect(provider.supported_scopes).to eq(['a.read'])

      provider.server_url = url_a

      expect(provider.supported_scopes).to eq(['a.read'])
      expect(WebMock).to have_requested(:get, "#{issuer_a}/.well-known/oauth-authorization-server").once
    end
  end
end

# --- round33 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, thirty-third round: round 32 made the
# access_token check type-strict, and stopped one field short. Every other
# field of a token response (RFC 6749 Section 5.1) and of a registration
# response (RFC 7591 Section 3.2.1) was still taken on trust, so a peer that
# answers with the right field names and the wrong JSON types crashed the
# client with a NoMethodError or a TypeError instead of failing with a
# ConnectionError — and on a refresh it did so after the still-valid token had
# already been thrown away, or before it could be presented.
#
# A token response is a credential only when every field it carries has the
# type RFC 6749 gives it; a registration response registers a client only when
# every field has the type RFC 7591 gives it. Anything else fails the flow the
# same way a missing access_token does: a ConnectionError on the code exchange,
# and on a refresh a warning that keeps the still-valid token in storage.
#
# The same strictness applies to what storage reads back: a record whose
# client_id is not a non-empty string is not a client, so registration happens
# before the browser is opened rather than an authorization request going out
# with a `to_s`-mangled client_id that the callback then rejects.
RSpec.describe 'MCP 2026-07-28 authorization — round 33' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer) { 'https://auth.example.com' }
  let(:token_endpoint) { "#{issuer}/token" }
  let(:registration_endpoint) { "#{issuer}/register" }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:state) { 'state-value' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  # Every field RFC 6749 Section 5.1 gives a successful token response, with a
  # value of a type the RFC does not allow for it. access_token is covered by
  # round 32; these are the fields the strictness stopped short of.
  let(:mistyped_token_responses) do
    {
      'token_type' => [['Bearer'], 1, true, { 'type' => 'Bearer' }, ''],
      'expires_in' => ['3600', ['3600'], true, { 'seconds' => 3600 }],
      'refresh_token' => [%w[refresh-2], 12_345, true, { 'token' => 'refresh-2' }],
      'scope' => [%w[read write], 12_345, true, { 'scope' => 'read' }]
    }
  end

  # The same, for the registration response of RFC 7591 Section 3.2.1 (whose
  # client metadata fields keep the types of Section 2). client_id is covered
  # by round 32.
  let(:mistyped_registration_responses) do
    {
      'client_secret' => [%w[secret], 12_345, true, { 'secret' => 's' }],
      'client_id_issued_at' => ['1700000000', [1_700_000_000], true, {}],
      'client_secret_expires_at' => ['1700000000', [1_700_000_000], true, {}],
      'redirect_uris' => ['http://localhost:1/cb', [['http://localhost:1/cb']], [12_345], 12_345, true,
                          { 'uris' => [] }],
      'token_endpoint_auth_method' => [['none'], 12_345, true, {}],
      'grant_types' => ['authorization_code', [%w[authorization_code]], [12_345], 12_345, true],
      'response_types' => ['code', [%w[code]], [12_345], 12_345, true],
      'contacts' => ['dev@example.com', [12_345], 12_345, true],
      'scope' => [%w[read], 12_345, true],
      'client_name' => [%w[name], 12_345, true],
      'client_uri' => [%w[https://example.com], 12_345, true],
      'logo_uri' => [%w[https://example.com/logo.png], 12_345, true],
      'tos_uri' => [%w[https://example.com/tos], 12_345, true],
      'policy_uri' => [%w[https://example.com/policy], 12_345, true],
      'application_type' => [%w[native], 12_345, true]
    }
  end

  def provider_for(store = storage, url: server_url)
    MCPClient::Auth::OAuthProvider.new(server_url: url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def server_metadata(iss = issuer, registration: nil)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      registration_endpoint: registration, code_challenge_methods_supported: ['S256'],
      authorization_response_iss_parameter_supported: false
    )
  end

  def client_info(id = 'client-1', iss = issuer)
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: 'pre_registered',
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
    )
  end

  def authorization_header_for(provider)
    request = Faraday::Request.new
    request.headers = {}
    provider.apply_authorization(request)
    request.headers['Authorization']
  end

  def each_mistyped_token_field
    mistyped_token_responses.each do |field, values|
      values.each do |value|
        body = { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => 3600 }
        body[field] = value
        yield field, value, body.to_json
      end
    end
  end

  def each_mistyped_registration_field
    mistyped_registration_responses.each do |field, values|
      values.each do |value|
        body = { 'client_id' => 'dyn-client', 'redirect_uris' => [redirect_uri] }
        body[field] = value
        yield field, value, body.to_json
      end
    end
  end

  describe 'a token response whose fields have the wrong JSON type' do
    before { storage.set_server_metadata(server_url, server_metadata) }

    describe 'on a refresh' do
      before do
        storage.set_client_info(server_url, client_info)
        # Still valid, but inside the five-minute early-refresh window.
        storage.set_token(server_url,
                          MCPClient::Auth::Token.new(access_token: 'still-valid', expires_in: 60,
                                                     refresh_token: 'refresh-1', issuer: issuer))
      end

      it 'keeps the still-valid token instead of raising or storing the response' do
        each_mistyped_token_field do |field, value, body|
          context = "#{field}: #{value.inspect}"
          stub_request(:post, token_endpoint).to_return(status: 200, headers: json, body: body)
          provider = provider_for

          expect { provider.access_token }.not_to raise_error, context
          expect(provider.access_token&.access_token).to eq('still-valid'), context
          expect(authorization_header_for(provider)).to eq('Bearer still-valid'), context
          expect(storage.get_token(server_url).access_token).to eq('still-valid'), context
        end
      end

      it 'never builds a header out of a token_type that is not a string' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => ['Bearer'] }.to_json)
        provider = provider_for

        expect(authorization_header_for(provider)).to eq('Bearer still-valid')
      end

      it 'presents the still-valid token when expires_in is a string' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => 'Bearer',
                             'expires_in' => '3600' }.to_json)
        provider = provider_for

        expect { provider.access_token }.not_to raise_error
        expect(authorization_header_for(provider)).to eq('Bearer still-valid')
      end

      it 'still accepts a fully typed refresh response' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => 3600,
                             'refresh_token' => 'refresh-2', 'scope' => 'read write' }.to_json)
        provider = provider_for

        expect(provider.access_token&.access_token).to eq('fresh')
        expect(storage.get_token(server_url).refresh_token).to eq('refresh-2')
      end

      it 'accepts a response that omits the optional fields' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)
        provider = provider_for

        expect(provider.access_token&.access_token).to eq('fresh')
        expect(authorization_header_for(provider)).to eq('Bearer fresh')
      end

      # A JSON null says the same thing as an absent member: the OPTIONAL
      # fields keep the defaults an omitted field gets, and the REQUIRED
      # token_type is missing either way (RFC 6749 Section 5.1).
      it 'treats a null optional field as an absent one' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => nil,
                             'refresh_token' => nil, 'scope' => nil }.to_json)
        provider = provider_for

        expect(provider.access_token&.access_token).to eq('fresh')
        expect(authorization_header_for(provider)).to eq('Bearer fresh')
      end

      it 'refuses a null token_type exactly as an absent one' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => nil }.to_json)
        provider = provider_for

        expect(provider.access_token&.access_token).to eq('still-valid')
        expect(storage.get_token(server_url).access_token).to eq('still-valid')
      end
    end

    describe 'on the code exchange' do
      before do
        storage.set_state(server_url, state)
        storage.set_client_info(server_url, client_info)
        storage.set_pkce(server_url,
                         MCPClient::Auth::PKCE.new(issuer: issuer, iss_parameter_supported: false,
                                                   client_id: 'client-1', redirect_uri: redirect_uri))
      end

      it 'fails the flow with a ConnectionError instead of storing the response' do
        each_mistyped_token_field do |field, value, body|
          context = "#{field}: #{value.inspect}"
          stub_request(:post, token_endpoint).to_return(status: 200, headers: json, body: body)
          provider = provider_for

          expect { provider.complete_authorization_flow('code', state) }
            .to raise_error(MCPClient::Errors::ConnectionError, /#{field}/), context
          expect(storage.get_token(server_url)).to be_nil, context
          expect(authorization_header_for(provider)).to be_nil, context
        end
      end

      it 'keeps the pending flow rather than reporting success' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => ['Bearer'] }.to_json)
        provider = provider_for

        expect { provider.complete_authorization_flow('code', state) }
          .to raise_error(MCPClient::Errors::ConnectionError)
        expect(storage.get_pkce(server_url)).not_to be_nil
      end

      it 'still accepts a fully typed token response' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => 3600,
                             'refresh_token' => 'refresh-2', 'scope' => 'read write' }.to_json)
        provider = provider_for

        token = provider.complete_authorization_flow('code', state)
        expect(token.access_token).to eq('fresh')
        expect(token.to_header).to eq('Bearer fresh')
        expect(storage.get_pkce(server_url)).to be_nil
      end
    end
  end

  describe 'a registration response whose fields have the wrong JSON type' do
    before { storage.set_server_metadata(server_url, server_metadata(issuer, registration: registration_endpoint)) }

    it 'fails registration with a ConnectionError before the browser is opened' do
      each_mistyped_registration_field do |field, value, body|
        context = "#{field}: #{value.inspect}"
        store = MCPClient::Auth::OAuthProvider::MemoryStorage.new
        store.set_server_metadata(server_url, server_metadata(issuer, registration: registration_endpoint))
        stub_request(:post, registration_endpoint).to_return(status: 201, headers: json, body: body)
        provider = provider_for(store)

        expect { provider.start_authorization_flow }
          .to raise_error(MCPClient::Errors::ConnectionError, /#{field}/), context
        expect(store.get_client_info(server_url)).to be_nil, context
        expect(store.get_pkce(server_url)).to be_nil, context
        expect(store.get_state(server_url)).to be_nil, context
      end
    end

    it 'reports a redirect_uris string as a registration failure, not a NoMethodError' do
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-client', 'redirect_uris' => redirect_uri }.to_json)
      provider = provider_for

      expect { provider.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /redirect_uris/)
    end

    it 'defaults to the requested redirect URI when the response omits redirect_uris' do
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json, body: { 'client_id' => 'dyn-client' }.to_json)
      provider = provider_for

      expect(provider.start_authorization_flow).to include('client_id=dyn-client')
      expect(storage.get_client_info(server_url).metadata.redirect_uris).to eq([redirect_uri])
    end

    it 'defaults to the requested redirect URI when the response registers none' do
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-client', 'redirect_uris' => [] }.to_json)
      provider = provider_for

      expect(provider.start_authorization_flow).to include('client_id=dyn-client')
      expect(storage.get_client_info(server_url).metadata.redirect_uris).to eq([redirect_uri])
    end

    it 'still registers when every field has the type RFC 7591 gives it' do
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-client', 'client_secret' => 'secret',
                           'client_id_issued_at' => 1_700_000_000, 'client_secret_expires_at' => 4_102_444_800,
                           'redirect_uris' => [redirect_uri], 'token_endpoint_auth_method' => 'none',
                           'grant_types' => %w[authorization_code refresh_token],
                           'response_types' => ['code'], 'scope' => 'read',
                           'client_name' => 'ruby-mcp-client', 'contacts' => ['dev@example.com'],
                           'application_type' => 'native' }.to_json)
      provider = provider_for

      expect(provider.start_authorization_flow).to include('client_id=dyn-client')
      stored = storage.get_client_info(server_url)
      expect(stored.client_id).to eq('dyn-client')
      expect(stored.client_secret_expired?).to be(false)
    end
  end

  describe 'a stored client record whose client_id is not a string' do
    before { storage.set_server_metadata(server_url, server_metadata(issuer, registration: registration_endpoint)) }

    [12_345, ['dyn-client'], { 'id' => 'dyn-client' }, true, '', nil].each do |client_id|
      it "registers a new client instead of using #{client_id.inspect}" do
        record = { 'client_id' => client_id, 'issuer' => issuer,
                   'metadata' => { 'redirect_uris' => [redirect_uri] } }
        storage.set_client_info(server_url, record)
        stub_request(:post, registration_endpoint)
          .to_return(status: 201, headers: json,
                     body: { 'client_id' => 'dyn-client', 'redirect_uris' => [redirect_uri] }.to_json)
        provider = provider_for

        url = provider.start_authorization_flow

        expect(url).to include('client_id=dyn-client')
        expect(url).not_to include('client_id=&')
        expect(storage.get_client_info(server_url).client_id).to eq('dyn-client')
      end
    end

    it 'fails closed when no registration is possible rather than opening a browser' do
      storage.set_server_metadata(server_url, server_metadata)
      storage.set_client_info(server_url, { 'client_id' => 12_345, 'issuer' => issuer,
                                            'metadata' => { 'redirect_uris' => [redirect_uri] } })
      provider = provider_for

      expect { provider.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /registration/i)
      expect(storage.get_pkce(server_url)).to be_nil
    end
  end
end

# --- round34 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, thirty-fourth round: round 33 read both
# peer-controlled response bodies field by field, and left holes that the new
# validation itself opened.
#
# A field of the right JSON type is not yet a usable credential. An
# access_token or a token_type of "Bearer\r\nX-Injected: 1" is a string, and
# putting it in an `Authorization` header splits the header. A refresh_token
# of "" is a string, and storing it drops the refresh token the client had. A
# redirect_uris of [""] is an array of strings, and it opens the browser with
# an empty redirect_uri. What reaches a header, a credential slot or a URL
# must be usable bytes, on the way in from the wire and on the way back out of
# storage alike.
#
# And what a peer sends is never quoted verbatim: a body, or the token a JSON
# parser choked on, reaches a log line or an exception message (which
# BrowserOAuth renders on its error page) only through safe_error_text /
# describe_parse_error — helpers the provider itself defines, so no rescue
# path raises NoMethodError over a helper it does not have.
RSpec.describe 'MCP 2026-07-28 authorization — round 34' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer) { 'https://auth.example.com' }
  let(:token_endpoint) { "#{issuer}/token" }
  let(:registration_endpoint) { "#{issuer}/register" }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:state) { 'state-value' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  # Bytes that cannot appear in an HTTP header field value: a header value is
  # visible characters and spaces (RFC 9110 Section 5.5), so a CR, an LF, a
  # NUL or a DEL in an access_token or a token_type either splits the header
  # or is rejected by the HTTP stack.
  let(:header_unsafe_values) do
    ["fresh\r\nX-Injected: yes", "fre\nsh", "fre\rsh", "fresh\u0000", "fresh\u007F", "fresh\tvalue"]
  end

  def provider_for(store = storage, url: server_url)
    MCPClient::Auth::OAuthProvider.new(server_url: url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def server_metadata(iss = issuer, registration: nil, iss_supported: false)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      registration_endpoint: registration, code_challenge_methods_supported: ['S256'],
      authorization_response_iss_parameter_supported: iss_supported
    )
  end

  def client_info(id = 'client-1', iss = issuer)
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: 'pre_registered',
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
    )
  end

  def authorization_header_for(provider)
    request = Faraday::Request.new
    request.headers = {}
    provider.apply_authorization(request)
    request.headers['Authorization']
  end

  def store_refreshable_token(store = storage)
    store.set_server_metadata(server_url, server_metadata)
    store.set_client_info(server_url, client_info)
    # Still valid, but inside the five-minute early-refresh window.
    store.set_token(server_url,
                    MCPClient::Auth::Token.new(access_token: 'still-valid', expires_in: 60,
                                               refresh_token: 'refresh-1', issuer: issuer))
  end

  def store_pending_flow(store = storage, metadata: server_metadata, pkce: nil)
    store.set_server_metadata(server_url, metadata)
    store.set_state(server_url, state)
    store.set_client_info(server_url, client_info)
    store.set_pkce(server_url,
                   pkce || MCPClient::Auth::PKCE.new(issuer: issuer, iss_parameter_supported: false,
                                                     client_id: 'client-1', redirect_uri: redirect_uri))
  end

  describe 'a response body that is not JSON at all' do
    # describe_parse_error lives on JsonRpcCommon, which OAuthProvider does
    # not include: calling it from a rescue path raised NoMethodError out of
    # the very request the still-valid token should have served.
    it 'defines every peer-text helper its rescue paths call' do
      provider = provider_for
      %i[safe_error_text describe_parse_error].each do |helper|
        expect(provider.private_methods).to include(helper), helper.to_s
      end
    end

    it 'keeps the still-valid token when a refresh answers 200 with junk' do
      store_refreshable_token
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json, body: 'SECRET-123 not json at all')
      provider = provider_for

      expect { provider.access_token }.not_to raise_error
      expect(provider.access_token&.access_token).to eq('still-valid')
      expect(authorization_header_for(provider)).to eq('Bearer still-valid')
      expect(storage.get_token(server_url).access_token).to eq('still-valid')
    end

    it 'never logs the bytes a refresh response failed to parse' do
      store_refreshable_token
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json, body: 'SECRET-123 not json at all')

      provider_for.access_token

      expect(log_output.string).to include('malformed JSON')
      expect(log_output.string).not_to include('SECRET-123')
    end

    it 'fails a code exchange without quoting the bytes that failed to parse' do
      store_pending_flow
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json, body: 'SECRET-123 not json at all')
      provider = provider_for

      expect { provider.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError) { |error|
              expect(error.message).to include('malformed JSON')
              expect(error.message).not_to include('SECRET-123')
            }
    end

    it 'fails a registration without quoting the bytes that failed to parse' do
      storage.set_server_metadata(server_url, server_metadata(issuer, registration: registration_endpoint))
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json, body: 'SECRET-123 not json at all')
      provider = provider_for

      expect { provider.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError) { |error|
              expect(error.message).to include('malformed JSON')
              expect(error.message).not_to include('SECRET-123')
            }
    end
  end

  describe 'a refresh_token of empty bytes' do
    it 'keeps the refresh token the client had instead of storing ""' do
      store_refreshable_token
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer',
                           'refresh_token' => '' }.to_json)
      provider = provider_for

      expect { provider.access_token }.not_to raise_error
      stored = storage.get_token(server_url)
      expect(stored.access_token).to eq('still-valid')
      expect(stored.refresh_token).to eq('refresh-1')
    end

    it 'refuses the code exchange rather than registering a token with no refresh bytes' do
      store_pending_flow
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer',
                           'refresh_token' => '' }.to_json)
      provider = provider_for

      expect { provider.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /refresh_token/)
      expect(storage.get_token(server_url)).to be_nil
    end

    it 'still accepts a response that omits refresh_token' do
      store_refreshable_token
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)
      provider = provider_for

      expect(provider.access_token&.access_token).to eq('fresh')
      expect(storage.get_token(server_url).refresh_token).to eq('refresh-1')
    end
  end

  describe 'an access_token or token_type carrying header-invalid bytes' do
    it 'keeps the still-valid token on a refresh' do
      %w[access_token token_type].each do |field|
        header_unsafe_values.each do |value|
          context = "#{field}: #{value.inspect}"
          store = MCPClient::Auth::OAuthProvider::MemoryStorage.new
          store_refreshable_token(store)
          body = { 'access_token' => 'fresh', 'token_type' => 'Bearer' }
          body[field] = value
          stub_request(:post, token_endpoint).to_return(status: 200, headers: json, body: body.to_json)
          provider = provider_for(store)

          expect { provider.access_token }.not_to raise_error, context
          expect(authorization_header_for(provider)).to eq('Bearer still-valid'), context
          expect(store.get_token(server_url).access_token).to eq('still-valid'), context
        end
      end
    end

    it 'fails the code exchange instead of building a multi-line header' do
      %w[access_token token_type].each do |field|
        header_unsafe_values.each do |value|
          context = "#{field}: #{value.inspect}"
          store = MCPClient::Auth::OAuthProvider::MemoryStorage.new
          store_pending_flow(store)
          body = { 'access_token' => 'fresh', 'token_type' => 'Bearer' }
          body[field] = value
          stub_request(:post, token_endpoint).to_return(status: 200, headers: json, body: body.to_json)
          provider = provider_for(store)

          expect { provider.complete_authorization_flow('code', state) }
            .to raise_error(MCPClient::Errors::ConnectionError, /#{field}/), context
          expect(store.get_token(server_url)).to be_nil, context
          expect(authorization_header_for(provider)).to be_nil, context
        end
      end
    end
  end

  describe 'a stored token record whose token_type is not usable' do
    before { storage.set_server_metadata(server_url, server_metadata) }

    [12_345, ['Bearer'], { 'type' => 'Bearer' }, true, '', "Bea\r\nrer", "Bearer\u0007"].each do |token_type|
      it "presents no token for a token_type of #{token_type.inspect}" do
        storage.set_token(server_url,
                          { 'access_token' => 'stored', 'token_type' => token_type, 'issuer' => issuer })
        provider = provider_for

        expect { provider.access_token }.not_to raise_error
        expect(provider.access_token).to be_nil
        expect(authorization_header_for(provider)).to be_nil
      end
    end

    it 'presents no token for an access_token carrying header-invalid bytes' do
      storage.set_token(server_url,
                        { 'access_token' => "stored\r\nX-Injected: yes", 'token_type' => 'Bearer',
                          'issuer' => issuer })
      provider = provider_for

      expect(provider.access_token).to be_nil
      expect(authorization_header_for(provider)).to be_nil
    end

    it 'still presents a record whose fields are usable' do
      storage.set_token(server_url, { 'access_token' => 'stored', 'token_type' => 'bearer', 'issuer' => issuer })
      provider = provider_for

      expect(provider.access_token&.access_token).to eq('stored')
      expect(authorization_header_for(provider)).to eq('Bearer stored')
    end
  end

  describe 'a registration response whose redirect_uris are not usable' do
    before { storage.set_server_metadata(server_url, server_metadata(issuer, registration: registration_endpoint)) }

    [[''], ['http://localhost:1/cb', ''], ['/cb'], ['not a uri'], ["http://localhost:1/cb\r\n"]].each do |uris|
      it "refuses #{uris.inspect} before the browser is opened" do
        store = MCPClient::Auth::OAuthProvider::MemoryStorage.new
        store.set_server_metadata(server_url, server_metadata(issuer, registration: registration_endpoint))
        stub_request(:post, registration_endpoint)
          .to_return(status: 201, headers: json,
                     body: { 'client_id' => 'dyn-client', 'redirect_uris' => uris }.to_json)
        provider = provider_for(store)

        expect { provider.start_authorization_flow }
          .to raise_error(MCPClient::Errors::ConnectionError, /redirect_uris/)
        expect(store.get_client_info(server_url)).to be_nil
        expect(store.get_pkce(server_url)).to be_nil
      end
    end

    it 'still registers with a usable redirect URI' do
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-client', 'redirect_uris' => [redirect_uri] }.to_json)
      provider = provider_for

      url = provider.start_authorization_flow
      expect(url).to include('client_id=dyn-client')
      expect(url).to include('redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcb')
    end
  end

  describe 'an authorization_response_iss_parameter_supported that is not a boolean' do
    ['true', 'false', 1, 0, {}, [], 'yes'].each do |value|
      it "treats #{value.inspect} as no answer and requires iss" do
        store = MCPClient::Auth::OAuthProvider::MemoryStorage.new
        store_pending_flow(store,
                           metadata: server_metadata(issuer, iss_supported: value),
                           pkce: MCPClient::Auth::PKCE.new(issuer: issuer, client_id: 'client-1',
                                                           redirect_uri: redirect_uri))
        provider = provider_for(store)

        expect { provider.complete_authorization_flow('code', state) }
          .to raise_error(MCPClient::Errors::ConnectionError, /iss/)
        expect(store.get_token(server_url)).to be_nil
      end
    end

    it 'reads a malformed advertisement as "advertised"' do
      metadata = server_metadata(issuer, iss_supported: 'true')
      expect(metadata.iss_parameter_supported?).to be(true)
      expect(metadata.iss_parameter_recorded?).to be(true)
    end

    it 'keeps a malformed advertisement fail-closed through a discovery document' do
      metadata = MCPClient::Auth::ServerMetadata.from_discovery_document(
        'issuer' => issuer, 'authorization_endpoint' => "#{issuer}/authorize",
        'token_endpoint' => token_endpoint, 'authorization_response_iss_parameter_supported' => 'true'
      )

      expect(metadata.iss_parameter_supported?).to be(true)
    end

    it 'still reads an explicit false as "not advertised"' do
      store_pending_flow(metadata: server_metadata(issuer, iss_supported: false),
                         pkce: MCPClient::Auth::PKCE.new(issuer: issuer, client_id: 'client-1',
                                                         redirect_uri: redirect_uri))
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)
      provider = provider_for

      expect(provider.complete_authorization_flow('code', state).access_token).to eq('fresh')
    end

    it 'accepts the response when the advertised iss is carried' do
      store_pending_flow(metadata: server_metadata(issuer, iss_supported: 'true'),
                         pkce: MCPClient::Auth::PKCE.new(issuer: issuer, client_id: 'client-1',
                                                         redirect_uri: redirect_uri))
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)
      provider = provider_for

      expect(provider.complete_authorization_flow('code', state, iss: issuer).access_token).to eq('fresh')
    end

    # A PKCE record read back from a hash-persisting backend can carry the
    # same malformed value; "not a boolean" is no answer there either, and the
    # authorization server's own metadata decides.
    it 'ignores a malformed value recorded with the request and asks the metadata' do
      pkce = MCPClient::Auth::PKCE.from_h('code_verifier' => 'v' * 64, 'code_challenge' => 'challenge',
                                          'issuer' => issuer, 'iss_parameter_supported' => 'false',
                                          'client_id' => 'client-1', 'redirect_uri' => redirect_uri)
      store_pending_flow(metadata: server_metadata(issuer, iss_supported: true), pkce: pkce)
      provider = provider_for

      expect { provider.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /iss/)
    end

    # ... and the metadata can answer "not advertised" as well as "advertised":
    # a malformed recorded value read as "advertised" would refuse this
    # callback, which carries no iss because the server sends none.
    it 'completes without iss when the metadata says the server does not advertise it' do
      pkce = MCPClient::Auth::PKCE.from_h('code_verifier' => 'v' * 64, 'code_challenge' => 'challenge',
                                          'issuer' => issuer, 'iss_parameter_supported' => 'true',
                                          'client_id' => 'client-1', 'redirect_uri' => redirect_uri)
      store_pending_flow(metadata: server_metadata(issuer, iss_supported: false), pkce: pkce)
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)
      provider = provider_for

      expect(provider.complete_authorization_flow('code', state).access_token).to eq('fresh')
    end
  end

  describe 'peer bytes in an exception message' do
    let(:hostile_body) do
      "error\r\nX-Injected: yes\r\n\r\n<script>alert('x')</script>#{'A' * 500}"
    end

    it 'sanitizes the body of a failed token exchange' do
      store_pending_flow
      stub_request(:post, token_endpoint).to_return(status: 400, headers: json, body: hostile_body)
      provider = provider_for

      expect { provider.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError) { |error|
              expect(error.message).not_to include("\r")
              expect(error.message).not_to include("\n")
              expect(error.message.length).to be < 400
            }
    end
  end
end

# --- round35 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, thirty-fifth round.
#
# Round 34 routed every peer string through a sanitizer and then wrote the
# sanitizer with `String#gsub`, which raises `ArgumentError` on bytes that are
# not valid UTF-8 — so the helper that exists to make peer bytes safe was the
# one thing a peer could crash the client with. A peer-text helper is total or
# it is worse than none: whatever comes off the wire, out of a callback query
# string or out of a parser's own message, it returns printable, bounded text.
#
# Round 33 read the token and registration responses field by field and left
# the two metadata documents unread: a `scopes_supported` string still raised
# `NoMethodError` out of `start_authorization_flow`, and a
# `code_challenge_methods_supported` of `"S256"` was *treated as PKCE
# support*, because a String answers `include?`. Both documents are now read
# against the types RFC 8414 and RFC 9728 give their fields, on the wire and
# on the way back out of storage.
#
# The rest of the round: the credentials go out the way the authorization
# server asked for them (RFC 7591's default is `client_secret_basic`, not
# `none`); an authorization endpoint's own query string survives the
# authorization parameters (RFC 6749 Section 3.1); a persisted token record
# is validated before its `expires_in` is added to a `Time`; no log line
# quotes an access token or a callback query string; and a registered
# redirect URI must be one a callback could actually arrive on.
RSpec.describe 'MCP 2026-07-28 authorization — round 35' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer) { 'https://auth.example.com' }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:as_url) { "#{issuer}/.well-known/oauth-authorization-server" }
  let(:oidc_url) { "#{issuer}/.well-known/openid-configuration" }
  let(:token_endpoint) { "#{issuer}/token" }
  let(:registration_endpoint) { "#{issuer}/register" }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:state) { 'state-value' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  # Bytes that are not valid UTF-8, in the shapes a peer can produce them:
  # a lone continuation byte, a truncated multi-byte sequence, an overlong
  # form, bytes carried in a binary (Faraday) body, and a string in another
  # encoding altogether. None of them may raise out of a helper whose whole
  # job is to make peer text safe.
  let(:invalid_utf8) do
    [
      +"\xFF",
      +"error: \xC3(",
      +"\xE2\x28\xA1 description",
      (+"caf\xC3\xA9 \xFF").force_encoding(Encoding::ASCII_8BIT),
      'plain text'.encode('UTF-16'),
      +"\xF0\x9F trailing"
    ]
  end

  def provider_for(store = storage, url: server_url)
    MCPClient::Auth::OAuthProvider.new(server_url: url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def server_metadata(iss = issuer, registration: nil, iss_supported: false, authorization_endpoint: nil,
                      pkce_methods: ['S256'])
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: authorization_endpoint || "#{iss}/authorize",
      token_endpoint: "#{iss}/token", registration_endpoint: registration,
      code_challenge_methods_supported: pkce_methods,
      authorization_response_iss_parameter_supported: iss_supported
    )
  end

  def client_info(id = 'client-1', iss = issuer, secret: nil, auth_method: 'none')
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: 'pre_registered', client_secret: secret,
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri],
                                                    token_endpoint_auth_method: auth_method)
    )
  end

  def store_pending_flow(store = storage, metadata: server_metadata, client: client_info)
    store.set_server_metadata(server_url, metadata)
    store.set_state(server_url, state)
    store.set_client_info(server_url, client)
    store.set_pkce(server_url,
                   MCPClient::Auth::PKCE.new(issuer: metadata.issuer, iss_parameter_supported: false,
                                             client_id: client.client_id, redirect_uri: redirect_uri))
  end

  def store_refreshable_token(store = storage, client: client_info)
    store.set_server_metadata(server_url, server_metadata)
    store.set_client_info(server_url, client)
    store.set_token(server_url,
                    MCPClient::Auth::Token.new(access_token: 'still-valid', expires_in: 60,
                                               refresh_token: 'refresh-1', issuer: issuer))
  end

  def stub_discovery(as_document)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => [issuer] }.to_json)
    stub_request(:get, as_url).to_return(status: 200, headers: json, body: as_document.to_json)
    stub_request(:get, oidc_url).to_return(status: 404, body: '')
  end

  def valid_as_document
    {
      'issuer' => issuer, 'authorization_endpoint' => "#{issuer}/authorize",
      'token_endpoint' => token_endpoint, 'code_challenge_methods_supported' => ['S256']
    }
  end

  # ---------------------------------------------------------------- finding 1

  describe 'peer text that is not valid UTF-8' do
    it 'never raises out of any peer-text helper' do
      provider = provider_for

      invalid_utf8.each do |bytes|
        expect { provider.send(:safe_error_text, bytes) }.not_to raise_error, bytes.inspect
        expect { provider.send(:safe_body_text, bytes) }.not_to raise_error, bytes.inspect
        expect(provider.send(:safe_error_text, bytes)).to be_a(String)
        expect(provider.send(:safe_error_text, bytes)).to be_valid_encoding
        expect(provider.send(:safe_body_text, bytes)).to be_valid_encoding
      end
    end

    it 'never raises out of describe_parse_error, whatever the parser choked on' do
      provider = provider_for

      invalid_utf8.each do |bytes|
        error = begin
          JSON.parse(%({"a": #{bytes.dup.force_encoding(Encoding::UTF_8)}}))
        rescue JSON::ParserError => e
          e
        end
        error ||= JSON::ParserError.new(+"unexpected \xFF at line 1 column 7")

        expect { provider.send(:describe_parse_error, error, bytes) }.not_to raise_error, bytes.inspect
        described = provider.send(:describe_parse_error, error, bytes)
        expect(described).to include('malformed JSON')
        expect(described).to be_valid_encoding
      end
    end

    it 'still strips control characters and bounds the length of undecodable text' do
      provider = provider_for
      text = provider.send(:safe_error_text, "a\r\nb\xFF#{'x' * 500}")

      expect(text).not_to include("\r")
      expect(text).not_to include("\n")
      expect(text.length).to be <= MCPClient::Auth::PeerText::PEER_TEXT_LIMIT
    end

    it 'still returns nil for a non-String and text for a String' do
      provider = provider_for

      expect(provider.send(:safe_error_text, nil)).to be_nil
      expect(provider.send(:safe_error_text, 42)).to be_nil
      expect(provider.send(:safe_error_text, 'plain')).to eq('plain')
      expect(provider.send(:safe_body_text, nil)).to eq('')
    end

    it 'reports a token endpoint 400 whose body is not UTF-8 as a ConnectionError' do
      store_pending_flow
      stub_request(:post, token_endpoint)
        .to_return(status: 400, headers: json, body: +"{\"error\":\"invalid_grant \xFF\"}")

      expect { provider_for.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /Token exchange failed: HTTP 400/)
    end

    it 'reports a token endpoint 200 whose body is not UTF-8 as a ConnectionError' do
      store_pending_flow
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json, body: +"\xFF not json at all")

      expect { provider_for.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /Invalid token response/)
    end

    it 'shows an error_description that is not UTF-8 instead of crashing the callback' do
      store_pending_flow

      message = provider_for.authorization_error_message(
        'state' => state, 'error' => 'access_denied', 'error_description' => CGI.unescape('%FF%FE denied')
      )

      expect(message).to be_a(String)
      expect(message).to be_valid_encoding
      # The printable part of the description is kept, not replaced by a
      # generic message.
      expect(message).to include('denied')
    end

    it 'lets the browser callback complete for an error_description of %FF' do
      store_pending_flow
      browser = MCPClient::Auth::BrowserOAuth.new(provider_for, callback_port: 1, callback_path: '/cb',
                                                                logger: logger)
      result = {}
      socket = instance_double('TCPSocket')
      allow(socket).to receive(:setsockopt)
      allow(socket).to receive(:print)
      allow(socket).to receive(:close)
      allow(socket).to receive(:gets).and_return(
        "GET /cb?state=#{state}&error=access_denied&error_description=%FF%FE HTTP/1.1\r\n", "\r\n", nil
      )

      expect do
        browser.send(:handle_http_request, socket, result, Mutex.new, ConditionVariable.new)
      end.not_to raise_error
      expect(result[:completed]).to be(true)
      expect(result[:error]).to be_a(String)
    end
  end

  # ---------------------------------------------------------------- finding 2

  describe 'a protected resource document whose fields are not of their RFC 9728 types' do
    before do
      stub_request(:get, as_url).to_return(status: 200, headers: json, body: valid_as_document.to_json)
      stub_request(:get, oidc_url).to_return(status: 404, body: '')
    end

    {
      'scopes_supported' => 'mcp:read mcp:write',
      'authorization_servers' => 'https://auth.example.com',
      'resource' => 42,
      'scopes_supported (array of non-strings)' => nil
    }.each do |field, value|
      next if value.nil?

      it "refuses a document whose #{field} is #{value.inspect}" do
        stub_request(:get, prm_url)
          .to_return(status: 200, headers: json,
                     body: { 'resource' => server_url, 'authorization_servers' => [issuer] }
                             .merge(field => value).to_json)

        expect { provider_for.start_authorization_flow }
          .to raise_error(MCPClient::Errors::ConnectionError, /#{Regexp.escape(field)}/)
      end
    end

    it 'refuses a scopes_supported array carrying a non-string' do
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [issuer],
                           'scopes_supported' => ['mcp:read', 7] }.to_json)

      expect { provider_for.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /scopes_supported/)
    end

    it 'refuses an authorization_servers array carrying a non-string' do
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [{ 'url' => issuer }] }.to_json)

      expect { provider_for.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization_servers/)
    end

    it 'never resolves a scope out of a refused document' do
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [issuer],
                           'scopes_supported' => 'mcp:read' }.to_json)
      provider = provider_for

      expect { provider.send(:discover_authorization_server) }.to raise_error(MCPClient::Errors::ConnectionError)
      expect(provider.send(:resolved_scope)).to be_nil
    end

    it 'still accepts a well-formed document' do
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [issuer],
                           'scopes_supported' => ['mcp:read'] }.to_json)
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn', 'redirect_uris' => [redirect_uri] }.to_json)

      expect(provider_for.send(:discover_authorization_server).issuer).to eq(issuer)
    end
  end

  describe 'an authorization server document whose fields are not of their RFC 8414 types' do
    {
      'code_challenge_methods_supported' => 'S256',
      'scopes_supported' => 'mcp:read',
      'response_types_supported' => 'code',
      'grant_types_supported' => { 'authorization_code' => true },
      'authorization_endpoint' => 42,
      'token_endpoint' => ['https://auth.example.com/token'],
      'registration_endpoint' => 7
    }.each do |field, value|
      it "refuses a document whose #{field} is #{value.inspect}" do
        stub_discovery(valid_as_document.merge(field => value))

        expect { provider_for.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError)
        expect(log_output.string).to include(field)
        expect(storage.get_server_metadata(server_url)).to be_nil
      end
    end

    it 'never reads a code_challenge_methods_supported string as PKCE support' do
      stub_discovery(valid_as_document.merge('code_challenge_methods_supported' => 'S256 plain'))
      stub_request(:post, registration_endpoint)

      expect { provider_for.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError)
      expect(WebMock).not_to have_requested(:post, registration_endpoint)
      expect(storage.get_pkce(server_url)).to be_nil
    end

    it 'refuses a cached record whose code_challenge_methods_supported is a string' do
      provider = provider_for
      metadata = server_metadata(pkce_methods: 'S256')

      expect { provider.send(:verify_pkce_support!, metadata) }
        .to raise_error(MCPClient::Errors::ConnectionError, /code_challenge_methods_supported/)
    end

    it 'refuses a cached record whose code_challenge_methods_supported is a hash' do
      provider = provider_for

      expect { provider.send(:verify_pkce_support!, server_metadata(pkce_methods: { 'S256' => true })) }
        .to raise_error(MCPClient::Errors::ConnectionError, /code_challenge_methods_supported/)
    end

    it 'never joins a cached scopes_supported that is not an array' do
      storage.set_server_metadata(server_url, server_metadata)
      provider = provider_for
      allow(provider).to receive(:discover_authorization_server)
        .and_return(MCPClient::Auth::ServerMetadata.new(
                      issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                      token_endpoint: token_endpoint, scopes_supported: 'mcp:read',
                      code_challenge_methods_supported: ['S256']
                    ))

      expect { provider.supported_scopes }.not_to raise_error
      expect(provider.supported_scopes).to eq([])
    end

    it 'still accepts a well-formed document' do
      stub_discovery(valid_as_document.merge('scopes_supported' => ['mcp:read'],
                                             'registration_endpoint' => registration_endpoint))

      expect(provider_for.send(:discover_authorization_server).token_endpoint).to eq(token_endpoint)
    end
  end

  # ---------------------------------------------------------------- finding 3

  describe 'the token endpoint authentication method' do
    it 'stores a registration that issues a secret without a method as client_secret_basic' do
      storage.set_server_metadata(server_url, server_metadata(registration: registration_endpoint))
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn', 'client_secret' => 's3cr3t',
                           'redirect_uris' => [redirect_uri] }.to_json)

      provider_for.start_authorization_flow

      expect(storage.get_client_info(server_url).metadata.token_endpoint_auth_method)
        .to eq('client_secret_basic')
    end

    it 'still stores a registration without a secret as a public client' do
      storage.set_server_metadata(server_url, server_metadata(registration: registration_endpoint))
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn', 'redirect_uris' => [redirect_uri] }.to_json)

      provider_for.start_authorization_flow

      expect(storage.get_client_info(server_url).metadata.token_endpoint_auth_method).to eq('none')
    end

    it 'still honours an explicit method the server registered' do
      storage.set_server_metadata(server_url, server_metadata(registration: registration_endpoint))
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn', 'client_secret' => 's3cr3t',
                           'token_endpoint_auth_method' => 'client_secret_post',
                           'redirect_uris' => [redirect_uri] }.to_json)

      provider_for.start_authorization_flow

      expect(storage.get_client_info(server_url).metadata.token_endpoint_auth_method)
        .to eq('client_secret_post')
    end

    it 'sends a client_secret_basic code exchange as an Authorization header' do
      store_pending_flow(client: client_info(secret: 's3cr3t', auth_method: 'client_secret_basic'))
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)

      provider_for.complete_authorization_flow('code', state)

      expect(WebMock).to have_requested(:post, token_endpoint)
        .with(headers: { 'Authorization' => "Basic #{Base64.strict_encode64('client-1:s3cr3t')}" }) { |req|
          !req.body.include?('client_secret')
        }
    end

    it 'sends a client_secret_basic refresh as an Authorization header' do
      store_refreshable_token(client: client_info(secret: 's3cr3t', auth_method: 'client_secret_basic'))
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'refreshed', 'token_type' => 'Bearer' }.to_json)

      expect(provider_for.access_token.access_token).to eq('refreshed')
      expect(WebMock).to have_requested(:post, token_endpoint)
        .with(headers: { 'Authorization' => "Basic #{Base64.strict_encode64('client-1:s3cr3t')}" })
    end

    it 'form-encodes the credentials before the Basic encoding (RFC 6749 Section 2.3.1)' do
      store_pending_flow(client: client_info('cli ent:1', secret: 'p@ss word',
                                                          auth_method: 'client_secret_basic'))
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)

      provider_for.complete_authorization_flow('code', state)

      expected = Base64.strict_encode64("#{URI.encode_www_form_component('cli ent:1')}:" \
                                        "#{URI.encode_www_form_component('p@ss word')}")
      expect(WebMock).to have_requested(:post, token_endpoint)
        .with(headers: { 'Authorization' => "Basic #{expected}" })
    end

    it 'defaults a stored secret without a usable method to client_secret_basic' do
      store_pending_flow(client: client_info(secret: 's3cr3t', auth_method: 'none'))
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)

      provider_for.complete_authorization_flow('code', state)

      expect(WebMock).to have_requested(:post, token_endpoint)
        .with(headers: { 'Authorization' => "Basic #{Base64.strict_encode64('client-1:s3cr3t')}" })
    end

    it 'still posts a client_secret_post secret in the body' do
      store_pending_flow(client: client_info(secret: 's3cr3t', auth_method: 'client_secret_post'))
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)

      provider_for.complete_authorization_flow('code', state)

      expect(WebMock).to have_requested(:post, token_endpoint)
        .with(body: /client_secret=s3cr3t/) { |req| !req.headers.key?('Authorization') }
    end

    it 'sends no client authentication for a public client' do
      store_pending_flow(client: client_info)
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)

      provider_for.complete_authorization_flow('code', state)

      expect(WebMock).to have_requested(:post, token_endpoint) { |req|
        !req.headers.key?('Authorization') && !req.body.include?('client_secret')
      }
    end

    it 'sends no secret for a method it cannot honour' do
      store_pending_flow(client: client_info(secret: 's3cr3t', auth_method: 'private_key_jwt'))
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer' }.to_json)

      provider_for.complete_authorization_flow('code', state)

      expect(WebMock).to have_requested(:post, token_endpoint) { |req|
        !req.headers.key?('Authorization') && !req.body.include?('s3cr3t')
      }
      expect(log_output.string).to include('private_key_jwt')
    end
  end

  # ---------------------------------------------------------------- finding 4

  describe 'an authorization endpoint that carries its own query string' do
    it 'appends the authorization parameters instead of replacing the query' do
      storage.set_server_metadata(server_url,
                                  server_metadata(authorization_endpoint: "#{issuer}/authorize?tenant=acme"))
      storage.set_client_info(server_url, client_info)

      url = provider_for.start_authorization_flow

      expect(url).to start_with("#{issuer}/authorize?tenant=acme&")
      expect(url).to include('response_type=code')
      expect(url).to include('client_id=client-1')
      expect(url).to include('code_challenge_method=S256')
    end

    it 'keeps every parameter of a multi-parameter endpoint query' do
      storage.set_server_metadata(
        server_url,
        server_metadata(authorization_endpoint: "#{issuer}/authorize?tenant=acme&brand=blue")
      )
      storage.set_client_info(server_url, client_info)

      query = URI.decode_www_form(URI.parse(provider_for.start_authorization_flow).query).to_h

      expect(query['tenant']).to eq('acme')
      expect(query['brand']).to eq('blue')
      expect(query['redirect_uri']).to eq(redirect_uri)
    end

    it 'still builds a plain endpoint without a leading ampersand' do
      storage.set_server_metadata(server_url, server_metadata)
      storage.set_client_info(server_url, client_info)

      url = provider_for.start_authorization_flow

      expect(url).to start_with("#{issuer}/authorize?response_type=code")
      expect(url).not_to include('?&')
    end
  end

  # ---------------------------------------------------------------- finding 5

  describe 'a persisted token record whose expiry cannot be read' do
    ['3600', 3600.5.to_s, [], {}, true].each do |value|
      it "does not raise for an expires_in of #{value.inspect}" do
        expect { MCPClient::Auth::Token.from_h('access_token' => 'a', 'expires_in' => value) }
          .not_to raise_error
      end

      it "treats an expires_in of #{value.inspect} as expired" do
        token = MCPClient::Auth::Token.from_h('access_token' => 'a', 'expires_in' => value)

        expect(token.expires_in).to be_nil
        expect(token.expired?).to be(true)
        expect(token.expires_soon?).to be(true)
      end
    end

    ['not a time', 12_345, [], {}].each do |value|
      it "treats an expires_at of #{value.inspect} as expired instead of raising" do
        token = nil
        expect { token = MCPClient::Auth::Token.from_h('access_token' => 'a', 'expires_at' => value) }
          .not_to raise_error
        expect(token.expired?).to be(true)
      end
    end

    it 'still reads a well-formed record' do
      token = MCPClient::Auth::Token.from_h('access_token' => 'a', 'expires_in' => 3600)

      expect(token.expires_in).to eq(3600)
      expect(token.expired?).to be(false)
      expect(token.expires_at).to be_within(5).of(Time.now + 3600)
    end

    it 'still round-trips through to_h' do
      token = MCPClient::Auth::Token.new(access_token: 'a', expires_in: 3600, issuer: issuer)
      restored = MCPClient::Auth::Token.from_h(token.to_h)

      expect(restored.expires_at.to_i).to eq(token.expires_at.to_i)
      expect(restored.issuer).to eq(issuer)
      expect(restored.expired?).to be(false)
    end

    it 'presents no token for a hash-persisted record with a string expires_in' do
      storage.set_server_metadata(server_url, server_metadata)
      storage.set_token(server_url,
                        { 'access_token' => 'stored', 'token_type' => 'Bearer', 'expires_in' => '3600',
                          'issuer' => issuer })
      provider = provider_for

      expect { provider.access_token }.not_to raise_error
      expect(provider.access_token).to be_nil
    end
  end

  # ---------------------------------------------------------------- finding 6

  describe 'what a debug log may carry' do
    it 'never quotes the access token when the header is applied' do
      storage.set_server_metadata(server_url, server_metadata)
      storage.set_token(server_url,
                        MCPClient::Auth::Token.new(access_token: 'SECRET-TOKEN-VALUE', issuer: issuer))
      request = Faraday::Request.new
      request.headers = {}

      provider_for.apply_authorization(request)

      expect(request.headers['Authorization']).to eq('Bearer SECRET-TOKEN-VALUE')
      expect(log_output.string).not_to include('SECRET-TOKEN')
      expect(log_output.string).not_to include('Bearer SECRET')
    end

    it 'never quotes the callback query string' do
      browser = MCPClient::Auth::BrowserOAuth.new(provider_for, callback_port: 1, callback_path: '/cb',
                                                                logger: logger)
      socket = instance_double('TCPSocket')
      allow(socket).to receive(:setsockopt)
      allow(socket).to receive(:print)
      allow(socket).to receive(:close)
      allow(socket).to receive(:gets).and_return(
        "GET /cb?code=SECRET-CODE&state=#{state} HTTP/1.1\r\n", "\r\n", nil
      )

      browser.send(:handle_http_request, socket, {}, Mutex.new, ConditionVariable.new)

      expect(log_output.string).not_to include('SECRET-CODE')
      expect(log_output.string).not_to include('code=')
      expect(log_output.string).to include('/cb')
    end
  end

  # ---------------------------------------------------------------- finding 7

  describe 'a redirect URI a callback could never arrive on' do
    let(:unusable) do
      ['javascript:alert(1)', 'http:', 'https:', 'mailto:someone@example.com', 'data:text/html,<b>x</b>',
       'file:///cb', 'javascript:/alert(1)', '//example.com/cb', 'urn:ietf:wg:oauth:2.0:oob',
       # MCP 2026-07-28 "Communication Security": every redirect URI is
       # localhost or HTTPS, so plain HTTP anywhere else is not one.
       'http://app.example.com/callback', 'http://10.0.0.1/callback']
    end
    let(:usable) do
      ['http://localhost:1/cb', 'https://app.example.com/callback', 'http://127.0.0.1:8080/callback',
       'http://[::1]:8080/callback', 'com.example.app:/oauth2/callback', 'com.example.app://oauth']
    end

    it 'is not a usable redirect URI' do
      provider = provider_for

      unusable.each { |uri| expect(provider.send(:redirect_uri_bytes?, uri)).to be(false), uri }
    end

    it 'still accepts one a callback can arrive on' do
      provider = provider_for

      usable.each { |uri| expect(provider.send(:redirect_uri_bytes?, uri)).to be(true), uri }
    end

    it 'refuses a redirect URI with a fragment (RFC 6749 Section 3.1.2)' do
      expect(provider_for.send(:redirect_uri_bytes?, 'http://localhost:1/cb#fragment')).to be(false)
    end

    it 'never opens the browser for a registration that carries one' do
      ['javascript:alert(1)', 'http:', 'data:text/html,x'].each do |uri|
        store = MCPClient::Auth::OAuthProvider::MemoryStorage.new
        store.set_server_metadata(server_url, server_metadata(registration: registration_endpoint))
        stub_request(:post, registration_endpoint)
          .to_return(status: 201, headers: json,
                     body: { 'client_id' => 'dyn', 'redirect_uris' => [uri] }.to_json)

        expect { provider_for(store).start_authorization_flow }
          .to raise_error(MCPClient::Errors::ConnectionError, /redirect_uris/), uri
        expect(store.get_client_info(server_url)).to be_nil
        expect(store.get_pkce(server_url)).to be_nil
      end
    end
  end
end

# --- round37 ---------------------------------------------------------------

# MCP 2026-07-28 authorization — round 37.
#
# The 2026 spec says an authorization request is ONE record: "the client MUST
# record the `issuer` value ... and associate it with the same per-request
# record used to store the PKCE code verifier (and the `state` value, if
# used)". This client kept the state in a slot of its own, so two flows
# sharing a storage backend could tear one apart: flow A writes its PKCE,
# flow B writes PKCE and state, flow A writes its state — and storage now
# pairs A's state with B's issuer, client and verifier. A callback carrying
# A's state then answers for B's request, and A's code is POSTed to B's token
# endpoint.
#
# A code exchange is two events with a gap between them, exactly as a refresh
# is: the request goes to the authorization server the flow started at, and
# the response arrives at a client whose authorization server may have changed
# meanwhile. The refresh path re-checks; completion did not, so a late
# response stored its token over the new server's and deleted the new server's
# pending flow.
#
# The remaining findings are about which record answers a question: a refresh
# preferred an older per-issuer copy over the credentials a host had just
# rotated into the slot it writes to; a portable Client ID Metadata Document
# id in that slot answered ahead of pre-registered credentials for the very
# authorization server in use; and a storage failure on the registration a
# flow needs was logged at debug and reported as success.
#
# Finally two conformance requirements the client stated but did not enforce:
# RFC 6749 Section 5.1 makes `token_type` REQUIRED and defines no default, and
# the MCP security considerations require every redirect URI to be `localhost`
# or HTTPS.
RSpec.describe 'MCP 2026-07-28 authorization — round 37' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer_a) { 'https://as-a.example.com' }
  let(:issuer_b) { 'https://as-b.example.com' }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage, **options)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store, **options)
  end

  def server_metadata(iss, registration: nil, cimd: false)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      registration_endpoint: registration, code_challenge_methods_supported: ['S256'],
      authorization_response_iss_parameter_supported: false,
      client_id_metadata_document_supported: cimd
    )
  end

  def client_info(id, iss, type: 'pre_registered', secret: nil, auth_method: 'none')
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: type, client_secret: secret,
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri],
                                                    token_endpoint_auth_method: auth_method)
    )
  end

  def token_for(iss, access_token, refresh: nil, expires_in: 3600)
    MCPClient::Auth::Token.new(access_token: access_token, expires_in: expires_in,
                               refresh_token: refresh, issuer: iss)
  end

  def state_in(url)
    URI.decode_www_form(URI.parse(url).query).to_h['state']
  end

  def scope_in(url)
    URI.decode_www_form(URI.parse(url).query).to_h['scope']
  end

  # ------------------------------------------------------------- finding 1
  #
  # The tear is produced entirely by production code: provider B runs a whole
  # authorization flow of its own in the window between provider A's
  # `set_pkce` and provider A's `set_state`.
  describe 'two authorization requests interleaved in one storage backend' do
    let(:interleaving_storage) do
      Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        attr_accessor :between_pkce_and_state

        def set_pkce(key, pkce)
          super
          hook = @between_pkce_and_state
          @between_pkce_and_state = nil
          hook&.call
        end
      end.new
    end

    # Provider A's flow, with B's whole flow slipped into the window.
    # @return [String] the authorization URL A returned
    def start_a_interleaved_with_b
      interleaving_storage.set_server_metadata(server_url, server_metadata(issuer_a))
      interleaving_storage.set_client_info(server_url, client_info('client-a', issuer_a))
      provider_a = provider_for(interleaving_storage)
      provider_b = provider_for(interleaving_storage)
      interleaving_storage.set_client_info(provider_b.client_registration_key(issuer_b),
                                           client_info('client-b', issuer_b))
      interleaving_storage.between_pkce_and_state = lambda {
        interleaving_storage.set_server_metadata(server_url, server_metadata(issuer_b))
        provider_b.start_authorization_flow
      }
      provider_a.start_authorization_flow
    end

    it 'tears the two requests apart in storage, pairing one state with the other request' do
      url_a = start_a_interleaved_with_b

      expect(interleaving_storage.get_state(server_url)).to eq(state_in(url_a))
      expect(interleaving_storage.get_pkce(server_url).issuer).to eq(issuer_b)
    end

    it 'never sends the code of one authorization server to the other' do
      url_a = start_a_interleaved_with_b
      at_b = stub_request(:post, "#{issuer_b}/token")
             .to_return(status: 200, headers: json,
                        body: { 'access_token' => 'token-b', 'token_type' => 'Bearer' }.to_json)

      expect { provider_for(interleaving_storage).complete_authorization_flow('code-from-a', state_in(url_a)) }
        .to raise_error(MCPClient::Errors::ConnectionError, /restart the authorization/)
      expect(at_b).not_to have_been_requested
    end

    it 'records the state on the per-request record, not only in a slot of its own' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))

      url = provider_for.start_authorization_flow

      expect(storage.get_pkce(server_url).state).to eq(state_in(url))
    end
  end

  # ------------------------------------------------------------- finding 2
  describe 'a code exchange whose response arrives after the authorization server switched' do
    def store_pending_flow_at_a
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      storage.set_state(server_url, 'state-a')
      storage.set_pkce(server_url, MCPClient::Auth::PKCE.from_h(
                                     'code_verifier' => 'verifier-a', 'code_challenge' => 'challenge-a',
                                     'issuer' => issuer_a, 'iss_parameter_supported' => false,
                                     'client_id' => 'client-a', 'redirect_uri' => redirect_uri,
                                     'state' => 'state-a'
                                   ))
    end

    # What another provider sharing the storage did while A's code was in
    # flight: it selected B, stored B's token, and started a flow of its own.
    def switch_to_b
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_client_info(server_url, client_info('client-b', issuer_b))
      storage.set_token(server_url, token_for(issuer_b, 'token-b'))
      storage.set_state(server_url, 'state-b')
      storage.set_pkce(server_url, MCPClient::Auth::PKCE.from_h(
                                     'code_verifier' => 'verifier-b', 'code_challenge' => 'challenge-b',
                                     'issuer' => issuer_b, 'iss_parameter_supported' => false,
                                     'client_id' => 'client-b', 'redirect_uri' => redirect_uri,
                                     'state' => 'state-b'
                                   ))
    end

    def exchange_answers_after_the_switch
      stub_request(:post, "#{issuer_a}/token").to_return do
        switch_to_b
        { status: 200, headers: json,
          body: { 'access_token' => 'late-a', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json }
      end
    end

    before { store_pending_flow_at_a }

    it 'refuses the late token rather than handing it back' do
      exchange_answers_after_the_switch

      expect { provider_for.complete_authorization_flow('code-a', 'state-a') }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed/i)
    end

    it 'leaves the token of the authorization server now in use in storage' do
      exchange_answers_after_the_switch

      begin
        provider_for.complete_authorization_flow('code-a', 'state-a')
      rescue MCPClient::Errors::ConnectionError
        nil
      end

      expect(storage.get_token(server_url).access_token).to eq('token-b')
    end

    it 'leaves the pending authorization request of the new server intact' do
      exchange_answers_after_the_switch

      begin
        provider_for.complete_authorization_flow('code-a', 'state-a')
      rescue MCPClient::Errors::ConnectionError
        nil
      end

      expect(storage.get_state(server_url)).to eq('state-b')
      expect(storage.get_pkce(server_url)&.issuer).to eq(issuer_b)
    end
  end

  # ------------------------------------------------------------- finding 3
  describe 'a client secret rotated in the slot a host writes to' do
    def basic_credentials(request)
      Base64.decode64(request.headers['Authorization'].to_s.sub(/\ABasic /, ''))
    end

    it 'refreshes with the rotated secret, not the copy kept for that server' do
      provider = provider_for
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(provider.client_registration_key(issuer_a),
                              client_info('client', issuer_a, secret: 'old-secret',
                                                              auth_method: 'client_secret_basic'))
      storage.set_client_info(server_url,
                              client_info('client', issuer_a, secret: 'rotated-secret',
                                                              auth_method: 'client_secret_basic'))
      storage.set_token(server_url, token_for(issuer_a, 'token-a', refresh: 'refresh-a', expires_in: 60))
      sent = nil
      stub_request(:post, "#{issuer_a}/token").to_return do |request|
        sent = basic_credentials(request)
        { status: 200, headers: json,
          body: { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json }
      end

      expect(provider.access_token&.access_token).to eq('fresh')
      expect(sent).to eq('client:rotated-secret')
    end
  end

  # ------------------------------------------------------------- finding 4
  describe 'pre-registered credentials alongside a Client ID Metadata Document id' do
    let(:metadata_url) { 'https://app.example.com/client.json' }

    it 'prefers the credentials pre-registered with the authorization server in use' do
      provider = provider_for(storage, client_id_metadata_url: metadata_url)
      storage.set_server_metadata(server_url, server_metadata(issuer_b, cimd: true))
      storage.set_client_info(server_url, client_info(metadata_url, nil, type: 'cimd'))
      storage.set_client_info(provider.client_registration_key(issuer_b),
                              client_info('pre-registered-b', issuer_b))

      expect(provider.start_authorization_flow).to include('client_id=pre-registered-b')
    end

    it 'still uses the metadata document id when that server has no pre-registered credentials' do
      provider = provider_for(storage, client_id_metadata_url: metadata_url)
      storage.set_server_metadata(server_url, server_metadata(issuer_b, cimd: true))
      storage.set_client_info(server_url, client_info(metadata_url, nil, type: 'cimd'))

      expect(provider.start_authorization_flow).to include("client_id=#{CGI.escape(metadata_url)}")
    end
  end

  # ------------------------------------------------------------- finding 5
  describe 'a storage backend that cannot persist the registration a flow needs' do
    let(:refusing_storage) do
      Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        attr_accessor :refuse_key

        def set_client_info(key, client_info)
          raise IOError, 'no room' if key == @refuse_key

          super
        end
      end.new
    end

    before do
      refusing_storage.set_server_metadata(server_url, server_metadata(issuer_a,
                                                                       registration: "#{issuer_a}/register"))
      stub_request(:post, "#{issuer_a}/register")
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-a', 'redirect_uris' => [redirect_uri] }.to_json)
    end

    it 'reports the failure instead of returning a URL the callback cannot complete' do
      refusing_storage.refuse_key = server_url

      expect { provider_for(refusing_storage).start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /registration/i)
    end

    it 'still completes when only the optional per-authorization-server copy cannot be written' do
      provider = provider_for(refusing_storage)
      refusing_storage.refuse_key = provider.client_registration_key(issuer_a)
      stub_request(:post, "#{issuer_a}/token")
        .with(body: hash_including('client_id' => 'dyn-a'))
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json)

      url = provider.start_authorization_flow
      expect(url).to include('client_id=dyn-a')
      state = URI.decode_www_form(URI.parse(url).query).to_h['state']

      expect(provider.complete_authorization_flow('code', state).access_token).to eq('fresh')
      expect(refusing_storage.get_token(server_url).access_token).to eq('fresh')
      request = Faraday::Request.new
      request.headers = {}
      provider.apply_authorization(request)
      expect(request.headers['Authorization']).to eq('Bearer fresh')
    end
  end

  # ------------------------------------------------------------- finding 6
  describe 'a step-up challenge that names only the scope one operation needs' do
    before do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => server_url, 'authorization_servers' => [issuer_a],
                'scopes_supported' => ['files:read'] }.to_json
      )
      stub_request(:get, "#{issuer_a}/.well-known/oauth-authorization-server").to_return(
        status: 200, headers: json,
        body: { 'issuer' => issuer_a, 'authorization_endpoint' => "#{issuer_a}/authorize",
                'token_endpoint' => "#{issuer_a}/token",
                'code_challenge_methods_supported' => ['S256'] }.to_json
      )
    end

    it 'asks for the union of the scopes already requested and the ones the challenge names' do
      provider = provider_for
      expect(scope_in(provider.start_authorization_flow)).to eq('files:read')

      provider.handle_unauthorized_response(
        instance_double(Faraday::Response,
                        headers: { 'WWW-Authenticate' => 'Bearer error="insufficient_scope", ' \
                                                         "resource_metadata=\"#{prm_url}\", scope=\"files:write\"" })
      )

      expect(scope_in(provider.start_authorization_flow).split).to contain_exactly('files:read', 'files:write')
    end
  end

  # ------------------------------------- retained conformance gap: token_type
  describe 'a token response that names no token type' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
    end

    it 'fails the code exchange rather than guessing the credential is a bearer token' do
      storage.set_state(server_url, 'state-a')
      storage.set_pkce(server_url, MCPClient::Auth::PKCE.from_h(
                                     'code_verifier' => 'v', 'code_challenge' => 'c', 'issuer' => issuer_a,
                                     'iss_parameter_supported' => false, 'client_id' => 'client-a',
                                     'redirect_uri' => redirect_uri, 'state' => 'state-a'
                                   ))
      stub_request(:post, "#{issuer_a}/token")
        .to_return(status: 200, headers: json, body: { 'access_token' => 'untyped' }.to_json)

      expect { provider_for.complete_authorization_flow('code-a', 'state-a') }
        .to raise_error(MCPClient::Errors::ConnectionError, /token_type/)
    end

    it 'keeps the still-valid token when a refresh response omits the type' do
      storage.set_token(server_url, token_for(issuer_a, 'token-a', refresh: 'refresh-a', expires_in: 60))
      stub_request(:post, "#{issuer_a}/token")
        .to_return(status: 200, headers: json, body: { 'access_token' => 'untyped' }.to_json)

      expect(provider_for.access_token&.access_token).to eq('token-a')
      expect(storage.get_token(server_url).access_token).to eq('token-a')
    end

    it 'refuses a null type exactly as an absent one' do
      storage.set_token(server_url, token_for(issuer_a, 'token-a', refresh: 'refresh-a', expires_in: 60))
      stub_request(:post, "#{issuer_a}/token")
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'untyped', 'token_type' => nil }.to_json)

      expect(provider_for.access_token&.access_token).to eq('token-a')
      expect(storage.get_token(server_url).access_token).to eq('token-a')
    end
  end

  # -------------------------------- retained conformance gap: redirect URIs
  describe 'a redirect URI that is neither localhost nor HTTPS' do
    it 'refuses to be configured with one' do
      expect { provider_for(storage, redirect_uri: 'http://app.example.com/callback') }
        .to raise_error(ArgumentError, /localhost|HTTPS/i)
    end

    it 'accepts a hosted HTTPS callback' do
      expect { provider_for(storage, redirect_uri: 'https://app.example.com/callback') }.not_to raise_error
    end

    it 'refuses a registration response that registers one' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a, registration: "#{issuer_a}/register"))
      stub_request(:post, "#{issuer_a}/register")
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-a',
                           'redirect_uris' => ['http://app.example.com/callback'] }.to_json)

      expect { provider_for.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /redirect/i)
    end
  end

  # ------------------------------------------- coverage: surviving mutations
  #
  # Replacing the pending-client issuer equality check with "any non-null
  # issuer" left the whole suite green, because every example that changed the
  # authorization server also changed the client id — which the preceding
  # check catches on its own.
  describe 'credentials swapped for another server\'s under the same client id' do
    it 'refuses to redeem the code with them' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_state(server_url, 'state-a')
      storage.set_pkce(server_url, MCPClient::Auth::PKCE.from_h(
                                     'code_verifier' => 'v', 'code_challenge' => 'c', 'issuer' => issuer_a,
                                     'iss_parameter_supported' => false, 'client_id' => 'shared-id',
                                     'redirect_uri' => redirect_uri, 'state' => 'state-a'
                                   ))
      # Same client id, another authorization server: only the issuer check
      # can tell these apart from the credentials the request was made with.
      storage.set_client_info(server_url, client_info('shared-id', issuer_b))
      at_a = stub_request(:post, "#{issuer_a}/token")

      expect { provider_for.complete_authorization_flow('code-a', 'state-a') }
        .to raise_error(MCPClient::Errors::ConnectionError, /credentials changed/)
      expect(at_a).not_to have_been_requested
    end
  end

  # A storage backend that implements the optional `delete_token` hook takes
  # the other branch of every retirement, and no backend in the suite did:
  # `MemoryStorage` has no `delete_token`, so every example exercised the
  # `set_token(url, nil)` fallback.
  describe 'a storage backend that can delete a token' do
    let(:deleting_storage) do
      Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        attr_accessor :deletions, :refuse_delete

        def delete_token(key)
          (@deletions ||= []) << key
          raise IOError, 'read-only' if @refuse_delete

          set_token(key, nil)
        end
      end.new
    end

    # A 401 challenge naming another authorization server retires the token
    # of the previous one.
    def challenge_to_b(provider)
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [issuer_b] }.to_json)
      provider.handle_unauthorized_response(
        instance_double(Faraday::Response,
                        headers: { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" })
      )
    end

    before do
      deleting_storage.set_server_metadata(server_url, server_metadata(issuer_a))
      deleting_storage.set_token(server_url, token_for(issuer_a, 'token-a'))
    end

    it 'deletes the record through the backend rather than writing a nil over it' do
      provider = provider_for(deleting_storage)

      challenge_to_b(provider)

      # A RETIRED token is removed wherever it is kept: the slot in use and
      # the copy under its own authorization server's key, which a later
      # return to that server would otherwise hand back.
      expect(deleting_storage.deletions)
        .to eq([provider.client_registration_key(issuer_a), server_url])
      expect(deleting_storage.get_token(server_url)).to be_nil
      expect(deleting_storage.get_token(provider.client_registration_key(issuer_a))).to be_nil
    end

    it 'presents nothing once the record is gone' do
      provider = provider_for(deleting_storage)

      challenge_to_b(provider)

      expect(provider.access_token).to be_nil
    end

    # A backend that refuses the delete keeps the bytes; the retirement marker
    # this process holds is gone with the process, so the record left behind
    # has to say for itself that it must not be presented again.
    it 'refuses to present a record a failed deletion left behind, even after a restart' do
      provider = provider_for(deleting_storage)
      deleting_storage.refuse_delete = true

      challenge_to_b(provider)

      expect(deleting_storage.get_token(server_url)&.access_token).to eq('token-a')
      expect(provider_for(deleting_storage).access_token).to be_nil
    end

    # A retired record is not "another authorization server's token" the
    # freshly issued one must not displace — it is what the failed deletion
    # left behind. Authorizing at the new server has to be able to store its
    # token over it, or the failed delete would lock the client out.
    it 'stores the token of a new authorization server over a retired record' do
      provider = provider_for(deleting_storage)
      deleting_storage.refuse_delete = true
      challenge_to_b(provider)
      stub_request(:get, "#{issuer_b}/.well-known/oauth-authorization-server").to_return(
        status: 200, headers: json,
        body: { 'issuer' => issuer_b, 'authorization_endpoint' => "#{issuer_b}/authorize",
                'token_endpoint' => "#{issuer_b}/token",
                'code_challenge_methods_supported' => ['S256'] }.to_json
      )
      deleting_storage.set_client_info(server_url, client_info('client-b', issuer_b))
      deleting_storage.set_state(server_url, 'state-b')
      deleting_storage.set_pkce(server_url, MCPClient::Auth::PKCE.from_h(
                                              'code_verifier' => 'v', 'code_challenge' => 'c',
                                              'issuer' => issuer_b, 'iss_parameter_supported' => false,
                                              'client_id' => 'client-b', 'redirect_uri' => redirect_uri,
                                              'state' => 'state-b'
                                            ))
      stub_request(:post, "#{issuer_b}/token")
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'token-b', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json)

      expect(provider.complete_authorization_flow('code-b', 'state-b').access_token).to eq('token-b')
      expect(deleting_storage.get_token(server_url).access_token).to eq('token-b')
    end
  end

  # The `client_secret_post` branch of client authentication had no wire-level
  # example on the refresh path: the secret must be in the body, and the Basic
  # header of the other branch must not be sent alongside it.
  describe 'a refresh by a client registered for client_secret_post' do
    it 'sends the secret in the request body and no Basic authentication' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url,
                              client_info('client-a', issuer_a, secret: 'the-secret',
                                                                auth_method: 'client_secret_post'))
      storage.set_token(server_url, token_for(issuer_a, 'token-a', refresh: 'refresh-a', expires_in: 60))
      body = nil
      authorization = :unset
      stub_request(:post, "#{issuer_a}/token").to_return do |request|
        body = URI.decode_www_form(request.body).to_h
        authorization = request.headers['Authorization']
        { status: 200, headers: json,
          body: { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json }
      end

      expect(provider_for.access_token&.access_token).to eq('fresh')
      expect(body).to include('client_secret' => 'the-secret', 'client_id' => 'client-a',
                              'grant_type' => 'refresh_token', 'refresh_token' => 'refresh-a')
      expect(authorization).to be_nil
    end
  end

  # An expired client secret is not a usable registration, whichever key it
  # sits under; a `client_secret_expires_at` of 0 means "never expires"
  # (RFC 7591 Section 3.2.1), so it is not one that expired at the epoch.
  describe 'a registration whose secret expired' do
    def confidential(id, expires_at)
      MCPClient::Auth::ClientInfo.new(
        client_id: id, issuer: issuer_a, registration_type: 'dynamic', client_secret: 's',
        client_secret_expires_at: expires_at,
        metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri],
                                                      token_endpoint_auth_method: 'client_secret_basic')
      )
    end

    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a, registration: "#{issuer_a}/register"))
      stub_request(:post, "#{issuer_a}/register")
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'dyn-fresh', 'redirect_uris' => [redirect_uri] }.to_json)
    end

    it 'registers again rather than reusing the expired copy kept for that server' do
      provider = provider_for
      storage.set_client_info(provider.client_registration_key(issuer_a), confidential('expired', 1))

      expect(provider.start_authorization_flow).to include('client_id=dyn-fresh')
    end

    it 'reuses a registration whose secret is recorded as never expiring' do
      provider = provider_for
      storage.set_client_info(server_url, confidential('eternal', 0))
      registration = stub_request(:post, "#{issuer_a}/register")

      expect(provider.start_authorization_flow).to include('client_id=eternal')
      expect(registration).not_to have_been_requested
    end
  end

  # Removing `refresh_token` from the registration request's grant_types left
  # the suite green: nothing asserted what the client actually asked for.
  describe 'the dynamic client registration request' do
    it 'asks for the grants this client uses, refresh_token included' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a, registration: "#{issuer_a}/register"))
      registered = stub_request(:post, "#{issuer_a}/register")
                   .to_return(status: 201, headers: json,
                              body: { 'client_id' => 'dyn-a', 'redirect_uris' => [redirect_uri] }.to_json)

      provider_for.start_authorization_flow

      expect(registered).to have_been_requested
      body = JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.body)
      expect(body['grant_types']).to contain_exactly('authorization_code', 'refresh_token')
      expect(body['response_types']).to eq(['code'])
    end
  end
end

# --- round38 ---------------------------------------------------------------

# MCP 2026-07-28 authorization — round 38.
#
# "Authorization Server Binding" keys credentials by the authorization server
# that ISSUED them. This client bound credentials that named none to whichever
# server discovery returned first, which is not the same thing: a resource
# that starts advertising another authorization server relabelled the host's
# pre-registered credentials as belonging to it, and the code exchange then
# posted a client secret registered with one server to a different one. First
# discovery does not establish provenance; the host does.
#
# The same section keeps registration state — "client credentials, tokens" —
# per authorization server. Client credentials were already kept per server;
# tokens were not, so a resource served by two authorization servers over its
# lifetime threw away a grant that was never revoked and sent the user
# through consent again on the way back. They are now kept the same way, with
# a token this client RETIRED still retired wherever it is kept.
#
# The rest are checks made about the wrong request or the wrong record: an
# error callback validated against another flow's per-request record; a
# step-up that asked only for the challenge's scope once the process
# restarted, and that carried one authorization server's scopes into
# another's request; a dynamic registration answering ahead of — and
# overwriting — credentials the host configured for the very server in use;
# and an authorization endpoint's own query producing a second `scope` or
# `state` in the authorization URL (RFC 6749 Section 3.1).
RSpec.describe 'MCP 2026-07-28 authorization — round 38' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer_a) { 'https://as-a.example.com' }
  let(:issuer_b) { 'https://as-b.example.com' }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage, **options)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store, **options)
  end

  def server_metadata(iss, registration: nil, iss_supported: false, scopes: nil)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      registration_endpoint: registration, code_challenge_methods_supported: ['S256'],
      scopes_supported: scopes, authorization_response_iss_parameter_supported: iss_supported
    )
  end

  def client_info(id, iss, type: 'pre_registered', secret: nil, auth_method: 'none')
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: type, client_secret: secret,
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri],
                                                    token_endpoint_auth_method: auth_method)
    )
  end

  def token_for(iss, access_token, refresh: nil, expires_in: 3600, scope: nil)
    MCPClient::Auth::Token.new(access_token: access_token, expires_in: expires_in, scope: scope,
                               refresh_token: refresh, issuer: iss)
  end

  def query_of(url)
    URI.decode_www_form(URI.parse(url).query)
  end

  def param_in(url, name)
    query_of(url).to_h[name]
  end

  # Discovery over the wire, so nothing about the flow is stubbed away.
  def stub_discovery(issuer, iss_supported: false, scopes: nil, registration: nil, prm_scopes: nil)
    stub_request(:get, prm_url).to_return(
      status: 200, headers: json,
      body: { 'resource' => server_url, 'authorization_servers' => [issuer],
              'scopes_supported' => prm_scopes }.compact.to_json
    )
    document = { 'issuer' => issuer, 'authorization_endpoint' => "#{issuer}/authorize",
                 'token_endpoint' => "#{issuer}/token", 'code_challenge_methods_supported' => ['S256'],
                 'registration_endpoint' => registration, 'scopes_supported' => scopes }.compact
    document['authorization_response_iss_parameter_supported'] = true if iss_supported
    stub_request(:get, "#{issuer}/.well-known/oauth-authorization-server")
      .to_return(status: 200, headers: json, body: document.to_json)
  end

  def stub_token(issuer, access_token: 'tok', scope: nil, refresh: nil)
    stub_request(:post, "#{issuer}/token").to_return(
      status: 200, headers: json,
      body: { 'access_token' => access_token, 'token_type' => 'Bearer', 'expires_in' => 3600,
              'scope' => scope, 'refresh_token' => refresh }.compact.to_json
    )
  end

  # ------------------------------------------------------------- finding 1
  #
  # The P1: credentials the host configured with one authorization server,
  # in the supported issuerless form, and a resource that now advertises
  # another one.
  describe 'pre-registered credentials that name no authorization server' do
    let(:unbound_static) do
      MCPClient::Auth::ClientInfo.new(
        client_id: 'static-for-a', client_secret: 'secret-of-a', registration_type: 'pre_registered',
        metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri],
                                                      token_endpoint_auth_method: 'client_secret_post')
      )
    end

    before { storage.set_client_info(server_url, unbound_static) }

    it 'never sends their secret to the authorization server discovery happened to find' do
      stub_discovery(issuer_b)
      token_endpoint = stub_token(issuer_b)
      provider = provider_for

      expect { provider.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /record no authorization server/)
      expect(token_endpoint).not_to have_been_requested
      # Nothing was relabelled: the record still names no authorization
      # server, so the host's own configuration is intact.
      expect(storage.get_client_info(server_url).issuer).to be_nil
      expect(storage.get_client_info(provider.client_registration_key(issuer_b))).to be_nil
    end

    it 'says how to name the authorization server that issued them' do
      stub_discovery(issuer_b)

      expect { provider_for.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /client_registration_key/)
    end

    it 'uses them once the host says which authorization server they belong to' do
      stub_discovery(issuer_b)
      provider = provider_for
      storage.set_client_info(server_url, unbound_static.with_issuer(issuer_b))

      expect(param_in(provider.start_authorization_flow, 'client_id')).to eq('static-for-a')
    end

    it 'uses the copy the host seeded under the authorization server key instead' do
      stub_discovery(issuer_b)
      provider = provider_for
      storage.set_client_info(provider.client_registration_key(issuer_b),
                              client_info('static-for-b', issuer_b, secret: 'secret-of-b'))

      expect(param_in(provider.start_authorization_flow, 'client_id')).to eq('static-for-b')
    end

    it 'is not attributed to the authorization server merely cached alongside it either' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      stub_discovery(issuer_b)
      provider = provider_for

      expect { provider.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /record no authorization server/)
      expect(storage.get_client_info(provider.client_registration_key(issuer_a))).to be_nil
    end

    it 'is not presented on a refresh either' do
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_token(server_url, token_for(issuer_b, 'stale', refresh: 'r', expires_in: -1))
      refresh = stub_request(:post, "#{issuer_b}/token")

      expect(provider_for.access_token).to be_nil
      expect(refresh).not_to have_been_requested
    end
  end

  # ------------------------------------------------------------- finding 2
  #
  # Provider B runs a whole flow of its own in the window between provider
  # A's set_pkce and provider A's set_state, so storage pairs A's state with
  # B's per-request record. The error callback then carries A's state and B's
  # issuer, and passes an issuer check it was never subject to.
  describe 'an error callback that arrives on a torn per-request record' do
    let(:interleaving_storage) do
      Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        attr_accessor :between_pkce_and_state

        def set_pkce(key, pkce)
          super
          hook = @between_pkce_and_state
          @between_pkce_and_state = nil
          hook&.call
        end
      end.new
    end

    def start_a_interleaved_with_b
      interleaving_storage.set_server_metadata(server_url, server_metadata(issuer_a))
      interleaving_storage.set_client_info(server_url, client_info('client-a', issuer_a))
      provider_a = provider_for(interleaving_storage)
      provider_b = provider_for(interleaving_storage)
      interleaving_storage.set_client_info(provider_b.client_registration_key(issuer_b),
                                           client_info('client-b', issuer_b))
      interleaving_storage.between_pkce_and_state = lambda {
        interleaving_storage.set_server_metadata(server_url, server_metadata(issuer_b))
        provider_b.start_authorization_flow
      }
      [provider_a, provider_a.start_authorization_flow]
    end

    it 'refuses to display it rather than checking it against the other request' do
      provider_a, url_a = start_a_interleaved_with_b

      expect do
        provider_a.authorization_error_message('error' => 'access_denied',
                                               'error_description' => 'The user said no at B',
                                               'iss' => issuer_b, 'state' => param_in(url_a, 'state'))
      end.to raise_error(MCPClient::Errors::ConnectionError) { |e|
        expect(e.message).to match(/not the one this response answers/)
        expect(e.message).not_to include('The user said no at B')
      }
    end

    it 'still displays an error response that answers the pending request' do
      interleaving_storage.set_server_metadata(server_url, server_metadata(issuer_a))
      interleaving_storage.set_client_info(server_url, client_info('client-a', issuer_a))
      provider = provider_for(interleaving_storage)
      url = provider.start_authorization_flow

      expect(provider.authorization_error_message('error' => 'access_denied',
                                                  'error_description' => 'The user said no',
                                                  'iss' => issuer_a, 'state' => param_in(url, 'state')))
        .to eq('The user said no')
    end
  end

  # ------------------------------------------------------------- finding 3
  describe 'the step-up scope union' do
    it 'keeps what the authorization server already granted after the provider is rebuilt' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      storage.set_token(server_url, token_for(issuer_a, 'granted', scope: 'files:read'))

      # A brand new provider: the in-process record of what was requested is
      # gone, and only the token says what this client already had.
      provider = provider_for(scope: 'files:read')
      provider.instance_variable_set(:@challenge_scope, 'files:write')

      expect(param_in(provider.start_authorization_flow, 'scope').split)
        .to contain_exactly('files:read', 'files:write')
    end

    # The step-up union preserves PREVIOUSLY REQUESTED permissions. A client
    # that has asked for nothing and holds no grant has none: the challenge
    # decides the first authorization alone, and the configured scope joins
    # the union only from the request after it (see round 42).
    it 'keeps the configured scope once it has actually been requested' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      provider = provider_for(scope: 'files:read')
      provider.instance_variable_set(:@challenge_scope, 'files:write')

      expect(param_in(provider.start_authorization_flow, 'scope').split)
        .to contain_exactly('files:write')

      provider.instance_variable_set(:@challenge_scope, 'mail:send')

      expect(param_in(provider.start_authorization_flow, 'scope').split)
        .to contain_exactly('files:read', 'files:write', 'mail:send')
    end

    it 'does not carry one authorization server scopes into another server request' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a, prm_scopes: ['files:read'])
      provider = provider_for
      expect(param_in(provider.start_authorization_flow, 'scope')).to eq('files:read')

      # A 401 moves the resource to B, which supports another scope entirely.
      WebMock.reset!
      storage.set_client_info(provider.client_registration_key(issuer_b), client_info('client-b', issuer_b))
      stub_discovery(issuer_b, prm_scopes: ['mail:send'])
      provider.handle_unauthorized_response(
        instance_double(Faraday::Response,
                        headers: { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" })
      )

      expect(param_in(provider.start_authorization_flow, 'scope')).to eq('mail:send')
    end

    it 'does not offer another authorization server granted scopes either' do
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_client_info(server_url, client_info('client-b', issuer_b))
      # A token of A left in the slot: B never granted its scope.
      storage.set_token(server_url, token_for(issuer_a, 'a-token', scope: 'files:read'))
      provider = provider_for(scope: 'mail:send')

      expect(param_in(provider.start_authorization_flow, 'scope')).to eq('mail:send')
    end
  end

  # ------------------------------------------------------------- finding 4
  describe 'a dynamic registration in the slot and pre-registered credentials for the same server' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('dyn-a', issuer_a, type: 'dynamic'))
    end

    it 'authorizes with the credentials the host configured, not the one this client registered' do
      provider = provider_for
      storage.set_client_info(provider.client_registration_key(issuer_a),
                              client_info('static-a', issuer_a, secret: 'shh'))

      expect(param_in(provider.start_authorization_flow, 'client_id')).to eq('static-a')
    end

    it 'does not overwrite the configured credentials with its own registration' do
      provider = provider_for
      key = provider.client_registration_key(issuer_a)
      storage.set_client_info(key, client_info('static-a', issuer_a, secret: 'shh'))

      provider.start_authorization_flow

      expect(storage.get_client_info(key).client_id).to eq('static-a')
      expect(storage.get_client_info(key).client_secret).to eq('shh')
    end

    it 'still lets the host rotate the credentials in the slot it writes to' do
      provider = provider_for
      key = provider.client_registration_key(issuer_a)
      storage.set_client_info(key, client_info('static-a', issuer_a, secret: 'old'))
      storage.set_client_info(server_url, client_info('static-a', issuer_a, secret: 'new'))

      expect(param_in(provider.start_authorization_flow, 'client_id')).to eq('static-a')
      expect(storage.get_client_info(key).client_secret).to eq('new')
    end
  end

  # ------------------------------------------------------------- finding 5
  describe 'an authorization endpoint whose query already names an OAuth parameter' do
    before do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      storage.set_server_metadata(
        server_url,
        MCPClient::Auth::ServerMetadata.new(
          issuer: issuer_a, token_endpoint: "#{issuer_a}/token",
          authorization_endpoint: "#{issuer_a}/authorize?tenant=acme&scope=openid&state=theirs",
          code_challenge_methods_supported: ['S256']
        )
      )
    end

    it 'sends each authorization request parameter exactly once' do
      url = provider_for(scope: 'files:read').start_authorization_flow
      names = query_of(url).map(&:first)

      expect(names).to eq(names.uniq)
      expect(query_of(url).filter_map { |name, value| value if name == 'scope' }).to eq(['files:read'])
      expect(query_of(url).count { |name, _| name == 'state' }).to eq(1)
    end

    it 'retains the endpoint parameters this request does not set' do
      url = provider_for(scope: 'files:read').start_authorization_flow

      expect(param_in(url, 'tenant')).to eq('acme')
      expect(url).to start_with("#{issuer_a}/authorize?tenant=acme&")
    end

    it 'keeps a plain endpoint query untouched' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      url = provider_for.start_authorization_flow

      expect(url).to start_with("#{issuer_a}/authorize?response_type=code")
      expect(url).not_to include('?&')
    end
  end

  # ------------------------------------------- the wire, pinned by its bytes
  #
  # Five production mutations passed the whole suite before this round: the
  # RFC 8707 `resource` parameter removed from all three requests, an
  # unrelated PKCE verifier transmitted, the recorded `iss` advertisement
  # replaced by the current metadata's, both cleanup guards removed, and the
  # retirement marker never cleared. Each of them is a body or a decision no
  # stub stands in for, so each is asserted here.
  describe 'what actually goes on the wire' do
    def bodies_of(issuer)
      posts = []
      stub_request(:post, "#{issuer}/token").to_return do |request|
        posts << URI.decode_www_form(request.body).to_h
        { status: 200, headers: json,
          body: { 'access_token' => 'tok', 'token_type' => 'Bearer', 'expires_in' => 3600,
                  'refresh_token' => 'r' }.to_json }
      end
      posts
    end

    it 'names the MCP server as the resource of the authorization request (RFC 8707)' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a)

      expect(param_in(provider_for.start_authorization_flow, 'resource')).to eq(server_url)
    end

    it 'names it again in the code exchange and in the refresh' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a)
      posts = bodies_of(issuer_a)
      provider = provider_for
      url = provider.start_authorization_flow

      token = provider.complete_authorization_flow('code', param_in(url, 'state'))
      provider.send(:refresh_token, token)

      expect(posts.length).to eq(2)
      expect(posts.map { |body| body['resource'] }).to eq([server_url, server_url])
      expect(posts.map { |body| body['grant_type'] }).to eq(%w[authorization_code refresh_token])
    end

    it 'sends the verifier of the challenge the browser was sent to' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a)
      posts = bodies_of(issuer_a)
      provider = provider_for
      url = provider.start_authorization_flow

      provider.complete_authorization_flow('code', param_in(url, 'state'))

      verifier = posts.first['code_verifier']
      expect(verifier).to be_a(String)
      expect(Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false))
        .to eq(param_in(url, 'code_challenge'))
      expect(param_in(url, 'code_challenge_method')).to eq('S256')
    end
  end

  # The advertisement recorded WITH THE REQUEST decides, not whatever the
  # metadata says by the time the callback arrives — with the authorization
  # server unchanged, so nothing else can account for the outcome.
  describe 'an iss advertisement that changed while the user was consenting' do
    before { storage.set_client_info(server_url, client_info('client-a', issuer_a)) }

    def start_then_change_advertisement_to(provider, advertised)
      url = provider.start_authorization_flow
      WebMock.reset!
      stub_discovery(issuer_a, iss_supported: advertised)
      storage.set_server_metadata(server_url, server_metadata(issuer_a, iss_supported: advertised))
      url
    end

    it 'still requires iss when the request recorded that it was advertised' do
      stub_discovery(issuer_a, iss_supported: true)
      provider = provider_for
      url = start_then_change_advertisement_to(provider, false)
      token_endpoint = stub_token(issuer_a)

      expect { provider.complete_authorization_flow('code', param_in(url, 'state')) }
        .to raise_error(MCPClient::Errors::ConnectionError, /advertises the iss parameter/)
      expect(token_endpoint).not_to have_been_requested
    end

    it 'does not start requiring it for a request that recorded it was not' do
      stub_discovery(issuer_a, iss_supported: false)
      provider = provider_for
      url = start_then_change_advertisement_to(provider, true)
      stub_token(issuer_a, access_token: 'fresh')

      expect(provider.complete_authorization_flow('code', param_in(url, 'state')).access_token).to eq('fresh')
    end
  end

  # A code exchange is two events with a gap between them: a flow started in
  # that gap, at the SAME authorization server, keeps the records it waits on.
  describe 'a completion that lands while a newer flow of the same server is pending' do
    # The second flow starts in the window between the token being written
    # and this request's records being cleaned up — all of it production
    # code, on one storage backend.
    let(:interleaving_storage) do
      Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        attr_accessor :on_set_token

        def set_token(key, token)
          super
          hook = @on_set_token
          @on_set_token = nil
          hook&.call
        end
      end.new
    end

    it 'leaves the newer request PKCE record and state alone' do
      interleaving_storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a)
      stub_token(issuer_a, access_token: 'first')
      provider = provider_for(interleaving_storage)
      first = provider.start_authorization_flow
      second = nil
      interleaving_storage.on_set_token = lambda {
        second = provider_for(interleaving_storage).start_authorization_flow
      }

      token = provider.complete_authorization_flow('code', param_in(first, 'state'))

      expect(token.access_token).to eq('first')
      expect(second).not_to be_nil
      expect(interleaving_storage.get_state(server_url)).to eq(param_in(second, 'state'))
      expect(interleaving_storage.get_pkce(server_url).code_challenge).to eq(param_in(second, 'code_challenge'))
    end

    it 'clears its own records when nothing newer is pending' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a)
      stub_token(issuer_a, access_token: 'only')
      provider = provider_for
      url = provider.start_authorization_flow

      provider.complete_authorization_flow('code', param_in(url, 'state'))

      expect(storage.get_state(server_url)).to be_nil
      expect(storage.get_pkce(server_url)).to be_nil
    end
  end

  # Opaque bytes are unique only within an issuer, and a token this client
  # retired can be issued again by the very server that issued it before.
  describe 'a replacement token that happens to carry the retired bytes' do
    it 'is presented once it has actually been stored' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      storage.set_token(server_url, token_for(issuer_a, 'recycled'))
      provider = provider_for
      # An unresolved challenge retires the stored bytes for issuer A.
      provider.send(:delete_token, bind_to: issuer_a)
      expect(provider.access_token).to be_nil

      stub_discovery(issuer_a)
      stub_token(issuer_a, access_token: 'recycled')
      url = provider.start_authorization_flow
      provider.complete_authorization_flow('code', param_in(url, 'state'))

      expect(provider.access_token&.access_token).to eq('recycled')
      request = Faraday::Request.create(:get) { |req| req.headers = {} }
      provider.apply_authorization(request)
      expect(request.headers['Authorization']).to eq('Bearer recycled')
    end
  end

  # ------------------------------------------------------- Grok, high: tokens
  #
  # "Clients MUST maintain separate registration state (client credentials,
  # tokens) per authorization server." The literal reading is adopted: a
  # token is kept under its own authorization server's key too, so coming
  # back to a server does not mean consenting again.
  describe 'a resource that goes back to an authorization server it used before' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      storage.set_token(server_url, token_for(issuer_a, 'token-a'))
    end

    # The resource advertises B; discovery learns it and the flow moves.
    def switch_to(provider, issuer)
      stub_discovery(issuer)
      provider.send(:discover_and_cache_authorization_server)
    end

    it 'keeps the token of each authorization server under its own key' do
      provider = provider_for
      switch_to(provider, issuer_b)

      expect(storage.get_token(server_url)).to be_nil
      expect(storage.get_token(provider.client_registration_key(issuer_a)).access_token).to eq('token-a')
    end

    it 'presents the token again when that server is the one in use again' do
      provider = provider_for
      switch_to(provider, issuer_b)
      expect(provider.access_token).to be_nil

      WebMock.reset!
      switch_to(provider, issuer_a)

      expect(provider.access_token&.access_token).to eq('token-a')
      expect(storage.get_token(server_url).access_token).to eq('token-a')
    end

    it 'never presents it at the other authorization server' do
      provider = provider_for
      switch_to(provider, issuer_b)
      # Even asked directly for B's key, A's token is not B's.
      expect(storage.get_token(provider.client_registration_key(issuer_b))).to be_nil
      expect(provider.access_token).to be_nil
    end

    it 'does not hand back a token this client retired' do
      provider = provider_for
      # Both copies a persisted token has: the slot in use and the one under
      # its own authorization server's key.
      storage.set_token(provider.client_registration_key(issuer_a), token_for(issuer_a, 'token-a'))
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => server_url, 'authorization_servers' => [issuer_b] }.to_json
      )
      # A 401 challenge naming another authorization server RETIRES the token.
      provider.handle_unauthorized_response(
        instance_double(Faraday::Response,
                        headers: { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" })
      )

      expect(storage.get_token(provider.client_registration_key(issuer_a))).to be_nil
      expect(provider.access_token).to be_nil

      # And durably: a provider built afterwards, whose in-process retirement
      # markers are empty, finds the token nowhere either.
      WebMock.reset!
      fresh = provider_for
      switch_to(fresh, issuer_a)
      expect(fresh.access_token).to be_nil
    end

    it 'keeps a token issued now under its authorization server key as well' do
      stub_discovery(issuer_a)
      stub_token(issuer_a, access_token: 'fresh')
      provider = provider_for
      url = provider.start_authorization_flow

      provider.complete_authorization_flow('code', param_in(url, 'state'))

      expect(storage.get_token(provider.client_registration_key(issuer_a)).access_token).to eq('fresh')
    end
  end
  # ----------------------------------------- the 2025-11-25 servers still
  #
  # Authorization is transport-level, so these checks run whatever protocol
  # version `initialize` negotiates. An authorization server that predates
  # RFC 9207 advertises nothing and sends no `iss`; a host that predates it
  # calls the two-argument completion. Both keep working — over real
  # discovery, with the token actually presented afterwards — and the same
  # host fails closed against a server that DOES advertise the parameter.
  describe 'an authorization server that never heard of the iss parameter' do
    it 'completes the two-argument flow and presents the token it issued' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a)
      stub_token(issuer_a, access_token: 'legacy-token')
      provider = provider_for
      url = provider.start_authorization_flow

      # The callback of such a server carries code and state, and no iss.
      token = provider.complete_authorization_flow('code', param_in(url, 'state'))

      expect(token.access_token).to eq('legacy-token')
      expect(storage.get_server_metadata(server_url)).not_to be_iss_parameter_supported
      expect(storage.get_server_metadata(server_url)).to be_iss_parameter_recorded
      request = Faraday::Request.create(:get) { |req| req.headers = {} }
      provider.apply_authorization(request)
      expect(request.headers['Authorization']).to eq('Bearer legacy-token')
    end
  end

  describe MCPClient::OAuthClient do
    def oauth_server
      described_class.create_streamable_http_server(server_url: server_url, redirect_uri: redirect_uri,
                                                    storage: storage, logger: logger)
    end

    it 'completes a two-argument flow against a server that advertises no iss' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a)
      stub_token(issuer_a, access_token: 'legacy-token')
      server = oauth_server
      url = described_class.start_oauth_flow(server)

      expect(described_class.complete_oauth_flow(server, 'code', param_in(url, 'state')).access_token)
        .to eq('legacy-token')
    end

    # The upgrade trap: the same host code against a 2026 authorization
    # server. The `iss` it never forwards is the one the server advertises,
    # so the code is not redeemed at all.
    it 'fails closed for a host that does not forward iss to a server that advertises it' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a, iss_supported: true)
      token_endpoint = stub_token(issuer_a)
      server = oauth_server
      url = described_class.start_oauth_flow(server)

      expect { described_class.complete_oauth_flow(server, 'code', param_in(url, 'state')) }
        .to raise_error(MCPClient::Errors::ConnectionError, /advertises the iss parameter/)
      expect(token_endpoint).not_to have_been_requested
    end

    it 'completes once the host forwards the iss the server sent' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a, iss_supported: true)
      stub_token(issuer_a, access_token: 'fresh')
      server = oauth_server
      url = described_class.start_oauth_flow(server)

      expect(described_class.complete_oauth_flow(server, 'code', param_in(url, 'state'), iss: issuer_a)
                            .access_token).to eq('fresh')
    end
  end

  # The browser callback, through a REAL provider: the success page is only
  # sent for a callback the provider accepted, and the code is redeemed.
  describe MCPClient::Auth::BrowserOAuth do
    def callback_socket(responses, query)
      socket = instance_double(TCPSocket)
      allow(socket).to receive(:setsockopt)
      allow(socket).to receive(:close)
      allow(socket).to receive(:print) { |data| responses << data }
      lines = ["GET /cb?#{query} HTTP/1.1\r\n", "\r\n", nil]
      allow(socket).to receive(:gets) { lines.shift }
      socket
    end

    def browser_for(provider, responses, &query)
      tcp_server = instance_double(TCPServer)
      allow(TCPServer).to receive(:new).and_return(tcp_server)
      allow(tcp_server).to receive(:wait_readable).and_return(tcp_server)
      allow(tcp_server).to receive(:close)
      allow(tcp_server).to receive(:accept) { callback_socket(responses, query.call) }
      described_class.new(provider, callback_port: 1, callback_path: '/cb', logger: logger)
    end

    it 'redeems the code and answers the browser for a callback whose iss matches' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a, iss_supported: true)
      token_endpoint = stub_token(issuer_a, access_token: 'browser-token')
      provider = provider_for
      responses = []
      browser = browser_for(provider, responses) do
        "code=abc&state=#{storage.get_state(server_url)}&iss=#{CGI.escape(issuer_a)}"
      end

      token = browser.authenticate(timeout: 1, auto_open_browser: false)

      expect(token.access_token).to eq('browser-token')
      expect(token_endpoint).to have_been_requested
      expect(responses.join).to include('HTTP/1.1 200')
    end

    it 'refuses the code of a callback whose iss names another authorization server' do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_discovery(issuer_a, iss_supported: true)
      token_endpoint = stub_token(issuer_a)
      provider = provider_for
      responses = []
      browser = browser_for(provider, responses) do
        "code=abc&state=#{storage.get_state(server_url)}&iss=#{CGI.escape(issuer_b)}"
      end

      expect { browser.authenticate(timeout: 1, auto_open_browser: false) }
        .to raise_error(MCPClient::Errors::ConnectionError, /issuer mismatch/)
      expect(token_endpoint).not_to have_been_requested
      expect(responses.join).to include('HTTP/1.1 400')
      expect(responses.join).not_to include('HTTP/1.1 200')
    end
  end
end

# --- round39 ---------------------------------------------------------------

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
    # The stored token belongs to the authorization server in use here; the
    # token of ANOTHER server, which must not be attached, is round 40's case.
    it 'attaches the stored token of the authorization server in use' do
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

# --- round40 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, fortieth review round: what two providers
# sharing one storage backend can do to each other's outstanding requests,
# and what a storage backend that cannot delete leaves behind.
#
# A refresh answered after ANOTHER provider retired the token being refreshed
# (a validated challenge moved the resource to a different authorization
# server) was accepted: the retirement is visible in shared storage — the
# token in use is gone — but the response-time check only asked whether the
# authorization server this provider knew was still the one it knew. A
# refresh response is kept only while the token it refreshed is still the
# token in use.
#
# A token retired outright is retired wherever it is kept. When the backend
# refuses to delete the copy under its own authorization server's key, that
# copy said nothing of the retirement and a provider built after a restart
# adopted it. The copy is now re-stored as retired when it cannot be deleted,
# exactly as the slot in use already was.
#
# The cleanup after a completed flow reads, compares and deletes the pending
# records; a flow started in between by another thread lost its records to
# that delete unless the backend answered the delete with the record it
# removed. Both ends of that window — the pending-record writes of a starting
# flow and the read-compare-delete — are now serialized in-process.
RSpec.describe 'MCP 2026-07-28 authorization — round 40' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer_a) { 'https://as-a.example.com' }
  let(:issuer_b) { 'https://as-b.example.com' }
  let(:issuer_c) { 'https://as-c.example.com' }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def server_metadata(iss, iss_supported: false)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      code_challenge_methods_supported: ['S256'], authorization_response_iss_parameter_supported: iss_supported
    )
  end

  def client_info(id, iss)
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: 'pre_registered',
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri], token_endpoint_auth_method: 'none')
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

  def challenge_headers(url)
    { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{url}\"" }
  end

  def prm_document(*issuers)
    { 'resource' => server_url, 'authorization_servers' => issuers }
  end

  def as_document(iss)
    server_metadata(iss).to_h.merge('registration_endpoint' => "#{iss}/register")
  end

  def param_in(url, name)
    URI.decode_www_form(URI.parse(url).query).to_h[name]
  end

  def seed_a(store = storage)
    store.set_server_metadata(server_url, server_metadata(issuer_a))
    store.set_client_info(server_url, client_info('client-a', issuer_a))
  end

  # A validated 401 challenge naming B, handled by `provider`.
  def challenge_to_b(provider)
    stub_request(:get, prm_url).to_return(status: 200, headers: json, body: prm_document(issuer_b).to_json)
    provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: challenge_headers(prm_url)))
  end

  # ------------------------------------------------ codex 1: shared storage

  describe 'a refresh answered after another provider retired the token being refreshed' do
    before do
      seed_a
      storage.set_token(server_url, token_for(issuer_a, 'token-a', refresh: 'refresh-a', expires_in: 60))
    end

    def refresh_answered_after(other_provider_acts)
      stub_request(:post, "#{issuer_a}/token").to_return do
        other_provider_acts.call
        { status: 200, headers: json,
          body: { 'access_token' => 'fresh-a', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json }
      end
    end

    it 'discards the response and presents nothing' do
      refresher = provider_for
      other = provider_for
      refresh_answered_after(-> { challenge_to_b(other) })

      expect(authorization_header_for(refresher)).to be_nil
      expect(storage.get_token(server_url)&.access_token).not_to eq('fresh-a')
      expect(log_output.string).to match(/no longer the token in use/i)
    end

    # The retirement is what shared storage shows; the same holds for any
    # other reason the token in use is gone or replaced meanwhile.
    it 'discards the response when the token in use was replaced meanwhile' do
      refresher = provider_for
      refresh_answered_after(-> { storage.set_token(server_url, token_for(issuer_a, 'token-a2')) })

      expect(authorization_header_for(refresher)).to eq('Bearer token-a2')
      expect(storage.get_token(server_url).access_token).to eq('token-a2')
    end

    it 'keeps the response while the token it refreshed is still the token in use' do
      refresher = provider_for
      refresh_answered_after(-> {})

      expect(authorization_header_for(refresher)).to eq('Bearer fresh-a')
      expect(storage.get_token(server_url).access_token).to eq('fresh-a')
    end
  end

  describe 'a code exchange answered after another provider moved the resource to another server' do
    it 'discards the token once the other provider recorded the new authorization server' do
      seed_a
      first = provider_for
      state = param_in(first.start_authorization_flow, 'state')
      stub_request(:post, "#{issuer_a}/token").to_return do
        other = provider_for
        challenge_to_b(other)
        stub_request(:get, "#{issuer_b}/.well-known/oauth-authorization-server")
          .to_return(status: 200, headers: json, body: as_document(issuer_b).to_json)
        other.send(:discover_and_cache_authorization_server)
        { status: 200, headers: json, body: { 'access_token' => 'exchanged-a', 'token_type' => 'Bearer' }.to_json }
      end

      expect { first.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed/)
      expect(storage.get_token(server_url)&.access_token).not_to eq('exchanged-a')
      expect(authorization_header_for(first)).to be_nil
    end
  end

  # ------------------------------------ codex 2: the copy that stayed behind

  describe 'a retired token whose copy under its own key the backend refuses to delete' do
    # The documented interface only: no delete_token, and nil is not a record.
    let(:sticky_storage) do
      Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        def set_token(url, token)
          raise ArgumentError, 'token required' if token.nil?

          super
        end
      end.new
    end

    def seed_both_copies(store, provider)
      seed_a(store)
      store.set_token(server_url, token_for(issuer_a, 'retired-a'))
      store.set_token(provider.client_registration_key(issuer_a), token_for(issuer_a, 'retired-a'))
    end

    it 'is refused after a restart from the slot in use and from its own key alike' do
      provider = provider_for(sticky_storage)
      seed_both_copies(sticky_storage, provider)

      challenge_to_b(provider)
      expect(provider.access_token).to be_nil

      # A provider built afterwards holds no in-process retirement marker:
      # every copy in storage has to say for itself that it was retired.
      restarted = provider_for(sticky_storage)
      expect(restarted.access_token).to be_nil
      expect(authorization_header_for(restarted)).to be_nil
      kept = sticky_storage.get_token(provider.client_registration_key(issuer_a))
      expect(kept).to be_retired
    end

    it 'is deleted from both places by a backend that can delete' do
      deleting = Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        def delete_token(key)
          set_token(key, nil)
        end
      end.new
      provider = provider_for(deleting)
      seed_both_copies(deleting, provider)

      challenge_to_b(provider)

      expect(deleting.get_token(server_url)).to be_nil
      expect(deleting.get_token(provider.client_registration_key(issuer_a))).to be_nil
      expect(provider_for(deleting).access_token).to be_nil
    end
  end

  # ------------------------------------------- codex 3: the cleanup window

  describe 'a flow started by another thread while a completed flow discards its records' do
    # A valid backend whose delete answers with nothing: the completed flow
    # cannot tell whose record it removed, so it must not have removed the
    # newer one in the first place.
    let(:silent_storage) do
      Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
        attr_accessor :on_get_pkce

        def delete_pkce(url)
          super
          nil
        end

        def delete_state(url)
          super
          nil
        end

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
      seed_a(silent_storage)
      first = provider_for(silent_storage)
      first_state = param_in(first.start_authorization_flow, 'state')
      second_url = nil
      second = nil
      stub_request(:post, "#{issuer_a}/token").to_return do
        if second.nil?
          silent_storage.on_get_pkce = lambda {
            # The other thread starts its flow while this one is between the
            # read and the delete; it must wait for the delete.
            second = Thread.new { second_url = provider_for(silent_storage).start_authorization_flow }
            sleep 0.2
          }
        end
        { status: 200, headers: json, body: { 'access_token' => 'first', 'token_type' => 'Bearer' }.to_json }
      end

      expect(first.complete_authorization_flow('code', first_state).access_token).to eq('first')
      expect(second.join(5)).not_to be_nil
      expect(second_url).not_to be_nil
      expect(silent_storage.get_state(server_url)).to eq(param_in(second_url, 'state'))
      expect(silent_storage.get_pkce(server_url)&.code_challenge).to eq(param_in(second_url, 'code_challenge'))
    end
  end

  # ------------------------------------------- codex: iss is decoded once

  describe 'an issuer with a percent-escape in it' do
    let(:issuer) { 'https://as.example/tenant%2Fone' }
    let(:responses) { [] }

    before do
      storage.set_server_metadata(server_url, server_metadata(issuer, iss_supported: true))
      storage.set_client_info(server_url, client_info('client-a', issuer))
    end

    def browser_with_callback(provider, query)
      browser = MCPClient::Auth::BrowserOAuth.new(provider, callback_port: 1, callback_path: '/cb', logger: logger)
      tcp_server = instance_double(TCPServer)
      socket = instance_double(TCPSocket)
      allow(TCPServer).to receive(:new).and_return(tcp_server)
      allow(tcp_server).to receive(:wait_readable).and_return(tcp_server)
      allow(tcp_server).to receive(:accept).and_return(socket)
      allow(tcp_server).to receive(:close)
      allow(socket).to receive(:setsockopt)
      allow(socket).to receive(:close)
      allow(socket).to receive(:print) { |data| responses << data }
      lines = nil
      allow(socket).to receive(:gets) do
        lines ||= ["GET /cb?#{query.call} HTTP/1.1\r\n", "\r\n", nil]
        lines.shift
      end
      browser
    end

    # The callback carries the issuer form-encoded ONCE: "%252F" is the
    # escape of the issuer's own "%2F". Decoded once it matches; decoded
    # twice it would read "tenant/one", another issuer.
    let(:once) { 'https%3A%2F%2Fas.example%2Ftenant%252Fone' }
    let(:twice) { 'https%3A%2F%2Fas.example%2Ftenant%2Fone' }

    it 'redeems a success response whose iss matches after one decoding pass' do
      token_endpoint = stub_request(:post, "#{issuer}/token")
                       .to_return(status: 200, headers: json,
                                  body: { 'access_token' => 'once', 'token_type' => 'Bearer' }.to_json)
      provider = provider_for
      browser = browser_with_callback(provider, -> { "code=abc&state=#{storage.get_state(server_url)}&iss=#{once}" })

      expect(browser.authenticate(timeout: 1, auto_open_browser: false).access_token).to eq('once')
      expect(token_endpoint).to have_been_requested
      expect(responses.join).to include('HTTP/1.1 200')
    end

    it 'refuses a success response whose iss only matches when decoded twice, without redeeming the code' do
      token_endpoint = stub_request(:post, "#{issuer}/token")
      provider = provider_for
      browser = browser_with_callback(provider, -> { "code=abc&state=#{storage.get_state(server_url)}&iss=#{twice}" })

      expect { browser.authenticate(timeout: 1, auto_open_browser: false) }
        .to raise_error(MCPClient::Errors::ConnectionError, /iss/)
      expect(token_endpoint).not_to have_been_requested
      expect(responses.join).to include('HTTP/1.1 400')
      expect(responses.join).not_to include('HTTP/1.1 200')
    end

    it 'shows an error response whose iss matches after one decoding pass' do
      provider = provider_for
      browser = browser_with_callback(provider, lambda {
        "error=access_denied&error_description=user-said-no&state=#{storage.get_state(server_url)}&iss=#{once}"
      })

      expect { browser.authenticate(timeout: 1, auto_open_browser: false) }
        .to raise_error(MCPClient::Errors::ConnectionError, /user-said-no/)
    end

    it 'hides an error response whose iss only matches when decoded twice' do
      provider = provider_for
      browser = browser_with_callback(provider, lambda {
        "error=access_denied&error_description=user-said-no&state=#{storage.get_state(server_url)}&iss=#{twice}"
      })

      expect { browser.authenticate(timeout: 1, auto_open_browser: false) }
        .to raise_error(MCPClient::Errors::ConnectionError) { |e| expect(e.message).not_to include('user-said-no') }
      expect(responses.join).not_to include('user-said-no')
    end
  end

  # ------------------------------------------- grok: RFC 9207 row 3

  describe 'a present iss from a server that does not advertise the parameter' do
    it 'is compared, and a matching one is accepted' do
      seed_a
      provider = provider_for
      state = param_in(provider.start_authorization_flow, 'state')
      token_endpoint = stub_request(:post, "#{issuer_a}/token")
                       .to_return(status: 200, headers: json,
                                  body: { 'access_token' => 'row-3', 'token_type' => 'Bearer' }.to_json)

      expect(provider.complete_authorization_flow('code', state, iss: issuer_a).access_token).to eq('row-3')
      expect(token_endpoint).to have_been_requested
    end
  end

  # --------------------------------------------- grok: only the first server

  describe 'protected resource metadata that lists more than one authorization server' do
    it 'uses the first and never contacts the others' do
      stub_request(:get, prm_url).to_return(status: 200, headers: json, body: prm_document(issuer_b, issuer_c).to_json)
      at_b = stub_request(:get, "#{issuer_b}/.well-known/oauth-authorization-server")
             .to_return(status: 200, headers: json, body: as_document(issuer_b).to_json)
      provider = provider_for

      metadata = provider.send(:discover_and_cache_authorization_server)

      expect(metadata.issuer).to eq(issuer_b)
      expect(at_b).to have_been_requested
      expect(a_request(:get, /as-c\.example\.com/)).not_to have_been_made
    end
  end

  # ------------------------------------------- grok: behind the transport

  describe 'a real provider behind the HTTP transport' do
    def http_server(store = storage)
      MCPClient::ServerHTTP.new(base_url: 'https://mcp.example.com', endpoint: '/mcp', retries: 0,
                                oauth_provider: provider_for(store), logger: logger)
    end

    it 'presents nothing when the stored token belongs to another authorization server' do
      seed_a
      storage.set_token(server_url, token_for(issuer_b, 'other-servers'))
      server = http_server
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

      expect(authorizations).to eq([nil])
    end

    # One complete 2025-11-25 session: the era probe, the handshake and a
    # request, every one of them carrying the token the provider holds.
    it 'carries the token through a negotiated 2025-11-25 session' do
      seed_a
      storage.set_token(server_url, token_for(issuer_a, 'bound'))
      server = http_server
      wire = []
      stub_request(:post, server_url).to_return do |request|
        body = JSON.parse(request.body)
        wire << [body['method'], request.headers['Authorization']]
        result = case body['method']
                 when 'server/discover'
                   next { status: 200, headers: json,
                          body: { jsonrpc: '2.0', id: body['id'],
                                  error: { code: -32_601, message: 'Method not found' } }.to_json }
                 when 'initialize'
                   { protocolVersion: '2025-11-25', capabilities: {}, serverInfo: { name: 's', version: '1' } }
                 when 'tools/list' then { tools: [] }
                 else next { status: 202, body: '' }
                 end
        { status: 200, headers: json, body: { jsonrpc: '2.0', id: body['id'], result: result }.to_json }
      end

      server.connect
      expect(server.list_tools).to eq([])
      expect(server.protocol_version).to eq('2025-11-25')
      expect(wire.map(&:first)).to include('server/discover', 'initialize', 'tools/list')
      expect(wire.map(&:last).uniq).to eq(['Bearer bound'])
    end
  end

  # ------------------------------------------- codex: configuration errors

  describe 'configuration that names an unknown type' do
    it 'refuses an unknown application_type' do
      expect do
        MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                           storage: storage, application_type: 'desktop')
      end.to raise_error(ArgumentError, /application_type/)
    end

    it 'refuses an unknown registration_type on a client record' do
      expect do
        MCPClient::Auth::ClientInfo.new(client_id: 'c', registration_type: 'manual',
                                        metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]))
      end.to raise_error(ArgumentError, /registration_type/)
    end
  end
end

# --- round41 ---------------------------------------------------------------

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

# --- round42 ---------------------------------------------------------------

# MCP 2026-07-28 authorization, forty-second review round: the checks that
# accept a token and the write that keeps it are one step against every
# provider sharing the storage; a change of authorization server another
# provider made is reconciled here before scopes are resolved; and the
# step-up union preserves what was actually asked for, not what a first
# authorization was merely configured to ask.
RSpec.describe 'MCP 2026-07-28 authorization — round 42' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:issuer_a) { 'https://as-a.example.com' }
  let(:issuer_b) { 'https://as-b.example.com' }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:storage) { hooked_storage }

  # A MemoryStorage that can be paused inside one write, so a second thread
  # can be shown to wait for it rather than interleave with it.
  def hooked_storage
    Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
      attr_accessor :before_set_token, :before_delete_pkce, :before_get_token, :after_get_token

      def set_token(url, token)
        hook = @before_set_token
        @before_set_token = nil
        hook&.call
        super
      end

      # Left armed until the hook itself disarms: a read of another key must
      # not spend the pause meant for one particular key. The `after` hook
      # runs once the value is in hand, which is what makes a stale read
      # reproducible.
      def get_token(url)
        @before_get_token&.call(url)
        value = super
        @after_get_token&.call(url)
        value
      end

      def delete_pkce(url)
        hook = @before_delete_pkce
        @before_delete_pkce = nil
        hook&.call
        super
      end
    end.new
  end

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

  def client_info(id, iss)
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: 'pre_registered',
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri],
                                                    token_endpoint_auth_method: 'none')
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

  def param_in(url, name)
    URI.decode_www_form(URI.parse(url).query).to_h[name]
  end

  def authorization_header_for(provider)
    request = Faraday::Request.new
    request.headers = {}
    provider.apply_authorization(request)
    request.headers['Authorization']
  end

  # A validated 401 challenge naming B, handled by a provider of its own.
  def challenge_to_b(provider, scopes: nil)
    body = { 'resource' => server_url, 'authorization_servers' => [issuer_b] }
    body['scopes_supported'] = scopes if scopes
    stub_request(:get, prm_url).to_return(status: 200, headers: json, body: body.to_json)
    header = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: header))
  end

  # ------------------------------------------------------------- codex P1
  # The acceptance checks and the write they guard are one step: a switch of
  # authorization server that another provider validates between them would
  # otherwise land its token in the slot first and have this response written
  # straight over it.
  describe 'a token accepted while another thread switches the authorization server' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      WebMock.stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => server_url, 'authorization_servers' => [issuer_b] }.to_json
      )
    end

    # Runs `switch` on its own thread while `writer` is paused inside its
    # token write, and reports whether the switch got in before the write.
    def racing(writer, &switch)
      at_write = Queue.new
      resume = Queue.new
      switched = Queue.new
      storage.before_set_token = lambda {
        at_write << true
        resume.pop
      }
      main = Thread.new { writer.call }
      at_write.pop
      other = Thread.new do
        switch.call
        switched << true
      end
      interleaved = !other.join(0.3).nil?
      resume << true
      [main, other].each { |thread| thread.join(5) }
      { interleaved: interleaved, switched: !switched.empty? }
    end

    it 'lets no code exchange write over the token of a switch that was waiting' do
      provider = provider_for
      state = param_in(provider.start_authorization_flow, 'state')
      stub_request(:post, "#{issuer_a}/token").to_return(token_body('late-a'))
      other = provider_for

      race = racing(-> { provider.complete_authorization_flow('code', state) }) do
        challenge_to_b(other)
        storage.set_token(server_url, token_for(issuer_b, 'token-b'))
      end

      expect(race[:interleaved]).to be(false)
      expect(race[:switched]).to be(true)
      expect(storage.get_token(server_url)&.access_token).to eq('token-b')
      # B's metadata was never discovered here, so the token it stored is not
      # presented yet — what matters is that A's late answer neither replaced
      # it nor reaches a caller.
      expect(authorization_header_for(provider_for)).not_to eq('Bearer late-a')
    end

    it 'lets no refresh write over the token of a switch that was waiting' do
      storage.set_token(server_url, token_for(issuer_a, 'old-a', refresh: 'r1', expires_in: -1))
      stub_request(:post, "#{issuer_a}/token").to_return(token_body('late-a'))
      provider = provider_for
      other = provider_for

      race = racing(-> { provider.access_token }) do
        challenge_to_b(other)
        storage.set_token(server_url, token_for(issuer_b, 'token-b'))
      end

      expect(race[:interleaved]).to be(false)
      expect(storage.get_token(server_url)&.access_token).to eq('token-b')
    end
  end

  # ------------------------------------------------------------- codex P1 (round 8)
  # Adoption reads the authorization server in use and the token kept for it,
  # then makes that token the one in use. The read is not the state the write
  # may trust: a switch of authorization server another provider validated in
  # between made ITS token the one in use, and this one stale. The
  # re-validation and the write are one step, under the lock the switch takes.
  describe 'a saved token adopted while another provider completes a switch' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
    end

    # Pauses the adopting provider on its read of the token kept for A, runs
    # the switch to B to completion, and only then lets the adoption go on.
    def adopting_across_a_switch(provider, kept_key)
      at_read = Queue.new
      resume = Queue.new
      storage.before_get_token = lambda { |url|
        next unless url == kept_key

        storage.before_get_token = nil
        at_read << true
        resume.pop
      }
      adopting = Thread.new { provider.access_token }
      at_read.pop
      switcher = provider_for
      challenge_to_b(switcher)
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_token(server_url, token_for(issuer_b, 'token-b'))
      resume << true
      adopting.join(5)
      adopting.value
    end

    it 'leaves the switch its token and never presents the previous issuer' do
      provider = provider_for
      kept_key = provider.client_registration_key(issuer_a)
      storage.set_token(kept_key, token_for(issuer_a, 'token-a'))

      adopted = adopting_across_a_switch(provider, kept_key)

      # The slot the switch wrote is untouched, and the caller that was
      # adopting is never handed the token of the server that is gone.
      expect(storage.get_token(server_url)&.access_token).to eq('token-b')
      expect(adopted&.access_token).not_to eq('token-a')
      expect(authorization_header_for(provider_for)).to eq('Bearer token-b')
      # The token kept for A stays kept: returning to A must still find it.
      expect(storage.get_token(kept_key)&.access_token).to eq('token-a')
    end

    it 'still adopts the token kept for the server that is still in use' do
      provider = provider_for
      kept_key = provider.client_registration_key(issuer_a)
      storage.set_token(kept_key, token_for(issuer_a, 'token-a'))

      expect(provider.access_token&.access_token).to eq('token-a')
      expect(storage.get_token(server_url)&.access_token).to eq('token-a')
    end
  end

  # ------------------------------------------------------------- codex coverage
  # Returning to an authorization server whose saved token has expired: the
  # refresh token kept with it is what makes the return usable at all, so the
  # saved grant is refreshed at that server and the rotation persisted.
  describe 'a return to an authorization server whose saved token expired' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
    end

    it 'refreshes the saved grant at that server and persists the rotated refresh token' do
      provider = provider_for
      kept_key = provider.client_registration_key(issuer_a)
      storage.set_token(kept_key, token_for(issuer_a, 'stale-a', refresh: 'r-old', expires_in: -1))
      refresh = stub_request(:post, "#{issuer_a}/token")
                .with(body: hash_including('grant_type' => 'refresh_token', 'refresh_token' => 'r-old'))
                .to_return(token_body('fresh-a', refresh: 'r-new'))

      token = provider.access_token

      expect(refresh).to have_been_requested
      expect(token&.access_token).to eq('fresh-a')
      expect(authorization_header_for(provider)).to eq('Bearer fresh-a')
      in_use = storage.get_token(server_url)
      expect(in_use&.access_token).to eq('fresh-a')
      expect(in_use&.refresh_token).to eq('r-new')
      expect(in_use&.issuer).to eq(issuer_a)
    end
  end

  # ------------------------------------------------------------- codex coverage
  # A 2025-11-25 token names no authorization server; it is bound to the one
  # in use the first time it is read. That binding is a write to the slot in
  # use, so it answers to the same rule as adoption.
  describe 'an issuer-less token bound while another provider completes a switch' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
    end

    it 'leaves the switch its token rather than binding over it' do
      storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'legacy', expires_in: 3600))
      provider = provider_for
      at_read = Queue.new
      resume = Queue.new
      # Paused with the issuer-less record already in hand: the switch that
      # follows is what the binding write must not land on top of.
      storage.after_get_token = lambda { |url|
        next unless url == server_url

        storage.after_get_token = nil
        at_read << true
        resume.pop
      }

      binding_thread = Thread.new { provider.access_token }
      at_read.pop
      challenge_to_b(provider_for)
      storage.set_server_metadata(server_url, server_metadata(issuer_b))
      storage.set_token(server_url, token_for(issuer_b, 'token-b'))
      resume << true
      binding_thread.join(5)

      expect(storage.get_token(server_url)&.access_token).to eq('token-b')
      expect(binding_thread.value&.access_token).not_to eq('legacy')
    end
  end

  # ------------------------------------------------------------- codex coverage
  # The cleanup's read-compare-delete is what the lock exists for: a flow
  # started while it runs must wait for the delete, not lose its record to it.
  describe 'a flow started while a completed flow is discarding its records' do
    before do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
    end

    it 'waits for the delete instead of racing it' do
      provider = provider_for
      state = param_in(provider.start_authorization_flow, 'state')
      stub_request(:post, "#{issuer_a}/token").to_return(token_body('exchanged'))
      at_delete = Queue.new
      resume = Queue.new
      storage.before_delete_pkce = lambda {
        at_delete << true
        resume.pop
      }

      completing = Thread.new { provider.complete_authorization_flow('code', state) }
      at_delete.pop
      starting = Thread.new { provider_for.start_authorization_flow }
      interleaved = !starting.join(0.3).nil?
      resume << true
      [completing, starting].each { |thread| thread.join(5) }

      expect(interleaved).to be(false)
      expect(storage.get_pkce(server_url)).not_to be_nil
    end
  end

  # ------------------------------------------------------------- codex P2 (scopes)
  describe 'a change of authorization server another provider discovered' do
    before do
      %w[a b].each do |name|
        issuer = name == 'a' ? issuer_a : issuer_b
        stub_request(:get, "#{issuer}/.well-known/oauth-authorization-server").to_return(
          status: 200, headers: json, body: server_metadata(issuer, scopes: ["#{name}:read"]).to_h.to_json
        )
      end
    end

    it 'is reconciled here before the next request resolves its scope' do
      first = provider_for
      second = provider_for
      [issuer_a, issuer_b].each do |issuer|
        storage.set_client_info(first.client_registration_key(issuer), client_info("client-of-#{issuer}", issuer))
      end
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => server_url, 'authorization_servers' => [issuer_a],
                'scopes_supported' => ['a:read'] }.to_json
      )
      expect(param_in(first.start_authorization_flow, 'scope')).to eq('a:read')

      challenge_to_b(second, scopes: ['b:read'])
      second.start_authorization_flow

      url = first.start_authorization_flow
      expect(URI.parse(url).host).to eq(URI.parse(issuer_b).host)
      expect(param_in(url, 'scope').to_s.split).to contain_exactly('b:read')
    end
  end

  # ------------------------------------------------------------- codex P2 (initial scope)
  # "Determine required scopes by computing the union of the client's
  # PREVIOUSLY REQUESTED scope set and the scopes from the current challenge"
  # (MCP 2026-07-28 step-up authorization). A first authorization has no
  # previously requested set: the challenge decides it alone.
  describe 'the first authorization after a challenge naming its scope' do
    before do
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      stub_request(:get, "#{issuer_a}/.well-known/oauth-authorization-server").to_return(
        status: 200, headers: json, body: server_metadata(issuer_a, scopes: %w[admin read]).to_h.to_json
      )
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => server_url, 'authorization_servers' => [issuer_a] }.to_json
      )
    end

    def challenge_scope(provider, scope)
      header = { 'WWW-Authenticate' => "Bearer scope=\"#{scope}\", resource_metadata=\"#{prm_url}\"" }
      provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: header))
    end

    it 'asks for the challenged scope alone, not every scope the server advertises' do
      provider = provider_for(storage, scope: :all)
      challenge_scope(provider, 'read')

      expect(param_in(provider.start_authorization_flow, 'scope').to_s.split).to contain_exactly('read')
    end

    it 'still preserves what an earlier request of this client asked for' do
      provider = provider_for(storage, scope: :all)
      expect(param_in(provider.start_authorization_flow, 'scope').to_s.split).to contain_exactly('admin', 'read')

      challenge_scope(provider, 'write')

      expect(param_in(provider.start_authorization_flow, 'scope').to_s.split)
        .to contain_exactly('admin', 'read', 'write')
    end

    it 'still preserves what the authorization server already granted' do
      storage.set_token(server_url, token_for(issuer_a, 'granted', expires_in: -1))
      storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'granted', expires_in: 3600,
                                                               scope: 'files:read', issuer: issuer_a))
      provider = provider_for(storage, scope: 'files:write')
      challenge_scope(provider, 'read')

      expect(param_in(provider.start_authorization_flow, 'scope').to_s.split)
        .to contain_exactly('files:read', 'files:write', 'read')
    end
  end

  # ------------------------------------------------------------- grok
  # A step-up challenge is a step-up challenge whatever status carries it:
  # RFC 6750 pairs insufficient_scope with 403, and servers send it on 401
  # too. A host that rescues InsufficientScopeError to run the step-up flow
  # would otherwise miss the 401 spelling entirely.
  describe 'an insufficient_scope challenge carried by a 401' do
    let(:transport) do
      MCPClient::ServerHTTP.new(base_url: 'https://mcp.example.com', endpoint: '/mcp', retries: 0)
    end

    it 'raises the typed step-up error with the scopes it names' do
      stub_request(:post, 'https://mcp.example.com/mcp').to_return(
        status: 401,
        headers: { 'WWW-Authenticate' => 'Bearer error="insufficient_scope", scope="files:write"' }
      )

      expect { transport.connect }.to raise_error(MCPClient::Errors::InsufficientScopeError) do |error|
        expect(error.scope).to eq('files:write')
      end
    end

    it 'still raises a plain connection error for a 401 that names no step-up' do
      stub_request(:post, 'https://mcp.example.com/mcp').to_return(
        status: 401, headers: { 'WWW-Authenticate' => 'Bearer error="invalid_token"' }
      )

      expect { transport.connect }.to raise_error(MCPClient::Errors::ConnectionError) do |error|
        expect(error).not_to be_a(MCPClient::Errors::InsufficientScopeError)
      end
    end
  end

  # A client id that is a Client ID Metadata Document URL goes to the token
  # endpoint as it went to the authorization endpoint (SEP-991).
  describe 'a Client ID Metadata Document URL as the client id' do
    it 'is what the code exchange names itself with' do
      cimd = 'https://app.example.com/client-metadata.json'
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      provider = provider_for
      storage.set_client_info(provider.client_registration_key(issuer_a), MCPClient::Auth::ClientInfo.new(
                                                                            client_id: cimd, issuer: issuer_a,
                                                                            registration_type: 'cimd',
                                                                            metadata:
                                                                              MCPClient::Auth::ClientMetadata.new(
                                                                                redirect_uris: [redirect_uri],
                                                                                token_endpoint_auth_method: 'none'
                                                                              )
                                                                          ))
      state = param_in(provider.start_authorization_flow, 'state')
      exchange = stub_request(:post, "#{issuer_a}/token")
                 .with(body: hash_including('client_id' => cimd))
                 .to_return(token_body('cimd-token'))

      expect(provider.complete_authorization_flow('code', state).access_token).to eq('cimd-token')
      expect(exchange).to have_been_requested
    end
  end

  # RFC 8414 Section 3.3: the issuer of the document must be the identifier it
  # was fetched for. Pinned over the wire, not by stubbing the fetch.
  describe 'a well-known document whose issuer is not the one it was fetched for' do
    it 'is refused' do
      stub_request(:get, prm_url).to_return(
        status: 200, headers: json,
        body: { 'resource' => server_url, 'authorization_servers' => [issuer_a] }.to_json
      )
      stub_request(:get, "#{issuer_a}/.well-known/oauth-authorization-server").to_return(
        status: 200, headers: json, body: server_metadata(issuer_b).to_h.to_json
      )

      expect { provider_for.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError)
      expect(storage.get_server_metadata(server_url)).to be_nil
    end
  end
end

# --- round43 ---------------------------------------------------------------

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

# --- release review: the authorization-state lock outlives a GC -------------

# The lock that serializes a resource's authorization state lived in an
# ObjectSpace::WeakMap, whose VALUES are weak as well as its keys. The
# registry's value is the hash holding the per-resource monitors, and nothing
# else referenced it: a garbage collection between two acquisitions dropped it,
# the next caller built a fresh monitor, and two providers sharing one storage
# entered the critical section at the same time. The section guards
# read-compare-write on the token slot, so what it costs is a token accepted
# against state that changed underneath it.
RSpec.describe 'MCP 2026-07-28 authorization — the authorization-state lock' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: storage)
  end

  it 'keeps two providers on one storage out of the critical section at once, across a GC' do
    first = provider
    second = provider
    inside = Queue.new
    release = Queue.new
    second_entered = Queue.new

    holder = Thread.new do
      first.send(:with_authorization_state_lock) do
        inside << true
        # The window the bug needed: nothing outside the registry referenced
        # the monitor table, so a collection here replaced it.
        3.times { GC.start }
        release.pop
      end
    end

    inside.pop
    contender = Thread.new do
      second.send(:with_authorization_state_lock) { second_entered << true }
    end

    # The contender must still be waiting: it may only enter once the holder
    # leaves. Without the fix it enters immediately on its own fresh monitor.
    entered_early = begin
      second_entered.pop(timeout: 0.5)
    rescue StandardError
      nil
    end
    expect(entered_early).to be_nil

    release << true
    holder.join(5)
    expect(second_entered.pop(timeout: 5)).to be(true)
    contender.join(5)
  end

  it 'hands the same lock to every provider sharing a storage and resource' do
    first = provider
    monitors = []
    first.send(:with_authorization_state_lock) { monitors << Thread.current }
    3.times { GC.start }

    # A second acquisition after a collection must reuse the first monitor;
    # comparing the objects directly is what the WeakMap could not promise.
    registry = MCPClient::Auth::OAuthProvider.const_get(:AUTHORIZATION_STATE_LOCKS)
    table = registry[storage]
    expect(table).not_to be_nil
    lock = table[server_url]
    expect(lock).to be_a(Monitor)

    3.times { GC.start }
    expect(registry[storage]&.fetch(server_url, nil)).to equal(lock)
  end

  # Weak KEYS so a storage the host drops takes its locks with it, and strong
  # VALUES so a collection cannot swap the monitor table out from under a held
  # lock. Whether a given object is collected on a given GC is not something a
  # suite can pin, but which map is in use decides both properties.
  it 'holds storages weakly and their monitor tables strongly' do
    registry = MCPClient::Auth::OAuthProvider.const_get(:AUTHORIZATION_STATE_LOCKS)
    expect(registry).to be_a(ObjectSpace::WeakKeyMap)
  end
end
