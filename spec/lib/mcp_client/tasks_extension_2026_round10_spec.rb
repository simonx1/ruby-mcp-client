# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, tenth review round: only a definite
# JSON-RPC rejection of tasks/update gives keys back (a 5xx or an untyped
# server error is ambiguous and is retransmitted), a terminal task observed
# after the caller's deadline does not rescue a timed-out wait, a later
# observation with ttlMs null lifts the TTL backstop, a completed task's
# result must be an object, and round accounting is atomic.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 10' do
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

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  {
    'a 5xx' => -> { raise MCPClient::Errors::TransientServerError, 'HTTP 503 Service Unavailable' },
    'an untyped server error' => -> { raise MCPClient::Errors::ServerError, 'response stream closed' }
  }.each do |label, failure|
    it "keeps the keys and retransmits the update after #{label}" do
      handled = 0
      client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
        handled += 1
        { action: 'accept', content: { 'n' => 'x' } }
      })
      sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                  { 'result' => detailed_task(status: 'input_required',
                                                              'inputRequests' => { 'k1' => elicit_request }) },
                                  ->(_req) { failure.call },
                                  { 'result' => detailed_task(status: 'input_required',
                                                              'inputRequests' => { 'k1' => elicit_request }) },
                                  { 'result' => {} },
                                  { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
      task = client.call_tool_as_task('slow', {})

      expect(client.wait_for_task(task)).to be_completed
      expect(handled).to eq(1)
      updates = sent.select { |r| r['method'] == 'tasks/update' }
      expect(updates.size).to eq(2)
      expect(updates.map { |r| r['params'][:inputResponses].keys }).to all(eq(['k1']))
    end
  end

  it 'lets call_tool survive a lost tasks/update' do
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

    expect(client.call_tool('slow', {})['isError']).to be(false)
    expect(handled).to eq(1)
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(2)
  end

  it 'presents the request again after a retransmitted update was rejected' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    input = { 'result' => detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }) }
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, input,
                                ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'update lost' },
                                input,
                                { 'error' => { 'code' => -32_602, 'message' => 'inputResponses: bad content' } },
                                input,
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::TaskError, /bad content/)
    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(2)
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(3)
  end

  it 'retransmits an update the host sent through update_task when its acknowledgement was lost' do
    client = client_for(stdio)
    input = { 'result' => detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }) }
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'update lost' },
                                input, { 'result' => {} },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})

    expect { client.update_task(task, { 'k1' => { 'action' => 'decline' } }) }
      .to raise_error(MCPClient::Errors::TaskError, /update lost/)
    expect(client.wait_for_task(task)).to be_completed
    updates = sent.select { |r| r['method'] == 'tasks/update' }
    expect(updates.size).to eq(2)
    expect(updates.last['params'][:inputResponses]).to eq({ 'k1' => { 'action' => 'decline' } })
  end

  it 'drops a pending payload once a later update_task succeeds' do
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

    client.update_task(task, { 'k1' => { 'action' => 'decline' } })
    expect(client.wait_for_task(task)).to be_completed

    updates = sent.select { |r| r['method'] == 'tasks/update' }.map { |r| r['params'][:inputResponses] }
    expect(updates).to eq([{ 'k1' => { 'action' => 'accept', 'content' => { 'n' => 'x' } } },
                           { 'k1' => { 'action' => 'decline' } }])
    expect(handled).to eq(1)
  end

  it "paces a timed-out first poll by the created task's pollIntervalMs" do
    client = client_for(stdio)
    seed = task_result.merge('pollIntervalMs' => 250)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => seed },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'stalled' },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    client.call_tool('slow', {})

    expect(client).to have_received(:sleep).with(0.25).once
  end

  it 'bounds tasks/update by the remaining wait and starts no handler round after the deadline' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    two = { 'result' => detailed_task(status: 'input_required',
                                      'inputRequests' => { 'k1' => elicit_request, 'k2' => elicit_request }) }
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }) },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'update lost' },
                         two,
                         lambda { |_req|
                           Kernel.sleep 0.45
                           { 'result' => {} }
                         }])
    allow(stdio).to receive(:rpc_request).and_call_original
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task, timeout: 0.4) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(handled).to eq(1)
    expect(stdio).to have_received(:rpc_request)
      .with('tasks/update', anything, hash_including(timeout: a_value <= 0.4)).at_least(:once)
  end

  it 'sanitizes peer text in list_tasks errors' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping).and_raise(MCPClient::Errors::ConnectionError, "down\nWARN forged")

    expect { client.list_tasks }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e.message).not_to include("\nWARN forged")
    }
  end

  it 'does not let a terminal task observed after the deadline rescue a timed-out wait' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         lambda { |_req|
                           Kernel.sleep 0.1
                           { 'result' => detailed_task(status: 'completed', 'result' => call_result) }
                         }])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task, timeout: 0.05) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
  end

  it 'lifts the TTL backstop when a later observation makes the task unlimited' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         ->(_req) { { 'result' => detailed_task(status: 'working', ttl_ms: 200) } },
                         lambda { |_req|
                           Kernel.sleep 0.25
                           { 'result' => detailed_task(status: 'working', ttl_ms: nil) }
                         },
                         lambda { |_req|
                           Kernel.sleep 0.05
                           { 'result' => detailed_task(status: 'completed', ttl_ms: nil, 'result' => call_result) }
                         }])

    expect(client.call_tool('slow', {})['isError']).to be(false)
  end

  ['done', ['done'], 7].each do |result|
    it "rejects a completed task whose result is #{result.inspect} rather than an object" do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                           { 'result' => detailed_task(status: 'completed', 'result' => result) }])

      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /result/)
    end
  end

  it 'consumes one round when two waits answer the same input request' do
    started = Queue.new
    release = Queue.new
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      started << true
      release.pop
      { action: 'accept', content: { 'n' => 'x' } }
    })
    input = { 'result' => detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request }) }
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, input, input,
                         { 'result' => {} }, { 'result' => {} }])
    task = client.call_tool_as_task('slow', {})
    first = client.get_task(task)
    second = client.get_task(task)
    state = client.send(:task_state, stdio, 'task-1')
    state[:rounds] = MCPClient::Client::TaskSupport::MAX_TASK_INPUT_ROUNDS - 1
    wait = { task_id: 'task-1', srv: stdio, answered: state[:answered] }

    t1 = Thread.new { client.send(:answer_task_round, first, wait) }
    started.pop
    # The second wait sees the same snapshot: nothing left to answer, no
    # round spent, no limit error.
    expect { client.send(:answer_task_round, second, wait) }.not_to raise_error
    release << true
    t1.join

    expect(handled).to eq(1)
    expect(state[:rounds]).to eq(MCPClient::Client::TaskSupport::MAX_TASK_INPUT_ROUNDS)
  end
end
