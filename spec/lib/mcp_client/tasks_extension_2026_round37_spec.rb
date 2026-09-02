# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirty-seventh review round:
#
# - Every observed creation under a task id starts a lifetime of its own, even
#   when nothing of the previous one is on the books any more, and every handle
#   a creation or a tasks/get hands out names the lifetime it belongs to.
# - A task-producing tools/call is written into the session it was sampled for
#   and into no other.
# - The bookkeeping cleanups are bounded: a rejected update gives back only what
#   it still owns, a request through a transport that takes no timeout is
#   bounded on the wall clock, and answers whose task another waiter already
#   saw gone are not delivered.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 37' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def create_result(**extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def detailed_task(status:, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  # A definite JSON-RPC rejection: the server answered and did not take it.
  def invalid_params(message)
    MCPClient::Errors::ServerError.new(message, code: MCPClient::Errors::Codes::INVALID_PARAMS)
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'ok?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def client_for(server = stdio, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server = stdio)
    allow(server).to receive(:capabilities).and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:modern?).and_return(true)
    allow(server).to receive(:ensure_session_ready)
  end

  # One CreateTaskResult, as the server would answer it in the live session.
  def creation(client, srv: stdio, result: nil)
    client.send(:created_task, result || create_result, srv, client.send(:current_session_epoch, srv))
  end

  def wait_joined(client, task_id: 'task-1', srv: stdio)
    wait = { task_id: task_id, srv: srv, deadline: nil, ttl_deadline: nil,
             answered: nil, state: nil, epoch: nil, last: nil }
    client.send(:refresh_wait_session, wait)
    wait
  end

  def task_tool(name: 'sync', task_support: nil)
    MCPClient::Tool.new(name: name, description: 'd', schema: { 'type' => 'object' }, server: stdio,
                        task_support: task_support)
  end

  # A transport that implements only the documented two-argument
  # rpc_request(method, params): no timeout keyword, and its own session pin.
  def two_arg_server(gate = nil)
    Class.new do
      include MCPClient::SessionPin

      attr_accessor :session_epoch
      attr_reader :sent

      def initialize(gate)
        @gate = gate
        @session_epoch = 0
        @sent = 0
      end

      def name
        'two-arg'
      end

      def rpc_request(_method, _params)
        @sent += 1
        check_session_pin!
        @gate ? @gate.pop : {}
      end
    end.new(gate)
  end

  describe 'a lifetime for every creation under a task id' do
    it 'gives two creations with no wait between them distinct lifetimes' do
      client = client_for
      negotiated

      first = creation(client)
      second = creation(client)

      expect(second.task_generation).to eq(first.task_generation + 1)
    end

    it 'refuses an update built for the task a second creation replaced' do
      client = client_for
      negotiated
      allow(client).to receive(:task_rpc)
      first = creation(client)

      creation(client)

      expect { client.update_task(first, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'refuses to cancel the task a second creation replaced' do
      client = client_for
      negotiated
      allow(client).to receive(:task_rpc)
      first = creation(client)

      creation(client)

      expect { client.cancel_task(first) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'starts a new lifetime for a creation made after the previous task was forgotten' do
      client = client_for
      negotiated
      first = creation(client)
      client.send(:task_state, stdio, 'task-1')
      # A terminal poll (or a TTL expiry) dropped everything the id had.
      client.send(:forget_task_keys, stdio, 'task-1')

      second = creation(client)

      expect(second.task_generation).to eq(first.task_generation + 1)
    end

    it 'leaves the very first creation of an unseen id at its first lifetime' do
      client = client_for
      negotiated

      first = creation(client)

      expect(first.task_generation).to eq(0)
      expect(client.send(:task_state, stdio, 'task-1')[:generation]).to eq(0)
    end

    it 'binds a legacy call_tool_as_task handle to the task it named' do
      allow(stdio).to receive_messages(
        list_tools: [task_tool(name: 'slow', task_support: 'optional')], modern?: false,
        capabilities: { 'tools' => {}, 'tasks' => { 'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request).and_return(create_result)
      client = client_for

      first = client.call_tool_as_task('slow', {})
      second = client.call_tool_as_task('slow', {})

      expect(first.task_generation).to eq(0)
      expect(second.task_generation).to eq(1)
    end
  end

  describe 'the lifetime counters a long-lived session accumulates' do
    let(:cap) { MCPClient::Client::TaskRegistry::MAX_TRACKED_TASK_LIFETIMES }

    it 'bounds how many task ids it keeps a counter for' do
      client = client_for
      negotiated

      (cap + 1).times { |i| creation(client, result: create_result('taskId' => "task-#{i}")) }

      expect(client.instance_variable_get(:@task_lifetimes).size).to be <= cap
    end

    it 'never drops the counter of a task whose bookkeeping is still live' do
      client = client_for
      negotiated
      creation(client)
      creation(client)
      live = client.send(:task_state, stdio, 'task-1')

      (cap + 1).times { |i| creation(client, result: create_result('taskId' => "other-#{i}")) }

      expect(live[:generation]).to eq(1)
      expect(client.send(:task_lifetime_current?, live)).to be(true)
    end
  end

  describe 'the lifetime a tasks/get keeps' do
    it 'stamps a refreshed handle with the lifetime of the handle it was asked for' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working'))

      refreshed = client.get_task(handle)

      expect(refreshed.task_generation).to eq(handle.task_generation)
    end

    it 'refuses an update through a refreshed handle once the id was handed out again' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working'))
      refreshed = client.get_task(handle)

      creation(client)

      expect { client.update_task(refreshed, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'leaves a handle for a bare task id naming whatever the id means now' do
      client = client_for
      negotiated
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working'))

      expect(client.get_task('task-1', server: stdio).task_generation).to be_nil
    end
  end

  describe 'the session a task-producing tools/call is written into' do
    def ends_session_at_the_wire
      lambda do |*_args|
        # The stdio child exited and was replaced between the sampling and
        # the write; the transport checks its pin right before the wire.
        stdio.send(:bump_session_epoch)
        stdio.check_session_pin!
        create_result
      end
    end

    before do
      allow(stdio).to receive_messages(list_tools: [task_tool], modern?: true, ping: true,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:ensure_session_ready)
    end

    it 'does not execute a modern tools/call in the session that replaced the sampled one' do
      allow(stdio).to receive(:call_tool, &ends_session_at_the_wire)
      client = client_for

      expect { client.call_tool('sync', {}) }
        .to raise_error(MCPClient::Errors::ToolCallError, /session/i)
    end

    it 'does not execute a modern call_tool_as_task in the session that replaced the sampled one' do
      allow(stdio).to receive(:call_tool, &ends_session_at_the_wire)
      client = client_for

      expect { client.call_tool_as_task('sync', {}) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
    end

    it 'does not open a streaming tools/call in the session that replaced the sampled one' do
      allow(stdio).to receive(:call_tool_streaming) do
        stdio.send(:bump_session_epoch)
        stdio.check_session_pin!
        [create_result].each
      end
      client = client_for

      expect { client.call_tool_streaming('sync', {}) }
        .to raise_error(MCPClient::Errors::ToolCallError, /session/i)
    end
  end

  describe 'a terminal handle waited on again after its id was reused' do
    it 'leaves the live task bookkeeping of the new lifetime alone' do
      client = client_for
      negotiated
      creation(client)
      terminal = MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => call_result),
                                           server: stdio, detailed: true, task_generation: 0,
                                           session_epoch: client.send(:current_session_epoch, stdio))
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])

      expect(client.wait_for_task(terminal).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end

    it 'still forgets the bookkeeping of the lifetime the handle belongs to' do
      client = client_for
      negotiated
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      terminal = MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => call_result),
                                           server: stdio, detailed: true, task_generation: 0,
                                           session_epoch: client.send(:current_session_epoch, stdio))

      expect(client.wait_for_task(terminal).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
    end
  end

  describe 'a cancel the server answered with an unknown task' do
    it 'forgets the keys of the session it was pinned to, not of the one that replaced it' do
      client = client_for
      negotiated
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      allow(client).to receive(:task_rpc) do
        # The child exited while the cancel was in flight and the successor
        # session gave the id to a task of its own.
        stdio.send(:bump_session_epoch)
        client.send(:remember_answered_keys, stdio, 'task-1', ['k2'])
        raise invalid_params('Task not found')
      end

      expect { client.cancel_task('task-1', server: stdio) }.to raise_error(MCPClient::Errors::TaskNotFound)
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k2')
    end
  end

  describe 'two updates for one input key that overlap' do
    it 'keeps the newer answer a definite rejection of the older one did not carry' do
      client = client_for
      negotiated
      state = client.send(:task_state, stdio, 'task-1')
      older = { 'action' => 'accept', 'content' => { 'n' => 'old' } }
      newer = { 'action' => 'accept', 'content' => { 'n' => 'new' } }
      allow(client).to receive(:task_rpc) do
        client.send(:queue_task_update, state, { 'k1' => newer })
        raise invalid_params('rejected inputResponses')
      end

      expect do
        client.send(:send_task_update, stdio, 'task-1', { 'k1' => older }, state: state)
      end.to raise_error(MCPClient::Errors::TaskError)

      expect(state[:pending_update]).to eq({ 'k1' => newer })
      expect(state[:answered]).to include('k1')
      expect(state[:submitted]).to include('k1')
    end

    it 'still gives back a rejected key nothing newer superseded' do
      client = client_for
      negotiated
      state = client.send(:task_state, stdio, 'task-1')
      allow(client).to receive(:task_rpc) do
        raise invalid_params('rejected inputResponses')
      end

      expect do
        client.send(:send_task_update, stdio, 'task-1', { 'k1' => { 'action' => 'accept' } }, state: state)
      end.to raise_error(MCPClient::Errors::TaskError)

      expect(state[:pending_update]).to be_nil
      expect(state[:answered]).to be_empty
      expect(state[:submitted]).to be_empty
    end
  end

  describe 'a transport that cannot take a per-request timeout' do
    it 'bounds a task request on the wall clock instead of running it inline forever' do
      gate = Queue.new
      srv = two_arg_server(gate)
      client = client_for
      raised = nil

      runner = Thread.new do
        client.send(:task_rpc, srv, 'tasks/get', { taskId: 'task-1' }, timeout: 0.05)
      rescue StandardError => e
        raised = e
      end

      expect(runner.join(5)).not_to be_nil
      expect(raised).to be_a(MCPClient::Errors::RequestTimeoutError)
      gate << {}
    end

    it 'still pins the bounded request to the session it belongs to' do
      srv = two_arg_server
      srv.define_singleton_method(:rpc_request) do |_method, _params|
        self.session_epoch += 1
        check_session_pin!
        {}
      end
      client = client_for

      expect { client.send(:task_rpc, srv, 'tasks/get', { taskId: 'task-1' }, timeout: 1, epoch: 0) }
        .to raise_error(MCPClient::Errors::SessionChangedError)
    end

    it 'hands a transport that does take the keyword its timeout as before' do
      client = client_for
      negotiated
      seen = nil
      allow(stdio).to receive(:rpc_request) { |_m, _p, **kw| seen = kw[:timeout] }

      client.send(:task_rpc, stdio, 'tasks/get', { taskId: 'task-1' }, timeout: 2)

      expect(seen).to eq(2)
    end
  end

  describe 'answers whose task another waiter already saw gone' do
    it 'discards them rather than updating the task the id names now' do
      client = client_for
      negotiated
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }
      wait = wait_joined(client)
      task = MCPClient::Task.from_json(detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }),
                                       server: stdio, detailed: true)
      allow(stdio).to receive(:fulfil_input_requests) do |pending, _task|
        # Another wait polled the task terminal while the host was answering.
        client.send(:forget_task_keys, stdio, 'task-1', state: wait[:state])
        pending.transform_values { { 'action' => 'accept', 'content' => { 'n' => 'x' } } }
      end

      expect(client.send(:answer_task_input_requests, task, wait[:answered], stdio, wait)).to eq([])
      expect(sent).to be_empty
    end

    it 'still delivers the answers of a task nothing disturbed' do
      client = client_for
      negotiated
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }
      wait = wait_joined(client)
      task = MCPClient::Task.from_json(detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }),
                                       server: stdio, detailed: true)
      allow(stdio).to receive(:fulfil_input_requests) do |pending, _task|
        pending.transform_values { { 'action' => 'accept', 'content' => { 'n' => 'x' } } }
      end

      expect(client.send(:answer_task_input_requests, task, wait[:answered], stdio, wait)).to eq(['k1'])
      expect(sent.map(&:first)).to eq(['tasks/update'])
    end
  end

  describe 'the pollIntervalMs of a task payload' do
    it 'refuses a CreateTaskResult whose pollIntervalMs is not an integer' do
      client = client_for
      negotiated

      expect { creation(client, result: create_result('pollIntervalMs' => 'soon')) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /pollIntervalMs/)
    end

    it 'refuses a CreateTaskResult whose pollIntervalMs is negative' do
      client = client_for
      negotiated

      expect { creation(client, result: create_result('pollIntervalMs' => -1)) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /pollIntervalMs/)
    end

    it 'refuses a tasks/get whose pollIntervalMs is not an integer' do
      client = client_for
      negotiated
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working', 'pollIntervalMs' => '1'))

      expect { client.get_task('task-1', server: stdio) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /pollIntervalMs/)
    end

    it 'accepts a task that reports no pollIntervalMs at all' do
      client = client_for
      negotiated
      result = create_result
      result.delete('pollIntervalMs')

      expect(creation(client, result: result).poll_interval_ms).to be_nil
    end

    it 'accepts an explicitly null pollIntervalMs' do
      client = client_for
      negotiated

      expect(creation(client, result: create_result('pollIntervalMs' => nil)).poll_interval_ms).to be_nil
    end
  end
end
