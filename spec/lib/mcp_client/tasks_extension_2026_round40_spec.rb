# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, fortieth review round:
#
# - A handle that names the same task still names the tool it is running: a
#   refreshed handle, and the one a wait hands back, validate what the task
#   delivers exactly as the creation handle does.
# - Ending a connection is not ending a session: the answers of a task that
#   outlives a cleanup outlive it too, so the host is not asked twice.
# - A rejected update gives back only what it still owns, decided and applied
#   in one step.
# - A legacy task the server reports gone leaves nothing on the books.
# - The pace a server asks for is kept, whatever its size, as long as the
#   clock can represent it.
#
# And the wire this revision prescribes, which the rounds above stubbed past:
# every lifecycle request declares the extension, a task is created by a plain
# tools/call and read with tasks/get, it is cancelled with tasks/cancel and
# never with notifications/cancelled, -32021 stays typed, the 2025-only
# methods refuse a 2025 server, an inputRequests entry is refused wherever a
# standalone request would be, and a taskIds listen delivers notifications/tasks.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 40' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def create_result(id: 'task-1', poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def detailed_task(status:, id: 'task-1', poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def legacy_task(id: 'task-1', status: 'working')
    now = Time.now.utc.iso8601(3)
    { 'taskId' => id, 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttl' => 60_000, 'pollInterval' => 1 }
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def structured_result(value)
    { 'content' => [], 'isError' => false, 'structuredContent' => { 'n' => value } }
  end

  def structured_tool(server = stdio, task_support: nil)
    MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                        output_schema: { 'type' => 'object', 'required' => ['n'],
                                         'properties' => { 'n' => { 'type' => 'integer' } } },
                        task_support: task_support, server: server)
  end

  def accept(value = 'x')
    { 'action' => 'accept', 'content' => { 'n' => value } }
  end

  def elicit_request(message = 'Name?')
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => message,
                    'requestedSchema' => { 'type' => 'object',
                                           'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def invalid_params(message)
    MCPClient::Errors::ServerError.new(message, code: MCPClient::Errors::Codes::INVALID_PARAMS)
  end

  def client_for(server = stdio, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server = stdio)
    allow(server).to receive_messages(modern?: true, ping: true,
                                      capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:ensure_session_ready)
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def tool_list
    { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }] }
  end

  # A scripted stdio session that records both what it sends as a request and
  # what it writes as a notification, so a request that never goes out and a
  # notification that never goes out are both observable.
  def script_stdio(server, responses)
    sent = []
    written = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', flush: nil, closed?: true, close: nil).tap do |pipe|
      allow(pipe).to receive(:puts) { |written_line| written << JSON.parse(written_line) }
    end)
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      responder.merge('jsonrpc' => '2.0', 'id' => id)
    end
    [sent, written]
  end

  # The params of a sent request as they go on the wire (string keys, no
  # protocol _meta).
  def wire_params(request)
    JSON.parse(request['params'].to_json).tap { |params| params.delete('_meta') }
  end

  def caps_meta_key
    'io.modelcontextprotocol/clientCapabilities'
  end

  def methods_of(sent)
    sent.map { |request| request['method'] }
  end

  describe 'the definition a handle of a running task carries' do
    before do
      stdio.singleton_class.include(MCPClient::CalledToolDefinition)
      negotiated
      allow(stdio).to receive(:list_tools).and_return([structured_tool])
      allow(stdio).to receive(:call_tool) do
        stdio.send(:note_called_tool_definition, 'sync', structured_tool)
        create_result
      end
    end

    def answering(*bodies)
      queue = bodies.dup
      allow(stdio).to receive(:rpc_request) do |method, _params, **_kw|
        raise "unexpected #{method}" unless method == 'tasks/get'

        queue.size > 1 ? queue.shift : queue.first
      end
    end

    it 'validates what the task delivered through a handle tasks/get refreshed' do
      client = client_for(validate_structured_content: :strict)
      task = client.call_tool_as_task('sync', {})
      answering(detailed_task(status: 'working'))
      refreshed = client.get_task(task)
      answering(detailed_task(status: 'completed', 'result' => structured_result('wrong')))

      expect { client.get_task_result(refreshed) }
        .to raise_error(MCPClient::Errors::ValidationError, /output schema/)
    end

    it 'validates what the task delivered through the handle the wait handed back' do
      client = client_for(validate_structured_content: :strict)
      task = client.call_tool_as_task('sync', {})
      answering(detailed_task(status: 'completed', 'result' => structured_result('wrong')))
      final = client.wait_for_task(task)

      expect { client.get_task_result(final) }
        .to raise_error(MCPClient::Errors::ValidationError, /output schema/)
    end

    it 'still returns a result the tool allows through a refreshed handle' do
      client = client_for(validate_structured_content: :strict)
      task = client.call_tool_as_task('sync', {})
      answering(detailed_task(status: 'working'))
      refreshed = client.get_task(task)
      answering(detailed_task(status: 'completed', 'result' => structured_result(1)))

      expect(client.get_task_result(refreshed)['structuredContent']).to eq({ 'n' => 1 })
    end
  end

  describe 'the definition a refreshed legacy handle carries' do
    before do
      allow(stdio).to receive_messages(
        modern?: false, list_tools: [structured_tool(task_support: 'optional')],
        capabilities: { 'tools' => {}, 'tasks' => { 'get' => true, 'result' => true,
                                                    'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(stdio).to receive(:ensure_session_ready)
    end

    def legacy_server(result)
      allow(stdio).to receive(:rpc_request) do |method, _params, **_kw|
        case method
        when 'tools/call' then { 'task' => legacy_task }
        when 'tasks/get' then legacy_task
        when 'tasks/result' then result
        else raise "unexpected #{method}"
        end
      end
    end

    it 'validates a legacy result through a handle tasks/get refreshed' do
      client = client_for(validate_structured_content: :strict)
      legacy_server(structured_result('wrong'))
      refreshed = client.get_task(client.call_tool_as_task('sync', {}))

      expect { client.get_task_result(refreshed) }
        .to raise_error(MCPClient::Errors::ValidationError, /output schema/)
    end

    it 'validates a legacy result through the creation handle' do
      client = client_for(validate_structured_content: :strict)
      legacy_server(structured_result('wrong'))
      task = client.call_tool_as_task('sync', {})

      expect { client.get_task_result(task) }
        .to raise_error(MCPClient::Errors::ValidationError, /output schema/)
    end
  end

  describe 'what a legacy tasks/result that found nothing leaves on the books' do
    before do
      allow(stdio).to receive_messages(
        modern?: false, list_tools: [structured_tool(task_support: 'optional')],
        capabilities: { 'tools' => {}, 'tasks' => { 'get' => true, 'result' => true,
                                                    'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(stdio).to receive(:ensure_session_ready)
    end

    # Every creation names a task of its own, as a server handing out unique
    # ids does; the result request fails the way the scenario asks for.
    def legacy_server(&failure)
      created = 0
      allow(stdio).to receive(:rpc_request) do |method, _params, **_kw|
        next { 'task' => legacy_task(id: "task-#{created += 1}") } if method == 'tools/call'
        raise "unexpected #{method}" unless method == 'tasks/result'

        failure.call
      end
    end

    def live_task_ids(client)
      (client.instance_variable_get(:@task_states) || {}).keys.map(&:last)
    end

    it 'forgets a task the server reports expired, and only that task' do
      client = client_for
      legacy_server { raise invalid_params('Task has expired') }
      running = client.call_tool_as_task('sync', {})

      20.times do
        expect { client.get_task_result(client.call_tool_as_task('sync', {})) }
          .to raise_error(MCPClient::Errors::TaskNotFound)
      end

      expect(live_task_ids(client)).to eq([running.task_id])
    end

    it 'keeps the books of a task whose result merely failed' do
      client = client_for
      legacy_server do
        raise MCPClient::Errors::ServerError.new('Upstream store unreachable',
                                                 code: MCPClient::Errors::Codes::INTERNAL_ERROR)
      end
      task = client.call_tool_as_task('sync', {})
      client.send(:remember_answered_keys, stdio, task.task_id, ['k1'])

      expect { client.get_task_result(task) }.to raise_error(MCPClient::Errors::TaskError, /store unreachable/)
      expect(client.send(:answered_task_keys, stdio, task.task_id)).to include('k1')
    end
  end

  describe 'a rejection settling while a newer answer is queued' do
    it 'leaves the newer answer answered and deliverable' do
      client = client_for
      negotiated
      state = client.send(:task_state, stdio, 'task-1')
      newer = accept('new')
      racer = nil
      # A second delivery answers k1 the moment the rejection has decided
      # which keys it still owns. Deciding and releasing in one step holds
      # that racer off until the release is done, so its answer survives;
      # deciding first and releasing after lets it land in between, where
      # the release unmarks a key it does not own any more.
      allow(client).to receive(:rejected_keys_of).and_wrap_original do |original, *args|
        original.call(*args).tap do
          racer = Thread.new { client.send(:queue_task_update, state, { 'k1' => newer }) }
          racer.join(0.2)
        end
      end
      allow(client).to receive(:task_rpc).and_raise(invalid_params('rejected inputResponses'))

      expect do
        client.send(:send_task_update, stdio, 'task-1', { 'k1' => accept('old') }, state: state)
      end.to raise_error(MCPClient::Errors::TaskError)
      expect(racer.join(5)).not_to be_nil

      expect(state[:pending_update]).to eq({ 'k1' => newer })
      expect(state[:answered]).to include('k1')
      expect(state[:submitted]).to include('k1')
    end
  end

  describe 'the pace a server asks for' do
    it 'keeps a pace of two days instead of polling every day' do
      two_days = 172_800_000
      client = client_for
      script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => tool_list },
                           { 'result' => create_result(poll_ms: two_days) },
                           { 'result' => detailed_task(status: 'working', poll_ms: two_days) },
                           { 'result' => detailed_task(status: 'completed', poll_ms: two_days,
                                                       'result' => call_result) }])

      expect(client.call_tool('slow', {})['isError']).to be(false)
      expect(client).to have_received(:sleep).with(172_800.0)
    end
  end

  describe 'the answers a cleanup keeps' do
    let(:url) { 'http://tasks.example/mcp' }

    # A sessionless 2026-07-28 Streamable HTTP server: its tasks outlive a
    # cleanup, because closing the connection ends no session. It never
    # acknowledges a tasks/update, so the answers stay owed to it.
    def http_client(prompts)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next { status: 500, body: 'no answer' } if body['method'] == 'tasks/update'

        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: { jsonrpc: '2.0', id: body['id'], result: http_result(body['method']) }.to_json }
      end
      http = MCPClient::ServerStreamableHTTP.new(base_url: url, retries: 0)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(http)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', url: url }],
                                     extensions: [TASKS_EXT],
                                     elicitation_handler: lambda { |message, _schema|
                                       prompts << message
                                       { action: 'accept', content: { 'n' => 'octocat' } }
                                     })
      allow(client).to receive(:sleep) { |seconds| Kernel.sleep(seconds) }
      [client, http]
    end

    def http_result(method)
      case method
      when 'server/discover' then discover_result
      when 'tools/list' then tool_list
      when 'tools/call' then create_result(poll_ms: 50)
      when 'tasks/get'
        detailed_task(status: 'input_required', poll_ms: 50, 'inputRequests' => { 'k1' => elicit_request })
      else {}
      end
    end

    it 'does not put an answered input request to the host again after a cleanup' do
      prompts = []
      client, http = http_client(prompts)
      task = client.call_tool_as_task('slow', {})
      expect { client.wait_for_task(task, timeout: 0.2) }.to raise_error(MCPClient::Errors::TaskError)
      session = http.session_epoch

      client.cleanup

      # The task outlived the connection: closing a sessionless connection
      # ends no session, so the same handle still names the same task, and
      # what the host already answered is still answered.
      expect(http.session_epoch).to eq(session)
      expect { client.wait_for_task(task, timeout: 0.2) }.to raise_error(MCPClient::Errors::TaskError)
      expect(prompts).to eq(['Name?'])
      expect(client.send(:answered_task_keys, http, task.task_id)).to include('k1')
      expect(client.send(:task_state, http, task.task_id)[:pending_update]).to have_key('k1')
    end

    it 'forgets the bookkeeping of a session the cleanup ended' do
      client = client_for
      script_stdio(stdio, [{ 'result' => discover_result }])
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])

      client.cleanup

      expect(stdio.session_epoch).to eq(1)
      expect(client.instance_variable_get(:@task_states)).to be_nil
    end
  end

  describe 'what a task request carries, and what it does not' do
    it 'declares the extension on tasks/get, tasks/update and tasks/cancel' do
      client = client_for
      sent, = script_stdio(stdio, [{ 'result' => discover_result },
                                   { 'result' => detailed_task(status: 'working') },
                                   { 'result' => {} }, { 'result' => {} }])

      client.get_task('task-1')
      client.update_task('task-1', { 'k1' => accept })
      client.cancel_task('task-1')

      lifecycle = sent.select { |request| request['method'].start_with?('tasks/') }
      expect(methods_of(lifecycle)).to eq(%w[tasks/get tasks/update tasks/cancel])
      # -32021 otherwise: every request that uses the extension declares it.
      expect(lifecycle.map { |request| request.dig('params', '_meta', caps_meta_key, 'extensions') })
        .to all(eq({ TASKS_EXT => {} }))
    end

    # 2026-07-28 removed the 2025 `task` parameter: the server alone decides
    # whether a call becomes a task, and there is no client-side TTL to ask
    # for. The result is read inline by tasks/get; tasks/result is gone.
    it 'creates a task with a plain tools/call and reads its result with tasks/get' do
      client = client_for
      sent, = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => tool_list },
                                   { 'result' => create_result },
                                   { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

      task = client.call_tool_as_task('slow', {}, ttl: 30_000)

      expect(client.get_task_result(task)['isError']).to be(false)
      expect(wire_params(sent.find { |request| request['method'] == 'tools/call' }))
        .to eq({ 'name' => 'slow', 'arguments' => {} })
      expect(methods_of(sent)).to eq(%w[server/discover tools/list tools/call tasks/get])
    end

    it 'cancels a task with tasks/cancel and never with notifications/cancelled' do
      client = client_for
      sent, written = script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => {} }])

      expect(client.cancel_task('task-1').task_id).to eq('task-1')
      expect(methods_of(sent)).to include('tasks/cancel')
      # Neither as a request nor as a notification written past the request
      # path.
      expect(methods_of(sent)).not_to include('notifications/cancelled')
      expect(methods_of(written)).not_to include('notifications/cancelled')
    end

    it 'keeps -32021 typed on creation, update and cancel' do
      client = client_for
      required = { 'requiredCapabilities' => { 'extensions' => { TASKS_EXT => {} } } }
      refusal = { 'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                               'data' => required } }
      script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => tool_list }, refusal, refusal, refusal])

      [-> { client.call_tool_as_task('slow', {}) },
       -> { client.update_task('task-1', { 'k1' => accept }) },
       -> { client.cancel_task('task-1') }].each do |operation|
        expect(&operation).to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |error|
          expect(error.required_capabilities).to eq({ 'extensions' => { TASKS_EXT => {} } })
        end
      end
    end
  end

  # A defaulted status, a missing TTL or a timestamp that could never bound a
  # wait would drive the wait on made-up state, so a payload short of the
  # shape is not a task at all. Each fixture below is otherwise valid, so
  # nothing but the named field can be what fails it.
  describe 'a tasks/get answer that is not a task' do
    [['a ttlMs that is a string', { 'ttlMs' => '60000' }, /ttlMs is not an integer or null/],
     ['a fractional ttlMs', { 'ttlMs' => 1.5 }, /ttlMs is not an integer or null/],
     ['a createdAt that is not a string', { 'createdAt' => 1_767_225_600 }, /createdAt is not a string/],
     ['a lastUpdatedAt that is not a timestamp', { 'lastUpdatedAt' => 'yesterday' },
      /lastUpdatedAt is not an ISO 8601 timestamp/]].each do |name, broken, message|
      it "refuses #{name}" do
        client = client_for
        script_stdio(stdio, [{ 'result' => discover_result },
                             { 'result' => detailed_task(status: 'working').merge(broken) }])

        expect { client.get_task('task-1') }.to raise_error(MCPClient::Errors::InvalidResultError, message)
      end
    end
  end

  describe 'a wait that ran out of the time the caller gave it' do
    # SEP-2663 leaves the task running: the handle is the host's, and only
    # the host knows whether the work is still wanted. The wait says so and
    # sends nothing — neither tasks/cancel nor, ever, the request
    # cancellation notification that is not a task cancellation.
    it 'leaves the task to the host rather than cancelling it' do
      client = client_for
      sent, written = script_stdio(stdio, [{ 'result' => discover_result },
                                           { 'result' => detailed_task(status: 'working', poll_ms: 60_000) },
                                           { 'result' => {} }])
      allow(client).to receive(:sleep) { |seconds| Kernel.sleep(seconds) }

      expect { client.wait_for_task('task-1', timeout: 0.05) }
        .to raise_error(MCPClient::Errors::TaskError, /timed out/i)
      expect(methods_of(sent)).not_to include('tasks/cancel')
      expect(methods_of(written)).not_to include('notifications/cancelled')

      # The task is still there to end, on the host's word.
      expect(client.cancel_task('task-1').task_id).to eq('task-1')
      expect(methods_of(sent)).to include('tasks/cancel')
    end
  end

  describe 'a 2025-11-25 server' do
    let(:legacy) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, protocol: :legacy) }

    def initialized
      { 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tasks' => { 'get' => true } },
                      'serverInfo' => { 'name' => 's', 'version' => '1' } } }
    end

    # Neither method exists before the extension: waiting would poll a
    # tasks/get that carries no result, and updating would send a method the
    # revision does not have.
    it 'refuses wait_for_task and update_task without sending either' do
      client = client_for(legacy)
      # The handshake and the era probe the wait runs before its own guard.
      sent, = script_stdio(legacy, [initialized, { 'result' => {} }])
      task = MCPClient::Task.new(task_id: 'task-1', status: 'working', server: legacy)

      expect { client.wait_for_task(task) }
        .to raise_error(MCPClient::Errors::TaskError, /2026-07-28/)
      expect { client.update_task(task, { 'k1' => accept }) }
        .to raise_error(MCPClient::Errors::TaskError, %r{tasks/update})
      expect(methods_of(sent)).not_to include('tasks/get', 'tasks/update')
    end

    it 'rejects input responses that are not a Hash before anything is sent' do
      client = client_for
      sent, = script_stdio(stdio, [{ 'result' => discover_result }])

      expect { client.update_task('task-1', ['k1']) }
        .to raise_error(ArgumentError, /input request key/)
      expect(methods_of(sent)).not_to include('tasks/update')
    end
  end

  # The two input mechanisms of this revision meet on one call: the server
  # finishes its multi round-trip exchange first (basic/patterns/mrtr) and
  # only then answers with a task, whose own input requests are answered
  # through tasks/update.
  describe 'a call that runs an MRTR exchange before it becomes a task' do
    it 'keeps requestState with the original request and out of tasks/update' do
      client = client_for(elicitation_handler: ->(_message, _schema) { accept })
      sent, = script_stdio(stdio, [
                             { 'result' => discover_result }, { 'result' => tool_list },
                             { 'result' => { 'resultType' => 'input_required', 'requestState' => 'opaque-state',
                                             'inputRequests' => { 'pre' => elicit_request } } },
                             { 'result' => create_result },
                             { 'result' => detailed_task(status: 'input_required',
                                                         'inputRequests' => { 'k1' => elicit_request }) },
                             { 'result' => {} },
                             { 'result' => detailed_task(status: 'completed', 'result' => call_result) }
                           ])

      expect(client.call_tool('slow', {})['isError']).to be(false)

      calls = sent.select { |request| request['method'] == 'tools/call' }
      expect(calls.size).to eq(2)
      expect(wire_params(calls[0])).not_to have_key('inputResponses')
      expect(wire_params(calls[1])['requestState']).to eq('opaque-state')
      expect(wire_params(calls[1])['inputResponses'].keys).to eq(['pre'])
      # The state belongs to the request that was retried; the task's own
      # answers carry nothing of it.
      update = wire_params(sent.find { |request| request['method'] == 'tasks/update' })
      expect(update.keys).to contain_exactly('taskId', 'inputResponses')
      expect(update['inputResponses'].keys).to eq(['k1'])
    end
  end

  # "Clients MUST apply the same trust model to inputRequests as they do to
  # standalone elicitation/sampling requests": an entry the client would
  # refuse as a server-initiated request is refused here too, and the round
  # trip fails rather than answering it — InputResponses has no per-request
  # error channel.
  describe 'an input request a standalone handler would refuse' do
    def creating(input_request)
      script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => tool_list },
                           { 'result' => create_result },
                           { 'result' => detailed_task(status: 'input_required',
                                                       'inputRequests' => { 'k1' => input_request }) }])
    end

    it 'refuses an elicitation mode this client never declared' do
      client = client_for(elicitation_handler: ->(_message, _schema) { { action: 'accept', content: {} } })
      sent, = creating({ 'method' => 'elicitation/create',
                         'params' => { 'mode' => 'telepathy', 'message' => 'Name?' } })

      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InputRequiredError)
      expect(methods_of(sent)).not_to include('tasks/update')
    end

    it 'refuses tool-enabled sampling when sampling.tools was not declared' do
      client = client_for(sampling_handler: ->(_params) { { 'role' => 'assistant', 'content' => {} } })
      sent, = creating({ 'method' => 'sampling/createMessage',
                         'params' => { 'messages' => [], 'tools' => [{ 'name' => 'run' }] } })

      expect { client.call_tool('slow', {}) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /sampling\.tools/)
      expect(methods_of(sent)).not_to include('tasks/update')
    end
  end

  describe 'a modern tool that still carries the legacy taskSupport' do
    # 2026-07-28: the server decides. A stale execution.taskSupport is not a
    # client-side gate any more, and call_tool drives whatever it gets back.
    it 'calls it plainly and drives the task the server answers with' do
      required = MCPClient::Tool.new(name: 'slow', description: 'd', schema: { 'type' => 'object' },
                                     task_support: 'required', server: stdio)
      client = client_for
      negotiated
      allow(stdio).to receive_messages(list_tools: [required], call_tool: create_result)
      allow(stdio).to receive(:rpc_request).and_return(detailed_task(status: 'completed', 'result' => call_result))

      expect(client.call_tool('slow', {})['isError']).to be(false)
    end
  end

  describe 'a listen that asks for task notifications' do
    def wait_for(timeout = 2)
      deadline = Time.now + timeout
      Kernel.sleep(0.002) until yield || Time.now > deadline
      raise 'condition not met in time' unless yield
    end

    # Acknowledge each listen as it goes out, the way the reader thread does
    # on a live session.
    def acknowledge_on_listen(server)
      allow(server).to receive(:open_subscription).and_wrap_original do |original, subscription|
        original.call(subscription)
        acknowledgement = { 'jsonrpc' => '2.0', 'method' => 'notifications/subscriptions/acknowledged',
                            'params' => { '_meta' => { 'io.modelcontextprotocol/subscriptionId' =>
                                                       subscription.id },
                                          'notifications' => subscription.requested } }
        server.handle_line("#{JSON.generate(acknowledgement)}\n")
      end
    end

    def task_notification(subscription)
      params = detailed_task(status: 'completed', 'result' => call_result)
      params.delete('resultType')
      params['_meta'] = { 'io.modelcontextprotocol/subscriptionId' => subscription.id }
      "#{JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/tasks', 'params' => params)}\n"
    end

    it 'puts taskIds on the wire with the extension and delivers notifications/tasks' do
      received = []
      client = client_for
      sent, = script_stdio(stdio, [{ 'result' => discover_result }])
      acknowledge_on_listen(stdio)

      subscription = client.listen(notifications: { task_ids: ['task-1'] }) do |method, params|
        received << [method, params['status'], params['result']]
      end

      request = sent.find { |message| message['method'] == 'subscriptions/listen' }
      expect(wire_params(request)['notifications']).to eq({ 'taskIds' => ['task-1'] })
      expect(request.dig('params', '_meta', caps_meta_key, 'extensions')).to eq({ TASKS_EXT => {} })
      expect(subscription.acknowledged).to eq({ 'taskIds' => ['task-1'] })
      expect(subscription).to be_active

      stdio.handle_line(task_notification(subscription))
      wait_for { received.any? }

      expect(received).to eq([['notifications/tasks', 'completed', call_result]])
    end
  end

  describe 'the lifetime of an id whose keys a handler is still presenting' do
    def cap
      MCPClient::Client::TaskLifetimes::MAX_TRACKED_TASK_LIFETIMES
    end

    def ended_creation(client, id)
      client.send(:created_task, create_result(id: id), stdio, client.send(:current_session_epoch, stdio))
      client.send(:forget_task_keys, stdio, id)
    end

    def lifetimes_of(client)
      (client.instance_variable_get(:@task_lifetimes) || {}).keys.map(&:last)
    end

    it 'survives the prune while the keys are held, and goes once they are not' do
      client = client_for
      negotiated
      ended_creation(client, 'task-1')
      held = client.send(:answered_keys_mutex).synchronize do
        client.send(:in_flight_task_keys, stdio, 'task-1', create: true).first
      end
      held << 'k1'

      (1..cap).each { |i| ended_creation(client, "other-#{i}") }
      expect(lifetimes_of(client)).to include('task-1')

      held.clear
      (1..cap).each { |i| ended_creation(client, "later-#{i}") }
      expect(lifetimes_of(client)).not_to include('task-1')
    end
  end
end
