# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirty-fifth review round: every path that
# replaces an HTTP session moves the session epoch — the transparent 404
# restart that succeeds without ever going through #cleanup, the host's own
# #terminate_session, and a handshake that lands a different session id on a
# live one — so nothing keyed by the session that ended can colour a task id
# the next session reuses. A peer-supplied pollIntervalMs or ttlMs too large
# for the clock is a bound, never a raw exception out of a wait. And a
# tasks/update answer lands only in the bookkeeping it was sent for.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 35' do
  describe 'an HTTP session that is replaced without a cleanup' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/rpc' }
    let(:url) { "#{base_url}#{endpoint}" }
    # Sessions (and so the 404 recovery) belong to the initialize handshake:
    # a modern server has none.
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: :legacy,
                                          name: 'sess-test')
    end

    after { server.cleanup }

    def initialize_result
      { 'protocolVersion' => '2025-11-25',
        'capabilities' => { 'tools' => {}, 'tasks' => { 'get' => true, 'list' => true, 'cancel' => true } },
        'serverInfo' => { 'name' => 's', 'version' => '1' } }
    end

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    # A server that hands out a fresh session on every handshake; `expired`
    # names the session it answers with the 404 that ends it.
    def stub_streamable(sent:, results: {}, expired: nil)
      sessions = 0
      stub_request(:get, url).to_return(status: 200, body: '')
      stub_request(:delete, url).to_return(status: 200, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        method = body['method']
        sent << [method, request.headers['Mcp-Session-Id']]
        if method == 'initialize'
          sessions += 1
          json_response(body['id'], initialize_result)
            .tap { |r| r[:headers]['Mcp-Session-Id'] = "sess-#{sessions}" }
        elsif method.start_with?('notifications/')
          { status: 202, body: '' }
        elsif expired && request.headers['Mcp-Session-Id'] == expired
          { status: 404, body: 'session gone' }
        else
          json_response(body['id'], results.fetch(method, {}))
        end
      end
    end

    def client_for(srv)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: base_url }],
                                     extensions: [TASKS_EXT])
      allow(client).to receive(:sleep)
      client
    end

    it 'moves the epoch through a 404 restart that succeeds and resends' do
      sent = []
      stub_streamable(sent: sent, results: { 'tools/list' => { 'tools' => [] } }, expired: 'sess-1')
      server.connect
      epoch = server.session_epoch

      expect(server.rpc_request('tools/list', {})).to eq({ 'tools' => [] })

      # The restart succeeded (a second handshake, then the resend) and no
      # cleanup ran: the epoch moved anyway.
      expect(sent.count { |method, _| method == 'initialize' }).to eq(2)
      expect(server.session_epoch).to be > epoch
    end

    it 'moves the epoch when the host terminates the session itself' do
      stub_streamable(sent: [])
      server.connect
      epoch = server.session_epoch

      expect(server.terminate_session).to be true

      expect(server.session_epoch).to be > epoch
    end

    it 'moves the epoch when a session termination the server refuses still ends it' do
      stub_streamable(sent: [])
      stub_request(:delete, url).to_return(status: 405, body: '')
      server.connect
      epoch = server.session_epoch

      expect(server.terminate_session).to be false

      expect(server.session_epoch).to be > epoch
    end

    it 'refuses a task handle of a session the host terminated' do
      stub_streamable(sent: [], results: { 'tasks/get' => { 'taskId' => 'task-1', 'status' => 'working' } })
      client = client_for(server)
      server.connect
      handle = MCPClient::Task.new(task_id: 'task-1', status: 'working', server: server, modern: true)

      server.terminate_session

      expect { client.get_task(handle) }.to raise_error(MCPClient::Errors::TaskError, /session/i)
    end

    it 'moves the epoch when a handshake lands a different session id on a live one' do
      sent = []
      stub_streamable(sent: sent)
      server.connect
      epoch = server.session_epoch

      # A re-handshake outside the 404 path: the server hands out sess-2 and
      # sess-1 is over, cleanup or no cleanup.
      server.send(:perform_initialize)

      expect(server.instance_variable_get(:@session_id)).to eq('sess-2')
      expect(server.session_epoch).to be > epoch
    end

    it 'leaves the epoch alone when a handshake establishes the first session' do
      stub_streamable(sent: [])
      epoch = server.session_epoch

      server.connect

      expect(server.instance_variable_get(:@session_id)).to eq('sess-1')
      expect(server.session_epoch).to eq(epoch)
    end
  end

  describe 'a peer-supplied number the clock cannot represent' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    # An integer no Float can hold: it converts to Float::INFINITY.
    def unrepresentable
      10**400
    end

    def discover_result
      { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
        'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
    end

    def call_result(text = 'done')
      { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
    end

    def detailed_task(status:, ttl_ms: nil, poll_ms: 1, **extra)
      now = Time.now.utc.iso8601(3)
      { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
        'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
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
        response.merge('jsonrpc' => '2.0', 'id' => id)
      end
      sent
    end

    def client_for(server)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
    end

    it 'bounds a pollIntervalMs too large for the clock instead of sleeping on infinity' do
      client = client_for(stdio)
      slept = []
      allow(client).to receive(:sleep) { |seconds| slept << seconds }
      script_stdio(stdio, [{ 'result' => discover_result },
                           { 'result' => detailed_task(status: 'working', poll_ms: unrepresentable) },
                           { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

      # No caller timeout and no TTL: nothing else would clamp the interval.
      expect(client.wait_for_task('task-1')).to be_completed
      expect(slept).to eq([MCPClient::Client::TaskSupport::MAX_TASK_POLL_INTERVAL])
      expect(slept.first).to be_finite
    end

    it 'treats a ttlMs too large for the clock as no backstop in both TTL predicates' do
      task = MCPClient::Task.from_json(detailed_task(status: 'working', ttl_ms: unrepresentable), detailed: true)

      expect { task.ttl_elapsed? }.not_to raise_error
      expect(task.ttl_elapsed?).to be false
      expect(task.ttl_remaining).to be_nil
      # A TTL that yields no deadline is still a reported one: it says the
      # task has no usable backstop, not that none was reported.
      expect(task.ttl_reported?).to be true
    end

    it 'polls a task whose ttlMs the clock cannot represent instead of failing the wait' do
      client = client_for(stdio)
      allow(client).to receive(:sleep)
      script_stdio(stdio, [{ 'result' => discover_result },
                           { 'result' => detailed_task(status: 'working', ttl_ms: unrepresentable) },
                           { 'result' => detailed_task(status: 'completed', ttl_ms: unrepresentable,
                                                       'result' => call_result) }])

      expect(client.wait_for_task('task-1')).to be_completed
    end
  end

  describe 'a tasks/update answer that outlived the session it was sent in' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def stdio_client
      allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
      allow(client).to receive(:sleep)
      allow(stdio).to receive(:capabilities).and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:modern?).and_return(true)
      allow(stdio).to receive(:ensure_initialized)
      client
    end

    # The session ends while the update is on the wire, and the session that
    # replaces it reserves the very same task id and key for a request of
    # its own.
    def restart_under_update(client, error)
      allow(stdio).to receive(:rpc_request) do
        stdio.send(:bump_session_epoch)
        client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
        raise error
      end
    end

    it 'gives keys back only in the state the rejected update was built from' do
      client = stdio_client
      state = client.send(:task_state, stdio, 'task-1')
      restart_under_update(client, MCPClient::Errors::ServerError.new('inputResponses rejected', code: -32_602))

      expect do
        client.send(:send_task_update, stdio, 'task-1', { 'k1' => { 'action' => 'accept' } }, epoch: 0, state: state)
      end.to raise_error(MCPClient::Errors::MCPError)

      # The rejection released the ended session's keys, not the ones the
      # replacement session has reserved for a different request.
      expect(state[:answered]).to be_empty
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end

    it 'drops only the bookkeeping the not-found update was sent for' do
      client = stdio_client
      state = client.send(:task_state, stdio, 'task-1')
      restart_under_update(client, MCPClient::Errors::ServerError.new('no such task', code: -32_602))

      expect do
        client.send(:send_task_update, stdio, 'task-1', { 'k1' => { 'action' => 'accept' } }, epoch: 0, state: state)
      end.to raise_error(MCPClient::Errors::TaskNotFound)

      # The task the old session named is gone; the reused id of the live
      # session keeps everything it has recorded since.
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end
  end
end
