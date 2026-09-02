# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twenty-second review round: a handler
# round that timed out spends no input round, and a key whose abandoned
# handler is still running is not presented again until it finishes.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 22' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(id: 'task-1', ttl_ms: 60_000)
    now = Time.now.utc.iso8601
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => ttl_ms, 'pollIntervalMs' => 1 }
  end

  def detailed_task(status:, id: 'task-1', ttl_ms: 60_000, poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def tool_list
    { 'result' => { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }], 'ttlMs' => 60_000 } }
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
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

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'Name?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  # tasks/get says input_required (k1) until an update was acknowledged,
  # then completed; tasks/update is acknowledged.
  def sticky_task_server
    updated = false
    lambda { |req|
      case req['method']
      when 'tasks/update'
        updated = true
        { 'result' => {} }
      when 'tasks/get'
        if updated
          { 'result' => detailed_task(status: 'completed', 'result' => call_result) }
        else
          { 'result' => detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }) }
        end
      else
        raise "unexpected #{req['method']}"
      end
    }
  end

  # A handler that blocks until this example lets it finish: `entered` says
  # it started, `release` lets it return. It replaces a handler that slept
  # for a fixed time, so nothing here depends on a wall-clock margin holding
  # under a loaded suite.
  def blocking_handler(entered, release, blocking)
    lambda { |_m, _s|
      if blocking.value
        entered << true
        release.pop
      end
      { action: 'accept', content: { 'n' => 'x' } }
    }
  end

  # Block until the handler the wait abandoned has actually started: the
  # thread outlives the wait, so it always gets there.
  def await_start(entered)
    raise 'the abandoned handler never started' if entered.pop(timeout: 5).nil?
  end

  # Block until another thread has made the state transition, rather than
  # assuming a fixed delay was enough for it.
  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for the abandoned handler to release its keys' if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Kernel.sleep(0.005)
    end
  end

  it 'does not spend an input round on a handler that timed out' do
    blocking = Struct.new(:value).new(true)
    entered = Queue.new
    release = Queue.new
    handled = 0
    inner = blocking_handler(entered, release, blocking)
    client = client_for(stdio, elicitation_handler: lambda { |message, schema|
      handled += 1
      inner.call(message, schema)
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, sticky_task_server])
    task = client.call_tool_as_task('slow', {})

    (MCPClient::Client::TaskSupport::MAX_TASK_INPUT_ROUNDS + 2).times do
      expect { client.wait_for_task(task, timeout: 0.3) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
      await_start(entered)
      release << true # the abandoned handler finishes
      wait_until { client.send(:answered_task_keys, stdio, 'task-1').empty? }
    end
    expect(client.send(:task_state, stdio, 'task-1')[:rounds]).to eq(0)

    blocking.value = false
    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(MCPClient::Client::TaskSupport::MAX_TASK_INPUT_ROUNDS + 3)
  end

  it 'does not present a key again while its abandoned handler is still running' do
    blocking = Struct.new(:value).new(true)
    entered = Queue.new
    release = Queue.new
    handled = 0
    inner = blocking_handler(entered, release, blocking)
    client = client_for(stdio, elicitation_handler: lambda { |message, schema|
      handled += 1
      inner.call(message, schema)
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, sticky_task_server])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task, timeout: 0.3) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    await_start(entered)
    # The first presentation is still running: the retry polls, it does not ask again.
    expect { client.wait_for_task(task, timeout: 0.1) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(handled).to eq(1)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')

    release << true # the abandoned handler finishes; its answer is dropped
    wait_until { client.send(:answered_task_keys, stdio, 'task-1').empty? }
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty

    blocking.value = false
    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(2)
  end

  it 'rejects a completed result whose resultType is present but not "complete"' do
    expect(MCPClient::Task.complete_result_object?({ 'resultType' => false })).to be(false)
    expect(MCPClient::Task.complete_result_object?({ 'resultType' => nil })).to be(false)
    expect(MCPClient::Task.complete_result_object?({ 'resultType' => 'complete' })).to be(true)
    expect(MCPClient::Task.complete_result_object?({ 'content' => [] })).to be(true)
  end

  it 'maps -32602 on tasks/update and tasks/cancel to TaskNotFound only on an explicit indication' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'error' => { 'code' => -32_602, 'message' => 'Task already completed' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'Response value is invalid' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'No such task' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'Invalid params' } }])

    expect { client.cancel_task('task-1') }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e).not_to be_a(MCPClient::Errors::TaskNotFound)
      expect(e.message).to include('already completed')
    }
    expect { client.update_task('task-1', { 'k1' => { 'action' => 'decline' } }) }
      .to raise_error(MCPClient::Errors::TaskError) { |e| expect(e).not_to be_a(MCPClient::Errors::TaskNotFound) }
    expect { client.cancel_task('task-1') }.to raise_error(MCPClient::Errors::TaskNotFound)
    expect { client.get_task('task-1') }.to raise_error(MCPClient::Errors::TaskNotFound)
  end
end
