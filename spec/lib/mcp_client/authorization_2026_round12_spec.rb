# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, twelfth review round: a PKCE record that
# names no client cannot bind the callback to the credentials the request
# was made with, so the flow fails closed like one without an issuer.
RSpec.describe 'MCP 2026-07-28 authorization — round 12' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def client_info(client_id: 'pre-registered', **opts)
    opts = { registration_type: 'pre_registered', issuer: 'https://auth.example.com' }.merge(opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  it 'refuses to redeem the code when the PKCE record names no client' do
    storage.set_server_metadata(server_url, as_meta)
    storage.set_client_info(server_url, client_info)
    provider = MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri,
                                                  logger: logger, storage: storage)
    url = provider.start_authorization_flow
    state = URI.decode_www_form(URI.parse(url).query).to_h['state']
    # A record persisted by an earlier version, or by a backend that kept
    # the issuer but not the client id.
    legacy = MCPClient::Auth::PKCE.from_h(storage.get_pkce(server_url).to_h.except(:client_id))
    storage.set_pkce(server_url, legacy)
    storage.set_client_info(server_url, client_info(client_id: 'swapped', client_secret: 's'))
    token_endpoint = stub_request(:post, 'https://auth.example.com/token')

    expect { provider.validate_authorization_response!(state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /no client was recorded/)
    expect { provider.complete_authorization_flow('code', state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /no client was recorded/)
    expect(token_endpoint).not_to have_been_requested
  end
end
