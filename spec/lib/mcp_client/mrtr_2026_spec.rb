# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 Multi Round-Trip Requests (basic/patterns/mrtr, SEP-2322):
# servers no longer send roots/list, sampling/createMessage or
# elicitation/create as their own JSON-RPC requests. Instead tools/call,
# resources/read and prompts/get may answer with an InputRequiredResult
# (resultType "input_required") whose inputRequests the client fulfils
# before retrying the original request — with a new id, the same params,
# `inputResponses` keyed like the requests, and `requestState` echoed
# verbatim (or omitted when the server sent none).
MRTR_META_CAPS = 'io.modelcontextprotocol/clientCapabilities'

RSpec.describe 'MCP 2026-07-28 multi round-trip requests' do
  def discover_result(capabilities: { 'tools' => {}, 'resources' => {}, 'prompts' => {} })
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => capabilities }
  end

  def input_required(requests, state: 'opaque-state')
    result = { 'resultType' => 'input_required' }
    result['inputRequests'] = requests if requests
    result['requestState'] = state if state
    result
  end

  def elicit_request(message = 'Please provide your GitHub username')
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => message,
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'name' => { 'type' => 'string' } },
                                           'required' => ['name'] } } }
  end

  def sampling_request
    { 'method' => 'sampling/createMessage',
      'params' => { 'messages' => [{ 'role' => 'user',
                                     'content' => { 'type' => 'text', 'text' => 'Capital of France?' } }],
                    'maxTokens' => 100 } }
  end

  # A stdio server driven by scripted responses (no subprocess).
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

  describe 'on stdio' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'fulfils an elicitation input request and retries with inputResponses and requestState' do
      handled = []
      server.on_elicitation_request do |key, params|
        handled << [key, params]
        { 'action' => 'accept', 'content' => { 'name' => 'octocat' } }
      end
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required({ 'github_login' => elicit_request }) },
                                   { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'hi octocat' }] } }])

      result = server.call_tool('greet', { 'loud' => true })

      expect(result['content'].first['text']).to eq('hi octocat')
      expect(handled).to eq([['github_login', elicit_request['params']]])
      calls = sent.select { |r| r['method'] == 'tools/call' }
      expect(calls.size).to eq(2)
      expect(calls[0]['id']).not_to eq(calls[1]['id'])
      expect(calls[0]['params']).not_to have_key('inputResponses')
      expect(calls[1]['params']['name']).to eq('greet')
      expect(calls[1]['params']['arguments']).to eq({ 'loud' => true })
      expect(calls[1]['params']['inputResponses'])
        .to eq({ 'github_login' => { 'action' => 'accept', 'content' => { 'name' => 'octocat' } } })
      expect(calls[1]['params']['requestState']).to eq('opaque-state')
    end

    it 'fulfils sampling and roots input requests alongside elicitation in one round trip' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'decline' } }
      server.on_sampling_request do |_k, _p|
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Paris' }, 'model' => 'm',
          'stopReason' => 'endTurn' }
      end
      server.on_roots_list_request { |_k, _p| { 'roots' => [{ 'uri' => 'file:///p', 'name' => 'p' }] } }
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required({ 'q' => elicit_request, 'c' => sampling_request,
                                                                  'r' => { 'method' => 'roots/list' } }) },
                                   { 'result' => { 'content' => [] } }])

      server.call_tool('t', {})

      responses = sent.last['params']['inputResponses']
      expect(responses['q']).to eq({ 'action' => 'decline' })
      expect(responses['c']['content']['text']).to eq('Paris')
      expect(responses['r']).to eq({ 'roots' => [{ 'uri' => 'file:///p', 'name' => 'p' }] })
    end

    it 'retries immediately when only requestState is present' do
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required(nil, state: 'wait-for-oob') },
                                   { 'result' => { 'content' => [] } }])

      server.call_tool('t', {})

      retry_params = sent.last['params']
      expect(retry_params['requestState']).to eq('wait-for-oob')
      expect(retry_params).not_to have_key('inputResponses')
    end

    it 'omits requestState on the retry when the server sent none, and echoes it verbatim otherwise' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'x' } } }
      weird = ' é {"not":"parsed"} =?base64?x?= '
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required({ 'a' => elicit_request }, state: nil) },
                                   { 'result' => input_required({ 'b' => elicit_request }, state: weird) },
                                   { 'result' => { 'content' => [] } }])

      server.call_tool('t', {})

      calls = sent.select { |r| r['method'] == 'tools/call' }
      expect(calls.size).to eq(3)
      expect(calls[1]['params']).not_to have_key('requestState')
      expect(calls[2]['params']['requestState']).to equal_string(weird)
      expect(calls[2]['params']['inputResponses'].keys).to eq(['b'])
    end

    it 'keeps the round trip scoped to its own request' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'x' } } }
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required({ 'a' => elicit_request }) },
                                   { 'result' => { 'content' => [] } },
                                   { 'result' => { 'tools' => [] } }])

      server.call_tool('t', {})
      server.list_tools

      expect(sent.last['method']).to eq('tools/list')
      expect(sent.last['params']).not_to have_key('inputResponses')
      expect(sent.last['params']).not_to have_key('requestState')
    end

    it 'supports resources/read and prompts/get' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'x' } } }
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required({ 'a' => elicit_request }) },
                                   { 'result' => { 'contents' => [{ 'uri' => 'file:///r', 'text' => 'ok' }] } },
                                   { 'result' => input_required({ 'b' => elicit_request }) },
                                   { 'result' => { 'messages' => [] } }])

      contents = server.read_resource('file:///r')
      prompt = server.get_prompt('p', {})

      expect(contents.first.text).to eq('ok')
      expect(prompt).to eq({ 'messages' => [] })
      expect(sent.map { |r| r['method'] })
        .to eq(%w[server/discover resources/read resources/read prompts/get prompts/get])
      expect(sent[2]['params']['uri']).to eq('file:///r')
      expect(sent[4]['params']['name']).to eq('p')
    end

    it 'rejects an input_required result on a method that does not support it' do
      script_stdio(server, [{ 'result' => discover_result },
                            { 'result' => input_required({ 'a' => elicit_request }) }])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
    end

    it 'bounds the number of round trips' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'x' } } }
      responses = [{ 'result' => discover_result }] +
                  Array.new(MCPClient::JsonRpcCommon::MAX_INPUT_ROUND_TRIPS + 2) do
                    { 'result' => input_required({ 'a' => elicit_request }) }
                  end
      sent = script_stdio(server, responses)

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /round trips/)
      expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(MCPClient::JsonRpcCommon::MAX_INPUT_ROUND_TRIPS + 1)
    end

    it 'raises InputRequiredError without retrying when an input request cannot be fulfilled' do
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => input_required({ 'a' => elicit_request }) }])

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError) do |e|
        expect(e.input_requests).to eq({ 'a' => elicit_request })
        expect(e.request_state).to eq('opaque-state')
        expect(e.message).to match(/elicitation/)
      end
      expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
    end

    it 'raises InputRequiredError for an unknown input request method' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept' } }
      script_stdio(server, [{ 'result' => discover_result },
                            { 'result' => input_required({ 'a' => { 'method' => 'ping', 'params' => {} } }) }])

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /ping/)
    end

    it 'raises InputRequiredError when a handler answers with an error' do
      server.on_sampling_request { |_k, _p| { 'error' => { 'code' => -1, 'message' => 'Sampling rejected' } } }
      script_stdio(server, [{ 'result' => discover_result },
                            { 'result' => input_required({ 'c' => sampling_request }) }])

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /Sampling rejected/)
    end

    it 'raises InputRequiredError for malformed inputRequests' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept' } }
      script_stdio(server, [{ 'result' => discover_result },
                            { 'result' => input_required({ 'a' => 'not-an-object' }) }])

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError)
    end

    it 'declares roots, elicitation and sampling in modern requests once handlers are registered' do
      server.on_elicitation_request { |_k, _p| nil }
      server.on_roots_list_request { |_k, _p| nil }
      server.on_sampling_request { |_k, _p| nil }
      server.declare_sampling_tools
      sent = script_stdio(server, [{ 'result' => discover_result }, { 'result' => { 'tools' => [] } }])

      server.list_tools

      caps = sent.last['params']['_meta'][MRTR_META_CAPS]
      expect(caps['roots']).to eq({})
      expect(caps['elicitation']).to eq({ 'form' => {}, 'url' => {} })
      expect(caps['sampling']).to eq({ 'tools' => {} })
    end

    it 'declares nothing a modern server could ask for when no handler is registered' do
      sent = script_stdio(server, [{ 'result' => discover_result }, { 'result' => { 'tools' => [] } }])

      server.list_tools

      expect(sent.last['params']['_meta'][MRTR_META_CAPS]).to eq({})
    end
  end

  describe 'on Streamable HTTP' do
    let(:url) { 'https://example.com/mcp' }
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

    after { server.cleanup }

    it 'retries the POST with a new id, inputResponses, requestState and the Mcp-Name header' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'octocat' } } }
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << { headers: request.headers, body: body }
        result = case body['method']
                 when 'server/discover' then discover_result
                 when 'tools/list' then { 'tools' => [] }
                 when 'tools/call'
                   if body['params'].key?('inputResponses')
                     { 'content' => [{ 'type' => 'text', 'text' => 'done' }] }
                   else
                     input_required({ 'login' => elicit_request })
                   end
                 end
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end

      result = server.call_tool('greet', {})

      expect(result['content'].first['text']).to eq('done')
      calls = requests.select { |r| r[:body]['method'] == 'tools/call' }
      expect(calls.size).to eq(2)
      expect(calls[1][:body]['id']).not_to eq(calls[0][:body]['id'])
      expect(calls[1][:body]['params']['inputResponses']['login']['content']).to eq({ 'name' => 'octocat' })
      expect(calls[1][:body]['params']['requestState']).to eq('opaque-state')
      expect(calls[1][:headers]['Mcp-Name']).to eq('greet')
    end
  end

  describe 'through MCPClient::Client' do
    def greet_tool
      { 'name' => 'greet', 'inputSchema' => { 'type' => 'object' } }
    end

    it 'routes elicitation input requests to the configured handler and roots to the client roots' do
      stdio = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
      seen = []
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }],
                                     roots: [{ 'uri' => 'file:///home', 'name' => 'home' }],
                                     elicitation_handler: lambda { |message, schema|
                                       seen << [message, schema['required']]
                                       { 'name' => 'octocat' }
                                     })
      sent = script_stdio(stdio, [
                            { 'result' => discover_result },
                            { 'result' => { 'tools' => [greet_tool] } },
                            { 'result' => input_required({ 'login' => elicit_request,
                                                           'r' => { 'method' => 'roots/list' } }) },
                            { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'hi' }] } }
                          ])

      result = client.call_tool('greet', {})

      expect(result['content'].first['text']).to eq('hi')
      expect(seen).to eq([['Please provide your GitHub username', ['name']]])
      responses = sent.last['params']['inputResponses']
      expect(responses['login']).to eq({ 'action' => 'accept', 'content' => { 'name' => 'octocat' } })
      expect(responses['r']).to eq({ 'roots' => [{ 'uri' => 'file:///home', 'name' => 'home' }] })
    end

    it 'surfaces an unfulfillable round trip as InputRequiredError from call_tool' do
      stdio = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }])
      script_stdio(stdio, [{ 'result' => discover_result },
                           { 'result' => { 'tools' => [greet_tool] } },
                           { 'result' => input_required({ 'login' => elicit_request }) }])

      expect { client.call_tool('greet', {}) }.to raise_error(MCPClient::Errors::InputRequiredError)
    end
  end
