# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, fourth review round: token retirement
# survives a new provider on the same storage, a wrong-issuer metadata
# candidate does not end discovery, a portable client is reused only where
# Client ID Metadata Documents are supported, and issuers in credential
# errors are sanitized.
RSpec.describe 'MCP 2026-07-28 authorization — round 4' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }

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

  def client_info(client_id: 'pre-registered', **opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  # A backend with the documented interface only, which refuses to forget a token.
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
  end

  it 'keeps a retired issuer-less token retired for a new provider on the same storage' do
    storage = sticky_storage
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(registration_type: 'cimd'))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old', expires_in: 0, refresh_token: 'r'))
    first = provider_for(storage)
    switch_authorization_server(first, as_meta(client_id_metadata_document_supported: true))
    first.start_authorization_flow

    fresh = provider_for(storage)
    refresh = stub_request(:post, 'https://auth.example.com/token')

    expect(fresh.access_token).to be_nil
    expect(refresh).not_to have_been_requested
    expect(storage.get_token(server_url).issuer).to eq('https://old.example.com')
  end

  it 'keeps a token retired by a challenge for a new provider on the same storage' do
    storage = sticky_storage
    storage.set_server_metadata(server_url, as_meta)
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'alice', expires_in: 3600))
    provider = provider_for(storage)
    prm = { 'resource' => server_url, 'authorization_servers' => ['https://other.example.com'] }
    stub_request(:get, 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp')
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: prm.to_json)
    challenge = 'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp"'
    response = instance_double(Faraday::Response, status: 401, headers: { 'WWW-Authenticate' => challenge })
    provider.handle_unauthorized_response(response)

    expect(provider_for(storage).access_token).to be_nil
  end

  it 'tries the next well-known candidate when a document names another issuer' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_client_info(server_url, client_info)
    provider = provider_for(storage)
    resource = MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: ['https://auth.example.com'])
    allow(provider).to receive(:fetch_resource_metadata).and_return(resource)
    allow(provider).to receive(:fetch_server_metadata) do |url|
      url.include?('openid-configuration') ? as_meta : as_meta(issuer: 'https://other.example.com')
    end

    expect { provider.start_authorization_flow }.not_to raise_error
    expect(storage.get_server_metadata(server_url).issuer).to eq('https://auth.example.com')
  end

  it 'registers dynamically when the new authorization server does not support Client ID Metadata Documents' do
    cimd_url = 'https://app.example.com/oauth/client-metadata.json'
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(issuer: 'https://old.example.com'))
    storage.set_client_info(server_url, client_info(client_id: cimd_url, registration_type: 'cimd'))
    provider = provider_for(storage, client_id_metadata_url: cimd_url)
    switch_authorization_server(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    registration = stub_request(:post, 'https://auth.example.com/register')
                   .to_return(status: 201, headers: { 'Content-Type' => 'application/json' },
                              body: { client_id: 'dyn' }.to_json)

    url = provider.start_authorization_flow

    expect(registration).to have_been_requested
    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn')
  end

  it 'sanitizes issuers in credential mismatch errors' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    forged = ['https://old.example.com', 'WARN forged'].join("\n")
    storage.set_client_info(server_url, client_info(issuer: forged, registration_type: 'pre_registered'))
    provider = provider_for(storage)
    resource = MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: ['https://auth.example.com'])
    allow(provider).to receive(:fetch_resource_metadata).and_return(resource)
    allow(provider).to receive(:fetch_server_metadata).and_return(as_meta)

    expect { provider.start_authorization_flow }.to raise_error(MCPClient::Errors::ConnectionError) { |e|
      expect(e.message).not_to include("\nWARN forged")
    }
  end
end
