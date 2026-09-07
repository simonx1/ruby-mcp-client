# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'open3'
require 'timeout'
require 'tmpdir'
require 'webmock/rspec'

# MCP 2026-07-28 the tasks extension: regression suite.
#
# These examples were written one adversarial review round at a time, each
# pinning a defect that round found. They are gathered here by subject
# rather than by the round that produced them; the round is noted on each
# section only because the review notes refer to it. Every example here
# covers production code no other spec reaches.

# --- verify ----------------------------------------------------------------

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, verification round:
#
# - A handle of a task that is still running stays usable however many other
#   task ids the session creates: the lifetime cap forgets ended tasks, never
#   live ones.
# - On a 2026-07-28 server the error code decides whether a task is missing:
#   an internal failure is not a `TaskNotFound`, and it takes nothing of the
#   task's bookkeeping with it.
# - Both new call paths validate a result against the definition the call went
#   out under, not against a list refreshed since.
# - An input round that fails part way keeps the answers the host already gave.
RSpec.describe 'MCP 2026-07-28 tasks extension — verification round' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def create_result(id: 'task-1', **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def detailed_task(status:, id: 'task-1', **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def client_for(server = stdio, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server = stdio)
    allow(server).to receive(:capabilities).and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:modern?).and_return(true)
    allow(server).to receive(:ensure_session_ready)
  end

  let(:legacy) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'legacy') }

  # A 2025-11-25 server whose tools/call creates a task (the wrapped
  # CreateTaskResult of that revision) and whose tasks/get reports it working.
  def legacy_tasks
    tool = MCPClient::Tool.new(name: 'slow', description: 'd', schema: { 'type' => 'object' },
                               task_support: 'optional', server: legacy)
    allow(legacy).to receive_messages(
      modern?: false, list_tools: [tool],
      capabilities: { 'tools' => {}, 'tasks' => { 'get' => true, 'requests' => { 'tools' => { 'call' => {} } } } }
    )
    allow(legacy).to receive(:ensure_session_ready)
    created = 0
    allow(legacy).to receive(:rpc_request) do |method, _params|
      now = Time.now.utc.iso8601(3)
      task = { 'taskId' => "task-#{created += 1}", 'status' => 'working', 'createdAt' => now,
               'lastUpdatedAt' => now, 'ttl' => 60_000, 'pollInterval' => 1 }
      method == 'tools/call' ? { 'task' => task } : task.merge('taskId' => 'task-1')
    end
  end

  # One CreateTaskResult, as the server would answer it in the live session.
  def creation(client, id = 'task-1', srv: stdio)
    client.send(:created_task, create_result(id: id), srv, client.send(:current_session_epoch, srv))
  end

  def accept(value = 'x')
    { 'action' => 'accept', 'content' => { 'n' => value } }
  end

  def cap
    MCPClient::Client::TaskLifetimes::MAX_TRACKED_TASK_LIFETIMES
  end

  describe 'the lifetime cap and a task that is still running' do
    it 'keeps a handle of a running task usable once the cap is passed' do
      client = client_for
      negotiated
      handle = creation(client)
      (1..cap).each { |i| creation(client, "other-#{i}") }
      allow(stdio).to receive(:rpc_request).and_return(detailed_task(status: 'working'))

      expect(client.get_task(handle).status).to eq('working')
    end

    it 'still updates and cancels through a handle the cap did not forget' do
      client = client_for
      negotiated
      handle = creation(client)
      (1..cap).each { |i| creation(client, "other-#{i}") }
      sent = []
      allow(stdio).to receive(:rpc_request) do |method, params|
        sent << [method, params]
        {}
      end

      expect(client.update_task(handle, { 'k1' => accept })).to be(true)
      expect(client.cancel_task(handle).task_id).to eq('task-1')
      expect(sent).to eq([['tasks/update', { taskId: 'task-1', inputResponses: { 'k1' => accept } }],
                          ['tasks/cancel', { taskId: 'task-1' }]])
    end

    it 'keeps a handle the legacy creation API produced usable too' do
      # The 2025 path unwraps the `task` member first, so it counts the
      # lifetime of a handle that already exists: that handle is a handle of
      # a running task like any other.
      client = client_for(legacy)
      legacy_tasks
      handle = client.call_tool_as_task('slow', {})
      (1..cap).each { |i| creation(client, "other-#{i}", srv: legacy) }

      expect(client.get_task(handle).status).to eq('working')
      expect(handle.task_id).to eq('task-1')
    end

    it 'still forgets the lifetimes of task ids whose tasks have ended' do
      client = client_for
      negotiated
      (1..(cap + 1)).each do |i|
        creation(client, "task-#{i}")
        client.send(:forget_task_keys, stdio, "task-#{i}")
      end

      expect(client.instance_variable_get(:@task_lifetimes).size)
        .to be <= MCPClient::Client::TaskLifetimes::TRACKED_TASK_LIFETIMES_LOW_WATER + 1
    end
  end

  describe 'what a modern tasks/get error means' do
    def failing(error)
      allow(stdio).to receive(:rpc_request).and_raise(error)
    end

    def server_error(message, code)
      MCPClient::Errors::ServerError.new(message, code: code)
    end

    it 'reports an internal failure as a task error, not a missing task' do
      client = client_for
      negotiated
      handle = creation(client)
      state = client.send(:task_state, stdio, 'task-1')
      client.send(:queue_task_update, state, { 'k1' => accept })
      failing(server_error('Upstream credential expired', MCPClient::Errors::Codes::INTERNAL_ERROR))

      expect { client.get_task(handle) }.to raise_error(MCPClient::Errors::TaskError, /credential expired/)
    end

    it 'keeps the answers of an unconfirmed update through an internal failure' do
      client = client_for
      negotiated
      handle = creation(client)
      state = client.send(:task_state, stdio, 'task-1')
      client.send(:queue_task_update, state, { 'k1' => accept })
      failing(server_error('Upstream credential expired', MCPClient::Errors::Codes::INTERNAL_ERROR))

      expect { client.get_task(handle) }.to raise_error(MCPClient::Errors::TaskError)
      kept = client.send(:task_state, stdio, 'task-1')
      expect(kept[:pending_update]).to eq({ 'k1' => accept })
      expect(kept[:answered]).to include('k1')
    end

    it 'still reads the specified -32602 as a missing task and forgets its keys' do
      client = client_for
      negotiated
      handle = creation(client)
      state = client.send(:task_state, stdio, 'task-1')
      client.send(:queue_task_update, state, { 'k1' => accept })
      failing(server_error("Task 'task-1' does not exist", MCPClient::Errors::Codes::INVALID_PARAMS))

      expect { client.get_task(handle) }.to raise_error(MCPClient::Errors::TaskNotFound)
      expect(client.send(:task_state, stdio, 'task-1')[:pending_update]).to be_nil
    end
  end

  describe 'the tool definition a modern task call is validated against' do
    def tool_with(required)
      MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                          output_schema: { 'type' => 'object', 'required' => required }, server: stdio)
    end

    # A transport that records the definition its tools/call goes out under,
    # as the HTTP ones do when they derive the Mcp-Param-* headers from their
    # tool list, and that refreshes that list mid-call (HeaderMismatch
    # recovery) so the re-resolve has two definitions to choose between.
    def recording(called, listed_after, &answer)
      stdio.extend(MCPClient::CalledToolDefinition)
      generation = 1
      stdio.define_singleton_method(:tools_generation) { generation }
      allow(stdio).to receive_messages(modern?: true, ping: true, list_tools: [called], ensure_initialized: true,
                                       ensure_session_ready: nil,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:rpc_request) do |method, _params|
        raise "unexpected #{method}" unless method == 'tools/call'

        stdio.send(:note_called_tool_definition, 'sync', called)
        generation = 2
        allow(stdio).to receive(:list_tools).and_return([listed_after])
        answer.call
      end
    end

    it 'validates a synchronous call_tool_as_task answer against the call\'s own definition' do
      recording(tool_with([]), tool_with(['b'])) { { 'content' => [], 'structuredContent' => {} } }
      client = client_for(validate_structured_content: :strict)

      expect(client.call_tool_as_task('sync', {})).to be_completed
    end

    it 'validates a streamed task chunk against the call\'s own definition' do
      recording(tool_with([]), tool_with(['b'])) { create_result }
      client = client_for(validate_structured_content: :strict)
      allow(client).to receive(:task_rpc)
        .and_return(detailed_task(status: 'completed', 'result' => { 'content' => [], 'structuredContent' => {} }))

      expect(client.call_tool_streaming('sync', {}).to_a)
        .to eq([{ 'content' => [], 'structuredContent' => {} }])
    end
  end

  describe 'an input round that fails part way' do
    def input_task
      MCPClient::Task.from_json(detailed_task(status: 'input_required', 'inputRequests' => {
                                                'k1' => elicit_request('Your name?'),
                                                'k2' => elicit_request('Your password?')
                                              }), server: stdio, detailed: true)
    end

    def elicit_request(message)
      { 'method' => 'elicitation/create',
        'params' => { 'mode' => 'form', 'message' => message,
                      'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
    end

    # A host that answers the first prompt and cannot answer the second: the
    # person has already typed their name when the round trip fails.
    def answering(asked)
      lambda do |message, _schema|
        asked << message
        raise 'the host could not answer' if message == 'Your password?'

        { 'action' => 'accept', 'content' => { 'n' => 'Ada' } }
      end
    end

    it 'keeps the answer the host already gave' do
      asked = []
      client = client_for(elicitation_handler: answering(asked))
      negotiated
      creation(client)
      state = client.send(:task_state, stdio, 'task-1')

      expect { client.send(:answer_task_input_requests, input_task, state[:answered], stdio) }
        .to raise_error(MCPClient::Errors::InputRequiredError)

      expect(state[:answered].to_a).to eq(['k1'])
      expect(state[:pending_update].keys).to eq(['k1'])
      expect(state[:pending_update]['k1']).to include('action' => 'accept')
    end

    it 'never puts an answered input request to the host a second time' do
      asked = []
      client = client_for(elicitation_handler: answering(asked))
      negotiated
      creation(client)
      task = input_task
      state = client.send(:task_state, stdio, 'task-1')

      2.times do
        expect { client.send(:answer_task_input_requests, task, state[:answered], stdio) }
          .to raise_error(MCPClient::Errors::InputRequiredError)
      end

      expect(asked).to eq(['Your name?', 'Your password?', 'Your password?'])
    end
  end

  describe 'a lost update and the state that holds it' do
    it 'retains both the answered key and the payload that resends it' do
      client = client_for
      # The session restarts right after every state lookup, and the update's
      # outcome is ambiguous: the state that recorded the answered key must
      # hold the pending payload too, or nothing ever resends it.
      allow(client).to receive(:task_state).and_wrap_original do |m, *args|
        m.call(*args).tap { stdio.send(:bump_session_epoch) }
      end
      allow(stdio).to receive(:rpc_request).and_raise(MCPClient::Errors::TransportError, 'lost')

      expect { client.send(:send_task_update, stdio, 't', { 'k1' => accept }) }
        .to raise_error(MCPClient::Errors::TaskError)

      states = client.instance_variable_get(:@task_states).values
      holding = states.select { |state| state[:answered].include?('k1') }
      expect(holding.size).to eq(1)
      expect(holding.first[:pending_update]).to eq({ 'k1' => accept })
      expect(states.count { |state| state[:pending_update] }).to eq(1)
    end
  end

  describe 'the update lock a retransmission reads the pending payload under' do
    # A lock that says when a thread is about to take it: the retransmission's
    # pending read has to happen on the far side of this point, or a confirmed
    # answer landing meanwhile is resent over.
    def gated_lock(&on_enter)
      Class.new do
        define_method(:initialize) { @mutex = Mutex.new }
        define_method(:synchronize) do |&block|
          on_enter.call
          @mutex.synchronize(&block)
        end
      end.new
    end

    it 'reads what is still pending only once it holds the lock' do
      client = client_for
      negotiated
      handle = creation(client)
      updates = []
      allow(stdio).to receive(:rpc_request) do |method, params|
        raise "unexpected #{method}" unless method == 'tasks/update'

        updates << params[:inputResponses]
        {}
      end
      state = client.send(:task_state, stdio, 'task-1')
      state[:pending_update] = { 'k1' => accept('lost') }
      at_the_lock = Queue.new
      may_lock = Queue.new
      state[:update_mutex] = gated_lock do
        next unless Thread.current[:retransmitting]

        at_the_lock << true
        may_lock.pop
      end
      retransmission = Thread.new do
        Thread.current[:retransmitting] = true
        # The observation the poll made says the task is asking but not for what:
        # everything still pending is the retransmission's to send.
        asking = MCPClient::Task.from_json({ 'taskId' => 'task-1', 'status' => 'input_required' }, server: stdio)
        client.send(:retransmit_pending_update, asking, { srv: stdio, task_id: 'task-1' })
      end
      # The retransmission has done everything it does before taking the lock;
      # the host's own answer for the same key now lands and is confirmed.
      at_the_lock.pop
      client.update_task(handle, { 'k1' => accept('decline') })
      may_lock << true
      retransmission.join

      expect(updates).to eq([{ 'k1' => accept('decline') }])
      expect(client.send(:task_state, stdio, 'task-1')[:pending_update]).to be_nil
    end
  end

  describe 'the lifetime pin a real transport enforces' do
    # The transport's own wire path, down to the write itself: only the pipe
    # is substituted, so every pre-write check the transport makes — the one
    # in the same critical section as the write included — runs for real.
    def wired(server)
      sent = []
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      allow(server).to receive(:ensure_initialized).and_return(true)
      pipe = double('stdin', flush: nil, closed?: false, close: nil)
      allow(pipe).to receive(:puts) { |line| sent << JSON.parse(line) }
      server.instance_variable_set(:@stdin, pipe)
      allow(server).to receive(:wait_response) { |id, **_| { 'jsonrpc' => '2.0', 'id' => id, 'result' => {} } }
      sent
    end

    it 'writes nothing when a creation lands while the update establishes its session' do
      client = client_for
      negotiated
      handle = creation(client)
      sent = wired(stdio)
      # Past every preflight, and before anything is written.
      allow(stdio).to receive(:ensure_session_ready) { creation(client) }

      expect { client.update_task(handle, { 'k1' => accept }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
      expect(sent).to be_empty
    end

    it 'writes nothing when a creation lands between the last two checks' do
      client = client_for
      negotiated
      handle = creation(client)
      sent = wired(stdio)
      # Past the check the request path makes before it builds the request,
      # and before the one the transport makes under the write lock.
      allow(stdio).to receive(:build_jsonrpc_request).and_wrap_original do |original, *args, **kwargs|
        creation(client)
        original.call(*args, **kwargs)
      end

      # The refusal keeps its type on the way up, so the update takes its
      # replacement branch: a definite "they were discarded", never the
      # ambiguous transport failure a wrapped refusal would report.
      expect { client.update_task(handle, { 'k1' => accept }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id .* discarded/im)
      expect(sent).to be_empty
      expect(client.send(:task_state, stdio, 'task-1')[:pending_update]).to be_nil
    end

    it 'writes the update of a task nothing replaced' do
      client = client_for
      negotiated
      handle = creation(client)
      sent = wired(stdio)

      expect(client.update_task(handle, { 'k1' => accept })).to be(true)
      expect(sent.map { |req| req['method'] }).to eq(['tasks/update'])
    end
  end
end

# --- round9 ----------------------------------------------------------------

# MCP 2026-07-28 tasks extension, ninth review round: a rejected update
# gives its keys back, a poll that ran past the deadline ends the wait, the
# caller deadline and the TTL stay separate (a later, longer TTL extends
# the wait; the seed TTL bounds polls that time out), a handler failure
# never releases keys another caller submitted, streamed task results are
# validated, and the client file loads on its own.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 9' do
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
    # Millisecond precision: short TTLs in these examples start now, not at
    # the last whole second.
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def tool_list(output_schema: nil)
    tool = { 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }
    tool['outputSchema'] = output_schema if output_schema
    { 'result' => { 'tools' => [tool], 'ttlMs' => 60_000 } }
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
      # A single trailing responder answers every remaining request.
      responder = responses.first.respond_to?(:call) && responses.size == 1 ? responses.first : responses.shift
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

  it 'presents an input request again after the server rejected its update' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                { 'error' => { 'code' => -32_602, 'message' => 'inputResponses: bad content' } },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::TaskError, /bad content/)
    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(2)
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(2)
  end

  it 'ends the wait when a poll came back after the deadline' do
    client = client_for(stdio)
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                lambda { |_req|
                                  Kernel.sleep 0.1
                                  { 'result' => detailed_task(status: 'working') }
                                }])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task, timeout: 0.05) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(sent.count { |r| r['method'] == 'tasks/get' }).to eq(1)
    expect(client).not_to have_received(:sleep)
  end

  it 'lets a later, longer ttlMs extend a wait that has no caller timeout' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         ->(_req) { { 'result' => detailed_task(status: 'working', ttl_ms: 200) } },
                         lambda { |_req|
                           Kernel.sleep 0.25
                           { 'result' => detailed_task(status: 'working', ttl_ms: 3_600_000) }
                         },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    expect(client.call_tool('slow', {})['isError']).to be(false)
  end

  it 'bounds a wait whose polls all time out by the TTL of the created task' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(ttl_ms: 300) },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'stalled' }])
    allow(stdio).to receive(:rpc_request).and_call_original
    task = client.call_tool_as_task('slow', {})

    Timeout.timeout(5) do
      expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    end
  end

  it 'keeps a key submitted through update_task when a handler fails afterwards' do
    started = Queue.new
    release = Queue.new
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      started << true
      release.pop
      raise 'handler broke'
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }) },
                         { 'result' => {} }])
    task = client.call_tool_as_task('slow', {})
    detailed = client.get_task(task)

    waiter = Thread.new do
      client.send(:answer_task_input_requests, detailed, client.send(:answered_task_keys, stdio, 'task-1'), stdio)
    end
    started.pop
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })
    release << true
    expect { waiter.join }.to raise_error(MCPClient::Errors::InputRequiredError, /handler/)

    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
  end

  it 'validates the structured content of a task resolved on the streaming path' do
    client = client_for(stdio, validate_structured_content: :strict)
    schema = { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer' } }, 'required' => ['n'] }
    result = call_result.merge('structuredContent' => { 'n' => 'x' })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list(output_schema: schema), { 'result' => task_result },
                         { 'result' => detailed_task(status: 'completed', 'result' => result) }])

    expect { client.call_tool_streaming('slow', {}).to_a }.to raise_error(MCPClient::Errors::ValidationError)
  end

  it 'sanitizes the legacy tasks/result transport error' do
    client = client_for(stdio)
    allow(stdio).to receive(:capabilities).and_return({ 'tasks' => { 'result' => {} } })
    allow(stdio).to receive(:modern?).and_return(false)
    allow(stdio).to receive(:ping)
    allow(stdio).to receive(:rpc_request).with('tasks/result', anything)
                                         .and_raise(MCPClient::Errors::TransportError, "boom\nWARN forged")

    expect { client.get_task_result("t\nWARN forged") }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e.message).not_to include("\nWARN forged")
    }
  end

  it 'forwards the extensions option through MCPClient.connect' do
    allow(stdio).to receive(:connect).and_return(true)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)

    client = MCPClient.connect(%w[echo test], extensions: [TASKS_EXT])

    expect(client).to be_tasks_extension
    expect(stdio.declared_extensions).to include(TASKS_EXT)
  end

  it 'loads the client file on its own' do
    lib = File.expand_path('../../../lib', __dir__)
    _out, err, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-e', "require 'mcp_client/client'")

    expect(status).to be_success, err
  end
