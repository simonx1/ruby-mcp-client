# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, fifteenth review round: lexical
# depths follow each resource's dialect, the keyword scan and boolean
# reference targets are bounded by their own position, an unusable input
# schema asserts nothing, and a tautological additionalItems is decided.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 15' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:modern) { 'https://json-schema.org/draft/2020-12/schema' }

  def nested_properties(depth, leaf)
    (1..depth).reduce(leaf) { |inner, _| { 'properties' => { 'a' => inner } } }
  end

  def nested_not(depth, leaf)
    (1..depth).reduce(leaf) { |inner, _| { 'not' => inner } }
  end

  it 'bounds a boolean reference target by its own lexical depth' do
    deep_bool = nested_not(validator::MAX_SCHEMA_DEPTH + 1, true)
    pointer = "#/definitions/n#{'/not' * (validator::MAX_SCHEMA_DEPTH + 1)}"
    schema = { 'properties' => { 'a' => { '$ref' => pointer } }, 'definitions' => { 'n' => deep_bool } }
    expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/depth/))

    shallow = { 'properties' => { 'a' => { '$ref' => '#/definitions/n/not' } },
                'definitions' => { 'n' => { 'not' => true } } }
    expect(validator.check_schema(shallow)).to be_empty
  end

  it 'follows each resource dialect when computing lexical depths, whatever the key order' do
    target = { '$id' => 'https://example.com/r', '$schema' => modern,
               'prefixItems' => [{ 'type' => 'integer' }] }
    chain = nested_properties(validator::MAX_SCHEMA_DEPTH, { '$ref' => '#/definitions/r/prefixItems/0' })
    ref_first = { '$schema' => draft7 }.merge(chain).merge('definitions' => { 'r' => target })
    resource_first = { '$schema' => draft7, 'definitions' => { 'r' => target } }.merge(chain)

    expect(validator.check_schema(ref_first)).to be_empty
    expect(validator.check_schema(resource_first)).to be_empty
  end

  it 'scans a referenced target for unsupported keywords at its own lexical depth' do
    chain = nested_properties(validator::MAX_SCHEMA_DEPTH - 1, { '$ref' => '#/$defs/t' })
    schema = chain.merge('$defs' => { 't' => { 'items' => { 'unevaluatedItems' => false } } })
    expect(validator.check_schema(schema)).to be_empty
    expect(validator.unsupported_keywords(schema)).to include('unevaluatedItems')
  end

  it 'treats a tautological additionalItems beside a tuple as decided' do
    # Two items against a one-schema tuple, so `additionalItems` really does
    # apply to the second: a tautological one still decides the branch.
    schema = { '$schema' => draft7, 'not' => { 'items' => [true], 'additionalItems' => true } }
    expect(validator.validate([1, 2], schema)).to contain_exactly(a_string_matching(/not/))
    empty_schema = { '$schema' => draft7, 'not' => { 'items' => [true], 'additionalItems' => {} } }
    expect(validator.validate([1, 2], empty_schema)).to contain_exactly(a_string_matching(/not/))
    real = { '$schema' => draft7, 'not' => { 'items' => [true], 'additionalItems' => false } }
    expect(validator.validate([1, 2], real)).to be_empty
  end

  describe 'through MCPClient::Client' do
    let(:logger) { Logger.new(StringIO.new) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    it 'sends the call when the input schema is unusable, whatever it claims to require' do
      # An unusable schema asserts nothing, so the server judges the
      # arguments; an unsupported *dialect* is an error instead (MCP
      # 2026-07-28 "Implementation Requirements"), covered in the
      # verification round.
      schema = { 'type' => 'object', 'required' => ['x'],
                 'properties' => { 'x' => { '$ref' => 'https://example.com/x' } } }
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: schema, server: mock_server)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)

      expect { client.call_tool('t', {}) }.not_to raise_error
      expect { client.call_tool('t', {}) }.not_to raise_error
      expect(mock_server).to have_received(:call_tool).twice
    end
  end
end
