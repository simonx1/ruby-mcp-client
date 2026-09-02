# frozen_string_literal: true

require 'spec_helper'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, twenty-seventh round: a synchronous answer
# to call_tool_as_task is validated against the tool definition a mid-call
# HeaderMismatch refresh replaced, like call_tool; ttl_elapsed? tolerates a
# ttlMs too large for a Time.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 27' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def tool_with(required)
    MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                        output_schema: { 'type' => 'object', 'required' => required }, server: stdio)
  end

  it 'validates a synchronous call_tool_as_task answer against the refreshed tool' do
    loose = tool_with([])
    strict = tool_with(['b'])
    generation = 1
    stdio.define_singleton_method(:tools_generation) { generation }
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    allow(stdio).to receive_messages(list_tools: [loose], modern?: true, ping: true,
                                     capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(stdio).to receive(:call_tool) do
      # A HeaderMismatch refresh replaced the definition while the call ran.
      generation = 2
      allow(stdio).to receive(:list_tools).and_return([strict])
      { 'content' => [], 'structuredContent' => {} }
    end
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   validate_structured_content: :strict)

    expect { client.call_tool_as_task('sync', {}) }.to raise_error(MCPClient::Errors::ValidationError)
  end

  it 'accepts a synchronous answer the refreshed tool allows' do
    strict = tool_with(['a'])
    loose = tool_with([])
    generation = 1
    stdio.define_singleton_method(:tools_generation) { generation }
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
    allow(stdio).to receive_messages(list_tools: [strict], modern?: true, ping: true,
                                     capabilities: { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } })
    allow(stdio).to receive(:call_tool) do
      generation = 2
      allow(stdio).to receive(:list_tools).and_return([loose])
      { 'content' => [], 'structuredContent' => {} }
    end
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   validate_structured_content: :strict)

    expect(client.call_tool_as_task('sync', {})).to be_completed
  end

  it 'reports no TTL elapse for an overflowing ttlMs instead of raising' do
    now = Time.now.utc.iso8601
    task = MCPClient::Task.from_json({ 'taskId' => 't', 'status' => 'working', 'createdAt' => now,
                                       'lastUpdatedAt' => now, 'ttlMs' => 10**400 }, server: stdio)

    expect { task.ttl_elapsed? }.not_to raise_error
    expect(task.ttl_elapsed?).to be(false)
  end
end
