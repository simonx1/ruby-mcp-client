# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, twenty-second round: a subtree a
# pointer reaches through a data keyword is adopted once and every pointer
# into it lands on the indexed objects (their own resource, dialect and
# subschema charge), the identifiers such a subtree declares are never the
# document's, a reference whose percent-encoding is not readable resolves to
# nothing instead of raising, a property named like a data keyword is a
# schema position, and a branch that already failed a supported assertion is
# not measured for the keywords it does not evaluate.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 22' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'a pointer into an adopted subtree' do
    it 'keeps the dialect of the resource the pointer entered' do
      schema = { 'allOf' => [{ '$ref' => '#/default/$defs/i' }],
                 'default' => { '$id' => 'https://example.com/emb', '$schema' => draft7,
                                '$defs' => { 'i' => { 'items' => [{ 'type' => 'integer' }] } } } }

      expect(validator.check_schema(schema)).to be_empty
      # draft-07 reads the items array positionally; 2020-12 would reject it.
      expect(validator.validate(['x'], schema))
        .to contain_exactly(a_string_matching(%r{#/0: expected type integer}))
    end

    it 'does not declare the anchors of the adopted subtree twice' do
      schema = { 'properties' => { 'a' => { '$ref' => '#/default' } },
                 'default' => { '$defs' => { 'i' => { '$anchor' => 'int', 'type' => 'integer' } },
                                'properties' => { 'b' => { '$ref' => '#/default/$defs/i' } } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => { 'b' => 'x' } }, schema))
        .to contain_exactly(a_string_matching(%r{#/a/b: expected type integer}))
    end

    it 'charges the adopted subtree against the subschema bound once' do
      big = { 'allOf' => Array.new(1200) { { 'type' => 'integer' } } }
      schema = { 'allOf' => [{ '$ref' => '#/default' }, { '$ref' => '#/default/$defs/i' }],
                 'default' => { '$defs' => { 'i' => big } } }

      expect(validator.check_schema(schema)).to be_empty
    end
  end

  describe 'identifiers written inside a data keyword' do
    it 'are not the document\'s anchors' do
      schema = { '$defs' => { 'x' => { '$anchor' => 'foo', 'type' => 'string' } },
                 'properties' => { 'a' => { '$ref' => '#/default' } },
                 'default' => { '$anchor' => 'foo', 'type' => 'integer' },
                 'allOf' => [{ '$ref' => '#foo' }] }

      expect(validator.check_schema(schema)).to be_empty
      # "#foo" is the one the document declares, whatever the data keyword holds.
      expect(validator.validate('x', schema)).to be_empty
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'resolves a plain name the same way whatever the member order' do
      props_first = { 'properties' => { 'a' => { '$ref' => '#/default' } },
                      'default' => { '$anchor' => 'foo', 'type' => 'integer' },
                      'allOf' => [{ '$ref' => '#foo' }] }
      allof_first = { 'allOf' => [{ '$ref' => '#foo' }],
                      'properties' => { 'a' => { '$ref' => '#/default' } },
                      'default' => { '$anchor' => 'foo', 'type' => 'integer' } }

      expect(validator.check_schema(props_first))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref "#foo"/))
      expect(validator.check_schema(allof_first)).to eq(validator.check_schema(props_first))
    end

    it 'validates the same way whatever the instance' do
      schema = { 'properties' => { 'a' => { '$ref' => '#/default' } },
                 'default' => { '$anchor' => 'foo', 'type' => 'integer' },
                 'allOf' => [{ '$ref' => '#foo' }] }

      expect(validator.validate('x', schema)).to eq(validator.validate({ 'a' => 1 }, schema))
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end
  end

  describe 'a reference whose percent-encoding is not readable' do
    it 'resolves to nothing rather than raising' do
      expect { validator.check_schema({ '$ref' => '#%FF' }) }.not_to raise_error
      expect(validator.check_schema({ '$ref' => '#%FF' }))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
      expect(validator.check_schema({ '$ref' => '#/%FF' }))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
      expect(validator.validate(1, { '$ref' => '#/%FF' }))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end

    it 'still reads a readable escape' do
      schema = { '$ref' => '#/$defs/a%2Db', '$defs' => { 'a-b' => { 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/expected type integer/))
    end
  end

  describe 'a property named like a data keyword' do
    it 'is a schema position, not data' do
      schema = { properties: { enum: { type: 'string' } } }

      expect(validator.validate({ 'enum' => 123 }, schema))
        .to contain_exactly(a_string_matching(%r{#/enum: expected type string}))
      expect(validator.validate({ 'enum' => 'ok' }, schema)).to be_empty
    end

    it 'still keeps a real data keyword as it was given' do
      schema = { type: 'object', properties: { a: { const: { b: 1 } } } }

      expect(validator.validate({ 'a' => { b: 1 } }, schema)).to be_empty
      expect(validator.validate({ 'a' => { 'c' => 1 } }, schema)).not_to be_empty
    end
  end

  describe 'a branch that already failed a supported assertion' do
    # Backtracking Ruby's regexp cache cannot flatten: matching it would
    # burn the whole validation budget.
    let(:evil_pattern) { '^(a*)*\1$' }
    let(:evil_name) { "#{'a' * 17}!" }

    it 'is not measured for the keywords the validator does not evaluate' do
      schema = { 'not' => { 'type' => 'string', 'patternProperties' => { evil_pattern => false } } }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      errors = validator.validate({ evil_name => 1 }, schema)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
      expect(errors).to be_empty
    end

    it 'still measures a branch its supported assertions accept' do
      schema = { 'not' => { 'type' => 'object', 'patternProperties' => { '^a' => { 'type' => 'string' } } } }
      expect(validator.validate({ 'ab' => 1 }, schema)).to be_empty
    end
  end

  describe 'the once-per-definition schema checks' do
    let(:logger) { Logger.new(StringIO.new) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def tool(name)
      MCPClient::Tool.from_json({ 'name' => name, 'description' => 'd',
                                  'inputSchema' => { 'type' => 'object' },
                                  'outputSchema' => { 'type' => 'object', 'minProperties' => 1 } },
                                server: mock_server)
    end

    def client_with(tools)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return(tools)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)
    end

    it 'forgets the tools a refreshed list no longer carries' do
      client = client_with([tool('old')])
      client.send(:input_schema_state, tool('old'))
      client.send(:warn_partial_schema_coverage, tool('old'))
      expect(client.instance_variable_get(:@input_schema_warnings)).not_to be_empty

      allow(mock_server).to receive(:list_tools).and_return([tool('new')])
      client.list_tools(cache: false)

      expect(client.instance_variable_get(:@input_schema_warnings)).to be_empty
      expect(client.instance_variable_get(:@output_schema_coverage)).to be_empty
    end

    it 'forgets them when the whole cache is cleared' do
      client = client_with([tool('old')])
      client.send(:input_schema_state, tool('old'))
      client.send(:warn_partial_schema_coverage, tool('old'))

      client.clear_cache

      expect(client.instance_variable_get(:@input_schema_warnings)).to be_empty
      expect(client.instance_variable_get(:@output_schema_coverage)).to be_empty
    end
  end
end
