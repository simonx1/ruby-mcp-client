# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, fifteenth review round: a wait that is
# active across a server restart follows the new session (a reused task id
# or key is a new request), and a caller holding an outdated session epoch
# can neither delete the newer session's bookkeeping nor become it.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 15' do
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

  it 'answers a reused key again when the server session changed during the wait' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    sent = script_stdio(stdio, [
                          { 'result' => discover_result }, tool_list, { 'result' => task_result },
                          { 'result' => detailed_task(status: 'input_required',
                                                      'inputRequests' => { 'k1' => elicit_request }) },
                          { 'result' => {} },
                          lambda { |_req|
                            # The process restarted while this poll was
                            # outstanding: what came back describes the ended
                            # session and is discarded.
                            stdio.send(:bump_session_epoch)
                            { 'result' => detailed_task(status: 'input_required',
                                                        'inputRequests' => { 'k1' => elicit_request }) }
                          },
                          # The new process reused the task id and the key, and
                          # presents the request again.
                          { 'result' => detailed_task(status: 'input_required',
                                                      'inputRequests' => { 'k1' => elicit_request }) },
                          { 'result' => {} },
                          { 'result' => detailed_task(status: 'completed', 'result' => call_result) }
                        ])

    expect(client.call_tool('slow', {})['isError']).to be(false)
    expect(handled).to eq(2)
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(2)
  end

  it 'reserves keys in the current session even when the wait started in the previous one' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }])
    task = client.call_tool_as_task('slow', {})
    wait = { task_id: 'task-1', srv: stdio, answered: client.send(:answered_task_keys, stdio, 'task-1') }
    old_epoch = stdio.session_epoch
    stdio.send(:bump_session_epoch)

    client.send(:refresh_wait_session, wait)
    wait[:answered] << 'k1'

    expect(wait[:epoch]).to eq(old_epoch + 1)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
    expect(client.instance_variable_get(:@task_states).keys.map { |k| k[1] }.uniq).to eq([old_epoch + 1])
    expect(task).to be_a(MCPClient::Task)
  end

  it 'never lets a caller with an outdated epoch delete or replace the current session state' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result }, { 'result' => {} }])
    task = client.call_tool_as_task('slow', {})
    stdio.send(:bump_session_epoch)
    client.update_task(task, { 'k2' => { 'action' => 'decline' } })
    current = client.send(:task_state, stdio, 'task-1')
    expect(current[:answered]).to include('k2')

    # A request that read the epoch before the restart reports the old one.
    allow(stdio).to receive(:session_epoch).and_return(stdio.session_epoch - 1)
    stale = client.send(:task_state, stdio, 'task-1')

    expect(stale).to equal(current)
    states = client.instance_variable_get(:@task_states)
    expect(states.keys.map { |k| k[1] }.uniq).to eq([current_epoch = states.keys.first[1]])
    expect(current_epoch).to eq(stdio.session_epoch + 1)
    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k2')
  end

  it 'rejects a tasks/get result that lacks the fields a Task must carry' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => { 'resultType' => 'complete', 'taskId' => 'task-1' } }])

    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, %r{tasks/get})
  end

  it 'rejects a tasks/get result without the ttlMs key but accepts a null ttlMs' do
    client = client_for(stdio)
    without_ttl = detailed_task(status: 'working').tap { |t| t.delete('ttlMs') }
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => without_ttl }])
    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /ttlMs/)

    other = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'b')
    client = client_for(other)
    script_stdio(other, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'working', ttl_ms: nil) },
                         { 'result' => detailed_task(status: 'completed', ttl_ms: nil, 'result' => call_result) }])
    expect(client.call_tool('slow', {})['isError']).to be(false)
  end

  it 'requires a failed task to carry a JSON-RPC error object' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'failed', 'error' => {}) }])
    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /error/)

    other = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'b')
    client = client_for(other)
    script_stdio(other, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'failed',
                                                     'error' => { 'code' => -32_000, 'message' => 'boom' }) }])
    expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::ServerError) { |e|
      expect(e.code).to eq(-32_000)
      expect(e.message).to include('boom')
    }
  end
end
