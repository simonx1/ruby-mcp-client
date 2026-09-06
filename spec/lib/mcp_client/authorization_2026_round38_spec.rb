# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'mcp_client/auth/browser_oauth'

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

    it 'keeps the configured scope when a challenge names another one' do
      storage.set_server_metadata(server_url, server_metadata(issuer_a))
      storage.set_client_info(server_url, client_info('client-a', issuer_a))
      provider = provider_for(scope: 'files:read')
      provider.instance_variable_set(:@challenge_scope, 'files:write')

      expect(param_in(provider.start_authorization_flow, 'scope').split)
        .to contain_exactly('files:read', 'files:write')
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
