# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirteenth review round: the standalone
# client entry point loads what the task APIs use, concurrent updates never
# lose a pending answer, task bookkeeping dies with the server session or
# the task, and a poll without a known pace waits the default interval.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 13' do
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

  it 'answers tasks_extension? from the standalone client entry point' do
    script = "require 'mcp_client/client'; " \
             'client = MCPClient::Client.new(mcp_server_configs: [], logger: Logger.new(File::NULL), ' \
             "extensions: ['io.modelcontextprotocol/tasks']); " \
             'exit(client.tasks_extension? ? 0 : 3)'
    expect(system(RbConfig.ruby, '-Ilib', '-e', script, out: File::NULL, err: File::NULL)).to be(true)
  end

  it 'serializes concurrent updates so an unconfirmed answer is carried by the next one' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }])
    task = client.call_tool_as_task('slow', {})
    updates = []
    second_started = Queue.new
    allow(stdio).to receive(:rpc_request) do |method, params, **|
      raise "unexpected #{method}" unless method == 'tasks/update'

      keys = params[:inputResponses].keys.map(&:to_s).sort
      updates << keys
      case keys
      when ['k1']
        # Fail only once a second update has read the (empty) pending slot,
        # or once it is clear no second update can start meanwhile.
        second_started.pop(timeout: 0.3)
        raise MCPClient::Errors::RequestTimeoutError, 'lost'
      when ['k2']
        # Unserialized: this request read an empty pending slot; the first
        # one now fails and records k1, which this success would then wipe.
        second_started << true
        sleep 0.1
        {}
      else
        {}
      end
    end

    first = Thread.new do
      client.update_task(task, { 'k1' => { 'action' => 'accept', 'content' => {} } })
    rescue MCPClient::Errors::TaskError
      nil
    end
    sleep 0.02
    second = Thread.new { client.update_task(task, { 'k2' => { 'action' => 'accept', 'content' => {} } }) }
    [first, second].each(&:join)

    expect(updates.last).to eq(%w[k1 k2])
    state = client.send(:task_state, stdio, 'task-1')
    expect(state[:pending_update]).to be_nil
    expect(state[:answered]).to include('k1', 'k2')
  end

  it 'forgets task bookkeeping when the server session ends' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, { 'result' => {} }])
    task = client.call_tool_as_task('slow', {})
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')

    stdio.cleanup

    expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
  end

  it 'forgets task bookkeeping once the task is gone or its TTL elapsed' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, { 'result' => {} },
                         { 'error' => { 'code' => -32_602, 'message' => 'Task not found' } }])
    task = client.call_tool_as_task('slow', {})
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })

    expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::TaskNotFound)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty

    script_stdio(stdio, [{ 'result' => {} }, { 'result' => detailed_task(status: 'working', ttl_ms: 1) }])
    client.update_task(task, { 'k2' => { 'action' => 'decline' } })
    sleep 0.01

    expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
  end

  it 'waits the default interval after a timed-out poll when no pace is known yet' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'stalled' },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    expect(client.wait_for_task('task-1')).to be_completed
    expect(client).to have_received(:sleep).with(MCPClient::Client::TaskSupport::DEFAULT_TASK_POLL_INTERVAL)
  end
end
