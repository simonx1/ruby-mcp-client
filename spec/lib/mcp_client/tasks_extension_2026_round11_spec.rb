# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, eleventh review round: a later update
# carries every response still pending from an ambiguous earlier update, a
# handle from another server neither seeds nor colours a wait or a cancel
# on the server named explicitly, and symbol-keyed camelCase task fields
# count as the modern shape.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 11' do
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

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }
  let(:other) { MCPClient::ServerStdio.new(command: 'echo other', read_timeout: 1, name: 'b') }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
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

  it 'carries responses still pending from an earlier ambiguous update in a later update' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    input = { 'result' => detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }) }
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, input,
                                lambda { |_req|
                                  Kernel.sleep 0.1
                                  raise MCPClient::Errors::RequestTimeoutError, 'update lost'
                                },
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})
    expect { client.wait_for_task(task, timeout: 0.05) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)

    # The host answers another key: the update the server actually sees
    # must still carry k1, whose delivery was never confirmed.
    client.update_task(task, { 'k2' => { 'action' => 'decline' } })
    expect(client.wait_for_task(task)).to be_completed

    updates = sent.select { |r| r['method'] == 'tasks/update' }.map { |r| r['params'][:inputResponses] }
    expect(updates.size).to eq(2)
    expect(updates.last).to eq('k1' => { 'action' => 'accept', 'content' => { 'n' => 'x' } },
                               'k2' => { 'action' => 'decline' })
    expect(handled).to eq(1)
  end

  it 'does not seed a wait on an explicitly named server with another server\'s handle' do
    client = two_server_client
    script_stdio(stdio, [{ 'result' => discover_result }])
    script_stdio(other, [{ 'result' => discover_result },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'stalled' },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    # A handle from server a whose TTL is long gone and whose pace is slow.
    foreign = MCPClient::Task.new(task_id: 'task-1', status: 'working', created_at: '2000-01-01T00:00:00Z',
                                  ttl: 1000, poll_interval: 250, server: stdio, modern: true)

    expect(client.wait_for_task(foreign, server: 'b')).to be_completed
    expect(client).not_to have_received(:sleep).with(0.25)
  end

  it 'does not copy the status of another server\'s handle into a cancel acknowledgement' do
    client = two_server_client
    script_stdio(stdio, [{ 'result' => discover_result }])
    script_stdio(other, [{ 'result' => discover_result }, { 'result' => {} }])
    foreign = MCPClient::Task.new(task_id: 'task-1', status: 'completed', server: stdio, modern: true)

    cancelled = client.cancel_task(foreign, server: 'b')

    expect(cancelled.server).to equal(other)
    expect(cancelled).not_to be_completed
    expect(cancelled.status).to eq('working')
  end

  it 'recognises symbol-keyed camelCase fields as the modern shape' do
    task = MCPClient::Task.from_json({ taskId: 't-1', status: 'working', resultType: 'complete', ttlMs: 5000,
                                       pollIntervalMs: 100 })

    expect(task.ttl).to eq(5000)
    expect(task.poll_interval).to eq(100)
    expect(task.to_h).to include('ttlMs' => 5000, 'pollIntervalMs' => 100)
    expect(task.to_h).not_to have_key('ttl')
  end
end
