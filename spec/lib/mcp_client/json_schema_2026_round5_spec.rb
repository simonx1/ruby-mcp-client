# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, fifth review round: the keyword
# grammar follows the dialect (draft-07 dependencies, keywords unknown to a
# dialect are ignored), a draft-07 $ref hides its siblings at preflight
# too, plain-name fragments resolve to anchors, an empty outputSchema is a
# schema, exclusive bounds are numbers under draft-07 too, and an external
# $recursiveRef makes a 2019-09 schema unusable.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 5' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:draft2019) { 'https://json-schema.org/draft/2019-09/schema' }

  describe 'dialect-specific keyword grammar' do
    let(:dependencies) do
      { 'type' => 'object',
        'properties' => { 'credit_card' => { 'type' => 'string' }, 'billing_address' => { 'type' => 'string' } },
        'dependencies' => { 'credit_card' => ['billing_address'] } }
    end

    it 'accepts the draft-07 property form of dependencies and reports it as unevaluated' do
      schema = dependencies.merge('$schema' => draft7)
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'credit_card' => '4111', 'billing_address' => 'x' }, schema)).to be_empty
      expect(validator.unsupported_keywords(schema)).to eq(['dependencies'])
    end

    it 'ignores dependencies entirely under 2020-12, where the keyword does not exist' do
      expect(validator.check_schema(dependencies)).to be_empty
      expect(validator.validate({ 'credit_card' => '4111' }, dependencies)).to be_empty
      expect(validator.unsupported_keywords(dependencies)).to be_empty
    end

    it 'still rejects a draft-07 dependencies entry that is neither a schema nor property names' do
      schema = { '$schema' => draft7, 'dependencies' => { 'a' => 5 } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/dependencies/))
    end

    it 'walks the schema-valued dependencies entries under draft-07' do
      schema = { '$schema' => draft7, 'dependencies' => { 'a' => { '$ref' => 'https://example.com/x' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/external \$ref/))
    end

    it 'neither shape-checks nor reports keywords unknown to the dialect' do
      expect(validator.check_schema({ 'additionalItems' => 'nope' })).to be_empty
      expect(validator.check_schema({ '$recursiveRef' => 'https://example.com/x' })).to be_empty
      expect(validator.unsupported_keywords({ '$recursiveRef' => 'https://example.com/x' })).to be_empty
      expect(validator.check_schema({ '$schema' => draft7, 'prefixItems' => 'nope' })).to be_empty
      expect(validator.check_schema({ '$schema' => draft7, '$dynamicRef' => 'https://example.com/x' })).to be_empty
      expect(validator.unsupported_keywords({ '$schema' => draft7, 'unevaluatedProperties' => false })).to be_empty
    end
  end

  it 'does not preflight the siblings a draft-07 $ref replaces' do
    schema = { '$schema' => draft7, '$ref' => '#/definitions/a',
               'allOf' => [{ '$ref' => 'https://example.com/x' }],
               'definitions' => { 'a' => { 'type' => 'integer' } } }
    expect(validator.check_schema(schema)).to be_empty
    expect(validator.validate(1, schema)).to be_empty
    expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/integer/))
  end

  it 'still preflights the definitions next to a draft-07 $ref' do
    schema = { '$schema' => draft7, '$ref' => '#/definitions/a',
               'definitions' => { 'a' => { 'properties' => { 'p' => { '$ref' => 'https://example.com/x' } } } } }
    expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/external \$ref/))
  end

  describe 'plain-name fragments' do
    it 'resolves $ref "#name" to the subschema carrying $anchor under 2020-12' do
      schema = { '$ref' => '#node', '$defs' => { 'n' => { '$anchor' => 'node', 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(1, schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/integer/))
    end

    it 'resolves $ref "#name" to the subschema whose $id is "#name" under draft-07' do
      schema = { '$schema' => draft7, '$ref' => '#node',
                 'definitions' => { 'n' => { '$id' => '#node', 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/integer/))
    end

    it 'keeps an unknown anchor an error' do
      expect(validator.check_schema({ '$ref' => '#missing' })).to contain_exactly(a_string_matching(/unresolvable/))
      # $anchor does not exist in draft-07, so it names nothing there.
      schema = { '$schema' => draft7, '$ref' => '#node', 'definitions' => { 'n' => { '$anchor' => 'node' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable/))
    end
  end

  describe 'draft-07 exclusive bounds' do
    it 'applies numeric exclusiveMinimum / exclusiveMaximum (draft-07 validation Sections 6.2.3 and 6.2.5)' do
      min = { '$schema' => draft7, 'type' => 'number', 'exclusiveMinimum' => 5 }
      max = { '$schema' => draft7, 'type' => 'number', 'exclusiveMaximum' => 10 }
      expect(validator.validate(5, min)).to contain_exactly(a_string_matching(/greater than/))
      expect(validator.validate(6, min)).to be_empty
      expect(validator.validate(10, max)).to contain_exactly(a_string_matching(/less than/))
      expect(validator.validate(9, max)).to be_empty
    end

    it 'rejects the draft-04 boolean form' do
      expect(validator.check_schema({ '$schema' => draft7, 'exclusiveMinimum' => true }))
        .to contain_exactly(a_string_matching(/exclusiveMinimum.*number/))
      expect(validator.check_schema({ 'exclusiveMaximum' => true }))
        .to contain_exactly(a_string_matching(/exclusiveMaximum.*number/))
    end
  end

  it 'treats an external $recursiveRef like an external $dynamicRef under 2019-09' do
    external = { '$schema' => draft2019, '$recursiveRef' => 'https://example.com/x' }
    expect(validator.check_schema(external)).to contain_exactly(a_string_matching(/external \$recursiveRef/))
    expect(validator.validate(1, external)).not_to be_empty

    local = { '$schema' => draft2019, '$recursiveRef' => '#' }
    expect(validator.check_schema(local)).to be_empty
    expect(validator.unsupported_keywords(local)).to eq(['$recursiveRef'])
  end

  describe 'an empty outputSchema' do
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    it 'is a schema (it accepts every value) for Tool.new and Tool.from_json' do
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' }, output_schema: {})
      expect(tool).to be_structured_output
      parsed = MCPClient::Tool.from_json({ 'name' => 't', 'inputSchema' => { 'type' => 'object' },
                                           'outputSchema' => {} })
      expect(parsed).to be_structured_output
      expect(MCPClient::Tool.from_json({ 'name' => 't', 'inputSchema' => {} })).not_to be_structured_output
    end

    it 'makes the client require structuredContent' do
      log_output = StringIO.new
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' }, output_schema: {},
                                 server: mock_server)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }],
                                     logger: Logger.new(log_output))

      client.call_tool('t', {})

      expect(log_output.string).to include('no structuredContent')
    end
  end
end
