# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 multi round-trip requests, review round 5 (codex): the
# corners a mutated resolver still survived — a symbolized InputRequiredResult
# whose arrays (messages, tools) must be restored to the wire spelling all the
# way down, the continuation-level recoveries on the HTTP transports (version
# renegotiation and an ordinary retry), two overlapping HTTP round trips each
# spending their own HeaderMismatch refresh, and the sampling histories this
# client hands to the host unvalidated on both eras.
RSpec.describe 'MCP 2026-07-28 multi round-trip requests — round 5' do
  let(:url) { 'https://example.com/mcp' }

  def discover_result(capabilities: { 'tools' => {} })
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => capabilities }
  end

  def input_required(requests, state: 'st')
    result = { 'resultType' => 'input_required', 'requestState' => state }
    result['inputRequests'] = requests unless requests.nil?
    result
  end

  def form_elicit_request(message = 'Who?')
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => message,
                    'requestedSchema' => { 'type' => 'object',
                                           'properties' => { 'name' => { 'type' => 'string' } } } } }
  end

  def sampling_request(extra = {})
    { 'method' => 'sampling/createMessage',
      'params' => { 'messages' => [{ 'role' => 'user',
                                     'content' => { 'type' => 'text', 'text' => 'Capital of France?' } }],
                    'maxTokens' => 100 }.merge(extra) }
  end

  def modern_stdio(**)
    MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, **)
  end

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
      responder = responder.call if responder.respond_to?(:call)
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

  def error_response(id, code, message, data = nil, status: 400)
    error = { 'code' => code, 'message' => message }
    error['data'] = data if data
    { status: status, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'error' => error) }
  end

  let(:tool_list) { { 'tools' => [{ 'name' => 'c', 'inputSchema' => { 'type' => 'object' } }] } }

  describe 'a symbolized InputRequiredResult restored all the way down' do
    # A host's JSON middleware that symbolizes names does so inside arrays
    # too: the sampling messages, the tool definitions. Restoring only the
    # top-level hashes would hand the sampler symbol-keyed messages it never
    # asked for — and the Client adapter reads them by their wire names.
    let(:symbolized_request) do
      { method: 'sampling/createMessage',
        params: { messages: [{ role: 'user', content: { type: 'text', text: 'Who?' } },
                             { role: 'assistant',
                               content: [{ type: 'tool_use', id: 'call_1', name: 'search', input: { q: 'ada' } }] },
                             { role: 'user',
                               content: [{ type: 'tool_result', toolUseId: 'call_1',
                                           content: [{ type: 'text', text: 'Ada Lovelace' }] }] }],
                  tools: [{ name: 'search',
                            inputSchema: { type: 'object', properties: { q: { type: 'string' } } } }],
                  toolChoice: { mode: 'auto' },
                  maxTokens: 5 } }
    end

    let(:wire_messages) do
      [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Who?' } },
       { 'role' => 'assistant',
         'content' => [{ 'type' => 'tool_use', 'id' => 'call_1', 'name' => 'search', 'input' => { 'q' => 'ada' } }] },
       { 'role' => 'user',
         'content' => [{ 'type' => 'tool_result', 'toolUseId' => 'call_1',
                         'content' => [{ 'type' => 'text', 'text' => 'Ada Lovelace' }] }] }]
    end

    let(:wire_tools) do
      [{ 'name' => 'search',
         'inputSchema' => { 'type' => 'object', 'properties' => { 'q' => { 'type' => 'string' } } } }]
    end

    it 'hands the Client sampling adapter string-keyed messages and tools, and answers under the string key' do
      stdio = modern_stdio
      seen = []
      handler = lambda do |messages, _prefs, _system, max_tokens, params|
        seen << [messages, max_tokens, params]
        { 'content' => 'Ada' }
      end
      client = client_with(stdio, sampling_handler: handler, sampling_supports_tools: true)
      sent = script_stdio(stdio, [{ 'result' => discover_result },
                                  { 'result' => tool_list },
                                  { 'result' => { resultType: 'input_required', requestState: 'sym',
                                                  inputRequests: { a: symbolized_request } } },
                                  { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'done' }] } }])

      expect(client.call_tool('c', {})['content'].first['text']).to eq('done')

      messages, max_tokens, params = seen.fetch(0)
      expect(messages).to eq(wire_messages)
      expect(max_tokens).to eq(5)
      expect(params['tools']).to eq(wire_tools)
      expect(params['toolChoice']).to eq({ 'mode' => 'auto' })
      expect(params.keys).to all(be_a(String))
      calls = sent.select { |r| r['method'] == 'tools/call' }
      expect(calls.size).to eq(2)
      expect(calls[1]['params']['requestState']).to eq('sym')
      expect(calls[1]['params']['inputResponses'].keys).to eq(['a'])
      expect(calls[1]['params']['inputResponses']['a'])
        .to include('role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Ada' })
    end

    it 'hands a transport-level sampling handler the whole request on the wire spelling' do
      server = modern_stdio
      server.declare_sampling_tools
      seen = []
      server.on_sampling_request do |key, params|
        seen << [key, params]
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Ada' }, 'model' => 'm',
          'stopReason' => 'endTurn' }
      end
      script_stdio(server, [{ 'result' => discover_result },
                            { 'result' => { resultType: 'input_required', requestState: 'sym',
                                            inputRequests: { a: symbolized_request } } },
                            { 'result' => { 'content' => [] } }])

      server.call_tool('c', {})

      key, params = seen.fetch(0)
      expect(key).to eq('a')
      expect(params).to eq('messages' => wire_messages, 'tools' => wire_tools,
                           'toolChoice' => { 'mode' => 'auto' }, 'maxTokens' => 5)
    end
  end

  describe 'continuation-level recoveries on Streamable HTTP' do
    def streamable(**)
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **)
    end

    it 'keeps the continuation through a version renegotiation of the retry' do
      stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2026-07-28 2026-06-18])
      server = streamable
      fulfilled = 0
      server.on_elicitation_request do |_key, _params|
        fulfilled += 1
        { 'action' => 'accept', 'content' => { 'name' => 'ada' } }
      end
      bodies = []
      versions_seen = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        bodies << body
        calls = bodies.count { |b| b['method'] == 'tools/call' }
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'tools/call'
          versions_seen << request.headers['Mcp-Protocol-Version']
          case calls
          when 1 then json_response(body['id'], input_required({ 'a' => form_elicit_request }, state: 'st'))
          when 2
            error_response(body['id'], -32_022, 'Unsupported protocol version',
                           { 'supported' => ['2026-06-18'], 'requested' => '2026-07-28' })
          else json_response(body['id'], { 'content' => [{ 'type' => 'text', 'text' => 'done' }] })
          end
        else json_response(body['id'], tool_list)
        end
      end

      expect(server.call_tool('c', {})['content'].first['text']).to eq('done')

      calls = bodies.select { |b| b['method'] == 'tools/call' }
      expect(calls.size).to eq(3)
      expect(calls.map { |c| c['id'] }.uniq.size).to eq(3)
      # Everything but the renegotiated version is re-sent verbatim.
      expect(calls[2]['params'].except('_meta')).to eq(calls[1]['params'].except('_meta'))
      expect(calls[2]['params']['requestState']).to eq('st')
      expect(calls[2]['params']['inputResponses']['a']).to eq({ 'action' => 'accept',
                                                                'content' => { 'name' => 'ada' } })
      version = MCPClient::JsonRpcCommon::META_PROTOCOL_VERSION
      expect(calls.map { |c| c['params']['_meta'][version] }).to eq(%w[2026-07-28 2026-07-28 2026-06-18])
      expect(versions_seen).to eq(%w[2026-07-28 2026-07-28 2026-06-18])
      expect(fulfilled).to eq(1)
      server.cleanup
    end

    it 'keeps the continuation through an ordinary retry of an idempotent request' do
      server = streamable(retries: 1, retry_backoff: 0.01)
      fulfilled = 0
      server.on_elicitation_request do |_key, _params|
        fulfilled += 1
        { 'action' => 'accept', 'content' => { 'name' => 'ada' } }
      end
      bodies = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        bodies << body
        reads = bodies.count { |b| b['method'] == 'resources/read' }
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result(capabilities: { 'resources' => {} }))
        when 'resources/read'
          case reads
          when 1 then json_response(body['id'], input_required({ 'a' => form_elicit_request }, state: 'st'))
          when 2 then { status: 503, headers: { 'Content-Type' => 'text/plain' }, body: 'later' }
          else json_response(body['id'], { 'contents' => [{ 'uri' => 'file:///x', 'text' => 'hello' }] })
          end
        end
      end

      result = server.rpc_request('resources/read', { 'uri' => 'file:///x' })

      expect(result['contents'].first['text']).to eq('hello')
      reads = bodies.select { |b| b['method'] == 'resources/read' }
      expect(reads.size).to eq(3)
      expect(reads.map { |r| r['id'] }.uniq.size).to eq(3)
      expect(reads[2]['params']).to eq(reads[1]['params'])
      expect(reads[2]['params']['requestState']).to eq('st')
      expect(reads[2]['params']['inputResponses']['a']).to eq({ 'action' => 'accept',
                                                                'content' => { 'name' => 'ada' } })
      # The round trip was fulfilled once; the retry replays the same attempt.
      expect(fulfilled).to eq(1)
      server.cleanup
    end
  end

  describe 'overlapping round trips on plain HTTP' do
    # The one HeaderMismatch refresh belongs to each logical request: two
    # calls in flight at once that both mismatch each get their own refresh
    # and retry, and neither's spent allowance is charged to the other.
    it 'gives each concurrent tools/call its own HeaderMismatch refresh' do
      http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      http.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
      lock = Mutex.new
      headers = { 'q1' => 'Region', 'q2' => 'Region' }
      calls = Hash.new { |h, k| h[k] = [] }
      arrived = []
      list_count = 0
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'tools/list'
          lock.synchronize { list_count += 1 }
          tools = %w[q1 q2].map do |name|
            schema = { 'type' => 'object',
                       'properties' => { 'region' => { 'type' => 'string',
                                                       'x-mcp-header' => lock.synchronize { headers[name] } } } }
            { 'name' => name, 'inputSchema' => schema }
          end
          json_response(body['id'], { 'tools' => tools })
        when 'tools/call'
          name = body['params']['name']
          first = lock.synchronize do
            calls[name] << request.headers
            calls[name].size == 1
          end
          if first
            # Hold the first rejection until both calls are in flight, so the
            # two refreshes really do overlap — and hand q2 its rejection only
            # once q1's refresh has fetched the list, so a budget shared
            # between the two calls would already be spent when q2 needs it.
            lock.synchronize { arrived << name }
            ready = lambda do
              lock.synchronize { arrived.size >= 2 && (name == 'q1' || list_count >= 2) }
            end
            sleep(0.001) while !ready.call && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            lock.synchronize { headers[name] = 'Zone' }
            error_response(body['id'], -32_020, 'Header mismatch: Mcp-Param-Zone')
          else
            json_response(body['id'], { 'content' => [{ 'type' => 'text', 'text' => name }] })
          end
        end
      end

      http.list_tools
      results = %w[q1 q2].map { |name| Thread.new { [name, http.call_tool(name, { 'region' => 'eu' })] } }
                         .to_h(&:value)

      expect(results.transform_values { |r| r['content'].first['text'] }).to eq({ 'q1' => 'q1', 'q2' => 'q2' })
      expect(arrived.sort).to eq(%w[q1 q2])
      %w[q1 q2].each do |name|
        expect(calls[name].size).to eq(2), name
        expect(calls[name].last['Mcp-Param-Zone']).to eq('eu'), name
      end
      # The initial list plus one refresh per logical call.
      expect(list_count).to eq(3)
      http.cleanup
    end
  end

  describe 'sampling histories this client leaves to the host' do
    # client/sampling (2026-07-28): both parties SHOULD validate message
    # content; the 2025-11-25 text recommends -32602 for a malformed history.
    # This client does not: the history is the host's to judge (it is the one
    # with a model behind it), so a mixed tool-result/text message and a tool
    # use without its result reach the handler exactly as sent, on both eras.
    let(:tools) { [{ 'name' => 'search', 'inputSchema' => { 'type' => 'object' } }] }
    let(:mixed_history) do
      [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Weather?' } },
       { 'role' => 'assistant',
         'content' => [{ 'type' => 'tool_use', 'id' => 'call_1', 'name' => 'search', 'input' => {} }] },
       { 'role' => 'user',
         'content' => [{ 'type' => 'tool_result', 'toolUseId' => 'call_1',
                         'content' => [{ 'type' => 'text', 'text' => 'sunny' }] },
                       { 'type' => 'text', 'text' => 'and tomorrow?' }] }]
    end
    let(:dangling_history) do
      [{ 'role' => 'assistant',
         'content' => [{ 'type' => 'tool_use', 'id' => 'call_9', 'name' => 'search', 'input' => {} }] },
       { 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'never mind' } }]
    end

    it 'hands a mixed or dangling tool history to the modern round-trip sampler unchanged' do
      stdio = modern_stdio
      seen = []
      handler = lambda do |messages, _prefs, _system, _max, params|
        seen << [messages, params['tools']]
        { 'content' => 'ok' }
      end
      client = client_with(stdio, sampling_handler: handler, sampling_supports_tools: true)
      mixed = sampling_request('tools' => tools, 'messages' => mixed_history)
      dangling = sampling_request('tools' => tools, 'messages' => dangling_history)
      sent = script_stdio(stdio, [{ 'result' => discover_result },
                                  { 'result' => tool_list },
                                  { 'result' => input_required({ 's' => mixed }, state: 'one') },
                                  { 'result' => input_required({ 's' => dangling }, state: 'two') },
                                  { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'done' }] } }])

      expect(client.call_tool('c', {})['content'].first['text']).to eq('done')

      expect(seen).to eq([[mixed_history, tools], [dangling_history, tools]])
      answers = sent.select { |r| r['method'] == 'tools/call' }.drop(1).map { |r| r['params']['inputResponses']['s'] }
      expect(answers).to all(include('role' => 'assistant', 'stopReason' => 'endTurn',
                                     'content' => { 'type' => 'text', 'text' => 'ok' }))
    end

    it 'hands a mixed or dangling tool history to the legacy sampling handler unchanged' do
      seen = []
      handler = lambda do |messages, _prefs, _system, _max, params|
        seen << [messages, params['tools']]
        { 'content' => 'ok' }
      end
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'echo test' }],
                                     sampling_handler: handler, sampling_supports_tools: true)

      results = [mixed_history, dangling_history].map do |history|
        client.send(:handle_sampling_request, 7, { 'messages' => history, 'tools' => tools, 'maxTokens' => 10 })
      end

      expect(seen).to eq([[mixed_history, tools], [dangling_history, tools]])
      expect(results).to all(include('role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'ok' }))
      expect(results.map { |r| r.key?('error') }).to eq([false, false])
    end
  end
end
