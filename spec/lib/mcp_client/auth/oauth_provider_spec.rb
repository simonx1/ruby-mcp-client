# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Auth::OAuthProvider do
  let(:server_url) { 'https://mcp.example.com' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { instance_double('Logger') }
  let(:storage) { instance_double('MCPClient::Auth::OAuthProvider::MemoryStorage') }

  subject(:oauth_provider) do
    described_class.new(
      server_url: server_url,
      redirect_uri: redirect_uri,
      scope: 'read write',
      logger: logger,
      storage: storage
    )
  end

  before do
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
  end

  describe '#initialize' do
    it 'normalizes server URL' do
      provider = described_class.new(server_url: 'HTTPS://MCP.EXAMPLE.COM:443/')
      expect(provider.server_url).to eq('https://mcp.example.com')
    end

    it 'sets default redirect URI' do
      provider = described_class.new(server_url: server_url)
      expect(provider.redirect_uri).to eq('http://localhost:8080/callback')
    end
  end

  describe 'OAuth discovery URL generation' do
    it 'generates correct discovery URL for full server URL with path and query' do
      provider = described_class.new(
        server_url: 'https://mcp.zapier.com/api/mcp/a/123/mcp?serverId=abc-123'
      )

      # Access private method for testing
      discovery_url = provider.send(:build_discovery_url, provider.server_url)
      expect(discovery_url).to eq('https://mcp.zapier.com/.well-known/oauth-protected-resource')
    end

    it 'generates correct discovery URL for simple server URL' do
      provider = described_class.new(server_url: 'https://api.example.com')

      discovery_url = provider.send(:build_discovery_url, provider.server_url)
      expect(discovery_url).to eq('https://api.example.com/.well-known/oauth-protected-resource')
    end

    it 'handles non-default ports correctly' do
      provider = described_class.new(server_url: 'https://api.example.com:8443/mcp')

      discovery_url = provider.send(:build_discovery_url, provider.server_url)
      expect(discovery_url).to eq('https://api.example.com:8443/.well-known/oauth-protected-resource')
    end
  end

  describe '#access_token' do
    context 'when no token is stored' do
      before do
        allow(storage).to receive(:get_token).with(server_url).and_return(nil)
      end

      it 'returns nil' do
        expect(oauth_provider.access_token).to be_nil
      end
    end

    context 'when valid token is stored' do
      let(:token) do
        MCPClient::Auth::Token.new(
          access_token: 'valid_token',
          expires_in: 3600
        )
      end

      before do
        allow(storage).to receive(:get_token).with(server_url).and_return(token)
      end

      it 'returns the token' do
        expect(oauth_provider.access_token).to eq(token)
      end
    end

    context 'when expired token with refresh token is stored' do
      let(:expired_token) do
        token = MCPClient::Auth::Token.new(
          access_token: 'expired_token',
          expires_in: 3600,
          refresh_token: 'refresh123'
        )
        # Manually set expiration to past
        token.instance_variable_set(:@expires_at, Time.now - 1)
        token
      end

      before do
        allow(storage).to receive(:get_token).with(server_url).and_return(expired_token)
        allow(oauth_provider).to receive(:refresh_token).with(expired_token).and_return(nil)
      end

      it 'attempts to refresh the token' do
        oauth_provider.access_token
        expect(oauth_provider).to have_received(:refresh_token).with(expired_token)
      end
    end
  end

  describe '#apply_authorization' do
    let(:request) { instance_double('Faraday::Request', headers: {}) }

    context 'when access token is available' do
      let(:token) do
        MCPClient::Auth::Token.new(
          access_token: 'test_token',
          token_type: 'Bearer'
        )
      end

      before do
        allow(oauth_provider).to receive(:access_token).and_return(token)
      end

      it 'adds Authorization header' do
        oauth_provider.apply_authorization(request)
        expect(request.headers['Authorization']).to eq('Bearer test_token')
      end
    end

    context 'when no access token is available' do
      before do
        allow(oauth_provider).to receive(:access_token).and_return(nil)
      end

      it 'does not add Authorization header' do
        oauth_provider.apply_authorization(request)
        expect(request.headers).not_to have_key('Authorization')
      end
    end
  end

  describe '#handle_unauthorized_response' do
    let(:response) { instance_double('Faraday::Response') }

    context 'when WWW-Authenticate header contains resource metadata URL' do
      let(:www_authenticate) { 'Bearer resource="https://example.com/.well-known/oauth-protected-resource"' }

      before do
        allow(response).to receive(:headers).and_return('WWW-Authenticate' => www_authenticate)
        allow(oauth_provider).to receive(:fetch_resource_metadata).and_return(
          MCPClient::Auth::ResourceMetadata.new(
            resource: 'https://example.com',
            authorization_servers: ['https://auth.example.com']
          )
        )
      end

      it 'fetches and returns resource metadata' do
        result = oauth_provider.handle_unauthorized_response(response)
        expect(result).to be_a(MCPClient::Auth::ResourceMetadata)
        expect(result.authorization_servers).to include('https://auth.example.com')
      end
    end

    context 'when WWW-Authenticate header is missing' do
      before do
        allow(response).to receive(:headers).and_return({})
      end

      it 'returns nil' do
        result = oauth_provider.handle_unauthorized_response(response)
        expect(result).to be_nil
      end
    end
  end

  describe '#exchange_authorization_code' do
    let(:storage_instance) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }
    let(:logger) { instance_double('Logger') }
    let(:provider) do
      described_class.new(
        server_url: 'https://3d4834530bf2.ngrok.app/mcp',
        redirect_uri: redirect_uri,
        logger: logger,
        storage: storage_instance
      )
    end
    let(:http_client) { double('Faraday::Connection') }
    let(:server_metadata) do
      instance_double(
        'MCPClient::Auth::ServerMetadata',
        token_endpoint: 'https://tropic-dev.us.auth0.com/oauth/token'
      )
    end
    let(:client_metadata) do
      MCPClient::Auth::ClientMetadata.new(
        redirect_uris: [redirect_uri],
        token_endpoint_auth_method: 'client_secret_post'
      )
    end
    let(:client_info) do
      MCPClient::Auth::ClientInfo.new(
        client_id: 'client123',
        client_secret: 'secret456',
        metadata: client_metadata
      )
    end
    let(:pkce) { instance_double('MCPClient::Auth::PKCE', code_verifier: 'verifier123') }
    let(:requests) { [] }
    let(:error_body) do
      {
        error: 'unauthorized_client',
        error_description: 'The redirect URI is wrong. You sent http://localhost:8080, and we expected https://3d4834530bf2.ngrok.app'
      }.to_json
    end
    let(:success_body) do
      {
        access_token: 'access-token',
        token_type: 'Bearer'
      }.to_json
    end
    let(:error_response) do
      instance_double('Faraday::Response', success?: false, status: 403, body: error_body)
    end
    let(:success_response) do
      instance_double('Faraday::Response', success?: true, status: 200, body: success_body)
    end

    before do
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:debug)

      provider.instance_variable_set(:@http_client, http_client)
      queue = [error_response, success_response]

      allow(http_client).to receive(:post) do |url, &block|
        expect(url).to eq(server_metadata.token_endpoint)

        request = Struct.new(:headers, :body).new({}, nil)
        block.call(request)
        requests << request.body

        response = queue.shift
        raise 'No response stubbed for token request' unless response

        response
      end
    end

    it 'retries token exchange with server-provided redirect URI when mismatch occurs' do
      token = provider.send(:exchange_authorization_code, server_metadata, client_info, 'auth-code', pkce)

      expect(token.access_token).to eq('access-token')
      expect(requests.length).to eq(2)
      expect(requests.first).to include('redirect_uri=http%3A%2F%2Flocalhost%3A8080%2Fcallback')
      expect(requests.last).to include('redirect_uri=https%3A%2F%2F3d4834530bf2.ngrok.app')
      expected_message = "Token exchange failed: redirect_uri mismatch. Retrying with server's expected value: " \
                         'https://3d4834530bf2.ngrok.app'
      expect(logger).to have_received(:warn).with(expected_message)
    end
  end
end
