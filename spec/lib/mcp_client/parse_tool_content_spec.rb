# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'MCPClient.parse_tool_content' do
  describe '.parse_content_item' do
    it 'converts resource_link type to ResourceLink' do
      item = {
        'type' => 'resource_link',
        'uri' => 'file:///docs/guide.md',
        'name' => 'guide.md',
        'description' => 'User guide',
        'mimeType' => 'text/markdown'
      }
      result = MCPClient.parse_content_item(item)
      expect(result).to be_a(MCPClient::ResourceLink)
      expect(result.uri).to eq('file:///docs/guide.md')
      expect(result.name).to eq('guide.md')
      expect(result.description).to eq('User guide')
      expect(result.mime_type).to eq('text/markdown')
    end

    it 'returns text content as-is' do
      item = { 'type' => 'text', 'text' => 'hello world' }
      result = MCPClient.parse_content_item(item)
      expect(result).to eq(item)
    end

    it 'returns image content as-is' do
      item = { 'type' => 'image', 'data' => 'base64data', 'mimeType' => 'image/png' }
      result = MCPClient.parse_content_item(item)
      expect(result).to eq(item)
    end

    it 'returns unknown types as-is' do
      item = { 'type' => 'custom', 'data' => 'something' }
      result = MCPClient.parse_content_item(item)
      expect(result).to eq(item)
    end
  end

  describe '.parse_tool_content' do
    it 'parses a mixed content array' do
      content = [
        { 'type' => 'text', 'text' => 'Found 2 relevant files' },
        {
          'type' => 'resource_link',
          'uri' => 'file:///src/main.rb',
          'name' => 'main.rb',
          'description' => 'Main entry point',
          'mimeType' => 'application/x-ruby'
        },
        {
          'type' => 'resource_link',
          'uri' => 'file:///src/helper.rb',
          'name' => 'helper.rb'
        }
      ]

      results = MCPClient.parse_tool_content(content)
      expect(results.size).to eq(3)

      expect(results[0]).to be_a(Hash)
      expect(results[0]['type']).to eq('text')

      expect(results[1]).to be_a(MCPClient::ResourceLink)
      expect(results[1].uri).to eq('file:///src/main.rb')
      expect(results[1].name).to eq('main.rb')
      expect(results[1].description).to eq('Main entry point')

      expect(results[2]).to be_a(MCPClient::ResourceLink)
      expect(results[2].uri).to eq('file:///src/helper.rb')
      expect(results[2].name).to eq('helper.rb')
      expect(results[2].description).to be_nil
    end

    it 'handles empty content array' do
      expect(MCPClient.parse_tool_content([])).to eq([])
    end

    it 'handles nil content' do
      expect(MCPClient.parse_tool_content(nil)).to eq([])
    end
  end
end
