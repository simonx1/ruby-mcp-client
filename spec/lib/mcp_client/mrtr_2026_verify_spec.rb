# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Verification pass over the MCP 2026-07-28 multi round-trip work:
#
#   * SEP-1577: a sampling request carrying `tools` or `toolChoice` is only
#     valid when the client declared `sampling.tools`. The check must live on
#     the transport's own round-trip path, not only in MCPClient::Client.
#   * `notifications/roots/list_changed` may only be sent on a session that
#     declared the roots capability — registering the plain HTTP handlers
#     (which serve the modern round trips) must not make a legacy plain HTTP
#     session a recipient.
#   * A URL-mode ElicitResult keeps the handler's `_meta` (the schema carries
#     it) while `content` is still stripped.
#
# Plus the coverage the same pass found missing: the retry-pacing ceiling, the
# sanitized schema warning, a real Client round trip on plain HTTP, concurrent
# round trips, a continuation surviving transport-level recovery, and the
# legacy paths none of this may disturb.
MRTR_VERIFY_CAPS_META = 'io.modelcontextprotocol/clientCapabilities'

# Scripted transports and the request shapes the round trips use.
module MrtrVerifyHelpers
  def discover_result(capabilities: { 'tools' => {} })
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => capabilities }
  end

  def input_required(requests, state: nil)
    result = { 'resultType' => 'input_required' }
    result['inputRequests'] = requests if requests
    result['requestState'] = state if state
    result
  end

  def sampling_request(extra = {})
    { 'method' => 'sampling/createMessage',
      'params' => { 'messages' => [{ 'role' => 'user',
                                     'content' => { 'type' => 'text', 'text' => 'Capital of France?' } }],
                    'maxTokens' => 100 }.merge(extra) }
  end

  def sampling_result
    { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Paris' },
      'model' => 'test-model', 'stopReason' => 'endTurn' }
  end

  def form_elicit_request(message = 'Who?')
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => message,
                    'requestedSchema' => { 'type' => 'object',
                                           'properties' => { 'name' => { 'type' => 'string' } } } } }
  end

  def url_elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'url', 'url' => 'https://mcp.example.com/connect', 'message' => 'Authorize' } }
  end

  def modern_stdio(**)
    MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, **)
  end

  # Answer a stdio transport's requests from a scripted list, in order, with
  # no subprocess behind it.
  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    allow(server).to receive(:sleep)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift or raise 'no scripted response left'
      responder.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  def client_with(server, **)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], **)
  end

  def json_response(id, result)
    { status: 200, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result) }
  end
end

RSpec.describe 'MCP 2026-07-28 MRTR verification — sampling.tools on the round-trip path' do
  include MrtrVerifyHelpers

  {
    'tools' => { 'tools' => [{ 'name' => 'search', 'inputSchema' => { 'type' => 'object' } }] },
    'toolChoice' => { 'toolChoice' => { 'mode' => 'auto' } }
  }.each do |field, extra|
    it "refuses a sampling input request carrying #{field} when sampling.tools is undeclared" do
      server = modern_stdio
      invoked = false
      server.on_sampling_request do |_key, _params|
        invoked = true
        sampling_result
      end
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required({ 's' => sampling_request(extra) }) }])

      expect { server.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /sampling\.tools/)
      expect(invoked).to be(false)
      expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
    end
  end

  it 'declares plain sampling and fulfils a request without tool fields' do
    server = modern_stdio
    server.on_sampling_request { |_key, _params| sampling_result }
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 's' => sampling_request }) },
                                 { 'result' => { 'content' => [] } }])

    server.call_tool('t', {})

    expect(sent.last['params']['inputResponses']['s']).to eq(sampling_result)
    expect(sent.last['params']['_meta'][MRTR_VERIFY_CAPS_META]['sampling']).to eq({})
  end

  it 'fulfils a tool-enabled sampling request once declare_sampling_tools was called' do
    server = modern_stdio
    server.declare_sampling_tools
    seen = nil
    server.on_sampling_request do |_key, params|
      seen = params
      sampling_result
    end
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required(
                                   { 's' => sampling_request('toolChoice' => { 'mode' => 'auto' }) }
                                 ) },
                                 { 'result' => { 'content' => [] } }])

    server.call_tool('t', {})

    expect(seen['toolChoice']).to eq({ 'mode' => 'auto' })
    expect(sent.last['params']['inputResponses']['s']).to eq(sampling_result)
    expect(sent.last['params']['_meta'][MRTR_VERIFY_CAPS_META]['sampling']).to eq({ 'tools' => {} })
  end

  it 'refuses the same request through MCPClient::Client without the opt-in' do
    stdio = modern_stdio
    invoked = false
    client = client_with(stdio, sampling_handler: lambda { |_messages, _prefs, _system, _max|
      invoked = true
      sampling_result
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [{ 'name' => 'c', 'inputSchema' => {} }] } },
                                { 'result' => input_required(
                                  { 's' => sampling_request('toolChoice' => { 'mode' => 'auto' }) }
                                ) }])

    expect { client.call_tool('c', {}) }
      .to raise_error(MCPClient::Errors::InputRequiredError, /sampling\.tools/)
    expect(invoked).to be(false)
    expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
  end

  it 'fulfils it through MCPClient::Client when sampling_supports_tools is set' do
    stdio = modern_stdio
    client = client_with(stdio, sampling_supports_tools: true,
                                sampling_handler: lambda { |_messages, _prefs, _system, _max, params = nil|
                                  { 'role' => 'assistant', 'model' => 'm', 'stopReason' => 'endTurn',
                                    'content' => { 'type' => 'text',
                                                   'text' => "choice:#{params['toolChoice']['mode']}" } }
                                })
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [{ 'name' => 'c', 'inputSchema' => {} }] } },
                                { 'result' => input_required(
                                  { 's' => sampling_request('toolChoice' => { 'mode' => 'auto' }) }
                                ) },
                                { 'result' => { 'content' => [] } }])

    client.call_tool('c', {})

    expect(sent.last['params']['inputResponses']['s']['content']['text']).to eq('choice:auto')
    expect(sent.last['params']['_meta'][MRTR_VERIFY_CAPS_META]['sampling']).to eq({ 'tools' => {} })
  end
