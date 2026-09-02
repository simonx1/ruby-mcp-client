# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twelfth review round: a lost update is
# carried by the next round's update, a locally completed handle yields its
# result without a server, and the mixin requires what it uses.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 12' do
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

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  it 'carries a lost answer in the update that answers a newly issued key' do
    handled = []
    client = client_for(stdio, elicitation_handler: lambda { |message, _s|
      handled << message
      { action: 'accept', content: { 'n' => 'x' } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'update lost' },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request,
                                                                                 'k2' => elicit_request }) },
                                # the retransmission of k1 is lost again; k2's update must carry k1
                                ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'update lost' },
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    expect(client.call_tool('slow', {})['isError']).to be(false)
    updates = sent.select { |r| r['method'] == 'tasks/update' }
    expect(updates.last['params'][:inputResponses].keys.map(&:to_s)).to contain_exactly('k1', 'k2')
    expect(handled.size).to eq(2)
  end

  it 'returns the result of a locally completed handle without touching the server' do
    client = client_for(stdio)
    task = MCPClient::Task.completed_locally(call_result('sync'), server: stdio)
    allow(stdio).to receive(:ping).and_raise(MCPClient::Errors::ConnectionError, 'gone')
    allow(stdio).to receive(:rpc_request).and_raise('no request expected')

    expect(client.get_task_result(task)['content'].first['text']).to eq('sync')
  end

  it 'drives a wait from the standalone client entry point' do
    script = "require 'mcp_client/client'; " \
             "task = MCPClient::Task.completed_locally({ 'content' => [] }); " \
             'client = MCPClient::Client.new(mcp_server_configs: [], logger: Logger.new(File::NULL)); ' \
             "exit(client.send(:task_state, Object.new, 't')[:answered].is_a?(Set) ? 0 : 3)"
    expect(system(RbConfig.ruby, '-Ilib', '-e', script, out: File::NULL, err: File::NULL)).to be(true)
  end
end
