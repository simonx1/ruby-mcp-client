# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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
          .to_return(status: 200, headers: json, body: { 'access_token' => 'fresh' }.to_json)
        provider = provider_for

        expect(provider.access_token&.access_token).to eq('fresh')
        expect(authorization_header_for(provider)).to eq('Bearer fresh')
      end

      # A JSON null says the same thing as an absent member; the defaults an
      # omitted field gets still apply.
      it 'treats a null optional field as an absent one' do
        stub_request(:post, token_endpoint)
          .to_return(status: 200, headers: json,
                     body: { 'access_token' => 'fresh', 'token_type' => nil, 'expires_in' => nil,
                             'refresh_token' => nil, 'scope' => nil }.to_json)
        provider = provider_for

        expect(provider.access_token&.access_token).to eq('fresh')
        expect(authorization_header_for(provider)).to eq('Bearer fresh')
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
