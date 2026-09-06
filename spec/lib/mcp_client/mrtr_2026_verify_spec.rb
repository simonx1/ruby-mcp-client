# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
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

  # The one HeaderMismatch refresh belongs to the logical request, not to each
  # attempt: the round trips are one tools/call as far as the caller is
  # concerned. A continuation that mismatches again is not going to be fixed
  # by a second tools/list, so the error surfaces instead of looping.
  it 'spends the single HeaderMismatch refresh across the whole round trip' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    http.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
    header = 'Region'
    bodies = []
    mismatch = lambda do |id, name|
      { status: 400, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate('jsonrpc' => '2.0', 'id' => id,
                            'error' => { 'code' => -32_020, 'message' => "Header mismatch: Mcp-Param-#{name}" }) }
    end
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
        case calls
        when 1
          header = 'Zone'
          mismatch.call(body['id'], 'Zone')
        when 2 then json_response(body['id'], input_required({ 'a' => form_elicit_request }, state: 'st'))
        else mismatch.call(body['id'], 'District')
        end
      end
    end

    http.list_tools
    expect { http.call_tool('q', { 'region' => 'eu' }) }.to raise_error(MCPClient::Errors::HeaderMismatchError)

    # Three tools/call requests: the mismatched original, the refreshed one
    # that answered input_required, and the continuation that mismatched
    # again — with no second refresh behind it.
    expect(bodies.count { |b| b['method'] == 'tools/call' }).to eq(3)
    expect(bodies.count { |b| b['method'] == 'tools/list' }).to eq(2)
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

  def send_request(request, _generation = nil)
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
    seen = Queue.new
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    server.on_elicitation_request do |key, _params|
      inside << key
      sleep(0.001) while inside.size < 4 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      # What this thread saw when it gave up waiting. Four means every round
      # trip really was in flight at once; a resolver that serialized them
      # would let each thread through on its own with fewer.
      seen << inside.size
      { 'action' => 'accept', 'content' => { 'key' => key } }
    end

    results = %w[alpha beta gamma delta]
              .map { |name| Thread.new { [name, server.call_tool(name, {})] } }
              .to_h(&:value)

    expect(Array.new(4) { seen.pop }).to all(eq(4))
    # Each thread's own final result came back to it, not another thread's.
    expect(results.transform_values { |r| r['content'].first['text'] })
      .to eq({ 'alpha' => 'alpha', 'beta' => 'beta', 'gamma' => 'gamma', 'delta' => 'delta' })
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

# Review round 3 (codex): MRTR is defined only for tools/call, resources/read
# and prompts/get (basic/patterns/mrtr "Supported Requests"). server/discover
# is not one of them, so an input_required discover answer must be rejected
# before the version and capabilities it carries are applied or cached —
# otherwise the probe records a modern version from an unfinished result and
# the first heartbeat hands that result straight back to the caller.
RSpec.describe 'MCP 2026-07-28 MRTR verification — server/discover never answers input_required' do
  include MrtrVerifyHelpers

  def input_required_discover
    { 'resultType' => 'input_required', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => {}, 'requestState' => 'pending-discovery' }
  end

  it 'rejects an input_required server/discover on stdio without recording the version' do
    server = modern_stdio(protocol: :modern)
    sent = script_stdio(server, [{ 'result' => input_required_discover },
                                 { 'result' => { 'tools' => [] } }])

    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /input_required/)
    expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
    expect(server.instance_variable_get(:@protocol_version)).to be_nil
    expect(server.instance_variable_get(:@last_discover_result)).to be_nil
  end

  it 'does not hand the unfinished discover result back from the first ping on stdio' do
    server = modern_stdio(protocol: :modern)
    script_stdio(server, [{ 'result' => input_required_discover }, { 'result' => input_required_discover }])

    expect { server.ping }.to raise_error(MCPClient::Errors::ModernServerError, /input_required/)
  end

  it 'rejects an input_required server/discover on plain HTTP' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                     protocol: :modern)
    stub_request(:post, 'https://example.com/mcp')
      .to_return { |request| json_response(JSON.parse(request.body)['id'], input_required_discover) }

    expect { http.connect }.to raise_error(MCPClient::Errors::ModernServerError, /input_required/)
    expect(http.instance_variable_get(:@last_discover_result)).to be_nil
    http.cleanup
  end

  it 'rejects an input_required server/discover on Streamable HTTP' do
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                                 protocol: :modern)
    stub_request(:post, 'https://example.com/mcp')
      .to_return { |request| json_response(JSON.parse(request.body)['id'], input_required_discover) }

    expect { server.connect }.to raise_error(MCPClient::Errors::ModernServerError, /input_required/)
    expect(server.instance_variable_get(:@last_discover_result)).to be_nil
    server.cleanup
  end

  it 'still rejects it when a later heartbeat answers input_required' do
    server = modern_stdio(protocol: :modern)
    # The probe succeeds, so the session is no longer freshly probed and the
    # next ping is a real server/discover round trip on the wire.
    script_stdio(server, [{ 'result' => discover_result }, { 'result' => { 'tools' => [] } },
                          { 'result' => input_required_discover }])
    server.list_tools

    expect { server.ping }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
    expect(server.instance_variable_get(:@last_discover_result)).to eq(discover_result)
  end
end