end

# --- round13 ---------------------------------------------------------------

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

  # A stateless 2026-07-28 peer holds no session a cleanup could end (round
  # 43): the task outlives the connection, and so does what the host already
  # answered for it. A 2025-11-25 handshake's session does end — see round 43.
  it 'keeps task bookkeeping across a cleanup: a stateless peer has no session to end' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, { 'result' => {} }])
    task = client.call_tool_as_task('slow', {})
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')

    stdio.cleanup

    expect(stdio.session_epoch).to eq(0)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
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

# --- round15 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, fifteenth review round: a server restart
# ends the wait that spans it (a reused task id or key is a new request, and
# round 33 stopped the wait from following it into the new session), and a
# caller holding an outdated session epoch can neither delete the newer
# session's bookkeeping nor become it.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 15' do
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

  def wire(request)
    JSON.parse(JSON.generate(request))
  end

  it 'ends the call when the server session changed during the wait' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    sent = script_stdio(stdio, [
                          { 'result' => discover_result }, tool_list, { 'result' => task_result },
                          { 'result' => detailed_task(status: 'input_required',
                                                      'inputRequests' => { 'k1' => elicit_request }) },
                          { 'result' => {} },
                          lambda { |_req|
                            # The process restarted while this poll was
                            # outstanding: what came back describes the ended
                            # session and is not acted on.
                            stdio.send(:bump_session_epoch)
                            { 'result' => detailed_task(status: 'input_required',
                                                        'inputRequests' => { 'k1' => elicit_request }) }
                          },
                          # The new process reused the task id and the key for
                          # a request of its own; the call never sees it.
                          { 'result' => detailed_task(status: 'input_required',
                                                      'inputRequests' => { 'k1' => elicit_request }) }
                        ])

    expect { client.call_tool('slow', {}) }
      .to raise_error(MCPClient::Errors::TaskError, /session it belongs to ended/i)
    expect(handled).to eq(1)
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(1)
  end

  it 'reserves keys in the current session even when the wait started in the previous one' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }])
    task = client.call_tool_as_task('slow', {})
    wait = { task_id: 'task-1', srv: stdio, answered: client.send(:answered_task_keys, stdio, 'task-1') }
    old_epoch = stdio.session_epoch
    stdio.send(:bump_session_epoch)

    client.send(:refresh_wait_session, wait)
    wait[:answered] << 'k1'

    expect(wait[:epoch]).to eq(old_epoch + 1)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    expect(client.instance_variable_get(:@task_states).keys.map { |k| k[1] }.uniq).to eq([old_epoch + 1])
    expect(task).to be_a(MCPClient::Task)
  end

  it 'never lets a caller with an outdated epoch delete or replace the current session state' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, { 'result' => {} }])
    client.call_tool_as_task('slow', {})
    stdio.send(:bump_session_epoch)
    # The handle belongs to the session that ended and no longer names a
    # task (see round 32); the live session's task of that id is named by id.
    client.update_task('task-1', { 'k2' => { 'action' => 'decline' } })
    current = client.send(:task_state, stdio, 'task-1')
    expect(current[:answered]).to include('k2')

    # A request that read the epoch before the restart reports the old one.
    allow(stdio).to receive(:session_epoch).and_return(stdio.session_epoch - 1)
    stale = client.send(:task_state, stdio, 'task-1')

    expect(stale).to equal(current)
    states = client.instance_variable_get(:@task_states)
    expect(states.keys.map { |k| k[1] }.uniq).to eq([current_epoch = states.keys.first[1]])
    expect(current_epoch).to eq(stdio.session_epoch + 1)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k2')
  end

  it 'rejects a tasks/get result that lacks the fields a Task must carry' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => { 'resultType' => 'complete', 'taskId' => 'task-1' } }])

    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, %r{tasks/get})
  end

  it 'rejects a tasks/get result without the ttlMs key but accepts a null ttlMs' do
    client = client_for(stdio)
    without_ttl = detailed_task(status: 'working').tap { |t| t.delete('ttlMs') }
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => without_ttl }])
    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /ttlMs/)

    other = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'b')
    client = client_for(other)
    script_stdio(other, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'working', ttl_ms: nil) },
                         { 'result' => detailed_task(status: 'completed', ttl_ms: nil, 'result' => call_result) }])
    expect(client.call_tool('slow', {})['isError']).to be(false)
  end

  it 'requires a failed task to carry a JSON-RPC error object' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'failed', 'error' => {}) }])
    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /error/)

    other = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'b')
    client = client_for(other)
    script_stdio(other, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'failed',
                                                     'error' => { 'code' => -32_000, 'message' => 'boom' }) }])
    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::ServerError) { |e|
      expect(e.code).to eq(-32_000)
      expect(e.message).to include('boom')
    }
  end
end

# --- round18 ---------------------------------------------------------------

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

# --- round19 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, nineteenth review round: the caller's
# wait budget bounds the capability probe itself (a spent budget sends
# nothing, a short one does not wait for the transport's own timeout), and a
# null task payload is an invalid result, not an empty working task.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 19' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def client_for(server)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
  end

  it 'sends nothing when the wait budget is already spent' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping).and_raise('the probe must not run')
    allow(stdio).to receive(:rpc_request).and_raise('no request must go out')

    expect { client.wait_for_task('task-1', timeout: 0) }
      .to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(stdio).not_to have_received(:ping)
  end

  it 'bounds the capability probe by the wait budget' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping) { Kernel.sleep(2) }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { client.wait_for_task('task-1', timeout: 0.05) }
      .to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
  end

  it 'still probes within the budget when the server answers in time' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping).and_raise(MCPClient::Errors::ConnectionError, 'down')

    expect { client.wait_for_task('task-1', timeout: 5) }
      .to raise_error(MCPClient::Errors::ConnectionError, /down/)
  end

  it 'rejects a null task payload' do
    [nil, false].each do |payload|
      expect { MCPClient::Task.from_json(payload) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /not an object/), payload.inspect
    end
  end

  it 'logs a parse failure for a task notification without params' do
    output = StringIO.new
    client = MCPClient::Client.new(mcp_server_configs: [], logger: Logger.new(output))

    client.send(:handle_task_status_notification, 'srv', nil)

    expect(output.string).to include('Failed to parse task status notification')
    expect(output.string).to match(/not an object/)
    expect(output.string).not_to include('status: working')
  end
end

# --- round20 ---------------------------------------------------------------

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

    expect(output.string.scan('Failed to parse task status notification').size).to eq(2)
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

# --- round21 ---------------------------------------------------------------

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

# --- round22 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, twenty-second review round: a handler
# round that timed out spends no input round, and a key whose abandoned
# handler is still running is not presented again until it finishes.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 22' do
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

  # A handler that blocks until this example lets it finish: `entered` says
  # it started, `release` lets it return. It replaces a handler that slept
  # for a fixed time, so nothing here depends on a wall-clock margin holding
  # under a loaded suite.
  def blocking_handler(entered, release, blocking)
    lambda { |_m, _s|
      if blocking.value
        entered << true
        release.pop
      end
      { action: 'accept', content: { 'n' => 'x' } }
    }
  end

  # Block until the handler the wait abandoned has actually started: the
  # thread outlives the wait, so it always gets there.
  def await_start(entered)
    raise 'the abandoned handler never started' if entered.pop(timeout: 5).nil?
  end

  # Block until another thread has made the state transition, rather than
  # assuming a fixed delay was enough for it.
  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for the abandoned handler to release its keys' if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Kernel.sleep(0.005)
    end
  end

  it 'does not spend an input round on a handler that timed out' do
    blocking = Struct.new(:value).new(true)
    entered = Queue.new
    release = Queue.new
    handled = 0
    inner = blocking_handler(entered, release, blocking)
    client = client_for(stdio, elicitation_handler: lambda { |message, schema|
      handled += 1
      inner.call(message, schema)
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, sticky_task_server])
    task = client.call_tool_as_task('slow', {})

    (MCPClient::Client::TaskSupport::MAX_TASK_INPUT_ROUNDS + 2).times do
      expect { client.wait_for_task(task, timeout: 0.3) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
      await_start(entered)
      release << true # the abandoned handler finishes
      wait_until { client.send(:answered_task_keys, stdio, 'task-1').empty? }
    end
    expect(client.send(:task_state, stdio, 'task-1')[:rounds]).to eq(0)

    blocking.value = false
    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(MCPClient::Client::TaskSupport::MAX_TASK_INPUT_ROUNDS + 3)
  end

  it 'does not present a key again while its abandoned handler is still running' do
    blocking = Struct.new(:value).new(true)
    entered = Queue.new
    release = Queue.new
    handled = 0
    inner = blocking_handler(entered, release, blocking)
    client = client_for(stdio, elicitation_handler: lambda { |message, schema|
      handled += 1
      inner.call(message, schema)
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, sticky_task_server])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task, timeout: 0.3) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    await_start(entered)
    # The first presentation is still running: the retry polls, it does not ask again.
    expect { client.wait_for_task(task, timeout: 0.1) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(handled).to eq(1)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')

    release << true # the abandoned handler finishes; its answer is dropped
    wait_until { client.send(:answered_task_keys, stdio, 'task-1').empty? }
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty

    blocking.value = false
    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(2)
  end

  it 'rejects a completed result whose resultType is present but not "complete"' do
    expect(MCPClient::Task.complete_result_object?({ 'resultType' => false })).to be(false)
    expect(MCPClient::Task.complete_result_object?({ 'resultType' => nil })).to be(false)
    expect(MCPClient::Task.complete_result_object?({ 'resultType' => 'complete' })).to be(true)
    expect(MCPClient::Task.complete_result_object?({ 'content' => [] })).to be(true)
  end

  it 'maps -32602 on tasks/update and tasks/cancel to TaskNotFound only on an explicit indication' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'error' => { 'code' => -32_602, 'message' => 'Task already completed' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'Response value is invalid' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'No such task' } },
                         { 'error' => { 'code' => -32_602, 'message' => 'Invalid params' } }])

    expect { client.cancel_task('task-1') }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e).not_to be_a(MCPClient::Errors::TaskNotFound)
      expect(e.message).to include('already completed')
    }
    expect { client.update_task('task-1', { 'k1' => { 'action' => 'decline' } }) }
      .to raise_error(MCPClient::Errors::TaskError) { |e| expect(e).not_to be_a(MCPClient::Errors::TaskNotFound) }
    expect { client.cancel_task('task-1') }.to raise_error(MCPClient::Errors::TaskNotFound)
    expect { client.get_task('task-1') }.to raise_error(MCPClient::Errors::TaskNotFound)
  end
end

# --- round27 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, twenty-seventh round: a synchronous answer
# to call_tool_as_task is validated against the tool definition a mid-call
# HeaderMismatch refresh replaced, like call_tool; ttl_elapsed? tolerates a
# ttlMs too large for a Time.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 27' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def tool_with(required)
    MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                        output_schema: { 'type' => 'object', 'required' => required }, server: stdio)
  end

  it 'validates a synchronous call_tool_as_task answer against the refreshed tool' do
    loose = tool_with([])
    strict = tool_with(['b'])
    stdio.singleton_class.include(MCPClient::CalledToolDefinition)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    allow(stdio).to receive_messages(list_tools: [loose], modern?: true, ping: true,
                                     capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(stdio).to receive(:call_tool) do
      # A HeaderMismatch refresh replaced the definition while the call ran;
      # the attempt that was answered went out under the refreshed one, and
      # the transport records it as the HTTP transports do.
      allow(stdio).to receive(:list_tools).and_return([strict])
      stdio.send(:note_called_tool_definition, 'sync', strict)
      { 'content' => [], 'structuredContent' => {} }
    end
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   validate_structured_content: :strict)

    expect { client.call_tool_as_task('sync', {}) }.to raise_error(MCPClient::Errors::ValidationError)
  end

  it 'accepts a synchronous answer the refreshed tool allows' do
    strict = tool_with(['a'])
    loose = tool_with([])
    stdio.singleton_class.include(MCPClient::CalledToolDefinition)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    allow(stdio).to receive_messages(list_tools: [strict], modern?: true, ping: true,
                                     capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(stdio).to receive(:call_tool) do
      allow(stdio).to receive(:list_tools).and_return([loose])
      stdio.send(:note_called_tool_definition, 'sync', loose)
      { 'content' => [], 'structuredContent' => {} }
    end
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   validate_structured_content: :strict)

    expect(client.call_tool_as_task('sync', {})).to be_completed
  end

  it 'reports no TTL elapse for an overflowing ttlMs instead of raising' do
    now = Time.now.utc.iso8601
    task = MCPClient::Task.from_json({ 'taskId' => 't', 'status' => 'working', 'createdAt' => now,
                                       'lastUpdatedAt' => now, 'ttlMs' => 10**400 }, server: stdio)

    expect { task.ttl_elapsed? }.not_to raise_error
    expect(task.ttl_elapsed?).to be(false)
  end
end

# --- round29 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, twenty-ninth round: the session epoch the
# answers were produced in is carried through the whole update path, every
# task RPC of a wait is bounded by the wall clock (even on a transport that
# takes no timeout), and a TTL extension the clock cannot represent lifts the
# previous backstop instead of ending the wait early.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 29' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(ttl_ms: nil, poll_ms: 1)
    now = Time.now.utc.iso8601
    { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }
  end

  def detailed_task(status:, ttl_ms: nil, poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def tool_list
    { 'result' => { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }], 'ttlMs' => 60_000 } }
  end

  def call_result
    { 'content' => [{ 'type' => 'text', 'text' => 'done' }], 'isError' => false }
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

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  describe 'the session epoch is carried through the update path' do
    it 'drops the payload when the session restarts after the update obtained its state' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      # The restart lands between the caller's epoch check and the send.
      allow(client).to receive(:task_state).and_wrap_original do |m, *args|
        m.call(*args).tap { stdio.send(:bump_session_epoch) }
      end
      allow(stdio).to receive(:rpc_request)

      expect(client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch)).to be(true)

      expect(stdio).not_to have_received(:rpc_request)
      expect(client.send(:answered_task_keys, stdio, 't')).not_to include('k1')
    end

    it 'still sends the update when the session did not move' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request).and_return({})

      client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch)

      expect(stdio).to have_received(:rpc_request).with('tasks/update', hash_including(taskId: 't'))
    end

    it 'does not deliver answers under a session that started after they were checked' do
      output = StringIO.new
      answered = 0
      bumped = false
      client = client_for(stdio, logger: Logger.new(output), elicitation_handler: lambda { |_m, _s|
        answered += 1
        { action: 'accept', content: { 'n' => 'x' } }
      })
      # request_timeout reads the transport's read_timeout on the way into
      # deliver_task_update, i.e. after the wait compared the epoch and
      # before the update goes out: the restart is placed exactly there.
      allow(stdio).to receive(:read_timeout).and_wrap_original do |m, *args|
        if answered.positive? && !bumped
          bumped = true
          stdio.send(:bump_session_epoch)
        end
        m.call(*args)
      end
      updated = false
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                           lambda { |req|
                             case req['method']
                             when 'tasks/update'
                               updated = true
                               { 'result' => {} }
                             else
                               if updated
                                 { 'result' => detailed_task(status: 'completed', 'result' => call_result) }
                               else
                                 { 'result' => detailed_task(status: 'input_required',
                                                             'inputRequests' => { 'k1' => elicit_request }) }
                               end
                             end
                           }])

      # Nothing is written into the session that replaced the answers' own,
      # and the wait ends with the session the task belonged to (round 33).
      expect { client.call_tool('slow', {}) }
        .to raise_error(MCPClient::Errors::TaskError, /session it belongs to ended/i)
      expect(output.string).to include('session restarted')
      expect(answered).to eq(1)
    end
  end

  describe 'a wait bounds every task RPC by its wall clock' do
    def blocking_transport(gate)
      Class.new(MCPClient::ServerBase) do
        def initialize(gate)
          super(name: 'two-arg')
          @gate = gate
          @logger = Logger.new(File::NULL)
        end

        def connect = true # rubocop:disable Naming/PredicateMethod
        def capabilities = { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } }
        def modern? = true
        def protocol_version = '2026-07-28'
        def ping = {}

        # The documented transport interface: rpc_request(method, params).
        def rpc_request(_method, _params = {})
          @gate.pop
          {}
        end
      end.new(gate)
    end

    it 'times out a two-argument transport that never answers tasks/get' do
      gate = Queue.new
      transport = blocking_transport(gate)
      client = client_for(transport)
      started = monotonic

      expect { client.wait_for_task('task-1', server: transport, timeout: 0.3) }
        .to raise_error(MCPClient::Errors::TaskError, /Timed out/)
      expect(monotonic - started).to be < 3
    ensure
      gate << :done
    end
  end

  describe 'a TTL extension the clock cannot represent' do
    it 'lifts the previous backstop instead of ending the wait early' do
      client = client_for(stdio)
      allow(client).to receive(:sleep) { |s| Kernel.sleep(s) }
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list,
                           { 'result' => task_result(ttl_ms: 200) },
                           { 'result' => detailed_task(status: 'working', ttl_ms: 10**400, poll_ms: 400) },
                           { 'result' => detailed_task(status: 'completed', ttl_ms: 10**400, poll_ms: 400,
                                                       'result' => call_result) }])

      expect(client.call_tool('slow', {})['isError']).to be(false)
    end

    it 'keeps the last backstop when an observation carries no ttlMs at all' do
      client = client_for(stdio)
      wait = { task_id: 't', srv: stdio, ttl_deadline: 123.0, polled: true }
      task = MCPClient::Task.from_json({ 'taskId' => 't', 'status' => 'working', 'pollIntervalMs' => 1 })

      expect(task.ttl_reported?).to be(false)
      client.send(:bound_wait_by_ttl, task, wait)

      expect(wait[:ttl_deadline]).to eq(123.0)
    end

    it 'still lifts the backstop for an explicit ttlMs null' do
      client = client_for(stdio)
      wait = { task_id: 't', srv: stdio, ttl_deadline: 123.0, polled: true }
      task = MCPClient::Task.from_json({ 'taskId' => 't', 'status' => 'working', 'ttlMs' => nil })

      expect(task.ttl_reported?).to be(true)
      client.send(:bound_wait_by_ttl, task, wait)

      expect(wait[:ttl_deadline]).to be_nil
    end
  end
