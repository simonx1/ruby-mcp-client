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
      # The first poll goes out at once; the server's pollIntervalMs paces
      # the polls that follow an observed non-terminal status.
      expect(client).to have_received(:sleep).with(0.5).once
      expect(client).not_to have_received(:sleep).with(0.25)
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

      # Routed the way the transport routes it: the client's own processing
      # (which logs the status) and the host's listeners hang off two
      # different hooks now, and this drives both.
      stdio.send(:route_notification, 'notifications/tasks',
                 detailed_task(status: 'completed', 'result' => call_result).tap { |t| t.delete('resultType') })

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

RSpec.describe 'MCP 2026-07-28 tasks extension — round 2' do
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

  def wire_params(request)
    JSON.parse(request['params'].to_json).tap { |params| params.delete('_meta') }
  end

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(stdio, extensions: [TASKS_EXT], **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }],
                                   extensions: extensions, **opts)
    allow(client).to receive(:sleep)
    client
  end

  it 'waits for a task by id on a client that has not talked to the server yet' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result('late')) }])

    task = client.wait_for_task('task-1')

    expect(task).to be_completed
    expect(task.result['content'].first['text']).to eq('late')
  end

  it 'never sleeps past the remaining timeout or TTL' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                         { 'result' => task_result(poll_ms: 60_000) },
                         { 'result' => detailed_task(status: 'working', poll_ms: 60_000) }])

    task = client.call_tool_as_task('slow', {})
    allow(client).to receive(:sleep) { |seconds| Kernel.sleep(seconds) }
    expect { client.wait_for_task(task, timeout: 0.2) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(client).to have_received(:sleep).with(a_value <= 0.2).at_least(:once)
    expect(client).not_to have_received(:sleep).with(a_value > 0.2)

    ttl_bound = MCPClient::Task.from_json(task_result(poll_ms: 60_000, ttl_ms: 500), server: stdio)
    expect(client.send(:task_poll_delay, ttl_bound, nil)).to be_between(0.0, 0.5)
  end

  it 'honours a long pollIntervalMs without capping it' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                         { 'result' => task_result(poll_ms: 180_000, ttl_ms: nil) },
                         { 'result' => detailed_task(status: 'working', poll_ms: 180_000, ttl_ms: nil) },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    client.call_tool('slow', {})

    expect(client).to have_received(:sleep).with(180.0)
  end

  it 'does not busy-loop on pollIntervalMs 0' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                         { 'result' => task_result(poll_ms: 0, ttl_ms: nil) },
                         { 'result' => detailed_task(status: 'working', poll_ms: 0, ttl_ms: nil) },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    client.call_tool('slow', {})

    expect(client).to have_received(:sleep).with(a_value >= MCPClient::Client::TaskSupport::MIN_TASK_POLL_INTERVAL)
  end

  it 'fetches the task when the creation seed claims a terminal status without its payload' do
    client = client_for(stdio)
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                                { 'result' => task_result(status: 'completed') },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result('fetched')) }])

    expect(client.call_tool('slow', {})['content'].first['text']).to eq('fetched')
    expect(sent.count { |r| r['method'] == 'tasks/get' }).to eq(1)
  end

  it 'fetches the task when the seed says failed or input_required without details' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                         { 'result' => task_result(status: 'failed') },
                         { 'result' => detailed_task(status: 'failed', 'error' => { 'code' => -32_603,
                                                                                    'message' => 'later' }) }])
    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::ServerError, /later/)

    other = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    client = client_for(other)
    script_stdio(other, [{ 'result' => discover_result }, tool_list,
                         { 'result' => task_result(status: 'input_required') },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result('ok')) }])
    expect(client.call_tool('slow', {})['content'].first['text']).to eq('ok')
  end

  it 'resolves a task returned to a streaming tool call' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result('streamed')) }])

    chunks = client.call_tool_streaming('slow', {}).to_a

    expect(chunks.size).to eq(1)
    expect(chunks.first['content'].first['text']).to eq('streamed')
  end

  it 'refuses task notifications when the server did not negotiate the extension' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result(extensions: nil) }])

    expect { client.listen(notifications: { task_ids: ['task-1'] }) }
      .to raise_error(MCPClient::Errors::CapabilityError, /tasks/)
  end

  it 'wraps creation failures on a 2026-07-28 server as TaskError' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                         { 'error' => { 'code' => -32_603, 'message' => 'cannot start' } }])

    expect { client.call_tool_as_task('slow', {}) }.to raise_error(MCPClient::Errors::TaskError, /cannot start/)
  end

  it 'maps -32602 on tasks/cancel and tasks/update to TaskNotFound' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'error' => { 'code' => -32_602, 'message' => 'No such task' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'No such task' } }])

    expect { client.cancel_task('gone') }.to raise_error(MCPClient::Errors::TaskNotFound)
    expect { client.update_task('gone', {}) }.to raise_error(MCPClient::Errors::TaskNotFound)
  end

  it 'keeps locally completed tasks distinct' do
    first = MCPClient::Task.completed_locally(call_result('a'))
    second = MCPClient::Task.completed_locally(call_result('b'))

    expect(first).not_to eq(second)
    expect(Set.new([first, second]).size).to eq(2)
    expect(first).to eq(first)
  end

  it 'answers sampling and roots input requests of a task through the client handlers' do
    sampling = { 'method' => 'sampling/createMessage',
                 'params' => { 'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'hi' } }],
                               'maxTokens' => 10 } }
    roots = { 'method' => 'roots/list', 'params' => {} }
    client = client_for(stdio, roots: [{ uri: 'file:///work', name: 'work' }], sampling_handler: lambda { |_params|
      { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'yo' }, 'model' => 'm' }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 's' => sampling, 'r' => roots }) },
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    client.call_tool('slow', {})

    update = wire_params(sent.find { |r| r['method'] == 'tasks/update' })
    expect(update['inputResponses']['s']['content']['text']).to eq('yo')
    expect(update['inputResponses']['r']['roots'].first['uri']).to eq('file:///work')
  end

  it 'routes tasks/update with Mcp-Name over Streamable HTTP' do
    url = 'http://tasks.example/mcp'
    seen = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      seen << [body['method'], request.headers['Mcp-Name']]
      result = body['method'] == 'server/discover' ? discover_result : { 'resultType' => 'complete' }
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { jsonrpc: '2.0', id: body['id'], result: result }.to_json }
    end
    http = MCPClient::ServerStreamableHTTP.new(base_url: url)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(http)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', url: url }],
                                   extensions: [TASKS_EXT])

    client.update_task('task-9', { 'k' => { 'action' => 'decline' } })

    expect(seen).to include(['tasks/update', 'task-9'])
  end
