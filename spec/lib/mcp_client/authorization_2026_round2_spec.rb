# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, second review round: the authorization
# server the code is redeemed at must be the one recorded for the request
# (RFC 9207 mix-up protection), metadata issuers must match the identifier
# they were fetched for (RFC 8414 Section 3.3), tokens are bound to their
# issuer, and error responses are state-bound and sanitized.
RSpec.describe 'MCP 2026-07-28 authorization — round 2' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  # Every authorization server here accepts Client ID Metadata Documents
  # unless a test says otherwise (a portable client is reused only there).
  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'],
                                        client_id_metadata_document_supported: true, **extra)
  end

  def provider_for(**opts)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: storage, **opts)
  end

  def stub_discovery(provider, meta, advertised: meta.issuer)
    resource = MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [advertised])
    allow(provider).to receive(:fetch_resource_metadata).and_return(resource)
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
  end

  def switch_authorization_server(provider, meta)
    provider.instance_variable_set(
      :@challenge_resource_metadata,
      MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [meta.issuer])
    )
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
  end

  def client_info(client_id: 'pre-registered', **opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  def stub_token_endpoint(issuer)
    stub_request(:post, "#{issuer}/token")
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: { access_token: 'tok', token_type: 'Bearer', expires_in: 3600, refresh_token: 'r' }.to_json)
  end

  it 'rejects authorization server metadata whose issuer differs from the identifier it was fetched for' do
    storage.set_client_info(server_url, client_info)
    provider = provider_for
    stub_discovery(provider, as_meta(issuer: 'https://honest.example'), advertised: 'https://attacker.example')

    expect { provider.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError, /issuer/)
    expect(storage.get_server_metadata(server_url)).to be_nil
  end

  it 'exchanges the code only with the authorization server recorded for the request' do
    storage.set_client_info(server_url, client_info(registration_type: 'cimd'))
    provider = provider_for
    stub_discovery(provider, as_meta)
    provider.start_authorization_flow
    state = storage.get_state(server_url)
    switch_authorization_server(provider, as_meta(issuer: 'https://evil.example'))
    evil = stub_token_endpoint('https://evil.example')

    expect { provider.complete_authorization_flow('code', state, iss: 'https://auth.example.com') }
      .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed/)
    expect { provider.complete_authorization_flow('code', state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed/)
    expect(evil).not_to have_been_requested
  end

  it 'fails closed for a request without a recorded issuer even when iss is absent' do
    storage.set_client_info(server_url, client_info)
    provider = provider_for
    stub_discovery(provider, as_meta)
    provider.start_authorization_flow
    state = storage.get_state(server_url)
    storage.set_pkce(server_url, MCPClient::Auth::PKCE.new)
    token = stub_token_endpoint('https://auth.example.com')

    expect { provider.complete_authorization_flow('code', state) }
      .to raise_error(MCPClient::Errors::ConnectionError, /no issuer was recorded/)
    expect(token).not_to have_been_requested
  end

  it 'records the issuer on the token and does not refresh it at a different authorization server' do
    storage.set_client_info(server_url, client_info(registration_type: 'cimd'))
    provider = provider_for
    stub_discovery(provider, as_meta)
    provider.start_authorization_flow
    stub_token_endpoint('https://auth.example.com')
    token = provider.complete_authorization_flow('code', storage.get_state(server_url), iss: 'https://auth.example.com')
    expect(token.issuer).to eq('https://auth.example.com')
    expect(MCPClient::Auth::Token.from_h(token.to_h).issuer).to eq('https://auth.example.com')

    expired = MCPClient::Auth::Token.new(access_token: 'old', expires_in: 0, refresh_token: 'r',
                                         issuer: 'https://auth.example.com')
    storage.set_token(server_url, expired)
    switch_authorization_server(provider, as_meta(issuer: 'https://other.example.com'))
    other = stub_token_endpoint('https://other.example.com')

    expect(provider.access_token).to be_nil
    expect(other).not_to have_been_requested
  end

  it 'drops the token together with mismatched dynamic credentials' do
    storage.set_client_info(server_url, client_info(issuer: 'https://old.example.com', registration_type: 'dynamic'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old'))
    provider = provider_for
    stub_discovery(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    stub_request(:post, 'https://auth.example.com/register')
      .to_return(status: 201, headers: { 'Content-Type' => 'application/json' }, body: { client_id: 'new' }.to_json)

    provider.start_authorization_flow

    expect(storage.get_token(server_url)).to be_nil
  end

  it 'tolerates a storage backend that only implements the documented get/set interface' do
    backend = Class.new do
      def initialize
        @data = Hash.new { |h, k| h[k] = {} }
      end

      def get_token(url) = @data[:token][url]

      def set_token(url, token)
        raise ArgumentError, 'token required' if token.nil?

        @data[:token][url] = token
      end

      def get_client_info(url) = @data[:client][url]
      def set_client_info(url, info) = @data[:client][url] = info
      def get_server_metadata(url) = @data[:metadata][url]
      def set_server_metadata(url, metadata) = @data[:metadata][url] = metadata
      def get_pkce(url) = @data[:pkce][url]
      def set_pkce(url, pkce) = @data[:pkce][url] = pkce
      def delete_pkce(url) = @data[:pkce].delete(url)
      def get_state(url) = @data[:state][url]
      def set_state(url, state) = @data[:state][url] = state
      def delete_state(url) = @data[:state].delete(url)
    end.new
    backend.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    backend.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old', issuer: 'https://old.example.com'))
    backend.set_client_info(server_url, client_info(registration_type: 'cimd'))
    output = StringIO.new
    provider = provider_for(storage: backend, logger: Logger.new(output))
    switch_authorization_server(provider, as_meta)

    expect { provider.start_authorization_flow }.not_to raise_error
    expect(output.string).to match(/delete_token/)
    expect(provider.access_token).to be_nil
  end

  it 'binds legacy credentials as pre-registered unless they look dynamically registered' do
    storage.set_client_info(server_url, client_info)
    provider = provider_for
    stub_discovery(provider, as_meta)
    provider.start_authorization_flow
    expect(storage.get_client_info(server_url).registration_type).to eq('pre_registered')

    switch_authorization_server(provider, as_meta(issuer: 'https://other.example.com',
                                                  registration_endpoint: 'https://other.example.com/register'))
    expect { provider.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError, /Pre-registered/)

    storage2 = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage2.set_client_info(server_url, client_info(client_id: 'dyn', client_id_issued_at: 1_700_000_000))
    provider2 = provider_for(storage: storage2)
    stub_discovery(provider2, as_meta)
    provider2.start_authorization_flow
    expect(storage2.get_client_info(server_url).registration_type).to eq('dynamic')
  end

  it 'treats an application_type given through client_metadata as the explicit choice' do
    bodies = []
    stub_request(:post, 'https://auth.example.com/register').to_return do |request|
      bodies << JSON.parse(request.body)
      { status: 400, headers: { 'Content-Type' => 'application/json' },
        body: { error: 'invalid_redirect_uri' }.to_json }
    end
    provider = provider_for(redirect_uri: 'https://app.example.com/cb',
                            client_metadata: { application_type: 'native', client_name: 'App' })
    stub_discovery(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))

    expect(provider.application_type).to eq('native')
    expect { provider.start_authorization_flow }
      .to raise_error(MCPClient::Errors::ConnectionError, /invalid_redirect_uri/)
    # The host chose the type: it is sent as given and not retried as web.
    expect(bodies.map { |b| b['application_type'] }).to eq(%w[native])
    expect(bodies.first['client_name']).to eq('App')
  end

  it 'refuses an error callback whose state does not match and sanitizes the description it shows' do
    storage.set_client_info(server_url, client_info)
    provider = provider_for
    stub_discovery(provider, as_meta)
    provider.start_authorization_flow
    state = storage.get_state(server_url)

    expect do
      provider.authorization_error_message('error' => 'access_denied', 'error_description' => 'Visit evil',
                                           'iss' => 'https://auth.example.com', 'state' => 'forged')
    end.to raise_error(MCPClient::Errors::ConnectionError) { |e|
      expect(e.message).to match(/state/)
      expect(e.message).not_to include('Visit evil')
    }
    description = ['denied', 'WARN forged'].join("\n")
    expect(provider.authorization_error_message('error' => 'access_denied', 'error_description' => description,
                                                'iss' => 'https://auth.example.com', 'state' => state))
      .to eq('denied WARN forged')
  end
end
