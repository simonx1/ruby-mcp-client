# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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
