# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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
