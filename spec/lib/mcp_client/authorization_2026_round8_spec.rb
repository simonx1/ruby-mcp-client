# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, eighth review round: a dynamic client whose
# authorization server was never cached is never adopted for the server
# discovery finds, even when storage cannot forget it, and serialized
# ClientInfo records are read back like every other record.
RSpec.describe 'MCP 2026-07-28 authorization — round 8' do
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

  def discovering(provider, meta)
    resource = MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [meta.issuer])
    allow(provider).to receive(:fetch_resource_metadata).and_return(resource)
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
  end

  def legacy_dynamic_client
    MCPClient::Auth::ClientInfo.new(client_id: 'dyn-old', client_secret: 'old-secret', client_id_issued_at: 1,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]))
  end

  # A backend with the documented interface only, which refuses nil records.
  def sticky_storage
    Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
      undef_method :delete_token if method_defined?(:delete_token)
      undef_method :delete_client_info if method_defined?(:delete_client_info)

      def set_token(url, token)
        raise ArgumentError, 'token required' if token.nil?

        super
      end

      def set_client_info(url, info)
        raise ArgumentError, 'client info required' if info.nil?

        super
      end
    end.new
  end

  # A backend that persists plain hashes for every record.
  def serializing_storage
    Class.new(MCPClient::Auth::OAuthProvider::MemoryStorage) do
      def set_server_metadata(url, metadata) = super(url, metadata.to_h)
      def set_client_info(url, info) = super(url, info&.to_h)
      def set_token(url, token) = super(url, token&.to_h)
    end.new
  end

  it 'never adopts an unbound dynamic client for a just-discovered server when storage cannot forget it' do
    storage = sticky_storage
    storage.set_client_info(server_url, legacy_dynamic_client)
    provider = provider_for(storage)
    discovering(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    registration = stub_request(:post, 'https://auth.example.com/register')
                   .to_return(status: 201, headers: json, body: { client_id: 'dyn-new' }.to_json)

    url = provider.start_authorization_flow

    expect(registration).to have_been_requested
    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn-new')
    expect(storage.get_client_info(server_url).client_secret).to be_nil
  end

  it 'reads serialized client records back through from_h' do
    storage = serializing_storage
    storage.set_client_info(server_url, legacy_dynamic_client)
    provider = provider_for(storage)
    discovering(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    registration = stub_request(:post, 'https://auth.example.com/register')
                   .to_return(status: 201, headers: json, body: { client_id: 'dyn-new' }.to_json)

    url = provider.start_authorization_flow

    expect(registration).to have_been_requested
    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn-new')
  end

  it 'completes a flow with serialized pre-registered credentials' do
    storage = serializing_storage
    storage.set_server_metadata(server_url, as_meta)
    storage.set_client_info(server_url, MCPClient::Auth::ClientInfo.new(
                                          client_id: 'pre-registered',
                                          metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                                        ))
    provider = provider_for(storage)
    stub_request(:post, 'https://auth.example.com/token')
      .to_return(status: 200, headers: json,
                 body: { access_token: 'fresh', token_type: 'Bearer', expires_in: 3600 }.to_json)

    url = provider.start_authorization_flow
    state = URI.decode_www_form(URI.parse(url).query).to_h['state']

    expect(provider.complete_authorization_flow('code', state).access_token).to eq('fresh')
  end
end
