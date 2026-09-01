# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 placed Roots, Sampling, Logging, the HTTP+SSE transport, the
# includeContext values thisServer / allServers and Dynamic Client
# Registration in the Deprecated state (SEP-2577, SEP-2596, PR #2858). They
# keep working; the client says so once per process and points at the
# suggested migration.
RSpec.describe 'MCP 2026-07-28 deprecations' do
  let(:output) { StringIO.new }
  let(:logger) { Logger.new(output) }

  around do |example|
    MCPClient::Deprecations.enabled = true
    MCPClient::Deprecations.reset!
    example.run
  ensure
    MCPClient::Deprecations.reset!
    MCPClient::Deprecations.enabled = false
  end

  def client(**opts)
    MCPClient::Client.new(mcp_server_configs: [], logger: logger, **opts)
  end

  def roots
    [{ uri: 'file:///tmp', name: 'tmp' }]
  end

  it 'lists every feature the revision placed in the Deprecated state' do
    expect(MCPClient::Deprecations::REGISTRY.keys)
      .to contain_exactly(:roots, :sampling, :logging, :http_sse_transport, :include_context,
                          :dynamic_client_registration)
    MCPClient::Deprecations::REGISTRY.each_value do |entry|
      expect(entry.keys).to include(:feature, :since, :reference, :migration)
      expect(entry[:since]).to eq('2026-07-28')
    end
  end

  it 'warns once when roots are configured' do
    client(roots: roots)
    client(roots: roots)

    expect(output.string.scan(/Roots .*deprecated/).size).to eq(1)
    expect(output.string).to include('SEP-2577')
  end

  it 'stays silent for a client that uses none of the deprecated features' do
    client

    expect(output.string).not_to match(/deprecated/)
  end

  it 'warns when roots are assigned later' do
    c = client
    c.roots = roots

    expect(output.string).to match(/Roots .*deprecated/)
  end

  it 'warns once when a sampling handler is configured' do
    client(sampling_handler: ->(_m, _p, _s, _t) { {} })

    expect(output.string).to match(/Sampling .*deprecated/)
    expect(output.string).to include('LLM provider')
  end

  it 'warns when a sampling request asks for thisServer or allServers context but still serves it' do
    handler = lambda { |_messages, _prefs, _system, _max|
      { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'ok' }, 'model' => 'm' }
    }
    c = client(sampling_handler: handler)
    params = { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'allServers' }

    result = c.send(:handle_sampling_request, 1, params)

    expect(result['content']['text']).to eq('ok')
    expect(output.string).to match(/includeContext.*allServers.*deprecated/i)
  end

  it 'does not mention includeContext for none or an absent field' do
    handler = lambda { |_messages, _prefs, _system, _max|
      { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'ok' }, 'model' => 'm' }
    }
    c = client(sampling_handler: handler)
    output.truncate(0)

    c.send(:handle_sampling_request, 1, { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'none' })
    c.send(:handle_sampling_request, 2, { 'messages' => [], 'maxTokens' => 5 })

    expect(output.string).not_to match(/includeContext/)
  end

  it 'warns when the log level is set' do
    client.log_level = 'debug'

    expect(output.string).to match(/Logging .*deprecated/)
    expect(output.string).to include('stderr')
  end

  it 'warns that the HTTP+SSE transport is deprecated' do
    MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger)

    expect(output.string).to match(/HTTP\+SSE transport .*deprecated/)
    expect(output.string).to include('Streamable HTTP')
  end

  it 'stays silent when notices are disabled' do
    MCPClient::Deprecations.enabled = false
    client(roots: roots, sampling_handler: ->(_m, _p, _s, _t) { {} })
    MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger)

    expect(output.string).not_to match(/deprecated/)
  end

  it 'reports whether a notice was emitted and rejects unknown features' do
    expect(MCPClient::Deprecations.warn(:roots, logger)).to be(true)
    expect(MCPClient::Deprecations.warn(:roots, logger)).to be(false)
    expect { MCPClient::Deprecations.warn(:bogus, logger) }.to raise_error(ArgumentError, /bogus/)
  end

  it 'is loaded by the standalone client entry point' do
    script = "require 'mcp_client/client'; " \
             'MCPClient::Client.new(mcp_server_configs: [], sampling_handler: ->(*) {}, roots: [], ' \
             "logger: Logger.new(File::NULL)).log_level = 'debug'"
    expect(system(RbConfig.ruby, '-Ilib', '-e', script, out: File::NULL, err: File::NULL)).to be(true)
  end

  it 'logs the Dynamic Client Registration notice once and silences it with the rest' do
    meta = MCPClient::Auth::ServerMetadata.new(issuer: 'https://auth.example.com',
                                               authorization_endpoint: 'https://auth.example.com/authorize',
                                               token_endpoint: 'https://auth.example.com/token',
                                               registration_endpoint: 'https://auth.example.com/register',
                                               code_challenge_methods_supported: ['S256'])
    stub_request(:post, 'https://auth.example.com/register')
      .to_return(status: 201, headers: { 'Content-Type' => 'application/json' }, body: { client_id: 'dyn' }.to_json)
    register = lambda do
      provider = MCPClient::Auth::OAuthProvider.new(server_url: 'https://mcp.example.com/mcp',
                                                    redirect_uri: 'http://localhost:8080/callback', logger: logger)
      allow(provider).to receive(:discover_authorization_server).and_return(meta)
      provider.start_authorization_flow
    end

    register.call
    register.call
    expect(output.string.scan(/Dynamic Client Registration .*deprecated/).size).to eq(1)

    MCPClient::Deprecations.enabled = false
    output.truncate(0)
    register.call
    expect(output.string).not_to match(/deprecated/)
  end

  it 'never lets peer-controlled detail forge log lines' do
    MCPClient::Deprecations.warn(:include_context, logger, detail: "allServers\nWARN forged")

    expect(output.string).not_to include("\nWARN forged")
  end
end
