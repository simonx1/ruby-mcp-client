# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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

      expect(provider.start_authorization_flow).to include('client_id=dyn-a')
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

      expect(deleting_storage.deletions).to eq([server_url])
      expect(deleting_storage.get_token(server_url)).to be_nil
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
