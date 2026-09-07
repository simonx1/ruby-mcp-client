# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 authorization, fifteenth review round: a retirement marker
# is cleared only once the token that reuses the bytes was persisted.
RSpec.describe 'MCP 2026-07-28 authorization — round 15' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }

  def as_meta(issuer: 'https://auth.example.com')
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'])
  end

  it 'keeps the retired token retired when the replacement cannot be persisted' do
    storage = Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
      attr_accessor :refuse_writes

      def set_token(url, token)
        raise IOError, 'disk full' if refuse_writes || token.nil?

        super
      end
    end.new
    storage.set_server_metadata(server_url, as_meta)
    stale = MCPClient::Auth::Token.new(access_token: 'same-bytes', expires_in: 3600,
                                       issuer: 'https://auth.example.com')
    storage.set_token(server_url, stale)
    provider = MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: 'http://localhost:1/cb',
                                                  logger: logger, storage: storage)
    # Retired in-process; the backend could not delete it, so the record stays.
    provider.send(:delete_token)
    expect(provider.access_token).to be_nil

    # The same authorization server reissues the same opaque bytes, but the
    # replacement cannot be written: the stale record must stay retired.
    storage.refuse_writes = true
    fresh = MCPClient::Auth::Token.new(access_token: 'same-bytes', expires_in: 3600, issuer: 'https://auth.example.com')
    expect { provider.send(:store_token, fresh) }.to raise_error(IOError)

    expect(provider.access_token).to be_nil
  end
end
