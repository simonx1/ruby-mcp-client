# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Tool do
  let(:tool_name) { 'test_tool' }
  let(:tool_description) { 'A test tool for testing' }
  let(:tool_schema) do
    {
      'type' => 'object',
      'properties' => {
        'param1' => { 'type' => 'string' },
        'param2' => { 'type' => 'number' }
      },
      'required' => ['param1']
    }
  end

  let(:tool) do
    described_class.new(
      name: tool_name,
      description: tool_description,
      schema: tool_schema
    )
  end

  describe '#initialize' do
    it 'sets the attributes correctly' do
      expect(tool.name).to eq(tool_name)
      expect(tool.title).to be_nil
      expect(tool.description).to eq(tool_description)
      expect(tool.schema).to eq(tool_schema)
      expect(tool.server).to be_nil
    end

    it 'sets title when provided' do
      tool_title = 'Test Tool Display Name'
      tool_with_title = described_class.new(
        name: tool_name,
        description: tool_description,
        schema: tool_schema,
        title: tool_title
      )
      expect(tool_with_title.title).to eq(tool_title)
    end

    it 'sets server when provided' do
      server = MCPClient::ServerBase.new(name: 'test_server')
      tool_with_server = described_class.new(
        name: tool_name,
        description: tool_description,
        schema: tool_schema,
        server: server
      )
      expect(tool_with_server.server).to eq(server)
    end
  end

  describe '.from_json' do
    let(:json_data) do
      {
        'name' => tool_name,
        'description' => tool_description,
        'schema' => tool_schema
      }
    end

    it 'creates a tool from JSON data' do
      tool = described_class.from_json(json_data)
      expect(tool.name).to eq(tool_name)
      expect(tool.title).to be_nil
      expect(tool.description).to eq(tool_description)
      expect(tool.schema).to eq(tool_schema)
      expect(tool.server).to be_nil
    end

    it 'parses title from JSON data with string keys' do
      json_data_with_title = json_data.merge('title' => 'Test Tool Display Name')
      tool = described_class.from_json(json_data_with_title)
      expect(tool.title).to eq('Test Tool Display Name')
    end

    it 'parses title from JSON data with symbol keys' do
      json_data_with_title = {
        name: tool_name,
        description: tool_description,
        schema: tool_schema,
        title: 'Test Tool Display Name'
      }
      tool = described_class.from_json(json_data_with_title)
      expect(tool.title).to eq('Test Tool Display Name')
    end

    it 'associates tool with server when provided' do
      server = MCPClient::ServerBase.new(name: 'test_server')
      tool = described_class.from_json(json_data, server: server)
      expect(tool.server).to eq(server)
    end
  end

  describe '#to_openai_tool' do
    it 'converts the tool to OpenAI function format' do
      openai_tool = tool.to_openai_tool
      # Function object format
      expect(openai_tool).to eq(
        {
          type: 'function',
          function: {
            name: tool_name,
            description: tool_description,
            parameters: tool_schema
          }
        }
      )
    end
  end

  describe '#to_anthropic_tool' do
    it 'converts the tool to Anthropic Claude tool format' do
      anthropic_tool = tool.to_anthropic_tool
      # Claude tool format
      expect(anthropic_tool).to eq(
        {
          name: tool_name,
          description: tool_description,
          input_schema: tool_schema
        }
      )
    end

    context 'with $schema in the schema' do
      let(:tool_with_dollar_schema) do
        described_class.new(
          name: tool_name,
          description: tool_description,
          schema: {
            '$schema' => 'https://json-schema.org/draft/2020-12/schema',
            'type' => 'object',
            'properties' => {
              'path' => { 'type' => 'string' }
            },
            'required' => ['path']
          }
        )
      end

      it 'removes $schema keys from the schema' do
        anthropic_tool = tool_with_dollar_schema.to_anthropic_tool
        expect(anthropic_tool[:input_schema]).to eq(
          {
            'type' => 'object',
            'properties' => {
              'path' => { 'type' => 'string' }
            },
            'required' => ['path']
          }
        )
      end
    end
  end

  describe '#to_google_tool' do
    it 'converts the tool to Google tool format' do
      google_tool = tool.to_google_tool
      # Google tool format
      expect(google_tool).to eq(
        {
          name: tool_name,
          description: tool_description,
          parameters: tool_schema
        }
      )
    end

    context 'with $schema in the schema' do
      let(:schema_with_dollar_schema) do
        {
          '$schema' => 'http://json-schema.org/draft-07/schema#',
          'type' => 'object',
          'properties' => {
            'param1' => { 'type' => 'string', '$schema' => 'http://example.com' },
            'param2' => { 'type' => 'number' }
          },
          'required' => ['param1']
        }
      end

      let(:expected_cleaned_schema) do
        {
          'type' => 'object',
          'properties' => {
            'param1' => { 'type' => 'string' },
            'param2' => { 'type' => 'number' }
          },
          'required' => ['param1']
        }
      end

      let(:tool_with_schema) do
        described_class.new(
          name: tool_name,
          description: tool_description,
          schema: schema_with_dollar_schema
        )
      end

      it 'removes $schema keys from the schema' do
        google_tool = tool_with_schema.to_google_tool
        expect(google_tool[:parameters]).to eq(expected_cleaned_schema)
      end
    end

    context 'with $schema inside nested arrays' do
      let(:schema_with_nested_arrays) do
        {
          '$schema' => 'http://json-schema.org/draft-07/schema#',
          'type' => 'object',
          'properties' => {
            'matrix' => {
              '$schema' => 'http://example.com/array',
              'type' => 'array',
              'items' => [
                {
                  'type' => 'array',
                  '$schema' => 'http://example.com/nested',
                  'items' => [
                    { 'type' => 'string', '$schema' => 'http://example.com/str' }
                  ]
                },
                { 'type' => 'number', '$schema' => 'http://example.com/num' }
              ]
            }
          },
          'required' => ['matrix']
        }
      end

      let(:expected_nested_cleaned_schema) do
        {
          'type' => 'object',
          'properties' => {
            'matrix' => {
              'type' => 'array',
              'items' => [
                {
                  'type' => 'array',
                  'items' => [
                    { 'type' => 'string' }
                  ]
                },
                { 'type' => 'number' }
              ]
            }
          },
          'required' => ['matrix']
        }
      end

      let(:tool_with_nested_arrays) do
        described_class.new(
          name: tool_name,
          description: tool_description,
          schema: schema_with_nested_arrays
        )
      end

      it 'removes $schema keys from nested arrays' do
        google_tool = tool_with_nested_arrays.to_google_tool
        expect(google_tool[:parameters]).to eq(expected_nested_cleaned_schema)
      end
    end
  end

  describe 'legacy annotation helpers' do
    describe '#read_only?' do
      it 'returns false when no annotations' do
        expect(tool.read_only?).to be false
      end

      it 'returns true when readOnly annotation is true' do
        t = described_class.new(name: 't', description: 'd', schema: {}, annotations: { 'readOnly' => true })
        expect(t.read_only?).to be true
      end

      it 'returns false when readOnly annotation is false' do
        t = described_class.new(name: 't', description: 'd', schema: {}, annotations: { 'readOnly' => false })
        expect(t.read_only?).to be false
      end
    end

    describe '#destructive?' do
      it 'returns false when no annotations' do
        expect(tool.destructive?).to be false
      end

      it 'returns true when destructive annotation is true' do
        t = described_class.new(name: 't', description: 'd', schema: {}, annotations: { 'destructive' => true })
        expect(t.destructive?).to be true
      end
    end

    describe '#requires_confirmation?' do
      it 'returns false when no annotations' do
        expect(tool.requires_confirmation?).to be false
      end

      it 'returns true when requiresConfirmation annotation is true' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { 'requiresConfirmation' => true })
        expect(t.requires_confirmation?).to be true
      end
    end
  end

  describe 'MCP 2025-11-25 annotation hints' do
    describe '#read_only_hint?' do
      it 'defaults to true when no annotations' do
        expect(tool.read_only_hint?).to be true
      end

      it 'defaults to true when annotations exist but readOnlyHint is not set' do
        t = described_class.new(name: 't', description: 'd', schema: {}, annotations: {})
        expect(t.read_only_hint?).to be true
      end

      it 'returns true when readOnlyHint is true (string key)' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { 'readOnlyHint' => true })
        expect(t.read_only_hint?).to be true
      end

      it 'returns false when readOnlyHint is false' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { 'readOnlyHint' => false })
        expect(t.read_only_hint?).to be false
      end

      it 'returns true when readOnlyHint is true (symbol key)' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { readOnlyHint: true })
        expect(t.read_only_hint?).to be true
      end
    end

    describe '#destructive_hint?' do
      it 'defaults to false when no annotations' do
        expect(tool.destructive_hint?).to be false
      end

      it 'defaults to false when annotations exist but destructiveHint is not set' do
        t = described_class.new(name: 't', description: 'd', schema: {}, annotations: {})
        expect(t.destructive_hint?).to be false
      end

      it 'returns false when destructiveHint is false (string key)' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { 'destructiveHint' => false })
        expect(t.destructive_hint?).to be false
      end

      it 'returns true when destructiveHint is true' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { 'destructiveHint' => true })
        expect(t.destructive_hint?).to be true
      end

      it 'returns false when destructiveHint is false (symbol key)' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { destructiveHint: false })
        expect(t.destructive_hint?).to be false
      end
    end

    describe '#idempotent_hint?' do
      it 'defaults to false when no annotations' do
        expect(tool.idempotent_hint?).to be false
      end

      it 'defaults to false when annotations exist but idempotentHint is not set' do
        t = described_class.new(name: 't', description: 'd', schema: {}, annotations: {})
        expect(t.idempotent_hint?).to be false
      end

      it 'returns true when idempotentHint is true (string key)' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { 'idempotentHint' => true })
        expect(t.idempotent_hint?).to be true
      end

      it 'returns false when idempotentHint is false' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { 'idempotentHint' => false })
        expect(t.idempotent_hint?).to be false
      end

      it 'returns true when idempotentHint is true (symbol key)' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { idempotentHint: true })
        expect(t.idempotent_hint?).to be true
      end
    end

    describe '#open_world_hint?' do
      it 'defaults to true when no annotations' do
        expect(tool.open_world_hint?).to be true
      end

      it 'defaults to true when annotations exist but openWorldHint is not set' do
        t = described_class.new(name: 't', description: 'd', schema: {}, annotations: {})
        expect(t.open_world_hint?).to be true
      end

      it 'returns false when openWorldHint is false (string key)' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { 'openWorldHint' => false })
        expect(t.open_world_hint?).to be false
      end

      it 'returns true when openWorldHint is true' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { 'openWorldHint' => true })
        expect(t.open_world_hint?).to be true
      end

      it 'returns false when openWorldHint is false (symbol key)' do
        t = described_class.new(name: 't', description: 'd', schema: {},
                                annotations: { openWorldHint: false })
        expect(t.open_world_hint?).to be false
      end
    end

    context 'with all hints set' do
      let(:fully_annotated_tool) do
        described_class.new(
          name: 'annotated_tool',
          description: 'A fully annotated tool',
          schema: tool_schema,
          annotations: {
            'readOnlyHint' => true,
            'destructiveHint' => false,
            'idempotentHint' => true,
            'openWorldHint' => false
          }
        )
      end

      it 'returns correct values for all hints' do
        expect(fully_annotated_tool.read_only_hint?).to be true
        expect(fully_annotated_tool.destructive_hint?).to be false
        expect(fully_annotated_tool.idempotent_hint?).to be true
        expect(fully_annotated_tool.open_world_hint?).to be false
      end
    end
  end

  describe '.from_json with annotations' do
    it 'parses MCP 2025-11-25 annotation hints from JSON with string keys' do
      data = {
        'name' => 'annotated',
        'description' => 'desc',
        'inputSchema' => tool_schema,
        'annotations' => {
          'readOnlyHint' => true,
          'destructiveHint' => false,
          'idempotentHint' => true,
          'openWorldHint' => false
        }
      }
      t = described_class.from_json(data)
      expect(t.read_only_hint?).to be true
      expect(t.destructive_hint?).to be false
      expect(t.idempotent_hint?).to be true
      expect(t.open_world_hint?).to be false
    end

    it 'parses annotations from JSON with symbol keys' do
      data = {
        name: 'annotated',
        description: 'desc',
        inputSchema: tool_schema,
        annotations: {
          readOnlyHint: true,
          destructiveHint: false
        }
      }
      t = described_class.from_json(data)
      expect(t.read_only_hint?).to be true
      expect(t.destructive_hint?).to be false
    end
  end

  describe 'outputSchema support' do
    let(:output_schema) do
      {
        'type' => 'object',
        'properties' => {
          'result' => { 'type' => 'string' },
          'count' => { 'type' => 'integer' }
        },
        'required' => ['result']
      }
    end

    describe '#structured_output?' do
      it 'returns false when no output_schema' do
        expect(tool.structured_output?).to be false
      end

      it 'returns false when output_schema is empty' do
        t = described_class.new(name: 't', description: 'd', schema: {}, output_schema: {})
        expect(t.structured_output?).to be false
      end

      it 'returns true when output_schema is present' do
        t = described_class.new(name: 't', description: 'd', schema: {}, output_schema: output_schema)
        expect(t.structured_output?).to be true
      end
    end

    describe '#output_schema' do
      it 'is nil by default' do
        expect(tool.output_schema).to be_nil
      end

      it 'stores the output schema' do
        t = described_class.new(name: 't', description: 'd', schema: {}, output_schema: output_schema)
        expect(t.output_schema).to eq(output_schema)
      end
    end

    describe '.from_json with outputSchema' do
      it 'parses outputSchema from JSON with string keys' do
        data = {
          'name' => 'tool_with_output',
          'description' => 'desc',
          'inputSchema' => tool_schema,
          'outputSchema' => output_schema
        }
        t = described_class.from_json(data)
        expect(t.output_schema).to eq(output_schema)
        expect(t.structured_output?).to be true
      end

      it 'parses outputSchema from JSON with symbol keys' do
        data = {
          name: 'tool_with_output',
          description: 'desc',
          inputSchema: tool_schema,
          outputSchema: output_schema
        }
        t = described_class.from_json(data)
        expect(t.output_schema).to eq(output_schema)
        expect(t.structured_output?).to be true
      end

      it 'handles missing outputSchema' do
        data = {
          'name' => 'tool_without_output',
          'description' => 'desc',
          'inputSchema' => tool_schema
        }
        t = described_class.from_json(data)
        expect(t.output_schema).to be_nil
        expect(t.structured_output?).to be false
      end
    end
  end
end
