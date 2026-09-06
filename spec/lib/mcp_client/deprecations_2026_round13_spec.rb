# frozen_string_literal: true

require 'spec_helper'

# Round 13 of the 2026-07-28 deprecation review: a notice must not cost the
# peer its answer. Every earlier example on these paths pinned the notice and
# stopped there, so a transport that logged the notice and dropped the
# response passed them all. Here the stdio transport is held to the response
# envelope it owes a legacy sampling request, the sampling handler to the
# includeContext value it was reported for, a multi round-trip failure with
# notices enabled to the failure it is with them disabled, and a modern URL
# elicitation to a complete discovery -> input_required -> continuation
# exchange rather than a direct call into fulfilment.
RSpec.describe 'MCP 2026-07-28 deprecations (round 13)' do
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

  let(:answer) do
    { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Paris' }, 'model' => 'm' }
  end

  def sampling_params(include_context = 'thisServer')
    params = { 'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Capital?' } }],
               'maxTokens' => 100 }
    params['includeContext'] = include_context unless include_context == :absent
    params
  end

  # A stdio server driven by scripted responses (no subprocess), as the MRTR
  # spec drives one. Returns every request the transport sent.
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

  def input_required(requests)
    { 'resultType' => 'input_required', 'requestState' => 'opaque-state', 'inputRequests' => requests }
  end

  def done
    { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'done' }] } }
  end

  describe 'a legacy sampling request served by a stdio transport driven directly' do
    let(:server) { MCPClient::ServerStdio.new(command: 'true', logger: logger) }
    let(:sent) { [] }
    let(:seen) { [] }

    before { allow(server).to receive(:send_message) { |message| sent << message } }

    def serve(id, params = sampling_params)
      server.send(:handle_server_request,
                  { 'id' => id, 'method' => 'sampling/createMessage', 'params' => params })
    end

    it 'answers the peer with the handler result under the request id, the params intact' do
      server.on_sampling_request do |_id, params|
        seen << params
        answer
      end

      serve(2)

      expect(sent).to eq([{ 'jsonrpc' => '2.0', 'id' => 2, 'result' => answer }])
      expect(seen).to eq([sampling_params])
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
      expect(MCPClient::Deprecations.emitted?(:include_context)).to be(true)
    end

    it 'answers the next request once the notice is spent' do
      server.on_sampling_request { |id, _params| answer.merge('model' => "m-#{id}") }

      serve(2)
      serve(3)

      expect(sent.map { |message| [message['id'], message['result']['model']] }).to eq([[2, 'm-2'], [3, 'm-3']])
      expect(output.string.scan(/Sampling .*deprecated/).size).to eq(1)
    end

    it 'answers with the error envelope the handler chose' do
      server.on_sampling_request do |_id, _params|
        { 'error' => { 'code' => -32_001, 'message' => 'Sampling rejected' } }
      end

      serve(4)

      expect(sent).to eq([{ 'jsonrpc' => '2.0', 'id' => 4,
                            'error' => { 'code' => -32_001, 'message' => 'Sampling rejected' } }])
    end

    it 'answers Internal error, keeping the exception text local, when the handler raises' do
      server.on_sampling_request { |_id, _params| raise 'provider down at /secret/path' }

      serve(5)

      expect(sent).to eq([{ 'jsonrpc' => '2.0', 'id' => 5,
                            'error' => { 'code' => -32_603, 'message' => 'Internal error' } }])
      expect(output.string).to include('/secret/path')
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
    end
  end

  describe 'a sampling input request on the multi round-trip path with notices enabled' do
    let(:server) { MCPClient::ServerStdio.new(command: 'true', read_timeout: 1, logger: logger) }
    let(:seen) { [] }

    def sampling_request(include_context = 'thisServer')
      { 'method' => 'sampling/createMessage', 'params' => sampling_params(include_context) }
    end

    def exchange(requests)
      sent = script_stdio(server, [{ 'result' => discover_result }, { 'result' => input_required(requests) }, done])
      [server.call_tool('answer', {}), sent.select { |request| request['method'] == 'tools/call' }]
    end

    %w[thisServer allServers none].each do |value|
      it "hands includeContext #{value} to the sampling handler unchanged" do
        server.on_sampling_request do |_key, params|
          seen << params
          answer
        end

        result, calls = exchange('c' => sampling_request(value))

        expect(seen).to eq([sampling_params(value)])
        expect(seen.first['includeContext']).to eq(value)
        expect(result['content'].first['text']).to eq('done')
        expect(calls.last['params']['inputResponses']).to eq({ 'c' => answer })
      end
    end

    it 'hands a request without includeContext to the sampling handler without one' do
      server.on_sampling_request do |_key, params|
        seen << params
        answer
      end

      exchange('c' => sampling_request(:absent))

      expect(seen).to eq([sampling_params(:absent)])
      expect(seen.first).not_to have_key('includeContext')
    end

    def failing_exchange(requests)
      script_stdio(server, [{ 'result' => discover_result }, { 'result' => input_required(requests) }])
    end

    def tools_calls(sent)
      sent.count { |request| request['method'] == 'tools/call' }
    end

    it 'fails the round trip without a continuation when the handler raises, the notice already out' do
      server.on_sampling_request { |_key, _params| raise 'provider down' }
      sent = failing_exchange('c' => sampling_request)

      expect { server.call_tool('answer', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /failed/)
      expect(tools_calls(sent)).to eq(1)
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
      expect(MCPClient::Deprecations.emitted?(:include_context)).to be(true)
    end

    it 'fails the round trip when the handler answers with an error' do
      server.on_sampling_request { |_key, _params| { 'error' => { 'code' => -1, 'message' => 'Sampling rejected' } } }
      sent = failing_exchange('c' => sampling_request)

      expect { server.call_tool('answer', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /Sampling rejected/)
      expect(tools_calls(sent)).to eq(1)
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
    end

    it 'fails the round trip when the handler returns something other than a result object' do
      server.on_sampling_request { |_key, _params| 'Paris' }
      sent = failing_exchange('c' => sampling_request)

      expect { server.call_tool('answer', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /expected a result object/)
      expect(tools_calls(sent)).to eq(1)
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
    end

    # No handler means no use of Sampling: the refusal is the same as with
    # notices disabled, and nothing is said about a feature never adopted.
    it 'stays silent when no sampling handler is registered' do
      sent = failing_exchange('c' => sampling_request)

      expect { server.call_tool('answer', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /no handler is registered/)
      expect(tools_calls(sent)).to eq(1)
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(false)
      expect(MCPClient::Deprecations.emitted?(:include_context)).to be(false)
    end

    # The deprecated values were on the wire, and a host with a sampling
    # handler asked for them: the 2025-11-25 path warns before its handler
    # rejects the undeclared tools, and the round trip is the same use.
    it 'still warns for a tool-enabled request it refuses for the undeclared sampling.tools capability' do
      server.on_sampling_request do |_key, params|
        seen << params
        answer
      end
      request = sampling_request.merge('params' => sampling_params.merge('tools' => []))
      sent = failing_exchange('c' => request)

      expect { server.call_tool('answer', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /sampling\.tools/)
      expect(tools_calls(sent)).to eq(1)
      expect(seen).to be_empty
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
      expect(MCPClient::Deprecations.emitted?(:include_context)).to be(true)
      expect(output.string).to include('Received: includeContext thisServer')
    end
  end

  # The removed-fields and round 12 examples reach the elicitation callback
  # by calling fulfilment directly or dispatching a server-initiated request
  # by hand. This is the exchange itself, on both eras of the same transport.
  describe 'a URL elicitation fulfilled through the exchange a real transport runs' do
    let(:server) { MCPClient::ServerStdio.new(command: 'true', read_timeout: 1, logger: logger) }
    let(:seen) { [] }
    let(:url_params) do
      { 'mode' => 'url', 'message' => 'Visit to authorize', 'url' => 'https://example.com/auth',
        'elicitationId' => 'elic-1' }
    end

    # A client on this one transport, registered before the server has
    # negotiated anything, as a client always is.
    before do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'true' }], logger: logger,
        elicitation_handler: lambda { |_message, metadata|
          seen << metadata
          { 'action' => 'accept' }
        }
      )
    end

    it 'discovers, receives the input request and continues with the answer on 2026-07-28' do
      sent = script_stdio(server, [
                            { 'result' => discover_result },
                            { 'result' => input_required('k1' => { 'method' => 'elicitation/create',
                                                                   'params' => url_params }) },
                            done
                          ])

      result = server.call_tool('authorize', { 'scope' => 'read' })

      expect(result['content'].first['text']).to eq('done')
      expect(sent.map { |request| request['method'] }).to eq(%w[server/discover tools/call tools/call])
      calls = sent.select { |request| request['method'] == 'tools/call' }
      expect(calls.first['params']).to include('name' => 'authorize', 'arguments' => { 'scope' => 'read' })
      expect(calls.first['params']).not_to have_key('requestState')
      expect(calls.last['params']).to include('name' => 'authorize', 'arguments' => { 'scope' => 'read' },
                                              'requestState' => 'opaque-state',
                                              'inputResponses' => { 'k1' => { 'action' => 'accept' } })
      expect(seen).to eq([{ 'mode' => 'url', 'url' => 'https://example.com/auth' }])
    end

    it 'serves the server-initiated request with the response envelope on 2025-11-25' do
      sent = []
      allow(server).to receive(:send_message) { |message| sent << message }
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      expect(server).not_to be_modern

      server.send(:handle_server_request, { 'id' => 7, 'method' => 'elicitation/create', 'params' => url_params })

      expect(sent).to eq([{ 'jsonrpc' => '2.0', 'id' => 7, 'result' => { 'action' => 'accept' } }])
      expect(seen).to eq([{ 'mode' => 'url', 'url' => 'https://example.com/auth', 'elicitationId' => 'elic-1' }])
    end

    # The other half of changelog minor change 11: 2026-07-28 removed
    # `notifications/elicitation/complete` along with the id it correlated
    # by. This library never treated it as completion — the outcome is
    # learned by retrying — so on either era it is an unknown notification:
    # nothing raises, the elicitation handler is not invoked, and the id it
    # carries reaches no host callback as an elicitation.
    %w[2025-11-25 2026-07-28].each do |era|
      it "ignores notifications/elicitation/complete on #{era}" do
        server.instance_variable_set(:@protocol_version, era)

        expect do
          server.route_notification('notifications/elicitation/complete', { 'elicitationId' => 'elic-1' })
        end.not_to raise_error

        expect(seen).to be_empty
        expect(output.string).not_to match(/error/i)
      end
    end
  end
end
