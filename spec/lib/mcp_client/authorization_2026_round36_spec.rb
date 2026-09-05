# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'mcp_client/auth/browser_oauth'

# MCP 2026-07-28 authorization, thirty-sixth round. Each finding is a gap left
# by round 35's own hardening.
#
# Round 35 made the peer-text helpers total, and then left the paths that read
# a peer's bytes *before* reaching a helper untouched: a token endpoint's
# `unauthorized_client` body is matched against a redirect_uri-mismatch
# pattern, a WWW-Authenticate header is masked and matched for its Bearer
# segment, and a callback query string is percent-decoded — all with
# `String#gsub`, `String#match` and `Regexp#match?`, all of which raise
# `ArgumentError: invalid byte sequence in UTF-8`. A sanitizer only helps the
# text that reaches it, so peer bytes are made decodable at the point they
# stop being bytes and start being text.
#
# Round 35 also read the two metadata documents field by field — and only for
# the types of the fields that were present. A document that simply omits
# `authorization_endpoint` or `token_endpoint` has no field of the wrong type,
# so it was cached as authorization server metadata, and the flow crashed with
# a `URI::InvalidURIError` in `start_authorization_flow` or
# `complete_authorization_flow` — after dynamic client registration had
# already created a client at the authorization server. RFC 8414 makes those
# fields REQUIRED, and RFC 9728 makes `resource` REQUIRED; a document that
# omits one is refused at discovery.
#
# And a token record whose stored expiry cannot be read must be treated as
# expired. Round 35's {MCPClient::Auth::Token::UNREADABLE_EXPIRY} did that for
# an unreadable *lifetime*, but let a numeric `expires_in` stand in for an
# unreadable `expires_at` — so `{ expires_in: 3600, expires_at: 'not a time' }`,
# the exact shape this library persists, came back freshly issued.
RSpec.describe 'MCP 2026-07-28 authorization — round 36' do
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

  # Bytes that are not valid UTF-8, in the shapes a peer can produce them.
  let(:invalid_utf8) do
    [
      +"\xFF",
      +"you sent \xC3(",
      +"\xE2\x28\xA1 description",
      (+"caf\xC3\xA9 \xFF").force_encoding(Encoding::ASCII_8BIT),
      +"\xF0\x9F trailing"
    ]
  end

  def provider_for(store = storage, url: server_url)
    MCPClient::Auth::OAuthProvider.new(server_url: url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def server_metadata(iss = issuer)
    MCPClient::Auth::ServerMetadata.new(
      issuer: iss, authorization_endpoint: "#{iss}/authorize", token_endpoint: "#{iss}/token",
      code_challenge_methods_supported: ['S256'], authorization_response_iss_parameter_supported: false
    )
  end

  def client_info(id = 'client-1', iss = issuer)
    MCPClient::Auth::ClientInfo.new(
      client_id: id, issuer: iss, registration_type: 'pre_registered',
      metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri],
                                                    token_endpoint_auth_method: 'none')
    )
  end

  def store_pending_flow(store = storage)
    metadata = server_metadata
    client = client_info
    store.set_server_metadata(server_url, metadata)
    store.set_state(server_url, state)
    store.set_client_info(server_url, client)
    store.set_pkce(server_url,
                   MCPClient::Auth::PKCE.new(issuer: metadata.issuer, iss_parameter_supported: false,
                                             client_id: client.client_id, redirect_uri: redirect_uri))
  end

  def valid_as_document
    {
      'issuer' => issuer, 'authorization_endpoint' => "#{issuer}/authorize",
      'token_endpoint' => token_endpoint, 'registration_endpoint' => registration_endpoint,
      'code_challenge_methods_supported' => ['S256']
    }
  end

  def valid_prm_document
    { 'resource' => server_url, 'authorization_servers' => [issuer] }
  end

  # ---------------------------------------------------------------- finding 1

  describe 'peer bytes that are read before a sanitizer sees them' do
    it 'reports a token endpoint unauthorized_client whose description is not UTF-8 as a ConnectionError' do
      store_pending_flow
      stub_request(:post, token_endpoint).to_return(
        status: 400, headers: json,
        body: +%({"error":"unauthorized_client","error_description":"You sent \xFF and we expected \xFF"})
      )

      expect { provider_for.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /Token exchange failed: HTTP 400/)
    end

    it 'never raises out of extract_redirect_mismatch, whatever the body carried' do
      provider = provider_for

      invalid_utf8.each do |bytes|
        body = %({"error":"unauthorized_client","error_description":"#{bytes.dup.force_encoding(
          Encoding::UTF_8
        )}"})
        expect { provider.send(:extract_redirect_mismatch, body) }.not_to raise_error, bytes.inspect
      end
    end

    it 'still recognises a redirect_uri mismatch in a description that also carries bad bytes' do
      provider = provider_for
      body = +%({"error":"unauthorized_client","error_description":) +
             +%("\xFF You sent https://a.example/cb, and we expected https://b.example/cb"})

      expect(provider.send(:extract_redirect_mismatch, body))
        .to include(expected: 'https://b.example/cb')
    end

    it 'never raises out of the WWW-Authenticate challenge parser' do
      provider = provider_for

      invalid_utf8.each do |bytes|
        header = "Bearer realm=\"x\", resource_metadata=\"#{bytes.dup.force_encoding(Encoding::UTF_8)}\""
        expect { provider.send(:bearer_challenge_segment, header) }.not_to raise_error, bytes.inspect
        expect { provider.send(:extract_challenge_param, header, 'scope') }.not_to raise_error, bytes.inspect
        expect { provider.send(:extract_resource_metadata_url, header) }.not_to raise_error, bytes.inspect
      end
    end

    it 'handles a 401 whose WWW-Authenticate header is not UTF-8 without raising' do
      response = Struct.new(:status, :headers).new(401, { 'WWW-Authenticate' => +"Bearer scope=\"a\xFFb\"" })

      expect { provider_for.handle_unauthorized_response(response) }.not_to raise_error
    end

    it 'chases no metadata URL a challenge only names in undecodable bytes' do
      provider = provider_for
      header = +"Bearer resource_metadata=\"https://evil.example/\xFF\""
      response = Struct.new(:status, :headers).new(401, { 'WWW-Authenticate' => header })

      # Scrubbing turns the undecodable byte into a '?': a URL nobody wrote,
      # and not one to send a request to. Discovery falls back to well-known.
      expect(provider.handle_unauthorized_response(response)).to be_nil
      expect(provider.send(:extract_resource_metadata_url, header)).to be_nil
      expect(a_request(:get, /evil\.example/)).not_to have_been_made
    end

    it 'raises an authorization error, not an ArgumentError, for a 403 challenge that is not UTF-8' do
      server = MCPClient::ServerHTTP.new(base_url: 'https://mcp.example.com', endpoint: '/rpc')
      header = +"Bearer error=\"insufficient_scope\", scope=\"files:write \xFF\""
      response = Struct.new(:status, :headers).new(403, { 'WWW-Authenticate' => header })

      expect { server.send(:raise_authorization_error, response) }
        .to raise_error(MCPClient::Errors::InsufficientScopeError)
    end

    it 'raises a ConnectionError for a 401 whose challenge is not UTF-8' do
      server = MCPClient::ServerHTTP.new(base_url: 'https://mcp.example.com', endpoint: '/rpc')
      response = Struct.new(:status, :headers).new(401, { 'WWW-Authenticate' => +"Bearer realm=\"\xFF\"" })

      expect { server.send(:raise_authorization_error, response) }
        .to raise_error(MCPClient::Errors::ConnectionError)
    end

    # `all(be_valid_encoding)` is satisfied by an empty Hash, so the names and
    # the decoded values are asserted: every parameter survives, each
    # undecodable byte becomes one replacement character, and the readable
    # bytes around it are still there.
    it 'decodes a callback query string into text nothing downstream can choke on' do
      browser = MCPClient::Auth::BrowserOAuth.new(provider_for, callback_port: 1, callback_path: '/cb',
                                                                logger: logger)
      params = browser.send(:parse_query_params, 'code=%FFabc&state=%FE&error_description=%FF%FE')

      expect(params.keys).to contain_exactly('code', 'state', 'error_description')
      expect(params['code']).to eq('?abc')
      expect(params['state']).to eq('?')
      expect(params['error_description']).to eq('??')
      expect(params.keys).to all(be_valid_encoding)
      expect(params.values).to all(be_valid_encoding)
    end

    # "Completes" here means the callback is ANSWERED, not that the
    # authorization succeeded: the scrubbed state matches no pending flow, so
    # the browser is told why rather than left hanging on a raised
    # ArgumentError.
    it 'answers a callback whose code and state carry undecodable bytes with an error' do
      store_pending_flow
      browser = MCPClient::Auth::BrowserOAuth.new(provider_for, callback_port: 1, callback_path: '/cb',
                                                                logger: logger)
      result = {}
      socket = instance_double('TCPSocket')
      allow(socket).to receive(:setsockopt)
      allow(socket).to receive(:print)
      allow(socket).to receive(:close)
      allow(socket).to receive(:gets).and_return("GET /cb?code=%FF&state=%FE HTTP/1.1\r\n", "\r\n", nil)

      expect do
        browser.send(:handle_http_request, socket, result, Mutex.new, ConditionVariable.new)
      end.not_to raise_error
      expect(result[:completed]).to be(true)
      expect(result[:error]).to be_a(String)
    end
  end

  # ---------------------------------------------------------------- finding 2

  describe 'a metadata document that omits what its RFC requires' do
    before do
      stub_request(:get, prm_url).to_return(status: 200, headers: json, body: valid_prm_document.to_json)
      stub_request(:get, oidc_url).to_return(status: 404, body: '')
    end

    %w[issuer authorization_endpoint token_endpoint].each do |field|
      it "refuses an authorization server document that omits #{field}" do
        stub_request(:get, as_url)
          .to_return(status: 200, headers: json, body: valid_as_document.except(field).to_json)

        expect { provider_for.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError)
        expect(log_output.string).to match(/Invalid server metadata.*#{field}/)
      end
    end

    it 'refuses the document before dynamic client registration runs' do
      registration = stub_request(:post, registration_endpoint)
                     .to_return(status: 201, headers: json, body: { 'client_id' => 'registered' }.to_json)
      stub_request(:get, as_url)
        .to_return(status: 200, headers: json,
                   body: valid_as_document.except('token_endpoint').to_json)

      expect { provider_for.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError)
      expect(registration).not_to have_been_made
      expect(storage.get_server_metadata(server_url)).to be_nil
    end

    it 'does not cache a document that omits an endpoint' do
      stub_request(:get, as_url)
        .to_return(status: 200, headers: json,
                   body: valid_as_document.except('authorization_endpoint').to_json)

      expect { provider_for.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError)
      expect(storage.get_server_metadata(server_url)).to be_nil
    end

    it 'still accepts a document that carries every required field' do
      stub_request(:get, as_url).to_return(status: 200, headers: json, body: valid_as_document.to_json)
      stub_request(:post, registration_endpoint)
        .to_return(status: 201, headers: json,
                   body: { 'client_id' => 'registered', 'redirect_uris' => [redirect_uri] }.to_json)

      expect(provider_for.start_authorization_flow).to start_with("#{issuer}/authorize?")
    end

    it 'refuses a protected resource document that omits resource' do
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json, body: { 'authorization_servers' => [issuer] }.to_json)
      as_document = stub_request(:get, as_url)
                    .to_return(status: 200, headers: json, body: valid_as_document.to_json)

      provider = provider_for
      expect { provider.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /resource/)
      expect(as_document).not_to have_been_made
      # A document RFC 9728 refuses must not go on supplying scopes either.
      expect(provider.instance_variable_get(:@resource_metadata)).to be_nil
    end

    it 'refuses a challenge-advertised protected resource document that omits resource' do
      metadata_url = 'https://mcp.example.com/.well-known/oauth-protected-resource'
      stub_request(:get, metadata_url)
        .to_return(status: 200, headers: json, body: { 'authorization_servers' => [issuer] }.to_json)
      response = Struct.new(:status, :headers).new(
        401, { 'WWW-Authenticate' => %(Bearer resource_metadata="#{metadata_url}") }
      )

      expect { provider_for.handle_unauthorized_response(response) }
        .to raise_error(MCPClient::Errors::ConnectionError, /resource/)
    end
  end

  # ---------------------------------------------------------------- finding 3

  describe 'a persisted token whose expiry cannot be read' do
    it 'treats a record whose expires_at is unparseable as expired' do
      token = MCPClient::Auth::Token.from_h(access_token: 'a', expires_in: 3600, expires_at: 'not a time')

      expect(token.expires_at).to eq(MCPClient::Auth::Token::UNREADABLE_EXPIRY)
      expect(token).to be_expired
    end

    it 'treats a record whose expires_at is a number as expired' do
      token = MCPClient::Auth::Token.from_h(access_token: 'a', expires_in: 3600, expires_at: 1_600_000_000)

      expect(token).to be_expired
      expect(token).to be_expires_soon
    end

    it 'keeps saying so after a round trip through storage' do
      token = MCPClient::Auth::Token.from_h(access_token: 'a', expires_in: 3600, expires_at: {})

      expect(MCPClient::Auth::Token.from_h(token.to_h)).to be_expired
    end

    it 'still reads a recorded expiry that can be read' do
      recorded = Time.now + 600
      token = MCPClient::Auth::Token.from_h(access_token: 'a', expires_in: 3600,
                                            expires_at: recorded.iso8601)

      expect(token).not_to be_expired
      expect(token.expires_at).to be_within(1).of(recorded)
    end

    it 'still uses expires_in when no expiry was recorded at all' do
      token = MCPClient::Auth::Token.new(access_token: 'a', expires_in: 3600)

      expect(token).not_to be_expired
      expect(token.expires_at).to be_within(5).of(Time.now + 3600)
    end

    it 'still records no expiry when the record carries neither field' do
      token = MCPClient::Auth::Token.new(access_token: 'a')

      expect(token.expires_at).to be_nil
      expect(token).not_to be_expired
    end

    it 'still treats an unusable lifetime with no expires_at as expired' do
      token = MCPClient::Auth::Token.from_h(access_token: 'a', expires_in: '3600')

      expect(token).to be_expired
    end

    it 'refreshes a stored token whose expiry cannot be read instead of presenting it' do
      storage.set_server_metadata(server_url, server_metadata)
      storage.set_client_info(server_url, client_info)
      storage.set_token(server_url,
                        MCPClient::Auth::Token.from_h(access_token: 'stale', token_type: 'Bearer',
                                                      expires_in: 3600, expires_at: 'not a time',
                                                      refresh_token: 'refresh-1', issuer: issuer))
      stub_request(:post, token_endpoint)
        .to_return(status: 200, headers: json,
                   body: { 'access_token' => 'fresh', 'token_type' => 'Bearer', 'expires_in' => 3600 }.to_json)

      expect(provider_for.access_token.access_token).to eq('fresh')
    end
  end
end
