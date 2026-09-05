# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twenty-sixth round: the in-flight registry
# holds every key a running handler presents, per task, and a watcher only
# ever touches the entry it owns — another task's watcher cannot drop a live
# reservation.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 26' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'Name?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def input_required_task(id)
    now = Time.now.utc.iso8601
    MCPClient::Task.from_json({ 'taskId' => id, 'status' => 'input_required', 'createdAt' => now,
                                'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1,
                                'inputRequests' => { 'k1' => elicit_request } }, server: stdio, detailed: true)
  end

  def hold(client, srv, task_id, gate)
    runner = Thread.new { gate.pop }
    state = client.send(:task_state, srv, task_id)
    answered = client.send(:answered_task_keys, srv, task_id)
    answered << 'k1'
    held, key = client.send(:in_flight_task_keys, srv, task_id, create: true)
    client.send(:hold_in_flight_keys, runner, state, answered, ['k1'], held, key)
  end

  def settled?
    50.times do
      return true if yield

      sleep 0.02
    end
    false
  end

  it 'keeps a running handler\'s keys in flight while another task\'s watcher finishes' do
    handled = 0
    gate_a = Queue.new
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   elicitation_handler: lambda { |_m, _s|
                                     handled += 1
                                     gate_a.pop
                                     { action: 'accept', content: { 'n' => 'x' } }
                                   })
    allow(stdio).to receive(:rpc_request).and_return({})
    task_a = input_required_task('task-a')

    first = Thread.new do
      client.send(:answer_task_input_requests, task_a, client.send(:answered_task_keys, stdio, 'task-a'), stdio)
    end
    expect(settled? { handled == 1 }).to be(true)
    # The handler is presenting k1: the key is in flight from the start.
    expect(client.send(:in_flight_task_keys, stdio, 'task-a')).to include('k1')

    # Another task's abandoned handler ends; its watcher must not touch A.
    gate_b = Queue.new
    hold(client, stdio, 'task-b', gate_b)
    gate_b << :done
    expect(settled? { client.send(:in_flight_task_keys, stdio, 'task-b').empty? }).to be(true)
    expect(client.send(:in_flight_task_keys, stdio, 'task-a')).to include('k1')

    # A TTL retry forgets A's bookkeeping, then polls: k1 is not asked again.
    client.send(:forget_task_keys, stdio, 'task-a')
    second = client.send(:answer_task_input_requests, task_a, client.send(:answered_task_keys, stdio, 'task-a'), stdio)
    expect(second).to eq([])
    expect(handled).to eq(1)

    gate_a << :done
    first.join
    expect(settled? { client.send(:in_flight_task_keys, stdio, 'task-a').empty? }).to be(true)
    expect(client.instance_variable_get(:@in_flight_keys)).to be_nil.or be_empty
  end
  it 'keeps a lost update and its answered keys in the same session state' do
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
    # The session restarts right after every state lookup, and the update's
    # outcome is ambiguous: whichever state recorded the answered key must
    # also hold the pending payload, or nothing ever resends it.
    allow(client).to receive(:task_state).and_wrap_original do |m, *args|
      m.call(*args).tap { stdio.send(:bump_session_epoch) }
    end
    allow(stdio).to receive(:rpc_request).and_raise(MCPClient::Errors::TransportError, 'lost')

    expect { client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }) }
      .to raise_error(MCPClient::Errors::TaskError)

    states = client.instance_variable_get(:@task_states).values
    # Exactly one state recorded the key, and that very state holds the
    # payload to resend: losing both would satisfy the pairing below.
    carrying = states.select { |state| state[:answered].include?('k1') }
    expect(carrying.size).to eq(1)
    expect(carrying.first[:pending_update]).to eq({ 'k1' => { 'action' => 'accept' } })
    states.each do |state|
      expect(state[:answered].include?('k1')).to eq(!state[:pending_update].nil?)
    end
  end

  it 'validates a synchronous modern tools/call answer of call_tool_as_task like call_tool' do
    tool = MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                               output_schema: { 'type' => 'object', 'required' => ['a'] }, server: stdio)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    allow(stdio).to receive_messages(list_tools: [tool], modern?: true, ping: true,
                                     capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(stdio).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   validate_structured_content: :strict)

    expect { client.call_tool_as_task('sync', {}) }.to raise_error(MCPClient::Errors::ValidationError)
  end

  it 'treats an overflowing ttlMs as no backstop rather than raising' do
    now = Time.now.utc.iso8601
    task = MCPClient::Task.from_json({ 'taskId' => 't', 'status' => 'working', 'createdAt' => now,
                                       'lastUpdatedAt' => now, 'ttlMs' => 10**400 }, server: stdio)

    expect { task.ttl_remaining }.not_to raise_error
    expect(task.ttl_remaining).to be_nil.or be_a(Float)
  end
end
