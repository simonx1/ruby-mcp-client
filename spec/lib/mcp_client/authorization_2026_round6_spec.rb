# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, sixth review round: an authorization server
# switch lands even when storage refuses to forget the dynamic client, an
# issuer-less token is bound to the authorization server it was stored
# under on first read, and a bound token is not presented while the
# authorization server is unknown.
RSpec.describe 'MCP 2026-07-28 authorization — round 6' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def provider_for(storage, **opts)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: storage, **opts)
  end

  def switch_authorization_server(provider, meta)
    provider.instance_variable_set(
      :@challenge_resource_metadata,
      MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [meta.issuer])
    )
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
  end

  def client_info(client_id: 'dyn-old', **opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id, client_id_issued_at: Time.now.to_i - 60,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  # A backend with the documented interface only, which refuses nil records.
  def sticky_storage
    Class.new do
      def initialize
        @data = Hash.new { |h, k| h[k] = {} }
      end

      def get_token(url) = @data[:token][url]

      def set_token(url, token)
        raise ArgumentError, 'token required' if token.nil?

        @data[:token][url] = token
      end

      def get_client_info(url) = @data[:client][url]

      def set_client_info(url, info)
        raise ArgumentError, 'client info required' if info.nil?

        @data[:client][url] = info
      end

      def get_server_metadata(url) = @data[:metadata][url]
      def set_server_metadata(url, metadata) = @data[:metadata][url] = metadata
      def get_pkce(url) = @data[:pkce][url]
      def set_pkce(url, pkce) = @data[:pkce][url] = pkce
      def delete_pkce(url) = @data[:pkce].delete(url)
      def get_state(url) = @data[:state][url]
      def set_state(url, state) = @data[:state][url] = state
      def delete_state(url) = @data[:state].delete(url)
    end.new
  end

  it 'lands the authorization server switch when storage refuses to forget the dynamic client' do
    storage = sticky_storage
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(issuer: 'https://old.example.com', registration_type: 'dynamic'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old', expires_in: 3600,
                                                             issuer: 'https://old.example.com'))
    provider = provider_for(storage)
    switch_authorization_server(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    stub_request(:post, 'https://auth.example.com/register')
      .to_return(status: 201, headers: json, body: { client_id: 'dyn-new' }.to_json)

    url = provider.start_authorization_flow

    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn-new')
    expect(storage.get_server_metadata(server_url).issuer).to eq('https://auth.example.com')
    expect(provider_for(storage).access_token).to be_nil
  end

  it 'binds an issuer-less token to the authorization server it was stored under on first read' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta)
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'legacy', expires_in: 3600))

    expect(provider_for(storage).access_token&.access_token).to eq('legacy')
    expect(storage.get_token(server_url).issuer).to eq('https://auth.example.com')

    storage.set_server_metadata(server_url, as_meta(issuer: 'https://other.example.com'))
    expect(provider_for(storage).access_token).to be_nil
  end

  it 'rejects an error response when no state is stored for a flow' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta)
    provider = provider_for(storage)

    expect { provider.authorization_error_message('error' => 'access_denied', 'error_description' => 'forged') }
      .to raise_error(MCPClient::Errors::ConnectionError, /state/)
  end

  it 'does not present a bound token while the authorization server is unknown' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'bound', expires_in: 3600,
                                                             issuer: 'https://auth.example.com'))
    refresh = stub_request(:post, 'https://auth.example.com/token')

    expect(provider_for(storage).access_token).to be_nil
    expect(refresh).not_to have_been_requested

    storage.set_server_metadata(server_url, as_meta)
    expect(provider_for(storage).access_token&.access_token).to eq('bound')
  end
end
