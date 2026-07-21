# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::SchemaValidator do
  describe '.validate' do
    it 'returns no errors when data conforms to the schema' do
      schema = {
        'type' => 'object',
        'properties' => {
          'temperature' => { 'type' => 'number', 'minimum' => -100, 'maximum' => 100 },
          'conditions' => { 'type' => 'string', 'enum' => %w[sunny cloudy rainy] },
          'readings' => { 'type' => 'array', 'items' => { 'type' => 'integer' }, 'minItems' => 1 }
        },
        'required' => %w[temperature conditions]
      }
      data = { 'temperature' => 22.5, 'conditions' => 'sunny', 'readings' => [1, 2] }

      expect(described_class.validate(data, schema)).to be_empty
    end

    it 'reports a top-level type mismatch' do
      errors = described_class.validate('not an object', { 'type' => 'object' })
      expect(errors).to contain_exactly(a_string_matching(/expected type object, got string/))
    end

    it 'reports missing required properties' do
      schema = { 'type' => 'object', 'properties' => { 'a' => { 'type' => 'string' } }, 'required' => ['a'] }
      errors = described_class.validate({}, schema)
      expect(errors).to contain_exactly(a_string_matching(/missing required property 'a'/))
    end

    it 'reports nested property mismatches with their path' do
      schema = {
        'type' => 'object',
        'properties' => {
          'nested' => { 'type' => 'object', 'properties' => { 'count' => { 'type' => 'integer' } } }
        }
      }
      errors = described_class.validate({ 'nested' => { 'count' => 'three' } }, schema)
      expect(errors).to contain_exactly(a_string_matching(%r{#/nested/count}))
    end

    it 'validates each array item against the items schema' do
      schema = { 'type' => 'array', 'items' => { 'type' => 'number' } }
      errors = described_class.validate([1, 'two', 3], schema)
      expect(errors).to contain_exactly(a_string_matching(%r{#/1: expected type number}))
    end

    it 'enforces enum membership' do
      errors = described_class.validate('hail', { 'type' => 'string', 'enum' => %w[sunny cloudy] })
      expect(errors).to contain_exactly(a_string_matching(/enum/))
    end

    it 'enforces string length bounds' do
      schema = { 'type' => 'string', 'minLength' => 2, 'maxLength' => 4 }
      expect(described_class.validate('abc', schema)).to be_empty
      expect(described_class.validate('a', schema)).to contain_exactly(a_string_matching(/minLength/))
      expect(described_class.validate('abcde', schema)).to contain_exactly(a_string_matching(/maxLength/))
    end

    it 'enforces string patterns' do
      schema = { 'type' => 'string', 'pattern' => '\\A[a-z]+\\z' }
      expect(described_class.validate('abc', schema)).to be_empty
      expect(described_class.validate('123', schema)).to contain_exactly(a_string_matching(/pattern/))
    end

    it 'enforces inclusive numeric bounds' do
      schema = { 'type' => 'number', 'minimum' => 0, 'maximum' => 10 }
      expect(described_class.validate(0, schema)).to be_empty
      expect(described_class.validate(-1, schema)).to contain_exactly(a_string_matching(/minimum/))
      expect(described_class.validate(11, schema)).to contain_exactly(a_string_matching(/maximum/))
    end

    it 'enforces exclusive numeric bounds' do
      schema = { 'type' => 'number', 'exclusiveMinimum' => 0, 'exclusiveMaximum' => 10 }
      expect(described_class.validate(5, schema)).to be_empty
      expect(described_class.validate(0, schema)).to contain_exactly(a_string_matching(/exclusiveMinimum/))
      expect(described_class.validate(10, schema)).to contain_exactly(a_string_matching(/exclusiveMaximum/))
    end

    it 'enforces array size bounds' do
      schema = { 'type' => 'array', 'minItems' => 1, 'maxItems' => 2 }
      expect(described_class.validate([1], schema)).to be_empty
      expect(described_class.validate([], schema)).to contain_exactly(a_string_matching(/at least 1/))
      expect(described_class.validate([1, 2, 3], schema)).to contain_exactly(a_string_matching(/at most 2/))
    end

    it 'treats whole floats as integers per JSON Schema 2020-12' do
      expect(described_class.validate(2.0, { 'type' => 'integer' })).to be_empty
      expect(described_class.validate(2.5, { 'type' => 'integer' })).to contain_exactly(a_string_matching(/integer/))
    end

    it 'accepts a type array when any member matches' do
      schema = { 'type' => %w[string null] }
      expect(described_class.validate(nil, schema)).to be_empty
      expect(described_class.validate('x', schema)).to be_empty
      expect(described_class.validate(1, schema)).to contain_exactly(a_string_matching(/string or null/))
    end

    it 'ignores JSON Schema keywords outside the supported subset' do
      # Full 2020-12 vocabulary (allOf/anyOf/$ref/...) is documented as out of
      # scope: unrecognized keywords must be ignored, not misapplied.
      schema = { 'allOf' => [{ 'type' => 'string' }], '$ref' => '#/$defs/x' }
      expect(described_class.validate(42, schema)).to be_empty
    end

    it 'handles symbol-keyed schemas and data' do
      schema = { type: 'object', properties: { name: { type: 'string' } }, required: ['name'] }
      expect(described_class.validate({ name: 'ok' }, schema)).to be_empty
      expect(described_class.validate({}, schema)).to contain_exactly(a_string_matching(/required property 'name'/))
      expect(described_class.validate({ name: 42 }, schema))
        .to contain_exactly(a_string_matching(%r{#/name: expected type string}))
    end
  end

  describe '.unsupported_keywords' do
    it 'returns an empty array for a schema using only the supported subset' do
      schema = {
        'type' => 'object',
        'properties' => { 'n' => { 'type' => 'number', 'minimum' => 0 } },
        'required' => ['n']
      }
      expect(described_class.unsupported_keywords(schema)).to eq([])
    end

    it 'detects top-level unsupported keywords' do
      schema = { 'type' => 'object', 'additionalProperties' => false, 'allOf' => [{ 'type' => 'object' }] }
      expect(described_class.unsupported_keywords(schema)).to contain_exactly('additionalProperties', 'allOf')
    end

    it 'detects every keyword in the unsupported list' do
      keywords = %w[$ref $dynamicRef $defs allOf anyOf oneOf not if then else
                    additionalProperties patternProperties propertyNames dependentSchemas
                    prefixItems contains minContains maxContains uniqueItems
                    multipleOf format dependentRequired minProperties maxProperties
                    unevaluatedProperties unevaluatedItems]
      expect(described_class::UNSUPPORTED_KEYWORDS).to match_array(keywords)
      keywords.each do |keyword|
        expect(described_class.unsupported_keywords({ keyword => {} })).to eq([keyword])
      end
    end

    it 'detects unapplied 2020-12 assertion keywords nested in property subschemas' do
      schema = {
        'type' => 'object',
        'properties' => {
          'email' => { 'type' => 'string', 'format' => 'email' },
          'count' => { 'type' => 'integer', 'multipleOf' => 5 },
          'tags' => { 'type' => 'array', 'uniqueItems' => true, 'contains' => { 'type' => 'string' } },
          'pair' => { 'type' => 'array', 'prefixItems' => [{ 'type' => 'string' }] },
          'names' => { 'type' => 'object', 'propertyNames' => { 'pattern' => '^a' } }
        }
      }
      expect(described_class.unsupported_keywords(schema)).to contain_exactly(
        'format', 'multipleOf', 'uniqueItems', 'contains', 'prefixItems', 'propertyNames'
      )
    end

    it 'detects unsupported keywords nested in properties and items' do
      schema = {
        'type' => 'object',
        'properties' => {
          'a' => { 'oneOf' => [{ 'type' => 'string' }] },
          'b' => { 'type' => 'array', 'items' => { '$ref' => '#/$defs/x' } }
        }
      }
      expect(described_class.unsupported_keywords(schema)).to contain_exactly('oneOf', '$ref')
    end

    it 'detects unsupported keywords nested inside applicator schemas' do
      schema = { 'anyOf' => [{ 'type' => 'object', 'patternProperties' => { '^x' => { 'type' => 'string' } } }] }
      expect(described_class.unsupported_keywords(schema)).to contain_exactly('anyOf', 'patternProperties')
    end

    it 'does not mistake property names for keywords' do
      schema = {
        'type' => 'object',
        'properties' => {
          'not' => { 'type' => 'string' },
          'if' => { 'type' => 'boolean' },
          '$ref' => { 'type' => 'string' }
        }
      }
      expect(described_class.unsupported_keywords(schema)).to eq([])
    end

    it 'does not mistake a property literally named format for the format keyword' do
      schema = {
        'type' => 'object',
        'properties' => {
          'format' => { 'type' => 'string' },
          'contains' => { 'type' => 'string' },
          'multipleOf' => { 'type' => 'number' }
        }
      }
      expect(described_class.unsupported_keywords(schema)).to eq([])
    end

    it 'does not scan data-carrying keywords such as enum and const' do
      schema = {
        'type' => 'object',
        'properties' => {
          'mode' => { 'enum' => [{ 'allOf' => 'just data' }], 'const' => { '$ref' => 'also data' } }
        }
      }
      expect(described_class.unsupported_keywords(schema)).to eq([])
    end

    it 'deduplicates repeated keywords' do
      schema = {
        'type' => 'object',
        'properties' => {
          'a' => { '$ref' => '#/$defs/x' },
          'b' => { '$ref' => '#/$defs/y' }
        }
      }
      expect(described_class.unsupported_keywords(schema)).to eq(['$ref'])
    end

    it 'handles symbol-keyed schemas' do
      schema = { type: 'object', additionalProperties: false, properties: { a: { anyOf: [{ type: 'string' }] } } }
      expect(described_class.unsupported_keywords(schema)).to contain_exactly('additionalProperties', 'anyOf')
    end

    it 'returns an empty array for non-hash input' do
      expect(described_class.unsupported_keywords(nil)).to eq([])
      expect(described_class.unsupported_keywords('nope')).to eq([])
    end
  end
end

RSpec.describe MCPClient::Client do
  describe 'structuredContent validation in #call_tool' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }
    let(:output_schema) do
      {
        'type' => 'object',
        'properties' => {
          'temperature' => { 'type' => 'number' },
          'conditions' => { 'type' => 'string' }
        },
        'required' => %w[temperature conditions]
      }
    end
    let(:weather_tool) do
      MCPClient::Tool.new(
        name: 'get_weather',
        description: 'Get weather data',
        schema: { 'type' => 'object', 'properties' => {} },
        output_schema: output_schema,
        server: mock_server
      )
    end
    let(:plain_tool) do
      MCPClient::Tool.new(
        name: 'plain_tool',
        description: 'No output schema',
        schema: { 'type' => 'object', 'properties' => {} },
        server: mock_server
      )
    end

    before do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return([weather_tool, plain_tool])
    end

    def build_client(**opts)
      described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger, **opts)
    end

    context 'with the default :warn mode' do
      it 'returns the result unchanged and logs nothing when structuredContent conforms' do
        result = { 'content' => [], 'structuredContent' => { 'temperature' => 22.5, 'conditions' => 'sunny' } }
        allow(mock_server).to receive(:call_tool).and_return(result)

        expect(build_client.call_tool('get_weather', {})).to eq(result)
        expect(log_output.string).not_to include('output schema')
      end

      it 'logs a warning naming the tool and still returns the result on mismatch' do
        result = { 'content' => [], 'structuredContent' => { 'temperature' => 'hot' } }
        allow(mock_server).to receive(:call_tool).and_return(result)

        expect(build_client.call_tool('get_weather', {})).to eq(result)
        expect(log_output.string).to match(/get_weather.*does not match its output schema/)
        expect(log_output.string).to include("missing required property 'conditions'")
      end

      it 'warns when a successful result carries no structuredContent despite a declared output schema' do
        # MCP 2025-11-25 server/tools: a tool declaring an outputSchema must
        # return structuredContent in successful results.
        result = { 'content' => [{ 'type' => 'text', 'text' => 'hi' }] }
        allow(mock_server).to receive(:call_tool).and_return(result)

        expect(build_client.call_tool('get_weather', {})).to eq(result)
        expect(log_output.string).to match(/get_weather.*declares an output schema.*no structuredContent/)
      end

      it 'does not validate tools without an output schema' do
        result = { 'content' => [], 'structuredContent' => { 'anything' => 'goes' } }
        allow(mock_server).to receive(:call_tool).and_return(result)

        expect(build_client.call_tool('plain_tool', {})).to eq(result)
        expect(log_output.string).not_to include('output schema')
      end

      it 'does not require structuredContent from tools without an output schema' do
        result = { 'content' => [{ 'type' => 'text', 'text' => 'hi' }] }
        allow(mock_server).to receive(:call_tool).and_return(result)

        expect(build_client.call_tool('plain_tool', {})).to eq(result)
        expect(log_output.string).not_to include('structuredContent')
      end

      it 'skips validation for error results (isError: true)' do
        result = { 'isError' => true, 'content' => [], 'structuredContent' => { 'temperature' => 'hot' } }
        allow(mock_server).to receive(:call_tool).and_return(result)

        expect(build_client.call_tool('get_weather', {})).to eq(result)
        expect(log_output.string).not_to include('output schema')
      end

      it 'does not require structuredContent on error results' do
        result = { 'isError' => true, 'content' => [{ 'type' => 'text', 'text' => 'boom' }] }
        allow(mock_server).to receive(:call_tool).and_return(result)

        expect(build_client.call_tool('get_weather', {})).to eq(result)
        expect(log_output.string).not_to include('structuredContent')
      end
    end

    context 'with validate_structured_content: :strict' do
      it 'raises MCPClient::Errors::ValidationError on mismatch' do
        result = { 'content' => [], 'structuredContent' => { 'temperature' => 22.5, 'conditions' => 42 } }
        allow(mock_server).to receive(:call_tool).and_return(result)
        client = build_client(validate_structured_content: :strict)

        expect { client.call_tool('get_weather', {}) }.to raise_error(
          MCPClient::Errors::ValidationError, /get_weather.*does not match its output schema/
        )
      end

      it 'also logs a warning on mismatch' do
        result = { 'content' => [], 'structuredContent' => {} }
        allow(mock_server).to receive(:call_tool).and_return(result)
        client = build_client(validate_structured_content: :strict)

        expect { client.call_tool('get_weather', {}) }.to raise_error(MCPClient::Errors::ValidationError)
        expect(log_output.string).to match(/get_weather.*does not match its output schema/)
      end

      it 'returns conforming results untouched' do
        result = { 'content' => [], 'structuredContent' => { 'temperature' => 1, 'conditions' => 'ok' } }
        allow(mock_server).to receive(:call_tool).and_return(result)
        client = build_client(validate_structured_content: :strict)

        expect(client.call_tool('get_weather', {})).to eq(result)
      end

      it 'raises when a successful result carries no structuredContent despite a declared output schema' do
        result = { 'content' => [{ 'type' => 'text', 'text' => 'hi' }] }
        allow(mock_server).to receive(:call_tool).and_return(result)
        client = build_client(validate_structured_content: :strict)

        expect { client.call_tool('get_weather', {}) }.to raise_error(
          MCPClient::Errors::ValidationError, /get_weather.*declares an output schema.*no structuredContent/
        )
      end

      it 'does not raise for error results without structuredContent' do
        result = { 'isError' => true, 'content' => [{ 'type' => 'text', 'text' => 'boom' }] }
        allow(mock_server).to receive(:call_tool).and_return(result)
        client = build_client(validate_structured_content: :strict)

        expect(client.call_tool('get_weather', {})).to eq(result)
      end
    end

    context 'when the output schema uses keywords outside the supported subset' do
      let(:output_schema) do
        {
          'type' => 'object',
          'properties' => {
            'temperature' => { 'type' => 'number' },
            'conditions' => { 'oneOf' => [{ 'type' => 'string' }, { 'type' => 'null' }] }
          },
          'required' => %w[temperature conditions],
          'additionalProperties' => false
        }
      end
      let(:result) do
        { 'content' => [], 'structuredContent' => { 'temperature' => 22.5, 'conditions' => 'sunny' } }
      end

      before { allow(mock_server).to receive(:call_tool).and_return(result) }

      it 'warns that validation is partial, naming the unsupported keywords, in the default mode' do
        expect(build_client.call_tool('get_weather', {})).to eq(result)
        expect(log_output.string).to match(/get_weather.*validation is partial: schema uses unsupported keywords/)
        expect(log_output.string).to include('oneOf').and include('additionalProperties')
      end

      it 'warns that validation is partial in :strict mode instead of silently passing' do
        client = build_client(validate_structured_content: :strict)

        expect(client.call_tool('get_weather', {})).to eq(result)
        expect(log_output.string).to match(/get_weather.*validation is partial: schema uses unsupported keywords/)
        expect(log_output.string).to include('oneOf').and include('additionalProperties')
      end

      it 'still validates and reports mismatches on the supported subset' do
        mismatch = { 'content' => [], 'structuredContent' => { 'temperature' => 'hot', 'conditions' => 'sunny' } }
        allow(mock_server).to receive(:call_tool).and_return(mismatch)

        expect(build_client.call_tool('get_weather', {})).to eq(mismatch)
        expect(log_output.string).to match(/get_weather.*does not match its output schema/)
      end

      it 'does not warn about partial validation for error results' do
        error_result = { 'isError' => true, 'content' => [] }
        allow(mock_server).to receive(:call_tool).and_return(error_result)

        expect(build_client.call_tool('get_weather', {})).to eq(error_result)
        expect(log_output.string).not_to include('validation is partial')
      end
    end

    context 'when the output schema uses unapplied assertion keywords (format/uniqueItems)' do
      let(:output_schema) do
        {
          'type' => 'object',
          'properties' => {
            'email' => { 'type' => 'string', 'format' => 'email' },
            'tags' => { 'type' => 'array', 'uniqueItems' => true }
          }
        }
      end
      let(:result) do
        { 'content' => [], 'structuredContent' => { 'email' => 'not-an-email', 'tags' => %w[dup dup] } }
      end

      before { allow(mock_server).to receive(:call_tool).and_return(result) }

      it 'warns that validation is partial instead of passing silently in :strict mode' do
        client = build_client(validate_structured_content: :strict)

        expect(client.call_tool('get_weather', {})).to eq(result)
        expect(log_output.string).to match(/get_weather.*validation is partial: schema uses unsupported keywords/)
        expect(log_output.string).to include('format').and include('uniqueItems')
      end
    end

    it 'rejects an unknown validate_structured_content mode' do
      expect { build_client(validate_structured_content: :bogus) }
        .to raise_error(ArgumentError, /validate_structured_content/)
    end
  end
end