end

RSpec.describe 'MCP 2026-07-28 MRTR verification — roots/list_changed stays on declared capabilities' do
  include MrtrVerifyHelpers

  def stub_legacy_http(posted)
    stub_request(:post, 'https://example.com/mcp').to_return do |request|
      body = JSON.parse(request.body)
      posted << body
      case body['method']
      when 'server/discover' then { status: 400, body: '' }
      when 'initialize'
        json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                    'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
      else { status: 202, body: '' }
      end
    end
  end

  it 'does not notify a plain HTTP server on a legacy session' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    posted = []
    stub_legacy_http(posted)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(http)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'http', base_url: 'https://example.com' }])
    http.connect

    client.roots = [{ 'uri' => 'file:///workspace', 'name' => 'ws' }]

    expect(http.client_capabilities).not_to have_key('roots')
    expect(posted.map { |b| b['method'] }).not_to include('notifications/roots/list_changed')
    http.cleanup
  end

  it 'still notifies a legacy session that declared roots' do
    legacy = MCPClient::ServerStdio.new(command: 'echo legacy', protocol: :legacy)
    legacy.instance_variable_set(:@protocol_version, '2025-11-25')
    allow(MCPClient::ServerFactory).to receive(:create).and_return(legacy)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' }])

    expect(legacy).to receive(:rpc_notify).with('notifications/roots/list_changed', {})

    client.roots = [{ 'uri' => 'file:///tmp', 'name' => 'tmp' }]
  end

  it 'never notifies a modern session, where the notification no longer exists' do
    modern = MCPClient::ServerStdio.new(command: 'echo modern')
    modern.instance_variable_set(:@protocol_version, '2026-07-28')
    allow(MCPClient::ServerFactory).to receive(:create).and_return(modern)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' }])

    expect(modern).not_to receive(:rpc_notify)

    client.roots = [{ 'uri' => 'file:///tmp', 'name' => 'tmp' }]
  end
end

