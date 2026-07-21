# frozen_string_literal: true

require 'spec_helper'

# MCP 2025-11-25 metadata fidelity (SEP-973 icons, BaseMetadata title, _meta).
# Each model class must round-trip the optional wire fields `icons`, `title`,
# and `_meta` from a fully-populated wire hash instead of silently dropping them.
RSpec.describe 'MCP 2025-11-25 model metadata fidelity' do
  let(:icons) do
    [
      { 'src' => 'https://example.com/icon-48.png', 'mimeType' => 'image/png', 'sizes' => ['48x48'] },
      { 'src' => 'https://example.com/icon.svg', 'mimeType' => 'image/svg+xml', 'sizes' => ['any'],
        'theme' => 'dark' }
    ]
  end
  let(:meta) { { 'vendor.example/trace-id' => 'abc-123', 'io.modelcontextprotocol/example' => { 'k' => 'v' } } }

  describe MCPClient::Tool do
    it 'round-trips icons and _meta from a fully-populated tools/list wire hash' do
      data = {
        'name' => 'search',
        'title' => 'Search',
        'description' => 'Searches things',
        'inputSchema' => { 'type' => 'object', 'properties' => { 'q' => { 'type' => 'string' } } },
        'outputSchema' => { 'type' => 'object' },
        'annotations' => { 'readOnlyHint' => true },
        'execution' => { 'taskSupport' => 'optional' },
        'icons' => icons,
        '_meta' => meta
      }

      tool = described_class.from_json(data)

      expect(tool.title).to eq('Search')
      expect(tool.icons).to eq(icons)
      expect(tool.meta).to eq(meta)
    end
  end

  describe MCPClient::Prompt do
    it 'round-trips title, icons, and _meta from a fully-populated prompts/list wire hash' do
      data = {
        'name' => 'code_review',
        'title' => 'Request Code Review',
        'description' => 'Asks the LLM to review code',
        'arguments' => [{ 'name' => 'code', 'required' => true }],
        'icons' => icons,
        '_meta' => meta
      }

      prompt = described_class.from_json(data)

      expect(prompt.title).to eq('Request Code Review')
      expect(prompt.icons).to eq(icons)
      expect(prompt.meta).to eq(meta)
    end
  end

  describe MCPClient::Resource do
    it 'round-trips icons and _meta from a fully-populated resources/list wire hash' do
      data = {
        'uri' => 'file:///project/src/main.rs',
        'name' => 'main.rs',
        'title' => 'Rust Software Application Main File',
        'description' => 'Primary application entry point',
        'mimeType' => 'text/x-rust',
        'size' => 1024,
        'annotations' => { 'audience' => ['user'], 'priority' => 0.5 },
        'icons' => icons,
        '_meta' => meta
      }

      resource = described_class.from_json(data)

      expect(resource.title).to eq('Rust Software Application Main File')
      expect(resource.icons).to eq(icons)
      expect(resource.meta).to eq(meta)
    end
  end

  describe MCPClient::ResourceTemplate do
    it 'round-trips icons and _meta from a fully-populated resources/templates/list wire hash' do
      data = {
        'uriTemplate' => 'file:///{path}',
        'name' => 'project_files',
        'title' => 'Project Files',
        'description' => 'Access files in the project directory',
        'mimeType' => 'application/octet-stream',
        'annotations' => { 'audience' => ['assistant'] },
        'icons' => icons,
        '_meta' => meta
      }

      template = described_class.from_json(data)

      expect(template.title).to eq('Project Files')
      expect(template.icons).to eq(icons)
      expect(template.meta).to eq(meta)
    end
  end

  describe MCPClient::ResourceLink do
    it 'round-trips icons and _meta from a fully-populated resource_link content wire hash' do
      data = {
        'type' => 'resource_link',
        'uri' => 'file:///project/README.md',
        'name' => 'README.md',
        'title' => 'Project README',
        'description' => 'Project documentation',
        'mimeType' => 'text/markdown',
        'size' => 2048,
        'annotations' => { 'audience' => ['user'] },
        'icons' => icons,
        '_meta' => meta
      }

      link = described_class.from_json(data)

      expect(link.title).to eq('Project README')
      expect(link.icons).to eq(icons)
      expect(link.meta).to eq(meta)
    end
  end

  describe MCPClient::ResourceContent do
    it 'round-trips _meta from a fully-populated resources/read contents wire hash' do
      data = {
        'uri' => 'file:///project/README.md',
        'name' => 'README.md',
        'title' => 'Project README',
        'mimeType' => 'text/markdown',
        'text' => '# Project',
        'annotations' => { 'audience' => ['user'] },
        '_meta' => meta
      }

      content = described_class.from_json(data)

      expect(content.title).to eq('Project README')
      expect(content.meta).to eq(meta)
    end
  end
end