end

# --- round30 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, thirtieth round: the session epoch is
# enforced at the wire (the connection is established before the guard, so a
# reconnect inside rpc_request cannot slip an ended session's answers into the
# next one), a rejected update gives its keys back to the state it was built
# from, a wait refreshes its session before enforcing a TTL that belongs to the
# previous one, and an abandoned task RPC leaves the pending payload and the
# task's bookkeeping usable by the next wait.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 30' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(ttl_ms: nil, poll_ms: 1)
    now = Time.now.utc.iso8601
    { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }
  end

  def detailed_task(status:, ttl_ms: nil, poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def tool_list
    { 'result' => { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }], 'ttlMs' => 60_000 } }
  end

  def call_result
    { 'content' => [{ 'type' => 'text', 'text' => 'done' }], 'isError' => false }
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

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server)
    allow(server).to receive(:capabilities)
      .and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:modern?).and_return(true)
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  describe 'the epoch guard holds at the wire' do
    it 'drops the payload when establishing the connection restarted the session' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      # rpc_request calls ensure_initialized: a reconnect there bumps the
      # epoch inside the very call the guard was meant to protect.
      allow(stdio).to receive(:ensure_session_ready) { stdio.send(:bump_session_epoch) }
      allow(stdio).to receive(:rpc_request).and_return({})

      expect(client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch)).to be(true)

      expect(stdio).not_to have_received(:rpc_request)
      expect(client.send(:answered_task_keys, stdio, 't')).not_to include('k1')
    end

    it 'establishes the session before it compares the epoch' do
      client = client_for(stdio)
      calls = []
      allow(stdio).to receive(:ensure_session_ready) { calls << :ready }
      allow(stdio).to receive(:rpc_request) do
        calls << :sent
        {}
      end

      client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } },
                  epoch: client.send(:current_session_epoch, stdio))

      expect(calls).to eq(%i[ready sent])
    end
  end

  describe 'a rejected update releases the state it was built from' do
    it 'leaves the keys the new session answered alone' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request) do
        stdio.send(:bump_session_epoch)
        # The new session answered the same key for what is a new task.
        client.send(:remember_answered_keys, stdio, 't', ['k1'])
        raise MCPClient::Errors::ServerError.new('bad inputResponses', code: -32_602)
      end

      expect { client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch) }
        .to raise_error(MCPClient::Errors::TaskError)

      expect(client.send(:answered_task_keys, stdio, 't')).to include('k1')
    end

    it 'forgets only the bookkeeping the update captured when the task is reported gone' do
      client = client_for(stdio)
      epoch = client.send(:current_session_epoch, stdio)
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request) do
        stdio.send(:bump_session_epoch)
        client.send(:remember_answered_keys, stdio, 't', ['k1'])
        raise MCPClient::Errors::ServerError.new('task not found', code: -32_602)
      end

      expect { client.send(:send_task_update, stdio, 't', { 'k1' => { 'action' => 'accept' } }, epoch: epoch) }
        .to raise_error(MCPClient::Errors::TaskNotFound)

      expect(client.send(:answered_task_keys, stdio, 't')).to include('k1')
    end
  end

  describe 'a wait refreshes its session before enforcing a TTL' do
    it 'resets the session-scoped fields when the wait moves to a new session' do
      client = client_for(stdio)
      wait = { task_id: 't', srv: stdio, epoch: nil, answered: nil, ttl_deadline: nil, last: nil }
      client.send(:refresh_wait_session, wait)
      first = wait[:epoch]
      wait[:ttl_deadline] = monotonic + 5
      wait[:last] = :seed
      stdio.send(:bump_session_epoch)

      client.send(:refresh_wait_session, wait)

      expect(wait[:epoch]).to eq(first + 1)
      expect(wait[:ttl_deadline]).to be_nil
      expect(wait[:last]).to be_nil
    end

    it 'does not enforce the TTL backstop of a session that has ended' do
      client = client_for(stdio)
      wait = { task_id: 't', srv: stdio, epoch: client.send(:current_session_epoch, stdio), answered: Set.new,
               deadline: nil, ttl_deadline: monotonic - 1, last: :seed, polled: true }
      stdio.send(:bump_session_epoch)

      expect { client.send(:raise_if_past_deadline!, wait) }.not_to raise_error
      expect(wait[:ttl_deadline]).to be_nil
    end

    it 'ends on the session that is over rather than on the ended session TTL' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |wait|
        polls += 1
        wait[:polled] = true
        # The poll timed out; the server restarted while it was outstanding.
        wait[:ttl_deadline] = monotonic - 1
        stdio.send(:bump_session_epoch)
        nil
      end

      # The stale backstop is dropped all the same — what ends the wait is the
      # session the task belonged to being over, not a TTL it no longer has
      # (round 33: the reused id is never polled in the new session).
      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /session it belongs to ended/i)
      expect(polls).to eq(1)
    end
  end

  describe 'an abandoned task RPC keeps the bookkeeping usable' do
    it 'retransmits the answers of an abandoned update without asking the host again' do
      gate = Queue.new
      answered = 0
      updates = 0
      updated = false
      client = client_for(stdio, elicitation_handler: lambda { |_message, _schema|
        answered += 1
        { action: 'accept', content: { 'n' => 'x' } }
      })
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                           lambda { |req|
                             if req['method'] == 'tasks/update'
                               updates += 1
                               gate.pop if updates == 1
                               updated = true
                               next { 'result' => {} }
                             end
                             if updated
                               { 'result' => detailed_task(status: 'completed', 'result' => call_result) }
                             else
                               { 'result' => detailed_task(status: 'input_required',
                                                           'inputRequests' => { 'k1' => elicit_request }) }
                             end
                           }])

      task = client.call_tool_as_task('slow', {})
      expect { client.wait_for_task(task, timeout: 0.3) }
        .to raise_error(MCPClient::Errors::TaskError, /Timed out/)
      expect(answered).to eq(1)

      expect(client.wait_for_task(task, timeout: 2).status).to eq('completed')
      expect(answered).to eq(1)
      expect(updates).to be >= 2
    ensure
      gate << :done
    end

    it 'lets a late forget from an abandoned request leave a reused task id alone' do
      client = client_for(stdio)
      abandoned = client.send(:task_state, stdio, 'task-1')
      # The wait ended; a new lifetime of the same id starts and is answered.
      client.send(:forget_task_keys, stdio, 'task-1')
      fresh = client.send(:task_state, stdio, 'task-1')
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])

      client.send(:forget_task_keys, stdio, 'task-1', state: abandoned)

      expect(client.send(:task_state, stdio, 'task-1')).to equal(fresh)
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end

    it 'does not drop a reused task id bookkeeping when an abandoned poll comes back terminal' do
      client = client_for(stdio)
      negotiated(stdio)
      # The bookkeeping below belongs to the session this transport is in:
      # establishing one is what a real call does before recording anything,
      # and a session that came up meanwhile would (rightly) retire it.
      allow(stdio).to receive(:ensure_session_ready)
      abandoned = client.send(:task_state, stdio, 'task-1')
      client.send(:forget_task_keys, stdio, 'task-1')
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      allow(stdio).to receive(:rpc_request)
        .and_return(detailed_task(status: 'completed', 'result' => call_result))

      client.get_task('task-1', server: stdio, state: abandoned)

      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end
  end
end

