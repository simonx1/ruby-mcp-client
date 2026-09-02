# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirtieth round: the session epoch is
# enforced at the wire (the connection is established before the guard, so a
# reconnect inside rpc_request cannot slip an ended session's answers into the
# next one), a rejected update gives its keys back to the state it was built
# from, a wait refreshes its session before enforcing a TTL that belongs to the
# previous one, and an abandoned task RPC leaves the pending payload and the
# task's bookkeeping usable by the next wait.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 30' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(ttl_ms: nil, poll_ms: 1)
    now = Time.now.utc.iso8601
    { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }
  end

  def detailed_task(status:, ttl_ms: nil, poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def tool_list
    { 'result' => { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }], 'ttlMs' => 60_000 } }
  end

  def call_result
    { 'content' => [{ 'type' => 'text', 'text' => 'done' }], 'isError' => false }
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'Name?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    server.instance_variable_set(:@stdout, double('stdout', closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.first.respond_to?(:call) && responses.size == 1 ? responses.first : responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
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

  describe 'the epoch guard holds at the wire' do
    it 'drops the payload when establishing the connection restarted the session' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      # rpc_request calls ensure_initialized: a reconnect there bumps the
      # epoch inside the very call the guard was meant to protect.
      allow(stdio).to receive(:ensure_session_ready) { stdio.send(:bump_session_epoch) }
      allow(stdio).to receive(:rpc_request).and_return({})

      expect(client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch)).to be(true)

      expect(stdio).not_to have_received(:rpc_request)
      expect(client.send(:answered_task_keys, stdio, 't')).not_to include('k1')
    end

    it 'establishes the session before it compares the epoch' do
      client = client_for(stdio)
      calls = []
      allow(stdio).to receive(:ensure_session_ready) { calls << :ready }
      allow(stdio).to receive(:rpc_request) do
        calls << :sent
        {}
      end

      client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } },
                  epoch: client.send(:current_session_epoch, stdio))

      expect(calls).to eq(%i[ready sent])
    end
  end

  describe 'a rejected update releases the state it was built from' do
    it 'leaves the keys the new session answered alone' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request) do
        stdio.send(:bump_session_epoch)
        # The new session answered the same key for what is a new task.
        client.send(:remember_answered_keys, stdio, 't', ['k1'])
        raise MCPClient::Errors::ServerError.new('bad inputResponses', code: -32_602)
      end

      expect { client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch) }
        .to raise_error(MCPClient::Errors::TaskError)

      expect(client.send(:answered_task_keys, stdio, 't')).to include('k1')
    end

    it 'forgets only the bookkeeping the update captured when the task is reported gone' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request) do
        stdio.send(:bump_session_epoch)
        client.send(:remember_answered_keys, stdio, 't', ['k1'])
        raise MCPClient::Errors::ServerError.new('task not found', code: -32_602)
      end

      expect { client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch) }
        .to raise_error(MCPClient::Errors::TaskNotFound)

      expect(client.send(:answered_task_keys, stdio, 't')).to include('k1')
    end
  end

  describe 'a wait refreshes its session before enforcing a TTL' do
    it 'resets the session-scoped fields when the wait moves to a new session' do
      client = client_for(stdio)
      wait = { task_id: 't', srv: stdio, epoch: nil, answered: nil, ttl_deadline: nil, last: nil }
      client.send(:refresh_wait_session, wait)
      first = wait[:epoch]
      wait[:ttl_deadline] = monotonic + 5
      wait[:last] = :seed
      stdio.send(:bump_session_epoch)

      client.send(:refresh_wait_session, wait)

      expect(wait[:epoch]).to eq(first + 1)
      expect(wait[:ttl_deadline]).to be_nil
      expect(wait[:last]).to be_nil
    end

    it 'does not enforce the TTL backstop of a session that has ended' do
      client = client_for(stdio)
      wait = { task_id: 't', srv: stdio, epoch: client.send(:current_session_epoch, stdio), answered: Set.new,
               deadline: nil, ttl_deadline: monotonic - 1, last: :seed, polled: true }
      stdio.send(:bump_session_epoch)

      expect { client.send(:raise_if_past_deadline!, wait) }.not_to raise_error
      expect(wait[:ttl_deadline]).to be_nil
    end

    it 'keeps polling the replacement session after a restart during the poll' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |wait|
        polls += 1
        wait[:polled] = true
        if polls == 1
          # The poll timed out; the server restarted while it was outstanding.
          wait[:ttl_deadline] = monotonic - 1
          stdio.send(:bump_session_epoch)
          nil
        else
          MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => call_result),
                                    server: stdio, detailed: true)
        end
      end

      task = client.wait_for_task('task-1', server: stdio, timeout: 2)

      expect(task.status).to eq('completed')
      expect(polls).to eq(2)
    end
  end

  describe 'an abandoned task RPC keeps the bookkeeping usable' do
    it 'retransmits the answers of an abandoned update without asking the host again' do
      gate = Queue.new
      answered = 0
      updates = 0
      updated = false
      client = client_for(stdio, elicitation_handler: lambda { |_message, _schema|
        answered += 1
        { action: 'accept', content: { 'n' => 'x' } }
      })
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                           lambda { |req|
                             if req['method'] == 'tasks/update'
                               updates += 1
                               gate.pop if updates == 1
                               updated = true
                               next { 'result' => {} }
                             end
                             if updated
                               { 'result' => detailed_task(status: 'completed', 'result' => call_result) }
                             else
                               { 'result' => detailed_task(status: 'input_required',
                                                           'inputRequests' => { 'k1' => elicit_request }) }
                             end
                           }])

      task = client.call_tool_as_task('slow', {})
      expect { client.wait_for_task(task, timeout: 0.3) }
        .to raise_error(MCPClient::Errors::TaskError, /Timed out/)
      expect(answered).to eq(1)

      expect(client.wait_for_task(task, timeout: 2).status).to eq('completed')
      expect(answered).to eq(1)
      expect(updates).to be >= 2
    ensure
      gate << :done
    end

    it 'lets a late forget from an abandoned request leave a reused task id alone' do
      client = client_for(stdio)
      abandoned = client.send(:task_state, stdio, 'task-1')
      # The wait ended; a new lifetime of the same id starts and is answered.
      client.send(:forget_task_keys, stdio, 'task-1')
      fresh = client.send(:task_state, stdio, 'task-1')
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])

      client.send(:forget_task_keys, stdio, 'task-1', state: abandoned)

      expect(client.send(:task_state, stdio, 'task-1')).to equal(fresh)
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end

    it 'does not drop a reused task id bookkeeping when an abandoned poll comes back terminal' do
      client = client_for(stdio)
      negotiated(stdio)
      abandoned = client.send(:task_state, stdio, 'task-1')
      client.send(:forget_task_keys, stdio, 'task-1')
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      allow(stdio).to receive(:rpc_request)
        .and_return(detailed_task(status: 'completed', 'result' => call_result))

      client.get_task('task-1', server: stdio, state: abandoned)

      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end
  end
end
