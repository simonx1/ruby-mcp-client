# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

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
