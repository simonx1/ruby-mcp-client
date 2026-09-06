# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 multi round-trip requests, review round 6 (codex): the
# out-of-band wait is the host's to steer ("Clients SHOULD provide manual
# controls that let the user retry or cancel the original request",
# client/elicitation "URL Mode"), a cancelled or timed-out wait can be
# resumed from the continuation it carried, the sampling histories this
# client hands to the host are checked against the message rules both
# parties SHOULD validate (client/sampling "Security Considerations"), and
# the HTTP transports carry a per-request timeout into every continuation.
RSpec.describe 'MCP 2026-07-28 multi round-trip requests — round 6' do
  let(:url) { 'https://example.com/mcp' }

  def discover_result(capabilities: { 'tools' => {} })
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => capabilities }
  end

  def state_only(state)
    { 'resultType' => 'input_required', 'requestState' => state }
  end

  def input_required(requests, state: 'st')
    result = { 'resultType' => 'input_required', 'requestState' => state }
    result['inputRequests'] = requests unless requests.nil?
    result
  end

  def elicit_request(message = 'Who?')
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

  def done
    { 'content' => [{ 'type' => 'text', 'text' => 'done' }] }
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

  def calls(sent)
    sent.select { |r| r['method'] == 'tools/call' }
  end

  def streamable(**)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **)
  end

  def json_response(id, result)
    { status: 200, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result) }
  end

  describe 'the out-of-band wait is the host\'s to steer' do
    it 'asks the host before each paced retry and waits by default' do
      stdio = modern_stdio
      waits = []
      stdio.on_input_required_wait { |wait| waits << wait }
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => state_only('s1') },
                                  { 'result' => state_only('s2') }, { 'result' => done }])
      expect(stdio).to receive(:sleep).with(0.5).ordered
      expect(stdio).to receive(:sleep).with(1.0).ordered

      expect(stdio.call_tool('t', {})).to eq(done)

      expect(waits.map(&:round_trip)).to eq([1, 2])
      expect(waits.map(&:request_state)).to eq(%w[s1 s2])
      expect(waits.map(&:delay)).to eq([0.5, 1.0])
      expect(waits.map(&:rpc_method)).to eq(%w[tools/call tools/call])
      expect(waits.last.result).to eq(state_only('s2'))
      expect(calls(sent).map { |r| r['params']['requestState'] }).to eq([nil, 's1', 's2'])
    end

    it 'retries at once when the host says so' do
      stdio = modern_stdio
      stdio.on_input_required_wait { |_wait| :retry }
      expect(stdio).not_to receive(:sleep)
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => state_only('s1') },
                                  { 'result' => done }])

      expect(stdio.call_tool('t', {})).to eq(done)
      expect(calls(sent).size).to eq(2)
    end

    it 'stops on cancel with the continuation the host can resume from, sending nothing more' do
      stdio = modern_stdio
      stdio.on_input_required_wait { |_wait| :cancel }
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => state_only('s1') },
                                  { 'result' => done }])

      expect { stdio.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /cancel/i) do |e|
        expect(e.request_state).to eq('s1')
        expect(e.request_method).to eq('tools/call')
        expect(e.request_params).to eq({ 'name' => 't', 'arguments' => {} })
        expect(e).to be_resumable
      end
      expect(calls(sent).size).to eq(1)
    end

    it 'resumes a cancelled request from its continuation: the state goes back, the answers do not' do
      stdio = modern_stdio
      decisions = [:cancel]
      stdio.on_input_required_wait { |_wait| decisions.shift || :wait }
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => state_only('s1') },
                                  { 'result' => state_only('s2') }, { 'result' => done }])
      error = begin
        stdio.call_tool('t', { 'city' => 'Paris' })
      rescue MCPClient::Errors::InputRequiredError => e
        e
      end

      expect(stdio.resume_input_required(error)).to eq(done)

      resumed = calls(sent).drop(1)
      expect(resumed.map { |r| r['params']['requestState'] }).to eq(%w[s1 s2])
      expect(resumed.map { |r| r['params']['name'] }).to eq(%w[t t])
      expect(resumed.map { |r| r['params']['arguments'] }).to all(eq({ 'city' => 'Paris' }))
      expect(resumed.map { |r| r['params'].key?('inputResponses') }).to eq([false, false])
      expect(resumed.map { |r| r['id'] }.uniq.size).to eq(2)
    end

    it 'resumes through the Client, which routes to the transport that raised' do
      stdio = modern_stdio
      stdio.on_input_required_wait { |_wait| :cancel }
      tools = { 'tools' => [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }] }
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => tools },
                                  { 'result' => state_only('s1') }, { 'result' => done }])
      client = client_with(stdio)
      error = begin
        client.call_tool('t', {})
      rescue MCPClient::Errors::InputRequiredError => e
        e
      end
      stdio.on_input_required_wait { |_wait| :wait }

      expect(client.resume_input_required(error)).to eq(done)
      expect(calls(sent).last['params']['requestState']).to eq('s1')
    end

    it 'refuses to resume an error that carries no continuation' do
      stdio = modern_stdio
      bare = MCPClient::Errors::InputRequiredError.new('x', data: state_only('s1'))

      expect(bare).not_to be_resumable
      expect { stdio.resume_input_required(bare) }.to raise_error(ArgumentError, /continuation/)
    end

    it 'bounds the wait by the request timeout and hands back the continuation' do
      stdio = modern_stdio
      clock = [0.0, 0.0, 0.6, 1.3, 2.5]
      allow(stdio).to receive(:input_wait_clock) { clock.shift || 9.0 }
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => state_only('s1') },
                                  { 'result' => state_only('s2') }, { 'result' => state_only('s3') },
                                  { 'result' => done }])
      stdio.send(:ensure_initialized)

      expect { stdio.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 1.0) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /timeout/i) do |e|
          expect(e.request_state).to eq('s2')
          expect(e).to be_resumable
        end
      expect(calls(sent).size).to eq(2)
    end
  end

  describe 'sampling histories are validated before they reach the host' do
    let(:tools) { [{ 'name' => 'search', 'inputSchema' => { 'type' => 'object' } }] }
    let(:tool_use) do
      { 'role' => 'assistant',
        'content' => [{ 'type' => 'tool_use', 'id' => 'call_1', 'name' => 'search', 'input' => {} }] }
    end
    let(:tool_result) do
      { 'role' => 'user', 'content' => [{ 'type' => 'tool_result', 'toolUseId' => 'call_1',
                                          'content' => [{ 'type' => 'text', 'text' => 'ok' }] }] }
    end
    let(:valid_loop) do
      [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'hi' } }, tool_use, tool_result]
    end
    let(:mixed_result) do
      [tool_use, { 'role' => 'user', 'content' => [tool_result['content'].first,
                                                   { 'type' => 'text', 'text' => 'and?' }] }]
    end
    let(:dangling_use) { [tool_use, { 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'never mind' } }] }
    let(:wrong_id) do
      [tool_use, { 'role' => 'user', 'content' => [tool_result['content'].first.merge('toolUseId' => 'other')] }]
    end
    let(:bad_role) { [{ 'role' => 'system', 'content' => { 'type' => 'text', 'text' => 'x' } }] }
    let(:no_content) { [{ 'role' => 'user' }] }

    def scripted_client(stdio, history, handler)
      client = client_with(stdio, sampling_handler: handler, sampling_supports_tools: true)
      tool_list = { 'tools' => [{ 'name' => 'c', 'inputSchema' => { 'type' => 'object' } }] }
      request = sampling_request('tools' => tools, 'messages' => history)
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => tool_list },
                                  { 'result' => input_required({ 's' => request }) }, { 'result' => done }])
      [client, sent]
    end

    it 'fails the round trip locally for each malformed history, without sending a retry' do
      [mixed_result, dangling_use, wrong_id, bad_role, no_content].each do |history|
        stdio = modern_stdio
        calls_to_host = 0
        handler = lambda do |*|
          calls_to_host += 1
          { 'content' => 'ok' }
        end
        client, sent = scripted_client(stdio, history, handler)

        expect { client.call_tool('c', {}) }
          .to raise_error(MCPClient::Errors::InputRequiredError, /sampling|message/i), history.inspect
        expect(calls_to_host).to eq(0), history.inspect
        expect(calls(sent).size).to eq(1), history.inspect
      end
    end

    it 'accepts a user message of tool results on its own: the spec forbids the mixing, not the message' do
      stdio = modern_stdio
      seen = nil
      client, = scripted_client(stdio, [tool_result], lambda { |messages, *|
        seen = messages
        { 'content' => 'ok' }
      })

      expect(client.call_tool('c', {})).to eq(done)
      expect(seen).to eq([tool_result])
    end

    it 'hands a well-formed tool loop through and answers the round trip' do
      stdio = modern_stdio
      seen = nil
      client, sent = scripted_client(stdio, valid_loop, lambda { |messages, *|
        seen = messages
        { 'content' => 'ok' }
      })

      expect(client.call_tool('c', {})).to eq(done)
      expect(seen).to eq(valid_loop)
      expect(calls(sent).last['params']['inputResponses']['s']).to include('role' => 'assistant')
    end

    it 'answers a legacy sampling request carrying a malformed history with -32602 on the wire' do
      stdio = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      stdio.instance_variable_set(:@protocol_version, '2025-11-25')
      calls_to_host = 0
      handler = lambda do |*|
        calls_to_host += 1
        { 'content' => 'ok' }
      end
      client_with(stdio, sampling_handler: handler, sampling_supports_tools: true)
      written = []
      allow(stdio).to receive(:send_message) { |msg| written << msg }

      stdio.send(:handle_server_request, { 'jsonrpc' => '2.0', 'id' => 7, 'method' => 'sampling/createMessage',
                                           'params' => { 'messages' => mixed_result, 'tools' => tools,
                                                         'maxTokens' => 10 } })

      expect(written.size).to eq(1)
      expect(written.first['id']).to eq(7)
      expect(written.first.dig('error', 'code')).to eq(-32_602)
      expect(written.first).not_to have_key('result')
      expect(calls_to_host).to eq(0)
    end

    it 'answers a legacy sampling request carrying a well-formed history with the sampled message' do
      stdio = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      stdio.instance_variable_set(:@protocol_version, '2025-11-25')
      client_with(stdio, sampling_handler: ->(*) { { 'content' => 'ok', 'model' => 'm' } },
                         sampling_supports_tools: true)
      written = []
      allow(stdio).to receive(:send_message) { |msg| written << msg }

      stdio.send(:handle_server_request, { 'jsonrpc' => '2.0', 'id' => 8, 'method' => 'sampling/createMessage',
                                           'params' => { 'messages' => valid_loop, 'tools' => tools,
                                                         'maxTokens' => 10 } })

      expect(written.size).to eq(1)
      expect(written.first['id']).to eq(8)
      expect(written.first['result']).to include('role' => 'assistant', 'model' => 'm',
                                                 'content' => { 'type' => 'text', 'text' => 'ok' })
      expect(written.first).not_to have_key('error')
    end
  end

  describe 'the per-request timeout on the HTTP transports' do
    it 'reaches every continuation attempt of a Streamable HTTP round trip' do
      server = streamable
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
      bodies = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        bodies << body
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        # A modern tools/call reads the definitions first (Mcp-Param-* headers).
        when 'tools/list'
          json_response(body['id'], 'tools' => [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }],
                                    'ttlMs' => 60_000)
        when 'tools/call'
          if body['params'].key?('inputResponses')
            json_response(body['id'], done)
          else
            json_response(body['id'], input_required({ 'a' => elicit_request }))
          end
        end
      end
      allow(server).to receive(:attempt_request).and_call_original

      expect(server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 0.25)).to eq(done)

      expect(server).to have_received(:attempt_request).with('tools/call', anything, 0.25, anything).twice
      expect(bodies.count { |b| b['method'] == 'tools/call' }).to eq(2)
    end

    it 'times out a stalled continuation without a further retry' do
      server = streamable
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
      bodies = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        bodies << body
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        # A modern tools/call reads the definitions first (Mcp-Param-* headers).
        when 'tools/list'
          json_response(body['id'], 'tools' => [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }],
                                    'ttlMs' => 60_000)
        when 'tools/call'
          # The continuation's read stalls past the request timeout.
          raise Faraday::TimeoutError, 'execution expired' if body['params'].key?('inputResponses')

          json_response(body['id'], input_required({ 'a' => elicit_request }))
        end
      end

      expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 0.2) }
        .to raise_error(MCPClient::Errors::RequestTimeoutError)
      expect(bodies.count { |b| b['method'] == 'tools/call' }).to eq(2)
    end
  end

  describe 'a handler that starts another round trip on the same transport' do
    it 'completes the nested request first, each with its own state and answers' do
      stdio = modern_stdio
      inner_results = []
      stdio.on_elicitation_request do |key, params|
        inner_results << stdio.call_tool('inner', {}) if params['message'] == 'outer?'
        { 'action' => 'accept', 'content' => { 'name' => "#{key}-answer" } }
      end
      sent = script_stdio(stdio, [{ 'result' => discover_result },
                                  { 'result' => input_required({ 'o' => elicit_request('outer?') }, state: 'outer') },
                                  { 'result' => input_required({ 'i' => elicit_request('inner?') }, state: 'inner') },
                                  { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'inner done' }] } },
                                  { 'result' => done }])

      result = Timeout.timeout(5) { stdio.call_tool('outer', {}) }

      expect(result).to eq(done)
      expect(inner_results).to eq([{ 'content' => [{ 'type' => 'text', 'text' => 'inner done' }] }])
      wire = calls(sent).map do |r|
        [r['params']['name'], r['params']['requestState'], r['params']['inputResponses']&.keys]
      end
      expect(wire).to eq([['outer', nil, nil], ['inner', nil, nil],
                          ['inner', 'inner', ['i']], ['outer', 'outer', ['o']]])
      expect(calls(sent).last['params']['inputResponses']['o']['content']).to eq({ 'name' => 'o-answer' })
      expect(calls(sent)[2]['params']['inputResponses']['i']['content']).to eq({ 'name' => 'i-answer' })
    end
  end
end
