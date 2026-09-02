# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirty-second round: every task request is
# pinned to the session it belongs to (tasks/get and the explicit
# tasks/update / tasks/cancel of a handle, not only the wait's updates), what
# a session answered stays that session's (round 33 settled that a terminal
# payload the wait's own session answered is the outcome, and that the
# replacement session is never polled for the reused id), and no bookkeeping
# of the session that replaced the one a request belongs to is forgotten on
# its behalf.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 32' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def detailed_task(status:, ttl_ms: nil, poll_ms: 1, created_at: nil, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => created_at || now,
      'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'Deploy to production?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def task_from(hash)
    MCPClient::Task.from_json(hash, server: stdio, detailed: true)
  end

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server)
    allow(server).to receive(:capabilities)
      .and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:modern?).and_return(true)
  end

  def accepting_client(server, &counter)
    client_for(server, elicitation_handler: lambda { |_message, _schema|
      counter&.call
      { action: 'accept', content: { 'n' => 'x' } }
    })
  end

  # A transport whose session ends inside rpc_request, the way a lazy
  # ensure_initialized / ensure_connected reconnect does.
  def reconnecting_transport(server, result: {})
    sent = []
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response).and_return({ 'jsonrpc' => '2.0', 'id' => 1, 'result' => result })
    allow(server).to receive(:ensure_initialized) { server.send(:bump_session_epoch) }
    sent
  end

  def wait_for(client, task_id: 'task-1')
    wait = { task_id: task_id, srv: stdio, deadline: nil, ttl_deadline: nil,
             answered: nil, state: nil, epoch: nil, last: nil }
    client.send(:refresh_wait_session, wait)
    wait
  end

  describe 'a poll pinned to the session the wait joined' do
    it 'writes no tasks/get once a reconnect inside rpc_request ended the session' do
      client = client_for(stdio)
      negotiated(stdio)
      wait = wait_for(client)
      sent = reconnecting_transport(stdio, result: detailed_task(status: 'completed', 'result' => call_result))

      expect(client.send(:poll_task, wait)).to be_nil
      expect(sent).to be_empty
    end

    it 'keeps polling after a lost poll rather than surfacing the session change' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:get_task) do
        polls += 1
        raise MCPClient::Errors::SessionChangedError, 'session 0 is over' if polls == 1

        task_from(detailed_task(status: 'completed', 'result' => call_result))
      end

      expect(client.wait_for_task('task-1', server: stdio, timeout: 2).status).to eq('completed')
      expect(polls).to eq(2)
    end
  end

  # Round 33 settled which side of a session move a terminal payload belongs
  # to: the poll was pinned to the wait's own session, so what came back is
  # this task's outcome; the session that replaced it is never asked about
  # the reused id.
  describe 'a session that ends around a terminal observation' do
    it 'returns the payload the wait own session answered' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        observation = task_from(detailed_task(status: 'completed', 'result' => call_result('this task')))
        stdio.send(:bump_session_epoch)
        observation
      end

      result = client.wait_for_task('task-1', server: stdio, timeout: 2)
      expect(result.result).to eq(call_result('this task'))
      expect(polls).to eq(1)
    end

    it 'raises no failure of another lifetime of the task id' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        observation = task_from(detailed_task(status: 'failed',
                                              'error' => { 'code' => -32_000, 'message' => 'this task' }))
        stdio.send(:bump_session_epoch)
        observation
      end

      # The failure the wait's own session reported, and no poll of the id in
      # the session that replaced it (whose task-1 may be anything at all).
      expect(client.wait_for_task('task-1', server: stdio, timeout: 2).error['message']).to eq('this task')
      expect(polls).to eq(1)
    end

    it 'forgets nothing of the session that replaced it' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        observation = task_from(detailed_task(status: 'completed', 'result' => call_result))
        stdio.send(:bump_session_epoch)
        client.send(:remember_answered_keys, stdio, 'task-1', ['k9'])
        observation
      end

      expect(client.wait_for_task('task-1', server: stdio, timeout: 2).status).to eq('completed')
      expect(polls).to eq(1)
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k9')
    end
  end

  describe 'input requests of a session that ended while an update was retransmitted' do
    it 'never reaches the host handlers' do
      asked = 0
      client = accepting_client(stdio) { asked += 1 }
      negotiated(stdio)
      # The retransmission is a full tasks/update RPC: the child may die under it.
      allow(client).to receive(:retransmit_pending_update) { stdio.send(:bump_session_epoch) }
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        if polls == 1
          task_from(detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }))
        else
          task_from(detailed_task(status: 'completed', 'result' => call_result))
        end
      end

      # The session did not survive the round trip, and neither does the
      # wait: the task is gone with it (round 33).
      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /session it belongs to ended/i)
      expect(asked).to eq(0)
      expect(polls).to eq(1)
    end
  end

  describe 'a terminal task handle kept across a restart' do
    it 'does not forget the replacement session bookkeeping for the reused id' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = task_from(detailed_task(status: 'completed', 'result' => call_result))
      stdio.send(:bump_session_epoch)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k9'])

      expect(client.wait_for_task(handle).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k9')
    end

    it 'still forgets its own session bookkeeping' do
      client = client_for(stdio)
      negotiated(stdio)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      handle = task_from(detailed_task(status: 'completed', 'result' => call_result))

      expect(client.wait_for_task(handle).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
    end
  end

  describe 'an explicit request for a task handle' do
    def modern_handle(status: 'working')
      MCPClient::Task.new(task_id: 'task-1', status: status, server: stdio, modern: true)
    end

    it 'refuses an update whose handle belongs to a session that has ended' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = modern_handle
      stdio.send(:bump_session_epoch)
      allow(stdio).to receive(:rpc_request)

      expect { client.update_task(handle, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(stdio).not_to have_received(:rpc_request)
    end

    it 'writes no tasks/update when a reconnect inside rpc_request ends the handle session' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = modern_handle
      sent = reconnecting_transport(stdio)

      expect(client.update_task(handle, { 'k1' => { 'action' => 'accept' } })).to be(true)
      expect(sent).to be_empty
    end

    it 'refuses a cancellation whose handle belongs to a session that has ended' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = modern_handle
      stdio.send(:bump_session_epoch)
      allow(stdio).to receive(:rpc_request)

      expect { client.cancel_task(handle) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(stdio).not_to have_received(:rpc_request)
    end

    it 'writes no tasks/cancel when a reconnect inside rpc_request ends the handle session' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = modern_handle
      sent = reconnecting_transport(stdio)

      expect { client.cancel_task(handle) }.to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(sent).to be_empty
    end

    it 'still cancels a task named by a bare id' do
      client = client_for(stdio)
      negotiated(stdio)
      allow(stdio).to receive(:rpc_request).and_return({})

      expect(client.cancel_task('task-1').status).to eq('working')
      expect(stdio).to have_received(:rpc_request).with('tasks/cancel', { taskId: 'task-1' })
    end
  end
end
