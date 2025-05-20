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
      expect(tool.description).to eq(tool_description)
      expect(tool.schema).to eq(tool_schema)
      expect(tool.server).to be_nil
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
      expect(tool.description).to eq(tool_description)
      expect(tool.schema).to eq(tool_schema)
      expect(tool.server).to be_nil
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
end
