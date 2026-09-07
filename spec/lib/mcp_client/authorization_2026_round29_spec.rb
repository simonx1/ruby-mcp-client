# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twenty-ninth round: the local-development
# exception is loopback-only. A configured server on a private network no
# longer turns off the HTTPS requirement or the local-address refusal for
# peer-advertised URLs, and even a loopback server only ever excuses a
# loopback peer target — never the cloud metadata endpoint or another private
# address. One definition of "loopback" now serves the SSRF classifier, the
# registered application_type and the HTTPS exception for discovered
# endpoints, so RFC 6761 '*.localhost' names and the shorthand, fully
# qualified and IPv4-mapped spellings mean the same thing everywhere.
RSpec.describe 'MCP 2026-07-28 authorization — round 29' do
  let(:logger) { Logger.new(File::NULL) }
  let(:redirect_uri) { 'http://localhost:1/cb' }

  def provider_for(server_url)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: MCPClient::Auth::OAuthProvider::MemoryStorage.new)
  end

  def deliver_challenge(provider, url)
    provider.handle_unauthorized_response(
      instance_double(Faraday::Response, headers: { 'WWW-Authenticate' => "Bearer resource_metadata=\"#{url}\"" })
    )
  end

  describe 'an MCP server on a private network' do
    # None of these is loopback: the exception was written for a developer
    # pointed at a local stack, not for every host behind a firewall.
    ['https://10.0.0.5/mcp', 'https://192.168.1.10/mcp', 'https://172.16.4.4/mcp',
     'https://app.internal/mcp', 'https://printer.local/mcp'].each do |server_url|
      context "configured as #{server_url}" do
        let(:provider) { provider_for(server_url) }

        it 'refuses a plain-HTTP peer-advertised URL' do
          expect { provider.send(:validate_peer_advertised_url!, 'https://auth.example.com/meta', 'test URL') }
            .not_to raise_error
          expect { provider.send(:validate_peer_advertised_url!, 'http://auth.example.com/meta', 'test URL') }
            .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)
        end

        it 'refuses a 401 challenge naming the cloud metadata endpoint' do
          expect { deliver_challenge(provider, 'http://169.254.169.254/latest/meta-data/') }
            .to raise_error(MCPClient::Errors::ConnectionError, /HTTPS|loopback or private/)
          expect(WebMock).not_to have_requested(:get, %r{//169\.254\.169\.254})
        end

        it "refuses a 401 challenge naming the client's own loopback" do
          expect { deliver_challenge(provider, 'http://127.0.0.1:1/secret') }
            .to raise_error(MCPClient::Errors::ConnectionError, /HTTPS|loopback or private/)
          expect { provider.send(:validate_peer_advertised_url!, 'https://127.0.0.1:1/secret', 'test URL') }
            .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
          expect(WebMock).not_to have_requested(:get, %r{//127\.0\.0\.1})
        end

        it 'refuses another private address' do
          expect { provider.send(:validate_peer_advertised_url!, 'https://10.1.2.3/meta', 'test URL') }
            .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
        end
      end
    end
  end

  describe 'an MCP server on the loopback interface' do
    # Every spelling a resolver reads as 127.0.0.0/8 or ::1, plus RFC 6761
    # '*.localhost' names (puma-dev, Caddy).
    ['http://localhost:9292/mcp', 'http://127.0.0.1:9292/mcp', 'http://127.1:9292/mcp',
     'http://[::1]:9292/mcp', 'http://localhost.:9292/mcp', 'http://app.localhost:9292/mcp'].each do |server_url|
      it "accepts a plain-HTTP loopback peer URL for #{server_url}" do
        provider = provider_for(server_url)
        ['http://127.0.0.1:9292/meta', 'http://localhost:9292/meta', 'http://[::1]:9292/meta'].each do |url|
          expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }.not_to raise_error
        end
      end
    end

    it 'still refuses a link-local or private peer target' do
      provider = provider_for('http://localhost:9292/mcp')
      ['http://169.254.169.254/latest/meta-data/', 'https://169.254.169.254/meta',
       'https://10.0.0.5/meta', 'http://192.168.1.10/meta', 'https://vault.internal/meta',
       'https://printer.local/meta'].each do |url|
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .to raise_error(MCPClient::Errors::ConnectionError, /HTTPS|loopback or private/)
      end
    end

    it 'refuses a 401 challenge naming the cloud metadata endpoint' do
      provider = provider_for('http://localhost:9292/mcp')
      expect { deliver_challenge(provider, 'http://169.254.169.254/latest/meta-data/') }
        .to raise_error(MCPClient::Errors::ConnectionError, /HTTPS|loopback or private/)
      expect(WebMock).not_to have_requested(:get, %r{//169\.254\.169\.254})
    end
  end

  describe 'the application type of a redirect URI on an RFC 6761 .localhost name' do
    let(:provider) { provider_for('https://mcp.example.com/mcp') }

    # getaddrinfo answers ::1 / 127.0.0.1 for all of these; the SSRF
    # classifier already treats them as local, and so must registration.
    ['http://app.localhost:3000/callback', 'http://app.localhost./cb',
     'http://deep.nested.localhost/cb'].each do |uri|
      it "registers #{uri} as native" do
        provider.redirect_uri = uri
        expect(provider.send(:resolved_application_type)).to eq('native')
      end
    end

    it 'still registers a remote redirect URI as web' do
      ['https://app.example.com/cb', 'https://notlocalhost/cb', 'https://app.local/cb'].each do |uri|
        provider.redirect_uri = uri
        expect(provider.send(:resolved_application_type)).to eq('web')
      end
    end
  end

  describe 'a host whose percent escapes decode to uppercase letters' do
    let(:provider) { provider_for('https://mcp.example.com/mcp') }

    # The caller downcases what the URL spells, but decoding puts the letters
    # back: '%4Cocalhost' is 'Localhost'. Hostnames are case-insensitive, so
    # the classification has to fold case after decoding, not before.
    ['https://%4Cocalhost/meta', 'https://%4C%4F%43%41%4C%48%4F%53%54/meta',
     'https://%4C%4F%43%41%4C%48%4F%53%54%2E/meta', 'https://foo.%4C%4F%43%41%4C/meta',
     'https://vault.%49%4E%54%45%52%4E%41%4C/meta', 'https://app.%4C%4Fcalhost/meta'].each do |url|
      it "refuses #{url}" do
        expect { provider.send(:validate_peer_advertised_url!, url, 'test URL') }
          .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      end
    end

    it 'registers a redirect URI on such a host as native' do
      ['http://%4Cocalhost/cb', 'http://app.%4C%4F%43%41%4C%48%4F%53%54/cb'].each do |uri|
        provider.redirect_uri = uri
        expect(provider.send(:resolved_application_type)).to eq('native')
      end
    end
  end

  describe 'the HTTPS exception for discovered authorization server endpoints' do
    let(:provider) { provider_for('http://localhost:9292/mcp') }

    ['http://127.0.0.1:9292/authorize', 'http://127.1:9292/authorize', 'http://0x7f.0.0.1:9292/authorize',
     'http://127.0.0.1.:9292/authorize', 'http://localhost.:9292/authorize', 'http://[::1]:9292/authorize',
     'http://[::ffff:127.0.0.1]:9292/authorize', 'http://app.localhost:9292/authorize'].each do |url|
      it "accepts #{url}" do
        expect { provider.send(:enforce_https!, url, 'authorization endpoint') }.not_to raise_error
      end
    end

    it 'still rejects plain HTTP on any other host' do
      ['http://auth.example.com/authorize', 'http://10.0.0.5:9292/authorize',
       'http://169.254.169.254/authorize', 'http://vault.internal/authorize'].each do |url|
        expect { provider.send(:enforce_https!, url, 'authorization endpoint') }
          .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)
      end
    end

    it 'still rejects another scheme on a loopback host' do
      expect { provider.send(:enforce_https!, 'ftp://127.1:9292/authorize', 'authorization endpoint') }
        .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)
    end

    it 'accepts server metadata whose endpoints use a loopback spelling' do
      metadata = MCPClient::Auth::ServerMetadata.new(
        issuer: 'http://127.1:9292',
        authorization_endpoint: 'http://127.1:9292/authorize',
        token_endpoint: 'http://localhost.:9292/token',
        registration_endpoint: 'http://[::ffff:127.0.0.1]:9292/register',
        code_challenge_methods_supported: ['S256']
      )

      expect { provider.send(:validate_server_metadata!, metadata) }.not_to raise_error
    end
  end
end
