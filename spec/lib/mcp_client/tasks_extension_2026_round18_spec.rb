# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, eighteenth review round: the handle a
# modern CreateTaskResult produces is the validated flat Task itself; an
# extra `task` property (the legacy 2025 wrapper) never replaces it, and a
# malformed one is an InvalidResultError, never a NoMethodError.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 18' do
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

  def wrapped_task_result(task)
    task_result.merge('task' => task)
  end

  it 'keeps the validated flat task when a CreateTaskResult also carries a task property' do
    client = client_for(stdio)
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                                { 'result' => wrapped_task_result('taskId' => 'other', 'status' => 'working') },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    task = client.call_tool_as_task('slow', {})

    expect(task.task_id).to eq('task-1')
    expect(task.ttl_ms).to eq(60_000)
    expect(task.ttl_remaining).to be > 0
    expect(client.wait_for_task(task)).to be_completed
    expect(sent.select { |r| r['method'] == 'tasks/get' }.map { |r| r['params'][:taskId] || r['params']['taskId'] })
      .to eq(['task-1'])
  end

  it 'seeds the TTL backstop from the flat task even when a task property is present' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                         { 'result' => wrapped_task_result('taskId' => 'other', 'status' => 'working')
                                       .merge('ttlMs' => 300, 'createdAt' => '2000-01-01T00:00:00Z',
                                              'lastUpdatedAt' => '2000-01-01T00:00:00Z') },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'stalled' }])

    Timeout.timeout(5) do
      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    end
  end

  it 'never turns a malformed task property into a NoMethodError or ArgumentError' do
    ['hello', { 'taskId' => 'x', 'status' => 'pending' }, []].each do |wrapper|
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a')
      client = client_for(server)
      script_stdio(server, [{ 'result' => discover_result }, tool_list,
                            { 'result' => wrapped_task_result(wrapper) },
                            { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

      expect { client.call_tool_as_task('slow', {}) }.not_to raise_error
    end
  end

  it 'reports a non-object or unknown-status task as an invalid result on the modern path' do
    expect { MCPClient::Task.from_json('hello') }.to raise_error(MCPClient::Errors::InvalidResultError)
    expect { MCPClient::Task.from_json({ 'taskId' => 'x', 'status' => 'pending' }) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /status/)
  end
end
