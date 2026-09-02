# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 authorization, thirtieth round: when the callback precheck
# rediscovers the authorization server to learn whether it advertises RFC 9207
# `iss` (a legacy PKCE record recorded no answer), a rediscovery that names
# ANOTHER authorization server is not an answer about `iss` — it is the same
# "the authorization server changed during the flow" that
# {OAuthProvider#complete_authorization_flow} rejects. The precheck and the
# error-response path now reject it too, so a browser callback never shows a
# success page for a flow the completion refuses. The same round closes three
# more holes: a discovered authorization/token/registration endpoint is
# classified exactly like a peer-advertised URL (so an authorization server
# document can no longer send the code to a local vhost or an internal
# address unless the configured MCP server is itself loopback); a protected
# resource document rejected as not this resource's stops supplying the
# scopes of a later flow; and a token record a hash-persisting storage
# backend left behind after a delete is no token at all.
RSpec.describe 'MCP 2026-07-28 authorization — round 30' do
  let(:server_url) { 'https://mcp.example.com/mcp' }
  let(:logger) { Logger.new(File::NULL) }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:prm_url) { 'https://mcp.example.com/.well-known/oauth-protected-resource/mcp' }
  let(:old_issuer) { 'https://old.example.com' }
  let(:new_issuer) { 'https://new.example.com' }
  let(:new_as_url) { 'https://new.example.com/.well-known/oauth-authorization-server' }
  let(:redirect_uri) { 'http://localhost:1/cb' }
  let(:state) { 'state-value' }
  let(:storage) { MCPClient::Auth::OAuthProvider::MemoryStorage.new }

  def provider_for(store = storage, url = server_url)
    MCPClient::Auth::OAuthProvider.new(server_url: url, redirect_uri: redirect_uri,
                                       logger: logger, storage: store)
  end

  describe 'a callback whose rediscovery names another authorization server' do
    before do
      # A PKCE record from before iss_parameter_supported was recorded, so the
      # precheck has to rediscover to answer the `iss` question at all.
      storage.set_pkce(server_url,
                       MCPClient::Auth::PKCE.new(issuer: old_issuer, client_id: 'client-1',
                                                 redirect_uri: redirect_uri).to_h)
      storage.set_state(server_url, state)
      storage.set_client_info(server_url,
                              MCPClient::Auth::ClientInfo.new(
                                client_id: 'client-1', issuer: old_issuer, registration_type: 'pre_registered',
                                metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                              ))
      # The resource now delegates to a different authorization server.
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [new_issuer] }.to_json)
      stub_request(:get, new_as_url)
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => new_issuer, 'authorization_endpoint' => "#{new_issuer}/authorize",
                           'token_endpoint' => "#{new_issuer}/token",
                           'code_challenge_methods_supported' => ['S256'],
                           'authorization_response_iss_parameter_supported' => true }.to_json)
    end

    it 'rejects a success response carrying the recorded issuer, as the completion does' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state, iss: old_issuer) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
      expect { provider.complete_authorization_flow('code', state, iss: old_issuer) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
      expect(WebMock).not_to have_requested(:post, "#{old_issuer}/token")
      expect(WebMock).not_to have_requested(:post, "#{new_issuer}/token")
    end

    it 'withholds the error text of an error response carrying the recorded issuer' do
      provider = provider_for
      params = { 'state' => state, 'error' => 'access_denied', 'iss' => old_issuer }
      expect { provider.authorization_error_message(params) }
        .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
    end

    it 'names the recorded issuer in the rejection' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state, iss: old_issuer) }
        .to raise_error(MCPClient::Errors::ConnectionError, /#{Regexp.escape(old_issuer)}/)
    end

    context 'with a metadata record persisted before RFC 9207 was read' do
      before do
        # Same issuer as the request, so nothing before the `iss` question
        # rejects the response — but no recorded answer, so the precheck
        # rediscovers and finds the server replaced.
        storage.set_server_metadata(server_url,
                                    { issuer: old_issuer, authorization_endpoint: "#{old_issuer}/authorize",
                                      token_endpoint: "#{old_issuer}/token",
                                      code_challenge_methods_supported: ['S256'] })
      end

      it 'rejects the callback instead of assuming the iss advertisement' do
        provider = provider_for
        expect { provider.validate_authorization_response!(state, iss: old_issuer) }
          .to raise_error(MCPClient::Errors::ConnectionError, /authorization server changed during the flow/)
      end
    end
  end

  describe 'a callback whose rediscovery still names the recorded authorization server' do
    before do
      storage.set_pkce(server_url,
                       MCPClient::Auth::PKCE.new(issuer: old_issuer, client_id: 'client-1',
                                                 redirect_uri: redirect_uri).to_h)
      storage.set_state(server_url, state)
      storage.set_client_info(server_url,
                              MCPClient::Auth::ClientInfo.new(
                                client_id: 'client-1', issuer: old_issuer, registration_type: 'pre_registered',
                                metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                              ))
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'authorization_servers' => [old_issuer] }.to_json)
      stub_request(:get, 'https://old.example.com/.well-known/oauth-authorization-server')
        .to_return(status: 200, headers: json,
                   body: { 'issuer' => old_issuer, 'authorization_endpoint' => "#{old_issuer}/authorize",
                           'token_endpoint' => "#{old_issuer}/token",
                           'code_challenge_methods_supported' => ['S256'],
                           'authorization_response_iss_parameter_supported' => true }.to_json)
    end

    it 'still accepts a response carrying that issuer' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state, iss: old_issuer) }.not_to raise_error
      params = { 'state' => state, 'error' => 'access_denied', 'iss' => old_issuer }
      expect(provider.authorization_error_message(params)).to eq('access_denied')
    end

    it 'still rejects a response without iss' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /advertises the iss parameter/)
    end
  end

  describe 'a callback whose rediscovery fails outright' do
    before do
      storage.set_pkce(server_url,
                       MCPClient::Auth::PKCE.new(issuer: old_issuer, client_id: 'client-1',
                                                 redirect_uri: redirect_uri).to_h)
      storage.set_state(server_url, state)
      storage.set_client_info(server_url,
                              MCPClient::Auth::ClientInfo.new(
                                client_id: 'client-1', issuer: old_issuer, registration_type: 'pre_registered',
                                metadata: MCPClient::Auth::ClientMetadata.new(redirect_uris: [redirect_uri])
                              ))
      stub_request(:get, prm_url).to_return(status: 500)
      stub_request(:get, 'https://mcp.example.com/.well-known/oauth-protected-resource')
        .to_return(status: 500)
      stub_request(:get, 'https://mcp.example.com/.well-known/oauth-authorization-server')
        .to_return(status: 500)
      stub_request(:get, 'https://mcp.example.com/.well-known/openid-configuration')
        .to_return(status: 500)
    end

    # An answer that cannot be obtained is unknown, not "the server changed":
    # the advertisement is still assumed, so a missing `iss` is refused and a
    # response carrying the recorded issuer is accepted.
    it 'is unknown rather than a changed authorization server' do
      provider = provider_for
      expect { provider.validate_authorization_response!(state) }
        .to raise_error(MCPClient::Errors::ConnectionError, /advertises the iss parameter/)
      expect { provider.validate_authorization_response!(state, iss: old_issuer) }.not_to raise_error
    end
  end
  describe 'a discovered endpoint for a remote MCP server' do
    # The endpoints come out of peer-controlled authorization server metadata,
    # so they are classified exactly like a peer-advertised URL: the
    # plain-HTTP exception needs a loopback configured server too.
    let(:provider) { provider_for }

    ['http://localhost:3000/steal', 'http://app.localhost:3000/steal', 'http://127.1/token',
     'http://127.0.0.1.:9292/token', 'http://[::1]:9292/token',
     'http://[::ffff:127.0.0.1]/token'].each do |url|
      it "refuses the plain-HTTP local vhost #{url}" do
        expect { provider.send(:enforce_https!, url, 'token endpoint') }
          .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)
      end
    end

    ['https://169.254.169.254/token', 'https://10.0.0.5/token', 'https://127.0.0.1/token',
     'https://vault.internal/token', 'https://printer.local/token'].each do |url|
      it "refuses the internal target #{url}" do
        expect { provider.send(:enforce_https!, url, 'token endpoint') }
          .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
      end
    end

    it 'refuses metadata whose token endpoint collects the code at a local vhost' do
      metadata = MCPClient::Auth::ServerMetadata.new(
        issuer: 'https://attacker.example',
        authorization_endpoint: 'https://attacker.example/authorize',
        token_endpoint: 'http://app.localhost:3000/steal',
        code_challenge_methods_supported: ['S256']
      )
      expect { provider.send(:validate_server_metadata!, metadata) }
        .to raise_error(MCPClient::Errors::ConnectionError, /must use HTTPS/)
    end

    it 'still accepts public HTTPS endpoints' do
      expect { provider.send(:enforce_https!, 'https://auth.example.com/token', 'token endpoint') }
        .not_to raise_error
    end
  end

  describe 'a discovered endpoint for a loopback MCP server' do
    let(:provider) { provider_for(storage, 'http://localhost:9292/mcp') }

    it 'still accepts the local stack' do
      ['http://127.0.0.1:9292/token', 'http://app.localhost:9292/token', 'http://[::1]:9292/token',
       'http://127.1:9292/token'].each do |url|
        expect { provider.send(:enforce_https!, url, 'token endpoint') }.not_to raise_error
      end
    end

    it 'still refuses another private address' do
      expect { provider.send(:enforce_https!, 'https://169.254.169.254/token', 'token endpoint') }
        .to raise_error(MCPClient::Errors::ConnectionError, /loopback or private/)
    end
  end

  describe 'a protected resource document that is not this resource' do
    it 'no longer supplies the scopes of the next flow' do
      provider = provider_for
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => 'https://other.example.com/mcp', 'scopes_supported' => ['admin:all'],
                           'authorization_servers' => ['https://auth.example.com'] }.to_json)

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /does not match the server URL/)

      expect(provider.send(:resolved_scope)).to be_nil
    end

    it 'no longer supplies them when it advertises no authorization server either' do
      provider = provider_for
      stub_request(:get, prm_url)
        .to_return(status: 200, headers: json,
                   body: { 'resource' => server_url, 'scopes_supported' => ['admin:all'] }.to_json)

      expect { provider.send(:discover_authorization_server) }
        .to raise_error(MCPClient::Errors::ConnectionError, /does not advertise any authorization_servers/)

      expect(provider.send(:resolved_scope)).to be_nil
    end
  end

  describe 'a token record a hash-persisting storage backend left behind' do
    # `set_token(server_url, nil)` is what a backend without `delete_token`
    # gets, and a backend that persists `token.to_h` writes `nil.to_h` — `{}`.
    # Read back, that is not a token: presenting it would send "Bearer ",
    # attributed to whatever authorization server is current now.
    before do
      storage.set_server_metadata(server_url,
                                  MCPClient::Auth::ServerMetadata.new(
                                    issuer: old_issuer, authorization_endpoint: "#{old_issuer}/authorize",
                                    token_endpoint: "#{old_issuer}/token",
                                    code_challenge_methods_supported: ['S256']
                                  ))
    end

    it 'is no token at all' do
      storage.set_token(server_url, {})
      provider = provider_for

      expect(provider.access_token).to be_nil
      request = Faraday::Request.new
      request.headers = {}
      provider.apply_authorization(request)
      expect(request.headers).not_to have_key('Authorization')
    end

    it 'still reads a persisted hash that carries token bytes' do
      storage.set_token(server_url,
                        MCPClient::Auth::Token.new(access_token: 'tok', expires_in: 3600,
                                                   issuer: old_issuer).to_h)
      provider = provider_for
      expect(provider.access_token&.access_token).to eq('tok')
    end
  end
end
