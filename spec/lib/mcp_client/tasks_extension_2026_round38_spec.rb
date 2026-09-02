# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirty-eighth review round:
#
# - A streaming tools/call is lazy: the pin that keeps the call out of the
#   session which replaced the sampled one has to be held while the stream is
#   enumerated, in the thread that consumes it, not only while it is built.
# - The lifetime a request is about is bound to the request itself: it is
#   checked at the wire and again before the answer is acted on, so a
#   CreateTaskResult that lands after a preflight cannot leave a caller
#   updating, cancelling or reading the task that replaced its own.
# - Lifetimes stay distinguishable once the counter map is pruned: a re-created
#   id never reads as the lifetime a handle of the pruned one names.
# - Establishing a lifetime and reading it back is one step.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 38' do
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

  def task_tool(name: 'sync', task_support: nil)
    MCPClient::Tool.new(name: name, description: 'd', schema: { 'type' => 'object' }, server: stdio,
                        task_support: task_support)
  end

  def accept(value = 'x')
    { 'action' => 'accept', 'content' => { 'n' => value } }
  end

  describe 'the session a streaming tools/call is enumerated in' do
    before do
      allow(stdio).to receive_messages(list_tools: [task_tool], modern?: true, ping: true,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:ensure_session_ready)
      # Exactly what every built-in transport hands back: an Enumerator that
      # sends nothing until the consumer enumerates it.
      allow(stdio).to receive(:call_tool_streaming) do |tool_name, parameters|
        Enumerator.new { |yielder| yielder << stdio.call_tool(tool_name, parameters) }
      end
    end

    it 'sends nothing before the returned stream is enumerated' do
      ran = false
      allow(stdio).to receive(:call_tool) do
        ran = true
        call_result
      end
      client = client_for

      client.call_tool_streaming('sync', {})

      expect(ran).to be(false)
    end

    it 'does not run the tool in the session that replaced the one the stream was opened for' do
      ran = false
      allow(stdio).to receive(:call_tool) do
        stdio.check_session_pin!
        ran = true
        call_result
      end
      client = client_for
      stream = client.call_tool_streaming('sync', {})
      # The stdio child exited and was replaced before the host consumed the
      # stream; the pin has to still be in force when the call goes out.
      stdio.send(:bump_session_epoch)

      expect { stream.to_a }.to raise_error(MCPClient::Errors::SessionChangedError)
      expect(ran).to be(false)
    end

    it 'yields the chunks of a stream nothing disturbed' do
      allow(stdio).to receive(:call_tool) do
        stdio.check_session_pin!
        call_result
      end
      client = client_for

      expect(client.call_tool_streaming('sync', {}).to_a).to eq([call_result])
    end

    it 'resolves a task chunk of a stream it enumerated under the pin' do
      allow(stdio).to receive(:call_tool) do
        stdio.check_session_pin!
        create_result
      end
      client = client_for
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'completed', 'result' => call_result))

      expect(client.call_tool_streaming('sync', {}).to_a).to eq([call_result])
    end
  end

  describe 'the lifetime a task request is bound to' do
    # A transport whose rpc_request checks its pins where the built-in ones
    # do: immediately before the wire.
    def wired(sent, &before_wire)
      allow(stdio).to receive(:rpc_request) do |method, params|
        before_wire&.call(method)
        stdio.check_session_pin!
        sent << [method, params]
        {}
      end
    end

    it 'does not send a tasks/update once a creation lands between the check and the wire' do
      client = client_for
      negotiated
      handle = creation(client)
      sent = []
      wired(sent)
      # The replacement arrives while the update is establishing its session:
      # past every preflight, and before anything is written.
      allow(stdio).to receive(:ensure_session_ready) { creation(client) }

      expect { client.update_task(handle, { 'k1' => accept }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
      expect(sent).to be_empty
    end

    it 'still sends the tasks/update of a task nothing replaced' do
      client = client_for
      negotiated
      handle = creation(client)
      sent = []
      wired(sent)

      expect(client.update_task(handle, { 'k1' => accept })).to be(true)
      expect(sent.map(&:first)).to eq(['tasks/update'])
    end

    it 'does not send a tasks/cancel once a creation lands between the check and the wire' do
      client = client_for
      negotiated
      handle = creation(client)
      sent = []
      wired(sent) { |method| creation(client) if method == 'tasks/cancel' }

      expect { client.cancel_task(handle) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
      expect(sent).to be_empty
    end

    it 'does not act on a tasks/get answer whose task was replaced while it was in flight' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(stdio).to receive(:rpc_request) do |_method, _params|
        stdio.check_session_pin!
        # The answer is already on its way back when the id is handed out again.
        creation(client)
        detailed_task(status: 'working')
      end

      expect { client.get_task(handle) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'refuses the replaced task with a TaskReplacedError, a TaskError as before' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc)
      creation(client)

      expect { client.cancel_task(handle) }.to raise_error(MCPClient::Errors::TaskReplacedError)
      expect(MCPClient::Errors::TaskReplacedError.ancestors).to include(MCPClient::Errors::TaskError)
    end

    it 'leaves the bookkeeping of the lifetime that replaced the one a terminal poll asked about' do
      client = client_for
      negotiated
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      allow(stdio).to receive(:rpc_request) do
        stdio.check_session_pin!
        # A creation under the same id lands while the poll's answer is in
        # flight; its answered keys are the new task's.
        creation(client)
        client.send(:remember_answered_keys, stdio, 'task-1', ['k2'])
        detailed_task(status: 'completed', 'result' => call_result)
      end

      expect(client.get_task('task-1', server: stdio).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k2')
    end

    it 'still forgets the bookkeeping of the lifetime a terminal poll did ask about' do
      client = client_for
      negotiated
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'completed', 'result' => call_result))

      expect(client.get_task('task-1', server: stdio).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
    end
  end

  describe 'the lifetimes a prune forgets' do
    let(:cap) { MCPClient::Client::TaskRegistry::MAX_TRACKED_TASK_LIFETIMES }

    def crowd_out(client, count = nil)
      (count || (cap + 1)).times { |i| creation(client, result: create_result('taskId' => "other-#{i}")) }
    end

    it 'never lets a re-created id read as the lifetime a pruned handle names' do
      client = client_for
      negotiated
      handle = creation(client)

      crowd_out(client)
      recreated = creation(client)

      expect(recreated.task_generation).not_to eq(handle.task_generation)
    end

    it 'refuses an update through a handle whose lifetime the prune forgot' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc)

      crowd_out(client)

      expect { client.update_task(handle, { 'k1' => accept }) }
        .to raise_error(MCPClient::Errors::TaskError, /no longer tracks/i)
    end

    it 'refuses a cancel through a handle whose lifetime the prune forgot' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc)

      crowd_out(client)

      expect { client.cancel_task(handle) }.to raise_error(MCPClient::Errors::TaskError, /no longer tracks/i)
    end

    it 'keeps naming the task of a handle nothing crowded out' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working'))

      crowd_out(client, 8)

      expect(client.get_task(handle).task_generation).to eq(handle.task_generation)
    end
  end

  describe 'establishing a lifetime and reading it back' do
    it 'stamps a creation with the lifetime it established, not with a later reading' do
      client = client_for
      negotiated
      # A concurrent creation of the same id would move what a second,
      # separate reading of the counter returns.
      allow(client).to receive(:task_lifetime).and_return(99)

      expect(creation(client).task_generation).to eq(0)
    end

    it 'stamps a legacy creation with the lifetime it established' do
      allow(stdio).to receive_messages(
        list_tools: [task_tool(name: 'slow', task_support: 'optional')], modern?: false,
        capabilities: { 'tools' => {}, 'tasks' => { 'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request).and_return(create_result)
      client = client_for
      allow(client).to receive(:task_lifetime).and_return(99)

      expect(client.call_tool_as_task('slow', {}).task_generation).to eq(0)
    end

    it 'gives concurrent creations of one id lifetimes of their own' do
      client = client_for
      negotiated
      epoch = client.send(:current_session_epoch, stdio)
      seen = Queue.new

      threads = Array.new(8) do
        Thread.new { 4.times { seen << client.send(:start_task_lifetime, stdio, 'task-1', epoch) } }
      end
      threads.each { |thread| expect(thread.join(10)).not_to be_nil }

      generations = []
      generations << seen.pop until seen.empty?
      expect(generations.size).to eq(32)
      expect(generations.uniq.size).to eq(32)
    end
  end

  describe 'a task named without a lifetime' do
    it 'leaves the live bookkeeping alone when a terminal handle names no lifetime' do
      client = client_for
      negotiated
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      terminal = MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => call_result),
                                           server: stdio, detailed: true,
                                           session_epoch: client.send(:current_session_epoch, stdio))

      expect(client.wait_for_task(terminal).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end

    it 'lets a bare task id name whatever the id means now' do
      client = client_for
      negotiated
      creation(client)
      creation(client)
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }

      client.cancel_task('task-1', server: stdio)

      expect(sent.map(&:first)).to eq(['tasks/cancel'])
    end

    it 'lets a bare task id be updated after the id was handed out again' do
      client = client_for
      negotiated
      creation(client)
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }

      expect(client.update_task('task-1', { 'k1' => accept })).to be(true)
      expect(sent.map(&:first)).to eq(['tasks/update'])
    end
  end
end
