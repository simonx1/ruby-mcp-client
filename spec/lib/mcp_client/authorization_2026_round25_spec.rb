# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twenty-fifth round: a refusal that came from
# speculative well-known discovery does not poison the provider for good, and
# an authorization code is redeemed with the redirect URI the authorization
# request recorded (RFC 6749 Section 4.1.3) rather than one a token-endpoint
# error body named.
RSpec.describe 'MCP 2026-07-28 authorization — round 25' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }

  def provider_for(storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: storage)
  end

  def stub_prm(authorization_server)
    stub_request(:get, prm_url)
      .to_return(status: 200, headers: json,
                 body: { 'resource' => server_url, 'authorization_servers' => [authorization_server] }.to_json)
  end

  describe 'a refused well-known document' do
    it 'is fetched again on the next discovery once the server is fixed' do
      storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
      provider = provider_for(storage)
      stub_prm('http://auth.example.com')

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)

      # The operator fixes the document; the very same provider must retry it.
      stub_prm('https://auth.example.com')
      stub_request(:get, 'https://auth.example.com/.well-known/oauth-authorization-server')
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => 'https://auth.example.com',
                           'authorization_endpoint' => 'https://auth.example.com/authorize',
                           'token_endpoint' => 'https://auth.example.com/token',
                           'code_challenge_methods_supported' => ['S256'] }.to_json)

      metadata = provider.send(:discover_authorization_server)
      expect(metadata.issuer).to eq('https://auth.example.com')
    end

    it 'still fails closed for a refused 401 challenge' do
      provider = provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new)
      headers = { 'WWW-Authenticate' => 'Bearer resource_metadata="http://169.254.169.254/meta"' }

      expect { provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: headers)) }
        .to raise_error(MCPClient::Errors::ConnectionError)
      # No well-known stub is registered: a fetch here would fail the example.
      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /HTTPS|loopback or private/)
    end
  end

  describe 'an authority-less authorization server URL' do
    it 'is refused before the stored token is retired' do
      storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
      storage.set_server_metadata(server_url,
                                  MCPClient::Auth::ServerMetadata.new(
                                    issuer: 'https://old.example.com',
                                    authorization_endpoint: 'https://old.example.com/authorize',
                                    token_endpoint: 'https://old.example.com/token',
                                    code_challenge_methods_supported: ['S256']
                                  ))
      storage.set_token(server_url,
                        MCPClient::Auth::Token.new(access_token: 'tok', expires_in: 3600,
                                                   issuer: 'https://old.example.com'))
      provider = provider_for(storage)
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => ['https:foo'] }.to_json)
      headers = { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{prm_url}\"" }

      expect { provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: headers)) }
        .to raise_error(MCPClient::Errors::ConnectionError, /must name a host/)

      stored = storage.get_token(server_url)
      expect(stored&.access_token).to eq('tok')
      expect(stored.issuer).to eq('https://old.example.com')
    end
  end

  describe 'redeeming the authorization code' do
    let(:token_endpoint) { 'https://auth.example.com/token' }
    let(:server_metadata) do
      MCPClient::Auth::ServerMetadata.new(issuer: 'https://auth.example.com',
                                          authorization_endpoint: 'https://auth.example.com/authorize',
                                          token_endpoint: token_endpoint,
                                          code_challenge_methods_supported: ['S256'])
    end
    let(:client_info) do
      MCPClient::Auth::ClientInfo.new(
        client_id: 'client123',
        metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
      )
    end
    let(:mismatch_body) do
      { error: 'unauthorized_client',
        error_description: "You sent #{redirect_uri}, and we expected https://attacker.example/cb" }.to_json
    end

    it 'never substitutes a redirect_uri the token error body named' do
      provider = provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new)
      pkce = MCPClient::Auth::PKCE.new(code_verifier: 'verifier123', code_challenge: 'challenge',
                                       code_challenge_method: 'S256', issuer: 'https://auth.example.com',
                                       client_id: 'client123', redirect_uri: redirect_uri)
      request = stub_request(:post, token_endpoint).to_return(status: 400, headers: json, body: mismatch_body)

      expect { provider.send(:exchange_authorization_code, server_metadata, client_info, 'auth-code', pkce) }
        .to raise_error(MCPClient::Errors::ConnectionError, /redirect_uri/)

      expect(request).to have_been_requested.once
      expect(WebMock).not_to have_requested(:post, token_endpoint)
        .with(body: /attacker\.example/)
    end
  end
end