end

RSpec.describe 'MCP 2026-07-28 tasks extension — round 3' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def detailed_task(status:, id: 'task-1', **extra)
    now = Time.now.utc.iso8601
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => 60_000, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def call_result(text)
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

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

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
  let(:client) do
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
    allow(client).to receive(:sleep)
    client
  end

  it 'never retries tasks/update' do
    expect(MCPClient::JsonRpcCommon::NON_IDEMPOTENT_METHODS).to include('tasks/update')
  end

  it 'checks the deadline before polling and bounds the poll by the remaining timeout' do
    script_stdio(stdio, [{ 'result' => discover_result }])
    expect { client.wait_for_task('task-1', timeout: 0) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)

    allow(stdio).to receive(:rpc_request).and_call_original
    allow(stdio).to receive(:rpc_request).with('tasks/get', anything, hash_including(timeout: a_value <= 0.5))
                                         .and_return(detailed_task(status: 'completed', 'result' => call_result('ok')))
    expect(client.wait_for_task('task-1', timeout: 0.5).result['content'].first['text']).to eq('ok')
  end

  it 'ignores a handle from another server when the server is overridden' do
    other = instance_double(MCPClient::ServerBase, name: 'other')
    handle = MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => call_result('from A')),
                                       server: other, detailed: true)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result('from B')) },
                         { 'result' => {} }])

    expect(client.wait_for_task(handle, server: 0).result['content'].first['text']).to eq('from B')
    expect(client.cancel_task(handle, server: 0).server).to equal(stdio)
  end

  it 'rejects a completed task that carries no result' do
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'result' => detailed_task(status: 'completed') }])

    expect { client.wait_for_task('task-1') }.to raise_error(MCPClient::Errors::InvalidResultError, /result/)
  end
end