RSpec.describe 'MCP 2026-07-28 MRTR verification — URL-mode elicitation _meta' do
  include MrtrVerifyHelpers

  let(:receipt) { { 'com.example/receipt' => 'receipt-17' } }

  it 'keeps the handler _meta on the round-trip answer and still strips content' do
    stdio = modern_stdio
    client = client_with(stdio, elicitation_handler: lambda { |_message, _details|
      { 'action' => 'accept', '_meta' => { 'com.example/receipt' => 'receipt-17' },
        'content' => { 'ignored' => true } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [{ 'name' => 'c', 'inputSchema' => {} }] } },
                                { 'result' => input_required({ 'auth' => url_elicit_request }, state: 'oob') },
                                { 'result' => { 'content' => [] } }])

    client.call_tool('c', {})

    expect(sent.last['params']['inputResponses']['auth']).to eq({ 'action' => 'accept', '_meta' => receipt })
  end

  it 'keeps _meta on a decline too, and adds none when the handler sent none' do
    [%w[decline decline], %w[cancel cancel]].each do |action, expected|
      stdio = modern_stdio
      client = client_with(stdio, elicitation_handler: ->(_m, _d) { { 'action' => action, '_meta' => receipt } })
      sent = script_stdio(stdio, [{ 'result' => discover_result },
                                  { 'result' => { 'tools' => [{ 'name' => 'c', 'inputSchema' => {} }] } },
                                  { 'result' => input_required({ 'auth' => url_elicit_request }, state: 'oob') },
                                  { 'result' => { 'content' => [] } }])

      client.call_tool('c', {})

      expect(sent.last['params']['inputResponses']['auth'])
        .to eq({ 'action' => expected, '_meta' => receipt })
    end
  end

  it 'sends a bare action when the handler returned no _meta' do
    stdio = modern_stdio
    client = client_with(stdio, elicitation_handler: ->(_m, _d) { { 'action' => 'accept' } })
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [{ 'name' => 'c', 'inputSchema' => {} }] } },
                                { 'result' => input_required({ 'auth' => url_elicit_request }, state: 'oob') },
                                { 'result' => { 'content' => [] } }])

    client.call_tool('c', {})

    expect(sent.last['params']['inputResponses']['auth']).to eq({ 'action' => 'accept' })
  end

  it 'keeps _meta on a legacy server-initiated URL elicitation as well' do
    stdio = MCPClient::ServerStdio.new(command: 'echo legacy', protocol: :legacy)
    written = []
    stdio.instance_variable_set(:@stdin, double('stdin', flush: nil).tap do |io|
      allow(io).to receive(:puts) { |line| written << line }
    end)
    client_with(stdio, elicitation_handler: ->(_m, _d) { { 'action' => 'accept', '_meta' => receipt } })

    stdio.handle_server_request({ 'id' => 7, 'method' => 'elicitation/create',
                                  'params' => { 'mode' => 'url', 'url' => 'https://mcp.example.com/c',
                                                'message' => 'Authorize' } })

    expect(JSON.parse(written.last)['result']).to eq({ 'action' => 'accept', '_meta' => receipt })
  end
end

RSpec.describe 'MCP 2026-07-28 MRTR verification — pacing, logs and plain HTTP' do
  include MrtrVerifyHelpers

  it 'caps the growing retry delay instead of doubling without bound' do
    server = modern_stdio
    responses = [{ 'result' => discover_result }]
    7.times { |i| responses << { 'result' => input_required(nil, state: "s#{i}") } }
    responses << { 'result' => { 'content' => [] } }
    script_stdio(server, responses)
    delays = []
    allow(server).to receive(:sleep) { |seconds| delays << seconds }

    server.call_tool('t', {})

    expect(delays).to eq([0.5, 1, 2, 4, 5, 5, 5])
    expect(delays.max).to eq(MCPClient::JsonRpcCommon::INPUT_RETRY_MAX_DELAY)
  end

  it 'escapes peer-controlled schema text in the elicitation schema warning' do
    output = StringIO.new
    stdio = modern_stdio
    client = client_with(stdio, logger: Logger.new(output),
                                elicitation_handler: ->(_m, _s) { { 'action' => 'decline' } })
    forged = "victim\nWARN  -- : forged log line"
    request = { 'method' => 'elicitation/create',
                'params' => { 'mode' => 'form', 'message' => 'm',
                              'requestedSchema' => { 'type' => 'object',
                                                     'properties' => { forged => { 'type' => 'sneaky' } } } } }
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'result' => { 'tools' => [{ 'name' => 'c', 'inputSchema' => {} }] } },
                         { 'result' => input_required({ 'a' => request }) },
                         { 'result' => { 'content' => [] } }])

    client.call_tool('c', {})

    expect(output.string).to include('Elicitation schema validation warnings')
    expect(output.string).to include('\x0AWARN  -- : forged log line')
    expect(output.string).not_to include("\nWARN  -- : forged log line")
  end

  it 'serves a full MCPClient::Client round trip over plain HTTP' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(http)
    client = MCPClient::Client.new(
      mcp_server_configs: [{ type: 'http', base_url: 'https://example.com' }],
      roots: [{ 'uri' => 'file:///workspace', 'name' => 'ws' }],
      elicitation_handler: ->(_message, _schema) { { 'name' => 'ada' } }
    )
    bodies = []
    stub_request(:post, 'https://example.com/mcp').to_return do |request|
      body = JSON.parse(request.body)
      bodies << body
      result = case body['method']
               when 'server/discover' then discover_result
               when 'tools/list'
                 { 'tools' => [{ 'name' => 'greet', 'inputSchema' => { 'type' => 'object' } }] }
               when 'tools/call'
                 if body['params'].key?('inputResponses')
                   { 'content' => [{ 'type' => 'text', 'text' => 'hi ada' }] }
                 else
                   input_required({ 'who' => form_elicit_request,
                                    'where' => { 'method' => 'roots/list', 'params' => {} } }, state: 'st')
                 end
               end
      json_response(body['id'], result)
    end

    result = client.call_tool('greet', {})

    expect(result['content'].first['text']).to eq('hi ada')
    retry_params = bodies.last['params']
    expect(retry_params['requestState']).to eq('st')
    expect(retry_params['inputResponses']['who']).to eq({ 'action' => 'accept', 'content' => { 'name' => 'ada' } })
    expect(retry_params['inputResponses']['where'])
      .to eq({ 'roots' => [{ 'uri' => 'file:///workspace', 'name' => 'ws' }] })
    client.cleanup
  end

  it 'keeps the continuation through a HeaderMismatch refresh on plain HTTP' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    http.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
    header = 'Region'
    bodies = []
    headers_seen = []
    stub_request(:post, 'https://example.com/mcp').to_return do |request|
      body = JSON.parse(request.body)
      bodies << body
      calls = bodies.count { |b| b['method'] == 'tools/call' }
      case body['method']
      when 'server/discover' then json_response(body['id'], discover_result)
      when 'tools/list'
        schema = { 'type' => 'object',
                   'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } }
        json_response(body['id'], { 'tools' => [{ 'name' => 'q', 'inputSchema' => schema }] })
      when 'tools/call'
        headers_seen << request.headers
        if calls == 1
          json_response(body['id'], input_required({ 'a' => form_elicit_request }, state: 'st'))
        elsif calls == 2
          header = 'Zone'
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_020, 'message' => 'Header mismatch: Mcp-Param-Zone' }) }
        else
          json_response(body['id'], { 'content' => [] })
        end
      end
    end

    http.list_tools
    http.call_tool('q', { 'region' => 'eu' })

    calls = bodies.select { |b| b['method'] == 'tools/call' }
    expect(calls.size).to eq(3)
    expect(calls.last['params']['requestState']).to eq('st')
    expect(calls.last['params']['inputResponses']['a'])
      .to eq({ 'action' => 'accept', 'content' => { 'name' => 'ada' } })
    expect(headers_seen.last['Mcp-Param-Zone']).to eq('eu')
    http.cleanup
  end
