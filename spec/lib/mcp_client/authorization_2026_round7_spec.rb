# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'mcp_client/auth/browser_oauth'

# MCP 2026-07-28 authorization, seventh review round: pre-upgrade records
# whose authorization server was never cached are retired rather than bound
# to whatever discovery finds, the browser callback is validated before the
# success page is sent, and loopback redirect URIs are recognized
# semantically.
RSpec.describe 'MCP 2026-07-28 authorization — round 7' do
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

  it 'retires pre-upgrade tokens and dynamic clients when no authorization server was cached' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_client_info(server_url, MCPClient::Auth::ClientInfo.new(
                                          client_id: 'dyn-old', client_secret: 'secret', client_id_issued_at: 1,
                                          metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                                        ))
    storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'legacy', expires_in: 3600,
                                                             refresh_token: 'r'))
    provider = provider_for(storage)
    discovering(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
    registration = stub_request(:post, 'https://auth.example.com/register')
                   .to_return(status: 201, headers: json, body: { client_id: 'dyn-new' }.to_json)
    refresh = stub_request(:post, 'https://auth.example.com/token')

    url = provider.start_authorization_flow

    expect(registration).to have_been_requested
    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('dyn-new')
    expect(provider.access_token).to be_nil
    expect(refresh).not_to have_been_requested
  end

  it 'keeps pre-registered credentials configured by the host when no authorization server was cached' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_client_info(server_url, MCPClient::Auth::ClientInfo.new(
                                          client_id: 'pre-registered', registration_type: 'pre_registered',
                                          metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                                        ))
    provider = provider_for(storage)
    discovering(provider, as_meta)

    url = provider.start_authorization_flow

    expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq('pre-registered')
    expect(storage.get_client_info(server_url).issuer).to eq('https://auth.example.com')
  end

  it 'recognizes loopback redirect URIs semantically' do
    %w[http://127.0.0.2:8080/callback http://[0:0:0:0:0:0:0:1]:8080/callback http://127.1.2.3/cb
       http://localhost:9/cb com.example.app://oauth].each do |uri|
      provider = provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new, redirect_uri: uri)
      expect(provider.send(:resolved_application_type)).to eq('native'), uri
    end
    %w[https://app.example.com/callback https://10.0.0.1/callback].each do |uri|
      provider = provider_for(MCPClient::Auth::OAuthProvider::MemoryStorage.new, redirect_uri: uri)
      expect(provider.send(:resolved_application_type)).to eq('web'), uri
    end
  end

  it 'validates a success callback before answering the browser' do
    storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new
    storage.set_server_metadata(server_url, as_meta(authorization_response_iss_parameter_supported: true))
    storage.set_client_info(server_url, MCPClient::Auth::ClientInfo.new(
                                          client_id: 'pre-registered',
                                          metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                                        ))
    provider = provider_for(storage)
    browser = MCPClient::Auth::BrowserOAuth.new(provider, logger: logger)
    tcp_server = instance_double(TCPServer)
    client_socket = instance_double(TCPSocket)
    allow(TCPServer).to receive(:new).and_return(tcp_server)
    allow(tcp_server).to receive(:wait_readable).and_return(tcp_server)
    allow(tcp_server).to receive(:accept).and_return(client_socket)
    allow(tcp_server).to receive(:close)
    allow(client_socket).to receive(:setsockopt)
    allow(client_socket).to receive(:close)
    responses = []
    allow(client_socket).to receive(:print) { |data| responses << data }
    # A code with the right state but the wrong issuer: RFC 9207 rejects it.
    lines = nil
    allow(client_socket).to receive(:gets) do
      state = storage.get_state(server_url)
      lines ||= ["GET /callback?code=abc&state=#{state}&iss=https%3A%2F%2Fevil.example HTTP/1.1\r\n", "\r\n", nil]
      lines.shift
    end

    expect { browser.authenticate(timeout: 1, auto_open_browser: false) }
      .to raise_error(MCPClient::Errors::ConnectionError, /iss/)
    expect(responses.join).to include('HTTP/1.1 400')
    expect(responses.join).not_to include('HTTP/1.1 200')
  end
end
