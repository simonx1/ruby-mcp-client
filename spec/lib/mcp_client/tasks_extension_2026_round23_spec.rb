# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twenty-third review round: a key whose
# abandoned handler is still running is not presented again even after the
# task's TTL backstop (or any other forget) dropped the bookkeeping; a round
# whose delivery the deadline forbade is refunded; an explicit missing-task
# message wins over the params test; a task needs a string taskId.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 23' do
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

  # tasks/get says input_required (k1) with a short TTL until an update was
  # acknowledged, then completed.
  def sticky_short_ttl_server
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
          { 'result' => detailed_task(status: 'input_required', ttl_ms: 300,
                                      'inputRequests' => { 'k1' => elicit_request }) }
        end
      else
        raise "unexpected #{req['method']}"
      end
    }
  end

  it 'does not present a key again after the TTL backstop while its abandoned handler is still running' do
    slow = true
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      Kernel.sleep(1.0) if slow
      { action: 'accept', content: { 'n' => 'x' } }
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(ttl_ms: 300) },
                         sticky_short_ttl_server])
    task = client.call_tool_as_task('slow', {})

    # The TTL, not a caller timeout, ends the first wait while the handler runs.
    expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    # The server kept the task (it MAY purge after the TTL, it does not have
    # to): a retry polls the same key but must not ask the host again.
    expect { client.wait_for_task(task, timeout: 0.15) }.to raise_error(MCPClient::Errors::TaskError)
    expect(handled).to eq(1)

    Kernel.sleep(1.1) # the abandoned handler finished; its answer was dropped
    slow = false
    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(2)
  end

  it 'keeps an in-flight key reserved across an explicit forget of the task' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      Kernel.sleep(0.5)
      { action: 'accept', content: { 'n' => 'x' } }
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, sticky_task_server])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task, timeout: 0.05) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    client.send(:forget_task_keys, stdio, 'task-1')
    expect { client.wait_for_task(task, timeout: 0.1) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(handled).to eq(1)

    Kernel.sleep(0.6)
    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(2)
  end

  it 'refunds the input round when the deadline expired before delivery' do
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      Kernel.sleep(0.12)
      { action: 'accept', content: { 'n' => 'x' } }
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, sticky_task_server])
    task = client.call_tool_as_task('slow', {})
    # The handler finishes within the join, but the wait's deadline passed
    # before anything could be delivered.
    allow(client).to receive(:bounded_by_wait).and_wrap_original do |_m, *_args, **_kw, &blk|
      result = blk.call
      Kernel.sleep(0.15)
      result
    end

    expect { client.wait_for_task(task, timeout: 0.1) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(client.send(:task_state, stdio, 'task-1')[:rounds]).to eq(0)
  end

  it 'lets an explicit missing-task message win over the params test' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'error' => { 'code' => -32_602, 'message' => 'Invalid params: unknown task task-1' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'Invalid params: task not found' } }])

    expect { client.update_task('task-1', { 'k1' => { 'action' => 'decline' } }) }
      .to raise_error(MCPClient::Errors::TaskNotFound)
    expect { client.cancel_task('task-1') }.to raise_error(MCPClient::Errors::TaskNotFound)
  end

  it 'sends tasks/update without a timeout keyword when no bound applies' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }])
    allow(stdio).to receive(:rpc_request).and_call_original
    # The documented transport interface is rpc_request(method, params).
    expect(stdio).to receive(:rpc_request).with('tasks/update', hash_including(taskId: 'task-1')).and_return({})

    client.update_task('task-1', { 'k1' => { 'action' => 'decline' } })
  end

  it 'requires a string taskId in every task payload' do
    output = StringIO.new
    client = client_for(stdio, logger: Logger.new(output))
    script_stdio(stdio, [{ 'result' => discover_result }])
    now = Time.now.utc.iso8601
    params = { 'status' => 'working', 'createdAt' => now, 'lastUpdatedAt' => now, 'ttlMs' => nil }

    client.send(:process_notification, stdio, 'notifications/tasks', params)

    expect(output.string).to match(/taskId/)
    expect(output.string).not_to match(/status: working/)
    expect(client.send(:task_shape_problem, params)).to match(/taskId/)
  end
end
