# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 multi round-trip requests, review round 4 (codex): the
# corners a mutated resolver survived — two input requests sharing a method,
# continuations correlated by id through the real reader with answers
# arriving out of order, the Client sampling adapter on a two-round tool
# loop, a continuation's own timeout over a real pipe, the legacy form
# answer for an action outside the schema, and the malformed shapes of an
# input request.
RSpec.describe 'MCP 2026-07-28 multi round-trip requests — round 4' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
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
      responder.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  def client_with(server, **)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], **)
  end

  # Wire the transport's stdout to a pipe so every response travels the real
  # reader thread; the responder decides what (if anything) to write back,
  # and may write more than one line at once.
  def wire_up(server, &responder)
    reader, writer = IO.pipe
    sent = []
    write_lock = Mutex.new
    stdin = double('stdin', flush: nil, closed?: false, close: nil)
    allow(stdin).to receive(:puts) do |line|
      request = JSON.parse(line)
      sent << request
      answers = responder.call(request)
      answers = [answers] if answers.is_a?(Hash)
      (answers || []).each { |answer| write_lock.synchronize { writer.puts(JSON.generate(answer)) } }
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

  def response_to(request, result)
    { 'jsonrpc' => '2.0', 'id' => request['id'], 'result' => result }
  end

  describe 'two input requests that share a method' do
    it 'fulfils both, each with its own answer, in one round trip' do
      server = modern_stdio
      handled = []
      server.on_elicitation_request do |key, params|
        handled << key
        { 'action' => 'accept', 'content' => { 'name' => "#{key}:#{params['message']}" } }
      end
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required({ 'first' => form_elicit_request('one'),
                                                                  'second' => form_elicit_request('two') }) },
                                   { 'result' => { 'content' => [] } }])

      server.call_tool('t', {})

      expect(handled).to contain_exactly('first', 'second')
      expect(sent.last['params']['inputResponses'])
        .to eq({ 'first' => { 'action' => 'accept', 'content' => { 'name' => 'first:one' } },
                 'second' => { 'action' => 'accept', 'content' => { 'name' => 'second:two' } } })
    end
  end

  describe 'overlapping continuations through the real reader' do
    it 'delivers each continuation its own answer when the answers arrive in reverse order' do
      server = modern_stdio(read_timeout: 5)
      held = Queue.new
      # The two continuations are held until both are on the wire and then
      # answered in REVERSE order, so arrival order and request order differ.
      sent, reader, writer = wire_up(server) do |request|
        case request['method']
        when 'server/discover' then response_to(request, discover_result)
        when 'tools/call'
          name = request['params']['name']
          if request['params'].key?('inputResponses')
            held << request
            next nil if held.size < 2

            Array.new(2) { held.pop }.reverse.map do |continuation|
              params = continuation['params']
              answered_for = params['inputResponses'][params['name']]['content']['for']
              response_to(continuation, { 'content' => [{ 'type' => 'text',
                                                          'text' => "#{params['name']}:#{answered_for}" }] })
            end
          else
            response_to(request, input_required({ name => form_elicit_request(name) }, state: "state-#{name}"))
          end
        end
      end
      inside = Queue.new
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      server.on_elicitation_request do |key, _params|
        inside << key
        sleep(0.001) while inside.size < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        { 'action' => 'accept', 'content' => { 'for' => key } }
      end

      begin
        alpha = Thread.new { server.call_tool('alpha', {}) }
        beta = Thread.new { server.call_tool('beta', {}) }

        expect(alpha.value['content'].first['text']).to eq('alpha:alpha')
        expect(beta.value['content'].first['text']).to eq('beta:beta')
        continuations = sent.select { |r| r['method'] == 'tools/call' && r['params'].key?('inputResponses') }
        expect(continuations.map { |r| [r['params']['name'], r['params']['requestState']] })
          .to contain_exactly(%w[alpha state-alpha], %w[beta state-beta])
        expect(server.instance_variable_get(:@pending)).to be_empty
        expect(server.instance_variable_get(:@awaiting)).to be_empty
      ensure
        server.cleanup
        reader.close unless reader.closed?
        writer.close unless writer.closed?
      end
    end
  end

  describe 'the Client sampling adapter on a two-round tool loop' do
    it 'passes several tool uses through with the toolUse default and forwards the matching results' do
      stdio = modern_stdio
      rounds = []
      handler = lambda do |messages, _prefs, _system, _max, params|
        rounds << [messages, params['tools']]
        if rounds.size == 1
          # No role, model or stopReason: the adapter supplies them.
          { 'content' => [{ 'type' => 'tool_use', 'id' => 'call_1', 'name' => 'search', 'input' => { 'q' => 'paris' } },
                          { 'type' => 'tool_use', 'id' => 'call_2', 'name' => 'fetch', 'input' => {} }] }
        else
          { 'content' => 'Paris' }
        end
      end
      client = client_with(stdio, sampling_handler: handler, sampling_supports_tools: true)
      tools = [{ 'name' => 'search', 'inputSchema' => { 'type' => 'object' } },
               { 'name' => 'fetch', 'inputSchema' => { 'type' => 'object' } }]
      tool_results = [{ 'role' => 'user',
                        'content' => [{ 'type' => 'tool_result', 'toolUseId' => 'call_1',
                                        'content' => [{ 'type' => 'text', 'text' => 'Paris' }] },
                                      { 'type' => 'tool_result', 'toolUseId' => 'call_2',
                                        'content' => [{ 'type' => 'text', 'text' => 'ok' }] }] }]
      sent = script_stdio(stdio, [{ 'result' => discover_result },
                                  { 'result' => { 'tools' => [{ 'name' => 'c',
                                                                'inputSchema' => { 'type' => 'object' } }] } },
                                  { 'result' => input_required({ 's' => sampling_request('tools' => tools) },
                                                               state: 'loop') },
                                  { 'result' => input_required({ 's2' => sampling_request('tools' => tools,
                                                                                          'messages' => tool_results) },
                                                               state: 'loop') },
                                  { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'done' }] } }])

      expect(client.call_tool('c', {})['content'].first['text']).to eq('done')

      calls = sent.select { |r| r['method'] == 'tools/call' }
      first = calls[1]['params']['inputResponses']['s']
      expect(first['content'].map { |c| c['id'] }).to eq(%w[call_1 call_2])
      expect(first['content'].map { |c| c['type'] }).to eq(%w[tool_use tool_use])
      expect(first).to include('role' => 'assistant', 'stopReason' => 'toolUse', 'model' => 'unknown')
      expect(rounds.last).to eq([tool_results, tools])
      expect(calls[2]['params']['inputResponses'])
        .to eq({ 's2' => { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Paris' },
                           'model' => 'unknown', 'stopReason' => 'endTurn' } })
    end
  end

  describe 'a continuation that times out over the real wire' do
    it 'honours the request timeout, cancels by the continuation id and leaves no registration behind' do
      server = modern_stdio(read_timeout: 5, retries: 0)
      server.on_elicitation_request { |_key, _params| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
      sent, reader, writer = wire_up(server) do |request|
        case request['method']
        when 'server/discover' then response_to(request, discover_result)
        when 'tools/call'
          # The continuation is never answered.
          next nil if request['params'].key?('inputResponses')

          response_to(request, input_required({ 'a' => form_elicit_request }))
        end
      end

      begin
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect { server.rpc_request('tools/call', { 'name' => 'greet', 'arguments' => {} }, timeout: 0.2) }
          .to raise_error(MCPClient::Errors::RequestTimeoutError)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2

        calls = sent.select { |r| r['method'] == 'tools/call' }
        expect(calls.size).to eq(2)
        expect(calls.last['params']).to include('requestState' => 'st')
        cancelled = sent.select { |r| r['method'] == 'notifications/cancelled' }
        expect(cancelled.map { |n| n['params']['requestId'] }).to eq([calls.last['id']])
        expect(server.instance_variable_get(:@pending)).to be_empty
        expect(server.instance_variable_get(:@awaiting)).to be_empty
      ensure
        server.cleanup
        reader.close unless reader.closed?
        writer.close unless writer.closed?
      end
    end
  end

  describe 'a legacy form elicitation answered with an action outside the schema' do
    it 'answers cancel without the content' do
      stdio = MCPClient::ServerStdio.new(command: 'echo legacy', protocol: :legacy)
      written = []
      stdio.instance_variable_set(:@stdin, double('stdin', flush: nil).tap do |io|
        allow(io).to receive(:puts) { |line| written << line }
      end)
      client_with(stdio, elicitation_handler: ->(_m, _s) { { 'action' => 'submit', 'content' => { 'name' => 'ada' } } })

      stdio.handle_server_request({ 'id' => 7, 'method' => 'elicitation/create',
                                    'params' => form_elicit_request['params'] })

      answer = JSON.parse(written.last)
      expect(answer['id']).to eq(7)
      expect(answer['result']).to eq({ 'action' => 'cancel' })
      expect(answer).not_to have_key('error')
    end
  end

  describe 'malformed input requests' do
    {
      'a request without a method' => { 'a' => { 'params' => {} } },
      'a request whose method is not a string' => { 'a' => { 'method' => 42, 'params' => {} } }
    }.each do |shape, requests|
      it "rejects #{shape} as malformed" do
        server = modern_stdio
        invoked = false
        server.on_elicitation_request { |_k, _p| invoked = true }
        script_stdio(server, [{ 'result' => discover_result }, { 'result' => input_required(requests) }])

        expect { server.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::InputRequiredError, /Malformed input request "a"/)
        expect(invoked).to be(false)
      end
    end

    it 'rejects an inputRequests array as malformed' do
      server = modern_stdio
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'x' } } }
      script_stdio(server, [{ 'result' => discover_result },
                            { 'result' => input_required([form_elicit_request]) }])

      expect { server.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /inputRequests is not an object/)
    end
  end
  # Review round 4 (grok): tools/call pins Mcp-Name on its continuation; the
  # other two MRTR methods build their params with symbol keys and had no
  # such pin, so a string-only header lookup would drop the header on their
  # retries without reddening anything.
  describe 'Mcp-Name on resources/read and prompts/get continuations (Streamable HTTP)' do
    let(:url) { 'https://example.com/mcp' }
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

    after { server.cleanup }

    def stub_modern_server(answers)
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << { headers: request.headers, body: body }
        result = body['method'] == 'server/discover' ? discover_result : answers.call(body)
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end
      requests
    end

    it 'mirrors the URI into Mcp-Name on the original resources/read and its continuation' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
      requests = stub_modern_server(lambda do |body|
        if body['params'].key?('inputResponses')
          { 'contents' => [{ 'uri' => 'file:///r', 'text' => 'hello' }] }
        else
          input_required({ 'who' => form_elicit_request })
        end
      end)

      contents = server.read_resource('file:///r')

      expect(contents.first.text).to eq('hello')
      reads = requests.select { |r| r[:body]['method'] == 'resources/read' }
      expect(reads.size).to eq(2)
      expect(reads.map { |r| r[:headers]['Mcp-Name'] }).to eq(['file:///r', 'file:///r'])
      expect(reads.map { |r| r[:headers]['Mcp-Method'] }).to eq(%w[resources/read resources/read])
      expect(reads[1][:body]['params']).to include('uri' => 'file:///r', 'requestState' => 'st')
      expect(reads[1][:body]['params']['inputResponses']['who']['content']).to eq({ 'name' => 'ada' })
    end

    it 'mirrors the prompt name into Mcp-Name on the original prompts/get and its continuation' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
      requests = stub_modern_server(lambda do |body|
        if body['params'].key?('inputResponses')
          { 'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'hi' } }] }
        else
          input_required({ 'who' => form_elicit_request })
        end
      end)

      prompt = server.get_prompt('letter', { 'to' => 'ada' })

      expect(prompt['messages'].first['content']['text']).to eq('hi')
      gets = requests.select { |r| r[:body]['method'] == 'prompts/get' }
      expect(gets.size).to eq(2)
      expect(gets.map { |r| r[:headers]['Mcp-Name'] }).to eq(%w[letter letter])
      expect(gets[1][:body]['params']).to include('name' => 'letter', 'arguments' => { 'to' => 'ada' },
                                                  'requestState' => 'st')
      expect(gets[1][:body]['params']['inputResponses']['who']['content']).to eq({ 'name' => 'ada' })
    end
  end
end
