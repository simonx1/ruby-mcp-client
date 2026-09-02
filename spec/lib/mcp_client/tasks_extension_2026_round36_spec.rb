# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirty-sixth review round:
#
# - A task id a fresh CreateTaskResult hands out again inside one session is a
#   new task. Its bookkeeping is a new lifetime: the in-flight holds of the
#   previous one no longer suppress its input requests, a wait still following
#   the previous one ends instead of reporting the new task's outcome, and the
#   answers the previous one produced are never delivered to it.
# - Ending a connection is not ending a session. An MCP 2026-07-28 HTTP
#   transport is sessionless (no initialize handshake, no Mcp-Session-Id), so
#   a task lives in the server's own id namespace for its ttlMs and survives a
#   cleanup/reconnect together with its answered keys and its pending update.
#   A legacy session — one a handshake opened — still ends with the connection.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 36' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def detailed_task(status:, poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def create_result
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'ok?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def task_from(hash, server: stdio)
    MCPClient::Task.from_json(hash, server: server, detailed: true)
  end

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server)
    allow(server).to receive(:capabilities).and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:modern?).and_return(true)
  end

  def wait_for(client, task_id: 'task-1', srv: stdio)
    wait = { task_id: task_id, srv: srv, deadline: nil, ttl_deadline: nil,
             answered: nil, state: nil, epoch: nil, last: nil }
    client.send(:refresh_wait_session, wait)
    wait
  end

  # The server hands out the very same task id again, in the session the wait
  # is in: a new CreateTaskResult, so a new task.
  def reuse_task_id(client, srv: stdio, epoch: nil)
    client.send(:created_task, create_result, srv, epoch || client.send(:current_session_epoch, srv))
  end

  describe 'a task id a fresh CreateTaskResult takes over inside one session' do
    it 'presents the new task its input requests, though the previous lifetime still holds the keys' do
      client = client_for(stdio)
      negotiated(stdio)
      requests = { 'k1' => elicit_request }
      task = task_from(detailed_task(status: 'input_required', 'inputRequests' => requests))
      previous = client.send(:task_state, stdio, 'task-1')
      # A handler of the previous task is still presenting k1 to the host.
      client.send(:reserve_input_requests, task, requests, previous[:answered], stdio, previous)

      reuse_task_id(client)

      current = client.send(:task_state, stdio, 'task-1')
      pending, = client.send(:reserve_input_requests, task, requests, current[:answered], stdio, current)
      expect(pending.keys).to eq(['k1'])
    end

    it 'keeps the previous lifetime hold under its own registry entry' do
      client = client_for(stdio)
      negotiated(stdio)
      requests = { 'k1' => elicit_request }
      task = task_from(detailed_task(status: 'input_required', 'inputRequests' => requests))
      previous = client.send(:task_state, stdio, 'task-1')
      client.send(:reserve_input_requests, task, requests, previous[:answered], stdio, previous)

      reuse_task_id(client)
      current = client.send(:task_state, stdio, 'task-1')

      expect(current[:key]).not_to eq(previous[:key])
      expect(client.send(:in_flight_task_keys, stdio, 'task-1', key: previous[:key])).to include('k1')
      expect(client.send(:in_flight_task_keys, stdio, 'task-1', key: current[:key])).to be_empty
    end

    it 'ends a wait whose task id the new task took over instead of reporting its outcome' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        reuse_task_id(client) if polls == 1
        task_from(detailed_task(status: 'working'))
      end

      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /replaced/i)
      expect(polls).to eq(1)
    end

    it 'does not hand the new task a terminal payload polled for the previous one' do
      client = client_for(stdio)
      negotiated(stdio)
      allow(client).to receive(:poll_task) do |w|
        w[:polled] = true
        reuse_task_id(client)
        task_from(detailed_task(status: 'completed', 'result' => { 'content' => [], 'isError' => false }))
      end

      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /replaced/i)
    end

    it 'discards answers the previous lifetime produced rather than updating the new task' do
      client = client_for(stdio)
      negotiated(stdio)
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }
      wait = wait_for(client)
      task = task_from(detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }))
      allow(stdio).to receive(:fulfil_input_requests) do |pending, _task|
        # The server handed the id out again while the host was answering.
        reuse_task_id(client)
        pending.transform_values { { 'action' => 'accept', 'content' => { 'n' => 'x' } } }
      end

      expect(client.send(:answer_task_input_requests, task, wait[:answered], stdio, wait)).to eq([])
      expect(sent).to be_empty
    end

    it 'refuses a tasks/update built in a lifetime the id no longer has' do
      client = client_for(stdio)
      negotiated(stdio)
      sent = []
      allow(stdio).to receive(:ensure_session_ready)
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }
      state = client.send(:task_state, stdio, 'task-1')
      client.send(:queue_task_update, state, { 'k1' => { 'action' => 'accept' } })

      reuse_task_id(client)

      client.send(:send_task_update, stdio, 'task-1', nil, pending_only: true, state: state,
                                                           epoch: client.send(:current_session_epoch, stdio))
      expect(sent).to be_empty
    end

    it 'refuses to wait on a handle of the task the new one replaced' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = client.send(:created_task, create_result, stdio, client.send(:current_session_epoch, stdio))
      # A wait puts the id on the books, so the next creation is a reuse.
      wait_for(client)

      replacement = reuse_task_id(client)

      expect { client.wait_for_task(handle, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
      expect(replacement.task_generation).to eq(handle.task_generation + 1)
    end

    it 'refuses an explicit tasks/update for a handle of the task the new one replaced' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = client.send(:created_task, create_result, stdio, client.send(:current_session_epoch, stdio))
      wait_for(client)

      reuse_task_id(client)

      expect { client.update_task(handle, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'takes a handle of the lifetime the id has now' do
      client = client_for(stdio)
      negotiated(stdio)
      wait_for(client)
      handle = reuse_task_id(client)
      allow(client).to receive(:poll_task) do |w|
        w[:polled] = true
        task_from(detailed_task(status: 'completed', 'result' => { 'content' => [], 'isError' => false }))
      end

      expect(client.wait_for_task(handle, timeout: 2).status).to eq('completed')
    end

    it 'leaves a first creation of an unseen task id at its first lifetime' do
      client = client_for(stdio)
      negotiated(stdio)

      reuse_task_id(client)

      expect(client.send(:task_state, stdio, 'task-1')[:generation]).to eq(0)
    end
  end

  describe 'a cleanup that ends only the connection' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }

    def discover_result
      { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
        'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } },
        '_meta' => { 'io.modelcontextprotocol/serverInfo' => { 'name' => 'modern', 'version' => '1' } } }
    end

    def initialize_result
      { 'protocolVersion' => '2025-11-25',
        'capabilities' => { 'tools' => {}, 'tasks' => { 'get' => true, 'cancel' => true } },
        'serverInfo' => { 'name' => 'legacy', 'version' => '1' } }
    end

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    def stub_modern
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        json_response(body['id'], body['method'] == 'server/discover' ? discover_result : {})
      end
    end

    def stub_legacy
      stub_request(:get, url).to_return(status: 200, body: '')
      stub_request(:delete, url).to_return(status: 200, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next({ status: 202, body: '' }) if body['method'].to_s.start_with?('notifications/')

        response = json_response(body['id'], body['method'] == 'initialize' ? initialize_result : {})
        response[:headers]['Mcp-Session-Id'] = 'sess-1' if body['method'] == 'initialize'
        response
      end
    end

    def streamable(protocol)
      MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: protocol,
                                          name: 'cleanup-test')
    end

    def plain_http(protocol)
      MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: protocol,
                                name: 'cleanup-test')
    end

    it 'leaves the session epoch alone for a sessionless 2026-07-28 streamable transport' do
      stub_modern
      server = streamable(:modern)
      server.connect
      epoch = server.session_epoch

      server.cleanup

      expect(server).to be_modern
      expect(server.session_epoch).to eq(epoch)
    end

    it 'leaves the session epoch alone for a sessionless 2026-07-28 HTTP transport' do
      stub_modern
      server = plain_http(:modern)
      server.connect
      epoch = server.session_epoch

      server.cleanup

      expect(server.session_epoch).to eq(epoch)
    end

    it 'still ends the session a legacy handshake opened' do
      stub_legacy
      server = streamable(:legacy)
      server.connect
      epoch = server.session_epoch

      server.cleanup

      expect(server.session_epoch).to be > epoch
    end

    it 'keeps the answered keys of a task that outlives a sessionless reconnect' do
      stub_modern
      server = streamable(:modern)
      client = client_for(server)
      server.connect
      client.send(:remember_answered_keys, server, 'task-1', ['k1'])

      server.cleanup

      expect(client.send(:answered_task_keys, server, 'task-1')).to include('k1')
    end

    it 'keeps a task handle of a sessionless server usable after a reconnect' do
      stub_modern
      server = streamable(:modern)
      client = client_for(server)
      server.connect
      handle = MCPClient::Task.new(task_id: 'task-1', status: 'working', server: server, modern: true)

      server.cleanup

      expect(client.send(:handle_session_epoch, handle, server, 'updating')).to eq(handle.session_epoch)
    end
  end
end