# Review round 3 (codex): every attempt is derived from the CALLER's params,
# never from the previous attempt's. "The client MUST omit fields the server
# did not send in the latest InputRequiredResult" applies to every retry, and
# the caller's own hash must survive the round trip untouched.
RSpec.describe 'MCP 2026-07-28 MRTR verification — continuation fields are rebuilt every attempt' do
  include MrtrVerifyHelpers

  let(:server) { modern_stdio }

  before { server.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => { 'n' => 1 } } } }

  # A result carrying neither field is more than the server is allowed to send
  # ("At least one of inputRequests or requestState MUST be present"); the
  # client tolerates it, and drops everything the previous round left behind.
  # The valid one-field-at-a-time shapes are covered further down.
  it 'drops both continuation fields once the server stops sending them' do
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 'a' => form_elicit_request }, state: 'st1') },
                                 { 'result' => input_required(nil, state: nil) },
                                 { 'result' => { 'content' => [] } }])

    server.call_tool('greet', { 'x' => 1 })

    calls = sent.select { |r| r['method'] == 'tools/call' }
    expect(calls.size).to eq(3)
    expect(calls[1]['params']).to include('inputResponses', 'requestState')
    expect(calls[2]['params']).not_to have_key('inputResponses')
    expect(calls[2]['params']).not_to have_key('requestState')
    expect(calls[2]['params']).to include('name' => 'greet', 'arguments' => { 'x' => 1 })
  end

  it 'drops fulfilled inputResponses when the next round asks only for state' do
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 'a' => form_elicit_request }, state: 'st1') },
                                 { 'result' => input_required(nil, state: 'st2') },
                                 { 'result' => { 'content' => [] } }])

    server.call_tool('greet', {})

    calls = sent.select { |r| r['method'] == 'tools/call' }
    expect(calls[1]['params']['requestState']).to eq('st1')
    expect(calls[2]['params']['requestState']).to eq('st2')
    expect(calls[2]['params']).not_to have_key('inputResponses')
  end

  it 'never carries a previous round key into the next inputResponses map' do
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 'first' => form_elicit_request }, state: 's1') },
                                 { 'result' => input_required({ 'second' => form_elicit_request }, state: 's2') },
                                 { 'result' => { 'content' => [] } }])

    server.call_tool('greet', {})

    calls = sent.select { |r| r['method'] == 'tools/call' }
    expect(calls[1]['params']['inputResponses'].keys).to eq(['first'])
    expect(calls[2]['params']['inputResponses'].keys).to eq(['second'])
  end

  # Each attempt keeps exactly what the LATEST result asked for, so every
  # spelling of a stale continuation field has to go — including the ones the
  # fresh values would not have overwritten. The two rounds are the shapes the
  # server may send: inputs without state, then state without inputs.
  it 'ignores continuation fields the caller supplied, in either key spelling' do
    caller_params = { 'uri' => 'file:///r', 'inputResponses' => { 'stale' => { 'action' => 'accept' } },
                      inputResponses: { 'stale' => { 'action' => 'accept' } },
                      'requestState' => 'stale-string', requestState: 'stale-symbol' }
    untouched = { 'uri' => 'file:///r', 'inputResponses' => { 'stale' => { 'action' => 'accept' } },
                  inputResponses: { 'stale' => { 'action' => 'accept' } },
                  'requestState' => 'stale-string', requestState: 'stale-symbol' }
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 'a' => form_elicit_request }, state: nil) },
                                 { 'result' => input_required(nil, state: 'fresh') },
                                 { 'result' => { 'contents' => [] } }])

    server.rpc_request('resources/read', caller_params)

    reads = sent.select { |r| r['method'] == 'resources/read' }
    expect(reads.size).to eq(3)
    # The server sent inputRequests and no state: neither spelling of the
    # caller's requestState may be presented as one.
    expect(reads[1]['params']['inputResponses'].keys).to eq(['a'])
    expect(reads[1]['params']).not_to have_key(:inputResponses)
    expect(reads[1]['params']).not_to have_key('requestState')
    expect(reads[1]['params']).not_to have_key(:requestState)
    # And now state without inputRequests: no answers ride along.
    expect(reads[2]['params']['requestState']).to eq('fresh')
    expect(reads[2]['params']).not_to have_key(:requestState)
    expect(reads[2]['params']).not_to have_key('inputResponses')
    expect(reads[2]['params']).not_to have_key(:inputResponses)
    expect(caller_params).to eq(untouched)
  end

  it 'leaves the caller params object unmodified across several round trips' do
    caller_params = { 'uri' => 'file:///r' }
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => input_required({ 'a' => form_elicit_request }, state: 's1') },
                          { 'result' => input_required({ 'b' => form_elicit_request }, state: 's2') },
                          { 'result' => { 'contents' => [] } }])

    server.rpc_request('resources/read', caller_params)

    expect(caller_params).to eq({ 'uri' => 'file:///r' })
  end
end

# Review round 3 (codex): SEP-1577 tool-enabled sampling on the round-trip
# path must actually deliver the tool definitions — and the tool_use /
# tool_result loop they exist for — to the host's sampler.
RSpec.describe 'MCP 2026-07-28 MRTR verification — sampling tool definitions reach the handler' do
  include MrtrVerifyHelpers

  def search_tools
    [{ 'name' => 'search', 'description' => 'Search the web',
       'inputSchema' => { 'type' => 'object', 'properties' => { 'q' => { 'type' => 'string' } } } },
     { 'name' => 'fetch', 'inputSchema' => { 'type' => 'object' } }]
  end

  it 'hands the declared tools, toolChoice, messages and maxTokens to the sampler' do
    server = modern_stdio
    server.declare_sampling_tools
    seen = nil
    server.on_sampling_request do |_key, params|
      seen = params
      sampling_result
    end
    request = sampling_request('tools' => search_tools, 'toolChoice' => { 'mode' => 'required' })
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 's' => request }) },
                                 { 'result' => { 'content' => [] } }])

    server.call_tool('t', {})

    expect(seen['tools']).to eq(search_tools)
    expect(seen['toolChoice']).to eq({ 'mode' => 'required' })
    expect(seen['maxTokens']).to eq(100)
    expect(seen['messages'].first['content']['text']).to eq('Capital of France?')
    expect(sent.last['params']['inputResponses']['s']).to eq(sampling_result)
  end

  it 'carries a multi tool_use answer back and the matching tool_result messages forward' do
    server = modern_stdio
    server.declare_sampling_tools
    seen = []
    tool_use = { 'role' => 'assistant', 'model' => 'test-model', 'stopReason' => 'toolUse',
                 'content' => [{ 'type' => 'tool_use', 'id' => 'call_1', 'name' => 'search',
                                 'input' => { 'q' => 'paris' } },
                               { 'type' => 'tool_use', 'id' => 'call_2', 'name' => 'fetch', 'input' => {} }] }
    server.on_sampling_request do |_key, params|
      seen << params['messages']
      seen.size == 1 ? tool_use : sampling_result
    end
    tool_results = [{ 'role' => 'user',
                      'content' => [{ 'type' => 'tool_result', 'toolUseId' => 'call_1',
                                      'content' => [{ 'type' => 'text', 'text' => 'Paris' }] },
                                    { 'type' => 'tool_result', 'toolUseId' => 'call_2',
                                      'content' => [{ 'type' => 'text', 'text' => 'ok' }] }] }]
    second = sampling_request('tools' => search_tools, 'messages' => tool_results)
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required(
                                   { 's' => sampling_request('tools' => search_tools) }, state: 'loop'
                                 ) },
                                 { 'result' => input_required({ 's2' => second }, state: 'loop') },
                                 { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'done' }] } }])

    expect(server.call_tool('t', {})['content'].first['text']).to eq('done')

    calls = sent.select { |r| r['method'] == 'tools/call' }
    expect(calls[1]['params']['inputResponses']['s']).to eq(tool_use)
    expect(calls[1]['params']['inputResponses']['s']['content'].map { |c| c['id'] }).to eq(%w[call_1 call_2])
    expect(seen.last).to eq(tool_results)
    expect(calls[2]['params']['inputResponses'].keys).to eq(['s2'])
  end

  it 'rejects an empty tools array as tool-enabled sampling without the declaration' do
    server = modern_stdio
    invoked = false
    server.on_sampling_request do |_key, _params|
      invoked = true
      sampling_result
    end
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 's' => sampling_request('tools' => []) }) }])

    expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /sampling\.tools/)
    expect(invoked).to be(false)
    expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
  end

  it 'passes every sampling argument through MCPClient::Client to the host handler' do
    stdio = modern_stdio
    seen = nil
    client = client_with(stdio, sampling_supports_tools: true,
                                sampling_handler: lambda { |messages, prefs, system, max, params = nil|
                                  seen = { messages: messages, prefs: prefs, system: system, max: max,
                                           params: params }
                                  sampling_result
                                })
    request = sampling_request('tools' => search_tools, 'toolChoice' => { 'mode' => 'auto' },
                               'systemPrompt' => 'Be terse',
                               'modelPreferences' => { 'hints' => [{ 'name' => 'claude' }] })
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [{ 'name' => 'c', 'inputSchema' => {} }] } },
                                { 'result' => input_required({ 's' => request }) },
                                { 'result' => { 'content' => [] } }])

    client.call_tool('c', {})

    expect(seen[:max]).to eq(100)
    expect(seen[:system]).to eq('Be terse')
    expect(seen[:prefs]).to eq({ 'hints' => [{ 'name' => 'claude' }] })
    expect(seen[:params]['tools']).to eq(search_tools)
    expect(sent.last['params']['inputResponses']['s']).to eq(sampling_result)
  end
