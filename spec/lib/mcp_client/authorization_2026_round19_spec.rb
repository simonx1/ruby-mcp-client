# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, nineteenth review round: a challenge naming
# the authorization server a stored token is already bound to retires
# nothing.
RSpec.describe 'MCP 2026-07-28 authorization — round 19' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

  def as_meta(issuer:)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'])
  end

  def sticky_storage
    Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
      undef_method :delete_token if method_defined?(:delete_token)

      def set_token(url, token)
        raise ArgumentError, 'token required' if token.nil?

        super
      end
    end.new
  end

  def challenge(provider, issuer)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => [issuer] }.to_json)
    headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
    provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
  end

  [['MemoryStorage', -> { MCPClient::Auth::OAuthProvider::MemoryStorage.new }],
   ['a backend that cannot delete', -> {}]].each do |label, factory|
    it "keeps a token already bound to the advertised authorization server (#{label})" do
      storage = factory.call || sticky_storage
      storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
      storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'new', expires_in: 3600,
                                                               issuer: 'https://auth.example.com'))
      provider = MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: 'http://localhost:1/cb',
                                                    logger: logger, storage: storage)
      allow(provider).to receive(:fetch_server_metadata).and_return(as_meta(issuer: 'https://auth.example.com'))

      challenge(provider, 'https://auth.example.com')

      expect(storage.get_token(server_url).issuer).to eq('https://auth.example.com')
      expect(provider.instance_variable_get(:@retired_tokens)).to be_nil.or be_empty
      # Presented once discovery confirmed the advertised server.
      provider.send(:discover_authorization_server)
      expect(provider.access_token&.access_token).to eq('new')
    end
  end

  it 'still retires a token of the previous authorization server' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old', expires_in: 3600,
                                                             issuer: 'https://old.example.com'))
    provider = MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: 'http://localhost:1/cb',
                                                  logger: logger, storage: storage)

    challenge(provider, 'https://auth.example.com')

    expect(provider.access_token).to be_nil
  end
end
