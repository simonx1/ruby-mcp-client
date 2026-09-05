# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 JSON Schema usage (basic/index "JSON Schema Usage",
# server/tools "Structured Content" / "Output Schema"):
# - the default dialect is JSON Schema 2020-12; an explicit `$schema` MAY
#   name another dialect and an unsupported one is an error, not a pass;
# - inputSchema / outputSchema may use any 2020-12 keyword;
# - structuredContent is any JSON value, including null;
# - `$ref` values that resolve to a network URI MUST NOT be dereferenced,
#   and a schema that cannot be validated because of one is rejected rather
#   than treated as permissive;
# - composition keywords are bounded (depth, subschema count, time).
RSpec.describe 'MCP 2026-07-28 JSON Schema handling' do
  let(:validator) { MCPClient::SchemaValidator }

  describe 'dialects' do
    it 'defaults to 2020-12 and accepts its known URIs' do
      expect(validator.dialect({ 'type' => 'object' })).to eq('https://json-schema.org/draft/2020-12/schema')
      expect(validator.check_schema({ 'type' => 'object' })).to be_empty
      expect(validator.check_schema({ '$schema' => 'https://json-schema.org/draft/2020-12/schema' })).to be_empty
      expect(validator.check_schema({ '$schema' => 'https://json-schema.org/draft/2020-12/schema#' })).to be_empty
      expect(validator.check_schema({ '$schema' => 'http://json-schema.org/draft-07/schema#' })).to be_empty
    end

    it 'reports an unsupported dialect instead of validating permissively' do
      problems = validator.check_schema({ '$schema' => 'http://json-schema.org/draft-04/schema#', 'type' => 'object' })
      expect(problems).to contain_exactly(a_string_matching(/dialect.*draft-04.*not supported/))

      errors = validator.validate({}, { '$schema' => 'http://json-schema.org/draft-04/schema#', 'type' => 'object' })
      expect(errors).to contain_exactly(a_string_matching(/dialect.*not supported/))
    end

    it 'implements exactly 2020-12, 2019-09 and draft-07' do
      expect(validator::SUPPORTED_DIALECTS).to contain_exactly('https://json-schema.org/draft/2020-12/schema',
                                                               'https://json-schema.org/draft/2019-09/schema',
                                                               'http://json-schema.org/draft-07/schema')
      validator::SUPPORTED_DIALECTS.each do |dialect|
        expect(validator.check_schema({ '$schema' => dialect, 'type' => 'object' })).to be_empty
      end
    end

    it 'requires a schema to be an object' do
      expect(validator.check_schema(nil)).to contain_exactly(a_string_matching(/must be an object/))
      expect(validator.check_schema('string')).to contain_exactly(a_string_matching(/must be an object/))
      expect(validator.validate({}, nil)).to contain_exactly(a_string_matching(/must be an object/))
    end
  end

  describe 'local $ref resolution' do
    let(:schema) do
      { 'type' => 'object',
        '$defs' => { 'point' => { 'type' => 'object', 'required' => %w[x y],
                                  'properties' => { 'x' => { 'type' => 'number' }, 'y' => { 'type' => 'number' } } } },
        'properties' => { 'origin' => { '$ref' => '#/$defs/point' },
                          'legacy' => { '$ref' => '#/definitions/name' } },
        'definitions' => { 'name' => { 'type' => 'string' } } }
    end

    it 'resolves $defs and definitions pointers within the root schema' do
      expect(validator.validate({ 'origin' => { 'x' => 1, 'y' => 2 }, 'legacy' => 'n' }, schema)).to be_empty
      errors = validator.validate({ 'origin' => { 'x' => 1 }, 'legacy' => 3 }, schema)
      expect(errors).to contain_exactly(a_string_matching(%r{#/origin: missing required property 'y'}),
                                        a_string_matching(%r{#/legacy: expected type string}))
    end

    it 'decodes JSON pointer escapes and percent-encoding in $ref' do
      schema = { '$defs' => { 'a/b' => { 'type' => 'integer' }, 'c~d' => { 'type' => 'boolean' } },
                 'properties' => { 'p' => { '$ref' => '#/$defs/a~1b' }, 'q' => { '$ref' => '#/%24defs/c~0d' } } }
      expect(validator.validate({ 'p' => 1, 'q' => true }, schema)).to be_empty
      expect(validator.validate({ 'p' => 'x' }, schema)).to contain_exactly(a_string_matching(%r{#/p: expected type}))
    end

    it 'follows recursive references without looping forever' do
      tree = { 'type' => 'object', 'properties' => { 'children' => { 'type' => 'array', 'items' => { '$ref' => '#' } },
                                                     'value' => { 'type' => 'integer' } } }
      good = { 'value' => 1, 'children' => [{ 'value' => 2, 'children' => [] }] }
      bad = { 'value' => 1, 'children' => [{ 'value' => 'two' }] }
      expect(validator.validate(good, tree)).to be_empty
      expect(validator.validate(bad, tree)).to contain_exactly(a_string_matching(%r{#/children/0/value}))

      loop_schema = { '$ref' => '#/$defs/a',
                      '$defs' => { 'a' => { '$ref' => '#/$defs/b' }, 'b' => { '$ref' => '#/$defs/a' } } }
      expect(validator.validate(1, loop_schema)).to contain_exactly(a_string_matching(/\$ref.*(cycle|depth)/))
    end

    it 'rejects an unresolvable local $ref instead of ignoring it' do
      schema = { 'properties' => { 'p' => { '$ref' => '#/$defs/missing' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(%r{unresolvable.*#/\$defs/missing}))
      expect(validator.validate({ 'p' => 1 }, schema)).to contain_exactly(a_string_matching(/unresolvable/))
    end
  end

  describe 'external $ref' do
    it 'never dereferences a network URI and rejects the schema' do
      schema = { 'type' => 'object', 'properties' => { 'p' => { '$ref' => 'https://example.com/schemas/p.json' } } }
      # WebMock raises on any real request; the reference must never be fetched.
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/external \$ref.*not dereferenced/))
      errors = validator.validate({ 'p' => 1 }, schema)
      expect(errors).to contain_exactly(a_string_matching(/external \$ref/))
      expect(a_request(:any, /example\.com/)).not_to have_been_made
    end

    it 'treats relative, urn and $id-based references as external too' do
      ['other.json', 'urn:example:schema', 'other.json#/x', 'file:///etc/passwd'].each do |ref|
        expect(validator.check_schema({ '$ref' => ref })).to contain_exactly(a_string_matching(/external \$ref/)),
                                                             "expected #{ref} to count as external"
      end
    end
  end

  describe 'composition keywords' do
    it 'evaluates allOf, anyOf, oneOf and not' do
      expect(validator.validate(5, { 'allOf' => [{ 'type' => 'integer' }, { 'minimum' => 3 }] })).to be_empty
      expect(validator.validate(1, { 'allOf' => [{ 'type' => 'integer' }, { 'minimum' => 3 }] }))
        .to contain_exactly(a_string_matching(/allOf/))
      expect(validator.validate('s', { 'anyOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }] })).to be_empty
      expect(validator.validate(true, { 'anyOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }] }))
        .to contain_exactly(a_string_matching(/anyOf/))
      expect(validator.validate(2, { 'oneOf' => [{ 'type' => 'integer' }, { 'minimum' => 10 }] })).to be_empty
      expect(validator.validate(12, { 'oneOf' => [{ 'type' => 'integer' }, { 'minimum' => 10 }] }))
        .to contain_exactly(a_string_matching(/oneOf/))
      expect(validator.validate('x', { 'not' => { 'type' => 'integer' } })).to be_empty
      expect(validator.validate(1, { 'not' => { 'type' => 'integer' } })).to contain_exactly(a_string_matching(/not/))
    end

    it 'evaluates if/then/else' do
      schema = { 'if' => { 'properties' => { 'kind' => { 'const' => 'a' } }, 'required' => ['kind'] },
                 'then' => { 'required' => ['a_value'] }, 'else' => { 'required' => ['other'] } }
      expect(validator.validate({ 'kind' => 'a', 'a_value' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'kind' => 'a' }, schema)).to contain_exactly(a_string_matching(/a_value/))
      expect(validator.validate({ 'kind' => 'b', 'other' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'kind' => 'b' }, schema)).to contain_exactly(a_string_matching(/other/))
    end

    it 'no longer reports the composition and reference keywords as unsupported' do
      %w[$ref $defs allOf anyOf oneOf not if then else].each do |keyword|
        expect(validator::UNSUPPORTED_KEYWORDS).not_to include(keyword)
      end
      expect(validator.unsupported_keywords({ 'allOf' => [{ 'format' => 'email' }] })).to eq(['format'])
    end
  end

  describe 'resource bounds' do
    it 'rejects a schema nested deeper than MAX_SCHEMA_DEPTH' do
      deep = { 'type' => 'integer' }
      (validator::MAX_SCHEMA_DEPTH + 1).times { deep = { 'type' => 'array', 'items' => deep } }

      expect(validator.check_schema(deep)).to contain_exactly(a_string_matching(/depth/))
      expect(validator.validate([[]], deep)).to contain_exactly(a_string_matching(/depth/))
    end

    it 'rejects a schema with more than MAX_SUBSCHEMAS subschemas' do
      wide = { 'anyOf' => Array.new(validator::MAX_SUBSCHEMAS + 1) { { 'type' => 'integer' } } }

      expect(validator.check_schema(wide)).to contain_exactly(a_string_matching(/subschemas/))
      expect(validator.validate(1, wide)).to contain_exactly(a_string_matching(/subschemas/))
    end

    it 'stops validating once the time budget is exhausted' do
      schema = { 'type' => 'array', 'items' => { 'type' => 'string', 'pattern' => 'a' } }
      allow(validator).to receive(:pattern_budget_remaining).and_return(0.0)

      errors = validator.validate(%w[a b], schema)

      expect(errors).to contain_exactly(a_string_matching(/budget/))
    end
  end

  it 'ignores the x-mcp-header annotation' do
    schema = { 'type' => 'object', 'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' } } }
    expect(validator.validate({ 'region' => 'eu' }, schema)).to be_empty
    expect(validator.unsupported_keywords(schema)).to be_empty
    expect(validator.check_schema(schema)).to be_empty
  end

  describe 'structuredContent through MCPClient::Client' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def tool(output_schema, name: 'tool')
      MCPClient::Tool.new(name: name, description: 'd', schema: { 'type' => 'object' }, output_schema: output_schema,
                          server: mock_server)
    end

    def client_with(tools, **opts)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return(tools)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger, **opts)
    end

    it 'accepts a null structuredContent when the key is present and the schema allows it' do
      client = client_with([tool({ 'type' => 'null' })], validate_structured_content: :strict)
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => nil })

      returned = client.call_tool('tool', {})
      # The key itself must survive: reading it as nil would pass just as
      # well for a result the client had dropped it from.
      expect(returned).to have_key('structuredContent')
      expect(returned['structuredContent']).to be_nil
      expect(log_output.string).not_to include('structuredContent')
    end

    it 'rejects a null structuredContent that the schema does not allow, and still requires the key' do
      client = client_with([tool({ 'type' => 'object' })], validate_structured_content: :strict)
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => nil })
      expect { client.call_tool('tool', {}) }.to raise_error(MCPClient::Errors::ValidationError, /expected type object/)

      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })
      expect { client.call_tool('tool', {}) }.to raise_error(MCPClient::Errors::ValidationError, /no structuredContent/)
    end

    it 'validates non-object structured content (arrays, scalars)' do
      client = client_with([tool({ 'type' => 'array', 'items' => { 'type' => 'integer' } })],
                           validate_structured_content: :strict)
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => [1, 2] })
      expect(client.call_tool('tool', {})['structuredContent']).to eq([1, 2])

      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => ['x'] })
      expect { client.call_tool('tool', {}) }.to raise_error(MCPClient::Errors::ValidationError, %r{#/0})
    end

    # "structuredContent can be any JSON value (object, array, string,
    # number, boolean, or null)": every one of them is validated, and a
    # symbol-keyed result carries the value just as a string-keyed one does.
    {
      'string' => ['ok', 42], 'number' => [1.5, 'no'], 'boolean' => [false, 'no'], 'null' => [nil, 1]
    }.each do |type, (conforming, violating)|
      it "validates #{type} structured content" do
        client = client_with([tool({ 'type' => type })], validate_structured_content: :strict)
        allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => conforming })
        expect(client.call_tool('tool', {})['structuredContent']).to eq(conforming)

        allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => violating })
        expect { client.call_tool('tool', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /expected type #{type}/)
      end
    end

    it 'reads a symbol-keyed result the same way' do
      client = client_with([tool({ 'type' => 'string' })], validate_structured_content: :strict)
      allow(mock_server).to receive(:call_tool).and_return({ content: [], structuredContent: 'ok' })
      expect(client.call_tool('tool', {})[:structuredContent]).to eq('ok')

      allow(mock_server).to receive(:call_tool).and_return({ content: [], structuredContent: 42 })
      expect { client.call_tool('tool', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /expected type string/)
    end

    it 'treats an output schema with an external $ref as a violation rather than as permissive' do
      schema = { 'type' => 'object', 'properties' => { 'p' => { '$ref' => 'https://example.com/p.json' } } }
      client = client_with([tool(schema)], validate_structured_content: :strict)
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => { 'p' => 1 } })

      expect { client.call_tool('tool', {}) }.to raise_error(MCPClient::Errors::ValidationError, /external \$ref/)
      expect(a_request(:any, /example\.com/)).not_to have_been_made
    end

    it 'errors (in either mode) when the output schema uses an unsupported dialect' do
      # MCP 2026-07-28 basic "Implementation Requirements": the client MUST
      # return an error saying the dialect is not supported. That is not a
      # structured-content mismatch the host's mode may reduce to a log line.
      schema = { '$schema' => 'http://json-schema.org/draft-04/schema#', 'type' => 'object' }
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })

      expect { client_with([tool(schema)]).call_tool('tool', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /dialect.*not supported/)
      expect { client_with([tool(schema)], validate_structured_content: :strict).call_tool('tool', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /dialect.*not supported/)
    end

    it 'warns once about an unusable input schema and still calls the tool' do
      bad_input = MCPClient::Tool.new(name: 'bad', description: 'd',
                                      schema: { '$ref' => 'https://example.com/in.json' }, server: mock_server)
      client = client_with([bad_input])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })

      client.call_tool('bad', {})
      client.call_tool('bad', {})

      expect(log_output.string.scan(/input schema.*external \$ref/).size).to eq(1)
    end
  end
end
