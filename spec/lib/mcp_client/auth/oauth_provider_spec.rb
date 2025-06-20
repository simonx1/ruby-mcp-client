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
end
