# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'socket'

# MCP 2026-07-28 multi round-trip requests, review round 7 (codex): an
# out-of-band wait is bounded by the timeout the request actually runs under
# — the caller's own, or the transport's configured read timeout when the
# caller named none — and the time the host's own control spends deciding
# counts against it. The sampling histories handed to the host are checked
# for the fields the message rules give meaning to, so a tool use and a tool
# result do not correlate by a pair of missing identifiers
# (client/sampling "Security Considerations").
# A server that answers the discovery, the tool list and the first
# tools/call, then accepts the continuation and never answers it.
class StallingContinuationServer
  attr_reader :received

  def initialize
    @received = []
    @socket = TCPServer.new('127.0.0.1', 0)
    @stop = false
    @thread = Thread.new { serve }
  end

  def base_url = "http://127.0.0.1:#{@socket.addr[1]}"

  def close
    @stop = true
    @socket.close unless @socket.closed?
    @thread&.kill
  end

  private

  def serve
    until @stop
      client = accept_one
      break if client.nil?

      Thread.new { handle(client) }
    end
  end

  def accept_one
    @socket.accept
  rescue StandardError
    nil
  end

  def handle(client)
    body = read_request(client)
    return if body.nil?

    message = JSON.parse(body)
    @received << message
    answer = answer_for(message)
    # The continuation is accepted and left hanging: its own timeout is
    # the only thing that can end it.
    return sleep(30) if answer.nil?

    write(client, JSON.generate('jsonrpc' => '2.0', 'id' => message['id'], 'result' => answer))
  rescue StandardError
    nil
  ensure
    client.close unless client.closed?
  end

  def answer_for(message)
    case message['method']
    when 'server/discover'
      { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
    when 'tools/list'
      { 'tools' => [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }], 'ttlMs' => 60_000 }
    when 'tools/call'
      return nil if message['params'].key?('inputResponses')

      { 'resultType' => 'input_required', 'requestState' => 'st',
        'inputRequests' => { 'a' => { 'method' => 'elicitation/create',
                                      'params' => { 'mode' => 'form', 'message' => 'Who?',
                                                    'requestedSchema' => { 'type' => 'object' } } } } }
    end
  end

  def read_request(client)
    headers = +''
    headers << client.readline until headers.end_with?("\r\n\r\n")
    length = headers[/Content-Length:\s*(\d+)/i, 1].to_i
    client.read(length)
  rescue StandardError
    nil
  end

  def write(client, payload)
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}")
  end
end

