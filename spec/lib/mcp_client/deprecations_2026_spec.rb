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
    end
    # The registry records when each feature entered the Deprecated state,
    # not the revision that reclassified it.
    expect(MCPClient::Deprecations::REGISTRY[:http_sse_transport][:since]).to eq('2025-03-26')
    expect(MCPClient::Deprecations::REGISTRY[:include_context][:since]).to eq('2025-11-25')
    expect(MCPClient::Deprecations::REGISTRY[:roots][:since]).to eq('2026-07-28')
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

  %w[thisServer allServers].each do |value|
    it "warns when a sampling request asks for #{value} context but still serves it" do
      handler = lambda { |_messages, _prefs, _system, _max|
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'ok' }, 'model' => 'm' }
      }
      c = client(sampling_handler: handler)
      params = { 'messages' => [], 'maxTokens' => 5, 'includeContext' => value }

      result = c.send(:handle_sampling_request, 1, params)

      expect(result['content']['text']).to eq('ok')
      expect(output.string).to include("Received: includeContext #{value}")
      expect(MCPClient::Deprecations.emitted?(:include_context)).to be(true)
    end
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

  it 'warns when the log level is set on a server directly' do
    servers = [
      MCPClient::ServerStdio.new(command: 'echo test', logger: logger),
      MCPClient::ServerHTTP.new(base_url: 'http://localhost:1', logger: logger),
      MCPClient::ServerStreamableHTTP.new(base_url: 'http://localhost:1', logger: logger),
      MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger)
    ]
    servers.each do |server|
      MCPClient::Deprecations.reset!
      output.truncate(0)
      allow(server).to receive(:rpc_request).and_return({})
      allow(server).to receive(:ensure_initialized) if server.respond_to?(:ensure_initialized, true)
      allow(server).to receive(:ensure_connected) if server.respond_to?(:ensure_connected, true)
      allow(server).to receive(:modern?).and_return(true)
      allow(server).to receive(:require_capability!) if server.respond_to?(:require_capability!, true)

      server.log_level = 'debug'

      expect(output.string).to match(/Logging .*deprecated/), server.class.name
    end
  end

  it 'warns when a server sends a log message' do
    server = MCPClient::ServerStdio.new(command: 'echo test', logger: logger)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    c = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], logger: logger)

    c.send(:process_notification, server, 'notifications/message', { 'level' => 'info', 'data' => 'hello' })

    expect(output.string).to match(/Logging .*deprecated/)
  end

  it 'warns that the HTTP+SSE transport is deprecated once it is connected, not when it is built' do
    server = MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger)
    expect(output.string).not_to match(/deprecated/)

    # MCPClient.connect tries SSE while probing a URL that may end up on
    # another transport: a failed attempt must not spend the notice.
    expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError)
    expect(MCPClient::Deprecations.emitted?(:http_sse_transport)).to be(false)

    allow(server).to receive(:start_sse_thread)
    allow(server).to receive(:wait_for_connection)
    allow(server).to receive(:start_activity_monitor)
    server.connect

    expect(output.string).to match(/HTTP\+SSE transport .*deprecated/)
    expect(output.string).to include('Streamable HTTP')
    expect(output.string).to include('2025-03-26')
  end

  it 'does not spend the notice on a logger that drops warnings' do
    quiet = Logger.new(output, level: Logger::ERROR)

    expect(MCPClient::Deprecations.warn(:roots, quiet)).to be(false)
    expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
    expect(MCPClient::Deprecations.warn(:roots, logger)).to be(true)
  end

  it 'swallows a logger failure and leaves the notice for a later use' do
    broken = Object.new
    def broken.warn(_message) = raise(IOError, 'closed stream')

    expect(MCPClient::Deprecations.warn(:roots, broken)).to be(false)
    expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
    expect(MCPClient::Deprecations.warn(:roots, logger)).to be(true)
  end

  it 'keeps serving deprecated features when the logger fails' do
    broken = Logger.new(StringIO.new)
    def broken.warn(*) = raise(IOError, 'closed stream')
    handler = lambda { |_messages, _prefs, _system, _max|
      { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'ok' }, 'model' => 'm' }
    }
    c = MCPClient::Client.new(mcp_server_configs: [], logger: broken, sampling_handler: handler, roots: roots)
    params = { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'thisServer' }
    expect(c.send(:handle_sampling_request, 1, params)['content']['text']).to eq('ok')
    expect { c.log_level = 'debug' }.not_to raise_error

    server = MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: broken)
    allow(server).to receive(:start_sse_thread)
    allow(server).to receive(:wait_for_connection)
    allow(server).to receive(:start_activity_monitor)
    expect(server.connect).to be(true)
  end

  it 'does not call warn? on a strict Logger double' do
    strict = instance_double(Logger, warn: nil)

    expect(MCPClient::Deprecations.warn(:roots, strict)).to be(true)
  end

  it 'logs outside its lock so a logger may consult the registry' do
    logger.formatter = proc { |severity, _time, _prog, msg| "#{severity} #{MCPClient::Deprecations.emitted?(:logging)} #{msg}\n" }

    expect(MCPClient::Deprecations.warn(:roots, logger)).to be(true)
    expect(output.string).to match(/Roots .*deprecated/)
  end

  it 'emits each notice exactly once under concurrent first uses' do
    threads = Array.new(8) do
      Thread.new do
        MCPClient::Deprecations.warn(:roots, logger)
        MCPClient::Deprecations.warn(:logging, logger)
      end
    end
    threads.each(&:join)

    expect(output.string.scan(/Roots .*deprecated/).size).to eq(1)
    expect(output.string.scan(/Logging .*deprecated/).size).to eq(1)
  end

  it 'stays silent when notices are disabled' do
    MCPClient::Deprecations.enabled = false
    client(roots: roots, sampling_handler: ->(_m, _p, _s, _t) { {} }).log_level = 'debug'
    server = MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger)
    allow(server).to receive(:start_sse_thread)
    allow(server).to receive(:wait_for_connection)
    allow(server).to receive(:start_activity_monitor)
    server.connect

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
    MCPClient::Deprecations.warn(:include_context, logger, detail: "allServers\nWARN forged\u2028more")

    expect(output.string).not_to include("\nWARN forged")
    expect(output.string).not_to include("\u2028")
  end

  it 'bounds the quoted detail' do
    MCPClient::Deprecations.warn(:include_context, logger, detail: 'x' * 5000)

    expect(output.string.length).to be < 1000
    expect(output.string).to include('...')
  end
end
