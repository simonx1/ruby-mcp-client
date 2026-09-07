# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirty-ninth review round:
#
# - A result a task delivers is the result of a tools/call, and is validated
#   against the definition that call went out under exactly as a synchronous
#   one is: the handle a creation hands back carries it.
# - A task that is over leaves nothing behind: the legacy result and cancel
#   APIs release its bookkeeping the way a terminal poll does.
# - An expired task is a task that is gone, whichever request reported it.
# - The pace a server asks for is kept, not shortened.
# - A completed task's result is the request's own result, `isError` and all.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 39' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def detailed_task(status:, poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def create_result(id: 'task-1', **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def structured_tool(server = stdio)
    MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                        output_schema: { 'type' => 'object', 'required' => ['n'],
                                         'properties' => { 'n' => { 'type' => 'integer' } } },
                        server: server)
  end

  def client_for(server = stdio, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  describe 'the schema a task-delivered result is checked against' do
    before do
      stdio.singleton_class.include(MCPClient::CalledToolDefinition)
      allow(stdio).to receive_messages(list_tools: [structured_tool], modern?: true, ping: true,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:call_tool) do
        stdio.send(:note_called_tool_definition, 'sync', structured_tool)
        create_result
      end
    end

    def terminal(result)
      allow(stdio).to receive(:rpc_request) do |method, _params, **_kw|
        raise "unexpected #{method}" unless method == 'tasks/get'

        detailed_task(status: 'completed', 'result' => result)
      end
    end

    it 'rejects structured content a task delivered that the tool forbids' do
      client = client_for(validate_structured_content: :strict)
      task = client.call_tool_as_task('sync', {})
      terminal({ 'content' => [], 'isError' => false, 'structuredContent' => { 'n' => 'wrong' } })

      expect { client.get_task_result(task) }.to raise_error(MCPClient::Errors::ValidationError, /output schema/)
    end

    it 'returns structured content a task delivered that the tool allows' do
      client = client_for(validate_structured_content: :strict)
      task = client.call_tool_as_task('sync', {})
      terminal({ 'content' => [], 'isError' => false, 'structuredContent' => { 'n' => 1 } })

      expect(client.get_task_result(task)['structuredContent']).to eq({ 'n' => 1 })
    end

    it 'validates against the definition a mid-creation refresh replaced' do
      refreshed = MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                                      output_schema: { 'type' => 'object', 'required' => ['b'] }, server: stdio)
      allow(stdio).to receive(:call_tool) do
        # A HeaderMismatch refresh replaced the definition while the creating
        # call ran; the attempt that was answered went out under this one.
        allow(stdio).to receive(:list_tools).and_return([refreshed])
        stdio.send(:note_called_tool_definition, 'sync', refreshed)
        create_result
      end
      client = client_for(validate_structured_content: :strict)
      task = client.call_tool_as_task('sync', {})
      terminal({ 'content' => [], 'isError' => false, 'structuredContent' => { 'n' => 1 } })

      expect { client.get_task_result(task) }.to raise_error(MCPClient::Errors::ValidationError, /'b'/)
    end

    it 'leaves an isError result of a task alone, as a synchronous one is' do
      client = client_for(validate_structured_content: :strict)
      task = client.call_tool_as_task('sync', {})
      terminal({ 'content' => [{ 'type' => 'text', 'text' => 'boom' }], 'isError' => true })

      expect(client.get_task_result(task)['isError']).to be(true)
    end

    it 'validates nothing for a task named by a bare id' do
      client = client_for(validate_structured_content: :strict)
      client.call_tool_as_task('sync', {})
      terminal({ 'content' => [], 'isError' => false, 'structuredContent' => { 'n' => 'wrong' } })

      expect(client.get_task_result('task-1')['structuredContent']).to eq({ 'n' => 'wrong' })
    end
  end

  describe 'what a finished legacy task leaves on the books' do
    let(:legacy_tool) do
      MCPClient::Tool.new(name: 'slow', description: 'd', schema: { 'type' => 'object' },
                          task_support: 'optional', server: stdio)
    end

    before do
      allow(stdio).to receive_messages(
        list_tools: [legacy_tool], modern?: false,
        capabilities: { 'tools' => {}, 'tasks' => { 'get' => true, 'cancel' => true,
                                                    'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(stdio).to receive(:ensure_session_ready)
    end

    # The 2025-11-25 CreateTaskResult wraps the task; every call names a task
    # of its own, as a server that hands out unique ids does.
    def legacy_server(&answer)
      created = 0
      allow(stdio).to receive(:rpc_request) do |method, params|
        next answer.call(method, params) unless method == 'tools/call'

        created += 1
        now = Time.now.utc.iso8601(3)
        { 'task' => { 'taskId' => "task-#{created}", 'status' => 'working', 'createdAt' => now,
                      'lastUpdatedAt' => now, 'ttl' => 60_000, 'pollInterval' => 1 } }
      end
    end

    def live_task_ids(client)
      (client.instance_variable_get(:@task_states) || {}).keys.map(&:last)
    end

    it 'forgets a task whose result the caller fetched' do
      client = client_for
      legacy_server { |_method, _params| { 'content' => [], 'isError' => false } }

      20.times { client.get_task_result(client.call_tool_as_task('slow', {})) }

      expect(live_task_ids(client)).to be_empty
      expect(client.instance_variable_get(:@task_lifetimes).size).to eq(20)
    end

    it 'forgets a task a cancellation ended' do
      client = client_for
      legacy_server do |_method, params|
        now = Time.now.utc.iso8601(3)
        { 'taskId' => params[:taskId], 'status' => 'cancelled', 'createdAt' => now, 'lastUpdatedAt' => now,
          'ttl' => 60_000 }
      end

      20.times { client.cancel_task(client.call_tool_as_task('slow', {})) }

      expect(live_task_ids(client)).to be_empty
    end

    it 'keeps a task a cancellation only acknowledged' do
      client = client_for
      legacy_server do |_method, params|
        now = Time.now.utc.iso8601(3)
        { 'taskId' => params[:taskId], 'status' => 'working', 'createdAt' => now, 'lastUpdatedAt' => now,
          'ttl' => 60_000 }
      end

      client.cancel_task(client.call_tool_as_task('slow', {}))

      expect(live_task_ids(client)).to eq(['task-1'])
    end

    it 'prunes the lifetimes of finished tasks once enough of them accumulate' do
      cap = MCPClient::Client::TaskLifetimes::MAX_TRACKED_TASK_LIFETIMES
      client = client_for
      legacy_server { |_method, _params| { 'content' => [], 'isError' => false } }

      (cap + 1).times { client.get_task_result(client.call_tool_as_task('slow', {})) }

      expect(client.instance_variable_get(:@task_lifetimes).size)
        .to be <= MCPClient::Client::TaskLifetimes::TRACKED_TASK_LIFETIMES_LOW_WATER + 1
      expect(live_task_ids(client)).to be_empty
    end
  end

  describe 'a task the server reports expired' do
    before do
      allow(stdio).to receive_messages(modern?: true, ping: true,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:ensure_session_ready)
    end

    def expired(message = 'Task has expired')
      allow(stdio).to receive(:rpc_request)
        .and_raise(MCPClient::Errors::ServerError.new(message, code: MCPClient::Errors::Codes::INVALID_PARAMS))
    end

    it 'reports an expired task a cancellation named as missing' do
      client = client_for
      handle = client.send(:created_task, create_result, stdio, client.send(:current_session_epoch, stdio))
      expired

      expect { client.cancel_task(handle) }.to raise_error(MCPClient::Errors::TaskNotFound)
      expect(client.instance_variable_get(:@task_states) || {}).to be_empty
    end

    it 'reports an expired task an update named as missing' do
      client = client_for
      handle = client.send(:created_task, create_result, stdio, client.send(:current_session_epoch, stdio))
      expired

      expect { client.update_task(handle, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskNotFound)
      expect(client.instance_variable_get(:@task_states) || {}).to be_empty
    end

    it 'still reads a rejection of the answers as the request failing' do
      client = client_for
      client.send(:created_task, create_result, stdio, client.send(:current_session_epoch, stdio))
      expired('inputResponses has expired entries')

      expect { client.update_task('task-1', { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError) { |e| expect(e).not_to be_a(MCPClient::Errors::TaskNotFound) }
    end
  end

  describe 'the pace a wait keeps' do
    it 'keeps a polling interval the server asked for above the hour' do
      slept = []
      allow(stdio).to receive_messages(modern?: true, ping: true,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:ensure_session_ready)
      polls = 0
      allow(stdio).to receive(:rpc_request) do
        polls += 1
        next detailed_task(status: 'working', poll_ms: 7_200_000) if polls == 1

        detailed_task(status: 'completed', 'result' => { 'content' => [], 'isError' => false })
      end
      client = client_for
      allow(client).to receive(:sleep) { |seconds| slept << seconds }

      # No caller deadline and no TTL: nothing else bounds the interval.
      expect(client.wait_for_task('task-1')).to be_completed
      expect(slept).to eq([7200.0])
    end
  end

  describe 'a write the lifetime guard refuses at the wire' do
    # A guard that passes a transport's early check and refuses its last
    # one: exactly what a creation landing in the gap between them does.
    def late_refusal
      calls = 0
      lambda do
        calls += 1
        raise MCPClient::Errors::TaskReplacedError, 'the task this handle names was replaced' if calls > 1
      end
    end

    it 'keeps the refusal a stdio transport was handed' do
      sent = []
      io = instance_double(IO, puts: nil, flush: nil, closed?: false, close: nil)
      allow(io).to receive(:puts) { |line| sent << line }
      stdio.instance_variable_set(:@stdin, io)
      allow(stdio).to receive_messages(connect: true, start_reader: nil, ensure_initialized: true)
      allow(stdio).to receive(:wait_response) { |id, **_| { 'jsonrpc' => '2.0', 'id' => id, 'result' => {} } }

      expect { stdio.guarded_writes(late_refusal) { stdio.rpc_request('tasks/update', { taskId: 't' }) } }
        .to raise_error(MCPClient::Errors::TaskReplacedError)
      expect(sent).to be_empty
    end

    it 'keeps the refusal a streamable HTTP transport was handed' do
      url = 'https://example.com/mcp'
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                              'result' => { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                            'capabilities' => { 'tools' => {} } }) }
      end
      server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                                   protocol: :modern)
      server.connect

      expect { server.guarded_writes(late_refusal) { server.rpc_request('tasks/update', { taskId: 't' }) } }
        .to raise_error(MCPClient::Errors::TaskReplacedError)
      expect(a_request(:post, url)).to have_been_made.once
    end
  end

  describe 'the outcome of a completed task' do
    it 'hands back a completed result that reports a tool error unchanged' do
      failed = { 'content' => [{ 'type' => 'text', 'text' => 'boom' }], 'isError' => true }
      task = MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => failed), detailed: true)
      client = client_for

      outcome = client.send(:task_outcome, task)

      expect(outcome).to eq(failed)
      expect(outcome['isError']).to be(true)
    end

    it 'drives a transparent call whose task completed with a tool error to that result' do
      failed = { 'content' => [{ 'type' => 'text', 'text' => 'boom' }], 'isError' => true }
      tool = MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' }, server: stdio)
      allow(stdio).to receive_messages(list_tools: [tool], modern?: true, ping: true, call_tool: create_result,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:rpc_request).and_return(detailed_task(status: 'completed', 'result' => failed))
      client = client_for

      expect(client.call_tool('sync', {})).to eq(failed)
    end
  end
end
