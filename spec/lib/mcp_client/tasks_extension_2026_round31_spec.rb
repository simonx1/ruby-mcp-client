# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirty-first round: an observation that came
# back after the session ended is discarded (its input requests are never
# presented, its TTL never ends the replacement wait, its pace never delays the
# first poll of the new session), the session epoch holds at the wire rather
# than at the guard, and every piece of per-task bookkeeping is taken from the
# session the wait captured.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 31' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def detailed_task(status:, ttl_ms: nil, poll_ms: 1, created_at: nil, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => created_at || now,
      'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def call_result
    { 'content' => [{ 'type' => 'text', 'text' => 'done' }], 'isError' => false }
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

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def accepting_client(server, &counter)
    client_for(server, elicitation_handler: lambda { |_message, _schema|
      counter&.call
      { action: 'accept', content: { 'n' => 'x' } }
    })
  end

  describe 'an observation of a session that ended during the poll' do
    it 'never presents the ended session input requests to the host' do
      asked = 0
      client = accepting_client(stdio) { asked += 1 }
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |wait|
        polls += 1
        wait[:polled] = true
        if polls == 1
          # The answer describes the session that has just ended: its keys
          # belong to a task that no longer exists.
          observation = task_from(detailed_task(status: 'input_required',
                                                'inputRequests' => { 'k1' => elicit_request }))
          stdio.send(:bump_session_epoch)
          observation
        else
          task_from(detailed_task(status: 'completed', 'result' => call_result))
        end
      end

      expect(client.wait_for_task('task-1', server: stdio, timeout: 2).status).to eq('completed')
      expect(asked).to eq(0)
      expect(polls).to eq(2)
    end

    it 'does not end the replacement wait on the ended session TTL' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      survived = nil
      allow(client).to receive(:poll_task) do |wait|
        polls += 1
        wait[:polled] = true
        if polls == 1
          expired = detailed_task(status: 'working', ttl_ms: 1,
                                  created_at: (Time.now.utc - 60).iso8601(3))
          observation = task_from(expired)
          stdio.send(:bump_session_epoch)
          # The replacement session answered a key of its own already.
          client.send(:remember_answered_keys, stdio, 'task-1', ['k9'])
          observation
        else
          # The replacement session's bookkeeping is intact: the ended
          # session's TTL neither raised nor forgot it.
          survived = client.send(:answered_task_keys, stdio, 'task-1').include?('k9')
          task_from(detailed_task(status: 'completed', 'result' => call_result))
        end
      end

      expect(client.wait_for_task('task-1', server: stdio, timeout: 2).status).to eq('completed')
      expect(polls).to eq(2)
      expect(survived).to be(true)
    end

    it 'paces the first poll of the replacement session by its own default' do
      client = client_for(stdio)
      negotiated(stdio)
      delays = []
      allow(client).to receive(:sleep) { |seconds| delays << seconds }
      seed = MCPClient::Task.from_json({ 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working',
                                         'createdAt' => Time.now.utc.iso8601, 'ttlMs' => nil,
                                         'pollIntervalMs' => 3_600_000 }, server: stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |wait|
        polls += 1
        wait[:polled] = true
        if polls == 1
          stdio.send(:bump_session_epoch)
          nil
        else
          task_from(detailed_task(status: 'completed', 'result' => call_result))
        end
      end

      expect(client.wait_for_task(seed, server: stdio, timeout: 5).status).to eq('completed')
      expect(delays.first).to be <= MCPClient::Client::TaskSupport::DEFAULT_TASK_POLL_INTERVAL
    end

    it 'does not seed a wait from a task handle of a session that has ended' do
      client = client_for(stdio)
      negotiated(stdio)
      seed = MCPClient::Task.from_json({ 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working',
                                         'createdAt' => (Time.now.utc - 60).iso8601, 'ttlMs' => 1,
                                         'pollIntervalMs' => 1 }, server: stdio)
      stdio.send(:bump_session_epoch)
      polls = 0
      allow(client).to receive(:poll_task) do |wait|
        polls += 1
        wait[:polled] = true
        polls == 1 ? nil : task_from(detailed_task(status: 'completed', 'result' => call_result))
      end

      expect(client.wait_for_task(seed, server: stdio, timeout: 2).status).to eq('completed')
      expect(polls).to eq(2)
    end
  end

  describe 'the epoch holds at the wire' do
    it 'writes nothing when a reconnect inside rpc_request ended the session' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      sent = []
      allow(stdio).to receive(:send_request) { |req| sent << req }
      allow(stdio).to receive(:wait_response).and_return({ 'jsonrpc' => '2.0', 'id' => 1, 'result' => {} })
      # The session is live when the guard compares...
      allow(stdio).to receive(:ensure_session_ready)
      # ...and the child exits while rpc_request establishes its own.
      allow(stdio).to receive(:ensure_initialized) { stdio.send(:bump_session_epoch) }

      expect(client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch))
        .to be(true)

      expect(sent).to be_empty
      expect(client.send(:answered_task_keys, stdio, 't')).not_to include('k1')
    end

    it 'does not swallow a failure to establish the session' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      allow(stdio).to receive(:ensure_session_ready).and_raise(MCPClient::Errors::ConnectionError, 'child gone')
      allow(stdio).to receive(:rpc_request)

      expect { client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch) }
        .to raise_error(MCPClient::Errors::TaskError, /child gone/)

      expect(stdio).not_to have_received(:rpc_request)
      # Nothing was delivered: the answers stay pending for the next poll.
      expect(client.send(:task_state, stdio, 't')[:pending_update]).to include('k1')
    end
  end

  describe 'the bookkeeping of the session the wait captured' do
    it 'keeps the answers of an update abandoned while queued behind another one' do
      client = client_for(stdio)
      state = client.send(:task_state, stdio, 't')
      gate = Queue.new
      holder = Thread.new { state[:update_mutex].synchronize { gate.pop } }
      Thread.pass until state[:update_mutex].locked?
      wait = { task_id: 't', srv: stdio, epoch: nil, state: state, answered: state[:answered],
               deadline: monotonic + 0.1, ttl_deadline: nil }

      expect { client.send(:deliver_task_update, stdio, 't', { 'k2' => { 'action' => 'accept' } }, wait) }
        .to raise_error(MCPClient::Errors::TaskError, /Timed out/)

      expect(state[:pending_update]).to include('k2')
      expect(client.send(:answered_task_keys, stdio, 't')).to include('k2')
    ensure
      gate << :done
      holder&.join
    end

    it 'charges an input round to the session the wait captured, not to the replacement' do
      client = accepting_client(stdio)
      negotiated(stdio)
      captured = client.send(:task_state, stdio, 'task-1')
      wait = { task_id: 'task-1', srv: stdio, epoch: client.send(:current_session_epoch, stdio),
               state: captured, answered: captured[:answered], deadline: nil, ttl_deadline: nil }
      task = task_from(detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }))
      # The session ends between the wait's refresh and the reservation.
      stdio.send(:bump_session_epoch)

      expect(client.send(:answer_task_input_requests, task, wait[:answered], stdio, wait)).to eq([])

      fresh = client.send(:task_state, stdio, 'task-1')
      expect(fresh[:rounds]).to eq(0)
      expect(fresh[:answered]).to be_empty
      expect(client.send(:in_flight_task_keys, stdio, 'task-1')).to be_empty
    end

    it 'reads the session epoch under the registry lock while answering' do
      client = accepting_client(stdio)
      negotiated(stdio)
      unlocked = []
      allow(client).to receive(:deliver_task_update)
      captured = client.send(:task_state, stdio, 'task-1')
      wait = { task_id: 'task-1', srv: stdio, epoch: client.send(:current_session_epoch, stdio),
               state: captured, answered: captured[:answered], deadline: nil, ttl_deadline: nil }
      allow(client).to receive(:current_session_epoch).and_wrap_original do |original, server|
        unlocked << server unless client.send(:answered_keys_mutex).owned?
        original.call(server)
      end
      task = task_from(detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }))

      client.send(:answer_task_input_requests, task, wait[:answered], stdio, wait)

      expect(unlocked).to be_empty
    end
  end
end