end

# A stdio transport whose wire is a Ruby block: each response is computed from
# the request it answers, so concurrent round trips cannot cross-talk through
# a shared script.
class MrtrScriptedStdio < MCPClient::ServerStdio
  attr_reader :sent

  def initialize(responder:, **)
    super(**)
    @responder = responder
    @sent = []
    @sent_lock = Mutex.new
  end

  # ServerStdio#connect answers true after spawning the process; this
  # override keeps that contract, so it cannot be renamed to a predicate.
  def connect # rubocop:disable Naming/PredicateMethod
    true
  end

  def start_reader; end

  def start_stderr_reader; end

  def send_request(request)
    @sent_lock.synchronize { @sent << request }
  end

  def wait_response(id, **_opts)
    request = @sent_lock.synchronize { @sent.find { |r| r['id'] == id } }
    @responder.call(request).merge('jsonrpc' => '2.0', 'id' => id)
  end
end

RSpec.describe 'MCP 2026-07-28 MRTR verification — concurrent round trips' do
  include MrtrVerifyHelpers

  it 'keeps each concurrent round trip scoped to its own request' do
    responder = lambda do |request|
      case request['method']
      when 'server/discover' then { 'result' => discover_result }
      when 'tools/call'
        name = request['params']['name']
        if request['params'].key?('inputResponses')
          { 'result' => { 'content' => [{ 'type' => 'text', 'text' => name }] } }
        else
          { 'result' => input_required({ name => form_elicit_request(name) }, state: "state-#{name}") }
        end
      end
    end
    server = MrtrScriptedStdio.new(command: 'echo test', read_timeout: 5, responder: responder)
    # Handlers are host code and may block (a real user prompt does), so hold
    # every thread inside its own round trip until all four are there: the
    # answers must still be routed per request, never through the transport.
    inside = Queue.new
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    server.on_elicitation_request do |key, _params|
      inside << key
      sleep(0.001) while inside.size < 4 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      { 'action' => 'accept', 'content' => { 'key' => key } }
    end

    %w[alpha beta gamma delta].map { |name| Thread.new { server.call_tool(name, {}) } }.each(&:join)

    expect(inside.size).to eq(4)
    retries = server.sent.select { |r| r['method'] == 'tools/call' && r['params'].key?('inputResponses') }
    expect(retries.size).to eq(4)
    retries.each do |request|
      name = request['params']['name']
      expect(request['params']['requestState']).to eq("state-#{name}")
      expect(request['params']['inputResponses'].keys).to eq([name])
      expect(request['params']['inputResponses'][name]['content']).to eq({ 'key' => name })
    end
  end
end
