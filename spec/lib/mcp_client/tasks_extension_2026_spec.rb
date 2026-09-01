# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 tasks extension (io.modelcontextprotocol/tasks):
# an opt-in extension declared in the per-request clientCapabilities. Once
# declared, a server MAY answer tools/call with a CreateTaskResult
# (resultType "task", a flat Task) instead of a CallToolResult; the client
# then polls tasks/get (honouring pollIntervalMs), answers input_required
# tasks through tasks/update, and cancels through tasks/cancel. There is no
# tasks/list and no tasks/result in this revision; notifications/tasks flow
# through subscriptions/listen `taskIds`.
TASKS_EXT = 'io.modelcontextprotocol/tasks'
TASKS_META_CAPS = 'io.modelcontextprotocol/clientCapabilities'

RSpec.describe 'MCP 2026-07-28 tasks extension' do
  def discover_result(extensions: { TASKS_EXT => {} })
    caps = { 'tools' => {}, 'resources' => {} }
    caps['extensions'] = extensions if extensions
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => caps }
  end

  def task_result(status: 'working', id: 'task-1', created_at: Time.now.utc.iso8601, ttl_ms: 60_000,
                  poll_ms: 1, **extra)
    { 'resultType' => 'task', 'taskId' => id, 'status' => status, 'createdAt' => created_at,
      'lastUpdatedAt' => created_at, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def detailed_task(status:, id: 'task-1', created_at: Time.now.utc.iso8601, ttl_ms: 60_000, poll_ms: 1, **extra)
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => created_at,
      'lastUpdatedAt' => created_at, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def tool_list
    { 'result' => { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }] } }
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'Name?',
                    'requestedSchema' => { 'type' => 'object',
                                           'properties' => { 'name' => { 'type' => 'string' } } } } }
  end

  # A stdio server driven by scripted responses (no subprocess).
  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  # The params of a sent request as they go on the wire (string keys, no
  # protocol _meta).
  def wire_params(request)
    JSON.parse(request['params'].to_json).tap { |params| params.delete('_meta') }
  end

  def client_for(stdio, extensions: [TASKS_EXT], **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }],
                                   extensions: extensions, **opts)
    allow(client).to receive(:sleep)
    client
  end

  describe 'MCPClient::Task (2026-07-28 shape)' do
    it 'parses the flat modern Task and DetailedTask fields' do
      task = MCPClient::Task.from_json(detailed_task(status: 'completed', ttl_ms: 5000, poll_ms: 250,
                                                     'result' => call_result, 'statusMessage' => 'ok'))

      expect(task.task_id).to eq('task-1')
      expect(task.status).to eq('completed')
      expect(task.ttl_ms).to eq(5000)
      expect(task.ttl).to eq(5000)
      expect(task.poll_interval_ms).to eq(250)
      expect(task.poll_interval).to eq(250)
      expect(task.result).to eq(call_result)
      expect(task.error).to be_nil
      expect(task.input_requests).to be_nil
      expect(task).to be_completed
      expect(task).to be_terminal
    end

    it 'exposes inputRequests and error and predicates for the other statuses' do
      waiting = MCPClient::Task.from_json(detailed_task(status: 'input_required',
                                                        'inputRequests' => { 'k' => elicit_request }))
      failed = MCPClient::Task.from_json(detailed_task(status: 'failed',
                                                       'error' => { 'code' => -32_603, 'message' => 'boom' }))
      cancelled = MCPClient::Task.from_json(detailed_task(status: 'cancelled'))

      expect(waiting.input_requests).to eq({ 'k' => elicit_request })
      expect(waiting).to be_input_required
      expect(failed.error).to eq({ 'code' => -32_603, 'message' => 'boom' })
      expect(failed).to be_failed
      expect(cancelled).to be_cancelled
    end

    it 'serializes back with the modern field names when built from a modern task' do
      task = MCPClient::Task.from_json(task_result(ttl_ms: nil, poll_ms: 10, 'statusMessage' => 'queued'))
      hash = task.to_h

      expect(hash).to include('taskId' => 'task-1', 'status' => 'working', 'ttlMs' => nil, 'pollIntervalMs' => 10,
                              'statusMessage' => 'queued')
      expect(hash).not_to have_key('ttl')
      expect(hash).not_to have_key('pollInterval')
      expect(hash).not_to have_key('resultType')
    end

    it 'keeps the legacy field names for a legacy task' do
      task = MCPClient::Task.from_json({ 'taskId' => 't', 'status' => 'working', 'ttl' => 5, 'pollInterval' => 2 })

      expect(task.ttl_ms).to eq(5)
      expect(task.to_h).to include('ttl' => 5, 'pollInterval' => 2)
      expect(task.to_h).not_to have_key('ttlMs')
    end

    it 'reports the TTL backstop from createdAt and ttlMs' do
      expired = MCPClient::Task.from_json(task_result(created_at: '2000-01-01T00:00:00Z', ttl_ms: 1000))
      unlimited = MCPClient::Task.from_json(task_result(created_at: '2000-01-01T00:00:00Z', ttl_ms: nil))
      fresh = MCPClient::Task.from_json(task_result(created_at: Time.now.utc.iso8601, ttl_ms: 60_000))

      expect(expired).to be_ttl_elapsed
      expect(unlimited).not_to be_ttl_elapsed
      expect(fresh).not_to be_ttl_elapsed
    end
  end

  describe 'result handling on a transport' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'accepts a CreateTaskResult for tools/call once the extension is declared and advertises it' do
      server.declare_extension(TASKS_EXT)
      sent = script_stdio(server, [{ 'result' => discover_result }, { 'result' => task_result }])

      result = server.call_tool('slow', {})

      expect(result['resultType']).to eq('task')
      expect(result['taskId']).to eq('task-1')
      call = sent.find { |r| r['method'] == 'tools/call' }
      expect(call.dig('params', '_meta', TASKS_META_CAPS, 'extensions')).to eq({ TASKS_EXT => {} })
    end

    it 'rejects a CreateTaskResult when the extension was not declared' do
      script_stdio(server, [{ 'result' => discover_result }, { 'result' => task_result }])

      expect { server.call_tool('slow', {}) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /resultType "task"/)
    end

    it 'rejects a CreateTaskResult on a request type that does not support tasks' do
      server.declare_extension(TASKS_EXT)
      script_stdio(server, [{ 'result' => discover_result }, { 'result' => task_result }])

      expect { server.read_resource('file:///x') }
        .to raise_error(MCPClient::Errors::InvalidResultError, %r{task.*tools/call})
    end

    it 'rejects a CreateTaskResult from a legacy server' do
      legacy = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, protocol: :legacy)
      legacy.declare_extension(TASKS_EXT)
      script_stdio(legacy, [{ 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                            'serverInfo' => { 'name' => 's', 'version' => '1' } } },
                            { 'result' => task_result }])

      expect { legacy.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError)
    end

    it 'rejects a tasks/get answer whose resultType is not complete' do
      server.declare_extension(TASKS_EXT)
      script_stdio(server, [{ 'result' => discover_result }, { 'result' => task_result }])

      expect { server.rpc_request('tasks/get', { 'taskId' => 'task-1' }) }
        .to raise_error(MCPClient::Errors::InvalidResultError)
    end
  end

  describe 'through MCPClient::Client' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'declares the extension on every server through the extensions option' do
      client = client_for(stdio, extensions: { TASKS_EXT => {} })
      sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list])

      client.list_tools

      list = sent.find { |r| r['method'] == 'tools/list' }
      expect(list.dig('params', '_meta', TASKS_META_CAPS, 'extensions')).to eq({ TASKS_EXT => {} })
      expect(client).to be_tasks_extension
    end

    it 'does not declare the extension unless asked' do
      client = client_for(stdio, extensions: nil)
      sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list])

      client.list_tools

      list = sent.find { |r| r['method'] == 'tools/list' }
      expect(list.dig('params', '_meta', TASKS_META_CAPS)).not_to have_key('extensions')
      expect(client).not_to be_tasks_extension
    end

    it 'drives a task returned by tools/call to completion and returns the final result' do
      client = client_for(stdio)
      sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                                  { 'result' => task_result(poll_ms: 250) },
                                  { 'result' => detailed_task(status: 'working', poll_ms: 500) },
                                  { 'result' => detailed_task(status: 'completed', 'result' => call_result('42')) }])

      result = client.call_tool('slow', {})

      expect(result['content'].first['text']).to eq('42')
      gets = sent.select { |r| r['method'] == 'tasks/get' }
      expect(gets.size).to eq(2)
      expect(gets.map { |r| wire_params(r)['taskId'] }).to all(eq('task-1'))
      expect(client).to have_received(:sleep).with(0.25).ordered
      expect(client).to have_received(:sleep).with(0.5).ordered
    end

    it 'raises the JSON-RPC error of a failed task' do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                           { 'result' => detailed_task(status: 'failed', 'statusMessage' => 'rate limited',
                                                       'error' => { 'code' => -32_603,
                                                                    'message' => 'API rate limit exceeded' }) }])

      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::ServerError) { |e|
        expect(e.message).to include('API rate limit exceeded')
        expect(e.code).to eq(-32_603)
      }
    end

    it 'raises TaskError when the task ends cancelled' do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                           { 'result' => detailed_task(status: 'cancelled') }])

      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::TaskError, /cancelled/)
    end

    it 'answers input_required tasks through tasks/update without repeating answered keys' do
      seen = []
      client = client_for(stdio, elicitation_handler: lambda { |message, _schema|
        seen << message
        { action: 'accept', content: { 'name' => 'octocat' } }
      })
      sent = script_stdio(stdio, [
                            { 'result' => discover_result }, tool_list, { 'result' => task_result },
                            { 'result' => detailed_task(status: 'input_required',
                                                        'inputRequests' => { 'k1' => elicit_request }) },
                            { 'result' => {} },
                            { 'result' => detailed_task(status: 'input_required',
                                                        'inputRequests' => { 'k1' => elicit_request,
                                                                             'k2' => elicit_request }) },
                            { 'result' => {} },
                            { 'result' => detailed_task(status: 'completed', 'result' => call_result) }
                          ])

      result = client.call_tool('slow', {})

      expect(result['isError']).to be(false)
      updates = sent.select { |r| r['method'] == 'tasks/update' }
      expect(updates.size).to eq(2)
      expect(wire_params(updates[0])['taskId']).to eq('task-1')
      expect(wire_params(updates[0])['inputResponses'].keys).to eq(['k1'])
      expect(wire_params(updates[0])['inputResponses']['k1'])
        .to eq({ 'action' => 'accept', 'content' => { 'name' => 'octocat' } })
      expect(wire_params(updates[1])['inputResponses'].keys).to eq(['k2'])
      expect(seen.size).to eq(2)
    end

    it 'surfaces an unfulfillable task input request as InputRequiredError' do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                           { 'result' => detailed_task(status: 'input_required',
                                                       'inputRequests' => { 'k1' => elicit_request }) }])

      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InputRequiredError)
    end

    it 'gives up on a task whose TTL elapsed without a terminal status' do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                           { 'result' => task_result(created_at: '2000-01-01T00:00:00Z', ttl_ms: 1000) },
                           { 'result' => detailed_task(status: 'working', created_at: '2000-01-01T00:00:00Z',
                                                       ttl_ms: 1000) }])

      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    end

    it 'bounds the wait with an explicit timeout' do
      client = client_for(stdio)
      responses = [{ 'result' => discover_result }, tool_list, { 'result' => task_result }]
      20.times { responses << { 'result' => detailed_task(status: 'working') } }
      script_stdio(stdio, responses)
      task = client.call_tool_as_task('slow', {})

      expect { client.wait_for_task(task, timeout: 0) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    end

    it 'returns the task handle from call_tool_as_task and exposes the task lifecycle' do
      client = client_for(stdio)
      sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                  { 'result' => detailed_task(status: 'working', 'statusMessage' => 'half') },
                                  { 'result' => {} },
                                  { 'result' => {} },
                                  { 'result' => detailed_task(status: 'completed', 'result' => call_result('ok')) }])

      task = client.call_tool_as_task('slow', {})
      expect(task).to be_a(MCPClient::Task)
      expect(task.task_id).to eq('task-1')
      expect(task).to be_working
      expect(task.server).to eq(stdio)

      current = client.get_task(task)
      expect(current.status_message).to eq('half')

      client.update_task(task, { 'k1' => { 'action' => 'decline' } })
      update = sent.find { |r| r['method'] == 'tasks/update' }
      expect(wire_params(update))
        .to eq({ 'taskId' => 'task-1', 'inputResponses' => { 'k1' => { 'action' => 'decline' } } })

      cancelled = client.cancel_task(task)
      expect(cancelled).to be_a(MCPClient::Task)
      expect(cancelled.task_id).to eq('task-1')
      expect(wire_params(sent.find { |r| r['method'] == 'tasks/cancel' })).to eq({ 'taskId' => 'task-1' })

      expect(client.get_task_result(task)['content'].first['text']).to eq('ok')
    end

    it 'returns a completed local task when the server answered tools/call synchronously' do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => call_result('sync') }])

      task = client.call_tool_as_task('slow', {})

      expect(task).to be_completed
      expect(task.task_id).to be_nil
      expect(task.result['content'].first['text']).to eq('sync')
      expect(client.wait_for_task(task)).to equal(task)
    end

    it 'refuses list_tasks on a 2026-07-28 server' do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result }])

      expect { client.list_tasks }.to raise_error(MCPClient::Errors::TaskError, %r{tasks/list})
    end

    it 'maps -32602 on tasks/get to TaskNotFound and lets -32021 propagate' do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result },
                           { 'error' => { 'code' => -32_602, 'message' => 'Failed to retrieve task' } },
                           { 'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                                          'data' => { 'requiredCapabilities' =>
                                                      { 'extensions' => { TASKS_EXT => {} } } } } }])

      expect { client.get_task('nope') }.to raise_error(MCPClient::Errors::TaskNotFound)
      expect { client.get_task('nope') }.to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError)
    end

    it 'refuses task operations when the server did not negotiate the extension' do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result(extensions: nil) }])

      expect { client.cancel_task('task-1') }.to raise_error(MCPClient::Errors::CapabilityError, /tasks/)
    end

    it 'refuses task operations when the client did not declare the extension' do
      client = client_for(stdio, extensions: nil)
      script_stdio(stdio, [{ 'result' => discover_result }])

      expect { client.get_task('task-1') }.to raise_error(MCPClient::Errors::CapabilityError, /extension/)
    end

    it 'requires the extension before listening for task notifications' do
      client = client_for(stdio, extensions: nil)
      script_stdio(stdio, [{ 'result' => discover_result }])

      expect { client.listen(notifications: { task_ids: ['task-1'] }) }
        .to raise_error(MCPClient::Errors::CapabilityError, /extension/)
    end

    it 'delivers notifications/tasks to listeners and logs the status' do
      output = StringIO.new
      client = client_for(stdio, logger: Logger.new(output))
      client.logger.level = Logger::INFO
      received = []
      client.on_notification { |_srv, method, params| received << [method, params['status']] }

      stdio.instance_variable_get(:@notification_callback)
           .call('notifications/tasks', detailed_task(status: 'completed', 'result' => call_result).tap do |t|
             t.delete('resultType')
           end)

      expect(received).to eq([['notifications/tasks', 'completed']])
      expect(output.string).to include('Task task-1 status: completed')
    end
  end

  describe 'over Streamable HTTP' do
    let(:url) { 'http://tasks.example/mcp' }

    it 'routes tasks/get, tasks/update and tasks/cancel with Mcp-Name set to the task id' do
      seen = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        seen << [body['method'], request.headers['Mcp-Name'], request.headers['Mcp-Method']]
        result = case body['method']
                 when 'server/discover' then discover_result
                 when 'tools/list' then { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }] }
                 when 'tools/call' then task_result
                 when 'tasks/get' then detailed_task(status: 'completed', 'result' => call_result('http'))
                 else { 'resultType' => 'complete' }
                 end
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: { jsonrpc: '2.0', id: body['id'], result: result }.to_json }
      end
      http = MCPClient::ServerStreamableHTTP.new(base_url: url)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(http)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', url: url }],
                                     extensions: [TASKS_EXT])
      allow(client).to receive(:sleep)

      result = client.call_tool('slow', {})
      client.cancel_task('task-1')

      expect(result['content'].first['text']).to eq('http')
      expect(seen).to include(['tasks/get', 'task-1', 'tasks/get'], ['tasks/cancel', 'task-1', 'tasks/cancel'])
    end
  end
end
