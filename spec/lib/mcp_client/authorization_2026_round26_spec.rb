# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twenty-sixth round: a peer-advertised URL is
# classified by parsing its host as an address rather than by string prefixes,
# so IPv4-mapped and expanded IPv6 spellings of loopback, link-local and
# private ranges are refused too; and a refused 401 challenge withholds the
# cached bearer token, not only discovery.
RSpec.describe 'MCP 2026-07-28 authorization — round 26' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:redirect_uri) { 'http://localhost:1/cb' }

  def provider_for(storage)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                       logger: logger, storage: storage)
  end

  def challenge(url)
    { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{url}\"" }
  end

  def deliver_challenge(provider, url)
    provider.handle_unauthorized_response(instance_double(Faraday::Response, headers: challenge(url)))
  end

  describe 'address classification of a peer-advertised URL' do
    let(:provider) { provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new) }

    # Every one of these is a literal address inside the ranges the check
    # already intends to reject, spelled the way IPv6 permits.
    [
      'https://[::ffff:169.254.169.254]/latest/meta-data/',
      'https://[::ffff:127.0.0.1]/meta',
      'https://[::ffff:10.0.0.1]/meta',
      'https://[::ffff:192.168.1.1]/meta',
      'https://[::ffff:172.16.0.1]/meta',
      'https://[0:0:0:0:0:0:0:1]/meta',
      'https://[0:0:0:0:0:0:0:0]/meta',
      'https://[fd00:0:0:0:0:0:0:1]/meta',
      'https://[fe80:0:0:0:0:0:0:1]/meta',
      # inet_aton shorthand and alternate radixes: every one of these is
      # resolved to a loopback, private or link-local address.
      'https://127.1/meta',
      'https://0177.0.0.1/meta',
      'https://0x7f.0.0.1/meta',
      'https://2130706433/meta',
      'https://0xa.0.0.1/meta',
      'https://2852039166/meta'
    ].each do |url|
      it "refuses #{url}" do
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      end
    end

    it 'still accepts a public host' do
      ['https://auth.example.com/meta', 'https://8.8.8.8/meta', 'https://[2001:db8::1]/meta'].each do |url|
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .not_to raise_error
      end
    end

    it 'still refuses hosts named as local by name' do
      ['https://localhost/meta', 'https://foo.local/meta', 'https://vault.internal/meta'].each do |url|
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      end
    end
  end

  describe 'a 401 challenge naming an IPv4-mapped link-local address' do
    it 'is refused before the metadata endpoint is fetched' do
      provider = provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new)
      expect { deliver_challenge(provider, 'https://[::ffff:169.254.169.254]/latest/meta-data/') }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      expect(WebMock).not_to have_requested(:get, /169\.254\.169\.254/)
    end
  end

  describe 'protected resource metadata advertising an IPv4-mapped private address' do
    it 'is refused before the authorization server is probed' do
      provider = provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new)
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url,
                           'authorization_servers' => ['https://[::ffff:10.0.0.1]'] }.to_json)

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      expect(WebMock).not_to have_requested(:get, /10\.0\.0\.1/)
    end
  end

  describe 'a refused 401 challenge' do
    let(:storage) do
      storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
      storage.set_server_metadata(server_url,
                                  MCPClient::Auth::ServerMetadata.new(
                                    issuer: 'https://old.example.com',
                                    authorization_endpoint: 'https://old.example.com/authorize',
                                    token_endpoint: 'https://old.example.com/token',
                                    code_challenge_methods_supported: ['S256']
                                  ))
      storage.set_token(server_url,
                        MCPClient::Auth::Token.new(access_token: 'old-tok', expires_in: 3600,
                                                   issuer: 'https://old.example.com'))
      storage
    end

    it 'withholds the cached token from access_token and apply_authorization' do
      provider = provider_for(storage)
      expect(provider.access_token&.access_token).to eq('old-tok')

      expect { deliver_challenge(provider, 'http://169.254.169.254/meta') }
        .to raise_error(MCPClient::Errors::ConnectionError)

      expect(provider.access_token).to be_nil
      request = Faraday::Request.new
      request.headers = {}
      provider.apply_authorization(request)
      expect(request.headers).not_to have_key('Authorization')
    end

    it 'withholds the cached token when a pending challenge resolves to a refused document' do
      provider = provider_for(storage)
      stub_request(:get, prm_url).to_return(status: 500)

      expect { deliver_challenge(provider, prm_url) }
        .to raise_error(MCPClient::Errors::ConnectionError)

      # The retry succeeds but the document names a plain-HTTP authorization
      # server: the challenge is refused, and resolve_pending_challenge
      # swallows that so access_token must consult the latch itself.
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url,
                           'authorization_servers' => ['http://auth.example.com'] }.to_json)

      expect(provider.access_token).to be_nil
      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /HTTPS/)
    end
  end

  describe 'an authorization server record persisted before RFC 9207 was read' do
    it 'is rediscovered instead of being read as "iss not supported"' do
      storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
      # The shape the previous release persisted: no
      # authorization_response_iss_parameter_supported key at all.
      storage.set_server_metadata(server_url,
                                  { issuer: 'https://auth.example.com',
                                    authorization_endpoint: 'https://auth.example.com/authorize',
                                    token_endpoint: 'https://auth.example.com/token',
                                    code_challenge_methods_supported: ['S256'] })
      provider = provider_for(storage)
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url,
                           'authorization_servers' => ['https://auth.example.com'] }.to_json)
      stub_request(:get, 'https://auth.example.com/.well-known/oauth-authorization-server')
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => 'https://auth.example.com',
                           'authorization_endpoint' => 'https://auth.example.com/authorize',
                           'token_endpoint' => 'https://auth.example.com/token',
                           'code_challenge_methods_supported' => ['S256'],
                           'authorization_response_iss_parameter_supported' => true }.to_json)

      metadata = provider.send(:discover_authorization_server)
      expect(metadata).to be_iss_parameter_supported
      # Rediscovery happens once: the refreshed cache carries the answer.
      expect(provider.send(:discover_authorization_server)).to be_iss_parameter_supported
      expect(WebMock).to have_requested(:get, prm_url).once
    end
  end

  describe 'a speculative protected resource document whose authorization server is refused' do
    it 'no longer supplies the scopes of the next request' do
      provider = provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new)
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'scopes_supported' => ['stale:scope'],
                           'authorization_servers' => ['http://auth.example.com'] }.to_json)

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /HTTPS/)

      expect(provider.send(:resolved_scope)).to be_nil
    end
  end
end
