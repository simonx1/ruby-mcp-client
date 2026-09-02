# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twenty-eighth round: a peer-advertised host is
# percent-decoded before it is classified, so the encoded spellings of a
# loopback, private or link-local target ('169.254.169.254%2e',
# '127%2e0%2e0%2e1', '%31%32%37.0.0.1') are refused rather than dialled; a host
# that is still not a hostname after decoding is refused too; and application
# type inference reads a redirect URI's loopback host the way the resolver
# does, so '127.1' and '127.0.0.1.' register as native.
RSpec.describe 'MCP 2026-07-28 authorization — round 28' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
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

  describe 'a peer-advertised host whose local address is percent-encoded' do
    let(:provider) { provider_for }

    # URI#hostname does not decode, but the HTTP client dials the decoded
    # name: every one of these reaches the address the plain spelling reaches.
    [
      'https://169.254.169.254%2e/latest/meta-data/',
      'https://127.0.0.1%2e/meta',
      'https://10.0.0.1%2e/meta',
      'https://192.168.1.1%2e/meta',
      'https://127%2e0%2e0%2e1/meta',
      'https://169%2e254%2e169%2e254/meta',
      'https://%31%32%37.0.0.1/meta',
      'https://%31%32%37%2e%30%2e%30%2e%31/meta',
      'https://127%2e1/meta',
      'https://localhost%2e/meta',
      'https://%6cocalhost/meta',
      'https://%6c%6f%63%61%6c%68%6f%73%74/meta',
      'https://foo%2elocal%2e/meta',
      'https://vault%2einternal/meta',
      # Doubly encoded: decoding runs until the host stops changing.
      'https://127.0.0.1%252e/meta'
    ].each do |url|
      it "refuses #{url}" do
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      end
    end

    it 'still accepts a public host, encoded or not' do
      ['https://auth.example.com/meta', 'https://auth%2eexample%2ecom/meta',
       'https://8.8.8.8%2e/meta', 'https://%38%2e%38%2e%38%2e%38/meta'].each do |url|
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }.not_to raise_error
      end
    end

    it 'refuses a host that is still not a hostname after decoding' do
      ['https://ex%00ample.com/meta', 'https://%2f%2f169.254.169.254/meta'].each do |url|
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .to raise_error(MCPClient::Errors::ConnectionError, /valid host/)
      end
    end
  end

  describe 'a 401 challenge naming the metadata endpoint with an encoded host' do
    it 'is refused before the endpoint is fetched' do
      provider = provider_for
      expect { deliver_challenge(provider, 'https://169.254.169.254%2e/latest/meta-data/') }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      expect(WebMock).not_to have_requested(:get, %r{//169\.254\.169\.254})
    end
  end

  describe 'protected resource metadata advertising an encoded private address' do
    it 'is refused before the authorization server is probed' do
      provider = provider_for
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => ['https://10%2e0%2e0%2e1'] }.to_json)

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      expect(WebMock).not_to have_requested(:get, %r{//10\.0\.0\.1})
    end
  end

  describe 'the application type of a redirect URI on a loopback interface' do
    let(:provider) { provider_for }

    # The resolver reads all of these as 127.0.0.1 or ::1; a client whose
    # callback is loopback is native, however the host is spelled.
    ['http://127.1/cb', 'http://127.0.1/cb', 'http://0177.0.0.1/cb', 'http://0x7f.0.0.1/cb',
     'http://2130706433/cb', 'http://127.0.0.1./cb', 'http://localhost./cb',
     'http://[::ffff:127.0.0.1]/cb', 'http://[::127.0.0.1]/cb'].each do |uri|
      it "registers #{uri} as native" do
        provider.redirect_uri = uri
        expect(provider.send(:resolved_application_type)).to eq('native')
      end
    end

    it 'still registers a remote redirect URI as web' do
      ['https://app.example.com/cb', 'https://8.8.8.8/cb'].each do |uri|
        provider.redirect_uri = uri
        expect(provider.send(:resolved_application_type)).to eq('web')
      end
    end
  end
end
