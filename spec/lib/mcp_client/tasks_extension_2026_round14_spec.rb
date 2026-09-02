# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, fourteenth review round: a retransmission
# sends only what is still pending, so an answer a later confirmed update
# superseded is never sent again, and the bookkeeping of a previous server
# session is dropped, not orphaned.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 14' do
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

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'Name?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def wire(request)
    JSON.parse(JSON.generate(request))
  end

  it 'never resends a lost answer that a later confirmed update superseded' do
    client = client_for(stdio, elicitation_handler: ->(_m, _s) { { action: 'accept', content: { 'n' => 'x' } } })
    task = nil
    sent = script_stdio(stdio, [
                          { 'result' => discover_result }, tool_list, { 'result' => task_result },
                          { 'result' => detailed_task(status: 'input_required',
                                                      'inputRequests' => { 'k1' => elicit_request }) },
                          ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'accept lost' },
                          # The host's own decline for k1 lands (and is confirmed) before the next
                          # poll answers; the lost accept must not be sent after it.
                          lambda { |_req|
                            client.update_task(task, { 'k1' => { 'action' => 'decline' } })
                            { 'result' => detailed_task(status: 'input_required',
                                                        'inputRequests' => { 'k1' => elicit_request }) }
                          },
                          { 'result' => {} },
                          { 'result' => detailed_task(status: 'completed', 'result' => call_result) }
                        ])
    task = client.call_tool_as_task('slow', {})

    expect(client.wait_for_task(task)).to be_completed
    updates = sent.select { |r| r['method'] == 'tasks/update' }.map { |r| wire(r)['params']['inputResponses'] }
    expect(updates.map { |u| u['k1']['action'] }).to eq(%w[accept decline])
  end

  it 'sends only what is still pending once the update lock is held' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }])
    task = client.call_tool_as_task('slow', {})
    client.send(:task_state, stdio, 'task-1')[:pending_update] = { 'k1' => { 'action' => 'accept' } }
    updates = []
    allow(stdio).to receive(:rpc_request) do |method, params, **|
      raise "unexpected #{method}" unless method == 'tasks/update'

      updates << wire(params)['inputResponses']
      {}
    end
    # The retransmission has read the pending slot but not taken the lock
    # yet when the host's decline for the same key lands and is confirmed.
    snapshot_taken = Queue.new
    decline_confirmed = Queue.new
    allow(client).to receive(:shown_task_id).and_wrap_original do |original, *args|
      if Thread.current[:retransmitting] && !Thread.current[:gated]
        Thread.current[:gated] = true
        snapshot_taken << true
        decline_confirmed.pop
      end
      original.call(*args)
    end
    retransmission = Thread.new do
      Thread.current[:retransmitting] = true
      client.send(:retransmit_pending_update, { srv: stdio, task_id: 'task-1' })
    end
    snapshot_taken.pop
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })
    decline_confirmed << true
    retransmission.join

    expect(updates.map { |u| u['k1']['action'] }).to eq(['decline'])
    expect(client.send(:task_state, stdio, 'task-1')[:pending_update]).to be_nil
  end

  it 'lets a newer explicit answer win over a pending one for the same key' do
    client = client_for(stdio)
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'lost' },
                                { 'result' => {} }])
    task = client.call_tool_as_task('slow', {})
    expect { client.update_task(task, { 'k1' => { 'action' => 'accept' } }) }.to raise_error(MCPClient::Errors::TaskError)

    client.update_task(task, { 'k1' => { 'action' => 'decline' } })

    last = wire(sent.select { |r| r['method'] == 'tasks/update' }.last)['params']['inputResponses']
    expect(last).to eq({ 'k1' => { 'action' => 'decline' } })
    expect(client.send(:task_state, stdio, 'task-1')[:pending_update]).to be_nil
  end

  it 'drops the bookkeeping of a previous server session' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, { 'result' => {} }])
    task = client.call_tool_as_task('slow', {})
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })
    states = client.instance_variable_get(:@task_states)
    expect(states.keys.count { |k| k.first == stdio.object_id }).to eq(1)

    stdio.cleanup
    client.send(:task_state, stdio, 'task-2')

    kept = states.keys.select { |k| k.first == stdio.object_id }
    expect(kept.map { |k| k[1] }.uniq).to eq([stdio.session_epoch])
    expect(kept.map(&:last)).to eq(['task-2'])
  end

  it 'forgets every task on Client#cleanup' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, { 'result' => {} }])
    task = client.call_tool_as_task('slow', {})
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })

    client.cleanup

    expect(client.instance_variable_get(:@task_states)).to be_nil.or be_empty
  end
end
