# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::OAuthClient do
  let(:server_url) { 'https://mcp.example.com' }
  let(:logger) { instance_double('Logger') }

  before do
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
    allow(logger).to receive(:progname=)
    allow(logger).to receive(:formatter=)
  end

  describe '.create_http_server' do
    it 'creates an OAuth-enabled HTTP server' do
      server = described_class.create_http_server(
        server_url: server_url,
        logger: logger
      )

      expect(server).to be_a(MCPClient::ServerHTTP)
      oauth_provider = server.instance_variable_get(:@oauth_provider)
      expect(oauth_provider).to be_a(MCPClient::Auth::OAuthProvider)
      expect(oauth_provider.server_url).to eq(server_url)
    end

    it 'passes through configuration options' do
      server = described_class.create_http_server(
        server_url: server_url,
        redirect_uri: 'http://localhost:9000/callback',
        scope: 'read write',
        endpoint: '/api/mcp',
        name: 'test-server',
        logger: logger
      )

      oauth_provider = server.instance_variable_get(:@oauth_provider)
      expect(oauth_provider.redirect_uri).to eq('http://localhost:9000/callback')
      expect(oauth_provider.scope).to eq('read write')
      expect(server.endpoint).to eq('/api/mcp')
    end
  end

  describe '.create_streamable_http_server' do
    it 'creates an OAuth-enabled Streamable HTTP server' do
      server = described_class.create_streamable_http_server(
        server_url: server_url,
        logger: logger
      )

      expect(server).to be_a(MCPClient::ServerStreamableHTTP)
      oauth_provider = server.instance_variable_get(:@oauth_provider)
      expect(oauth_provider).to be_a(MCPClient::Auth::OAuthProvider)
      expect(oauth_provider.server_url).to eq(server_url)
    end
  end

  describe '.start_oauth_flow' do
    let(:oauth_provider) { instance_double('MCPClient::Auth::OAuthProvider') }
    let(:server) { instance_double('MCPClient::ServerHTTP') }

    before do
      allow(server).to receive(:instance_variable_get).with(:@oauth_provider).and_return(oauth_provider)
      allow(oauth_provider).to receive(:start_authorization_flow).and_return('https://auth.example.com/authorize?...')
    end

    it 'starts OAuth flow for server' do
      result = described_class.start_oauth_flow(server)
      expect(result).to eq('https://auth.example.com/authorize?...')
      expect(oauth_provider).to have_received(:start_authorization_flow)
    end

    it 'raises error if server has no OAuth provider' do
      allow(server).to receive(:instance_variable_get).with(:@oauth_provider).and_return(nil)

      expect do
        described_class.start_oauth_flow(server)
      end.to raise_error(ArgumentError, 'Server does not have OAuth provider configured')
    end
  end

  describe '.complete_oauth_flow' do
    let(:oauth_provider) { instance_double('MCPClient::Auth::OAuthProvider') }
    let(:server) { instance_double('MCPClient::ServerHTTP') }
    let(:token) { instance_double('MCPClient::Auth::Token') }

    before do
      allow(server).to receive(:instance_variable_get).with(:@oauth_provider).and_return(oauth_provider)
      allow(oauth_provider).to receive(:complete_authorization_flow).and_return(token)
    end

    it 'completes OAuth flow for server' do
      result = described_class.complete_oauth_flow(server, 'auth_code', 'state123')
      expect(result).to eq(token)
      expect(oauth_provider).to have_received(:complete_authorization_flow).with('auth_code', 'state123')
    end

    it 'raises error if server has no OAuth provider' do
      allow(server).to receive(:instance_variable_get).with(:@oauth_provider).and_return(nil)

      expect do
        described_class.complete_oauth_flow(server, 'auth_code', 'state123')
      end.to raise_error(ArgumentError, 'Server does not have OAuth provider configured')
    end
  end

  describe '.valid_token?' do
    let(:oauth_provider) { instance_double('MCPClient::Auth::OAuthProvider') }
    let(:server) { instance_double('MCPClient::ServerHTTP') }

    before do
      allow(server).to receive(:instance_variable_get).with(:@oauth_provider).and_return(oauth_provider)
    end

    context 'when server has valid token' do
      let(:token) { instance_double('MCPClient::Auth::Token', expired?: false) }

      before do
        allow(oauth_provider).to receive(:access_token).and_return(token)
      end

      it 'returns true' do
        expect(described_class.valid_token?(server)).to be true
      end
    end

    context 'when server has expired token' do
      let(:token) { instance_double('MCPClient::Auth::Token', expired?: true) }

      before do
        allow(oauth_provider).to receive(:access_token).and_return(token)
      end

      it 'returns false' do
        expect(described_class.valid_token?(server)).to be false
      end
    end

    context 'when server has no token' do
      before do
        allow(oauth_provider).to receive(:access_token).and_return(nil)
      end

      it 'returns false' do
        expect(described_class.valid_token?(server)).to eq(false)
      end
    end

    context 'when server has no OAuth provider' do
      before do
        allow(server).to receive(:instance_variable_get).with(:@oauth_provider).and_return(nil)
      end

      it 'returns false' do
        expect(described_class.valid_token?(server)).to be false
      end
    end
  end
end
