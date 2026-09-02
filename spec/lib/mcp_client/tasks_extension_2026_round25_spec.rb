# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twenty-fifth round: the watcher of an
# abandoned handler releases exactly the hold it took, never one a later
# session's retry placed under the same task id and key.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 25' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def client_for(server)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
  end

  def hold(client, srv, gate)
    runner = Thread.new { gate.pop }
    state = client.send(:task_state, srv, 'task-1')
    answered = client.send(:answered_task_keys, srv, 'task-1')
    answered << 'k1'
    held = client.send(:in_flight_task_keys, srv, 'task-1', create: true)
    client.send(:hold_in_flight_keys, runner, state, answered, ['k1'], held)
  end

  def settled?
    50.times do
      return true if yield

      sleep 0.02
    end
    false
  end

  it 'lets a hold taken in an earlier session end without dropping the hold of a later retry' do
    client = client_for(stdio)
    first_gate = Queue.new
    second_gate = Queue.new

    hold(client, stdio, first_gate)
    expect(client.send(:in_flight_task_keys, stdio, 'task-1')).to include('k1')

    # The process restarts: the reused task id and key are a new request,
    # presented again, and that retry's handler is abandoned too.
    stdio.send(:bump_session_epoch)
    expect(client.send(:in_flight_task_keys, stdio, 'task-1')).to be_empty
    hold(client, stdio, second_gate)
    expect(client.send(:in_flight_task_keys, stdio, 'task-1')).to include('k1')

    # The first handler finishes: only its own hold ends.
    first_gate << :done
    sleep 0.1
    expect(client.send(:in_flight_task_keys, stdio, 'task-1')).to include('k1')

    second_gate << :done
    expect(settled? { client.send(:in_flight_task_keys, stdio, 'task-1').empty? }).to be(true)
  end

  it 'records a hold under the session the handler started in, not the one current when it times out' do
    client = client_for(stdio)
    gate = Queue.new
    runner = Thread.new { gate.pop }
    state = client.send(:task_state, stdio, 'task-1')
    answered = client.send(:answered_task_keys, stdio, 'task-1')
    held = client.send(:in_flight_task_keys, stdio, 'task-1', create: true)

    stdio.send(:bump_session_epoch)
    client.send(:hold_in_flight_keys, runner, state, answered, ['k1'], held)

    expect(held).to include('k1')
    expect(client.send(:in_flight_task_keys, stdio, 'task-1')).to be_empty
    gate << :done
    expect(settled? { held.empty? }).to be(true)
  end

  it 'does not allocate a hold entry on a read' do
    client = client_for(stdio)

    expect(client.send(:in_flight_task_keys, stdio, 'task-1')).to be_empty
    expect(client.instance_variable_get(:@in_flight_keys)).to be_nil.or be_empty
  end

  it 'treats a fresh CreateTaskResult as a new task lifetime' do
    client = client_for(stdio)
    client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
    now = Time.now.utc.iso8601
    result = { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
               'lastUpdatedAt' => now, 'ttlMs' => 60_000, 'pollIntervalMs' => 1 }

    client.send(:created_task, result, stdio)

    expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
  end

  it 'drives a wait on a transport implementing only rpc_request(method, params)' do
    transport = Class.new(MCPClient::ServerBase) do
      attr_reader :calls

      def initialize
        super(name: 'two-arg')
        @calls = []
        @logger = Logger.new(File::NULL)
      end

      def connect = true # rubocop:disable Naming/PredicateMethod
      def capabilities = { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } }
      def modern? = true
      def protocol_version = '2026-07-28'
      def ping = {}

      def rpc_request(method, params = {})
        @calls << method
        now = Time.now.utc.iso8601
        { 'resultType' => 'complete', 'taskId' => params[:taskId], 'status' => 'completed', 'createdAt' => now,
          'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1,
          'result' => { 'content' => [{ 'type' => 'text', 'text' => 'ok' }], 'isError' => false } }
      end
    end.new
    client = client_for(transport)

    task = client.wait_for_task('task-1', server: transport, timeout: 5)

    expect(task).to be_completed
    expect(transport.calls).to include('tasks/get')
  end

  it 'still releases a same-session hold when its handler finishes' do
    client = client_for(stdio)
    gate = Queue.new
    hold(client, stdio, gate)

    gate << :done

    expect(settled? { client.send(:in_flight_task_keys, stdio, 'task-1').empty? }).to be(true)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).not_to include('k1')
  end
end
