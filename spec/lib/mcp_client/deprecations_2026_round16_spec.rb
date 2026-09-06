# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 deprecations, sixteenth review round: the notice is a side
# effect, never the operation. Every transport that still offers Logging must
# be shown doing the deprecated work on its own era's path — the HTTP
# transports carry their own `log_level=`, and a notice-only one would have
# passed the suite before this file — and the Roots answer a modern server
# asks for through the multi round-trip pattern must reach the wire under the
# key the server named, with its opaque state echoed back.
RSpec.describe 'MCP 2026-07-28 deprecations (round 16)' do
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

  # Each HTTP transport implements `log_level=` itself. The notice is asserted
  # elsewhere; what is asserted here is the operation the notice is about.
  describe 'the log level an HTTP transport is given' do
    # A transport whose connection is already established, so the setter runs
    # against the era under test without any wire traffic of its own.
    def http_transport(klass, version)
      server = klass.new(base_url: 'http://localhost:1', logger: logger)
      server.instance_variable_set(:@protocol_version, version)
      allow(server).to receive(:ensure_connected)
      allow(server).to receive(:ensure_initialized) if server.respond_to?(:ensure_initialized, true)
      server
    end

    [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
      context "with #{klass}" do
        it 'carries it on every later modern request instead of sending logging/setLevel' do
          server = http_transport(klass, '2026-07-28')
          expect(server).to be_modern
          sent = []
          allow(server).to receive(:rpc_request) { |method, params| sent << [method, params] }

          server.log_level = 'debug'

          expect(sent).to be_empty
          expect(server.with_request_meta({ 'name' => 'tool' })['_meta']['io.modelcontextprotocol/logLevel'])
            .to eq('debug')
        end

        it 'sends logging/setLevel on a legacy session' do
          server = http_transport(klass, '2025-06-18')
          expect(server).not_to be_modern
          allow(server).to receive(:require_capability!)
          sent = []
          allow(server).to receive(:rpc_request) { |method, params| sent << [method, params] }

          server.log_level = 'debug'

          expect(sent.size).to eq(1)
          method, params = sent.first
          expect(method).to eq('logging/setLevel')
          expect(params.transform_keys(&:to_s)).to eq({ 'level' => 'debug' })
        end

        it 'refuses a level the protocol does not define, before anything goes out' do
          server = http_transport(klass, '2026-07-28')
          sent = []
          allow(server).to receive(:rpc_request) { |method, params| sent << [method, params] }

          expect { server.log_level = 'chatty' }.to raise_error(ArgumentError, /chatty/)
          expect(sent).to be_empty
          expect(server.with_request_meta({ 'name' => 'tool' })['_meta'])
            .not_to have_key('io.modelcontextprotocol/logLevel')
        end
      end
    end

    # The HTTP+SSE transport is itself pre-2026 and negotiates no modern
    # revision, so Logging there is only ever the request path.
    it 'sends logging/setLevel from the HTTP+SSE transport' do
      server = MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger)
      allow(server).to receive(:ensure_initialized)
      allow(server).to receive(:require_capability!)
      sent = []
      allow(server).to receive(:rpc_request) { |method, params| sent << [method, params] }

      server.log_level = 'debug'

      expect(sent.size).to eq(1)
      method, params = sent.first
      expect(method).to eq('logging/setLevel')
      expect(params.transform_keys(&:to_s)).to eq({ 'level' => 'debug' })
    end
  end

  # A stdio transport driven by scripted responses (no subprocess), as the
  # multi round-trip specs drive one. Returns every request it sent.
  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'resources' => {}, 'prompts' => {} } }
  end

  # MCP 2026-07-28 asks for roots through the multi round-trip pattern rather
  # than a server-initiated request. Answering the handler is not enough: the
  # answer has to leave the client under the key the server named, beside the
  # opaque state it must echo, or the server never receives the roots it asked
  # for and the notice stands for nothing.
  describe 'the Roots answer a modern server asks for mid-request' do
    it 'continues the request with the roots under the key the server named' do
      client = MCPClient::Client.new(mcp_server_configs: [MCPClient.stdio_config(command: 'true')],
                                     logger: logger,
                                     roots: [{ uri: 'file:///workspace', name: 'Workspace' }])
      # The constructor's own notice is not what this example is about.
      MCPClient::Deprecations.reset!
      output.truncate(output.rewind)
      server = client.servers.first
      sent = script_stdio(server, [
                            { 'result' => discover_result },
                            { 'result' => { 'resultType' => 'input_required',
                                            'requestState' => 'opaque-state',
                                            'inputRequests' => {
                                              'r1' => { 'method' => 'roots/list', 'params' => {} }
                                            } } },
                            { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'done' }] } }
                          ])

      result = server.call_tool('index', { 'scope' => 'all' })

      expect(result['content'].first['text']).to eq('done')
      expect(sent.map { |request| request['method'] }).to eq(%w[server/discover tools/call tools/call])
      calls = sent.select { |request| request['method'] == 'tools/call' }
      expect(calls.first['params']).not_to have_key('requestState')
      expect(calls.last['params']).to include(
        'name' => 'index',
        'arguments' => { 'scope' => 'all' },
        'requestState' => 'opaque-state',
        'inputResponses' => { 'r1' => { 'roots' => [{ 'uri' => 'file:///workspace', 'name' => 'Workspace' }] } }
      )
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
      expect(output.string).to match(/Roots .*deprecated/)
    end
  end
end
