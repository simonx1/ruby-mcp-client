# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 JSON Schema handling, second review round: aborted
# validations never fail open, error output is bounded, resource bounds
# cannot be bypassed, draft-07 tuples and $ref siblings follow their
# dialect, JSON pointers follow RFC 6901, boolean root schemas work, and
# schema-derived text is sanitized before it reaches logs or exceptions.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 2' do
  let(:validator) { MCPClient::SchemaValidator }

  describe 'aborted validations' do
    it 'reports a $ref chain abort as an error even under not or oneOf' do
      recursive = { 'not' => { '$ref' => '#/$defs/loop' },
                    '$defs' => { 'loop' => { '$ref' => '#/$defs/loop2' }, 'loop2' => { '$ref' => '#/$defs/loop' } } }
      expect(validator.validate(1, recursive)).to contain_exactly(a_string_matching(/\$ref.*(cycle|depth|chain)/))

      one_of = { 'oneOf' => [{ 'type' => 'integer' }, { '$ref' => '#/$defs/loop' }],
                 '$defs' => { 'loop' => { '$ref' => '#/$defs/loop' } } }
      expect(validator.validate(1, one_of)).to contain_exactly(a_string_matching(/\$ref.*(cycle|depth|chain)/))
    end

    it 'stops at the time budget with a single error instead of one per item' do
      schema = { 'type' => 'array', 'items' => { 'type' => 'string', 'pattern' => 'a' } }
      allow(validator).to receive(:pattern_budget_remaining).and_return(0.0)

      errors = validator.validate(Array.new(500, 'a'), schema)

      expect(errors.size).to eq(1)
      expect(errors.first).to match(/budget/)
    end

    it 'does not let not accept a value once the budget is gone' do
      schema = { 'not' => { 'type' => 'string', 'pattern' => 'a' } }
      allow(validator).to receive(:pattern_budget_remaining).and_return(0.0)

      expect(validator.validate('a', schema)).to contain_exactly(a_string_matching(/budget/))
    end
  end

  describe 'bounded output' do
    it 'keeps the error list and each message small for a tiny recursive allOf schema' do
      schema = { 'allOf' => [{ '$ref' => '#' }, { '$ref' => '#' }], 'type' => 'string' }

      errors = validator.validate(1, schema)

      expect(errors.size).to be <= validator::MAX_ERRORS
      expect(errors.sum(&:bytesize)).to be < 20_000
    end

    it 'caps the number of errors' do
      schema = { 'type' => 'array', 'items' => { 'type' => 'integer' } }

      errors = validator.validate(Array.new(5000, 'x'), schema)

      expect(errors.size).to be <= validator::MAX_ERRORS
      expect(errors.last).to match(/more errors|truncated/i)
    end

    it 'truncates inspected values in enum and const messages' do
      long = 'x' * 10_000
      errors = validator.validate(long, { 'enum' => ['a'] })
      expect(errors.first.bytesize).to be < 600
    end
  end

  describe 'resource bounds' do
    it 'counts boolean subschemas toward the subschema cap' do
      wide = { 'anyOf' => Array.new(validator::MAX_SUBSCHEMAS + 1, true) }
      expect(validator.check_schema(wide)).to contain_exactly(a_string_matching(/subschemas/))
    end

    it 'reports an unusable $ref chain during preflight' do
      chain = {}
      chain['$ref'] = '#/$defs/d0'
      defs = {}
      (validator::MAX_REF_DEPTH + 2).times { |i| defs["d#{i}"] = { '$ref' => "#/$defs/d#{i + 1}" } }
      defs["d#{validator::MAX_REF_DEPTH + 2}"] = { 'type' => 'integer' }
      chain['$defs'] = defs
      expect(validator.check_schema(chain)).to contain_exactly(a_string_matching(/\$ref chain/))

      cycle = { '$ref' => '#/$defs/a',
                '$defs' => { 'a' => { '$ref' => '#/$defs/b' }, 'b' => { '$ref' => '#/$defs/a' } } }
      expect(validator.check_schema(cycle)).to contain_exactly(a_string_matching(/\$ref chain/))
    end

    it 'does not overflow on deeply nested const or enum values' do
      deep = 1
      2000.times { deep = [deep] }
      expect { validator.check_schema({ 'const' => deep }) }.not_to raise_error
      expect(validator.validate(deep, { 'const' => deep })).to be_empty
    end

    it 'rejects a $ref that points at something that is not a schema' do
      schema = { '$ref' => '#/$defs/name', '$defs' => { 'name' => 'not a schema' } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/does not point at a schema/))
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/does not point at a schema/))
    end
  end

  describe 'dialects' do
    it 'validates draft-07 tuple items and finds an external $ref inside them' do
      schema = { '$schema' => 'http://json-schema.org/draft-07/schema#', 'type' => 'array',
                 'items' => [{ 'type' => 'integer' }, { 'type' => 'string' }] }
      expect(validator.validate([1, 'a'], schema)).to be_empty
      expect(validator.validate(['a', 1], schema)).to contain_exactly(a_string_matching(%r{#/0}),
                                                                      a_string_matching(%r{#/1}))

      external = { '$schema' => 'http://json-schema.org/draft-07/schema#', 'type' => 'array',
                   'items' => [{ '$ref' => 'https://example.com/s.json' }] }
      expect(validator.check_schema(external)).to contain_exactly(a_string_matching(/external \$ref/))
    end

    it 'validates 2020-12 prefixItems' do
      schema = { 'type' => 'array', 'prefixItems' => [{ 'type' => 'integer' }], 'items' => { 'type' => 'string' } }
      expect(validator.validate([1, 'a', 'b'], schema)).to be_empty
      expect(validator.validate(%w[x a], schema)).to contain_exactly(a_string_matching(%r{#/0}))
      expect(validator.validate([1, 2], schema)).to contain_exactly(a_string_matching(%r{#/1}))
      expect(validator::UNSUPPORTED_KEYWORDS).not_to include('prefixItems')
    end

    it 'ignores the siblings of $ref under draft-07 but applies them under 2020-12' do
      draft7 = { '$schema' => 'http://json-schema.org/draft-07/schema#',
                 'properties' => { 'p' => { '$ref' => '#/definitions/s', 'type' => 'integer' } },
                 'definitions' => { 's' => { 'type' => 'string' } } }
      expect(validator.validate({ 'p' => 'text' }, draft7)).to be_empty

      modern = { 'properties' => { 'p' => { '$ref' => '#/$defs/s', 'type' => 'integer' } },
                 '$defs' => { 's' => { 'type' => 'string' } } }
      expect(validator.validate({ 'p' => 'text' }, modern)).to contain_exactly(a_string_matching(%r{#/p}))
    end

    it 'reports draft-specific keywords it does not evaluate under the dialect that defines them' do
      draft7 = 'http://json-schema.org/draft-07/schema#'
      expect(validator.unsupported_keywords({ '$schema' => draft7, 'items' => [], 'additionalItems' => false }))
        .to eq(['additionalItems'])
      expect(validator.unsupported_keywords({ '$schema' => draft7, 'dependencies' => {} })).to eq(['dependencies'])
      expect(validator.unsupported_keywords({ '$schema' => validator::DRAFT_2019_09, '$recursiveRef' => '#' }))
        .to eq(['$recursiveRef'])
    end

    it 'treats $dynamicRef to another document as unusable' do
      expect(validator.check_schema({ '$dynamicRef' => 'https://example.com/x' }))
        .to contain_exactly(a_string_matching(/external/))
    end
  end

  describe 'JSON pointers' do
    it 'keeps literal plus signs and rejects indexes with leading zeros' do
      schema = { '$defs' => { 'a+b' => { 'type' => 'integer' } }, 'prefixItems' => [{ 'type' => 'string' }],
                 'properties' => { 'p' => { '$ref' => '#/$defs/a+b' }, 'q' => { '$ref' => '#/prefixItems/00' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(%r{unresolvable.*#/prefixItems/00}))
      expect(validator.validate({ 'p' => 'x' }, { '$defs' => { 'a+b' => { 'type' => 'integer' } },
                                                  'properties' => { 'p' => { '$ref' => '#/$defs/a+b' } } }))
        .to contain_exactly(a_string_matching(%r{#/p: expected type integer}))
    end
  end

  describe 'boolean root schemas and symbol keys' do
    it 'accepts a boolean root schema' do
      expect(validator.check_schema(true)).to be_empty
      expect(validator.validate(1, true)).to be_empty
      expect(validator.validate(1, false)).to contain_exactly(a_string_matching(/false/))
    end

    it 'compares symbol-keyed const and enum values as given' do
      expect(validator.validate({ a: 1 }, { const: { a: 1 } })).to be_empty
      expect(validator.validate({ 'a' => 1 }, { 'enum' => [{ 'a' => 1 }] })).to be_empty
    end

    it 'lets a tool declare a boolean output schema' do
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' }, output_schema: true)
      expect(tool.structured_output?).to be(true)
    end
  end

  describe 'through MCPClient::Client' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def tool(output_schema, name: 'tool', schema: { 'type' => 'object' })
      MCPClient::Tool.new(name: name, description: 'd', schema: schema, output_schema: output_schema,
                          server: mock_server)
    end

    def client_with(tools, **opts)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return(tools)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger, **opts)
    end

    it 'sanitizes and bounds schema-derived text in violations' do
      schema = { 'type' => 'object', 'properties' => { 'p' => { '$ref' => "https://example.com/\nWARN forged.json" } } }
      client = client_with([tool(schema, name: "tool\nWARN forged")], validate_structured_content: :strict)
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => { 'p' => 1 } })

      expect { client.call_tool("tool\nWARN forged", {}) }.to raise_error(MCPClient::Errors::ValidationError) { |e|
        expect(e.message).not_to include("\nWARN forged")
        expect(e.message.bytesize).to be < 5000
      }
      expect(log_output.string).not_to include("\nWARN forged")
    end

    it 're-checks an input schema when the tool definition changes' do
      bad = { '$ref' => 'https://example.com/in.json' }
      good = { 'type' => 'object' }
      client = client_with([tool(nil, name: 'x', schema: good)])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })
      client.call_tool('x', {})
      expect(log_output.string).not_to match(/input schema/)

      allow(mock_server).to receive(:list_tools).and_return([tool(nil, name: 'x', schema: bad)])
      client.list_tools(cache: false)
      client.call_tool('x', {})

      expect(log_output.string).to match(/input schema.*external \$ref/)
    end
  end
end