# --- round32 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, thirty-second round: every task request is
# pinned to the session it belongs to (tasks/get and the explicit
# tasks/update / tasks/cancel of a handle, not only the wait's updates), what
# a session answered stays that session's (round 33 settled that a terminal
# payload the wait's own session answered is the outcome, and that the
# replacement session is never polled for the reused id), and no bookkeeping
# of the session that replaced the one a request belongs to is forgotten on
# its behalf.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 32' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def detailed_task(status:, ttl_ms: nil, poll_ms: 1, created_at: nil, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => created_at || now,
      'lastUpdatedAt' => now, 'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'Deploy to production?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def task_from(hash)
    MCPClient::Task.from_json(hash, server: stdio, detailed: true)
  end

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server)
    allow(server).to receive(:capabilities)
      .and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:modern?).and_return(true)
  end

  def accepting_client(server, &counter)
    client_for(server, elicitation_handler: lambda { |_message, _schema|
      counter&.call
      { action: 'accept', content: { 'n' => 'x' } }
    })
  end

  # A transport whose session ends inside rpc_request, the way a lazy
  # ensure_initialized / ensure_connected reconnect does.
  def reconnecting_transport(server, result: {})
    sent = []
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response).and_return({ 'jsonrpc' => '2.0', 'id' => 1, 'result' => result })
    allow(server).to receive(:ensure_initialized) { server.send(:bump_session_epoch) }
    sent
  end

  def wait_for(client, task_id: 'task-1')
    wait = { task_id: task_id, srv: stdio, deadline: nil, ttl_deadline: nil,
             answered: nil, state: nil, epoch: nil, last: nil }
    client.send(:refresh_wait_session, wait)
    wait
  end

  describe 'a poll pinned to the session the wait joined' do
    it 'writes no tasks/get once a reconnect inside rpc_request ended the session' do
      client = client_for(stdio)
      negotiated(stdio)
      wait = wait_for(client)
      sent = reconnecting_transport(stdio, result: detailed_task(status: 'completed', 'result' => call_result))

      expect(client.send(:poll_task, wait)).to be_nil
      expect(sent).to be_empty
    end

    # The session does not move here (the epoch is the same before and
    # after): what is pinned is that a poll the transport refused as a
    # SessionChangedError is a lost poll, polled again — the wait ending on
    # a session that did move is pinned by the epoch-changing examples.
    it 'polls again after a poll the transport refused, when the session did not move' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:get_task) do
        polls += 1
        raise MCPClient::Errors::SessionChangedError, 'session 0 is over' if polls == 1

        task_from(detailed_task(status: 'completed', 'result' => call_result))
      end

      expect(client.wait_for_task('task-1', server: stdio, timeout: 2).status).to eq('completed')
      expect(polls).to eq(2)
    end
  end

  # Round 33 settled which side of a session move a terminal payload belongs
  # to: the poll was pinned to the wait's own session, so what came back is
  # this task's outcome; the session that replaced it is never asked about
  # the reused id.
  describe 'a session that ends around a terminal observation' do
    it 'returns the payload the wait own session answered' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        observation = task_from(detailed_task(status: 'completed', 'result' => call_result('this task')))
        stdio.send(:bump_session_epoch)
        observation
      end

      result = client.wait_for_task('task-1', server: stdio, timeout: 2)
      expect(result.result).to eq(call_result('this task'))
      expect(polls).to eq(1)
    end

    it 'raises no failure of another lifetime of the task id' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        observation = task_from(detailed_task(status: 'failed',
                                              'error' => { 'code' => -32_000, 'message' => 'this task' }))
        stdio.send(:bump_session_epoch)
        observation
      end

      # The failure the wait's own session reported, and no poll of the id in
      # the session that replaced it (whose task-1 may be anything at all).
      expect(client.wait_for_task('task-1', server: stdio, timeout: 2).error['message']).to eq('this task')
      expect(polls).to eq(1)
    end

    it 'forgets nothing of the session that replaced it' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        observation = task_from(detailed_task(status: 'completed', 'result' => call_result))
        stdio.send(:bump_session_epoch)
        client.send(:remember_answered_keys, stdio, 'task-1', ['k9'])
        observation
      end

      expect(client.wait_for_task('task-1', server: stdio, timeout: 2).status).to eq('completed')
      expect(polls).to eq(1)
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k9')
    end
  end

  describe 'input requests of a session that ended while an update was retransmitted' do
    it 'never reaches the host handlers' do
      asked = 0
      client = accepting_client(stdio) { asked += 1 }
      negotiated(stdio)
      # The retransmission is a full tasks/update RPC: the child may die under it.
      allow(client).to receive(:retransmit_pending_update) { stdio.send(:bump_session_epoch) }
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        if polls == 1
          task_from(detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }))
        else
          task_from(detailed_task(status: 'completed', 'result' => call_result))
        end
      end

      # The session did not survive the round trip, and neither does the
      # wait: the task is gone with it (round 33).
      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /session it belongs to ended/i)
      expect(asked).to eq(0)
      expect(polls).to eq(1)
    end
  end

  describe 'a terminal task handle kept across a restart' do
    it 'does not forget the replacement session bookkeeping for the reused id' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = task_from(detailed_task(status: 'completed', 'result' => call_result))
      stdio.send(:bump_session_epoch)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k9'])

      expect(client.wait_for_task(handle).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k9')
    end

    it 'still forgets its own session bookkeeping' do
      client = client_for(stdio)
      negotiated(stdio)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      handle = task_from(detailed_task(status: 'completed', 'result' => call_result))

      expect(client.wait_for_task(handle).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
    end
  end

  describe 'an explicit request for a task handle' do
    def modern_handle(status: 'working')
      MCPClient::Task.new(task_id: 'task-1', status: status, server: stdio, modern: true)
    end

    it 'refuses an update whose handle belongs to a session that has ended' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = modern_handle
      stdio.send(:bump_session_epoch)
      allow(stdio).to receive(:rpc_request)

      expect { client.update_task(handle, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(stdio).not_to have_received(:rpc_request)
    end

    it 'writes no tasks/update when a reconnect inside rpc_request ends the handle session' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = modern_handle
      sent = reconnecting_transport(stdio)

      # Nothing went out, and the caller that asked for this delivery is told
      # so (round 34): a silent true would leave the host believing the
      # server has answers it never received.
      expect { client.update_task(handle, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(sent).to be_empty
    end

    it 'refuses a cancellation whose handle belongs to a session that has ended' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = modern_handle
      stdio.send(:bump_session_epoch)
      allow(stdio).to receive(:rpc_request)

      expect { client.cancel_task(handle) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(stdio).not_to have_received(:rpc_request)
    end

    it 'writes no tasks/cancel when a reconnect inside rpc_request ends the handle session' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = modern_handle
      sent = reconnecting_transport(stdio)

      expect { client.cancel_task(handle) }.to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(sent).to be_empty
    end

    it 'still cancels a task named by a bare id' do
      client = client_for(stdio)
      negotiated(stdio)
      allow(stdio).to receive(:rpc_request).and_return({})

      expect(client.cancel_task('task-1').status).to eq('working')
      expect(stdio).to have_received(:rpc_request).with('tasks/cancel', { taskId: 'task-1' })
    end
  end
end

# --- round34 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, thirty-fourth round: a task handle carries
# the session its request was pinned to (not whatever session is live when the
# handle happens to be built), the HTTP session id a request was cleared for is
# the one that goes on the wire, and an HTTP 404 moves the session epoch the
# moment it ends the session — not only once a replacement handshake succeeded.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 34' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }
  let(:url) { "#{base_url}#{endpoint}" }
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def detailed_task(status:, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def stdio_client
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
    allow(client).to receive(:sleep)
    allow(stdio).to receive(:capabilities).and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(stdio).to receive(:modern?).and_return(true)
    # The session is brought up before it is sampled; no child process here.
    allow(stdio).to receive(:ensure_initialized)
    client
  end

  def wait_joined_on(client, srv)
    wait = { task_id: 'task-1', srv: srv, deadline: nil, ttl_deadline: nil,
             answered: nil, state: nil, epoch: nil, last: nil }
    client.send(:refresh_wait_session, wait)
    wait
  end

  describe 'a handle built after the session that answered the request ended' do
    it 'carries the session the request was pinned to, not the one that replaced it' do
      client = stdio_client
      allow(stdio).to receive(:rpc_request) do
        # The answer is in hand; the child then exits and the successor
        # session starts before the handle is built.
        stdio.send(:bump_session_epoch)
        detailed_task(status: 'completed', 'result' => call_result)
      end

      task = client.get_task('task-1', server: stdio)

      expect(task.session_epoch).to eq(0)
    end

    it 'refuses the terminal handle a wait returned in the session that replaced its own' do
      client = stdio_client
      allow(stdio).to receive(:rpc_request) do
        stdio.send(:bump_session_epoch)
        detailed_task(status: 'completed', 'result' => call_result('this task'))
      end

      task = client.wait_for_task('task-1', server: stdio, timeout: 2)

      expect(task.result).to eq(call_result('this task'))
      expect(task.session_epoch).to eq(0)
      # The successor session may have reused the id: the handle is refused
      # rather than describing whatever it named task-1.
      expect { client.get_task(task) }.to raise_error(MCPClient::Errors::TaskError, /session/i)
    end

    it 'does not take a terminal payload of another session as the wait outcome' do
      client = stdio_client
      allow(client).to receive(:poll_task) do |w|
        w[:polled] = true
        stdio.send(:bump_session_epoch)
        # A payload stamped with the successor session (a poll the transport
        # could not vouch for): it is not this wait's task.
        MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => call_result),
                                  server: stdio, detailed: true, session_epoch: stdio.session_epoch)
      end

      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /session it belongs to ended/i)
    end
  end

  describe 'public task operations and a session that ended under them' do
    it 'reports a refused tasks/get as a task error' do
      client = stdio_client
      allow(stdio).to receive(:rpc_request).and_raise(MCPClient::Errors::SessionChangedError, 'session 0 is over')

      expect { client.get_task('task-1', server: stdio) }.to raise_error(MCPClient::Errors::TaskError, /session/i)
    end

    it 'still hands a poll the raw session signal' do
      client = stdio_client
      wait = wait_joined_on(client, stdio)
      allow(stdio).to receive(:rpc_request).and_raise(MCPClient::Errors::SessionChangedError, 'session 0 is over')

      expect(client.send(:poll_task, wait)).to be_nil
    end

    it 'reports answers the pin dropped as a failed update_task' do
      client = stdio_client
      allow(stdio).to receive(:rpc_request).and_raise(MCPClient::Errors::SessionChangedError, 'session 0 is over')

      expect { client.update_task('task-1', { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
    end
  end

  describe 'the HTTP session a request was cleared for' do
    def initialize_result
      { 'protocolVersion' => '2025-11-25',
        'capabilities' => { 'tools' => {}, 'tasks' => { 'get' => true, 'list' => true, 'cancel' => true } },
        'serverInfo' => { 'name' => 's', 'version' => '1' } }
    end

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: :legacy,
                                          name: 'sess-test')
    end

    after { server.cleanup }

    # A server that hands out a session per handshake; `expired` names the
    # session it answers with the 404 that ends it, and `handshakes` bounds
    # how many handshakes succeed (a later one fails, as a server under load
    # would answer it).
    def stub_streamable(sent:, results: {}, expired: nil, handshakes: nil)
      sessions = 0
      stub_request(:get, url).to_return(status: 200, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        method = body['method']
        sent << [method, request.headers['Mcp-Session-Id']]
        if method == 'initialize'
          sessions += 1
          next { status: 503, body: 'overloaded' } if handshakes && sessions > handshakes

          json_response(body['id'], initialize_result)
            .tap { |r| r[:headers]['Mcp-Session-Id'] = "sess-#{sessions}" }
        elsif method.start_with?('notifications/')
          { status: 202, body: '' }
        elsif expired && request.headers['Mcp-Session-Id'] == expired
          { status: 404, body: 'session gone' }
        else
          json_response(body['id'], results.fetch(method, {}))
        end
      end
    end

    def client_for(srv)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: base_url }],
                                     extensions: [TASKS_EXT])
      allow(client).to receive(:sleep)
      client
    end

    it 'puts the captured session id on the wire after a concurrent recovery cleared it' do
      sent = []
      stub_streamable(sent: sent, results: { 'tasks/get' => { 'taskId' => 'task-1', 'status' => 'working' } })
      server.connect
      # A concurrent 404 recovery nils @session_id while this request is
      # already being written; the header must still be the captured one.
      allow(server).to receive(:apply_request_headers).and_wrap_original do |original, req, request|
        server.instance_variable_set(:@session_id, nil) if request['method'] == 'tasks/get'
        original.call(req, request)
      end

      server.rpc_request('tasks/get', { taskId: 'task-1' })

      expect(sent).to include(['tasks/get', 'sess-1'])
    end

    it 'moves the session epoch when the 404 ends the session, not when the replacement is up' do
      sent = []
      stub_streamable(sent: sent, results: {}, expired: 'sess-1', handshakes: 1)
      server.connect
      epoch = server.session_epoch

      expect { server.rpc_request('tasks/get', { taskId: 'task-1' }) }.to raise_error(MCPClient::Errors::MCPError)

      expect(server.session_epoch).to be > epoch
      expect(sent.count { |method, _| method == 'initialize' }).to eq(2)
    end

    it 'refuses a task handle of the session a failed replacement handshake left behind' do
      sent = []
      stub_streamable(sent: sent, results: {}, expired: 'sess-1', handshakes: 1)
      client = client_for(server)
      server.connect
      handle = MCPClient::Task.new(task_id: 'task-1', status: 'working', server: server)

      expect { server.rpc_request('tasks/get', { taskId: 'task-1' }) }.to raise_error(MCPClient::Errors::MCPError)

      expect { client.get_task(handle) }.to raise_error(MCPClient::Errors::TaskError, /session/i)
    end

    it 'does not replay a bare-id task request into the session that replaced its own' do
      sent = []
      stub_streamable(sent: sent, results: { 'tasks/get' => { 'taskId' => 'task-1', 'status' => 'working' } },
                      expired: 'sess-1')
      client = client_for(server)
      server.connect

      expect { client.get_task('task-1') }.to raise_error(MCPClient::Errors::TaskError, /session/i)

      expect(sent.count { |method, _| method == 'tasks/get' }).to eq(1)
      expect(sent.count { |method, _| method == 'initialize' }).to eq(2)
    end
  end

  describe 'the tool definition a task result is validated against' do
    def tool_with(required)
      MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                          output_schema: { 'type' => 'object', 'required' => required }, server: stdio)
    end

    def create_task_result
      now = Time.now.utc.iso8601(3)
      { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
        'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }
    end

    def strict_client
      allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                     validate_structured_content: :strict)
      allow(client).to receive(:sleep)
      client
    end

    # A tools/list_changed refresh that has nothing to do with this call
    # lands while its task is being polled.
    def refresh_during_wait(client, generation, strict)
      allow(client).to receive(:wait_for_task) do
        generation.call
        allow(stdio).to receive(:list_tools).and_return([strict])
        MCPClient::Task.from_json({ 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => 'completed',
                                    'ttlMs' => nil,
                                    'result' => { 'content' => [], 'structuredContent' => {} } },
                                  server: stdio, detailed: true)
      end
    end

    before do
      allow(stdio).to receive_messages(list_tools: [tool_with([])], modern?: true, ping: true,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    end

    it 'validates a polled task result against the definition the call was answered under' do
      generation = 1
      stdio.define_singleton_method(:tools_generation) { generation }
      allow(stdio).to receive(:call_tool).and_return(create_task_result)
      client = strict_client
      refresh_during_wait(client, -> { generation = 2 }, tool_with(['b']))

      expect(client.call_tool('sync', {})).to eq({ 'content' => [], 'structuredContent' => {} })
    end

    it 'validates a streamed task result against the definition the chunk arrived under' do
      generation = 1
      stdio.define_singleton_method(:tools_generation) { generation }
      allow(stdio).to receive(:call_tool_streaming).and_return([create_task_result].each)
      client = strict_client
      refresh_during_wait(client, -> { generation = 2 }, tool_with(['b']))

      expect(client.call_tool_streaming('sync', {}).to_a)
        .to eq([{ 'content' => [], 'structuredContent' => {} }])
    end
  end
end

# --- round36 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, thirty-sixth review round:
#
# - A task id a fresh CreateTaskResult hands out again inside one session is a
#   new task. Its bookkeeping is a new lifetime: the in-flight holds of the
#   previous one no longer suppress its input requests, a wait still following
#   the previous one ends instead of reporting the new task's outcome, and the
#   answers the previous one produced are never delivered to it.
# - Ending a connection is not ending a session. An MCP 2026-07-28 HTTP
#   transport is sessionless (no initialize handshake, no Mcp-Session-Id), so
#   a task lives in the server's own id namespace for its ttlMs and survives a
#   cleanup/reconnect together with its answered keys and its pending update.
#   A legacy session — one a handshake opened — still ends with the connection.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 36' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def detailed_task(status:, poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def create_result
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'ok?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def task_from(hash, server: stdio)
    MCPClient::Task.from_json(hash, server: server, detailed: true)
  end

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server)
    allow(server).to receive(:capabilities).and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:modern?).and_return(true)
  end

  def wait_for(client, task_id: 'task-1', srv: stdio)
    wait = { task_id: task_id, srv: srv, deadline: nil, ttl_deadline: nil,
             answered: nil, state: nil, epoch: nil, last: nil }
    client.send(:refresh_wait_session, wait)
    wait
  end

  # The server hands out the very same task id again, in the session the wait
  # is in: a new CreateTaskResult, so a new task.
  def reuse_task_id(client, srv: stdio, epoch: nil)
    client.send(:created_task, create_result, srv, epoch || client.send(:current_session_epoch, srv))
  end

  describe 'a task id a fresh CreateTaskResult takes over inside one session' do
    it 'presents the new task its input requests, though the previous lifetime still holds the keys' do
      client = client_for(stdio)
      negotiated(stdio)
      requests = { 'k1' => elicit_request }
      task = task_from(detailed_task(status: 'input_required', 'inputRequests' => requests))
      previous = client.send(:task_state, stdio, 'task-1')
      # A handler of the previous task is still presenting k1 to the host.
      client.send(:reserve_input_requests, task, requests, previous[:answered], stdio, previous)

      reuse_task_id(client)

      current = client.send(:task_state, stdio, 'task-1')
      pending, = client.send(:reserve_input_requests, task, requests, current[:answered], stdio, current)
      expect(pending.keys).to eq(['k1'])
    end

    it 'keeps the previous lifetime hold under its own registry entry' do
      client = client_for(stdio)
      negotiated(stdio)
      requests = { 'k1' => elicit_request }
      task = task_from(detailed_task(status: 'input_required', 'inputRequests' => requests))
      previous = client.send(:task_state, stdio, 'task-1')
      client.send(:reserve_input_requests, task, requests, previous[:answered], stdio, previous)

      reuse_task_id(client)
      current = client.send(:task_state, stdio, 'task-1')

      expect(current[:key]).not_to eq(previous[:key])
      expect(client.send(:in_flight_task_keys, stdio, 'task-1', key: previous[:key])).to include('k1')
      expect(client.send(:in_flight_task_keys, stdio, 'task-1', key: current[:key])).to be_empty
    end

    it 'ends a wait whose task id the new task took over instead of reporting its outcome' do
      client = client_for(stdio)
      negotiated(stdio)
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        reuse_task_id(client) if polls == 1
        task_from(detailed_task(status: 'working'))
      end

      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /replaced/i)
      expect(polls).to eq(1)
    end

    it 'does not hand the new task a terminal payload polled for the previous one' do
      client = client_for(stdio)
      negotiated(stdio)
      allow(client).to receive(:poll_task) do |w|
        w[:polled] = true
        reuse_task_id(client)
        task_from(detailed_task(status: 'completed', 'result' => { 'content' => [], 'isError' => false }))
      end

      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /replaced/i)
    end

    it 'discards answers the previous lifetime produced rather than updating the new task' do
      client = client_for(stdio)
      negotiated(stdio)
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }
      wait = wait_for(client)
      task = task_from(detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }))
      allow(stdio).to receive(:fulfil_input_requests) do |pending, _task|
        # The server handed the id out again while the host was answering.
        reuse_task_id(client)
        pending.transform_values { { 'action' => 'accept', 'content' => { 'n' => 'x' } } }
      end

      expect(client.send(:answer_task_input_requests, task, wait[:answered], stdio, wait)).to eq([])
      expect(sent).to be_empty
    end

    it 'refuses a tasks/update built in a lifetime the id no longer has' do
      client = client_for(stdio)
      negotiated(stdio)
      sent = []
      allow(stdio).to receive(:ensure_session_ready)
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }
      state = client.send(:task_state, stdio, 'task-1')
      client.send(:queue_task_update, state, { 'k1' => { 'action' => 'accept' } })

      reuse_task_id(client)

      client.send(:send_task_update, stdio, 'task-1', nil, pending_only: true, state: state,
                                                           epoch: client.send(:current_session_epoch, stdio))
      expect(sent).to be_empty
    end

    it 'refuses to wait on a handle of the task the new one replaced' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = client.send(:created_task, create_result, stdio, client.send(:current_session_epoch, stdio))
      # A wait puts the id on the books, so the next creation is a reuse.
      wait_for(client)

      replacement = reuse_task_id(client)

      expect { client.wait_for_task(handle, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
      expect(replacement.task_generation).to eq(handle.task_generation + 1)
    end

    it 'refuses an explicit tasks/update for a handle of the task the new one replaced' do
      client = client_for(stdio)
      negotiated(stdio)
      handle = client.send(:created_task, create_result, stdio, client.send(:current_session_epoch, stdio))
      wait_for(client)

      reuse_task_id(client)

      expect { client.update_task(handle, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'takes a handle of the lifetime the id has now' do
      client = client_for(stdio)
      negotiated(stdio)
      wait_for(client)
      handle = reuse_task_id(client)
      allow(client).to receive(:poll_task) do |w|
        w[:polled] = true
        task_from(detailed_task(status: 'completed', 'result' => { 'content' => [], 'isError' => false }))
      end

      expect(client.wait_for_task(handle, timeout: 2).status).to eq('completed')
    end

    it 'leaves a first creation of an unseen task id at its first lifetime' do
      client = client_for(stdio)
      negotiated(stdio)

      reuse_task_id(client)

      expect(client.send(:task_state, stdio, 'task-1')[:generation]).to eq(0)
    end
  end

  describe 'a cleanup that ends only the connection' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }

    def discover_result
      { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
        'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } },
        '_meta' => { 'io.modelcontextprotocol/serverInfo' => { 'name' => 'modern', 'version' => '1' } } }
    end

    def initialize_result
      { 'protocolVersion' => '2025-11-25',
        'capabilities' => { 'tools' => {}, 'tasks' => { 'get' => true, 'cancel' => true } },
        'serverInfo' => { 'name' => 'legacy', 'version' => '1' } }
    end

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    def stub_modern
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        json_response(body['id'], body['method'] == 'server/discover' ? discover_result : {})
      end
    end

    def stub_legacy
      stub_request(:get, url).to_return(status: 200, body: '')
      stub_request(:delete, url).to_return(status: 200, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next({ status: 202, body: '' }) if body['method'].to_s.start_with?('notifications/')

        response = json_response(body['id'], body['method'] == 'initialize' ? initialize_result : {})
        response[:headers]['Mcp-Session-Id'] = 'sess-1' if body['method'] == 'initialize'
        response
      end
    end

    def streamable(protocol)
      MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: protocol,
                                          name: 'cleanup-test')
    end

    def plain_http(protocol)
      MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: protocol,
                                name: 'cleanup-test')
    end

    def tool_list
      { 'tools' => [{ 'name' => 'slow', 'description' => 'd', 'inputSchema' => { 'type' => 'object' } }] }
    end

    # A sessionless 2026-07-28 Streamable HTTP server that turns tools/call
    # into a task and answers its polls: one input request, then the result.
    # Every creation hands out the same id — a server may name a new task
    # with the id of one that is over.
    def streamable_task_server
      @sent = []
      polls = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        @sent << body
        result = case body['method']
                 when 'server/discover' then discover_result
                 when 'tools/list' then tool_list
                 when 'tools/call' then create_result.merge('pollIntervalMs' => 1000)
                 when 'tasks/get'
                   polls += 1
                   if polls > 2
                     detailed_task(status: 'completed', poll_ms: 1000,
                                   'result' => { 'content' => [], 'isError' => false })
                   else
                     detailed_task(status: 'input_required', poll_ms: 1000,
                                   'inputRequests' => { 'k1' => elicit_request })
                   end
                 else {}
                 end
        json_response(body['id'], result)
      end
      streamable(:modern)
    end

    # What the client actually put on the wire.
    def sent_methods(method)
      (@sent || []).select { |request| request['method'] == method }
    end

    # A wait whose clock only moves when the client sleeps: one poll, then
    # the budget is gone.
    def fake_clock(client)
      now = 0.0
      allow(client).to receive(:monotonic_time) { now }
      allow(client).to receive(:sleep) { |seconds| now += seconds }
    end

    it 'leaves the session epoch alone for a sessionless 2026-07-28 streamable transport' do
      stub_modern
      server = streamable(:modern)
      server.connect
      epoch = server.session_epoch

      server.cleanup

      expect(server).to be_modern
      expect(server.session_epoch).to eq(epoch)
    end

    it 'leaves the session epoch alone for a sessionless 2026-07-28 HTTP transport' do
      stub_modern
      server = plain_http(:modern)
      server.connect
      epoch = server.session_epoch

      server.cleanup

      expect(server.session_epoch).to eq(epoch)
    end

    it 'still ends the session a legacy handshake opened' do
      stub_legacy
      server = streamable(:legacy)
      server.connect
      epoch = server.session_epoch

      server.cleanup

      expect(server.session_epoch).to be > epoch
    end

    it 'answers an input request once across a sessionless reconnect' do
      handled = 0
      client = client_for(streamable_task_server,
                          elicitation_handler: lambda { |_m, _s|
                            handled += 1
                            { action: 'accept', content: { 'n' => 'x' } }
                          })
      handle = client.call_tool_as_task('slow', {})
      # The first wait answers k1 and then runs out of budget: the poll
      # interval the server asks for is longer than what is left of it.
      fake_clock(client)
      expect { client.wait_for_task(handle, timeout: 0.5) }
        .to raise_error(MCPClient::Errors::TaskError, /timed out/i)
      expect(handled).to eq(1)

      handle.server.cleanup

      # The connection ended, the session did not: the second wait sees the
      # very same k1 and must not answer it again.
      expect(client.wait_for_task(handle)).to be_completed
      expect(handled).to eq(1)
      expect(sent_methods('tasks/update').size).to eq(1)
    end

    it 'keeps a creation-stamped handle usable after a sessionless reconnect' do
      client = client_for(streamable_task_server)
      handle = client.call_tool_as_task('slow', {})

      client.cleanup

      # Nothing has taken the id: the task is still the server's, and the
      # handle still names it.
      expect(client.get_task(handle).task_id).to eq('task-1')
      expect(sent_methods('tasks/get').size).to eq(1)
    end

    it 'refuses a handle whose task id a creation reused after a client cleanup' do
      client = client_for(streamable_task_server)
      handle = client.call_tool_as_task('slow', {})

      client.cleanup

      # The task expired and the server handed the id to another one. The
      # lifetime numbers of a session never restart, so the replacement is
      # not what the old handle names.
      replacement = client.call_tool_as_task('slow', {})
      expect(replacement.task_generation).not_to eq(handle.task_generation)
      expect { client.cancel_task(handle) }.to raise_error(MCPClient::Errors::TaskReplacedError)
      expect(sent_methods('tasks/cancel')).to be_empty
      # And the guard is not simply refusing everything: the task the id
      # names now is cancellable through its own handle.
      expect(client.cancel_task(replacement).status).to eq('working')
      expect(sent_methods('tasks/cancel').size).to eq(1)
    end
  end
end

# --- round37 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, thirty-seventh review round:
#
# - Every observed creation under a task id starts a lifetime of its own, even
#   when nothing of the previous one is on the books any more, and every handle
#   a creation or a tasks/get hands out names the lifetime it belongs to.
# - A task-producing tools/call is written into the session it was sampled for
#   and into no other.
# - The bookkeeping cleanups are bounded: a rejected update gives back only what
#   it still owns, a request through a transport that takes no timeout is
#   bounded on the wall clock, and answers whose task another waiter already
#   saw gone are not delivered.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 37' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def create_result(**extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def detailed_task(status:, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  # A definite JSON-RPC rejection: the server answered and did not take it.
  def invalid_params(message)
    MCPClient::Errors::ServerError.new(message, code: MCPClient::Errors::Codes::INVALID_PARAMS)
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'ok?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def client_for(server = stdio, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server = stdio)
    allow(server).to receive(:capabilities).and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:modern?).and_return(true)
    allow(server).to receive(:ensure_session_ready)
  end

  # One CreateTaskResult, as the server would answer it in the live session.
  def creation(client, srv: stdio, result: nil)
    client.send(:created_task, result || create_result, srv, client.send(:current_session_epoch, srv))
  end

  def wait_joined(client, task_id: 'task-1', srv: stdio)
    wait = { task_id: task_id, srv: srv, deadline: nil, ttl_deadline: nil,
             answered: nil, state: nil, epoch: nil, last: nil }
    client.send(:refresh_wait_session, wait)
    wait
  end

  def task_tool(name: 'sync', task_support: nil)
    MCPClient::Tool.new(name: name, description: 'd', schema: { 'type' => 'object' }, server: stdio,
                        task_support: task_support)
  end

  # A transport that implements only the documented two-argument
  # rpc_request(method, params): no timeout keyword, and its own session pin.
  def two_arg_server(gate = nil)
    Class.new do
      include MCPClient::SessionPin

      attr_accessor :session_epoch
      attr_reader :sent

      def initialize(gate)
        @gate = gate
        @session_epoch = 0
        @sent = 0
      end

      def name
        'two-arg'
      end

      def rpc_request(_method, _params)
        @sent += 1
        check_session_pin!
        @gate ? @gate.pop : {}
      end
    end.new(gate)
  end

  describe 'a lifetime for every creation under a task id' do
    it 'gives two creations with no wait between them distinct lifetimes' do
      client = client_for
      negotiated

      first = creation(client)
      second = creation(client)

      expect(second.task_generation).to eq(first.task_generation + 1)
    end

    it 'refuses an update built for the task a second creation replaced' do
      client = client_for
      negotiated
      allow(client).to receive(:task_rpc)
      first = creation(client)

      creation(client)

      expect { client.update_task(first, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'refuses to cancel the task a second creation replaced' do
      client = client_for
      negotiated
      allow(client).to receive(:task_rpc)
      first = creation(client)

      creation(client)

      expect { client.cancel_task(first) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'starts a new lifetime for a creation made after the previous task was forgotten' do
      client = client_for
      negotiated
      first = creation(client)
      client.send(:task_state, stdio, 'task-1')
      # A terminal poll (or a TTL expiry) dropped everything the id had.
      client.send(:forget_task_keys, stdio, 'task-1')

      second = creation(client)

      expect(second.task_generation).to eq(first.task_generation + 1)
    end

    it 'leaves the very first creation of an unseen id at its first lifetime' do
      client = client_for
      negotiated

      first = creation(client)

      expect(first.task_generation).to eq(0)
      expect(client.send(:task_state, stdio, 'task-1')[:generation]).to eq(0)
    end

    it 'binds a legacy call_tool_as_task handle to the task it named' do
      allow(stdio).to receive_messages(
        list_tools: [task_tool(name: 'slow', task_support: 'optional')], modern?: false,
        capabilities: { 'tools' => {}, 'tasks' => { 'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request).and_return(create_result)
      client = client_for

      first = client.call_tool_as_task('slow', {})
      second = client.call_tool_as_task('slow', {})

      expect(first.task_generation).to eq(0)
      expect(second.task_generation).to eq(1)
    end
  end

  describe 'the lifetime counters a long-lived session accumulates' do
    let(:cap) { MCPClient::Client::TaskRegistry::MAX_TRACKED_TASK_LIFETIMES }

    it 'bounds how many task ids it keeps a counter for' do
      client = client_for
      negotiated

      # Tasks that ran and ended: what a prune may forget is the lifetime of
      # an id whose task this client no longer tracks.
      (cap + 1).times do |i|
        creation(client, result: create_result('taskId' => "task-#{i}"))
        client.send(:forget_task_keys, stdio, "task-#{i}")
      end

      expect(client.instance_variable_get(:@task_lifetimes).size).to be <= cap
    end

    it 'never drops the counter of a task whose bookkeeping is still live' do
      client = client_for
      negotiated
      creation(client)
      creation(client)
      live = client.send(:task_state, stdio, 'task-1')

      (cap + 1).times { |i| creation(client, result: create_result('taskId' => "other-#{i}")) }

      expect(live[:generation]).to eq(1)
      expect(client.send(:task_lifetime_current?, live)).to be(true)
    end
  end

  describe 'the lifetime a tasks/get keeps' do
    it 'stamps a refreshed handle with the lifetime of the handle it was asked for' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working'))

      refreshed = client.get_task(handle)

      expect(refreshed.task_generation).to eq(handle.task_generation)
    end

    it 'refuses an update through a refreshed handle once the id was handed out again' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working'))
      refreshed = client.get_task(handle)

      creation(client)

      expect { client.update_task(refreshed, { 'k1' => { 'action' => 'accept' } }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'leaves a handle for a bare task id naming whatever the id means now' do
      client = client_for
      negotiated
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working'))

      expect(client.get_task('task-1', server: stdio).task_generation).to be_nil
    end
  end

  describe 'the session a task-producing tools/call is written into' do
    def ends_session_at_the_wire
      lambda do |*_args|
        # The stdio child exited and was replaced between the sampling and
        # the write; the transport checks its pin right before the wire.
        stdio.send(:bump_session_epoch)
        stdio.check_session_pin!
        create_result
      end
    end

    before do
      allow(stdio).to receive_messages(list_tools: [task_tool], modern?: true, ping: true,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:ensure_session_ready)
    end

    it 'does not execute a modern tools/call in the session that replaced the sampled one' do
      allow(stdio).to receive(:call_tool, &ends_session_at_the_wire)
      client = client_for

      expect { client.call_tool('sync', {}) }
        .to raise_error(MCPClient::Errors::ToolCallError, /session/i)
    end

    it 'does not execute a modern call_tool_as_task in the session that replaced the sampled one' do
      allow(stdio).to receive(:call_tool, &ends_session_at_the_wire)
      client = client_for

      expect { client.call_tool_as_task('sync', {}) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
    end

    it 'does not open a streaming tools/call in the session that replaced the sampled one' do
      allow(stdio).to receive(:call_tool_streaming) do
        stdio.send(:bump_session_epoch)
        stdio.check_session_pin!
        [create_result].each
      end
      client = client_for

      expect { client.call_tool_streaming('sync', {}) }
        .to raise_error(MCPClient::Errors::ToolCallError, /session/i)
    end
  end

  describe 'a terminal handle waited on again after its id was reused' do
    it 'leaves the live task bookkeeping of the new lifetime alone' do
      client = client_for
      negotiated
      creation(client)
      terminal = MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => call_result),
                                           server: stdio, detailed: true, task_generation: 0,
                                           session_epoch: client.send(:current_session_epoch, stdio))
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])

      expect(client.wait_for_task(terminal).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end

    it 'still forgets the bookkeeping of the lifetime the handle belongs to' do
      client = client_for
      negotiated
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      terminal = MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => call_result),
                                           server: stdio, detailed: true, task_generation: 0,
                                           session_epoch: client.send(:current_session_epoch, stdio))

      expect(client.wait_for_task(terminal).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
    end
  end

  describe 'a cancel the server answered with an unknown task' do
    it 'forgets the keys of the session it was pinned to, not of the one that replaced it' do
      client = client_for
      negotiated
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      allow(client).to receive(:task_rpc) do
        # The child exited while the cancel was in flight and the successor
        # session gave the id to a task of its own.
        stdio.send(:bump_session_epoch)
        client.send(:remember_answered_keys, stdio, 'task-1', ['k2'])
        raise invalid_params('Task not found')
      end

      expect { client.cancel_task('task-1', server: stdio) }.to raise_error(MCPClient::Errors::TaskNotFound)
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k2')
    end
  end

  describe 'two updates for one input key that overlap' do
    it 'keeps the newer answer a definite rejection of the older one did not carry' do
      client = client_for
      negotiated
      state = client.send(:task_state, stdio, 'task-1')
      older = { 'action' => 'accept', 'content' => { 'n' => 'old' } }
      newer = { 'action' => 'accept', 'content' => { 'n' => 'new' } }
      allow(client).to receive(:task_rpc) do
        client.send(:queue_task_update, state, { 'k1' => newer })
        raise invalid_params('rejected inputResponses')
      end

      expect do
        client.send(:send_task_update, stdio, 'task-1', { 'k1' => older }, state: state)
      end.to raise_error(MCPClient::Errors::TaskError)

      expect(state[:pending_update]).to eq({ 'k1' => newer })
      expect(state[:answered]).to include('k1')
      expect(state[:submitted]).to include('k1')
    end

    it 'still gives back a rejected key nothing newer superseded' do
      client = client_for
      negotiated
      state = client.send(:task_state, stdio, 'task-1')
      allow(client).to receive(:task_rpc) do
        raise invalid_params('rejected inputResponses')
      end

      expect do
        client.send(:send_task_update, stdio, 'task-1', { 'k1' => { 'action' => 'accept' } }, state: state)
      end.to raise_error(MCPClient::Errors::TaskError)

      expect(state[:pending_update]).to be_nil
      expect(state[:answered]).to be_empty
      expect(state[:submitted]).to be_empty
    end
  end

  describe 'a transport that cannot take a per-request timeout' do
    it 'bounds a task request on the wall clock instead of running it inline forever' do
      gate = Queue.new
      srv = two_arg_server(gate)
      client = client_for
      raised = nil

      runner = Thread.new do
        client.send(:task_rpc, srv, 'tasks/get', { taskId: 'task-1' }, timeout: 0.05)
      rescue StandardError => e
        raised = e
      end

      expect(runner.join(5)).not_to be_nil
      expect(raised).to be_a(MCPClient::Errors::RequestTimeoutError)
      gate << {}
    end

    it 'still pins the bounded request to the session it belongs to' do
      srv = two_arg_server
      srv.define_singleton_method(:rpc_request) do |_method, _params|
        self.session_epoch += 1
        check_session_pin!
        {}
      end
      client = client_for

      expect { client.send(:task_rpc, srv, 'tasks/get', { taskId: 'task-1' }, timeout: 1, epoch: 0) }
        .to raise_error(MCPClient::Errors::SessionChangedError)
    end

    it 'hands a transport that does take the keyword its timeout as before' do
      client = client_for
      negotiated
      seen = nil
      allow(stdio).to receive(:rpc_request) { |_m, _p, **kw| seen = kw[:timeout] }

      client.send(:task_rpc, stdio, 'tasks/get', { taskId: 'task-1' }, timeout: 2)

      expect(seen).to eq(2)
    end
  end

  describe 'answers whose task another waiter already saw gone' do
    it 'discards them rather than updating the task the id names now' do
      client = client_for
      negotiated
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }
      wait = wait_joined(client)
      task = MCPClient::Task.from_json(detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }),
                                       server: stdio, detailed: true)
      allow(stdio).to receive(:fulfil_input_requests) do |pending, _task|
        # Another wait polled the task terminal while the host was answering.
        client.send(:forget_task_keys, stdio, 'task-1', state: wait[:state])
        pending.transform_values { { 'action' => 'accept', 'content' => { 'n' => 'x' } } }
      end

      expect(client.send(:answer_task_input_requests, task, wait[:answered], stdio, wait)).to eq([])
      expect(sent).to be_empty
    end

    it 'still delivers the answers of a task nothing disturbed' do
      client = client_for
      negotiated
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }
      wait = wait_joined(client)
      task = MCPClient::Task.from_json(detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }),
                                       server: stdio, detailed: true)
      allow(stdio).to receive(:fulfil_input_requests) do |pending, _task|
        pending.transform_values { { 'action' => 'accept', 'content' => { 'n' => 'x' } } }
      end

      expect(client.send(:answer_task_input_requests, task, wait[:answered], stdio, wait)).to eq(['k1'])
      expect(sent.map(&:first)).to eq(['tasks/update'])
    end
  end

  describe 'the pollIntervalMs of a task payload' do
    it 'refuses a CreateTaskResult whose pollIntervalMs is not an integer' do
      client = client_for
      negotiated

      expect { creation(client, result: create_result('pollIntervalMs' => 'soon')) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /pollIntervalMs/)
    end

    it 'refuses a CreateTaskResult whose pollIntervalMs is negative' do
      client = client_for
      negotiated

      expect { creation(client, result: create_result('pollIntervalMs' => -1)) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /pollIntervalMs/)
    end

    it 'refuses a tasks/get whose pollIntervalMs is not an integer' do
      client = client_for
      negotiated
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working', 'pollIntervalMs' => '1'))

      expect { client.get_task('task-1', server: stdio) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /pollIntervalMs/)
    end

    it 'accepts a task that reports no pollIntervalMs at all' do
      client = client_for
      negotiated
      result = create_result
      result.delete('pollIntervalMs')

      expect(creation(client, result: result).poll_interval_ms).to be_nil
    end

    it 'accepts an explicitly null pollIntervalMs' do
      client = client_for
      negotiated

      expect(creation(client, result: create_result('pollIntervalMs' => nil)).poll_interval_ms).to be_nil
    end
  end