RSpec.describe 'MCP 2026-07-28 tasks extension — round 4' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(status: 'working', id: 'task-1', poll_ms: 1, ttl_ms: 60_000, created_at: Time.now.utc.iso8601,
                  **extra)
    { 'resultType' => 'task', 'taskId' => id, 'status' => status, 'createdAt' => created_at,
      'lastUpdatedAt' => created_at, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def detailed_task(status:, id: 'task-1', poll_ms: 1, **extra)
    now = Time.now.utc.iso8601
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => 60_000, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def tool_list(name = 'slow')
    { 'result' => { 'tools' => [{ 'name' => name, 'inputSchema' => { 'type' => 'object' } }] } }
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
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  let(:output) { StringIO.new }
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    logger = Logger.new(output)
    logger.level = Logger::INFO
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   logger: logger, **opts)
    allow(client).to receive(:sleep)
    client
  end

  it 'polls immediately after creation instead of trusting the seed for TTL or pacing' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                         { 'result' => task_result(poll_ms: 180_000, ttl_ms: 1000,
                                                   created_at: '2000-01-01T00:00:00Z') },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result('quick')) }])

    expect(client.call_tool('slow', {})['content'].first['text']).to eq('quick')
    expect(client).not_to have_received(:sleep)
  end

  it 'confirms a cancelled seed with tasks/get' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(status: 'cancelled') },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result('finished')) }])

    expect(client.call_tool('slow', {})['content'].first['text']).to eq('finished')
  end

  it 'rejects a CreateTaskResult without a taskId' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                         { 'result' => task_result.tap { |t| t.delete('taskId') } }])

    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /taskId/)
  end

  it 'refuses lifecycle requests for a locally completed task' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => call_result('sync') }])
    local = client.call_tool_as_task('slow', {})

    expect { client.get_task(local) }.to raise_error(MCPClient::Errors::TaskError, /locally/)
    expect { client.cancel_task(local) }.to raise_error(MCPClient::Errors::TaskError, /locally/)
    expect { client.update_task(local, {}) }.to raise_error(MCPClient::Errors::TaskError, /locally/)
  end

  it 'maps -32602 to TaskNotFound only when it is about the task, not about the params' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'error' => { 'code' => -32_602,
                                        'message' => 'Invalid params: inputResponses must be an object' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'Unknown task' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'Invalid params' } }])

    expect { client.update_task('live', { 'k' => 'x' }) }.to raise_error(MCPClient::Errors::TaskError)
    expect { client.update_task('gone', {}) }.to raise_error(MCPClient::Errors::TaskNotFound)
    expect { client.get_task('gone') }.to raise_error(MCPClient::Errors::TaskNotFound)
  end

  it 'surfaces an initialization failure instead of a protocol-era error' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping).and_raise(MCPClient::Errors::ConnectionError, 'server down')

    expect { client.wait_for_task('task-1') }.to raise_error(MCPClient::Errors::ConnectionError, /server down/)
    expect { client.update_task('task-1', {}) }.to raise_error(MCPClient::Errors::ConnectionError, /server down/)
  end

  it 'sanitizes peer-controlled tool names and task ids in logs and errors' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list("slow\nWARN forged"),
                         { 'result' => task_result(id: "task\nWARN forged-id") },
                         { 'result' => detailed_task(status: 'cancelled', id: "task\nWARN forged-id") }])

    expect { client.call_tool("slow\nWARN forged", {}) }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e.message).not_to include("\nWARN forged")
    }
    expect(output.string).not_to include("\nWARN forged")
  end

  it 'bounds the number of input rounds a task may demand' do
    client = client_for(stdio, elicitation_handler: ->(_m, _s) { { action: 'accept', content: { 'n' => 'x' } } })
    responses = [{ 'result' => discover_result }, tool_list, { 'result' => task_result }]
    30.times do |i|
      responses << { 'result' => detailed_task(status: 'input_required',
                                               'inputRequests' => { "k#{i}" => elicit_request }) }
      responses << { 'result' => {} }
    end
    script_stdio(stdio, responses)

    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /round/)
  end

  it 'remembers answered input request keys across waits for the same task' do
    client = client_for(stdio, elicitation_handler: ->(_m, _s) { { action: 'accept', content: { 'n' => 'x' } } })
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task, timeout: 0) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(client.wait_for_task(task)).to be_completed
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(1)
  end
end