end

# Review round 3 (codex): an input handler that answers with anything but a
# result object fails the round trip — InputResponses has no per-key error
# channel, so a partial map must never reach the wire.
RSpec.describe 'MCP 2026-07-28 MRTR verification — handler results that are not result objects' do
  include MrtrVerifyHelpers

  [nil, 'accepted', 42, [{ 'action' => 'accept' }]].each do |bad|
    it "raises InputRequiredError when a handler returns #{bad.class}" do
      server = modern_stdio
      server.on_elicitation_request { |_key, _params| bad }
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required({ 'a' => form_elicit_request }, state: 'st') }])

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError) do |e|
        expect(e.message).to match(/expected a result object/)
        expect(e.request_state).to eq('st')
        expect(e.input_requests).to eq({ 'a' => form_elicit_request })
      end
      expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
    end
  end

  it 'raises InputRequiredError for a symbol-keyed handler error' do
    server = modern_stdio
    server.on_sampling_request { |_key, _params| { error: { message: 'model unavailable' } } }
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 's' => sampling_request }, state: 'st') }])

    expect { server.call_tool('t', {}) }
      .to raise_error(MCPClient::Errors::InputRequiredError, /model unavailable/)
    expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
  end

  it 'fails the whole round trip when one entry of a multi-entry map fails' do
    server = modern_stdio
    fulfilled = []
    server.on_elicitation_request do |key, _params|
      fulfilled << key
      { 'action' => 'accept', 'content' => {} }
    end
    server.on_sampling_request { |_key, _params| { 'error' => { 'code' => -1, 'message' => 'no model' } } }
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 'a' => form_elicit_request,
                                                                's' => sampling_request }, state: 'st') }])

    expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /no model/)
    expect(fulfilled).to eq(['a'])
    expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
  end
end