end

# --- round38 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, thirty-eighth review round:
#
# - A streaming tools/call is lazy: the pin that keeps the call out of the
#   session which replaced the sampled one has to be held while the stream is
#   enumerated, in the thread that consumes it, not only while it is built.
# - The lifetime a request is about is bound to the request itself: it is
#   checked at the wire and again before the answer is acted on, so a
#   CreateTaskResult that lands after a preflight cannot leave a caller
#   updating, cancelling or reading the task that replaced its own.
# - Lifetimes stay distinguishable once the counter map is pruned: a re-created
#   id never reads as the lifetime a handle of the pruned one names.
# - Establishing a lifetime and reading it back is one step.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 38' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def create_result(**extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def detailed_task(status:, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def client_for(server = stdio, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server = stdio)
    allow(server).to receive(:capabilities).and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:modern?).and_return(true)
    allow(server).to receive(:ensure_session_ready)
  end

  # One CreateTaskResult, as the server would answer it in the live session.
  def creation(client, srv: stdio, result: nil)
    client.send(:created_task, result || create_result, srv, client.send(:current_session_epoch, srv))
  end

  def task_tool(name: 'sync', task_support: nil)
    MCPClient::Tool.new(name: name, description: 'd', schema: { 'type' => 'object' }, server: stdio,
                        task_support: task_support)
  end

  def accept(value = 'x')
    { 'action' => 'accept', 'content' => { 'n' => value } }
  end

  describe 'the session a streaming tools/call is enumerated in' do
    before do
      allow(stdio).to receive_messages(list_tools: [task_tool], modern?: true, ping: true,
                                       capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:ensure_session_ready)
      # Exactly what every built-in transport hands back: an Enumerator that
      # sends nothing until the consumer enumerates it.
      allow(stdio).to receive(:call_tool_streaming) do |tool_name, parameters|
        Enumerator.new { |yielder| yielder << stdio.call_tool(tool_name, parameters) }
      end
    end

    it 'sends nothing before the returned stream is enumerated' do
      ran = false
      allow(stdio).to receive(:call_tool) do
        ran = true
        call_result
      end
      client = client_for

      client.call_tool_streaming('sync', {})

      expect(ran).to be(false)
    end

    it 'does not run the tool in the session that replaced the one the stream was opened for' do
      ran = false
      allow(stdio).to receive(:call_tool) do
        stdio.check_session_pin!
        ran = true
        call_result
      end
      client = client_for
      stream = client.call_tool_streaming('sync', {})
      # The stdio child exited and was replaced before the host consumed the
      # stream; the pin has to still be in force when the call goes out.
      stdio.send(:bump_session_epoch)

      expect { stream.to_a }.to raise_error(MCPClient::Errors::SessionChangedError)
      expect(ran).to be(false)
    end

    it 'yields the chunks of a stream nothing disturbed' do
      allow(stdio).to receive(:call_tool) do
        stdio.check_session_pin!
        call_result
      end
      client = client_for

      expect(client.call_tool_streaming('sync', {}).to_a).to eq([call_result])
    end

    it 'resolves a task chunk of a stream it enumerated under the pin' do
      allow(stdio).to receive(:call_tool) do
        stdio.check_session_pin!
        create_result
      end
      client = client_for
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'completed', 'result' => call_result))

      expect(client.call_tool_streaming('sync', {}).to_a).to eq([call_result])
    end
  end

  describe 'the lifetime a task request is bound to' do
    # A transport whose rpc_request checks its pins where the built-in ones
    # do: immediately before the wire.
    def wired(sent, &before_wire)
      allow(stdio).to receive(:rpc_request) do |method, params|
        before_wire&.call(method)
        stdio.check_session_pin!
        sent << [method, params]
        {}
      end
    end

    it 'does not send a tasks/update once a creation lands between the check and the wire' do
      client = client_for
      negotiated
      handle = creation(client)
      sent = []
      wired(sent)
      # The replacement arrives while the update is establishing its session:
      # past every preflight, and before anything is written.
      allow(stdio).to receive(:ensure_session_ready) { creation(client) }

      expect { client.update_task(handle, { 'k1' => accept }) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
      expect(sent).to be_empty
    end

    it 'still sends the tasks/update of a task nothing replaced' do
      client = client_for
      negotiated
      handle = creation(client)
      sent = []
      wired(sent)

      expect(client.update_task(handle, { 'k1' => accept })).to be(true)
      expect(sent.map(&:first)).to eq(['tasks/update'])
    end

    it 'does not send a tasks/cancel once a creation lands between the check and the wire' do
      client = client_for
      negotiated
      handle = creation(client)
      sent = []
      wired(sent) { |method| creation(client) if method == 'tasks/cancel' }

      expect { client.cancel_task(handle) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
      expect(sent).to be_empty
    end

    it 'does not act on a tasks/get answer whose task was replaced while it was in flight' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(stdio).to receive(:rpc_request) do |_method, _params|
        stdio.check_session_pin!
        # The answer is already on its way back when the id is handed out again.
        creation(client)
        detailed_task(status: 'working')
      end

      expect { client.get_task(handle) }
        .to raise_error(MCPClient::Errors::TaskError, /new task with this id/i)
    end

    it 'refuses the replaced task with a TaskReplacedError, a TaskError as before' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc)
      creation(client)

      expect { client.cancel_task(handle) }.to raise_error(MCPClient::Errors::TaskReplacedError)
      expect(MCPClient::Errors::TaskReplacedError.ancestors).to include(MCPClient::Errors::TaskError)
    end

    it 'leaves the bookkeeping of the lifetime that replaced the one a terminal poll asked about' do
      client = client_for
      negotiated
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      allow(stdio).to receive(:rpc_request) do
        stdio.check_session_pin!
        # A creation under the same id lands while the poll's answer is in
        # flight; its answered keys are the new task's.
        creation(client)
        client.send(:remember_answered_keys, stdio, 'task-1', ['k2'])
        detailed_task(status: 'completed', 'result' => call_result)
      end

      expect(client.get_task('task-1', server: stdio).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k2')
    end

    it 'still forgets the bookkeeping of the lifetime a terminal poll did ask about' do
      client = client_for
      negotiated
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'completed', 'result' => call_result))

      expect(client.get_task('task-1', server: stdio).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
    end
  end

  describe 'the lifetimes a prune forgets' do
    let(:cap) { MCPClient::Client::TaskRegistry::MAX_TRACKED_TASK_LIFETIMES }

    # Ids whose tasks are over: a prune only forgets the lifetime of a task
    # this client no longer tracks, so the crowd has to be a crowd of ended
    # tasks — a live one keeps its lifetime however many ids follow it.
    def crowd_out(client, count = nil)
      (count || (cap + 1)).times do |i|
        creation(client, result: create_result('taskId' => "other-#{i}"))
        client.send(:forget_task_keys, stdio, "other-#{i}")
      end
    end

    # The wait that was following the task ended (its TTL ran out, a poll
    # found it terminal), so the client keeps no bookkeeping for it — while
    # the host still holds the handle.
    def no_longer_tracked(client, task_id = 'task-1')
      client.send(:forget_task_keys, stdio, task_id)
    end

    it 'never lets a re-created id read as the lifetime a pruned handle names' do
      client = client_for
      negotiated
      handle = creation(client)
      no_longer_tracked(client)

      crowd_out(client)
      recreated = creation(client)

      expect(recreated.task_generation).not_to eq(handle.task_generation)
    end

    it 'refuses an update through a handle whose lifetime the prune forgot' do
      client = client_for
      negotiated
      handle = creation(client)
      no_longer_tracked(client)
      allow(client).to receive(:task_rpc)

      crowd_out(client)

      expect { client.update_task(handle, { 'k1' => accept }) }
        .to raise_error(MCPClient::Errors::TaskError, /no longer tracks/i)
    end

    it 'refuses a cancel through a handle whose lifetime the prune forgot' do
      client = client_for
      negotiated
      handle = creation(client)
      no_longer_tracked(client)
      allow(client).to receive(:task_rpc)

      crowd_out(client)

      expect { client.cancel_task(handle) }.to raise_error(MCPClient::Errors::TaskError, /no longer tracks/i)
    end

    it 'keeps naming the task of a handle nothing crowded out' do
      client = client_for
      negotiated
      handle = creation(client)
      allow(client).to receive(:task_rpc).and_return(detailed_task(status: 'working'))

      crowd_out(client, 8)

      expect(client.get_task(handle).task_generation).to eq(handle.task_generation)
    end
  end

  describe 'establishing a lifetime and reading it back' do
    it 'stamps a creation with the lifetime it established, not with a later reading' do
      client = client_for
      negotiated
      # A concurrent creation of the same id would move what a second,
      # separate reading of the counter returns.
      allow(client).to receive(:task_lifetime).and_return(99)

      expect(creation(client).task_generation).to eq(0)
    end

    it 'stamps a legacy creation with the lifetime it established' do
      allow(stdio).to receive_messages(
        list_tools: [task_tool(name: 'slow', task_support: 'optional')], modern?: false,
        capabilities: { 'tools' => {}, 'tasks' => { 'requests' => { 'tools' => { 'call' => {} } } } }
      )
      allow(stdio).to receive(:ensure_session_ready)
      allow(stdio).to receive(:rpc_request).and_return(create_result)
      client = client_for
      allow(client).to receive(:task_lifetime).and_return(99)

      expect(client.call_tool_as_task('slow', {}).task_generation).to eq(0)
    end

    it 'gives concurrent creations of one id lifetimes of their own' do
      client = client_for
      negotiated
      epoch = client.send(:current_session_epoch, stdio)
      seen = Queue.new

      threads = Array.new(8) do
        Thread.new { 4.times { seen << client.send(:start_task_lifetime, stdio, 'task-1', epoch) } }
      end
      threads.each { |thread| expect(thread.join(10)).not_to be_nil }

      generations = []
      generations << seen.pop until seen.empty?
      expect(generations.size).to eq(32)
      expect(generations.uniq.size).to eq(32)
    end
  end

  describe 'a task named without a lifetime' do
    it 'leaves the live bookkeeping alone when a terminal handle names no lifetime' do
      client = client_for
      negotiated
      creation(client)
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])
      terminal = MCPClient::Task.from_json(detailed_task(status: 'completed', 'result' => call_result),
                                           server: stdio, detailed: true,
                                           session_epoch: client.send(:current_session_epoch, stdio))

      expect(client.wait_for_task(terminal).status).to eq('completed')
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end

    it 'lets a bare task id name whatever the id means now' do
      client = client_for
      negotiated
      creation(client)
      creation(client)
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }

      client.cancel_task('task-1', server: stdio)

      expect(sent.map(&:first)).to eq(['tasks/cancel'])
    end

    it 'lets a bare task id be updated after the id was handed out again' do
      client = client_for
      negotiated
      creation(client)
      sent = []
      allow(client).to receive(:task_rpc) { |_srv, method, params, **| sent << [method, params] }

      expect(client.update_task('task-1', { 'k1' => accept })).to be(true)
      expect(sent.map(&:first)).to eq(['tasks/update'])
    end
  end
