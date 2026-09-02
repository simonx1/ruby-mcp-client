# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twenty-eighth round: a pollIntervalMs the
# clock cannot represent (or that is merely enormous) is bounded, so a wait
# without a caller timeout keeps polling instead of raising from sleep.
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

  [10**400, 10**12].each do |interval|
    it "bounds a pollIntervalMs of #{interval.to_s[0, 6]}… to the maximum pace" do
      client = client_for(stdio)
      script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(interval) },
                           { 'result' => detailed_task(status: 'working', poll_ms: interval) },
                           { 'result' => detailed_task(status: 'completed', poll_ms: interval,
                                                       'result' => call_result) }])

      expect(client.call_tool('slow', {})['isError']).to be(false)
      expect(client).to have_received(:sleep).with(MCPClient::Client::TaskSupport::MAX_TASK_POLL_INTERVAL).at_least(:once)
      expect(client).not_to have_received(:sleep).with(Float::INFINITY)
    end
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
