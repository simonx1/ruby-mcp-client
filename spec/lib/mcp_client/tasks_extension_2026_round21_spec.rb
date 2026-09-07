# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twenty-first review round: input-key rejections
# are not a missing task, the TTL bounds an input handler, the wait's session
# and answered set are read together, legacy status notifications keep their
# flat shape, and the task model loads on its own.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 21' do
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

  it 'reports a rejected input key as a task error, not a missing task' do
    client = client_for(stdio, elicitation_handler: ->(_m, _s) { { action: 'accept', content: { 'n' => 'x' } } })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }) },
                         { 'error' => { 'code' => -32_602, 'message' => 'inputResponses key k1 not found' } }])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e).not_to be_a(MCPClient::Errors::TaskNotFound)
      expect(e.message).to include('inputResponses')
    }
  end

  it 'still maps an unknown task on tasks/update to TaskNotFound' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'error' => { 'code' => -32_602, 'message' => 'invalid taskId' } }])

    expect { client.update_task('gone', { 'k1' => { 'action' => 'decline' } }) }
      .to raise_error(MCPClient::Errors::TaskNotFound)
  end

  it 'bounds an input handler by the task TTL when the caller set no timeout' do
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      Kernel.sleep(5)
      { action: 'accept', content: { 'n' => 'x' } }
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(ttl_ms: 300) },
                         { 'result' => detailed_task(status: 'input_required', ttl_ms: 300,
                                                     'inputRequests' => { 'k1' => elicit_request }) }])
    allow(client).to receive(:sleep) { |s| Kernel.sleep(s) }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
  end

  it 'reads the session epoch together with the answered set' do
    client = client_for(stdio)
    # A server whose session moves on every read: the wait's epoch and the
    # state it points at must still belong to the same session.
    reads = 0
    allow(stdio).to receive(:session_epoch) { reads += 1 }
    wait = { srv: stdio, task_id: 't' }

    client.send(:refresh_wait_session, wait)

    states = client.instance_variable_get(:@task_states)
    expect(states[[stdio.object_id, wait[:epoch], 't']][:answered]).to equal(wait[:answered])
  end

  it 'keeps handling legacy notifications/tasks/status with the flat 2025 shape' do
    output = StringIO.new
    client = client_for(stdio, logger: Logger.new(output))
    params = { 'taskId' => 'legacy-1', 'status' => 'working', 'createdAt' => Time.now.utc.iso8601,
               'ttl' => 60_000, 'pollInterval' => 1000 }

    client.send(:process_notification, stdio, 'notifications/tasks/status', params)

    expect(output.string).to include('legacy-1')
    expect(output.string).to include('status: working')
    expect(output.string).not_to include('Failed to parse')
  end

  it 'loads the task model on its own' do
    script = "require 'mcp_client/task'; " \
             'begin; MCPClient::Task.from_json(nil); rescue MCPClient::Errors::InvalidResultError; exit 0; end; exit 1'
    expect(system(RbConfig.ruby, '-Ilib', '-e', script, out: File::NULL, err: File::NULL)).to be(true)
  end
end