end

RSpec::Matchers.define :equal_string do |expected|
  match { |actual| actual.is_a?(String) && actual == expected && actual.encoding == expected.encoding }
end

# Review (codex): round-trip params survive transport-level recovery of an
# attempt; handler exceptions become InputRequiredError; an explicit null
# inputRequests is malformed; input_required from a legacy session is
# rejected; the plain HTTP transport exposes the handlers.
RSpec.describe 'MCP 2026-07-28 multi round-trip requests — review follow-ups' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'name?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => {} } } }
  end

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
      raise response if response.is_a?(Exception)

      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, retries: 1, retry_backoff: 0) }

  it 'wraps a handler exception as InputRequiredError' do
    server.on_elicitation_request { |_k, _p| raise 'boom' }
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => { 'resultType' => 'input_required',
                                                 'inputRequests' => { 'a' => elicit_request } } }])

    expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, %r{elicitation/create})
    expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
  end

  it 'treats an explicit null inputRequests as malformed' do
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'resultType' => 'input_required', 'inputRequests' => nil,
                                          'requestState' => 's' } }])

    expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /inputRequests/)
  end

  it 'keeps the round-trip params when a retry attempt is recovered at the transport level' do
    server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => {} } }
    sent = script_stdio(server, [{ 'result' => discover_result },
                                 { 'result' => { 'resultType' => 'input_required', 'requestState' => 'st',
                                                 'inputRequests' => { 'a' => elicit_request } } },
                                 MCPClient::Errors::TransportError.new('flaky pipe'),
                                 { 'result' => { 'tools' => [] } }])

    server.rpc_request('resources/read', { 'uri' => 'file:///x' })

    reads = sent.select { |r| r['method'] == 'resources/read' }
    expect(reads.size).to eq(3)
    expect(reads[1]['params']['requestState']).to eq('st')
    expect(reads[2]['params']['requestState']).to eq('st')
    expect(reads[2]['params']['inputResponses']).to eq({ 'a' => { 'action' => 'accept', 'content' => {} } })
  end

  it 'rejects input_required from a legacy session' do
    legacy = MCPClient::ServerStdio.new(command: 'echo test', protocol: :legacy)
    sent = script_stdio(legacy, [{ 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {} } },
                                 { 'result' => { 'resultType' => 'input_required', 'requestState' => 's' } }])

    expect { legacy.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
    expect(sent.count { |r| r['method'] == 'tools/call' }).to eq(1)
  end

  it 'exposes the handlers on the plain HTTP transport and declares the capabilities' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    expect(http).to respond_to(:on_elicitation_request, :on_roots_list_request, :on_sampling_request)
    http.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'x' } } }
    http.on_roots_list_request { |_k, _p| { 'roots' => [] } }
    requests = []
    stub_request(:post, 'https://example.com/mcp').to_return do |request|
      body = JSON.parse(request.body)
      requests << body
      result = case body['method']
               when 'server/discover' then discover_result
               when 'tools/list' then { 'tools' => [] }
               when 'tools/call'
                 if body['params'].key?('inputResponses')
                   { 'content' => [] }
                 else
                   { 'resultType' => 'input_required', 'inputRequests' => { 'a' => elicit_request } }
                 end
               end
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    expect(http.call_tool('t', {})).to eq({ 'content' => [] })
    caps = requests.last['params']['_meta']['io.modelcontextprotocol/clientCapabilities']
    expect(caps).to include('elicitation' => { 'form' => {}, 'url' => {} }, 'roots' => {})
    expect(requests.last['params']['inputResponses']).to eq({ 'a' => { 'action' => 'accept',
                                                                       'content' => { 'name' => 'x' } } })
    http.cleanup
  end

  it 'lets MCPClient::Client wire its handlers to a plain HTTP server' do
    http = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(http)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'http', base_url: 'x' }],
                                   elicitation_handler: ->(_m, _s) { { 'name' => 'x' } })
    expect(http.instance_variable_get(:@elicitation_request_callback)).not_to be_nil
    expect(http.instance_variable_get(:@roots_list_request_callback)).not_to be_nil
    client.cleanup
  end