# Review round 3 (codex): the remaining attempt-level recoveries. The resolver
# sits outside them, so a broken response stream or a version renegotiation
# re-sends the SAME continuation under a new request id — and never asks the
# host to fulfil the round trip a second time.
RSpec.describe 'MCP 2026-07-28 MRTR verification — a continuation survives the remaining recoveries' do
  include MrtrVerifyHelpers

  let(:url) { 'https://example.com/mcp' }

  def sse_event(message)
    "event: message\ndata: #{JSON.generate(message)}\n\n"
  end

  # A response stream that ends without ever carrying the response.
  def truncated_stream
    sse_event('jsonrpc' => '2.0', 'method' => 'notifications/progress', 'params' => { 'progress' => 1 })
  end

  it 're-issues a continuation whose Streamable HTTP response stream closed empty' do
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    fulfilled = 0
    server.on_elicitation_request do |_key, _params|
      fulfilled += 1
      { 'action' => 'accept', 'content' => { 'name' => 'ada' } }
    end
    bodies = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      bodies << body
      calls = bodies.count { |b| b['method'] == 'tools/call' }
      case body['method']
      when 'server/discover' then json_response(body['id'], discover_result)
      when 'tools/call'
        case calls
        when 1 then json_response(body['id'], input_required({ 'a' => form_elicit_request }, state: 'st'))
        when 2 then { status: 200, body: truncated_stream, headers: { 'Content-Type' => 'text/event-stream' } }
        else json_response(body['id'], { 'content' => [{ 'type' => 'text', 'text' => 'done' }] })
        end
      else json_response(body['id'], { 'tools' => [] })
      end
    end

    expect(server.call_tool('t', {})['content'].first['text']).to eq('done')

    calls = bodies.select { |b| b['method'] == 'tools/call' }
    expect(calls.size).to eq(3)
    expect(calls[1]['id']).not_to eq(calls[2]['id'])
    expect(calls[2]['params']).to eq(calls[1]['params'])
    expect(calls[2]['params']['requestState']).to eq('st')
    expect(calls[2]['params']['inputResponses']['a']).to eq({ 'action' => 'accept', 'content' => { 'name' => 'ada' } })
    # The round trip was fulfilled once; the re-issue is a transport-level
    # replay of the same attempt, not a new round trip.
    expect(fulfilled).to eq(1)
    server.cleanup
  end

  # Every other Streamable HTTP round trip here is answered with application/
  # json. The unfinished result and the completion can equally arrive as SSE
  # events, behind a notification on the same stream.
  it 'drives a round trip whose answers arrive as SSE events' do
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    server.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
    bodies = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      bodies << body
      calls = bodies.count { |b| b['method'] == 'tools/call' }
      next json_response(body['id'], discover_result) if body['method'] == 'server/discover'

      result = if calls == 1
                 input_required({ 'a' => form_elicit_request }, state: 'st')
               else
                 { 'content' => [{ 'type' => 'text', 'text' => 'done' }] }
               end
      stream = sse_event('jsonrpc' => '2.0', 'method' => 'notifications/progress',
                         'params' => { 'progressToken' => 'p', 'progress' => calls }) +
               sse_event('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result)
      { status: 200, body: stream, headers: { 'Content-Type' => 'text/event-stream' } }
    end

    expect(server.call_tool('t', {})['content'].first['text']).to eq('done')

    calls = bodies.select { |b| b['method'] == 'tools/call' }
    expect(calls.size).to eq(2)
    expect(calls[0]['id']).not_to eq(calls[1]['id'])
    expect(calls[1]['params']['requestState']).to eq('st')
    expect(calls[1]['params']['inputResponses']['a']).to eq({ 'action' => 'accept', 'content' => { 'name' => 'ada' } })
    server.cleanup
  end

  it 'keeps the continuation through a version renegotiation of the retry' do
    # This client speaks exactly one modern revision, so a second one has to
    # exist for the server to negotiate down to.
    stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2026-07-28 2026-06-18])
    server = modern_stdio
    fulfilled = 0
    server.on_elicitation_request do |_key, _params|
      fulfilled += 1
      { 'action' => 'accept', 'content' => { 'name' => 'ada' } }
    end
    rejected = false
    responses = [{ 'result' => discover_result },
                 { 'result' => input_required({ 'a' => form_elicit_request }, state: 'st') },
                 lambda do
                   rejected = true
                   { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                  'data' => { 'supported' => ['2026-06-18'], 'requested' => '2026-07-28' } } }
                 end,
                 { 'result' => { 'content' => [] } }]
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    allow(server).to receive(:sleep)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift or raise 'no scripted response left'
      responder = responder.call if responder.respond_to?(:call)
      responder.merge('jsonrpc' => '2.0', 'id' => id)
    end

    server.call_tool('t', {})

    expect(rejected).to be(true)
    calls = sent.select { |r| r['method'] == 'tools/call' }
    expect(calls.size).to eq(3)
    expect(calls[1]['id']).not_to eq(calls[2]['id'])
    # Everything but the renegotiated version is re-sent verbatim.
    expect(calls[2]['params'].except('_meta')).to eq(calls[1]['params'].except('_meta'))
    expect(calls[2]['params']['requestState']).to eq('st')
    expect(calls[1]['params']['_meta'][MCPClient::JsonRpcCommon::META_PROTOCOL_VERSION]).to eq('2026-07-28')
    expect(calls[2]['params']['_meta'][MCPClient::JsonRpcCommon::META_PROTOCOL_VERSION]).to eq('2026-06-18')
    expect(fulfilled).to eq(1)
  end

  it 'runs a prompts/get round trip over plain HTTP' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    http.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => { 'tone' => 'formal' } } }
    bodies = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      bodies << body
      result = case body['method']
               when 'server/discover' then discover_result(capabilities: { 'prompts' => {} })
               when 'prompts/get'
                 if body['params'].key?('inputResponses')
                   { 'messages' => [{ 'role' => 'user',
                                      'content' => { 'type' => 'text', 'text' => 'Dear Sir' } }] }
                 else
                   input_required({ 'tone' => form_elicit_request('Tone?') }, state: 'ps')
                 end
               end
      json_response(body['id'], result)
    end

    prompt = http.get_prompt('letter', { 'to' => 'ada' })

    expect(prompt['messages'].first['content']['text']).to eq('Dear Sir')
    gets = bodies.select { |b| b['method'] == 'prompts/get' }
    expect(gets.size).to eq(2)
    expect(gets[1]['params']).to include('name' => 'letter', 'arguments' => { 'to' => 'ada' },
                                         'requestState' => 'ps')
    expect(gets[1]['params']['inputResponses']['tone'])
      .to eq({ 'action' => 'accept', 'content' => { 'tone' => 'formal' } })
    http.cleanup
  end
end

# Review round 3 (codex): two overlapping round trips that use the SAME input
# key, one of which cannot be fulfilled. Nothing may leak between them: the
# failing request raises, the other completes with its own answer.
RSpec.describe 'MCP 2026-07-28 MRTR verification — overlapping round trips with identical input keys' do
  include MrtrVerifyHelpers

  it 'fails only the request whose input could not be fulfilled' do
    responder = lambda do |request|
      case request['method']
      when 'server/discover' then { 'result' => discover_result }
      when 'tools/call'
        answers = request['params']['inputResponses']
        if answers
          { 'result' => { 'content' => [{ 'type' => 'text', 'text' => answers['k']['content']['for'] }] } }
        else
          { 'result' => input_required({ 'k' => form_elicit_request(request['params']['name']) },
                                       state: "state-#{request['params']['name']}") }
        end
      end
    end
    server = MrtrScriptedStdio.new(command: 'echo test', read_timeout: 5, responder: responder)
    inside = Queue.new
    seen = Queue.new
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    server.on_elicitation_request do |key, params|
      raise "unexpected key #{key}" unless key == 'k'

      inside << params['message']
      sleep(0.001) while inside.size < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      # Both round trips have to be in flight for this to prove anything.
      seen << inside.size
      raise 'the user closed the dialog' if params['message'] == 'doomed'

      { 'action' => 'accept', 'content' => { 'for' => params['message'] } }
    end

    fine = Thread.new { server.call_tool('fine', {}) }
    doomed = Thread.new do
      server.call_tool('doomed', {})
    rescue MCPClient::Errors::MCPError => e
      e
    end

    expect(fine.value['content'].first['text']).to eq('fine')
    expect(Array.new(2) { seen.pop }).to all(eq(2))
    expect(doomed.value).to be_a(MCPClient::Errors::InputRequiredError)
    expect(doomed.value.request_state).to eq('state-doomed')
    retries = server.sent.select { |r| r['method'] == 'tools/call' && r['params'].key?('inputResponses') }
    expect(retries.map { |r| r['params']['name'] }).to eq(['fine'])
    expect(retries.first['params']['inputResponses']['k']['content']).to eq({ 'for' => 'fine' })
  end
end

