# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twenty-seventh round: a trailing FQDN dot
# names the same host as the undotted spelling, so a peer-advertised URL
# carrying one is classified as local too; and the callback precheck reads an
# unrecorded `authorization_response_iss_parameter_supported` the way the
# completion does — as an unanswered question, not as "not supported".
RSpec.describe 'MCP 2026-07-28 authorization — round 27' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:as_url) { 'https://auth.example.com/.well-known/oauth-authorization-server' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  def deliver_challenge(provider, url)
    provider.handle_unauthorized_response(
      instance_double(Faraday::Response, headers: { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{url}\"" })
    )
  end

  describe 'a peer-advertised host spelled as a fully qualified name' do
    let(:provider) { provider_for }

    # Every one of these resolves to exactly what the undotted spelling
    # resolves to: the trailing dot only marks the name as fully qualified.
    [
      'https://169.254.169.254./latest/meta-data/',
      'https://127.0.0.1./meta',
      'https://10.0.0.1./meta',
      'https://192.168.1.1./meta',
      'https://127.1./meta',
      'https://2130706433./meta',
      'https://localhost./meta',
      'https://foo.local./meta',
      'https://vault.internal./meta'
    ].each do |url|
      it "refuses #{url}" do
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      end
    end

    it 'still accepts a public host spelled with a trailing dot' do
      ['https://auth.example.com./meta', 'https://8.8.8.8./meta'].each do |url|
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }.not_to raise_error
      end
    end
  end

  describe 'a 401 challenge naming the metadata endpoint as a fully qualified name' do
    it 'is refused before the endpoint is fetched' do
      provider = provider_for
      expect { deliver_challenge(provider, 'https://169.254.169.254./latest/meta-data/') }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      expect(WebMock).not_to have_requested(:get, %r{//169\.254\.169\.254})
    end
  end

  describe 'protected resource metadata advertising a fully qualified private address' do
    it 'is refused before the authorization server is probed' do
      provider = provider_for
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => ['https://10.0.0.1.'] }.to_json)

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      expect(WebMock).not_to have_requested(:get, %r{//10\.0\.0\.1})
    end
  end

  describe 'a callback for a flow whose iss advertisement was never recorded' do
    let(:issuer) { 'https://auth.example.com' }
    let(:state) { 'state-value' }

    before do
      # The shapes a previous release persisted: metadata without the RFC 9207
      # key at all, and a PKCE record from before the flag was recorded.
      storage.set_server_metadata(server_url,
                                  { issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                    token_endpoint: "#{issuer}/token",
                                    code_challenge_methods_supported: ['S256'] })
      storage.set_pkce(server_url,
                       MCPClient::Auth::PKCE.new(issuer: issuer, client_id: 'client-1',
                                                 redirect_uri: redirect_uri).to_h)
      storage.set_state(server_url, state)
      storage.set_client_info(server_url,
                              MCPClient::Auth::ClientInfo.new(
                                client_id: 'client-1', issuer: issuer, registration_type: 'pre_registered',
                                metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                              ))
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [issuer] }.to_json)
      stub_request(:get, as_url)
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => issuer, 'authorization_endpoint' => "#{issuer}/authorize",
                           'token_endpoint' => "#{issuer}/token",
                           'code_challenge_methods_supported' => ['S256'],
                           'authorization_response_iss_parameter_supported' => true }.to_json)
    end

    it 'rejects a success response without iss at the precheck, as the completion does' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /advertises the iss parameter/)
      expect { provider.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /advertises the iss parameter/)
      expect(WebMock).not_to have_requested(:post, "#{issuer}/token")
    end

    it 'withholds the error text of an error response without iss' do
      provider = provider_for
      expect { provider.authorization_error_message('state' => state, 'error' => 'access_denied') }
        .to raise_error(MCPClient::Errors::ConnectionError, /advertises the iss parameter/)
    end

    it 'still accepts a success response carrying the recorded issuer' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state, iss: issuer) }.not_to raise_error
      expect(provider.authorization_error_message('state' => state, 'error' => 'access_denied', 'iss' => issuer))
        .to eq('access_denied')
    end

    it 'accepts a missing iss when rediscovery says the server does not advertise it' do
      stub_request(:get, as_url)
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => issuer, 'authorization_endpoint' => "#{issuer}/authorize",
                           'token_endpoint' => "#{issuer}/token",
                           'code_challenge_methods_supported' => ['S256'] }.to_json)
      provider = provider_for
      expect { provider.validate_authorization_response!(state) }.not_to raise_error
    end
  end
end
