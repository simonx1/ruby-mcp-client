# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twenty-fourth round: a token retired while a
# pending challenge is resolved is never written back, so it stays retired
# for a new provider on the same storage.
RSpec.describe 'MCP 2026-07-28 authorization — round 24' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }

  def as_meta(issuer:)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'])
  end

  def provider_for(storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: 'http://localhost:1/cb',
                                       logger: logger, storage: storage)
  end

  # A backend with the documented interface only, which refuses nil records.
  def sticky_storage
    Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
      undef_method :delete_token if method_defined?(:delete_token)

      def set_token(url, token)
        raise ArgumentError, 'token required' if token.nil?

        super
      end
    end.new
  end

  [['MemoryStorage', :memory], ['a backend that cannot delete', :sticky]].each do |label, kind|
    it "keeps an issuer-less token retired across providers when a pending challenge switches servers (#{label})" do
      storage = kind == :memory ? MCPClient::Auth::OAuthProvider::MemoryStorage.new : sticky_storage
      storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
      storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'legacy-tok', expires_in: 3600))
      provider = provider_for(storage)
      stub_request(:get, prm_url).to_return(status: 502)
      headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }
      begin
        provider.handle_unauthorized_response(instance_double(Faraday::Response, status: 401, headers: headers))
      rescue MCPClient::Errors::ConnectionError
        nil
      end
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => ['https://auth.example.com'] }.to_json)

      expect(provider.access_token).to be_nil

      stored = storage.get_token(server_url)
      expect(stored.nil? || stored.retired?).to be(true), "token was written back as #{stored&.issuer}"
      expect(provider_for(storage).access_token).to be_nil
    end
  end
end