# Review round 3 (codex): the roots/list_changed recipients across a mixed
# fleet, asserting what each session declared and what actually went out.
RSpec.describe 'MCP 2026-07-28 MRTR verification — roots/list_changed across a mixed fleet' do
  include MrtrVerifyHelpers

  it 'writes the notification only on the legacy stdio session that declared roots' do
    legacy = MCPClient::ServerStdio.new(command: 'echo legacy', protocol: :legacy)
    written = []
    legacy.instance_variable_set(:@stdin, double('stdin', flush: nil).tap do |io|
      allow(io).to receive(:puts) { |line| written << line }
    end)
    legacy.instance_variable_set(:@initialized, true)
    legacy.instance_variable_set(:@protocol_version, '2025-11-25')
    modern = modern_stdio
    modern.instance_variable_set(:@initialized, true)
    modern.instance_variable_set(:@protocol_version, '2026-07-28')
    allow(modern).to receive(:rpc_notify).and_call_original
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    http.instance_variable_set(:@protocol_version, '2025-11-25')
    allow(http).to receive(:rpc_notify)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(legacy, modern, http)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' },
                                                        { type: 'stdio', command: 'b' },
                                                        { type: 'http', base_url: 'https://example.com' }])

    client.roots = [{ 'uri' => 'file:///workspace', 'name' => 'ws' }]

    expect(legacy.client_capabilities['roots']).to eq({ 'listChanged' => true })
    expect(modern.client_capabilities['roots']).to eq({})
    expect(http.client_capabilities).not_to have_key('roots')
    notification = JSON.parse(written.last)
    expect(notification).to include('method' => 'notifications/roots/list_changed')
    expect(notification).not_to have_key('id')
    expect(modern).not_to have_received(:rpc_notify)
    expect(http).not_to have_received(:rpc_notify)
    http.cleanup
  end
end

# Review round 3 (codex): the URL-mode consent normalization this PR added is
# shared by the legacy server-initiated path; symbol-keyed handler results
# must travel it the same way.
RSpec.describe 'MCP 2026-07-28 MRTR verification — URL-mode consent on the legacy path' do
  include MrtrVerifyHelpers

  def legacy_stdio_with(handler)
    stdio = MCPClient::ServerStdio.new(command: 'echo legacy', protocol: :legacy)
    written = []
    stdio.instance_variable_set(:@stdin, double('stdin', flush: nil).tap do |io|
      allow(io).to receive(:puts) { |line| written << line }
    end)
    client_with(stdio, elicitation_handler: handler)
    [stdio, written]
  end

  def url_request_message
    { 'id' => 7, 'method' => 'elicitation/create',
      'params' => { 'mode' => 'url', 'url' => 'https://mcp.example.com/c', 'message' => 'Authorize' } }
  end

  it 'answers cancel when a legacy URL elicitation handler returns form-shaped content' do
    stdio, written = legacy_stdio_with(->(_m, _d) { { 'name' => 'ada' } })

    stdio.handle_server_request(url_request_message)

    expect(JSON.parse(written.last)['result']).to eq({ 'action' => 'cancel' })
  end

  it 'accepts a symbol-keyed legacy URL answer and keeps its symbol-keyed _meta' do
    stdio, written = legacy_stdio_with(->(_m, _d) { { action: 'accept', _meta: { 'com.example/r' => 'r-1' } } })

    stdio.handle_server_request(url_request_message)

    expect(JSON.parse(written.last)['result'])
      .to eq({ 'action' => 'accept', '_meta' => { 'com.example/r' => 'r-1' } })
  end

  it 'keeps a symbol-keyed _meta on the modern round-trip answer too' do
    stdio = modern_stdio
    client = client_with(stdio, elicitation_handler: lambda { |_m, _d|
      { action: 'decline', _meta: { 'com.example/r' => 'r-2' } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [{ 'name' => 'c', 'inputSchema' => {} }] } },
                                { 'result' => input_required({ 'auth' => url_elicit_request }, state: 'oob') },
                                { 'result' => { 'content' => [] } }])

    client.call_tool('c', {})

    expect(sent.last['params']['inputResponses']['auth'])
      .to eq({ 'action' => 'decline', '_meta' => { 'com.example/r' => 'r-2' } })
  end
end

# Review round 3 (codex): the round trips above answer a stubbed
# #wait_response. This one runs over a real pipe, so the reader thread,
# handle_line and the id correlation in @pending are the ones under test —
# and the request that follows a continuation must be an ordinary one again.
RSpec.describe 'MCP 2026-07-28 MRTR verification — round trips over real stdio response handling' do
  include MrtrVerifyHelpers

  # Wire the transport's stdout to a pipe that a fake stdin answers into, so
  # every response travels the real reader thread.
  def wire_up(server, &responder)
    reader, writer = IO.pipe
    sent = []
    stdin = double('stdin', flush: nil, closed?: false, close: nil)
    allow(stdin).to receive(:puts) do |line|
      request = JSON.parse(line)
      sent << request
      answer = responder.call(request)
      writer.puts(JSON.generate(answer.merge('jsonrpc' => '2.0', 'id' => request['id']))) if answer
    end
    server.instance_variable_set(:@stdin, stdin)
    allow(server).to receive(:connect) do
      server.instance_variable_set(:@stdout, reader)
      true
    end
    allow(server).to receive(:start_stderr_reader)
    allow(server).to receive(:sleep)
    [sent, reader, writer]
  end

  it 'correlates a continuation and the ordinary request that follows it' do
    server = modern_stdio(read_timeout: 5)
    server.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
    sent, reader, writer = wire_up(server) do |request|
      case request['method']
      when 'server/discover' then { 'result' => discover_result }
      when 'tools/call'
        if request['params'].key?('inputResponses')
          { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'hi ada' }] } }
        else
          { 'result' => input_required({ 'a' => form_elicit_request }, state: 'st') }
        end
      when 'tools/list' then { 'result' => { 'tools' => [] } }
      end
    end

    begin
      expect(server.call_tool('greet', {})['content'].first['text']).to eq('hi ada')
      expect(server.list_tools).to eq([])

      calls = sent.select { |r| r['method'] == 'tools/call' }
      expect(calls.size).to eq(2)
      expect(calls[0]['id']).not_to eq(calls[1]['id'])
      expect(calls[1]['params']['requestState']).to eq('st')
      expect(sent.last['method']).to eq('tools/list')
      expect(sent.last['params']).not_to have_key('inputResponses')
      expect(sent.last['params']).not_to have_key('requestState')
      expect(server.instance_variable_get(:@pending)).to be_empty
      expect(server.instance_variable_get(:@awaiting)).to be_empty
    ensure
      server.cleanup
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
  end

  it 'rejects an input_required answer to server/discover over the real wire' do
    server = modern_stdio(read_timeout: 5, protocol: :modern)
    sent, reader, writer = wire_up(server) do |_request|
      { 'result' => { 'resultType' => 'input_required', 'supportedVersions' => ['2026-07-28'],
                      'capabilities' => {}, 'requestState' => 'pending-discovery' } }
    end

    begin
      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /input_required/)
      expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
  end
