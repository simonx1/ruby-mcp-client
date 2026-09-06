# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'mcp_client/auth/browser_oauth'

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
