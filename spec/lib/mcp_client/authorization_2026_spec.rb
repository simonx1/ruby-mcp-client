# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'mcp_client/auth/browser_oauth'

# MCP 2026-07-28 authorization (basic/authorization, basic/authorization/
# client-registration, basic/authorization/authorization-server-discovery):
# - RFC 9207 issuer identification: the client records the selected
#   authorization server's issuer with the PKCE record and validates the
#   `iss` parameter of the authorization response (including error
#   responses) before the code reaches any token endpoint, keyed on
#   `authorization_response_iss_parameter_supported`, with no URL
#   normalization.
# - Dynamic Client Registration is deprecated; registrations MUST carry an
#   `application_type` (native for localhost / custom-scheme redirects).
# - Client credentials are bound to the issuing authorization server:
#   dynamic registrations are redone for a new AS, pre-registered
#   credentials surface an error, Client ID Metadata Document clients are
#   portable.
RSpec.describe 'MCP 2026-07-28 authorization' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def as_meta(issuer: 'https://auth.example.com', **extra)
    MCPClient::Auth::ServerMetadata.new(issuer: issuer, authorization_endpoint: "#{issuer}/authorize",
                                        token_endpoint: "#{issuer}/token",
                                        code_challenge_methods_supported: ['S256'], **extra)
  end

  def provider_for(**opts)
    MCPClient::Auth::OAuthProvider.new(server_url: server_url, redirect_uri: redirect_uri, logger: logger,
                                       storage: storage, **opts)
  end

  def stub_discovery(provider, meta)
    resource = MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [meta.issuer])
    allow(provider).to receive(:fetch_resource_metadata).and_return(resource)
    allow(provider).to receive(:fetch_server_metadata).and_return(meta)
  end

  # Host-provided credentials say they are pre-registered (an untyped
  # record counts as a dynamic registration since round 9).
  def client_info(client_id: 'pre-registered', **opts)
    opts = { registration_type: 'pre_registered' }.merge(opts)
    MCPClient::Auth::ClientInfo.new(client_id: client_id,
                                    metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]),
                                    **opts)
  end

  def stub_token_endpoint(issuer = 'https://auth.example.com')
    stub_request(:post, "#{issuer}/token")
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: { access_token: 'tok', token_type: 'Bearer', expires_in: 3600 }.to_json)
  end

  describe MCPClient::Auth::ServerMetadata do
    it 'parses authorization_response_iss_parameter_supported and keeps an explicit false' do
      supported = described_class.from_h('issuer' => 'https://auth.example.com',
                                         'authorization_endpoint' => 'https://auth.example.com/authorize',
                                         'token_endpoint' => 'https://auth.example.com/token',
                                         'authorization_response_iss_parameter_supported' => true)
      unsupported = described_class.from_h(issuer: 'https://auth.example.com',
                                           authorization_endpoint: 'https://auth.example.com/authorize',
                                           token_endpoint: 'https://auth.example.com/token',
                                           authorization_response_iss_parameter_supported: false)

      expect(supported.authorization_response_iss_parameter_supported).to be(true)
      expect(supported).to be_iss_parameter_supported
      expect(unsupported.authorization_response_iss_parameter_supported).to be(false)
      expect(unsupported).not_to be_iss_parameter_supported
      expect(as_meta).not_to be_iss_parameter_supported
      # A record built here (as one read from a discovery document) answers the
      # question, and its answer survives serialization.
      expect(as_meta).to be_iss_parameter_recorded
      expect(as_meta.to_h[:authorization_response_iss_parameter_supported]).to be(false)
      expect(described_class.from_h(supported.to_h)).to be_iss_parameter_supported
    end

    it 'carries no answer for a record persisted before the field was read' do
      legacy = described_class.from_h('issuer' => 'https://auth.example.com',
                                      'authorization_endpoint' => 'https://auth.example.com/authorize',
                                      'token_endpoint' => 'https://auth.example.com/token')

      expect(legacy).not_to be_iss_parameter_recorded
      # A document the authorization server itself served answers "no" by
      # staying silent (RFC 8414 default), which is recorded as such.
      fetched = described_class.from_discovery_document('issuer' => 'https://auth.example.com',
                                                        'authorization_endpoint' =>
                                                          'https://auth.example.com/authorize',
                                                        'token_endpoint' => 'https://auth.example.com/token')
      expect(fetched).to be_iss_parameter_recorded
      expect(fetched).not_to be_iss_parameter_supported
    end
  end

  describe MCPClient::Auth::PKCE do
    it 'carries the recorded issuer through serialization' do
      pkce = described_class.new(issuer: 'https://auth.example.com')
      restored = described_class.from_h(pkce.to_h)

      expect(pkce.to_h[:issuer]).to eq('https://auth.example.com')
      expect(restored.issuer).to eq('https://auth.example.com')
      expect(described_class.new.to_h).not_to have_key(:issuer)
    end
  end

  describe 'issuer recording and RFC 9207 validation' do
    it 'records the selected authorization server issuer with the PKCE record' do
      storage.set_client_info(server_url, client_info)
      provider = provider_for
      stub_discovery(provider, as_meta)

      provider.start_authorization_flow

      expect(storage.get_pkce(server_url).issuer).to eq('https://auth.example.com')
    end

    def start_flow(meta, client: client_info)
      storage.set_client_info(server_url, client)
      provider = provider_for
      stub_discovery(provider, meta)
      provider.start_authorization_flow
      [provider, storage.get_state(server_url)]
    end

    it 'exchanges the code when the advertised iss matches the recorded issuer' do
      provider, state = start_flow(as_meta(authorization_response_iss_parameter_supported: true))
      token_request = stub_token_endpoint

      token = provider.complete_authorization_flow('code', state, iss: 'https://auth.example.com')

      expect(token.access_token).to eq('tok')
      expect(token_request).to have_been_requested
    end

    it 'rejects a response without iss when the server advertises the parameter' do
      provider, state = start_flow(as_meta(authorization_response_iss_parameter_supported: true))
      token_request = stub_token_endpoint

      expect { provider.complete_authorization_flow('code', state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /iss/)
      expect(token_request).not_to have_been_requested
    end

    it 'compares a present iss even when the server does not advertise the parameter' do
      provider, state = start_flow(as_meta)
      token_request = stub_token_endpoint

      expect { provider.complete_authorization_flow('code', state, iss: 'https://evil.example.com') }
        .to raise_error(MCPClient::Errors::ConnectionError, /issuer/)
      expect(token_request).not_to have_been_requested
    end

    it 'proceeds without iss when the server does not advertise the parameter' do
      provider, state = start_flow(as_meta(authorization_response_iss_parameter_supported: false))
      stub_token_endpoint

      expect(provider.complete_authorization_flow('code', state).access_token).to eq('tok')
    end

    it 'uses simple string comparison without any URL normalization' do
      %w[https://auth.example.com/ HTTPS://auth.example.com https://AUTH.example.com
         https://auth.example.com:443 https://auth.example%2Ecom].each do |variant|
        provider, state = start_flow(as_meta)
        stub_token_endpoint

        expect { provider.complete_authorization_flow('code', state, iss: variant) }
          .to raise_error(MCPClient::Errors::ConnectionError, /issuer/), "expected #{variant} to be rejected"
      end
    end

    it 'fails closed when no issuer was recorded for the request' do
      provider, state = start_flow(as_meta)
      storage.set_pkce(server_url, MCPClient::Auth::PKCE.new)
      token_request = stub_token_endpoint

      expect { provider.complete_authorization_flow('code', state, iss: 'https://auth.example.com') }
        .to raise_error(MCPClient::Errors::ConnectionError, /issuer/)
      expect(token_request).not_to have_been_requested
    end

    it 'refuses to surface an error response whose iss does not match' do
      provider, state = start_flow(as_meta)

      expect do
        provider.authorization_error_message('error' => 'access_denied', 'error_description' => 'Try the other AS',
                                             'iss' => 'https://evil.example.com', 'state' => state)
      end.to raise_error(MCPClient::Errors::ConnectionError) { |e|
        expect(e.message).to include('issuer')
        expect(e.message).not_to include('Try the other AS')
        expect(e.message).not_to include('access_denied')
      }
    end

    it 'surfaces an error response whose iss matches (or that carries none)' do
      provider, state = start_flow(as_meta)

      expect(provider.authorization_error_message('error' => 'access_denied', 'error_description' => 'User denied',
                                                  'iss' => 'https://auth.example.com', 'state' => state))
        .to eq('User denied')
      expect(provider.authorization_error_message('error' => 'access_denied', 'state' => state))
        .to eq('access_denied')
    end
  end

  describe MCPClient::Auth::BrowserOAuth do
    def stub_callback(query)
      tcp_server = instance_double(TCPServer)
      socket = instance_double(TCPSocket)
      allow(TCPServer).to receive(:new).and_return(tcp_server)
      allow(tcp_server).to receive(:wait_readable).and_return(tcp_server)
      allow(tcp_server).to receive(:accept).and_return(socket)
      allow(tcp_server).to receive(:close)
      allow(socket).to receive(:setsockopt)
      allow(socket).to receive(:gets).and_return("GET /callback?#{query} HTTP/1.1\r\n", "\r\n", nil)
      allow(socket).to receive(:print)
      allow(socket).to receive(:close)
    end

    let(:provider) do
      instance_double(MCPClient::Auth::OAuthProvider, start_authorization_flow: 'https://auth.example.com/authorize',
                                                      redirect_uri: redirect_uri)
    end
    let(:browser) { described_class.new(provider, callback_port: 8080, logger: logger) }

    it 'passes the iss parameter of the callback to the provider' do
      stub_callback('code=abc&state=s1&iss=https%3A%2F%2Fauth.example.com')
      allow(provider).to receive(:complete_authorization_flow).and_return(:token)

      expect(browser.authenticate(timeout: 1, auto_open_browser: false)).to eq(:token)
      expect(provider).to have_received(:complete_authorization_flow)
        .with('abc', 's1', iss: 'https://auth.example.com')
    end

    it 'lets the provider validate an error callback before it is surfaced' do
      stub_callback('error=access_denied&error_description=User+denied&iss=https%3A%2F%2Fevil.example.com&state=s1')
      allow(provider).to receive(:authorization_error_message)
        .and_raise(MCPClient::Errors::ConnectionError, 'Authorization error response rejected: issuer mismatch')

      expect { browser.authenticate(timeout: 1, auto_open_browser: false) }
        .to raise_error(MCPClient::Errors::ConnectionError, /issuer mismatch/)
      expect(provider).to have_received(:authorization_error_message)
        .with(hash_including('error' => 'access_denied', 'iss' => 'https://evil.example.com'))
    end
  end

  describe 'dynamic client registration' do
    let(:registration_endpoint) { 'https://auth.example.com/register' }

    # Registration request bodies, in order, with the scripted answers.
    def registration_bodies
      @registration_bodies ||= []
    end

    def json_answer(status, body)
      { status: status, headers: { 'Content-Type' => 'application/json' }, body: body.to_json }
    end

    def registered(*answers)
      answers = [json_answer(201, { client_id: 'dyn-1' })] if answers.empty?
      stub_request(:post, registration_endpoint).to_return do |request|
        registration_bodies << JSON.parse(request.body)
        answers.size > 1 ? answers.shift : answers.first
      end
    end

    it 'registers a localhost redirect as a native application and warns that DCR is deprecated' do
      output = StringIO.new
      provider = provider_for(logger: Logger.new(output))
      stub_discovery(provider, as_meta(registration_endpoint: registration_endpoint))
      registered

      provider.start_authorization_flow

      expect(registration_bodies.first['application_type']).to eq('native')
      expect(output.string).to match(/Dynamic Client Registration is deprecated/)
    end

    it 'registers a custom-scheme redirect as native and a remote https redirect as web' do
      native = provider_for(redirect_uri: 'com.example.app://oauth/callback')
      stub_discovery(native, as_meta(registration_endpoint: registration_endpoint))
      registered
      native.start_authorization_flow

      web = provider_for(redirect_uri: 'https://app.example.com/oauth/callback',
                         storage: MCPClient::Auth::OAuthProvider::MemoryStorage.new)
      stub_discovery(web, as_meta(registration_endpoint: registration_endpoint))
      web.start_authorization_flow

      expect(registration_bodies.map { |b| b['application_type'] }).to eq(%w[native web])
    end

    it 'honours an explicit application_type' do
      provider = provider_for(application_type: 'web')
      stub_discovery(provider, as_meta(registration_endpoint: registration_endpoint))
      registered

      provider.start_authorization_flow

      expect(registration_bodies.first['application_type']).to eq('web')
    end

    it 'retries once with the other application_type when the redirect URI is rejected for it' do
      provider = provider_for
      stub_discovery(provider, as_meta(registration_endpoint: registration_endpoint))
      registered(json_answer(400, { error: 'invalid_redirect_uri',
                                    error_description: 'native clients must use loopback or custom scheme' }),
                 json_answer(201, { client_id: 'dyn-2' }))

      provider.start_authorization_flow

      expect(registration_bodies.map { |b| b['application_type'] }).to eq(%w[native web])
      expect(storage.get_client_info(server_url).client_id).to eq('dyn-2')
    end

    it 'surfaces the registration error and description when registration is rejected' do
      provider = provider_for(application_type: 'native')
      stub_discovery(provider, as_meta(registration_endpoint: registration_endpoint))
      registered(json_answer(400, { error: 'invalid_client_metadata',
                                    error_description: 'redirect_uris not allowed' }))

      expect { provider.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, /invalid_client_metadata.*redirect_uris not allowed/)
      expect(registration_bodies.size).to eq(1)
    end

    it 'binds the registered client to the issuing authorization server' do
      provider = provider_for
      stub_discovery(provider, as_meta(registration_endpoint: registration_endpoint))
      registered

      provider.start_authorization_flow

      info = storage.get_client_info(server_url)
      expect(info.issuer).to eq('https://auth.example.com')
      expect(info.registration_type).to eq('dynamic')
      expect(MCPClient::Auth::ClientInfo.from_h(info.to_h).issuer).to eq('https://auth.example.com')
    end

    it 'includes application_type in the client metadata hash only when set' do
      expect(MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri]).to_h).not_to have_key(:application_type)
      expect(MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri], application_type: 'native').to_h)
        .to include(application_type: 'native')
    end
  end

  describe 'authorization server binding' do
    let(:registration_endpoint) { 'https://other.example.com/register' }

    def switch_authorization_server(provider, meta)
      # The protected resource metadata now points at a different AS.
      provider.instance_variable_set(
        :@challenge_resource_metadata,
        MCPClient::Auth::ResourceMetadata.new(resource: server_url, authorization_servers: [meta.issuer])
      )
      allow(provider).to receive(:fetch_server_metadata).and_return(meta)
    end

    it 're-registers a dynamically registered client with the new authorization server and drops the old token' do
      provider = provider_for
      stub_discovery(provider, as_meta(registration_endpoint: 'https://auth.example.com/register'))
      stub_request(:post, 'https://auth.example.com/register')
        .to_return(status: 201, headers: { 'Content-Type' => 'application/json' }, body: { client_id: 'at-a' }.to_json)
      provider.start_authorization_flow
      storage.set_token(server_url, MCPClient::Auth::Token.new(access_token: 'old'))

      switch_authorization_server(provider, as_meta(issuer: 'https://other.example.com',
                                                    registration_endpoint: registration_endpoint))
      other = stub_request(:post, registration_endpoint)
              .to_return(status: 201, headers: { 'Content-Type' => 'application/json' },
                         body: { client_id: 'at-b' }.to_json)
      provider.start_authorization_flow

      expect(other).to have_been_requested
      expect(storage.get_client_info(server_url).client_id).to eq('at-b')
      expect(storage.get_client_info(server_url).issuer).to eq('https://other.example.com')
      expect(storage.get_token(server_url)).to be_nil
    end

    it 'binds pre-registered credentials to the first authorization server and refuses another' do
      storage.set_client_info(server_url, client_info(registration_type: 'pre_registered'))
      provider = provider_for
      stub_discovery(provider, as_meta)
      provider.start_authorization_flow
      expect(storage.get_client_info(server_url).issuer).to eq('https://auth.example.com')

      switch_authorization_server(provider, as_meta(issuer: 'https://other.example.com',
                                                    registration_endpoint: registration_endpoint))
      registration = stub_request(:post, registration_endpoint)

      expect { provider.start_authorization_flow }
        .to raise_error(MCPClient::Errors::ConnectionError, %r{https://auth\.example\.com.*https://other\.example\.com})
      expect(registration).not_to have_been_requested
    end

    it 'keeps a Client ID Metadata Document client across authorization servers' do
      cimd_url = 'https://app.example.com/oauth/client-metadata.json'
      provider = provider_for(client_id_metadata_url: cimd_url)
      stub_discovery(provider, as_meta(client_id_metadata_document_supported: true))
      provider.start_authorization_flow
      expect(storage.get_client_info(server_url).registration_type).to eq('cimd')

      switch_authorization_server(provider, as_meta(issuer: 'https://other.example.com',
                                                    client_id_metadata_document_supported: true,
                                                    registration_endpoint: registration_endpoint))
      registration = stub_request(:post, registration_endpoint)
      url = provider.start_authorization_flow

      expect(URI.decode_www_form(URI.parse(url).query).to_h['client_id']).to eq(cimd_url)
      expect(registration).not_to have_been_requested
    end

    it 'adopts an unbound cached client for the current issuer' do
      storage.set_client_info(server_url, client_info)
      provider = provider_for
      stub_discovery(provider, as_meta)

      provider.start_authorization_flow

      expect(storage.get_client_info(server_url).issuer).to eq('https://auth.example.com')
    end
  end

  describe MCPClient::OAuthClient do
    it 'forwards application_type to the provider and iss to the flow completion' do
      provider = instance_double(MCPClient::Auth::OAuthProvider)
      allow(MCPClient::Auth::OAuthProvider).to receive(:new).and_return(provider)
      allow(provider).to receive(:complete_authorization_flow).and_return(:token)

      server = described_class.create_streamable_http_server(server_url: server_url, application_type: 'web')
      expect(MCPClient::Auth::OAuthProvider).to have_received(:new).with(hash_including(application_type: 'web'))

      expect(described_class.complete_oauth_flow(server, 'code', 'state', iss: 'https://auth.example.com'))
        .to eq(:token)
      expect(provider).to have_received(:complete_authorization_flow)
        .with('code', 'state', iss: 'https://auth.example.com')
    end
  end
end
