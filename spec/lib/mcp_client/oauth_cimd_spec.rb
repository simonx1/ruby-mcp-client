# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 authorization (basic/authorization.mdx, SEP-991):
# - "Authorization servers and MCP clients SHOULD support OAuth Client ID
#   Metadata Documents" — the recommended registration mechanism when client
#   and server have no prior relationship.
# - Discovery: "Authorization servers advertise that they support clients
#   using Client ID Metadata Documents by including ...
#   client_id_metadata_document_supported" in their AS metadata, and
#   "MCP clients SHOULD check for this capability and MAY fall back to
#   Dynamic Client Registration or pre-registration if unavailable."
# - Priority order: pre-registered client information → Client ID Metadata
#   Documents → Dynamic Client Registration.
# - "The client_id URL MUST use the 'https' scheme and contain a path
#   component, e.g. https://example.com/client.json"
RSpec.describe 'OAuth Client ID Metadata Documents (SEP-991)' do
  let(:server_url) { 'https://mcp.example.com' }
  let(:redirect_uri) { 'http://localhost:8080/callback' }
  let(:client_id_metadata_url) { 'https://app.example.com/oauth/client-metadata.json' }
  let(:registration_endpoint) { 'https://auth.example.com/register' }
  let(:logger) { Logger.new(File::NULL) }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def build_server_metadata(**overrides)
    defaults = {
      issuer: 'https://auth.example.com',
      authorization_endpoint: 'https://auth.example.com/authorize',
      token_endpoint: 'https://auth.example.com/token',
      code_challenge_methods_supported: ['S256']
    }
    MCPClient::Auth::ServerMetadata.new(**defaults, **overrides)
  end

  describe MCPClient::Auth::ServerMetadata do
    it 'parses client_id_metadata_document_supported from AS metadata (string keys)' do
      metadata = described_class.from_h(
        'issuer' => 'https://auth.example.com',
        'authorization_endpoint' => 'https://auth.example.com/authorize',
        'token_endpoint' => 'https://auth.example.com/token',
        'client_id_metadata_document_supported' => true
      )

      expect(metadata.client_id_metadata_document_supported).to be(true)
      expect(metadata.supports_client_id_metadata_documents?).to be(true)
    end

    it 'parses an explicit false value (symbol keys) without coercing it to nil' do
      metadata = described_class.from_h(
        issuer: 'https://auth.example.com',
        authorization_endpoint: 'https://auth.example.com/authorize',
        token_endpoint: 'https://auth.example.com/token',
        client_id_metadata_document_supported: false
      )

      expect(metadata.client_id_metadata_document_supported).to be(false)
      expect(metadata.supports_client_id_metadata_documents?).to be(false)
    end

    it 'defaults to nil (no CIMD support) when the field is absent' do
      metadata = build_server_metadata

      expect(metadata.client_id_metadata_document_supported).to be_nil
      expect(metadata.supports_client_id_metadata_documents?).to be(false)
      expect(metadata.to_h).not_to have_key(:client_id_metadata_document_supported)
    end

    it 'round-trips client_id_metadata_document_supported through to_h/from_h' do
      metadata = build_server_metadata(client_id_metadata_document_supported: true)
      restored = described_class.from_h(metadata.to_h)

      expect(metadata.to_h[:client_id_metadata_document_supported]).to be(true)
      expect(restored.client_id_metadata_document_supported).to be(true)
      expect(restored.supports_client_id_metadata_documents?).to be(true)
    end

    it 'round-trips an explicit false through to_h/from_h' do
      metadata = build_server_metadata(client_id_metadata_document_supported: false)
      restored = described_class.from_h(metadata.to_h)

      expect(metadata.to_h[:client_id_metadata_document_supported]).to be(false)
      expect(restored.client_id_metadata_document_supported).to be(false)
    end
  end

  describe MCPClient::Auth::OAuthProvider do
    describe 'client_id_metadata_url configuration' do
      it 'accepts a client_id_metadata_url option and exposes it' do
        provider = described_class.new(server_url: server_url, client_id_metadata_url: client_id_metadata_url)

        expect(provider.client_id_metadata_url).to eq(client_id_metadata_url)
      end

      it 'defaults to nil' do
        provider = described_class.new(server_url: server_url)

        expect(provider.client_id_metadata_url).to be_nil
      end

      it 'rejects a non-HTTPS URL with ArgumentError' do
        expect do
          described_class.new(server_url: server_url,
                              client_id_metadata_url: 'http://app.example.com/client-metadata.json')
        end.to raise_error(ArgumentError, /https/i)
      end

      it 'rejects a URL without a path component with ArgumentError' do
        expect do
          described_class.new(server_url: server_url, client_id_metadata_url: 'https://app.example.com')
        end.to raise_error(ArgumentError, /path/i)
      end

      it 'rejects a string that is not a URL with ArgumentError' do
        expect do
          described_class.new(server_url: server_url, client_id_metadata_url: 'not a url')
        end.to raise_error(ArgumentError)
      end

      it 'validates assignment through the writer as well' do
        provider = described_class.new(server_url: server_url)

        expect { provider.client_id_metadata_url = 'http://insecure.example.com/client.json' }
          .to raise_error(ArgumentError, /https/i)
      end

      it 'allows clearing the URL by assigning nil' do
        provider = described_class.new(server_url: server_url, client_id_metadata_url: client_id_metadata_url)
        provider.client_id_metadata_url = nil

        expect(provider.client_id_metadata_url).to be_nil
      end
    end

    describe 'client registration strategy order' do
      let(:provider) do
        described_class.new(
          server_url: server_url,
          redirect_uri: redirect_uri,
          client_id_metadata_url: client_id_metadata_url,
          logger: logger,
          storage: storage
        )
      end

      context 'when the AS advertises client_id_metadata_document_supported: true' do
        let(:server_metadata) do
          build_server_metadata(
            registration_endpoint: registration_endpoint,
            client_id_metadata_document_supported: true
          )
        end

        it 'uses the metadata URL as the client_id without a registration request' do
          client_info = provider.send(:get_or_register_client, server_metadata)

          expect(client_info.client_id).to eq(client_id_metadata_url)
          expect(client_info.client_secret).to be_nil
          expect(WebMock).not_to have_requested(:post, registration_endpoint)
        end

        it "carries the provider's redirect_uri in the client metadata" do
          client_info = provider.send(:get_or_register_client, server_metadata)

          expect(client_info.metadata.redirect_uris).to eq([redirect_uri])
          expect(client_info.metadata.token_endpoint_auth_method).to eq('none')
        end

        it 'persists the client info so the authorization code exchange can find it' do
          client_info = provider.send(:get_or_register_client, server_metadata)

          expect(storage.get_client_info(server_url)).to eq(client_info)
        end

        it 'still prefers pre-registered/cached client information (priority 1)' do
          preregistered = MCPClient::Auth::ClientInfo.new(
            client_id: 'preregistered-123',
            metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
          )
          storage.set_client_info(server_url, preregistered)

          client_info = provider.send(:get_or_register_client, server_metadata)

          expect(client_info.client_id).to eq('preregistered-123')
        end

        it 'falls back to dynamic client registration when no metadata URL is configured' do
          provider.client_id_metadata_url = nil
          stub_registration = stub_request(:post, registration_endpoint).to_return(
            status: 201,
            headers: { 'Content-Type' => 'application/json' },
            body: { client_id: 'dcr-client-456', redirect_uris: [redirect_uri] }.to_json
          )

          client_info = provider.send(:get_or_register_client, server_metadata)

          expect(client_info.client_id).to eq('dcr-client-456')
          expect(stub_registration).to have_been_requested
        end
      end

      context 'when the AS does not advertise CIMD support' do
        it 'falls back to dynamic client registration despite a configured metadata URL' do
          server_metadata = build_server_metadata(registration_endpoint: registration_endpoint)
          stub_registration = stub_request(:post, registration_endpoint).to_return(
            status: 201,
            headers: { 'Content-Type' => 'application/json' },
            body: { client_id: 'dcr-client-789', redirect_uris: [redirect_uri] }.to_json
          )

          client_info = provider.send(:get_or_register_client, server_metadata)

          expect(client_info.client_id).to eq('dcr-client-789')
          expect(stub_registration).to have_been_requested
        end

        it 'raises ConnectionError when dynamic registration is unavailable too' do
          server_metadata = build_server_metadata

          expect { provider.send(:get_or_register_client, server_metadata) }
            .to raise_error(MCPClient::Errors::ConnectionError, /registration/i)
        end
      end
    end

    describe 'authorization flow with CIMD' do
      it 'sends the metadata URL as client_id in the authorization URL' do
        provider = described_class.new(
          server_url: server_url,
          redirect_uri: redirect_uri,
          client_id_metadata_url: client_id_metadata_url,
          logger: logger,
          storage: storage
        )
        storage.set_server_metadata(
          server_url,
          build_server_metadata(client_id_metadata_document_supported: true)
        )

        auth_url = provider.start_authorization_flow
        params = URI.decode_www_form(URI.parse(auth_url).query).to_h

        expect(params['client_id']).to eq(client_id_metadata_url)
        expect(params['redirect_uri']).to eq(redirect_uri)
      end
    end
  end
end