end

RSpec.describe 'MCP 2026-07-28 multi round-trip requests — pacing and URL mode' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift or raise 'no scripted response left'
      responder.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  it 'paces retries of requestState-only answers with a growing delay' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    delays = []
    allow(server).to receive(:sleep) { |d| delays << d }
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'resultType' => 'input_required', 'requestState' => 's1' } },
                          { 'result' => { 'resultType' => 'input_required', 'requestState' => 's2' } },
                          { 'result' => { 'resultType' => 'input_required', 'requestState' => 's3' } },
                          { 'result' => { 'content' => [] } }])

    server.call_tool('t', {})

    expect(delays).to eq([0.5, 1.0, 2.0])
  end

  it 'does not pace retries that carry fulfilled input responses' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => {} } }
    expect(server).not_to receive(:sleep)
    request = { 'method' => 'elicitation/create',
                'params' => { 'message' => 'x', 'requestedSchema' => { 'type' => 'object' } } }
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'resultType' => 'input_required', 'inputRequests' => { 'a' => request } } },
                          { 'result' => { 'content' => [] } }])

    server.call_tool('t', {})
  end

  it 'routes a URL-mode elicitation through the Client handler and answers with a bare accept' do
    stdio = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    seen = nil
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }],
                                   elicitation_handler: lambda { |message, details|
                                     seen = [message, details]
                                     { 'action' => 'accept' }
                                   })
    url_request = { 'method' => 'elicitation/create',
                    'params' => { 'mode' => 'url', 'url' => 'https://mcp.example.com/connect', 'message' => 'Authorize' } }
    sent = script_stdio(stdio, [{ 'result' => discover_result },
                                { 'result' => { 'tools' => [{ 'name' => 'connect',
                                                              'inputSchema' => { 'type' => 'object' } }] } },
                                { 'result' => { 'resultType' => 'input_required', 'requestState' => 'oob',
                                                'inputRequests' => { 'auth' => url_request } } },
                                { 'result' => { 'content' => [] } }])
    allow(stdio).to receive(:sleep)

    client.call_tool('connect', {})

    expect(seen.first).to eq('Authorize')
    expect(seen.last).to include('mode' => 'url', 'url' => 'https://mcp.example.com/connect')
    expect(sent.last['params']['inputResponses']).to eq({ 'auth' => { 'action' => 'accept' } })
    expect(sent.last['params']['requestState']).to eq('oob')
  end
end