RSpec.describe 'MCP 2026-07-28 multi round-trip requests — round 7' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
  end

  def state_only(state)
    { 'resultType' => 'input_required', 'requestState' => state }
  end

  def input_required(requests, state: 'st')
    { 'resultType' => 'input_required', 'requestState' => state, 'inputRequests' => requests }
  end

  def sampling_request(history, tools)
    { 'method' => 'sampling/createMessage',
      'params' => { 'messages' => history, 'maxTokens' => 100, 'tools' => tools } }
  end

  def done
    { 'content' => [{ 'type' => 'text', 'text' => 'done' }] }
  end

  def modern_stdio(**)
    MCPClient::ServerStdio.new(command: 'echo test', **)
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

  def calls(sent)
    sent.select { |r| r['method'] == 'tools/call' }
  end

  # ---------------------------------------------------------------------------
  describe 'the wait is bounded by the timeout the request runs under' do
    # A caller that names no timeout still runs under one: the transport's
    # configured read timeout. Before, the bound existed only for an explicit
    # `timeout:`, so a state-only answer paced its way past a read timeout of
    # a hundredth of a second.
    it 'bounds a wait by the transport read timeout when the caller named none' do
      stdio = modern_stdio(read_timeout: 0.05)
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => state_only('s1') },
                                  { 'result' => done }])
      stdio.send(:ensure_initialized)

      expect { stdio.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /timeout/i) do |e|
          expect(e.request_state).to eq('s1')
          expect(e).to be_resumable
        end
      expect(calls(sent).size).to eq(1)
      expect(stdio).not_to have_received(:sleep)
    end

    # The host's control is host code: it may open a window, ask a person and
    # come back a minute later. That minute belongs to the request, so the
    # pause that follows is measured from when the control returned.
    it 'counts the time the host control itself spent against the timeout' do
      stdio = modern_stdio(read_timeout: 30)
      now = 0.0
      allow(stdio).to receive(:input_wait_clock) { now }
      stdio.on_input_required_wait do |_wait|
        now += 0.5
        :wait
      end
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => state_only('s1') },
                                  { 'result' => done }])
      stdio.send(:ensure_initialized)

      expect { stdio.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 0.6) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /timeout/i) do |e|
          expect(e.request_state).to eq('s1')
        end
      expect(calls(sent).size).to eq(1)
      expect(stdio).not_to have_received(:sleep)
    end

    # The bound is the caller's when it named one, even where the transport's
    # own read timeout is longer: a request cannot outlast what it was given.
    it 'still prefers the caller\'s own timeout over the transport default' do
      stdio = modern_stdio(read_timeout: 30)
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => state_only('s1') },
                                  { 'result' => done }])
      stdio.send(:ensure_initialized)

      expect { stdio.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 0.01) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /timeout/i)
      expect(calls(sent).size).to eq(1)
    end

    # A transport with no bound of its own (a host adapter that never sets
    # one) keeps the documented behaviour: the round-trip ceiling is what
    # stops it, not a timeout nobody set.
    it 'paces on when neither the caller nor the transport bounds the request' do
      stdio = modern_stdio(read_timeout: nil)
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => state_only('s1') },
                                  { 'result' => done }])
      stdio.send(:ensure_initialized)

      expect(stdio.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} })).to eq(done)
      expect(calls(sent).size).to eq(2)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'sampling histories are checked on the fields that carry meaning' do
    let(:tools) { [{ 'name' => 'search', 'inputSchema' => { 'type' => 'object' } }] }

    def use_block(id, name: 'search')
      { 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => {} }
    end

    def result_block(id)
      { 'type' => 'tool_result', 'toolUseId' => id, 'content' => [{ 'type' => 'text', 'text' => 'ok' }] }
    end

    def ask
      { 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'hi' } }
    end

    def run(history)
      stdio = modern_stdio(read_timeout: 1)
      invoked = 0
      handler = lambda do |*|
        invoked += 1
        { 'content' => 'ok' }
      end
      allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }],
                                     sampling_handler: handler, sampling_supports_tools: true)
      tool_list = { 'tools' => [{ 'name' => 'c', 'inputSchema' => { 'type' => 'object' } }] }
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => tool_list },
                                  { 'result' => input_required({ 's' => sampling_request(history, tools) }) },
                                  { 'result' => done }])
      [client, sent, -> { invoked }]
    end

    def expect_refused(history)
      client, sent, invoked = run(history)

      expect { client.call_tool('c', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /message/)
      expect(invoked.call).to eq(0)
      expect(calls(sent).size).to eq(1)
    end

    def expect_accepted(history)
      client, sent, invoked = run(history)

      expect(client.call_tool('c', {})).to eq(done)
      expect(invoked.call).to eq(1)
      expect(calls(sent).size).to eq(2)
    end

    it 'refuses a text block that carries no text' do
      expect_refused([{ 'role' => 'user', 'content' => [{ 'type' => 'text' }] }])
    end

    # The refusal names what to look at: the block and its type, never the
    # content itself (a malformed history is exactly where a server would
    # hide something it wants echoed into the host's logs).
    it 'names the block type in the refusal, and not the block' do
      client, = run([{ 'role' => 'user', 'content' => [{ 'type' => 'text', 'secret' => 'sssh' }] }])

      expect { client.call_tool('c', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /"text" content block without the fields/) do |e|
          expect(e.message).not_to include('sssh')
        end
    end

    it 'refuses a tool use with no id answered by a tool result with no toolUseId' do
      use = { 'type' => 'tool_use', 'name' => 'search', 'input' => {} }
      answer = { 'type' => 'tool_result', 'content' => [{ 'type' => 'text', 'text' => 'ok' }] }
      expect_refused([ask,
                      { 'role' => 'assistant', 'content' => [use] },
                      { 'role' => 'user', 'content' => [answer] }])
    end

    it 'refuses a history that ends on an unanswered tool use' do
      expect_refused([ask, { 'role' => 'assistant', 'content' => [use_block('call_1')] }])
    end

    it 'refuses a tool result whose toolUseId is not a string' do
      expect_refused([ask,
                      { 'role' => 'assistant', 'content' => [use_block('call_1')] },
                      { 'role' => 'user', 'content' => [result_block(1)] }])
    end

    # Nothing in the message rules orders the answers: two uses answered by
    # their two results, whichever way round, is a valid history.
    it 'accepts two tool uses answered in the other order' do
      expect_accepted([ask,
                       { 'role' => 'assistant', 'content' => [use_block('call_1'), use_block('call_2')] },
                       { 'role' => 'user', 'content' => [result_block('call_2'), result_block('call_1')] }])
    end

    # The content types are an open set: a block this client does not know is
    # the host's to read, not this client's to refuse — refusing it would
    # break a session with a server using a type added after this release.
    it 'accepts a content block of a type it does not know' do
      expect_accepted([{ 'role' => 'user', 'content' => [{ 'type' => 'flowchart', 'nodes' => [] }] }])
    end

    it 'accepts an image block that carries its data and mimeType' do
      expect_accepted([{ 'role' => 'user',
                         'content' => [{ 'type' => 'image', 'data' => 'AAAA', 'mimeType' => 'image/png' }] }])
    end

    it 'refuses an image block with no data' do
      expect_refused([{ 'role' => 'user', 'content' => [{ 'type' => 'image', 'mimeType' => 'image/png' }] }])
    end
  end

  # ---------------------------------------------------------------------------
  describe 'the host controls reach the server that raised' do
    # One server cannot tell "the transport that raised" from "the first
    # transport": the continuation is resumed on its own server, and the
    # other one is never asked.
    it 'resumes a continuation on its own server, not on the first' do
      first = modern_stdio(read_timeout: 1)
      second = modern_stdio(read_timeout: 1)
      second.on_input_required_wait { |_wait| :cancel }
      tools = { 'tools' => [{ 'name' => 'only-on-second', 'inputSchema' => { 'type' => 'object' } }] }
      first_sent = script_stdio(first, [{ 'result' => discover_result }, { 'result' => { 'tools' => [] } }])
      second_sent = script_stdio(second, [{ 'result' => discover_result }, { 'result' => tools },
                                          { 'result' => state_only('s1') }, { 'result' => done }])
      allow(MCPClient::ServerFactory).to receive(:create).and_return(first, second)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' },
                                                          { type: 'stdio', command: 'b' }])
      error = begin
        client.call_tool('only-on-second', {})
      rescue MCPClient::Errors::InputRequiredError => e
        e
      end
      second.on_input_required_wait { |_wait| :wait }

      expect(client.resume_input_required(error)).to eq(done)
      expect(calls(second_sent).size).to eq(2)
      expect(calls(second_sent).last['params']['requestState']).to eq('s1')
      expect(calls(first_sent)).to be_empty
    end

    # Registered on the Client, the control covers every server it holds.
    it 'registers a wait control through the Client for each of its servers' do
      first = modern_stdio(read_timeout: 1)
      second = modern_stdio(read_timeout: 1)
      script_stdio(first, [{ 'result' => discover_result }, { 'result' => { 'tools' => [] } }])
      tools = { 'tools' => [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }] }
      sent = script_stdio(second, [{ 'result' => discover_result }, { 'result' => tools },
                                   { 'result' => state_only('s1') }, { 'result' => done }])
      allow(MCPClient::ServerFactory).to receive(:create).and_return(first, second)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' },
                                                          { type: 'stdio', command: 'b' }])
      seen = []
      client.on_input_required_wait do |wait|
        seen << wait.rpc_method
        :cancel
      end

      expect { client.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /cancelled by the host/)
      expect(seen).to eq(['tools/call'])
      expect(calls(sent).size).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'an elicitation mode this client does not implement' do
    # form and url are the two modes the Client serves; any other is refused
    # before the host's handler sees it, and the round trip fails with the
    # continuation rather than sending an answer the server cannot use.
    it 'fails the round trip without asking the host' do
      stdio = modern_stdio(read_timeout: 1)
      invoked = false
      handler = lambda do |_message, _details|
        invoked = true
        { 'name' => 'ada' }
      end
      allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }],
                                     elicitation_handler: handler)
      tool_list = { 'tools' => [{ 'name' => 'c', 'inputSchema' => { 'type' => 'object' } }] }
      request = { 'method' => 'elicitation/create',
                  'params' => { 'mode' => 'dialog', 'message' => 'Who?' } }
      sent = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => tool_list },
                                  { 'result' => input_required({ 'a' => request }) }, { 'result' => done }])

      expect { client.call_tool('c', {}) }.to raise_error(MCPClient::Errors::InputRequiredError)
      expect(invoked).to be(false)
      expect(calls(sent).size).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # The continuation is a request like any other: the timeout the call was
  # made with bounds it on the wire, not just in the argument the recovery
  # wrapper is handed.
  describe 'an HTTP continuation runs under the call\'s own timeout' do
    around do |example|
      WebMock.disable!
      @fixture = StallingContinuationServer.new
      example.run
    ensure
      @fixture&.close
      WebMock.enable!
    end

    it 'ends a stalled continuation at the call timeout, not at the transport default' do
      server = MCPClient::ServerStreamableHTTP.new(base_url: @fixture.base_url, endpoint: '/mcp',
                                                   retries: 0, read_timeout: 30)
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => { 'name' => 'ada' } } }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }, timeout: 0.4) }
        .to raise_error(MCPClient::Errors::RequestTimeoutError)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
      expect(@fixture.received.count { |m| m['method'] == 'tools/call' }).to eq(2)
    end
  end
end