RSpec.describe 'MCP 2026-07-28 tasks extension — round 5' do
  def discover_result(extensions: { TASKS_EXT => {} })
    caps = { 'tools' => {} }
    caps['extensions'] = extensions if extensions
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => caps }
  end

  def task_result(id: 'task-1')
    now = Time.now.utc.iso8601
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => 60_000, 'pollIntervalMs' => 1 }
  end

  def detailed_task(status:, id: 'task-1', **extra)
    now = Time.now.utc.iso8601
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => 60_000, 'pollIntervalMs' => 1 }.merge(extra)
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
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

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

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server, extensions: [TASKS_EXT], **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: extensions,
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  it 'rejects a tasks/get answer for another task or without a taskId' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'result' => detailed_task(status: 'completed', id: 'task-2', 'result' => call_result) },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result).tap do |t|
                           t.delete('taskId')
                         end }])

    expect { client.wait_for_task('task-1') }.to raise_error(MCPClient::Errors::InvalidResultError, /taskId/)
    expect { client.wait_for_task('task-1') }.to raise_error(MCPClient::Errors::InvalidResultError, /taskId/)
  end

  it 'stops before sending an input round beyond the limit' do
    client = client_for(stdio, elicitation_handler: ->(_m, _s) { { action: 'accept', content: { 'n' => 'x' } } })
    responses = [{ 'result' => discover_result }, tool_list, { 'result' => task_result }]
    30.times do |i|
      responses << { 'result' => detailed_task(status: 'input_required',
                                               'inputRequests' => { "k#{i}" => elicit_request }) }
      responses << { 'result' => {} }
    end
    sent = script_stdio(stdio, responses)

    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InputRequiredError, /round/)
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(MCPClient::Client::TaskSupport::MAX_TASK_INPUT_ROUNDS)
  end

  it 'never enlarges the remaining timeout of a poll' do
    # A transport whose own read timeout — like MAX_TASK_REQUEST_TIMEOUT —
    # is far above the caller's budget: the poll must ask for what is left
    # of the budget and nothing wider. The wait's clock is frozen so the
    # assertion is about that arithmetic, not about how much wall clock a
    # loaded suite has taken by the time the poll goes out.
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 30)
    client = client_for(server)
    script_stdio(server, [{ 'result' => discover_result }])
    allow(client).to receive(:monotonic_time).and_return(0.0)
    allow(server).to receive(:rpc_request).and_call_original
    allow(server).to receive(:rpc_request).with('tasks/get', anything, hash_including(timeout: a_value <= 2.0))
                                          .and_return(detailed_task(status: 'completed', 'result' => call_result))

    expect(client.wait_for_task('task-1', timeout: 2.0)).to be_completed
  end

  it 'reports the removal of tasks/list before asking for the extension' do
    client = client_for(stdio, extensions: nil)
    script_stdio(stdio, [{ 'result' => discover_result(extensions: nil) }])

    expect { client.list_tasks }.to raise_error(MCPClient::Errors::TaskError, %r{tasks/list})
  end
end

RSpec.describe 'MCP 2026-07-28 tasks extension — round 6' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(id: 'task-1')
    now = Time.now.utc.iso8601
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => 60_000, 'pollIntervalMs' => 1 }
  end

  def detailed_task(status:, id: 'task-1', created_at: Time.now.utc.iso8601, ttl_ms: 60_000, **extra)
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => created_at,
      'lastUpdatedAt' => created_at, 'ttlMs' => ttl_ms, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def tool_list(name = 'slow')
    { 'result' => { 'tools' => [{ 'name' => name, 'inputSchema' => { 'type' => 'object' } }] } }
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
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  it 'keeps polling after a tasks/get request timeout' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'tasks/get timed out' },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result('late')) }])

    expect(client.call_tool('slow', {})['content'].first['text']).to eq('late')
  end

  it 'applies the TTL backstop before answering input requests' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: {} }
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'input_required', created_at: '2000-01-01T00:00:00Z',
                                                     ttl_ms: 1000, 'inputRequests' => { 'k1' => elicit_request }) }])

    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    expect(handled).to eq(0)
  end

  it 'remembers an answered key even when the update acknowledgement is lost' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'update timed out' },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})

    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(1)
    # The lost update is delivered again with the next poll of the same
    # wait, without asking the handler a second time.
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(2)
  end

  it 'sanitizes task ids and tool names in transport and creation errors' do
    client = client_for(stdio)
    forged = { 'result' => { 'tools' => [{ 'name' => "slow\nWARN forged", 'inputSchema' => { 'type' => 'object' } }],
                             'ttlMs' => 60_000 } }
    script_stdio(stdio, [{ 'result' => discover_result }, forged])
    client.list_tools
    allow(stdio).to receive(:rpc_request).and_call_original
    %w[tasks/get tasks/update tools/call].each do |method|
      allow(stdio).to receive(:rpc_request).with(method, any_args)
                                           .and_raise(MCPClient::Errors::TransportError, "broken pipe\nWARN forged")
    end

    expect { client.get_task("task\nWARN forged") }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e.message).not_to include("\nWARN forged")
    }
    expect { client.update_task("task\nWARN forged", {}) }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e.message).not_to include("\nWARN forged")
    }
    expect { client.call_tool_as_task("slow\nWARN forged", {}) }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e.message).not_to include("\nWARN forged")
    }
  end

  it 'surfaces an initialization failure from get_task_result instead of sending tasks/result' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping).and_raise(MCPClient::Errors::ConnectionError, 'server down')
    allow(stdio).to receive(:rpc_request).and_raise('tasks/result must not be sent')

    expect { client.get_task_result('task-1') }.to raise_error(MCPClient::Errors::ConnectionError, /server down/)
  end

  it 'guards the answered-key registry with a mutex' do
    client = client_for(stdio)
    expect(client.send(:answered_keys_mutex)).to be_a(Mutex)
  end
end