end

# Review round 3 (codex): the discover rejection must not read as a legacy
# rejection either. A server that answered server/discover at all is modern,
# so protocol: :auto must surface the failure rather than fall back to the
# initialize handshake with an unfinished result behind it.
RSpec.describe 'MCP 2026-07-28 MRTR verification — an input_required discover is not a legacy verdict' do
  include MrtrVerifyHelpers

  it 'does not fall back to initialize on an auto-negotiating stdio transport' do
    server = modern_stdio
    sent = script_stdio(server, [{ 'result' => { 'resultType' => 'input_required',
                                                 'supportedVersions' => ['2026-07-28'],
                                                 'capabilities' => {}, 'requestState' => 'pending' } },
                                 { 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {} } }])

    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /input_required/)
    expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
  end

  it 'does not fall back to initialize on an auto-negotiating plain HTTP transport' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    bodies = []
    stub_request(:post, 'https://example.com/mcp').to_return do |request|
      body = JSON.parse(request.body)
      bodies << body['method']
      json_response(body['id'], { 'resultType' => 'input_required', 'supportedVersions' => ['2026-07-28'],
                                  'capabilities' => {}, 'requestState' => 'pending' })
    end

    expect { http.connect }.to raise_error(MCPClient::Errors::ModernServerError, /input_required/)
    expect(bodies).to eq(['server/discover'])
    http.cleanup
  end
end

# Review round 5 (grok): an InputRequiredResult is allowed to carry only
# `requestState` — "At least one of inputRequests or requestState MUST be
# present" (basic/patterns/mrtr) — so an unfinished discover answer need not
# have the DiscoverResult shape at all. The shape test must therefore not be
# what decides the era: `resultType: "input_required"` exists only in
# 2026-07-28, so a peer that sent it is modern and must never be retried with
# the legacy initialize handshake.
RSpec.describe 'MCP 2026-07-28 MRTR verification — an unfinished discover without supportedVersions' do
  include MrtrVerifyHelpers

  let(:state_only_discover) { { 'resultType' => 'input_required', 'requestState' => 'pending-discovery' } }

  it 'does not fall back to initialize on an auto-negotiating stdio transport' do
    server = modern_stdio
    sent = script_stdio(server, [{ 'result' => state_only_discover },
                                 { 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {} } },
                                 { 'result' => { 'tools' => [] } }])

    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /input_required/)
    expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
    expect(server.instance_variable_get(:@protocol_version)).to be_nil
  end

  it 'does not fall back to initialize on an auto-negotiating plain HTTP transport' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    bodies = []
    stub_request(:post, 'https://example.com/mcp').to_return do |request|
      body = JSON.parse(request.body)
      bodies << body['method']
      json_response(body['id'], state_only_discover)
    end

    expect { http.connect }.to raise_error(MCPClient::Errors::ModernServerError, /input_required/)
    expect(bodies).to eq(['server/discover'])
    http.cleanup
  end

  it 'does not fall back to initialize on an auto-negotiating Streamable HTTP transport' do
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    bodies = []
    stub_request(:post, 'https://example.com/mcp').to_return do |request|
      body = JSON.parse(request.body)
      bodies << body['method']
      json_response(body['id'], state_only_discover)
    end

    expect { server.connect }.to raise_error(MCPClient::Errors::ModernServerError, /input_required/)
    expect(bodies).to eq(['server/discover'])
    server.cleanup
  end

  # The era the rejection settles is cached like any other modern verdict, so
  # a second attempt on the same transport does not reopen the question.
  it 'keeps the modern verdict for a later connect on the same transport' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    bodies = []
    stub_request(:post, 'https://example.com/mcp').to_return do |request|
      body = JSON.parse(request.body)
      bodies << body['method']
      json_response(body['id'], state_only_discover)
    end

    2.times { expect { http.connect }.to raise_error(MCPClient::Errors::ModernServerError, /input_required/) }

    expect(bodies).to eq(%w[server/discover server/discover])
    expect(http.instance_variable_get(:@confirmed_era)).to eq(:modern)
    http.cleanup
  end
end

# Review round 5 (codex): the rejection has to survive MCPClient.connect's
# transport detector too. A server that answered server/discover is modern,
# so the legacy SSE and HTTP+POST fallbacks cannot do better — and trying
# them buries the actionable message in a "tried all transports" list.
RSpec.describe 'MCP 2026-07-28 MRTR verification — an unfinished discover through MCPClient.connect' do
  include MrtrVerifyHelpers

  let(:ambiguous_url) { 'https://example.com/api' }

  it 'stops at the modern verdict instead of trying the legacy SSE transport' do
    post_stub = stub_request(:post, ambiguous_url).to_return do |request|
      json_response(JSON.parse(request.body)['id'],
                    { 'resultType' => 'input_required', 'supportedVersions' => ['2026-07-28'],
                      'capabilities' => { 'tools' => {} }, 'requestState' => 'pending-discovery' })
    end
    get_stub = stub_request(:get, ambiguous_url).to_return(status: 200, body: '')

    expect { MCPClient.connect(ambiguous_url, retries: 0) }
      .to raise_error(MCPClient::Errors::ModernServerError, /input_required/)

    expect(post_stub).to have_been_requested.once
    expect(get_stub).not_to have_been_requested
  end

  it 'stops there for the requestState-only shape as well' do
    post_stub = stub_request(:post, ambiguous_url).to_return do |request|
      json_response(JSON.parse(request.body)['id'],
                    { 'resultType' => 'input_required', 'requestState' => 'pending-discovery' })
    end
    get_stub = stub_request(:get, ambiguous_url).to_return(status: 200, body: '')

    expect { MCPClient.connect(ambiguous_url, retries: 0) }
      .to raise_error(MCPClient::Errors::ModernServerError, /input_required/)

    expect(post_stub).to have_been_requested.once
    expect(get_stub).not_to have_been_requested
  end
