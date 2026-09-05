# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, nineteenth round: the once-per-schema
# checks are keyed by a tool identity that survives the copies the client
# cache hands out, and a refreshed definition is checked again.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 19' do
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

  def tool(input, output = nil)
    MCPClient::Tool.new(name: 'tool', description: 'd', schema: input, output_schema: output, server: mock_server)
  end

  def client_with(tools)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
    allow(mock_server).to receive(:on_notification)
    allow(mock_server).to receive(:list_tools).and_return(tools)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)
  end

  it 'keeps the identity of a tool definition across copies and changes it for a new definition' do
    original = tool({ 'type' => 'object' })
    copy = MCPClient::DeepCopy.copy(original)

    expect(copy).not_to equal(original)
    expect(copy.schema).not_to equal(original.schema)
    expect(copy.schema_identity).to eq(original.schema_identity)
    expect(tool({ 'type' => 'object' }).schema_identity).not_to eq(original.schema_identity)
  end

  it 'warns once about an unusable input schema across cache hits handing out copies' do
    client = client_with([tool({ '$ref' => 'https://example.com/in.json' })])
    allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })
    allow(MCPClient::SchemaValidator).to receive(:check_schema).and_call_original

    first = client.list_tools.first
    second = client.list_tools.first
    expect(second).not_to equal(first)
    2.times { client.call_tool('tool', {}) }

    expect(log_output.string.scan(/input schema.*external \$ref/).size).to eq(1)
    expect(MCPClient::SchemaValidator).to have_received(:check_schema).once
  end

  it 'scans the output schema once per definition across copies and again for a refreshed one' do
    partial = { 'type' => 'object', 'format' => 'custom' }
    client = client_with([tool({ 'type' => 'object' }, partial)])
    allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })
    allow(MCPClient::SchemaValidator).to receive(:unsupported_keywords).and_call_original

    3.times { client.call_tool('tool', {}) }
    expect(MCPClient::SchemaValidator).to have_received(:unsupported_keywords).once

    allow(mock_server).to receive(:list_tools).and_return([tool({ 'type' => 'object' }, partial.dup)])
    client.clear_cache
    client.call_tool('tool', {})
    expect(MCPClient::SchemaValidator).to have_received(:unsupported_keywords).twice
  end
end
