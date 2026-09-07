# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

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
