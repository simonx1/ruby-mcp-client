# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

# MCP 2026-07-28 tasks extension, seventh review round: the observed TTL
# bounds every poll, manually submitted input keys are remembered,
# malformed input_required details are rejected at once, keys are reserved
# before handlers run, and a terminal DetailedTask handle is final.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 7' do
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

  it 'bounds polling by the observed TTL even when every poll times out' do
    client = client_for(stdio)
    ttl_deadline = detailed_task(status: 'working', ttl_ms: 300)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => ttl_deadline },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'stalled' }])

    Timeout.timeout(5) do
      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    end
  end

  it 'remembers keys submitted through update_task' do
    client = client_for(stdio)
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })

    expect(client.wait_for_task(task)).to be_completed
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(1)
  end

  it 'rejects an input_required task whose inputRequests is not an object' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'input_required', 'inputRequests' => []) }])

    # Since round 16 the malformed DetailedTask is rejected as an invalid
    # result before the input handling could see it.
    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /inputRequests/)
  end

  it 'reserves input keys before the handlers run so concurrent waits do not both answer' do
    started = Queue.new
    release = Queue.new
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      started << true
      release.pop
      { action: 'accept', content: { 'n' => 'x' } }
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }) },
                         { 'result' => detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }) },
                         { 'result' => {} },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})
    first = client.get_task(task)
    second = client.get_task(task)

    t1 = Thread.new do
      client.send(:answer_task_input_requests, first, client.send(:answered_task_keys, stdio, 'task-1'), stdio)
    end
    started.pop
    t2 = Thread.new do
      client.send(:answer_task_input_requests, second, client.send(:answered_task_keys, stdio, 'task-1'), stdio)
    end
    sleep 0.1
    release << true
    release << true
    t1.join
    t2.join

    expect(handled).to eq(1)
  end

  it 'treats a terminal DetailedTask handle as final without polling again' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result('final')) }])
    task = client.get_task('task-1')

    expect(client.wait_for_task(task)).to equal(task)
    expect(client.get_task_result(task)['content'].first['text']).to eq('final')
  end
end
