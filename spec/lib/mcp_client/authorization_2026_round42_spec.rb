# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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
