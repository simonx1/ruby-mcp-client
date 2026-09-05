# frozen_string_literal: true

require 'spec_helper'

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
      allow(stdio).to receive(:rpc_request) do |method, _params|
        sent << method
        {}
      end

      expect(client.update_task(handle, { 'k1' => accept })).to be(true)
      expect(client.cancel_task(handle).task_id).to eq('task-1')
      expect(sent).to eq(['tasks/update', 'tasks/cancel'])
    end

    it 'keeps a handle the legacy creation API produced usable too' do
      client = client_for
      negotiated
      epoch = client.send(:current_session_epoch, stdio)
      # The 2025 path unwraps the `task` member first, so it counts the
      # lifetime of a handle that already exists.
      handle = client.send(:started_task_lifetime,
                           MCPClient::Task.new(task_id: 'task-1', status: 'working', server: stdio,
                                               session_epoch: epoch),
                           stdio, epoch)
      (1..cap).each { |i| creation(client, "other-#{i}") }
      allow(stdio).to receive(:rpc_request).and_return(detailed_task(status: 'working'))

      expect(client.get_task(handle).status).to eq('working')
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
        client.send(:retransmit_pending_update, { srv: stdio, task_id: 'task-1' })
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
    # The transport's own wire path: only send_request is stubbed, so the
    # pre-write check every built-in transport makes runs for real.
    def wired(server)
      sent = []
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      allow(server).to receive(:ensure_initialized).and_return(true)
      server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
      allow(server).to receive(:send_request) { |req| sent << req }
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