end

# --- round40 ---------------------------------------------------------------

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

    # A stateless 2026-07-28 stdio peer holds no session either (round 43):
    # its cleanup ends none, and the bookkeeping stays exactly as it does over
    # sessionless HTTP above. The session a 2025-11-25 handshake opened is
    # forgotten with its cleanup — pinned in round 43.
    it 'keeps the bookkeeping of a stateless stdio peer across a cleanup' do
      client = client_for
      script_stdio(stdio, [{ 'result' => discover_result }])
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])

      client.cleanup

      expect(stdio.session_epoch).to eq(0)
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
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

# --- round42 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, forty-second review round:
#
# - A handle a host restored into a transport that has not connected yet is
#   not refused as belonging to an ended session: connecting for the first
#   time ends no session, and a sessionless server has none to end.
# - A transport that takes no per-request timeout is polled through a bounded
#   number of workers: a hung request is joined again on the next poll rather
#   than started again beside it, and the number of distinct requests left
#   hanging is capped.
# - What a notifications/tasks carries reaches the host whole (inputRequests,
#   result, error), two waits on one task drive one round through the public
#   API, and a legacy task runs through the stdio transport's own paths.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 42' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

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

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def elicit_request(message = 'Name?')
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => message,
                    'requestedSchema' => { 'type' => 'object',
                                           'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def client_for(server = stdio, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x', name: 'a' }],
                                   extensions: [TASKS_EXT], **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server = stdio)
    allow(server).to receive_messages(modern?: true, ping: true,
                                      capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:ensure_session_ready)
  end

  def legacy_task(id: 'task-1', status: 'working')
    now = Time.now.utc.iso8601(3)
    { 'taskId' => id, 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttl' => 60_000, 'pollInterval' => 1 }
  end

  def structured_tool(server = stdio, task_support: nil)
    MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                        output_schema: { 'type' => 'object', 'required' => ['n'],
                                         'properties' => { 'n' => { 'type' => 'integer' } } },
                        task_support: task_support, server: server)
  end

  # A creation the server answers with a task under the id task-1.
  def creating(server = stdio, tool: structured_tool(server))
    server.singleton_class.include(MCPClient::CalledToolDefinition)
    allow(server).to receive(:list_tools).and_return([tool])
    allow(server).to receive(:call_tool) do
      server.send(:note_called_tool_definition, 'sync', tool)
      create_result
    end
  end

  def wait_for(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      raise 'condition never met' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end

  # The workers still blocked inside a fixture transport's rpc_request:
  # what a hung transport piles up, counted without the noise of the
  # process's other threads.
  def hung_workers
    Thread.list.count do |thread|
      thread.backtrace&.any? do |line|
        line.include?("in 'rpc_request'") || line.include?('`rpc_request')
      end
    end
  end

  def json_answer(id, result)
    { status: 200, headers: { 'Content-Type' => 'application/json' },
      body: { jsonrpc: '2.0', id: id, result: result }.to_json }
  end

  # The stdio transport with its process replaced by a script: requests are
  # answered in order (a proc responder may first inject a line from the
  # server), and what the transport writes back is kept.
  def scripted(server, responses)
    sent = []
    written = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', flush: nil, closed?: true, close: nil).tap do |pipe|
      allow(pipe).to receive(:puts) { |line| written << JSON.parse(line) }
    end)
    # The wire shape: what send_request would serialize.
    allow(server).to receive(:send_request) { |req| sent << JSON.parse(JSON.generate(req)) }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      answer = responder.respond_to?(:call) ? responder.call : responder
      answer.merge('jsonrpc' => '2.0', 'id' => id)
    end
    [sent, written]
  end

  describe 'a handle restored into a transport that has not connected yet' do
    let(:url) { 'http://tasks.example/mcp' }

    # A modern (sessionless) server that still holds task-1, completed.
    def serving_the_task
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << body['method']
        result = case body['method']
                 when 'server/discover' then discover_result
                 when 'tasks/get' then detailed_task(status: 'completed', 'result' => call_result('kept'))
                 else raise "unexpected #{body['method']}"
                 end
        json_answer(body['id'], result)
      end
      sent
    end

    def client_over(http, type)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(http)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: type, url: url }], extensions: [TASKS_EXT])
      allow(client).to receive(:sleep)
      client
    end

    { 'Streamable HTTP' => [MCPClient::ServerStreamableHTTP, 'streamable_http'],
      'plain HTTP' => [MCPClient::ServerHTTP, 'http'] }.each do |label, (klass, type)|
      it "is waited on over #{label}, by the serialized handle and by its id" do
        sent = serving_the_task
        http = klass.new(base_url: url)
        client = client_over(http, type)
        # What a host persisted from an earlier process: the handle's hash,
        # rebuilt against a transport nothing has been sent through yet.
        stored = MCPClient::Task.from_create_result(create_result).to_h
        handle = MCPClient::Task.from_json(stored, server: http)

        finished = client.wait_for_task(handle)

        expect(finished).to be_completed
        expect(finished.result).to eq(call_result('kept'))
        expect(sent).to eq(%w[server/discover tasks/get])
        expect(client.wait_for_task(stored['taskId'])).to be_completed
      end
    end
  end

  describe 'a transport that takes no per-request timeout and never answers' do
    # The documented two-argument rpc_request(method, params) and nothing
    # else: every request blocks until its gate is fed.
    def hung_server
      Class.new do
        attr_reader :sent, :gate

        def initialize
          @sent = []
          @gate = Queue.new
        end

        def name
          'hung'
        end

        def rpc_request(method, params)
          @sent << [method, params]
          @gate.pop
        end
      end.new
    end

    def timed_out_poll(client, srv, params = { taskId: 'task-1' })
      client.send(:task_rpc, srv, 'tasks/get', params, timeout: 0.02)
      raise 'the poll came back'
    rescue MCPClient::Errors::RequestTimeoutError
      nil
    end

    after { @release&.call }

    it 'joins the request still hanging on the next poll instead of starting another beside it' do
      srv = hung_server
      client = client_for
      @release = -> { 6.times { srv.gate << {} } }

      6.times { timed_out_poll(client, srv) }

      expect(srv.sent.size).to eq(1)
      expect(hung_workers).to eq(1)
    end

    it 'hands the answer of a request that came back while nobody was waiting to the next poll' do
      srv = hung_server
      client = client_for
      @release = -> { srv.gate << {} }
      timed_out_poll(client, srv)
      srv.gate << detailed_task(status: 'completed', 'result' => call_result)

      answer = client.send(:task_rpc, srv, 'tasks/get', { taskId: 'task-1' }, timeout: 1)

      expect(answer['status']).to eq('completed')
      expect(srv.sent.size).to eq(1)
    end

    it 'caps how many distinct requests may be left hanging on one transport' do
      srv = hung_server
      client = client_for
      limit = MCPClient::Client::TaskSupport::MAX_PENDING_TASK_REQUESTS
      @release = -> { (limit + 1).times { srv.gate << {} } }

      limit.times { |i| timed_out_poll(client, srv, { taskId: "task-#{i}" }) }

      expect { client.send(:task_rpc, srv, 'tasks/get', { taskId: 'task-more' }, timeout: 0.02) }
        .to raise_error(MCPClient::Errors::TransportError, /#{limit} .*unanswered/)
      expect(srv.sent.size).to eq(limit)
    end
  end

  describe 'what a notifications/tasks carries' do
    it 'reaches the host whole for an input_required task, and no handler is run for it' do
      received = []
      client = client_for(elicitation_handler: ->(_message, _schema) { raise 'the client answered on its own' })
      negotiated
      client.on_notification { |_server, method, params| received << [method, params] }
      sent = []
      allow(stdio).to receive(:rpc_request) { |method, *_rest| sent << method }
      params = detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request })
      params.delete('resultType')

      stdio.instance_variable_get(:@notification_callback).call('notifications/tasks', params)

      expect(received).to eq([['notifications/tasks', params]])
      expect(received.dig(0, 1, 'inputRequests', 'k1')).to eq(elicit_request)
      expect(received.dig(0, 1, 'taskId')).to eq('task-1')
      expect(sent).to be_empty
    end

    it 'reaches the host whole for a failed task, error code, message and data included' do
      received = []
      client = client_for
      client.on_notification { |_server, method, params| received << [method, params] }
      error = { 'code' => -32_603, 'message' => 'boom', 'data' => { 'stage' => 'render' } }
      params = detailed_task(status: 'failed', 'error' => error)
      params.delete('resultType')

      stdio.send(:route_notification, 'notifications/tasks', params)

      expect(received).to eq([['notifications/tasks', params]])
      expect(received.dig(0, 1, 'error')).to eq(error)
    end
  end

  describe 'two waits on one task through the public API' do
    it 'drive one round between them: the host is asked once and one update goes out' do
      started = Queue.new
      release = Queue.new
      handled = 0
      client = client_for(elicitation_handler: lambda { |_message, _schema|
        handled += 1
        started << true
        release.pop
        { action: 'accept', content: { 'n' => 'x' } }
      })
      negotiated
      creating
      sent = []
      updated = false
      allow(stdio).to receive(:rpc_request) do |method, params, **_kw|
        sent << [method, params]
        case method
        when 'tasks/get'
          if updated
            detailed_task(status: 'completed', 'result' => call_result)
          else
            detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request })
          end
        when 'tasks/update'
          updated = true
          {}
        else raise "unexpected #{method}"
        end
      end
      task = client.call_tool_as_task('sync', {})

      first = Thread.new { client.wait_for_task(task) }
      started.pop
      # The first wait is inside the handler with k1 reserved; the second
      # polls the same input_required task and finds nothing left to answer.
      second = Thread.new { client.wait_for_task(task) }
      wait_for { sent.count { |method, _| method == 'tasks/get' } >= 2 }
      release << true

      expect(first.value).to be_completed
      expect(second.value).to be_completed
      expect(handled).to eq(1)
      updates = sent.select { |pair| pair.first == 'tasks/update' }
      expect(updates.size).to eq(1)
      expect(updates.dig(0, 1, :inputResponses) || updates.dig(0, 1, 'inputResponses')).to have_key('k1')
    end
  end

  describe 'a task on a transport that takes no per-request timeout, waited on repeatedly' do
    # A transport with the documented two-argument rpc_request only, which
    # negotiated the extension and then never answers a tasks/get.
    def hung_task_server
      Class.new do
        attr_reader :sent, :gate

        def initialize
          @sent = []
          @gate = Queue.new
        end

        def name = 'hung'
        def modern? = true
        def ping = true # rubocop:disable Naming/PredicateMethod
        def ensure_session_ready = nil
        def list_tools = []
        def on_notification(&) = nil
        def capability?(kind, name = nil) = kind == 'extensions' && name == TASKS_EXT
        def capabilities = { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } }

        def rpc_request(method, params)
          @sent << [method, params]
          @gate.pop
        end
      end.new
    end

    after { @release&.call }

    it 'keeps one request hanging across the waits rather than one per poll' do
      srv = hung_task_server
      client = client_for(srv)
      @release = -> { 3.times { srv.gate << {} } }

      3.times do
        expect { client.wait_for_task('task-1', timeout: 0.1) }.to raise_error(MCPClient::Errors::TaskError, /task-1/)
      end

      expect(srv.sent.map(&:first)).to eq(['tasks/get'])
      expect(hung_workers).to eq(1)
    end
  end

  describe 'a legacy task through the stdio transport itself' do
    def elicitation_line
      JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-7', 'method' => 'elicitation/create',
                    'params' => { 'message' => 'Name?', 'mode' => 'form',
                                  'requestedSchema' => { 'type' => 'object',
                                                         'properties' => { 'n' => { 'type' => 'string' } } },
                                  '_meta' => { related_key => { 'taskId' => 'task-1' } } })
    end

    def related_key
      MCPClient::ServerBase::RELATED_TASK_META_KEY
    end

    it 'creates the task, answers the related-task elicitation and fetches the result on the wire' do
      legacy = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a', protocol: :legacy)
      client = client_for(legacy, elicitation_handler: lambda { |_message, _schema|
        { action: 'accept', content: { 'n' => 'x' } }
      })
      handshake = { 'result' => { 'protocolVersion' => '2025-11-25',
                                  'capabilities' => { 'tools' => {},
                                                      'tasks' => { 'get' => true, 'result' => true,
                                                                   'requests' => { 'tools' => { 'call' => {} } } } },
                                  'serverInfo' => { 'name' => 's', 'version' => '1' } } }
      tools = { 'result' => { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' },
                                            'execution' => { 'taskSupport' => 'optional' } }] } }
      sent, written = scripted(legacy, [
                                 handshake, tools, { 'result' => { 'task' => legacy_task } },
                                 lambda {
                                   legacy.send(:handle_line, "#{elicitation_line}\n")
                                   { 'result' => legacy_task(status: 'input_required') }
                                 },
                                 { 'result' => legacy_task(status: 'completed') },
                                 { 'result' => call_result('legacy') }
                               ])

      handle = client.call_tool_as_task('slow', {})
      expect(client.get_task(handle)).to be_input_required
      expect(client.get_task(handle)).to be_completed
      expect(client.get_task_result(handle)).to eq(call_result('legacy'))

      expect(sent.map { |request| request['method'] })
        .to eq(%w[initialize tools/list tools/call tasks/get tasks/get tasks/result])
      creation = sent[2]
      expect(creation['params']).to include('task' => {})
      expect(sent[3..5].map { |request| request.dig('params', 'taskId') }).to all(eq('task-1'))
      answer = written.find { |message| message['id'] == 'srv-7' }
      expect(answer['result']).to include('action' => 'accept', 'content' => { 'n' => 'x' })
      expect(answer.dig('result', '_meta',
                        MCPClient::ServerBase::RELATED_TASK_META_KEY)).to eq({ 'taskId' => 'task-1' })
    end
  end
  describe 'task payloads handed up with Symbol keys' do
    # A transport of the host's own (the documented rpc_request interface)
    # may parse JSON with symbolized names; a Task is a Task whichever way
    # its keys are spelled, as an ordinary result already is.
    def symbolized(value)
      case value
      when Hash then value.to_h { |key, member| [key.to_sym, symbolized(member)] }
      when Array then value.map { |member| symbolized(member) }
      else value
      end
    end

    it 'creates, polls and completes a task whose CreateTaskResult and DetailedTask carry Symbol keys' do
      client = client_for
      negotiated
      tool = structured_tool
      stdio.singleton_class.include(MCPClient::CalledToolDefinition)
      allow(stdio).to receive(:list_tools).and_return([tool])
      allow(stdio).to receive(:call_tool) do
        stdio.send(:note_called_tool_definition, 'sync', tool)
        symbolized(create_result)
      end
      sent = []
      allow(stdio).to receive(:rpc_request) do |method, *_rest|
        sent << method
        raise "unexpected #{method}" unless method == 'tasks/get'

        symbolized(detailed_task(status: 'completed',
                                 'result' => { 'content' => [],
                                               'structuredContent' => { 'n' => 1 } }))
      end

      task = client.call_tool_as_task('sync', {})
      expect(task.task_id).to eq('task-1')
      finished = client.wait_for_task(task)

      expect(finished).to be_completed
      expect(finished.result).to eq({ 'content' => [], 'structuredContent' => { 'n' => 1 } })
      expect(sent).to eq(['tasks/get'])
    end
  end

  describe 'a tasks/get answered with the input_required discriminator' do
    # tasks/get is not a multi round-trip method: a server that answers it
    # with an InputRequiredResult (the discriminator, not a DetailedTask
    # whose status is input_required) has answered with an invalid result —
    # the input is asked for through tasks/update, never by retrying
    # tasks/get with inputResponses.
    it 'is an invalid result, not a round trip retried on tasks/get' do
      modern = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a')
      client = client_for(modern, elicitation_handler: lambda { |_message, _schema|
        { action: 'accept', content: { 'n' => 'x' } }
      })
      tools = { 'result' => { 'resultType' => 'complete',
                              'tools' => [{ 'name' => 'sync', 'inputSchema' => { 'type' => 'object' } }] } }
      unfinished = { 'result' => { 'resultType' => 'input_required', 'requestState' => 'keep-me',
                                   'inputRequests' => { 'k1' => elicit_request } } }
      sent, = scripted(modern, [{ 'result' => discover_result }, tools, { 'result' => create_result }, unfinished])

      handle = client.call_tool_as_task('sync', {})

      expect { client.get_task(handle) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
      expect(sent.map { |request| request['method'] }).to eq(%w[server/discover tools/list tools/call tasks/get])
      expect(sent.last['params']).not_to have_key('inputResponses')
    end
  end

  describe 'a 2026 tasks/cancel acknowledgement that carries a status' do
    # The acknowledgement is not a Task and its fields are not the task's
    # state: cancellation is eventually consistent, and tasks/get is where
    # the state is read (a server that already reports cancelled says so
    # there too).
    it 'is not taken for the task: the handle stays as it was until tasks/get says otherwise' do
      client = client_for
      negotiated
      creating
      answers = { 'tasks/cancel' => { 'status' => 'cancelled', 'taskId' => 'task-1' },
                  'tasks/get' => detailed_task(status: 'cancelled') }
      sent = []
      allow(stdio).to receive(:rpc_request) do |method, *_rest|
        sent << method
        answers.fetch(method) { raise "unexpected #{method}" }
      end
      task = client.call_tool_as_task('sync', {})

      cancelled = client.cancel_task(task)

      expect(cancelled).to be_working
      expect(cancelled).not_to be_terminal
      expect(client.get_task(task)).to be_cancelled
      expect(sent).to eq(%w[tasks/cancel tasks/get])
    end
  end
end

# --- round43 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, review round 43: a replaced stdio process is
# not the end of a session on a stateless 2026-07-28 peer (a task it holds
# outlives the connection, as it does over HTTP), a retransmitted update
# carries only the answers the task still asks for, and a transport that
# reports no session keeps its bookkeeping in one place.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 43' do
  def detailed_task(status:, id: 'task-1', poll_ms: 1, **extra)
    now = Time.now.utc.iso8601
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => 60_000, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def elicit_request(name = 'n')
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => "#{name}?",
                    'requestedSchema' => { 'type' => 'object', 'properties' => { name => { 'type' => 'string' } } } } }
  end

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  # The stdio transport driven at the wire: every request it writes is
  # recorded, and each method is answered from its own queue (a Proc raises
  # or returns). Its own handlers fulfil the input requests a task raises.
  def scripted(server, script)
    sent = []
    script = { 'server/discover' => [discover_result] }.merge(script)
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    # The wire shape: what send_request would serialize.
    allow(server).to receive(:send_request) { |req, *_rest, **_opts| sent << JSON.parse(JSON.generate(req)) }
    allow(server).to receive(:wait_response) do |id, **_opts|
      method = sent.last['method']
      queue = script.fetch(method) { raise "no script for #{method}" }
      answer = queue.size == 1 && method == 'server/discover' ? queue.first : queue.shift
      raise "no scripted answer left for #{method}" if answer.nil?

      answer = answer.call(method, sent.last['params']) if answer.respond_to?(:call)
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => answer }
    end
    sent
  end

  def update_keys(sent)
    sent.select { |req| req['method'] == 'tasks/update' }
        .map { |req| (req['params']['inputResponses'] || req['params'][:inputResponses]).keys.map(&:to_s) }
  end

  describe 'a replaced stdio process on a 2026-07-28 peer' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def connected(server, version:, initialized: true)
      server.instance_variable_set(:@protocol_version, version)
      server.instance_variable_set(:@initialized, initialized)
      server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    end

    it 'leaves the session epoch alone: a stateless peer holds no session a cleanup could end' do
      connected(stdio, version: '2026-07-28')
      epoch = stdio.session_epoch

      stdio.cleanup

      expect(stdio.session_epoch).to eq(epoch)
    end

    it 'still ends the session a 2025-11-25 handshake opened' do
      connected(stdio, version: '2025-11-25')
      epoch = stdio.session_epoch

      stdio.cleanup

      expect(stdio.session_epoch).to be > epoch
    end

    it 'forgets the task bookkeeping of the session a 2025-11-25 handshake opened' do
      client = client_for(stdio)
      connected(stdio, version: '2025-11-25')
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])

      stdio.cleanup

      expect(stdio.session_epoch).to eq(1)
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
    end

    it 'ends no session on a process that never completed a handshake' do
      connected(stdio, version: nil, initialized: false)
      epoch = stdio.session_epoch

      stdio.cleanup

      expect(stdio.session_epoch).to eq(epoch)
    end

    describe 'a durable task, driven by a real child process' do
      # A 2026-07-28 stdio server fronting a job store that outlives it: the
      # task it creates is recorded in a file, and the process that replaces
      # it answers tasks/get from that file.
      def stdio_server_source
        <<~RUBY
          require 'json'
          $stdout.sync = true
          store = ENV.fetch('MCP_SPEC_STORE')
          generation = (File.exist?("\#{store}.gen") ? File.read("\#{store}.gen").to_i : 0) + 1
          File.write("\#{store}.gen", generation.to_s)
          tasks_ext = 'io.modelcontextprotocol/tasks'
          now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
          stamp = { 'createdAt' => now, 'lastUpdatedAt' => now, 'ttlMs' => 60_000, 'pollIntervalMs' => 1 }
          answer = ->(id, result) { $stdout.puts(JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result)) }

          $stdin.each_line do |line|
            begin
              message = JSON.parse(line)
            rescue JSON::ParserError
              next
            end
            id = message['id']
            case message['method']
            when 'server/discover'
              answer.call(id, { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                'capabilities' => { 'tools' => {}, 'extensions' => { tasks_ext => {} } } })
            when 'tools/list'
              answer.call(id, { 'resultType' => 'complete', 'ttlMs' => 60_000,
                                'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }] })
            when 'tools/call'
              File.write(store, JSON.generate('status' => 'working', 'polls' => 0, 'generation' => generation))
              answer.call(id, { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working' }.merge(stamp))
            when 'tasks/get'
              task = File.exist?(store) ? JSON.parse(File.read(store)) : nil
              if task.nil?
                $stdout.puts(JSON.generate('jsonrpc' => '2.0', 'id' => id,
                                           'error' => { 'code' => -32_602, 'message' => 'no such task' }))
              else
                task['polls'] += 1
                task['status'] = 'completed' if task['polls'] >= 2
                File.write(store, JSON.generate(task))
                result = { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => task['status'],
                           'servedBy' => generation }.merge(stamp)
                if task['status'] == 'completed'
                  # The generation travels in the payload the client hands
                  # back, so the example can name the process that served the
                  # task without depending on a field Task#to_h drops.
                  result['result'] = { 'content' => [{ 'type' => 'text', 'text' => "done by \#{generation}" }],
                                       'isError' => false }
                end
                answer.call(id, result)
              end
            end
          end
        RUBY
      end

      let(:workdir) { Dir.mktmpdir('mcp-round43') }
      let(:script) { File.join(workdir, 'server.rb') }
      let(:store) { File.join(workdir, 'task') }
      let(:server) do
        MCPClient::ServerStdio.new(command: [RbConfig.ruby, script], read_timeout: 5, discover_timeout: 5,
                                   env: { 'MCP_SPEC_STORE' => store })
      end

      before { File.write(script, stdio_server_source) }

      after do
        server.cleanup
      rescue StandardError
        nil
      ensure
        FileUtils.remove_entry(workdir)
      end

      it 'is still the handle\'s task after the process was replaced' do
        client = client_for(server)
        handle = client.call_tool_as_task('slow', {})
        expect(handle).to be_working

        server.cleanup

        # The next request negotiates a replacement process; the task is
        # asked about there, not refused as belonging to an ended session.
        finished = client.wait_for_task(handle, timeout: 10)
        expect(finished).to be_completed
        # The replacement process served it: its generation is in the payload
        # the client handed back, asserted unconditionally.
        expect(finished.result).to eq(call_result('done by 2'))
        expect(File.read("#{store}.gen").to_i).to eq(2)
      end
    end
  end

  describe 'a retransmitted update' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:lost) { ->(_method, _params) { raise MCPClient::Errors::TransportError, 'acknowledgement lost' } }
    let(:ask_k1) { detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request('a') }) }
    let(:ask_k2) { detailed_task(status: 'input_required', 'inputRequests' => { 'k2' => elicit_request('b') }) }
    let(:done) { detailed_task(status: 'completed', 'result' => call_result) }

    def answering_client(asked)
      client_for(stdio, elicitation_handler: lambda { |message, _schema|
        asked << message
        { action: 'accept', content: { 'n' => 'x' } }
      })
    end

    it 'carries nothing once the task no longer asks for the answer the server consumed' do
      asked = []
      client = answering_client(asked)
      calls = scripted(stdio, 'tasks/get' => [ask_k1, detailed_task(status: 'working'), done], 'tasks/update' => [lost])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(asked.size).to eq(1)
      expect(update_keys(calls)).to eq([['k1']])
    end

    it 'carries only the answers to the requests the task still lists' do
      asked = []
      client = answering_client(asked)
      calls = scripted(stdio, 'tasks/get' => [ask_k1, ask_k2, done], 'tasks/update' => [lost, {}])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(asked.size).to eq(2)
      expect(update_keys(calls)).to eq([['k1'], ['k2']])
    end

    it 'still resends an answer the task keeps asking for, without asking the host again' do
      asked = []
      client = answering_client(asked)
      calls = scripted(stdio, 'tasks/get' => [ask_k1, ask_k1, done], 'tasks/update' => [lost, {}])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(asked.size).to eq(1)
      expect(update_keys(calls)).to eq([['k1'], ['k1']])
    end
  end

  describe 'a transport that reports no session' do
    # The stdio transport with its session surface removed: what a
    # third-party transport implementing the documented interface and
    # nothing else looks like to the task registry.
    let(:sessionless) do
      Class.new(MCPClient::ServerStdio) do
        undef_method :session_epoch
        undef_method :pinned_to_session
      end.new(command: 'echo test', read_timeout: 1)
    end

    it 'takes one explicit update after another and is then waited on' do
      client = client_for(sessionless)
      calls = scripted(sessionless, 'tasks/update' => [{}, {}],
                                    'tasks/get' => [detailed_task(status: 'completed', 'result' => call_result)])
      expect(sessionless).not_to respond_to(:session_epoch)

      client.update_task('task-1', { 'k1' => { 'action' => 'accept', 'content' => { 'n' => 'x' } } })
      expect do
        client.update_task('task-1', { 'k2' => { 'action' => 'accept', 'content' => { 'n' => 'y' } } })
      end.not_to raise_error

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed
      expect(update_keys(calls)).to eq([['k1'], ['k2']])
      expect(calls.map { |req| req['method'] }).to eq(%w[server/discover tasks/update tasks/update tasks/get])
    end
  end

  describe 'a completed handle a host persisted' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'hands back its serialized result without asking a server that may have purged the task' do
      client = client_for(stdio)
      sent = scripted(stdio, 'tasks/get' => [detailed_task(status: 'completed', 'result' => call_result('kept'))])
      finished = client.wait_for_task('task-1', timeout: 5)

      # What the README shows: the handle's hash, persisted and read back.
      restored = MCPClient::Task.from_json(JSON.parse(JSON.generate(finished.to_h)), server: stdio)

      expect(restored).to be_detailed
      expect(client.get_task_result(restored)).to eq(call_result('kept'))
      expect(sent.count { |req| req['method'] == 'tasks/get' }).to eq(1)
    end

    it 'still treats a persisted CreateTaskResult as the seed it is' do
      created = MCPClient::Task.from_create_result(
        { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'ttlMs' => 1000 }, server: stdio
      )

      expect(MCPClient::Task.from_json(created.to_h, server: stdio)).not_to be_detailed
    end
  end

  describe 'the input a 2026-07-28 task asks for' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:done) { detailed_task(status: 'completed', 'result' => call_result) }

    def url_request
      { 'method' => 'elicitation/create',
        'params' => { 'mode' => 'url', 'message' => 'Sign in', 'url' => 'https://consent.example.com/session/1' } }
    end

    it 'runs a URL-mode elicitation through tasks/update, handing the host no 2025 field' do
      seen = []
      client = client_for(stdio, elicitation_handler: lambda { |message, details|
        seen << [message, details]
        { action: 'accept' }
      })
      asks = detailed_task(status: 'input_required', 'inputRequests' => { 'consent' => url_request })
      sent = scripted(stdio, 'tasks/get' => [asks, done], 'tasks/update' => [{}])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(seen).to eq([['Sign in', { 'mode' => 'url', 'url' => 'https://consent.example.com/session/1' }]])
      update = sent.find { |req| req['method'] == 'tasks/update' }
      expect(update['params']['inputResponses']).to eq({ 'consent' => { 'action' => 'accept' } })
    end

    # The session here is 2026-07-28 (it answers server/discover), and the
    # deprecations branch removed elicitationId from the modern URL-mode host
    # contract: a modern server that sends the field anyway cannot smuggle a
    # correlation id to the host through it, and the client names the field in
    # one warning without quoting its value. The 2025-11-25 contract, key
    # present and all, is pinned on that branch.
    it 'keeps a modern server from smuggling an elicitationId to the host' do
      seen = []
      logger = instance_double(Logger, warn: nil, info: nil, debug: nil, error: nil, :level= => nil)
      client = client_for(stdio, elicitation_handler: lambda { |_message, details|
        seen << details
        { action: 'accept' }
      })
      client.instance_variable_set(:@logger, logger)
      request = url_request.merge('params' => url_request['params'].merge('elicitationId' => 'e-1'))
      asks = detailed_task(status: 'input_required', 'inputRequests' => { 'consent' => request })
      scripted(stdio, 'tasks/get' => [asks, done], 'tasks/update' => [{}])

      client.wait_for_task('task-1', timeout: 5)

      expect(seen.first).not_to have_key('elicitationId')
      expect(seen.first).to eq({ 'mode' => 'url', 'url' => 'https://consent.example.com/session/1' })
      expect(logger).to have_received(:warn).with(/elicitationId/).at_least(:once)
    end

    def sampling_request(tools: true)
      params = { 'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'hi' } }],
                 'maxTokens' => 10 }
      if tools
        params.merge!('tools' => [{ 'name' => 'lookup', 'inputSchema' => { 'type' => 'object' } }],
                      'toolChoice' => { 'mode' => 'auto' })
      end
      { 'method' => 'sampling/createMessage', 'params' => params }
    end

    it 'refuses a tool-enabled sampling request when sampling.tools was not declared, before any sampler runs' do
      sampled = []
      client = client_for(stdio, sampling_handler: lambda { |params|
        sampled << params
        raise 'not reached'
      })
      asks = detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => sampling_request })
      sent = scripted(stdio, 'tasks/get' => [asks])

      expect { client.wait_for_task('task-1', timeout: 5) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /sampling\.tools/)
      expect(sampled).to be_empty
      expect(sent.map { |req| req['method'] }).not_to include('tasks/update')
    end

    it 'hands a declared sampler the tools and tool choice whole and sends its answer whole' do
      sampled = []
      answer = { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'call lookup' },
                 'model' => 'm-1', 'stopReason' => 'toolUse' }
      client = client_for(stdio, sampling_supports_tools: true,
                                 sampling_handler: lambda { |_messages, _prefs, _system, _max, params|
                                   sampled << params
                                   answer
                                 })
      asks = detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => sampling_request })
      sent = scripted(stdio, 'tasks/get' => [asks, done], 'tasks/update' => [{}])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(sampled.first).to include('tools' => sampling_request['params']['tools'],
                                       'toolChoice' => { 'mode' => 'auto' }, 'maxTokens' => 10)
      update = sent.find { |req| req['method'] == 'tasks/update' }
      expect(update['params']['inputResponses']).to eq({ 'k1' => answer })
    end
  end

  describe 'a task created after a real HeaderMismatch recovery over Streamable HTTP' do
    let(:url) { 'http://tasks.example/mcp' }

    def charge_tool(required)
      { 'name' => 'charge',
        'inputSchema' => { 'type' => 'object',
                           'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' } } },
        'outputSchema' => { 'type' => 'object', 'properties' => { 'a' => { 'type' => 'integer' },
                                                                  'b' => { 'type' => 'integer' } },
                            'required' => required } }
    end

    def json_answer(id, result)
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { jsonrpc: '2.0', id: id, result: result }.to_json }
    end

    # The first call is rejected with HeaderMismatch; the list the client
    # refreshes in response carries a stricter outputSchema, and the retried
    # call is accepted as a task.
    def serving
      sent = []
      lists = 0
      calls = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << [body['method'], request.headers['Mcp-Param-Region']]
        case body['method']
        when 'server/discover' then json_answer(body['id'], discover_result)
        when 'tools/list'
          lists += 1
          json_answer(body['id'], { 'resultType' => 'complete', 'ttlMs' => 60_000,
                                    'tools' => [charge_tool(lists == 1 ? ['a'] : %w[a b])] })
        when 'tools/call'
          calls += 1
          if calls == 1
            { status: 400, headers: { 'Content-Type' => 'application/json' },
              body: { jsonrpc: '2.0', id: body['id'],
                      error: { code: -32_020, message: 'Header mismatch' } }.to_json }
          else
            now = Time.now.utc.iso8601
            json_answer(body['id'], { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working',
                                      'createdAt' => now, 'lastUpdatedAt' => now, 'ttlMs' => 60_000,
                                      'pollIntervalMs' => 1 })
          end
        when 'tasks/get'
          json_answer(body['id'], detailed_task(status: 'completed',
                                                'result' => { 'content' => [], 'structuredContent' => { 'a' => 1 },
                                                              'isError' => false }))
        else raise "unexpected #{body['method']}"
        end
      end
      sent
    end

    it 'validates what the task delivers against the definition the recovery refreshed' do
      sent = serving
      http = MCPClient::ServerStreamableHTTP.new(base_url: url)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(http)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', url: url }],
                                     extensions: [TASKS_EXT], validate_structured_content: :strict)
      allow(client).to receive(:sleep)

      handle = client.call_tool_as_task('charge', { 'region' => 'eu' })

      expect(handle).to be_working
      expect(sent.map(&:first)).to eq(%w[server/discover tools/list tools/call tools/list tools/call
                                         tasks/get].first(5))
      expect(sent.filter_map { |method, region| region if method == 'tools/call' }).to eq(%w[eu eu])
      expect { client.get_task_result(handle) }.to raise_error(MCPClient::Errors::ValidationError, /\bb\b/)
      expect(sent.map(&:first).last).to eq('tasks/get')
    end
  end

  describe 'a legacy task whose result stream carries a related-task elicitation' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }
    let(:related_key) { MCPClient::ServerBase::RELATED_TASK_META_KEY }

    def legacy_task(status: 'working')
      now = Time.now.utc.iso8601
      { 'taskId' => 'task-1', 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now, 'ttl' => 60_000,
        'pollInterval' => 1 }
    end

    def event(message)
      "event: message\ndata: #{JSON.generate(message)}\n\n"
    end

    def elicitation_from_server
      { 'jsonrpc' => '2.0', 'id' => 'srv-7', 'method' => 'elicitation/create',
        'params' => { 'message' => 'Name?', 'mode' => 'form',
                      'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } },
                      '_meta' => { related_key => { 'taskId' => 'task-1' } } } }
    end

    # The SSE transport at the wire: every POST is recorded, and the answer
    # (or, for tasks/result, first the server's own request and then the
    # answer) arrives on the event stream, as it does over this transport.
    def on_the_stream(answers)
      sent = []
      written = []
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
      allow(server).to receive(:post_json_rpc_request) do |request|
        wire = JSON.parse(JSON.generate(request))
        sent << wire
        next nil if wire['method'].start_with?('notifications/')

        answers.fetch(wire['method']) { raise "no answer for #{wire['method']}" }.call(wire).each do |message|
          server.send(:parse_and_handle_sse_event, event(message.merge('jsonrpc' => '2.0')))
        end
        nil
      end
      allow(server).to receive(:post_jsonrpc_response) { |response| written << JSON.parse(JSON.generate(response)) }
      [sent, written]
    end

    it 'answers the elicitation on the stream before the result is released, related to the task' do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'sse', base_url: 'https://example.com/sse' }],
                                     elicitation_handler: lambda { |_message, _schema|
                                       { action: 'accept', content: { 'n' => 'x' } }
                                     })
      allow(client).to receive(:sleep)
      answer = ->(wire, result) { [{ 'id' => wire['id'], 'result' => result }] }
      sent, written = on_the_stream(
        'initialize' => lambda { |wire|
          tasks = { 'get' => true, 'result' => true, 'requests' => { 'tools' => { 'call' => {} } } }
          answer.call(wire, { 'protocolVersion' => '2025-11-25',
                              'capabilities' => { 'tools' => {}, 'tasks' => tasks },
                              'serverInfo' => { 'name' => 's', 'version' => '1' } })
        },
        'tools/list' => lambda { |wire|
          answer.call(wire, { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' },
                                            'execution' => { 'taskSupport' => 'optional' } }] })
        },
        'tools/call' => ->(wire) { answer.call(wire, { 'task' => legacy_task }) },
        'tasks/result' => ->(wire) { [elicitation_from_server] + answer.call(wire, call_result('legacy')) }
      )

      handle = client.call_tool_as_task('slow', {})
      expect(client.get_task_result(handle)).to eq(call_result('legacy'))

      expect(sent.map { |request| request['method'] }.reject { |method| method.start_with?('notifications/') })
        .to eq(%w[initialize tools/list tools/call tasks/result])
      reply = written.find { |message| message['id'] == 'srv-7' }
      expect(reply['result']).to include('action' => 'accept', 'content' => { 'n' => 'x' })
      expect(reply.dig('result', '_meta', related_key)).to eq({ 'taskId' => 'task-1' })
    end
  end
