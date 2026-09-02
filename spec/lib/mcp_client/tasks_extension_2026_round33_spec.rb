# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, thirty-third round: the automatic session
# recovery of the HTTP transports (an HTTP 404 answering a request that
# carried an Mcp-Session-Id, which the client MUST answer with a fresh
# InitializeRequest) ends the session it replaces. The task bookkeeping keyed
# by that session — answered keys, pending answers, rounds — dies with it,
# exactly as it does for a cleanup or a restarted stdio process, and nothing
# built in the old session is written into the new one.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 33' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }
  let(:url) { "#{base_url}#{endpoint}" }
  # Sessions (and so the 404 recovery) belong to the initialize handshake:
  # a modern server has none.
  let(:server) do
    MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: :legacy,
                                        name: 'sess-test')
  end

  after { server.cleanup }

  def initialize_result
    { 'protocolVersion' => '2025-11-25',
      'capabilities' => { 'tools' => {}, 'tasks' => { 'get' => true, 'list' => true, 'cancel' => true } },
      'serverInfo' => { 'name' => 's', 'version' => '1' } }
  end

  def task_result
    now = Time.now.utc.iso8601(3)
    { 'taskId' => 'task-1', 'status' => 'completed', 'createdAt' => now, 'lastUpdatedAt' => now,
      'pollIntervalMs' => 1, 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'done' }],
                                           'isError' => false } }
  end

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  # A server that hands out a fresh session on every handshake and answers
  # anything still carrying the first one with the 404 that ends it.
  def stub_streamable(sent:, results: {})
    sessions = 0
    stub_request(:get, url).to_return(status: 200, body: '')
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      method = body['method']
      sent << [method, request.headers['Mcp-Session-Id']]
      if method == 'initialize'
        sessions += 1
        json_response(body['id'], initialize_result)
          .tap { |r| r[:headers]['Mcp-Session-Id'] = "sess-#{sessions}" }
      elsif method.start_with?('notifications/')
        { status: 202, body: '' }
      elsif request.headers['Mcp-Session-Id'] == 'sess-1'
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

  # A wait that has joined the session the transport is in, the way
  # #wait_for_task's first pass does.
  def wait_joined(client)
    wait = { task_id: 'task-1', srv: server, deadline: nil, ttl_deadline: nil,
             answered: nil, state: nil, epoch: nil, last: nil }
    client.send(:refresh_wait_session, wait)
    wait
  end

  describe 'a session the server invalidated with 404 mid-wait' do
    it 'does not carry its answered keys into the session that replaces it' do
      sent = []
      stub_streamable(sent: sent, results: { 'tasks/get' => task_result })
      client = client_for(server)
      server.connect
      wait = wait_joined(client)
      client.send(:remember_answered_keys, server, 'task-1', ['k1'])
      expect(wait[:answered]).to include('k1')

      client.send(:poll_task, wait)

      # The 404 restarted the session: a second handshake went out.
      expect(sent.count { |method, _| method == 'initialize' }).to eq(2)
      expect(client.send(:refresh_wait_session, wait)).to be(true)
      expect(wait[:answered]).to be_empty
      expect(client.send(:answered_task_keys, server, 'task-1')).to be_empty
    end

    it 'does not resend the poll of the ended session into the new one' do
      sent = []
      stub_streamable(sent: sent, results: { 'tasks/get' => task_result })
      client = client_for(server)
      server.connect
      wait = wait_joined(client)

      # A lost poll, not an observation of a task the new session may know
      # nothing about: the wait polls the live session again.
      expect(client.send(:poll_task, wait)).to be_nil
      expect(sent.count { |method, _| method == 'tasks/get' }).to eq(1)
    end

    it 'puts no pinned request on the wire of the session that replaced its own' do
      sent = []
      stub_streamable(sent: sent, results: { 'tasks/get' => task_result })
      client = client_for(server)
      server.connect
      wait = wait_joined(client)
      # A cleanup (or a reconnect) completes after the request was cleared
      # for its session and before the send picks the session to write it to.
      allow(server).to receive(:http_connection).and_wrap_original do |original, *args|
        server.send(:bump_session_epoch)
        original.call(*args)
      end

      expect(client.send(:poll_task, wait)).to be_nil
      expect(sent.count { |method, _| method == 'tasks/get' }).to eq(0)
    end

    it 'still resends a request that belongs to no session' do
      sent = []
      stub_streamable(sent: sent, results: { 'tools/list' => { 'tools' => [] } })
      client_for(server)
      server.connect
      epoch = server.session_epoch

      expect(server.rpc_request('tools/list', {})).to eq({ 'tools' => [] })
      expect(sent.count { |method, _| method == 'tools/list' }).to eq(2)
      expect(server.session_epoch).to be > epoch
    end
  end

  # The stdio side of the same rule: a session that ends mid-wait takes its
  # task with it.
  describe 'a wait whose own session ends' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def detailed_task(status:, **extra)
      now = Time.now.utc.iso8601(3)
      { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
        'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }.merge(extra)
    end

    def call_result(text = 'done')
      { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
    end

    def task_from(hash)
      MCPClient::Task.from_json(hash, server: stdio, detailed: true)
    end

    def stdio_client
      allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
      allow(client).to receive(:sleep)
      allow(stdio).to receive(:capabilities).and_return({ 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
      allow(stdio).to receive(:modern?).and_return(true)
      client
    end

    def wait_joined_on(client, srv)
      wait = { task_id: 'task-1', srv: srv, deadline: nil, ttl_deadline: nil,
               answered: nil, state: nil, epoch: nil, last: nil }
      client.send(:refresh_wait_session, wait)
      wait
    end

    it 'keeps the terminal result its own session answered' do
      client = stdio_client
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        observation = task_from(detailed_task(status: 'completed', 'result' => call_result('this task')))
        # The session ends once the answer is in hand: the poll was pinned to
        # the session that produced it, so the payload is this task's own.
        stdio.send(:bump_session_epoch)
        observation
      end

      expect(client.wait_for_task('task-1', server: stdio, timeout: 2).result).to eq(call_result('this task'))
      expect(polls).to eq(1)
    end

    it 'never polls the session that replaced its own for the reused task id' do
      client = stdio_client
      polls = 0
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        stdio.send(:bump_session_epoch)
        nil
      end

      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(polls).to eq(1)
    end

    it 'refuses to wait on a live handle whose session has ended' do
      client = stdio_client
      handle = MCPClient::Task.new(task_id: 'task-1', status: 'working', server: stdio, modern: true)
      stdio.send(:bump_session_epoch)
      allow(stdio).to receive(:rpc_request)

      expect { client.wait_for_task(handle, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(stdio).not_to have_received(:rpc_request)
    end

    it 'refuses a tasks/get for a handle whose session has ended' do
      client = stdio_client
      handle = MCPClient::Task.new(task_id: 'task-1', status: 'working', server: stdio, modern: true)
      stdio.send(:bump_session_epoch)
      allow(stdio).to receive(:rpc_request)

      expect { client.get_task(handle) }.to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(stdio).not_to have_received(:rpc_request)
    end

    it 'writes no pinned request into the process that replaced its own' do
      client = stdio_client
      wait = wait_joined_on(client, stdio)
      stdin = double('stdin')
      allow(stdin).to receive(:puts)
      stdio.instance_variable_set(:@stdin, stdin)
      allow(stdio).to receive(:ensure_initialized)
      # The child dies after the request was cleared for its session and
      # before it is written to the pipe.
      allow(stdio).to receive(:build_jsonrpc_request).and_wrap_original do |original, *args|
        stdio.send(:bump_session_epoch)
        original.call(*args)
      end

      expect(client.send(:poll_task, wait)).to be_nil
      expect(stdin).not_to have_received(:puts)
    end

    it 'ends when the session moved while the wait slept between polls' do
      client = stdio_client
      polls = 0
      allow(client).to receive(:sleep) { stdio.send(:bump_session_epoch) }
      allow(client).to receive(:poll_task) do |w|
        polls += 1
        w[:polled] = true
        task_from(detailed_task(status: 'working'))
      end

      expect { client.wait_for_task('task-1', server: stdio, timeout: 2) }
        .to raise_error(MCPClient::Errors::TaskError, /session it belongs to ended/i)
      expect(polls).to eq(1)
    end

    it 'refuses a legacy tasks/result for a handle whose session has ended' do
      client = stdio_client
      allow(stdio).to receive(:modern?).and_return(false)
      handle = MCPClient::Task.new(task_id: 'task-1', status: 'completed', server: stdio)
      stdio.send(:bump_session_epoch)
      allow(stdio).to receive(:rpc_request)

      expect { client.get_task_result(handle) }.to raise_error(MCPClient::Errors::TaskError, /session/i)
      expect(stdio).not_to have_received(:rpc_request)
    end

    it "does not unmark the replacement session's keys when an ended delivery is dropped" do
      client = stdio_client
      wait = wait_joined_on(client, stdio)
      stdio.send(:bump_session_epoch)
      # The new session reserved the reused key for what is a different
      # request; the ended session's delivery must not give it back.
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])

      client.send(:deliver_task_update, stdio, 'task-1', { 'k1' => { 'action' => 'accept' } }, wait)

      expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    end
  end
end
