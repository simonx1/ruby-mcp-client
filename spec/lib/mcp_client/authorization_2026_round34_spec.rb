# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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
