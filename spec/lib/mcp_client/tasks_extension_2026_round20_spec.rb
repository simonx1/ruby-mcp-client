# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twentieth review round: an input handler
# is bounded by the wait's deadline and its answers are not delivered into
# a session that restarted meanwhile; an explicit null resultType in a
# completed task's result is invalid; a streamed task result is validated
# against the tool a mid-stream refresh replaced.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 20' do
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

  it 'does not deliver answers into a session that restarted while the handler ran' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      # The transport restarts (cleanup bumps the session epoch) while the
      # user is still answering the first request.
      stdio.send(:bump_session_epoch) if handled == 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                # The restarted server would reuse the id and the
                                # key; the wait never asks it (round 33).
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) }])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task) }
      .to raise_error(MCPClient::Errors::TaskError, /session it belongs to ended/i)
    expect(handled).to eq(1)
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(0)
  end

  it 'bounds a slow input handler by the wait deadline' do
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      Kernel.sleep(2)
      { action: 'accept', content: { 'n' => 'x' } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) }])
    task = client.call_tool_as_task('slow', {})

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { client.wait_for_task(task, timeout: 0.1) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(0)
    # The key stays reserved while the abandoned handler still presents it,
    # and is free again once that handler finished (round 22).
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    Kernel.sleep(2.1)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
  end

  it 'shares one capability probe between waits that time out on it' do
    client = client_for(stdio)
    pings = 0
    allow(stdio).to receive(:ping) {
      pings += 1
      Kernel.sleep(1.5)
    }

    2.times do
      expect do
        client.wait_for_task('task-1', timeout: 0.05)
      end.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    end

    expect(pings).to eq(1)
  end

  it 'logs a parse failure for a task notification that is not a task' do
    output = StringIO.new
    client = MCPClient::Client.new(mcp_server_configs: [], logger: Logger.new(output))

    client.send(:handle_task_status_notification, 'srv', {})
    client.send(:handle_task_status_notification, 'srv', { 'foo' => 1 })

    expect(output.string).not_to include('status: working')
  end

  it 'rejects an explicit null resultType in a completed task result' do
    expect(MCPClient::Task.complete_result_object?(call_result.merge('resultType' => nil))).to be(false)
    expect(MCPClient::Task.complete_result_object?(call_result)).to be(true)

    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'result' => detailed_task(status: 'completed',
                                                     'result' => call_result.merge('resultType' => nil)) }])

    expect { client.get_task('task-1') }.to raise_error(MCPClient::Errors::InvalidResultError)
  end

  it 'validates a streamed task result against the tool a mid-stream refresh replaced' do
    client = client_for(stdio, validate_structured_content: :strict)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list])
    client.list_tools
    stdio.singleton_class.include(MCPClient::CalledToolDefinition)
    strict_tool = MCPClient::Tool.new(name: 'slow', description: 'd', schema: { 'type' => 'object' },
                                      output_schema: { 'type' => 'object',
                                                       'properties' => { 'n' => { 'type' => 'string' } },
                                                       'required' => ['n'] }, server: stdio)
    allow(stdio).to receive(:call_tool_streaming) do
      Enumerator.new do |y|
        # A HeaderMismatch refresh replaced the tool while the stream ran;
        # the attempt that was answered went out under the refreshed one.
        allow(stdio).to receive(:list_tools).and_return([strict_tool])
        stdio.send(:note_called_tool_definition, 'slow', strict_tool)
        y << task_result
      end
    end
    completed = detailed_task(status: 'completed', 'result' => call_result.merge('structuredContent' => { 'n' => 1 }))
    allow(stdio).to receive(:rpc_request).with('tasks/get', anything, any_args).and_return(completed)

    expect { client.call_tool_streaming('slow', {}).to_a }.to raise_error(MCPClient::Errors::ValidationError)
  end
end
