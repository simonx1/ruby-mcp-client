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
  end
end
