# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twenty-eighth round: a pollIntervalMs the
# clock cannot represent is bounded, so a wait without a caller timeout keeps
# polling instead of raising from sleep — while one it can represent is kept,
# whatever its size.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 28' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(poll_ms)
    now = Time.now.utc.iso8601
    { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => poll_ms }
  end

  def detailed_task(status:, poll_ms:, **extra)
    now = Time.now.utc.iso8601
    { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def tool_list
    { 'result' => { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }], 'ttlMs' => 60_000 } }
  end

  def call_result
    { 'content' => [{ 'type' => 'text', 'text' => 'done' }], 'isError' => false }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      responder.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
    allow(client).to receive(:sleep)
    client
  end

  def polling(interval)
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(interval) },
                         { 'result' => detailed_task(status: 'working', poll_ms: interval) },
                         { 'result' => detailed_task(status: 'completed', poll_ms: interval,
                                                     'result' => call_result) }])

    expect(client.call_tool('slow', {})['isError']).to be(false)
    client
  end

  it 'bounds a pollIntervalMs the clock cannot represent' do
    client = polling(10**400)

    expect(client).to have_received(:sleep).with(MCPClient::Client::TaskSupport::MAX_TASK_POLL_INTERVAL).at_least(:once)
    expect(client).not_to have_received(:sleep).with(Float::INFINITY)
  end

  # The bound is there for what sleep would refuse, not to overrule a server:
  # an interval of eleven and a half days is a pace, and it is kept.
  it 'keeps a pollIntervalMs the clock can represent, however long' do
    client = polling(1_000_000_000)

    expect(client).to have_received(:sleep).with(1_000_000.0).at_least(:once)
    expect(client).not_to have_received(:sleep).with(86_400.0)
  end

  it 'still clamps the pace to what is left of the caller timeout' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(10**400) },
                         { 'result' => detailed_task(status: 'working', poll_ms: 10**400) },
                         { 'result' => detailed_task(status: 'completed', poll_ms: 10**400,
                                                     'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})

    expect(client.wait_for_task(task, timeout: 2)).to be_completed
    expect(client).to have_received(:sleep).with(a_value <= 2.0).at_least(:once)
  end
end
