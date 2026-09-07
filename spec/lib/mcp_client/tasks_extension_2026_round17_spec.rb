# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, seventeenth review round: the caller's
# timeout bounds the whole wait including the capability probe, a task
# request never outlives the transport's configured timeout, a direct
# terminal or not-found lookup forgets the task's bookkeeping, a completed
# task's nested result is a complete result, and a CreateTaskResult carries
# the whole Task shape.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 17' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(id: 'task-1', ttl_ms: 60_000, created_at: Time.now.utc.iso8601)
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => created_at,
      'lastUpdatedAt' => created_at, 'ttlMs' => ttl_ms, 'pollIntervalMs' => 1 }
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

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def task_state_ids(client)
    (client.instance_variable_get(:@task_states) || {}).keys.map(&:last)
  end

  it 'bounds the whole wait by the caller timeout, capability probe included' do
    client = client_for(stdio)
    sent = script_stdio(stdio, [lambda { |_req|
                                  Kernel.sleep(0.3)
                                  { 'result' => discover_result }
                                },
                                { 'result' => detailed_task(status: 'working') }])

    Timeout.timeout(5) do
      expect { client.wait_for_task('task-1', timeout: 0.1) }
        .to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    end
    expect(sent.map { |r| r['method'] }).not_to include('tasks/get')
  end

  it 'never lets a task request outlive the transport read timeout' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(ttl_ms: 3_600_000) },
                         { 'result' => detailed_task(status: 'working', ttl_ms: 3_600_000) },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    allow(stdio).to receive(:rpc_request).and_call_original

    client.call_tool('slow', {})

    expect(stdio).to have_received(:rpc_request)
      .with('tasks/get', anything, hash_including(timeout: a_value <= 1)).at_least(:once)
    expect(stdio).not_to have_received(:rpc_request)
      .with('tasks/get', anything, hash_including(timeout: a_value > 1))
  end

  it 'forgets the task bookkeeping when get_task returns a terminal task' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => {} },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })
    expect(task_state_ids(client)).to include('task-1')

    expect(client.get_task(task)).to be_completed
    expect(task_state_ids(client)).not_to include('task-1')
  end

  it 'forgets the task bookkeeping when get_task reports the task gone' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => {} },
                         { 'error' => { 'code' => -32_602, 'message' => 'Task not found' } }])
    task = client.call_tool_as_task('slow', {})
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })

    expect { client.get_task(task) }.to raise_error(MCPClient::Errors::TaskNotFound)
    expect(task_state_ids(client)).not_to include('task-1')
  end

  it 'rejects a completed task whose nested result is not a complete result' do
    client = client_for(stdio)
    bogus = call_result.merge('resultType' => 'bogus')
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'completed', 'result' => bogus) },
                         { 'result' => detailed_task(status: 'completed', 'result' => bogus) }])

    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /resultType/)
    expect { client.get_task('task-1') }.to raise_error(MCPClient::Errors::InvalidResultError, /resultType/)
  end

  it 'rejects a CreateTaskResult that lacks the Task shape' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                         { 'result' => { 'resultType' => 'task', 'taskId' => 'x' } }])

    expect { client.call_tool('slow', {}) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /CreateTaskResult/)
  end
end
