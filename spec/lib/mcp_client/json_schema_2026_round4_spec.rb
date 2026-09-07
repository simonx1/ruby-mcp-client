# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, fourth review round: contentSchema
# is walked, speculative branches never abort a conforming value, applicator
# values that are not schemas are rejected, boolean item schemas still
# count against the bounds, and log lines sanitize the tool name.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 4' do
  let(:validator) { MCPClient::SchemaValidator }

  it 'walks contentSchema so an external $ref there makes the schema unusable' do
    schema = { 'type' => 'string', 'contentMediaType' => 'application/json',
               'contentSchema' => { '$ref' => 'https://example.com/inner.json' } }
    expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/external \$ref/))
    expect(validator.unsupported_keywords({ 'contentSchema' => { 'type' => 'object' } })).to eq(['contentSchema'])
  end

  it 'never lets a fat rejected branch abort a conforming value' do
    fat = { 'type' => 'object', 'properties' => {} }
    (validator::MAX_ERRORS + 20).times { |i| fat['properties']["p#{i}"] = { 'type' => 'string' } }
    fat['required'] = fat['properties'].keys
    # An object, so the branch really runs its required list and produces the
    # hundred-odd errors: an integer would be decided by `type` alone and the
    # branch would never reach the error cap this example is about.
    data = { 'other' => 1 }
    # The branch really runs: on its own it produces past the error cap.
    expect(validator.validate(data, fat)).to contain_exactly(a_string_matching(/more than .* validation errors/))

    expect(validator.validate(data, { 'anyOf' => [fat, { 'type' => 'object' }] })).to be_empty
    expect(validator.validate(data, { 'not' => fat })).to be_empty
    expect(validator.validate(data, { 'if' => fat, 'then' => false })).to be_empty
    # And a branch the value satisfies still decides the composition.
    expect(validator.validate(1, { 'anyOf' => [fat, { 'type' => 'integer' }] })).to be_empty
  end

  it 'rejects applicator values that are not schemas' do
    expect(validator.check_schema({ 'not' => 5 })).to contain_exactly(a_string_matching(/not.*schema/))
    expect(validator.check_schema({ 'allOf' => [{ 'type' => 'string' }, 'x'] }))
      .to contain_exactly(a_string_matching(/allOf.*schema/))
    expect(validator.check_schema({ 'items' => 'nope' })).to contain_exactly(a_string_matching(/items.*schema/))
    expect(validator.check_schema({ 'properties' => { 'a' => 1 } }))
      .to contain_exactly(a_string_matching(/properties.*schema/))
  end

  it 'counts array elements under a boolean item schema against the visit bound' do
    huge = Array.new(validator::MAX_NODE_VISITS + 10, 1)
    errors = validator.validate(huge, { 'type' => 'array', 'items' => true })
    expect(errors).to contain_exactly(a_string_matching(/aborted/))
  end

  it 'clips huge values without inspecting them whole' do
    huge = Array.new(200_000) { 'x' * 10 }
    allow(huge).to receive(:inspect).and_raise('inspect must not run on the whole value')
    errors = validator.validate(huge, { 'type' => 'string' })
    expect(errors.first).to match(/expected type string, got array/)
    expect(validator.validate(huge, { 'const' => 1 }).first.bytesize).to be < 300
  end

  describe 'through MCPClient::Client' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def tool(output_schema)
      MCPClient::Tool.new(name: "tool\nWARN forged", description: 'd', schema: { 'type' => 'object' },
                          output_schema: output_schema, server: mock_server)
    end

    def client_with(tools)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return(tools)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)
    end

    it 'sanitizes the tool name on the missing-content and partial-coverage log paths' do
      client = client_with([tool({ 'type' => 'object', 'format' => 'custom' })])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })

      client.call_tool("tool\nWARN forged", {})

      expect(log_output.string).to include('no structuredContent')
      expect(log_output.string).to include('validation is partial')
      expect(log_output.string).not_to include("\nWARN forged")
    end
  end
end
