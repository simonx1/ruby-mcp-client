# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, sixteenth review round: a task timestamp
# that does not parse is an invalid result (it can never lift the TTL
# backstop), and the DetailedTask that get_task returns carries the payload
# its status implies.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 16' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(id: 'task-1', ttl_ms: 60_000, created_at: Time.now.utc.iso8601)
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => created_at,
      'lastUpdatedAt' => created_at, 'ttlMs' => ttl_ms, 'pollIntervalMs' => 1 }
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

  %w[createdAt lastUpdatedAt].each do |field|
    it "rejects a polled task whose #{field} does not parse instead of lifting the TTL backstop" do
      client = client_for(stdio)
      polls = 0
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(ttl_ms: 1000) },
                           { 'result' => detailed_task(status: 'working', ttl_ms: 1000) },
                           lambda { |_req|
                             polls += 1
                             { 'result' => detailed_task(status: 'working', ttl_ms: 1000, field => 'not-a-timestamp') }
                           }])

      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /#{field}/)
      expect(polls).to eq(1)
    end
  end

  it 'rejects a CreateTaskResult whose createdAt does not parse' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(created_at: '') }])

    expect { client.call_tool_as_task('slow', {}) }.to raise_error(MCPClient::Errors::InvalidResultError, /createdAt/)
  end

  it 'keeps the TTL backstop until a poll says ttlMs is null' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(ttl_ms: 200) },
                         { 'result' => detailed_task(status: 'working', ttl_ms: 200) },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'stalled' }])

    Timeout.timeout(5) do
      expect { client.call_tool('slow', {}) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    end
  end

  {
    'completed without a result' => [{ status: 'completed' }, /result/],
    'completed with a result that is not an object' => [{ status: 'completed', 'result' => 'done' }, /result/],
    'failed without a JSON-RPC error' => [{ status: 'failed', 'error' => {} }, /error/],
    'input_required without input requests' => [{ status: 'input_required' }, /inputRequests/],
    'input_required with input requests that are not an object' =>
      [{ status: 'input_required', 'inputRequests' => [] }, /inputRequests/]
  }.each do |title, (shape, pattern)|
    it "rejects a DetailedTask from get_task that is #{title}" do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result }, { 'result' => detailed_task(**shape) }])

      expect { client.get_task('task-1') }.to raise_error(MCPClient::Errors::InvalidResultError, pattern)
    end
  end

  it 'returns a well-formed DetailedTask from get_task' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    expect(client.get_task('task-1')).to be_completed
  end
end
