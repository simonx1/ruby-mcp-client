# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, forty-first review round:
#
# - Every handle a wait hands back, and the one a legacy cancellation hands
#   back, names the lifetime of the task it describes: none of them may
#   later reach a task the server named with the same id.
# - Queuing an answer marks its key and keeps its payload in one step, so a
#   rejection settling for an older answer never unmarks a newer one.
# - A `server:` override discards the provenance of a handle from another
#   server: what that server delivers is not checked against the other
#   server's tool.
# - The pace, the error payload, the resumption of a handle in a fresh
#   client and the notification-only delivery of an input_required task are
#   pinned.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 41' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }
  let(:other) { MCPClient::ServerStdio.new(command: 'echo other', read_timeout: 1, name: 'b') }

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

  def structured_tool(server = stdio, type: 'integer', task_support: nil)
    MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                        output_schema: { 'type' => 'object', 'required' => ['n'],
                                         'properties' => { 'n' => { 'type' => type } } },
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
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x', name: 'a' }],
                                   extensions: [TASKS_EXT], **opts)
    allow(client).to receive(:sleep)
    client
  end

  def two_server_client(**opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio, other)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x', name: 'a' },
                                                        { type: 'stdio', command: 'y', name: 'b' }],
                                   extensions: [TASKS_EXT], **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server = stdio)
    allow(server).to receive_messages(modern?: true, ping: true,
                                      capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:ensure_session_ready)
  end

  # A creation the server answers with a task under the (reused) id task-1.
  def creating(server = stdio, tool: structured_tool(server))
    server.singleton_class.include(MCPClient::CalledToolDefinition)
    allow(server).to receive(:list_tools).and_return([tool])
    allow(server).to receive(:call_tool) do
      server.send(:note_called_tool_definition, 'sync', tool)
      create_result
    end
  end

  # Every request after the creation, recorded by method.
  def recording(server = stdio)
    sent = []
    allow(server).to receive(:rpc_request) do |method, _params, **_kw|
      sent << method
      yield method
    end
    sent
  end

  describe 'the lifetime the handle a wait hands back names' do
    it 'never cancels, refreshes or updates the task that reused the id' do
      client = client_for
      negotiated
      creating
      sent = recording { |_method| detailed_task(status: 'completed', 'result' => call_result) }
      finished = client.wait_for_task(client.call_tool_as_task('sync', {}))
      expect(finished).to be_completed

      # The id is handed out again: the task the wait followed is gone.
      client.call_tool_as_task('sync', {})
      sent.clear

      expect { client.cancel_task(finished) }.to raise_error(MCPClient::Errors::TaskReplacedError)
      expect { client.get_task(finished) }.to raise_error(MCPClient::Errors::TaskReplacedError)
      expect { client.update_task(finished, { 'k1' => accept }) }
        .to raise_error(MCPClient::Errors::TaskReplacedError)
      expect(sent).to be_empty
    end
  end

  describe 'the lifetime the handle a legacy cancellation hands back names' do
    before do
      allow(stdio).to receive_messages(
        modern?: false, ping: true,
        capabilities: { 'tools' => {}, 'tasks' => { 'get' => true, 'cancel' => true, 'result' => true,
                                                    'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:list_tools).and_return([structured_tool(task_support: 'optional')])
    end

    it 'never cancels or refreshes the task that reused the id' do
      client = client_for
      sent = []
      allow(stdio).to receive(:rpc_request) do |method, _params, **_kw|
        sent << method
        case method
        when 'tools/call' then { 'task' => legacy_task }
        when 'tasks/cancel' then legacy_task(status: 'working')
        else raise "unexpected #{method}"
        end
      end
      acknowledged = client.cancel_task(client.call_tool_as_task('sync', {}))
      expect(acknowledged).to be_working

      client.call_tool_as_task('sync', {})
      sent.clear

      expect { client.cancel_task(acknowledged) }.to raise_error(MCPClient::Errors::TaskReplacedError)
      expect { client.get_task(acknowledged) }.to raise_error(MCPClient::Errors::TaskReplacedError)
      expect(sent).to be_empty
    end
  end

  describe 'a rejection settling after a newer answer was marked but before it was kept' do
    it 'leaves the newer answer answered and deliverable' do
      client = client_for
      negotiated
      state = client.send(:task_state, stdio, 'task-1')
      old = accept('old')
      newer = accept('new')
      marked = Queue.new
      release = Queue.new
      # The newer delivery pauses between marking its key and keeping its
      # payload (when those are two steps) — exactly where a rejection of
      # the older answer could still find the older payload pending.
      allow(client).to receive(:remember_answered_keys_in).and_wrap_original do |original, *args|
        original.call(*args).tap do
          if Thread.current[:newer]
            marked << true
            release.pop
          end
        end
      end
      racer = nil
      allow(client).to receive(:task_rpc) do |*_args, **_kw|
        racer = Thread.new do
          Thread.current[:newer] = true
          client.send(:queue_task_update, state, { 'k1' => newer })
        end
        # Marked and paused — or, marked and kept in one step, in which case
        # there is nothing to wait for.
        Timeout.timeout(0.5) { marked.pop } if racer.join(0.2).nil?
        raise invalid_params('rejected inputResponses')
      end

      expect { client.send(:send_task_update, stdio, 'task-1', { 'k1' => old }, state: state) }
        .to raise_error(MCPClient::Errors::TaskError)
      release << true
      expect(racer.join(5)).not_to be_nil

      expect(state[:pending_update]).to eq({ 'k1' => newer })
      expect(state[:answered]).to include('k1')
      expect(state[:submitted]).to include('k1')
    end

    it 'does not ask the host again for a key whose newer answer survived a rejection' do
      handled = 0
      client = client_for(elicitation_handler: lambda { |_message, _schema|
        handled += 1
        { 'action' => 'accept', 'content' => { 'n' => 'again' } }
      })
      negotiated
      state = client.send(:task_state, stdio, 'task-1')
      newer = accept('new')
      marked = Queue.new
      release = Queue.new
      allow(client).to receive(:remember_answered_keys_in).and_wrap_original do |original, *args|
        original.call(*args).tap do
          if Thread.current[:newer]
            marked << true
            release.pop
          end
        end
      end
      racer = nil
      allow(client).to receive(:task_rpc) do |*_args, **_kw|
        racer = Thread.new do
          Thread.current[:newer] = true
          client.send(:queue_task_update, state, { 'k1' => newer })
        end
        Timeout.timeout(0.5) { marked.pop } if racer.join(0.2).nil?
        raise invalid_params('rejected inputResponses')
      end
      expect { client.send(:send_task_update, stdio, 'task-1', { 'k1' => accept('old') }, state: state) }
        .to raise_error(MCPClient::Errors::TaskError)
      release << true
      expect(racer.join(5)).not_to be_nil

      # The next wait delivers what is pending and, seeing k1 asked for
      # again, does not put it to the host: it is answered.
      updates = []
      polls = 0
      allow(client).to receive(:task_rpc) do |_srv, method, params, **_kw|
        case method
        when 'tasks/update'
          updates << params[:inputResponses]
          {}
        when 'tasks/get'
          polls += 1
          next detailed_task(status: 'completed', 'result' => call_result) if polls > 1

          detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request })
        end
      end

      expect(client.wait_for_task('task-1')).to be_completed
      expect(updates).to eq([{ 'k1' => newer }])
      expect(handled).to eq(0)
    end
  end

  describe 'a server override on a handle from another server' do
    # Server a's tool delivers integers, server b's strings; both name the
    # task task-1.
    def conflicting_servers
      creating(stdio, tool: structured_tool(stdio, type: 'integer'))
      creating(other, tool: structured_tool(other, type: 'string'))
    end

    it 'does not validate what the named server delivers against the other server\'s tool' do
      client = two_server_client(validate_structured_content: :strict)
      negotiated(stdio)
      negotiated(other)
      conflicting_servers
      handle_a = client.call_tool_as_task('sync', {}, server: 'a')
      allow(other).to receive(:rpc_request).and_return(detailed_task(status: 'completed',
                                                                     'result' => structured_result('text')))

      expect(client.get_task_result(handle_a, server: 'b')['structuredContent']).to eq({ 'n' => 'text' })
    end

    it 'hands back a handle of the named server that carries no tool of the other' do
      client = two_server_client(validate_structured_content: :strict)
      negotiated(stdio)
      negotiated(other)
      conflicting_servers
      handle_a = client.call_tool_as_task('sync', {}, server: 'a')
      allow(other).to receive(:rpc_request).and_return(detailed_task(status: 'working'))

      handle_b = client.get_task(handle_a, server: 'b')

      expect(handle_b.server).to equal(other)
      expect(handle_b.called_tool).to be_nil
      expect(handle_a.called_tool).not_to be_nil
    end

    it 'does not validate a legacy result of the named server against the other server\'s tool' do
      client = two_server_client(validate_structured_content: :strict)
      negotiated(stdio)
      conflicting_servers
      allow(other).to receive_messages(
        modern?: false, ping: true,
        capabilities: { 'tools' => {}, 'tasks' => { 'get' => true, 'result' => true,
                                                    'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(other).to receive(:ensure_session_ready)
      allow(other).to receive(:rpc_request).and_return(structured_result('text'))
      handle_a = client.call_tool_as_task('sync', {}, server: 'a')

      expect(client.get_task_result(handle_a, server: 'b')['structuredContent']).to eq({ 'n' => 'text' })
    end

    it 'still validates what the handle\'s own server delivers' do
      client = two_server_client(validate_structured_content: :strict)
      negotiated(stdio)
      negotiated(other)
      conflicting_servers
      handle_a = client.call_tool_as_task('sync', {}, server: 'a')
      allow(stdio).to receive(:rpc_request).and_return(detailed_task(status: 'completed',
                                                                     'result' => structured_result('text')))

      expect { client.get_task_result(handle_a) }.to raise_error(MCPClient::Errors::ValidationError, /output schema/)
    end
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def tool_list
    { 'result' => { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }] } }
  end

  # A stdio server driven by scripted responses (no subprocess), recording
  # every request it was handed.
  def script_stdio(server, responses)
    sent = []
    allow(server).to receive_messages(connect: true, start_reader: nil, start_stderr_reader: nil)
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

  describe 'the pace successive observations set' do
    it 'follows every change of pollIntervalMs, up and down' do
      client = client_for
      negotiated
      creating
      slept = []
      allow(client).to receive(:sleep) { |seconds| slept << seconds }
      polls = 0
      recording do |_method|
        polls += 1
        case polls
        when 1 then detailed_task(status: 'working', poll_ms: 500)
        when 2 then detailed_task(status: 'working', poll_ms: 100)
        when 3 then detailed_task(status: 'working', poll_ms: 900)
        else detailed_task(status: 'completed', 'result' => call_result)
        end
      end

      expect(client.wait_for_task(client.call_tool_as_task('sync', {}))).to be_completed
      expect(slept).to eq([0.5, 0.1, 0.9])
    end
  end

  describe 'the error a failed task carries' do
    it 'is raised with its data intact' do
      data = { 'retryAfter' => { 'seconds' => 5 }, 'reasons' => %w[quota] }
      client = client_for
      negotiated
      creating
      recording do |_method|
        detailed_task(status: 'failed', 'error' => { 'code' => -32_603, 'message' => 'quota', 'data' => data })
      end

      expect { client.call_tool('sync', {}) }.to raise_error(MCPClient::Errors::ServerError) { |e|
        expect(e.code).to eq(-32_603)
        expect(e.data).to eq(data)
      }
    end
  end

  describe 'a 2026 tasks/cancel acknowledgement' do
    it 'is not a Task: the handle handed back still reports the task working' do
      client = client_for
      negotiated
      creating
      sent = recording { |method| method == 'tasks/cancel' ? {} : raise("unexpected #{method}") }

      cancelled = client.cancel_task(client.call_tool_as_task('sync', {}))

      expect(sent).to eq(['tasks/cancel'])
      expect(cancelled).to be_working
      expect(cancelled).not_to be_terminal
      expect(client.cancel_task('task-1')).to be_working
    end
  end

  describe 'a legacy tasks/result reporting a tool error' do
    it 'hands the CallToolResult back unchanged, isError and all' do
      failed = { 'content' => [{ 'type' => 'text', 'text' => 'boom' }], 'isError' => true }
      tool = MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                                 task_support: 'optional', server: stdio)
      allow(stdio).to receive_messages(
        modern?: false, ping: true, list_tools: [tool],
        capabilities: { 'tools' => {}, 'tasks' => { 'get' => true, 'result' => true,
                                                    'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request) do |method, _params, **_kw|
        method == 'tools/call' ? { 'task' => legacy_task } : failed
      end
      client = client_for

      expect(client.get_task_result(client.call_tool_as_task('sync', {}))).to eq(failed)
    end
  end

  describe 'the tools/call a transparent 2026 call sends' do
    it 'carries no task parameter: the server decides whether to answer with a task' do
      client = client_for
      sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => create_result },
                                  { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

      expect(client.call_tool('slow', {})['isError']).to be(false)

      call = sent.find { |request| request['method'] == 'tools/call' }
      expect(wire_params(call)).to eq({ 'name' => 'slow', 'arguments' => {} })
      expect(call.dig('params', '_meta', 'io.modelcontextprotocol/clientCapabilities', 'extensions'))
        .to eq({ TASKS_EXT => {} })
    end
  end

  describe 'the legacy initialize handshake of a client that declared the extension' do
    # Extension negotiation is a 2026-07-28 mechanism (basic/versioning
    # "Extension Negotiation"): the tasks extension is not defined under
    # 2025-11-25, and the 2025 handshake does not advertise it.
    it 'does not advertise the 2026 extension to a 2025 server' do
      legacy = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, protocol: :legacy)
      legacy.declare_extension(TASKS_EXT)
      sent = script_stdio(legacy, [{ 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                                   'serverInfo' => { 'name' => 's', 'version' => '1' } } },
                                   { 'result' => { 'tools' => [] } }])

      legacy.list_tools

      handshake = sent.find { |request| request['method'] == 'initialize' }
      expect(handshake['params']['capabilities']).not_to have_key('extensions')
      expect(legacy.declared_extensions).to include(TASKS_EXT)
    end
  end

  describe 'the polling bound' do
    it 'is a delay Ruby can actually sleep' do
      bound = MCPClient::Client::TaskSupport::MAX_TASK_POLL_INTERVAL

      expect(bound).to be_finite
      # sleep refuses a Float too large for a Time with a RangeError; the
      # timeout proves it accepted the bound and started waiting.
      expect { Timeout.timeout(0.05) { sleep(bound) } }.to raise_error(Timeout::Error)
    end
  end

  describe 'a handle resumed in a fresh client' do
    # Task ids and handles survive this process only as far as the host
    # persists them: what a creation hands back serializes with #to_h, and
    # a handle rebuilt from that hash in another client names the same task
    # on the server it is routed to.
    it 'waits on a task another client created, by its serialized handle and by its id' do
      creator = client_for
      negotiated
      creating
      stored = creator.call_tool_as_task('sync', {}).to_h
      expect(stored).to include('taskId' => 'task-1', 'status' => 'working')

      resumed = client_for
      polls = 0
      recording do |_method|
        polls += 1
        polls == 1 ? detailed_task(status: 'working') : detailed_task(status: 'completed', 'result' => call_result)
      end
      handle = MCPClient::Task.from_json(stored, server: stdio)

      expect(resumed.wait_for_task(handle)).to be_completed
      expect(resumed.wait_for_task(stored['taskId'], server: 'a')).to be_completed
    end
  end

  describe 'an input_required task announced by notifications/tasks alone' do
    # The client answers input requests only inside a wait (or through
    # #update_task): a notification carrying inputRequests is delivered to
    # the host as-is, so a host that leaves the task to notifications has to
    # answer it itself, or hand it to #wait_for_task.
    it 'is handed to the host unanswered, and nothing is sent for it' do
      received = []
      client = client_for
      negotiated
      client.on_notification { |_server, method, params| received << [method, params['status']] }
      sent = recording { |method| raise "unexpected #{method}" }
      params = detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request })
      params.delete('resultType')

      # Delivered the way the transport delivers it: through the handler the
      # client registered on the server.
      stdio.instance_variable_get(:@notification_callback).call('notifications/tasks', params)

      expect(received).to eq([['notifications/tasks', 'input_required']])
      expect(sent).to be_empty
    end
  end

  describe 'a write the lifetime guard refuses at the wire of a legacy SSE transport' do
    # A guard that passes the transport's early check and refuses its last
    # one, inside the POST: exactly what a creation landing in the gap does.
    def late_refusal
      calls = 0
      lambda do
        calls += 1
        raise MCPClient::Errors::TaskReplacedError, 'the task this handle names was replaced' if calls > 1
      end
    end

    it 'keeps the refusal and posts nothing' do
      server = MCPClient::ServerSSE.new(base_url: 'http://example.com/sse', read_timeout: 1, retries: 0)
      server.instance_variable_set(:@rpc_endpoint, '/rpc')
      server.instance_variable_set(:@use_sse, false)
      allow(server).to receive_messages(ensure_initialized: true)
      post = stub_request(:post, 'http://example.com/rpc')

      expect { server.guarded_writes(late_refusal) { server.rpc_request('tasks/update', { taskId: 't' }) } }
        .to raise_error(MCPClient::Errors::TaskReplacedError)
      expect(post).not_to have_been_requested
    end
  end
end
