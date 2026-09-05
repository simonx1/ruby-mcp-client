# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 tasks extension, eighth review round: a poll request never
# waits for the whole TTL, a lost update is retransmitted, the input-round
# cap is per task, list_tasks needs a known era, timed-out polls keep the
# server's pace, and the last raw peer text is sanitized.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 8' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(id: 'task-1')
    now = Time.now.utc.iso8601
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => 60_000, 'pollIntervalMs' => 1 }
  end

  def detailed_task(status:, id: 'task-1', ttl_ms: 60_000, poll_ms: 1, **extra)
    now = Time.now.utc.iso8601
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

  it 'caps the request timeout of a poll even when the TTL is long' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'working', ttl_ms: 3_600_000) }])
    allow(stdio).to receive(:rpc_request).and_call_original
    allow(stdio).to receive(:rpc_request)
      .with('tasks/get', anything, hash_including(timeout: a_value <= MCPClient::Client::TaskSupport::MAX_TASK_REQUEST_TIMEOUT))
      .and_return(detailed_task(status: 'completed', 'result' => call_result))

    expect(client.call_tool('slow', {})['isError']).to be(false)
  end

  it 'retransmits an update whose delivery failed before answering anything else' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'update lost' },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})

    # The lost update is not the end of the wait: it goes out again with
    # the next poll (round 10).
    expect(client.wait_for_task(task)).to be_completed
    updates = sent.select { |r| r['method'] == 'tasks/update' }
    expect(updates.size).to eq(2)
    expect(handled).to eq(1)
  end

  it 'counts input rounds per task across waits' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    keys = 0
    # Every poll asks for a new key; every update is acknowledged.
    server = lambda { |req|
      next { 'result' => {} } if req['method'] == 'tasks/update'

      keys += 1
      { 'result' => detailed_task(status: 'input_required', poll_ms: 20,
                                  'inputRequests' => { "k#{keys}" => elicit_request }) }
    }
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, server])
    task = client.call_tool_as_task('slow', {})
    # A clock that only moves when the wait sleeps: the first wait gets
    # exactly four rounds at the pace the server asks for, then times out.
    now = 0.0
    allow(client).to receive(:monotonic_time) { now }
    allow(client).to receive(:sleep) { |seconds| now += seconds }

    expect { client.wait_for_task(task, timeout: 0.2) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    spent = sent.count { |r| r['method'] == 'tasks/update' }
    expect(spent).to eq(4)

    # The second wait resumes the count where the first left it: what the cap
    # bounds is the task's rounds, not one wait's.
    expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::InputRequiredError, /round/)
    expect(sent.count { |r| r['method'] == 'tasks/update' })
      .to eq(MCPClient::Client::TaskSupport::MAX_TASK_INPUT_ROUNDS)
    expect(handled).to eq(MCPClient::Client::TaskSupport::MAX_TASK_INPUT_ROUNDS)
  end

  it 'refuses list_tasks when the server era cannot be established' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping).and_raise(MCPClient::Errors::ConnectionError, 'down')
    allow(stdio).to receive(:rpc_request).and_raise('tasks/list must not be sent')

    expect { client.list_tasks }.to raise_error(MCPClient::Errors::TaskError, /down/)
  end

  it 'keeps the server pace after a poll timed out' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'working', poll_ms: 250) },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'stalled' },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    client.call_tool('slow', {})

    expect(client).to have_received(:sleep).with(0.25).twice
  end

  it 'sanitizes the terminal-task cancel error' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'error' => { 'code' => -32_602, 'message' => "Task is terminal\nWARN forged" } }])

    expect { client.cancel_task("t\nWARN forged") }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e.message).not_to include("\nWARN forged")
    }
  end
end