end

# Review round 5 (grok): ::result_type accepts a symbol-keyed `resultType`
# because a host's response middleware may symbolize the keys of everything
# it parses (Faraday's :json parser with symbolize_names). The rest of the
# InputRequiredResult has to survive that middleware too: reading only the
# String spelling would enter the round-trip loop and then retry WITHOUT
# fulfilling inputRequests and WITHOUT echoing requestState — both client
# MUSTs (basic/patterns/mrtr "Client Requirements").
RSpec.describe 'MCP 2026-07-28 MRTR verification — a symbolized InputRequiredResult' do
  include MrtrVerifyHelpers

  let(:server) { modern_stdio }

  it 'fulfils a symbol-keyed inputRequests map and echoes its symbol-keyed requestState' do
    seen = []
    server.on_elicitation_request do |key, params|
      seen << [key, params]
      { 'action' => 'accept', 'content' => { 'name' => 'ada' } }
    end
    symbolized = { resultType: 'input_required',
                   inputRequests: { 'a' => { method: 'elicitation/create',
                                             params: { mode: 'form', message: 'Who?',
                                                       requestedSchema: { type: 'object' } } } },
                   requestState: 'symbol-state' }
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => symbolized },
                                 { 'result' => { 'content' => [] } }])

    server.call_tool('greet', {})

    calls = sent.select { |r| r['method'] == 'tools/call' }
    expect(calls.size).to eq(2)
    expect(calls[1]['params']['requestState']).to eq('symbol-state')
    expect(calls[1]['params']['inputResponses'])
      .to eq({ 'a' => { 'action' => 'accept', 'content' => { 'name' => 'ada' } } })
    # The handler is host code written against the wire shape, so it sees the
    # protocol's own spelling however the transport parsed it.
    expect(seen.map(&:first)).to eq(['a'])
    expect(seen.first.last).to include('mode' => 'form', 'message' => 'Who?')
  end

  it 'refuses a symbol-keyed tool-enabled sampling request without the declaration' do
    sampled = false
    server.on_sampling_request { |_key, _params| sampled = true }
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => { resultType: 'input_required',
                                                 inputRequests: {
                                                   'c' => { method: 'sampling/createMessage',
                                                            params: { messages: [], tools: [{ name: 't' }] } }
                                                 },
                                                 requestState: 'st' } }])

    expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /sampling.tools/)
    expect(sampled).to be(false)
    expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
  end

  it 'reports a symbol-keyed unfulfillable round trip with its requests and state' do
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { resultType: 'input_required',
                                          inputRequests: { 'a' => { method: 'elicitation/create', params: {} } },
                                          requestState: 'sym' } }])

    expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError) do |error|
      expect(error.request_state).to eq('sym')
      expect(error.input_requests).to eq({ 'a' => { 'method' => 'elicitation/create', 'params' => {} } })
    end
  end
end

# Review round 5 (codex): ensure_initialized runs once, before the resolver;
# every continuation round after that goes straight to the wire. On stdio the
# subprocess can exit while the host is gathering the input — a real prompt
# waits for a person — and MCP 2026-07-28 basic/transports/stdio ("Unexpected
# Termination") says a client SHOULD restart a server that terminated
# unexpectedly. Writing the continuation to the dead process's pipe instead
# loses the whole call to a broken pipe, with the gathered answers in it.
MRTR_STDIO_FIXTURE = File.expand_path('../../support/protocol_era_stdio_server.rb', __dir__)