end

# --- round44 ---------------------------------------------------------------

# MCP 2026-07-28 tasks extension, forty-fourth review round:
#
# - An observation only retires the answers it could have seen: a poll issued
#   before an answer was queued says nothing about whether the server consumed
#   it, so a stale snapshot never strands an input request.
# - A retransmission of a partly consumed batch carries exactly the answers
#   the task still lists, each with the content it was given.
# - A legacy HTTP session ends only where there was one: a server that never
#   assigned an Mcp-Session-Id keeps its tasks across a client cleanup.
# - A CreateTaskResult is refused wherever it arrives, discovery included.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 44' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def detailed_task(status:, id: 'task-1', poll_ms: 1, **extra)
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def elicit_request(message = 'Name?')
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => message,
                    'requestedSchema' => { 'type' => 'object',
                                           'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def client_for(server = stdio, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x', name: 'a' }],
                                   extensions: [TASKS_EXT], **opts)
    allow(client).to receive(:sleep)
    client
  end

  def negotiated(server = stdio)
    allow(server).to receive_messages(modern?: true, ping: true,
                                      capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(server).to receive(:ensure_session_ready)
  end

  def wait_for(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      raise 'condition never met' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end

  # rpc_request is stubbed directly here, so params arrive as the transport
  # would serialize them: symbol-keyed, not the JSON round trip.
  def input_responses(params)
    params[:inputResponses] || params['inputResponses'] || {}
  end

  def updates_in(calls)
    calls.filter_map { |method, params| params if method == 'tasks/update' }
  end

  def update_keys(calls)
    updates_in(calls).map { |params| input_responses(params).keys.sort }
  end

  describe 'an observation older than the answer it would retire' do
    # The interleaving: one wait polls and its tasks/get is held in flight;
    # another wait meanwhile answers the request the task is asking for and
    # its delivery is lost, so the answer stays pending. The held poll then
    # comes back carrying a snapshot taken BEFORE that answer existed. It
    # cannot testify that the server consumed the answer — it never saw it —
    # so the answer must stay pending for the next poll to resend.
    it 'leaves the answer pending, and the next poll resends it' do
      release = Queue.new
      held = Queue.new
      asked = []
      client = client_for(elicitation_handler: lambda { |message, _schema|
        asked << message
        { action: 'accept', content: { 'n' => 'x' } }
      })
      negotiated
      calls = []
      lost_once = true
      stale_poll_taken = false
      allow(stdio).to receive(:rpc_request) do |method, params, **_kw|
        calls << [method, params]
        case method
        when 'tasks/get'
          if !stale_poll_taken
            # The stale poll: its snapshot is taken now (the task is asking
            # for k1, nothing is answered yet) but it returns much later.
            stale_poll_taken = true
            held << true
            release.pop
            detailed_task(status: 'working')
          elsif asked.empty? || lost_once
            # Still asking for k1: while it is unanswered, and again after the
            # answer's acknowledgement was lost.
            detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request })
          else
            detailed_task(status: 'completed', 'result' => call_result)
          end
        when 'tasks/update'
          if lost_once
            lost_once = false
            raise MCPClient::Errors::TransportError, 'acknowledgement lost'
          end
          {}
        else raise "unexpected #{method}"
        end
      end

      stale = Thread.new { client.wait_for_task('task-1', timeout: 10) }
      held.pop
      # A second wait answers k1 while the first poll is still in flight; its
      # delivery is lost, so the answer is pending and k1 is marked answered.
      answering = Thread.new { client.wait_for_task('task-1', timeout: 10) }
      wait_for { !lost_once }
      release << true

      expect(stale.value).to be_completed
      expect(answering.value).to be_completed
      # The host was asked once, and the answer reached the server on the
      # retransmission rather than being dropped with its key left answered.
      expect(asked.size).to eq(1)
      expect(update_keys(calls)).to include(['k1'])
      expect(update_keys(calls).size).to be >= 2
    end
  end

  describe 'a retransmission of a partly consumed batch' do
    let(:lost) { ->(_method, _params) { raise MCPClient::Errors::TransportError, 'acknowledgement lost' } }

    it 'carries exactly the answer the task still lists, with its own content' do
      asked = []
      client = client_for(elicitation_handler: lambda { |message, _schema|
        asked << message
        { action: 'accept', content: { 'n' => message } }
      })
      negotiated
      both = { 'k1' => elicit_request('one'), 'k2' => elicit_request('two') }
      calls = []
      step = 0
      allow(stdio).to receive(:rpc_request) do |method, params, **_kw|
        calls << [method, params]
        case method
        when 'tasks/get'
          step += 1
          case step
          when 1 then detailed_task(status: 'input_required', 'inputRequests' => both)
          when 2 then detailed_task(status: 'input_required', 'inputRequests' => { 'k2' => elicit_request('two') })
          else detailed_task(status: 'completed', 'result' => call_result)
          end
        when 'tasks/update'
          # The first delivery's acknowledgement is lost; the second lands.
          updates = calls.count { |m, _| m == 'tasks/update' }
          raise MCPClient::Errors::TransportError, 'acknowledgement lost' if updates == 1

          {}
        else raise "unexpected #{method}"
        end
      end

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      # Both were answered once; the resend names only k2, the request the
      # task still lists, and carries the answer k2 was given.
      expect(asked.sort).to eq(%w[one two])
      resent = input_responses(updates_in(calls).last)
      expect(resent.keys).to eq(['k2'])
      expect(resent['k2']['content']).to eq({ 'n' => 'two' })
    end
  end

  describe 'a legacy HTTP server that assigns no session id' do
    let(:base_url) { 'https://example.com' }

    # 2025-11-25 session management makes Mcp-Session-Id optional. A server
    # that never assigns one has no session to end, so a client cleanup
    # leaves its durable tasks — and the handles naming them — usable.
    [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
      it "keeps a retained handle usable across cleanup on #{klass}" do
        server = klass.new(base_url: base_url, endpoint: '/rpc', retries: 0)
        allow(server).to receive(:ping).and_return(true)
        allow(server).to receive(:ensure_session_ready)
        # A negotiated 2025-11-25 session that the server never assigned an
        # Mcp-Session-Id for: the connection is up (so a cleanup would end a
        # session if there were one) and the era is settled as legacy.
        server.instance_variable_set(:@protocol_version, '2025-11-25')
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
        server.instance_variable_set(:@session_id, nil)
        expect(server.protocol_era).to eq(:legacy)
        client = client_for(server)
        handle = MCPClient::Task.from_json(
          { 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => Time.now.utc.iso8601(3),
            'lastUpdatedAt' => Time.now.utc.iso8601(3), 'ttl' => 60_000, 'pollInterval' => 1 }, server: server
        )
        asked = []
        allow(server).to receive(:rpc_request) do |method, params, **_kw|
          asked << [method, params]
          { 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => Time.now.utc.iso8601(3),
            'lastUpdatedAt' => Time.now.utc.iso8601(3) }
        end

        client.cleanup

        # The handle still reaches the server: the task is asked about rather
        # than refused as belonging to a session that never existed.
        expect { client.get_task(handle) }.not_to raise_error
        expect(asked.map(&:first)).to eq(['tasks/get'])
      end
    end
  end

  describe 'what a 2026-07-28 wait reads, and what it does not' do
    # tasks/result is gone in 2026-07-28: the outcome is read from tasks/get.
    # The handshake succeeds here, so the assertion is about the wire.
    it 'reads a finished task with tasks/get and never sends tasks/result' do
      client = client_for
      negotiated
      calls = []
      allow(stdio).to receive(:rpc_request) do |method, params, **_kw|
        calls << [method, params]
        detailed_task(status: 'completed', 'result' => call_result)
      end

      expect(client.get_task_result('task-1')).to eq(call_result)

      expect(calls.map(&:first)).to include('tasks/get')
      expect(calls.map(&:first)).not_to include('tasks/result')
    end

    # Notifications announce; they do not drive. A notifications/tasks that
    # says the task finished — or that it is asking for input — must not end
    # the wait or answer anything on its own: only tasks/get settles it.
    it 'finishes from tasks/get alone, whatever a notification announced' do
      asked = []
      client = client_for(elicitation_handler: lambda { |message, _schema|
        asked << message
        { action: 'accept', content: { 'n' => 'x' } }
      })
      negotiated
      seen = []
      client.on_notification { |_server, method, params| seen << [method, params] }
      calls = []
      polls = 0
      allow(stdio).to receive(:rpc_request) do |method, params, **_kw|
        calls << [method, params]
        polls += 1 if method == 'tasks/get'
        if polls == 1
          # Announced as finished — and as asking for input — before any
          # tasks/get has said so.
          stdio.send(:route_notification, 'notifications/tasks',
                     detailed_task(status: 'completed', 'result' => call_result))
          stdio.send(:route_notification, 'notifications/tasks',
                     detailed_task(status: 'input_required',
                                   'inputRequests' => { 'k1' => elicit_request }))
          detailed_task(status: 'working')
        else
          detailed_task(status: 'completed', 'result' => call_result)
        end
      end

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      # Both notifications reached the host, and neither drove the wait: no
      # tasks/update went out for the request only a notification mentioned,
      # and the host was never asked to answer it.
      expect(seen.map(&:first)).to eq(['notifications/tasks', 'notifications/tasks'])
      expect(asked).to be_empty
      expect(calls.map(&:first)).to eq(['tasks/get', 'tasks/get'])
    end

    # The cancel pin's mirror: an acknowledgement is an empty Result, and an
    # update ack that looks like a finished task is not the task's status.
    it 'does not take a task-shaped tasks/update acknowledgement for the outcome' do
      client = client_for
      negotiated
      calls = []
      polls = 0
      allow(stdio).to receive(:rpc_request) do |method, params, **_kw|
        calls << [method, params]
        case method
        when 'tasks/get'
          polls += 1
          if polls == 1
            detailed_task(status: 'input_required',
                          'inputRequests' => { 'k1' => elicit_request })
          else
            detailed_task(status: 'working')
          end
        when 'tasks/update' then detailed_task(status: 'completed', 'result' => call_result)
        else raise "unexpected #{method}"
        end
      end
      client.update_task('task-1', { 'k1' => { 'action' => 'accept' } })

      # The ack said "completed"; the task is only what tasks/get reports.
      expect(client.get_task('task-1')).not_to be_completed
      expect(calls.map(&:first).last).to eq('tasks/get')
    end
  end

  describe 'a CreateTaskResult where the extension does not allow one' do
    # "A server MUST NOT return CreateTaskResult to a client that did not
    # include the extension capability on its request", and the client MUST
    # treat resultType "task" on any other method as invalid — server/discover
    # included, whichever path processes it.
    def task_shaped_discover
      now = Time.now.utc.iso8601(3)
      { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
        'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1,
        'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
    end

    # The extension is declared and the probe proposes 2026-07-28, which is
    # what widens accepted_result_types to include "task": exactly the state
    # in which the discovery paths used to install a task creation's
    # capabilities. The refusal is a ModernServerError, like the
    # input_required sibling: the era is settled by the discriminator, so the
    # transport must not fall back to the initialize handshake.
    def declaring(server)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.declare_extension(TASKS_EXT)
      expect(server.send(:accepted_result_types)).to include('task')
    end

    it 'is refused when it arrives as the stdio discovery answer' do
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      declaring(server)
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response).and_return('result' => task_shaped_discover)

      expect { server.send(:perform_discover) }.to raise_error(MCPClient::Errors::ModernServerError, /task/)
      expect(server.capabilities).to be_nil
    end

    it 'is refused when it arrives as the HTTP discovery answer' do
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/rpc', retries: 0)
      declaring(server)
      stub_request(:post, 'https://example.com/rpc')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'result' => task_shaped_discover))

      expect { server.send(:perform_discover) }.to raise_error(MCPClient::Errors::ModernServerError, /task/)
      expect(server.capabilities).to be_nil
    end
  end
end
