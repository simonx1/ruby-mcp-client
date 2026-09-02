# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

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

      expect(client.call_tool('slow', {})['isError']).to be(false)
      expect(output.string).to include('session restarted')
      expect(answered).to eq(2)
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
