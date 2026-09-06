# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 deprecations, fourteenth review round: a deprecation notice
# is a side effect of the deprecated operation, never a substitute for it —
# the level still reaches every server on its own era's path, deprecated
# capabilities stay advertised on every exchange of a notice-enabled client,
# and the removed completion notification cannot finish an interaction that
# is still waiting on the server's answer.
RSpec.describe 'MCP 2026-07-28 deprecations (round 14)' do
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

  # A stdio transport driven by scripted responses (no subprocess). Returns
  # every request the transport sent.
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

  # A stdio transport that already negotiated the 2025-11-25 handshake and
  # declared logging; only the requests after it are of interest.
  def legacy_stdio(server, capabilities: { 'logging' => {} })
    allow(server).to receive(:ensure_initialized)
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@protocol_version, '2025-11-25')
    server.instance_variable_set(:@capabilities, capabilities)
    server
  end

  # The modern server declares logging: a client only uses what was
  # negotiated, on either era.
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'resources' => {}, 'prompts' => {}, 'logging' => {} } }
  end

  def done
    { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'done' }] } }
  end

  def input_required(requests)
    { 'resultType' => 'input_required', 'requestState' => 'opaque-state', 'inputRequests' => requests }
  end

  describe 'the level a notice-enabled client sets' do
    let(:legacy) { legacy_stdio(MCPClient::ServerStdio.new(command: 'true', logger: logger)) }
    let(:modern) { MCPClient::ServerStdio.new(command: 'true', read_timeout: 1, logger: logger) }
    let(:client) do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(legacy, modern)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'true' },
                                                 { type: 'stdio', command: 'true' }], logger: logger)
    end

    it 'reaches the legacy server as logging/setLevel and the modern one on its next request' do
      legacy_sent = script_stdio(legacy, [{ 'result' => {} }])
      modern_sent = script_stdio(modern, [{ 'result' => discover_result }, done])

      client.log_level = 'debug'
      modern.call_tool('t', {})

      expect(output.string).to include('Logging is deprecated')
      set_level = legacy_sent.find { |request| request['method'] == 'logging/setLevel' }
      expect(set_level).not_to be_nil
      expect(set_level['params']).to eq({ 'level' => 'debug' })
      call = modern_sent.find { |request| request['method'] == 'tools/call' }
      expect(call.dig('params', '_meta', 'io.modelcontextprotocol/logLevel')).to eq('debug')
    end

    it 'still reaches every server once the notice is spent' do
      legacy_sent = script_stdio(legacy, [{ 'result' => {} }, { 'result' => {} }])
      modern_sent = script_stdio(modern, [{ 'result' => discover_result }, done, done])

      client.log_level = 'debug'
      modern.call_tool('t', {})
      client.log_level = 'warning'
      modern.call_tool('t', {})

      expect(output.string.scan('Logging is deprecated').size).to eq(1)
      levels = legacy_sent.select { |request| request['method'] == 'logging/setLevel' }
                          .map { |request| request.dig('params', 'level') }
      expect(levels).to eq(%w[debug warning])
      calls = modern_sent.select { |request| request['method'] == 'tools/call' }
                         .map { |request| request.dig('params', '_meta', 'io.modelcontextprotocol/logLevel') }
      expect(calls).to eq(%w[debug warning])
    end

    it 'skips only the legacy server whose negotiated set lacks logging' do
      legacy_sent = script_stdio(legacy_stdio(legacy, capabilities: { 'tools' => {} }), [])
      modern_sent = script_stdio(modern, [{ 'result' => discover_result }, done])

      client.log_level = 'debug'
      modern.call_tool('t', {})

      expect(legacy_sent).to be_empty
      call = modern_sent.find { |request| request['method'] == 'tools/call' }
      expect(call.dig('params', '_meta', 'io.modelcontextprotocol/logLevel')).to eq('debug')
    end
  end

  describe 'the level set through a logger that writes nothing' do
    it 'is carried by the next modern request all the same' do
      server = MCPClient::ServerStdio.new(command: 'true', read_timeout: 1, logger: Logger.new(nil))
      sent = script_stdio(server, [{ 'result' => discover_result }, done])

      server.log_level = 'debug'
      server.call_tool('t', {})

      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)
      call = sent.find { |request| request['method'] == 'tools/call' }
      expect(call.dig('params', '_meta', 'io.modelcontextprotocol/logLevel')).to eq('debug')
    end

    it 'is sent to a legacy server all the same' do
      server = legacy_stdio(MCPClient::ServerStdio.new(command: 'true', logger: Logger.new(nil)))
      sent = script_stdio(server, [{ 'result' => {} }])

      server.log_level = 'debug'

      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)
      expect(sent.map { |request| request['method'] }).to eq(['logging/setLevel'])
    end
  end

  describe 'the capabilities a notice-enabled client keeps advertising' do
    let(:server) { MCPClient::ServerStdio.new(command: 'true', read_timeout: 1, logger: logger) }
    let(:url_params) do
      { 'mode' => 'url', 'message' => 'Visit to authorize', 'url' => 'https://example.com/auth' }
    end
    let(:declared) do
      { 'elicitation' => { 'form' => {}, 'url' => {} }, 'roots' => {}, 'sampling' => {} }
    end

    before do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'true' }], logger: logger,
        roots: [MCPClient::Root.new(uri: 'file:///work', name: 'work')],
        elicitation_handler: ->(_message, _metadata) { { 'action' => 'accept' } },
        sampling_handler: lambda { |_params|
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'x' }, 'model' => 'm' }
        }
      )
    end

    it 'names them on the first modern request and on the continuation alike' do
      sent = script_stdio(server, [
                            { 'result' => discover_result },
                            { 'result' => input_required('k1' => { 'method' => 'elicitation/create',
                                                                   'params' => url_params }) },
                            done
                          ])

      server.call_tool('authorize', {})

      calls = sent.select { |request| request['method'] == 'tools/call' }
      expect(calls.size).to eq(2)
      calls.each do |request|
        advertised = request.dig('params', '_meta', 'io.modelcontextprotocol/clientCapabilities')
        expect(advertised).to include(declared)
        # 2026-07-28 sampling: a server SHOULD NOT send thisServer/allServers
        # unless sampling.context is declared — it never is.
        expect(advertised['sampling']).not_to have_key('context')
      end
      expect(output.string).to match(/deprecated/)
    end

    it 'advertises roots on every modern request even before any root is configured' do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'true' }], logger: logger)
      sent = script_stdio(server, [{ 'result' => discover_result }, done])

      server.call_tool('t', {})

      call = sent.find { |request| request['method'] == 'tools/call' }
      expect(call.dig('params', '_meta', 'io.modelcontextprotocol/clientCapabilities')).to include('roots' => {})
    end

    it 'names them on the 2025-11-25 handshake' do
      sent = script_stdio(server, [
                            { 'error' => { 'code' => -32_601, 'message' => 'Method not found' } },
                            { 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                                            'serverInfo' => { 'name' => 's', 'version' => '1' } } },
                            done
                          ])

      server.call_tool('t', {})

      handshake = sent.find { |request| request['method'] == 'initialize' }
      expect(handshake).not_to be_nil
      # The handshake still promises notifications/roots/list_changed; a
      # modern session, which has no such notification, omits the flag.
      expect(handshake.dig('params', 'capabilities')).to include(declared.merge('roots' => { 'listChanged' => true }))
    end
  end

  describe 'a 2025-11-25 tool-enabled sampling request the client must refuse' do
    let(:server) { MCPClient::ServerStdio.new(command: 'true', logger: logger) }
    let(:sent) { [] }

    before do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'true' }], logger: logger,
        sampling_handler: lambda { |_params|
          { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'x' }, 'model' => 'm' }
        }
      )
      allow(server).to receive(:send_message) { |message| sent << message }
      server.instance_variable_set(:@protocol_version, '2025-11-25')
    end

    it 'refuses it on the wire and still gives the includeContext notice, as the round-trip path does' do
      server.send(:handle_server_request, {
                    'id' => 9, 'method' => 'sampling/createMessage',
                    'params' => { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'thisServer',
                                  'tools' => [] }
                  })

      expect(sent.size).to eq(1)
      expect(sent.first.dig('error', 'code')).to eq(-32_602)
      expect(sent.first.dig('error', 'message')).to match(/sampling\.tools/)
      expect(output.string).to match(/includeContext thisServer/)
      expect(output.string).to match(/Sampling .*deprecated/)
    end

    # The same MUST holds for a host driving the transport directly: the
    # refusal is the transport's, not the Client callback's.
    it 'is refused by the transport itself when a host serves sampling without declaring tools' do
      transport = MCPClient::ServerStdio.new(command: 'true', logger: logger)
      served = []
      transport.on_sampling_request do |_id, params|
        served << params
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'x' }, 'model' => 'm' }
      end
      allow(transport).to receive(:send_message) { |message| sent << message }
      transport.instance_variable_set(:@protocol_version, '2025-11-25')

      transport.send(:handle_server_request, {
                       'id' => 10, 'method' => 'sampling/createMessage',
                       'params' => { 'messages' => [], 'maxTokens' => 5, 'toolChoice' => { 'mode' => 'auto' } }
                     })

      expect(served).to be_empty
      expect(sent.size).to eq(1)
      expect(sent.first.dig('error', 'code')).to eq(-32_602)
      expect(sent.first.dig('error', 'message')).to match(/sampling\.tools/)
      expect(output.string).to match(/Sampling .*deprecated/)
    end
  end

  describe 'a completion notification arriving during an unfinished modern interaction' do
    let(:server) { MCPClient::ServerStdio.new(command: 'true', read_timeout: 1, logger: logger) }
    let(:seen) { [] }
    let(:notified) { [] }
    let(:url_params) do
      { 'mode' => 'url', 'message' => 'Visit to authorize', 'url' => 'https://example.com/auth' }
    end

    before do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'true' }], logger: logger,
        elicitation_handler: lambda { |_message, metadata|
          seen << metadata
          # The removed notification lands while this elicitation is still
          # being served, as a stale server might send it.
          server.route_notification('notifications/elicitation/complete', { 'elicitationId' => 'elic-1' })
          { 'action' => 'accept' }
        }
      )
    end

    it 'does not finish the interaction: the outcome is still the continuation the server answers' do
      server.on_notification { |method, params| notified << [method, params] }
      sent = script_stdio(server, [
                            { 'result' => discover_result },
                            { 'result' => input_required('k1' => { 'method' => 'elicitation/create',
                                                                   'params' => url_params }) },
                            { 'result' => input_required('k2' => { 'method' => 'elicitation/create',
                                                                   'params' => url_params }) },
                            done
                          ])

      result = server.call_tool('authorize', {})

      expect(result['content'].first['text']).to eq('done')
      expect(sent.map { |request| request['method'] }).to eq(%w[server/discover tools/call tools/call tools/call])
      expect(sent.last.dig('params', 'inputResponses')).to eq({ 'k2' => { 'action' => 'accept' } })
      expect(seen.size).to eq(2)
      # The removed notification is still handed to a generic listener as the
      # raw method it was sent under; nothing in the client acted on it.
      expect(notified).to eq([['notifications/elicitation/complete', { 'elicitationId' => 'elic-1' }]] * 2)
      expect(output.string).not_to match(/error/i)
    end
  end
end
