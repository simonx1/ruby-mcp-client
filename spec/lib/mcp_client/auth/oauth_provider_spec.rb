# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Auth::OAuthProvider do
  let(:server_url) { 'https://mcp.example.com' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:logger) { instance_double('Logger') }
  let(:storage) { instance_double('MCPClient::Auth::OAuthProvider::MemoryStorage') }

  subject(:oauth_provider) do
    described_class.new(
      server_url: server_url,
      redirect_uri: redirect_uri,
      scope: 'read write',
      logger: logger,
      storage: storage
    )
  end

  before do
    allow(logger).to receive(:debug)
    allow(logger).to receive(:warn)
  end

  describe '#initialize' do
    it 'normalizes server URL' do
      provider = described_class.new(server_url: 'HTTPS://MCP.EXAMPLE.COM:443/')
      expect(provider.server_url).to eq('https://mcp.example.com')
    end

    it 'sets default redirect URI' do
      provider = described_class.new(server_url: server_url)
      expect(provider.redirect_uri).to eq('http://localhost:8080/callback')
    end

    it 'accepts extra client_metadata' do
      provider = described_class.new(
        server_url: server_url,
        client_metadata: { client_name: 'My App', contacts: ['dev@example.com'] }
      )
      extra = provider.instance_variable_get(:@extra_client_metadata)
      expect(extra).to eq(client_name: 'My App', contacts: ['dev@example.com'])
    end

    it 'defaults extra client_metadata to empty hash' do
      provider = described_class.new(server_url: server_url)
      extra = provider.instance_variable_get(:@extra_client_metadata)
      expect(extra).to eq({})
    end
  end

  describe 'OAuth discovery URL generation' do
    it 'generates correct authorization-server discovery URL (default)' do
      provider = described_class.new(
        server_url: 'https://mcp.zapier.com/api/mcp/a/123/mcp?serverId=abc-123'
      )

      # Access private method for testing - defaults to :authorization_server
      discovery_url = provider.send(:build_discovery_url, provider.server_url)
      expect(discovery_url).to eq('https://mcp.zapier.com/.well-known/oauth-authorization-server')
    end

    it 'generates correct protected-resource discovery URL when specified' do
      provider = described_class.new(
        server_url: 'https://mcp.zapier.com/api/mcp/a/123/mcp?serverId=abc-123'
      )

      discovery_url = provider.send(:build_discovery_url, provider.server_url, :protected_resource)
      expect(discovery_url).to eq('https://mcp.zapier.com/.well-known/oauth-protected-resource')
    end

    it 'generates correct discovery URL for simple server URL' do
      provider = described_class.new(server_url: 'https://api.example.com')

      discovery_url = provider.send(:build_discovery_url, provider.server_url)
      expect(discovery_url).to eq('https://api.example.com/.well-known/oauth-authorization-server')
    end

    it 'handles non-default ports correctly' do
      provider = described_class.new(server_url: 'https://api.example.com:8443/mcp')

      discovery_url = provider.send(:build_discovery_url, provider.server_url)
      expect(discovery_url).to eq('https://api.example.com:8443/.well-known/oauth-authorization-server')
    end
  end

  describe 'RFC-compliant discovery' do
    describe '#protected_resource_metadata_urls (RFC 9728 path-aware)' do
      it 'inserts the well-known segment before the path, then falls back to root' do
        p = described_class.new(server_url: 'https://ex.com/public/mcp')
        expect(p.send(:protected_resource_metadata_urls, p.server_url)).to eq(
          [
            'https://ex.com/.well-known/oauth-protected-resource/public/mcp',
            'https://ex.com/.well-known/oauth-protected-resource'
          ]
        )
      end

      it 'returns only the root URL for a path-less server' do
        p = described_class.new(server_url: 'https://ex.com')
        expect(p.send(:protected_resource_metadata_urls, p.server_url))
          .to eq(['https://ex.com/.well-known/oauth-protected-resource'])
      end
    end

    describe '#authorization_server_metadata_urls (RFC 8414 path-insertion + OIDC)' do
      let(:p) { described_class.new(server_url: server_url) }

      it 'path-inserts oauth + OIDC and appends OIDC for an issuer with a path' do
        expect(p.send(:authorization_server_metadata_urls, 'https://auth.example.com/tenant1')).to eq(
          [
            'https://auth.example.com/.well-known/oauth-authorization-server/tenant1',
            'https://auth.example.com/.well-known/openid-configuration/tenant1',
            'https://auth.example.com/tenant1/.well-known/openid-configuration'
          ]
        )
      end

      it 'tries oauth then OIDC for a path-less issuer' do
        expect(p.send(:authorization_server_metadata_urls, 'https://auth.example.com')).to eq(
          [
            'https://auth.example.com/.well-known/oauth-authorization-server',
            'https://auth.example.com/.well-known/openid-configuration'
          ]
        )
      end
    end

    describe '#extract_resource_metadata_url (WWW-Authenticate)' do
      let(:p) { described_class.new(server_url: server_url) }

      it 'parses the quoted resource_metadata parameter' do
        header = 'Bearer resource_metadata="https://mcp.example.com/meta", scope="files:read"'
        expect(p.send(:extract_resource_metadata_url, header)).to eq('https://mcp.example.com/meta')
      end

      it 'parses the unquoted resource_metadata parameter' do
        header = 'Bearer resource_metadata=https://mcp.example.com/meta'
        expect(p.send(:extract_resource_metadata_url, header)).to eq('https://mcp.example.com/meta')
      end

      it 'falls back to the legacy resource parameter' do
        header = 'Bearer resource="https://mcp.example.com/legacy"'
        expect(p.send(:extract_resource_metadata_url, header)).to eq('https://mcp.example.com/legacy')
      end

      it 'tolerates whitespace around the parameter equals sign' do
        header = 'Bearer resource_metadata = "https://mcp.example.com/meta"'
        expect(p.send(:extract_resource_metadata_url, header)).to eq('https://mcp.example.com/meta')
      end
    end

    describe '#verify_pkce_support!' do
      def metadata(methods)
        MCPClient::Auth::ServerMetadata.new(
          issuer: 'https://a', authorization_endpoint: 'https://a/auth',
          token_endpoint: 'https://a/token', code_challenge_methods_supported: methods
        )
      end

      it 'raises when S256 is explicitly not offered' do
        expect { oauth_provider.send(:verify_pkce_support!, metadata(['plain'])) }
          .to raise_error(MCPClient::Errors::ConnectionError, /PKCE S256/)
      end

      it 'passes when S256 is offered' do
        expect { oauth_provider.send(:verify_pkce_support!, metadata(['S256'])) }.not_to raise_error
      end

      it 'warns but proceeds when not advertised' do
        expect(logger).to receive(:warn).with(/omits code_challenge_methods_supported/)
        oauth_provider.send(:verify_pkce_support!, metadata(nil))
      end
    end

    describe '#enforce_https!' do
      it 'rejects a non-localhost http endpoint' do
        expect { oauth_provider.send(:enforce_https!, 'http://evil.com/token', 'token endpoint') }
          .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)
      end

      it 'allows https endpoints' do
        expect { oauth_provider.send(:enforce_https!, 'https://auth.example.com/token', 'token endpoint') }
          .not_to raise_error
      end

      it 'allows http on localhost for local development' do
        expect { oauth_provider.send(:enforce_https!, 'http://localhost:9292/token', 'token endpoint') }
          .not_to raise_error
      end

      it 'allows http on an IPv6 loopback endpoint' do
        expect { oauth_provider.send(:enforce_https!, 'http://[::1]:9292/token', 'token endpoint') }
          .not_to raise_error
      end

      it 'rejects a non-http scheme even on a loopback host' do
        expect { oauth_provider.send(:enforce_https!, 'ftp://localhost/token', 'token endpoint') }
          .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)
      end
    end

    describe '#validate_resource_matches!' do
      def resource_metadata(resource)
        MCPClient::Auth::ResourceMetadata.new(resource: resource, authorization_servers: ['https://auth.example.com'])
      end

      it 'accepts an exact canonical resource match' do
        expect { oauth_provider.send(:validate_resource_matches!, resource_metadata('https://mcp.example.com')) }
          .not_to raise_error
      end

      it 'ignores a trailing slash on an exact match' do
        expect { oauth_provider.send(:validate_resource_matches!, resource_metadata('https://mcp.example.com/')) }
          .not_to raise_error
      end

      it 'treats the query as part of the resource identity' do
        q_provider = described_class.new(server_url: 'https://mcp.example.com/mcp?serverId=a', logger: logger)
        expect do
          q_provider.send(:validate_resource_matches!, resource_metadata('https://mcp.example.com/mcp?serverId=b'))
        end.to raise_error(MCPClient::Errors::ConnectionError, /does not match/)
      end

      it 'rejects a different resource host (confused deputy protection)' do
        expect { oauth_provider.send(:validate_resource_matches!, resource_metadata('https://other.com')) }
          .to raise_error(MCPClient::Errors::ConnectionError, /does not match/)
      end

      it 'rejects a same-host but different-path resource (multi-tenant safety)' do
        tenant_provider = described_class.new(server_url: 'https://api.example.com/tenant-b/mcp', logger: logger)
        expect do
          tenant_provider.send(:validate_resource_matches!, resource_metadata('https://api.example.com/tenant-a/mcp'))
        end.to raise_error(MCPClient::Errors::ConnectionError, /does not match/)
      end

      it 'rejects protected resource metadata that omits the required resource identifier' do
        expect { oauth_provider.send(:validate_resource_matches!, resource_metadata(nil)) }
          .to raise_error(MCPClient::Errors::ConnectionError, /missing the required "resource"/)
      end

      it 'raises a ConnectionError (not NoMethodError) for a non-absolute resource value' do
        expect { oauth_provider.send(:validate_resource_matches!, resource_metadata('mcp.example.com')) }
          .to raise_error(MCPClient::Errors::ConnectionError, /must be absolute/)
      end
    end

    describe '#fetch_resource_metadata (404 handling)' do
      let(:http_client) { instance_double('Faraday::Connection') }

      before { oauth_provider.instance_variable_set(:@http_client, http_client) }

      def response(status, body = '{}')
        instance_double('Faraday::Response', status: status, success?: (200..299).cover?(status), body: body)
      end

      it 'returns nil for a speculative well-known 404 (non-strict)' do
        allow(http_client).to receive(:get).and_return(response(404))
        expect(oauth_provider.send(:fetch_resource_metadata, 'https://x.example.com/meta')).to be_nil
      end

      it 'raises for a 404 on an explicitly-advertised challenge URL (strict)' do
        allow(http_client).to receive(:get).and_return(response(404))
        expect { oauth_provider.send(:fetch_resource_metadata, 'https://x.example.com/meta', strict: true) }
          .to raise_error(MCPClient::Errors::ConnectionError, /HTTP 404/)
      end
    end

    describe '#discover_authorization_server (PRM-first)' do
      let(:storage_instance) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }
      let(:provider) do
        described_class.new(server_url: 'https://mcp.example.com/mcp', logger: logger, storage: storage_instance)
      end
      let(:resource_meta) do
        MCPClient::Auth::ResourceMetadata.new(
          resource: 'https://mcp.example.com/mcp', authorization_servers: ['https://auth.example.com']
        )
      end

      def server_meta(methods)
        MCPClient::Auth::ServerMetadata.new(
          issuer: 'https://auth.example.com',
          authorization_endpoint: 'https://auth.example.com/authorize',
          token_endpoint: 'https://auth.example.com/token',
          code_challenge_methods_supported: methods
        )
      end

      it 'follows PRM to the authorization server, verifies S256, and caches' do
        allow(provider).to receive(:fetch_resource_metadata).and_return(resource_meta)
        allow(provider).to receive(:fetch_server_metadata).and_return(server_meta(['S256']))

        result = provider.send(:discover_authorization_server)
        expect(result.token_endpoint).to eq('https://auth.example.com/token')
        expect(storage_instance.get_server_metadata('https://mcp.example.com/mcp')).not_to be_nil
      end

      it 'refuses an authorization server that does not support PKCE S256' do
        allow(provider).to receive(:fetch_resource_metadata).and_return(resource_meta)
        allow(provider).to receive(:fetch_server_metadata).and_return(server_meta(['plain']))

        expect { provider.send(:discover_authorization_server) }
          .to raise_error(MCPClient::Errors::ConnectionError, /PKCE S256/)
      end

      it 'falls back to direct AS discovery when no PRM document exists (404)' do
        # fetch_resource_metadata returns nil for a genuine 404 (absent candidate)
        allow(provider).to receive(:fetch_resource_metadata).and_return(nil)
        allow(provider).to receive(:fetch_server_metadata).and_return(server_meta(['S256']))

        result = provider.send(:discover_authorization_server)
        expect(result.token_endpoint).to eq('https://auth.example.com/token')
      end

      it 'hard-fails (no fallback) when a PRM candidate exists but is malformed or errors' do
        # A non-404 failure (malformed JSON / 5xx) at a PRM URL must not fall
        # through to root PRM or direct-AS discovery.
        allow(provider).to receive(:fetch_resource_metadata)
          .and_raise(MCPClient::Errors::ConnectionError, 'Invalid resource metadata JSON')
        # If a fallback were (wrongly) taken, this would let discovery succeed:
        allow(provider).to receive(:fetch_server_metadata).and_return(server_meta(['S256']))

        expect { provider.send(:discover_authorization_server) }
          .to raise_error(MCPClient::Errors::ConnectionError, /Invalid resource metadata JSON/)
      end

      it 'hard-fails (no origin fallback) when PRM is found but its advertised AS is unreachable' do
        allow(provider).to receive(:fetch_resource_metadata).and_return(resource_meta)
        # The AS advertised by the authoritative PRM cannot be loaded
        allow(provider).to receive(:fetch_server_metadata)
          .and_raise(MCPClient::Errors::ConnectionError, 'HTTP 500')

        expect { provider.send(:discover_authorization_server) }
          .to raise_error(MCPClient::Errors::ConnectionError, /could not be discovered/)
      end

      it 'validates a cached metadata entry (rejects a cached AS lacking S256)' do
        storage_instance.set_server_metadata('https://mcp.example.com/mcp', server_meta(['plain']))

        expect { provider.send(:discover_authorization_server) }
          .to raise_error(MCPClient::Errors::ConnectionError, /PKCE S256/)
      end

      it 'reuses protected resource metadata learned from a 401 challenge' do
        provider.instance_variable_set(:@challenge_resource_metadata, resource_meta)
        # No PRM well-known fetch should be needed; only the AS lookup runs
        expect(provider).not_to receive(:fetch_resource_metadata)
        allow(provider).to receive(:fetch_server_metadata).and_return(server_meta(['S256']))

        result = provider.send(:discover_authorization_server)
        expect(result.token_endpoint).to eq('https://auth.example.com/token')
      end

      it 'lets a 401 challenge override stale cached AS metadata' do
        # A previously direct-discovered AS is cached...
        stale = MCPClient::Auth::ServerMetadata.new(
          issuer: 'https://stale.example.com',
          authorization_endpoint: 'https://stale.example.com/authorize',
          token_endpoint: 'https://stale.example.com/token',
          code_challenge_methods_supported: ['S256']
        )
        storage_instance.set_server_metadata('https://mcp.example.com/mcp', stale)

        # ...but a fresh 401 challenge points at the authoritative PRM/AS
        provider.instance_variable_set(:@challenge_resource_metadata, resource_meta)
        allow(provider).to receive(:fetch_server_metadata).and_return(server_meta(['S256']))

        result = provider.send(:discover_authorization_server)
        expect(result.token_endpoint).to eq('https://auth.example.com/token')
      end

      it 'discards a cached client registered with the previous AS when the AS changes' do
        stale = MCPClient::Auth::ServerMetadata.new(
          issuer: 'https://stale.example.com',
          authorization_endpoint: 'https://stale.example.com/authorize',
          token_endpoint: 'https://stale.example.com/token',
          code_challenge_methods_supported: ['S256']
        )
        storage_instance.set_server_metadata('https://mcp.example.com/mcp', stale)
        storage_instance.set_client_info('https://mcp.example.com/mcp', double('old-client'))

        provider.instance_variable_set(:@challenge_resource_metadata, resource_meta)
        allow(provider).to receive(:fetch_server_metadata).and_return(server_meta(['S256']))

        provider.send(:discover_authorization_server)
        expect(storage_instance.get_client_info('https://mcp.example.com/mcp')).to be_nil
      end

      it 'does not persist AS metadata that fails validation' do
        allow(provider).to receive(:fetch_resource_metadata).and_return(resource_meta)
        allow(provider).to receive(:fetch_server_metadata).and_return(server_meta(['plain']))

        expect { provider.send(:discover_authorization_server) }
          .to raise_error(MCPClient::Errors::ConnectionError, /PKCE S256/)
        expect(storage_instance.get_server_metadata('https://mcp.example.com/mcp')).to be_nil
      end

      it 'resets memoized supported_scopes when the AS changes' do
        stale = MCPClient::Auth::ServerMetadata.new(
          issuer: 'https://stale.example.com', authorization_endpoint: 'https://stale.example.com/authorize',
          token_endpoint: 'https://stale.example.com/token', code_challenge_methods_supported: ['S256']
        )
        storage_instance.set_server_metadata('https://mcp.example.com/mcp', stale)
        provider.instance_variable_set(:@supported_scopes, ['old:scope'])
        provider.instance_variable_set(:@challenge_resource_metadata, resource_meta)
        allow(provider).to receive(:fetch_server_metadata).and_return(server_meta(['S256']))

        provider.send(:discover_authorization_server)
        expect(provider.instance_variable_get(:@supported_scopes)).to be_nil
      end

      it 'clears client info via set_client_info(nil) for storage without delete_client_info' do
        # A minimal custom storage that intentionally does NOT implement
        # delete_client_info (only the documented get/set interface).
        storage_class = Class.new do
          def initialize(stale)
            @server_metadata = stale
            @client_info = :registered_with_old_as
          end

          def get_server_metadata(_url) = @server_metadata
          def set_server_metadata(_url, meta) = (@server_metadata = meta)
          def get_client_info(_url) = @client_info
          def set_client_info(_url, info) = (@client_info = info)
          # deliberately no delete_client_info
        end

        stale = MCPClient::Auth::ServerMetadata.new(
          issuer: 'https://stale.example.com', authorization_endpoint: 'https://stale.example.com/authorize',
          token_endpoint: 'https://stale.example.com/token', code_challenge_methods_supported: ['S256']
        )
        custom_storage = storage_class.new(stale)
        custom_provider = described_class.new(
          server_url: 'https://mcp.example.com/mcp', logger: logger, storage: custom_storage
        )
        custom_provider.instance_variable_set(:@challenge_resource_metadata, resource_meta)
        allow(custom_provider).to receive(:fetch_server_metadata).and_return(server_meta(['S256']))

        custom_provider.send(:discover_authorization_server)
        expect(custom_storage.get_client_info(nil)).to be_nil
      end
    end
  end

  describe '#access_token' do
    context 'when no token is stored' do
      before do
        allow(storage).to receive(:get_token).with(server_url).and_return(nil)
      end

      it 'returns nil' do
        expect(oauth_provider.access_token).to be_nil
      end
    end

    context 'when valid token is stored' do
      let(:token) do
        MCPClient::Auth::Token.new(
          access_token: 'valid_token',
          expires_in: 3600
        )
      end

      before do
        allow(storage).to receive(:get_token).with(server_url).and_return(token)
      end

      it 'returns the token' do
        expect(oauth_provider.access_token).to eq(token)
      end
    end

    context 'when expired token with refresh token is stored' do
      let(:expired_token) do
        token = MCPClient::Auth::Token.new(
          access_token: 'expired_token',
          expires_in: 3600,
          refresh_token: 'refresh123'
        )
        # Manually set expiration to past
        token.instance_variable_set(:@expires_at, Time.now - 1)
        token
      end

      before do
        allow(storage).to receive(:get_token).with(server_url).and_return(expired_token)
        allow(oauth_provider).to receive(:refresh_token).with(expired_token).and_return(nil)
      end

      it 'attempts to refresh the token' do
        oauth_provider.access_token
        expect(oauth_provider).to have_received(:refresh_token).with(expired_token)
      end
    end
  end

  describe '#apply_authorization' do
    let(:request) { instance_double('Faraday::Request', headers: {}) }

    context 'when access token is available' do
      let(:token) do
        MCPClient::Auth::Token.new(
          access_token: 'test_token',
          token_type: 'Bearer'
        )
      end

      before do
        allow(oauth_provider).to receive(:access_token).and_return(token)
      end

      it 'adds Authorization header' do
        oauth_provider.apply_authorization(request)
        expect(request.headers['Authorization']).to eq('Bearer test_token')
      end
    end

    context 'when no access token is available' do
      before do
        allow(oauth_provider).to receive(:access_token).and_return(nil)
      end

      it 'does not add Authorization header' do
        oauth_provider.apply_authorization(request)
        expect(request.headers).not_to have_key('Authorization')
      end
    end
  end

  describe '#handle_unauthorized_response' do
    let(:response) { instance_double('Faraday::Response') }

    context 'when WWW-Authenticate header contains resource metadata URL' do
      let(:www_authenticate) { 'Bearer resource="https://example.com/.well-known/oauth-protected-resource"' }

      before do
        allow(response).to receive(:headers).and_return('WWW-Authenticate' => www_authenticate)
        allow(oauth_provider).to receive(:fetch_resource_metadata).and_return(
          MCPClient::Auth::ResourceMetadata.new(
            resource: 'https://example.com',
            authorization_servers: ['https://auth.example.com']
          )
        )
      end

      it 'fetches and returns resource metadata' do
        result = oauth_provider.handle_unauthorized_response(response)
        expect(result).to be_a(MCPClient::Auth::ResourceMetadata)
        expect(result.authorization_servers).to include('https://auth.example.com')
      end
    end

    context 'when WWW-Authenticate header is missing' do
      before do
        allow(response).to receive(:headers).and_return({})
      end

      it 'returns nil' do
        result = oauth_provider.handle_unauthorized_response(response)
        expect(result).to be_nil
      end
    end
  end

  describe '#supported_scopes' do
    let(:server_metadata) do
      MCPClient::Auth::ServerMetadata.new(
        issuer: 'https://mcp.example.com',
        authorization_endpoint: 'https://mcp.example.com/authorize',
        token_endpoint: 'https://mcp.example.com/token',
        scopes_supported: %w[read write admin]
      )
    end

    before do
      allow(oauth_provider).to receive(:discover_authorization_server).and_return(server_metadata)
    end

    it 'returns the scopes from server metadata' do
      expect(oauth_provider.supported_scopes).to eq(%w[read write admin])
    end

    it 'memoizes the result' do
      oauth_provider.supported_scopes
      oauth_provider.supported_scopes
      expect(oauth_provider).to have_received(:discover_authorization_server).once
    end

    context 'when scopes_supported is nil' do
      let(:server_metadata) do
        MCPClient::Auth::ServerMetadata.new(
          issuer: 'https://mcp.example.com',
          authorization_endpoint: 'https://mcp.example.com/authorize',
          token_endpoint: 'https://mcp.example.com/token',
          scopes_supported: nil
        )
      end

      it 'returns an empty array' do
        expect(oauth_provider.supported_scopes).to eq([])
      end
    end
  end

  describe 'scope: :all' do
    let(:server_metadata) do
      MCPClient::Auth::ServerMetadata.new(
        issuer: 'https://mcp.example.com',
        authorization_endpoint: 'https://mcp.example.com/authorize',
        token_endpoint: 'https://mcp.example.com/token',
        registration_endpoint: 'https://mcp.example.com/register',
        scopes_supported: %w[read write admin]
      )
    end

    let(:client_metadata) do
      MCPClient::Auth::ClientMetadata.new(
        redirect_uris: [redirect_uri],
        token_endpoint_auth_method: 'none'
      )
    end

    let(:client_info) do
      MCPClient::Auth::ClientInfo.new(
        client_id: 'client123',
        metadata: client_metadata
      )
    end

    let(:provider) do
      described_class.new(
        server_url: server_url,
        redirect_uri: redirect_uri,
        scope: :all,
        logger: logger,
        storage: storage
      )
    end

    before do
      allow(storage).to receive(:get_server_metadata).and_return(server_metadata)
      allow(storage).to receive(:set_server_metadata)
      allow(storage).to receive(:get_client_info).and_return(client_info)
      allow(storage).to receive(:set_pkce)
      allow(storage).to receive(:set_state)
    end

    it 'resolves :all to all supported scopes in the authorization URL' do
      auth_url = provider.start_authorization_flow
      uri = URI.parse(auth_url)
      params = URI.decode_www_form(uri.query).to_h
      expect(params['scope']).to eq('read write admin')
    end

    it 'does not mutate @scope' do
      provider.start_authorization_flow
      expect(provider.scope).to eq(:all)
    end
  end

  describe '#exchange_authorization_code' do
    let(:storage_instance) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }
    let(:logger) { instance_double('Logger') }
    let(:provider) do
      described_class.new(
        server_url: 'https://3d4834530bf2.ngrok.app/mcp',
        redirect_uri: redirect_uri,
        logger: logger,
        storage: storage_instance
      )
    end
    let(:http_client) { double('Faraday::Connection') }
    let(:server_metadata) do
      instance_double(
        'MCPClient::Auth::ServerMetadata',
        token_endpoint: 'https://tropic-dev.us.auth0.com/oauth/token'
      )
    end
    let(:client_metadata) do
      MCPClient::Auth::ClientMetadata.new(
        redirect_uris: [redirect_uri],
        token_endpoint_auth_method: 'client_secret_post'
      )
    end
    let(:client_info) do
      MCPClient::Auth::ClientInfo.new(
        client_id: 'client123',
        client_secret: 'secret456',
        metadata: client_metadata
      )
    end
    let(:pkce) { instance_double('MCPClient::Auth::PKCE', code_verifier: 'verifier123') }
    let(:requests) { [] }
    let(:error_body) do
      {
        error: 'unauthorized_client',
        error_description: 'The redirect URI is wrong. You sent http://localhost:8080, and we expected https://3d4834530bf2.ngrok.app'
      }.to_json
    end
    let(:success_body) do
      {
        access_token: 'access-token',
        token_type: 'Bearer'
      }.to_json
    end
    let(:error_response) do
      instance_double('Faraday::Response', success?: false, status: 403, body: error_body)
    end
    let(:success_response) do
      instance_double('Faraday::Response', success?: true, status: 200, body: success_body)
    end

    before do
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:debug)

      provider.instance_variable_set(:@http_client, http_client)
      queue = [error_response, success_response]

      allow(http_client).to receive(:post) do |url, &block|
        expect(url).to eq(server_metadata.token_endpoint)

        request = Struct.new(:headers, :body).new({}, nil)
        block.call(request)
        requests << request.body

        response = queue.shift
        raise 'No response stubbed for token request' unless response

        response
      end
    end

    it 'retries token exchange with server-provided redirect URI when mismatch occurs' do
      token = provider.send(:exchange_authorization_code, server_metadata, client_info, 'auth-code', pkce)

      expect(token.access_token).to eq('access-token')
      expect(requests.length).to eq(2)
      expect(requests.first).to include('redirect_uri=http%3A%2F%2Flocalhost%3A8080%2Fcallback')
      expect(requests.last).to include('redirect_uri=https%3A%2F%2F3d4834530bf2.ngrok.app')
      expected_message = "Token exchange failed: redirect_uri mismatch. Retrying with server's expected value: " \
                         'https://3d4834530bf2.ngrok.app'
      expect(logger).to have_received(:warn).with(expected_message)
    end
  end

  describe '#register_client with extra client_metadata' do
    let(:storage_instance) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }
    let(:logger) { instance_double('Logger') }
    let(:extra_metadata) do
      {
        client_name: 'My MCP App',
        client_uri: 'https://myapp.example.com',
        logo_uri: 'https://myapp.example.com/logo.png',
        tos_uri: 'https://myapp.example.com/tos',
        policy_uri: 'https://myapp.example.com/privacy',
        contacts: ['admin@myapp.example.com']
      }
    end
    let(:provider) do
      described_class.new(
        server_url: 'https://mcp.example.com',
        redirect_uri: redirect_uri,
        scope: 'read',
        logger: logger,
        storage: storage_instance,
        client_metadata: extra_metadata
      )
    end
    let(:http_client) { double('Faraday::Connection') }
    let(:server_metadata) do
      instance_double(
        'MCPClient::Auth::ServerMetadata',
        registration_endpoint: 'https://auth.example.com/register'
      )
    end
    let(:registration_response_body) do
      {
        'client_id' => 'new-client-id',
        'client_name' => 'My MCP App',
        'client_uri' => 'https://myapp.example.com',
        'logo_uri' => 'https://myapp.example.com/logo.png',
        'tos_uri' => 'https://myapp.example.com/tos',
        'policy_uri' => 'https://myapp.example.com/privacy',
        'contacts' => ['admin@myapp.example.com'],
        'redirect_uris' => [redirect_uri]
      }.to_json
    end
    let(:sent_bodies) { [] }

    before do
      allow(logger).to receive(:debug)
      allow(logger).to receive(:warn)

      provider.instance_variable_set(:@http_client, http_client)
      response = instance_double('Faraday::Response', success?: true, status: 200, body: registration_response_body)

      allow(http_client).to receive(:post) do |_url, &block|
        request = Struct.new(:headers, :body).new({}, nil)
        block.call(request)
        sent_bodies << JSON.parse(request.body)
        response
      end
    end

    it 'sends extra metadata fields in DCR request' do
      provider.send(:register_client, server_metadata)

      body = sent_bodies.first
      expect(body['client_name']).to eq('My MCP App')
      expect(body['client_uri']).to eq('https://myapp.example.com')
      expect(body['logo_uri']).to eq('https://myapp.example.com/logo.png')
      expect(body['tos_uri']).to eq('https://myapp.example.com/tos')
      expect(body['policy_uri']).to eq('https://myapp.example.com/privacy')
      expect(body['contacts']).to eq(['admin@myapp.example.com'])
    end

    it 'parses extra metadata fields from server response' do
      client_info = provider.send(:register_client, server_metadata)

      expect(client_info.metadata.client_name).to eq('My MCP App')
      expect(client_info.metadata.client_uri).to eq('https://myapp.example.com')
      expect(client_info.metadata.logo_uri).to eq('https://myapp.example.com/logo.png')
      expect(client_info.metadata.tos_uri).to eq('https://myapp.example.com/tos')
      expect(client_info.metadata.policy_uri).to eq('https://myapp.example.com/privacy')
      expect(client_info.metadata.contacts).to eq(['admin@myapp.example.com'])
    end

    it 'omits nil extra fields from DCR request' do
      minimal_provider = described_class.new(
        server_url: 'https://mcp.example.com',
        redirect_uri: redirect_uri,
        logger: logger,
        storage: storage_instance
      )
      minimal_provider.instance_variable_set(:@http_client, http_client)

      minimal_provider.send(:register_client, server_metadata)

      body = sent_bodies.first
      expect(body).not_to have_key('client_name')
      expect(body).not_to have_key('contacts')
    end
  end
end
