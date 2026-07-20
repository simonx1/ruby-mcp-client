# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 authorization (basic/authorization.mdx):
# - "MCP clients MUST be able to parse WWW-Authenticate headers and respond
#   appropriately to HTTP 401 Unauthorized responses" — and MUST use the
#   resource metadata URL from the parsed header when present.
# - "Clients MUST treat the scopes provided in the challenge as authoritative
#   for satisfying the current request" (scope selection priority 1); the
#   fallback is scopes_supported from the Protected Resource Metadata.
# - SEP-835: clients SHOULD respond to 403 insufficient_scope challenges with
#   a step-up authorization flow — which requires the challenge parameters to
#   be surfaced, not swallowed.
RSpec.describe 'OAuth challenge handling (MCP 2025-11-25)' do
  let(:base_url) { 'https://mcp.example.com' }

  describe 'transport 401 handling (default configuration)' do
    it 'passes the WWW-Authenticate challenge to the OAuth provider before raising' do
      provider = instance_double(MCPClient::Auth::OAuthProvider)
      allow(provider).to receive(:apply_authorization)
      allow(provider).to receive(:handle_unauthorized_response)

      server = MCPClient::ServerHTTP.new(base_url: base_url, endpoint: '/rpc', oauth_provider: provider)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)

      stub_request(:post, "#{base_url}/rpc").to_return(
        status: 401,
        headers: { 'WWW-Authenticate' =>
          'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"' },
        body: ''
      )

      expect { server.rpc_request('tools/list', {}) }.to raise_error(MCPClient::Errors::ConnectionError)
      expect(provider).to have_received(:handle_unauthorized_response) do |response|
        expect(response.headers['WWW-Authenticate']).to include('resource_metadata')
      end
    end
  end

  describe '403 insufficient_scope step-up (SEP-835)' do
    it 'raises InsufficientScopeError exposing the challenged scopes' do
      server = MCPClient::ServerHTTP.new(base_url: base_url, endpoint: '/rpc')
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)

      stub_request(:post, "#{base_url}/rpc").to_return(
        status: 403,
        headers: { 'WWW-Authenticate' =>
          'Bearer error="insufficient_scope", scope="files:write admin", error_description="Need more scopes"' },
        body: ''
      )

      expect { server.rpc_request('tools/call', {}) }.to raise_error(MCPClient::Errors::InsufficientScopeError) do |e|
        expect(e.scope).to eq('files:write admin')
        expect(e.error_description).to eq('Need more scopes')
        expect(e).to be_a(MCPClient::Errors::ConnectionError)
      end
    end
  end

  describe MCPClient::Auth::OAuthProvider do
    let(:provider) { described_class.new(server_url: base_url) }

    it 'captures the challenge scope parameter as authoritative' do
      stub_request(:get, 'https://mcp.example.com/.well-known/oauth-protected-resource')
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { resource: base_url, authorization_servers: ['https://auth.example.com'] }.to_json
        )

      response = instance_double(
        Faraday::Response,
        headers: {
          'WWW-Authenticate' =>
            'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", ' \
            'scope="mcp:tools mcp:resources"'
        }
      )
      provider.handle_unauthorized_response(response)

      expect(provider.challenge_scope).to eq('mcp:tools mcp:resources')
    end

    it 'captures the challenge scope even without a resource_metadata parameter' do
      response = instance_double(
        Faraday::Response,
        headers: { 'WWW-Authenticate' => 'Bearer scope="mcp:tools"' }
      )
      provider.handle_unauthorized_response(response)

      expect(provider.challenge_scope).to eq('mcp:tools')
    end

    describe 'scope resolution priority' do
      it 'prefers the challenge scope over everything else' do
        provider.scope = 'configured:scope'
        provider.instance_variable_set(:@challenge_scope, 'challenge:scope')

        expect(provider.send(:resolved_scope)).to eq('challenge:scope')
      end

      it 'falls back to the configured scope when there is no challenge' do
        provider.scope = 'configured:scope'

        expect(provider.send(:resolved_scope)).to eq('configured:scope')
      end

      it 'falls back to Protected Resource Metadata scopes_supported' do
        prm = MCPClient::Auth::ResourceMetadata.new(
          resource: base_url,
          authorization_servers: ['https://auth.example.com'],
          scopes_supported: %w[mcp:tools mcp:resources]
        )
        provider.instance_variable_set(:@resource_metadata, prm)

        expect(provider.send(:resolved_scope)).to eq('mcp:tools mcp:resources')
      end

      it 'omits the scope entirely when nothing is defined' do
        expect(provider.send(:resolved_scope)).to be_nil
      end
    end
  end

  describe 'exception-path (raise_error middleware) parity' do
    it 'routes Hash-shaped exception responses through the same challenge pipeline' do
      provider = instance_double(MCPClient::Auth::OAuthProvider)
      allow(provider).to receive(:handle_unauthorized_response)

      server = MCPClient::ServerHTTP.new(base_url: base_url, endpoint: '/rpc', oauth_provider: provider)
      error = Faraday::ForbiddenError.new(
        nil,
        { status: 403,
          headers: { 'www-authenticate' =>
            'Bearer error="insufficient_scope", scope="mcp:admin"' },
          body: '' }
      )

      expect { server.send(:handle_auth_error, error) }.to raise_error(
        MCPClient::Errors::InsufficientScopeError
      ) do |e|
        expect(e.scope).to eq('mcp:admin')
      end
      expect(provider).to have_received(:handle_unauthorized_response) do |response|
        expect(response.headers['www-authenticate']).to include('insufficient_scope')
      end
    end
  end

  describe 'challenge parsing robustness' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: base_url, endpoint: '/rpc') }

    def response_with(header, status: 403)
      Struct.new(:status, :headers).new(status, { 'WWW-Authenticate' => header })
    end

    it 'ignores non-Bearer challenges' do
      expect { server.send(:raise_authorization_error, response_with('Basic error="insufficient_scope"')) }
        .to raise_error(MCPClient::Errors::ConnectionError) { |e| expect(e).not_to be_a(MCPClient::Errors::InsufficientScopeError) }
    end

    it 'does not treat a prefixed error token as insufficient_scope' do
      expect { server.send(:raise_authorization_error, response_with('Bearer error="insufficient_scope_extra"')) }
        .to raise_error(MCPClient::Errors::ConnectionError) { |e| expect(e).not_to be_a(MCPClient::Errors::InsufficientScopeError) }
    end

    it 'does not capture a prefixed scope parameter' do
      header = 'Bearer error="insufficient_scope", previous_scope="wrong", scope="right"'
      expect { server.send(:raise_authorization_error, response_with(header)) }
        .to raise_error(MCPClient::Errors::InsufficientScopeError) { |e| expect(e.scope).to eq('right') }
    end
  end

  describe 'challenge scope lifecycle' do
    let(:provider) { MCPClient::Auth::OAuthProvider.new(server_url: base_url) }

    it 'clears the previous challenge scope when a new challenge carries none' do
      provider.instance_variable_set(:@challenge_scope, 'old:scope')
      response = instance_double(Faraday::Response, headers: { 'WWW-Authenticate' => 'Bearer realm="mcp"' })

      provider.handle_unauthorized_response(response)

      expect(provider.challenge_scope).to be_nil
    end

    it 'falls back to PRM scopes when :all resolves to an empty AS scope list' do
      provider.scope = :all
      allow(provider).to receive(:supported_scopes).and_return([])
      prm = MCPClient::Auth::ResourceMetadata.new(
        resource: base_url, authorization_servers: ['https://auth.example.com'],
        scopes_supported: %w[mcp:tools]
      )
      provider.instance_variable_set(:@resource_metadata, prm)

      expect(provider.send(:resolved_scope)).to eq('mcp:tools')
    end
  end

  describe MCPClient::Auth::ResourceMetadata do
    it 'parses and round-trips scopes_supported from RFC 9728 metadata' do
      metadata = described_class.from_h(
        'resource' => base_url,
        'authorization_servers' => ['https://auth.example.com'],
        'scopes_supported' => %w[mcp:tools mcp:resources]
      )

      expect(metadata.scopes_supported).to eq(%w[mcp:tools mcp:resources])
      expect(metadata.to_h[:scopes_supported]).to eq(%w[mcp:tools mcp:resources])
    end
  end
end