RSpec.describe 'MCP 2026-07-28 MRTR verification — a continuation against a retired stdio process', :slow do
  around do |example|
    Dir.mktmpdir('mcp-mrtr') do |dir|
      @transcript = File.join(dir, 'transcript.log')
      example.run
    end
  end

  attr_reader :transcript

  after do
    transcript_pids.each do |pid|
      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end

  # @param path [String] transcript path
  # @return [Array<String>] the lines the fixture has flushed so far
  def transcript_lines
    File.exist?(transcript) ? File.readlines(transcript).map(&:strip).reject(&:empty?) : []
  rescue Errno::ENOENT
    []
  end

  # @return [Array<Integer>] pids of every fixture process spawned
  def transcript_pids
    transcript_lines.grep(/\Apid /).map { |line| Integer(line.split.last) }
  end

  # @return [Array<String>] the JSON-RPC methods the fixture processes received
  def transcript_methods
    transcript_lines.grep_v(/\Apid /)
  end

  # @param pid [Integer]
  # @return [Boolean] whether the process still exists (a reaped child does not)
  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # @param what [String] what is being waited for, for the failure message
  # @return [void]
  def wait_for(what, timeout: 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
    raise "timed out after #{timeout}s waiting for #{what}" unless yield
  end

  it 'restarts the server and completes the continuation it was gathering answers for' do
    server = MCPClient::ServerStdio.new(command: [RbConfig.ruby, MRTR_STDIO_FIXTURE, 'mrtr-one-shot', transcript],
                                        read_timeout: 5, discover_timeout: 3)
    server.on_elicitation_request do |_key, _params|
      # The fixture exits as soon as it has asked for input; a host handler is
      # exactly where that wait happens, so the transport retires under it.
      wait_for('the first subprocess to exit') { transcript_pids.first && !process_alive?(transcript_pids.first) }
      wait_for('the transport to be retired') { server.transport_retired? }
      { 'action' => 'accept', 'content' => { 'name' => 'ada' } }
    end

    result = server.call_tool('greet', {})

    # The continuation reached a fresh process with the gathered answer and
    # the state it was issued against, both intact.
    expect(result['content'].first['text']).to eq('ada/st')
    expect(transcript_pids.uniq.size).to eq(2)
    expect(transcript_methods).to eq(%w[server/discover tools/call server/discover tools/call])
  ensure
    server&.cleanup
  end
end

# Review round 5 (grok, codex): the boundaries of the round-trip loop that had
# no example — an inputRequests map that is present but empty, and the three
# ways a registered handler can still fail the round trip (schema-invalid
# content, a rejected sampling request, an unknown action).
RSpec.describe 'MCP 2026-07-28 MRTR verification — round-trip boundaries' do
  include MrtrVerifyHelpers

  def greet_tool
    { 'name' => 'c', 'inputSchema' => { 'type' => 'object' } }
  end

  it 'retries an empty inputRequests map at once, with an empty inputResponses map' do
    server = modern_stdio
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => { 'resultType' => 'input_required', 'inputRequests' => {},
                                                 'requestState' => 'st' } },
                                 { 'result' => { 'content' => [] } }])

    server.call_tool('t', {})

    calls = sent.select { |r| r['method'] == 'tools/call' }
    expect(calls.size).to eq(2)
    # Present-but-empty is not the same as omitted: the server asked for
    # nothing rather than for something out of band, so the answer is an empty
    # map and the retry is not paced.
    expect(calls[1]['params']['inputResponses']).to eq({})
    expect(calls[1]['params']['requestState']).to eq('st')
    expect(server).not_to have_received(:sleep)
  end

  # requestState is opaque: "" is a value the server chose, not an absence, so
  # it is echoed. Only an omitted state is omitted from the retry.
  it 'echoes an empty requestState rather than omitting it' do
    server = modern_stdio
    server.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => {} } }
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => input_required({ 'a' => form_elicit_request }, state: '') },
                                 { 'result' => { 'content' => [] } }])

    server.call_tool('t', {})

    expect(sent.last['params']).to have_key('requestState')
    expect(sent.last['params']['requestState']).to eq('')
  end

  # A continuation is an independent request with an id of its own, so the
  # cancellation a timeout owes the server has to name that id — the original
  # request's was answered a round ago.
  it 'cancels a timed-out continuation by the continuation own request id' do
    server = modern_stdio
    server.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => {} } }
    sent = []
    written = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    stdin = double('stdin', flush: nil, closed?: false, close: nil)
    allow(stdin).to receive(:puts) { |line| written << line }
    server.instance_variable_set(:@stdin, stdin)
    allow(server).to receive(:send_request) { |request| sent << request }
    answers = [{ 'result' => discover_result },
               { 'result' => input_required({ 'a' => form_elicit_request }, state: 'st') },
               :timeout]
    allow(server).to receive(:wait_response) do |id, **_opts|
      answer = answers.shift or raise 'no scripted response left'
      raise MCPClient::Errors::RequestTimeoutError, 'Timeout waiting for response' if answer == :timeout

      answer.merge('jsonrpc' => '2.0', 'id' => id)
    end

    expect { server.rpc_request('resources/read', { 'uri' => 'file:///r' }) }
      .to raise_error(MCPClient::Errors::RequestTimeoutError)

    reads = sent.select { |request| request['method'] == 'resources/read' }
    expect(reads.size).to eq(2)
    expect(reads.last['params']).to include('requestState' => 'st')
    cancelled = written.map { |line| JSON.parse(line) }.select { |m| m['method'] == 'notifications/cancelled' }
    expect(cancelled.size).to eq(1)
    expect(cancelled.first['params']['requestId']).to eq(reads.last['id'])
    expect(reads.last['id']).not_to eq(reads.first['id'])
  end

  # Spec SHOULD (client/elicitation): the client validates the content against
  # requestedSchema and does not transmit content that violates it. There is
  # no per-key error channel in InputResponses, so the round trip fails.
  it 'fails the round trip when the handler content violates the requestedSchema' do
    stdio = modern_stdio
    client = client_with(stdio, elicitation_handler: ->(_message, _schema) { { 'name' => 42 } })
    request = { 'method' => 'elicitation/create',
                'params' => { 'mode' => 'form', 'message' => 'Who?',
                              'requestedSchema' => { 'type' => 'object',
                                                     'properties' => { 'name' => { 'type' => 'string' } },
                                                     'required' => ['name'] } } }
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [greet_tool] } },
                                { 'result' => input_required({ 'a' => request }, state: 'st') }])

    expect { client.call_tool('c', {}) }
      .to raise_error(MCPClient::Errors::InputRequiredError, /schema validation/)
    expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
  end

  # A nil sampling result is the host's rejection signal (-1 "User rejected
  # sampling request" on the legacy back-channel). On the round-trip path
  # there is nowhere to write that error, so the original call fails.
  it 'fails the round trip when the Client sampling handler rejects with nil' do
    stdio = modern_stdio
    # An empty handler returns nil, which is the host's rejection signal.
    client = client_with(stdio, sampling_handler: ->(_messages, _prefs, _system, _max) {})
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [greet_tool] } },
                                { 'result' => input_required({ 's' => sampling_request }, state: 'st') }])

    expect { client.call_tool('c', {}) }
      .to raise_error(MCPClient::Errors::InputRequiredError, /Sampling rejected/)
    expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
  end

  # ElicitResult.action is exactly accept | decline | cancel. An action
  # outside that set is not consent the user gave, so it is answered as cancel
  # — the same verdict URL mode reaches for the same handler result — rather
  # than rewritten into an accept and transmitted with the content attached.
  it 'answers cancel when the form handler returns an action outside the schema' do
    stdio = modern_stdio
    client = client_with(stdio, elicitation_handler: lambda { |_message, _schema|
      { 'action' => 'submit', 'content' => { 'name' => 'ada' } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [greet_tool] } },
                                { 'result' => input_required({ 'a' => form_elicit_request }, state: 'st') },
                                { 'result' => { 'content' => [] } }])

    client.call_tool('c', {})

    expect(sent.last['params']['inputResponses']['a']).to eq({ 'action' => 'cancel' })
  end

  # "If mode is not specified, form mode is assumed" (client/elicitation).
  it 'treats an elicitation request without a mode as form mode' do
    stdio = modern_stdio
    seen = nil
    client = client_with(stdio, elicitation_handler: lambda { |message, schema|
      seen = [message, schema]
      { 'name' => 'ada' }
    })
    request = { 'method' => 'elicitation/create',
                'params' => { 'message' => 'Who?',
                              'requestedSchema' => { 'type' => 'object',
                                                     'properties' => { 'name' => { 'type' => 'string' } } } } }
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [greet_tool] } },
                                { 'result' => input_required({ 'a' => request }, state: 'st') },
                                { 'result' => { 'content' => [] } }])

    client.call_tool('c', {})

    # The handler was given the requestedSchema (form mode), not a URL-mode
    # payload, and its content was transmitted with the accept action form
    # mode carries. URL mode would have stripped the content.
    expect(seen).to eq(['Who?', { 'type' => 'object', 'properties' => { 'name' => { 'type' => 'string' } } }])
    expect(sent.last['params']['inputResponses']['a'])
      .to eq({ 'action' => 'accept', 'content' => { 'name' => 'ada' } })
  end
end
