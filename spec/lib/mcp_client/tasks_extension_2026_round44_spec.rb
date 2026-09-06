# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

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
