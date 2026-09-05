# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'base64'
require 'mcp_client/auth/browser_oauth'

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
