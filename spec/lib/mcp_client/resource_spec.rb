# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Resource do
  let(:resource_uri) { 'file:///example.txt' }
  let(:resource_name) { 'example.txt' }
  let(:resource_title) { 'Example Text File' }
  let(:resource_description) { 'A test file for testing' }
  let(:resource_mime_type) { 'text/plain' }
  let(:resource_size) { 1024 }
  let(:resource_annotations) { { 'audience' => ['user'], 'priority' => 0.8, 'lastModified' => '2025-07-15T10:30:00Z' } }

  let(:resource) do
    described_class.new(
      uri: resource_uri,
      name: resource_name,
      title: resource_title,
      description: resource_description,
      mime_type: resource_mime_type,
      size: resource_size,
      annotations: resource_annotations
    )
  end

  describe '#initialize' do
    it 'sets the attributes correctly' do
      expect(resource.uri).to eq(resource_uri)
      expect(resource.name).to eq(resource_name)
      expect(resource.title).to eq(resource_title)
      expect(resource.description).to eq(resource_description)
      expect(resource.mime_type).to eq(resource_mime_type)
      expect(resource.size).to eq(resource_size)
      expect(resource.annotations).to eq(resource_annotations)
      expect(resource.server).to be_nil
    end

    it 'sets server when provided' do
      server = MCPClient::ServerBase.new(name: 'test_server')
      resource_with_server = described_class.new(
        uri: resource_uri,
        name: resource_name,
        server: server
      )
      expect(resource_with_server.server).to eq(server)
    end

    it 'accepts minimal required parameters' do
      minimal_resource = described_class.new(
        uri: resource_uri,
        name: resource_name
      )
      expect(minimal_resource.uri).to eq(resource_uri)
      expect(minimal_resource.name).to eq(resource_name)
      expect(minimal_resource.title).to be_nil
      expect(minimal_resource.description).to be_nil
      expect(minimal_resource.mime_type).to be_nil
      expect(minimal_resource.size).to be_nil
      expect(minimal_resource.annotations).to be_nil
    end
  end

  describe '.from_json' do
    let(:json_data) do
      {
        'uri' => resource_uri,
        'name' => resource_name,
        'title' => resource_title,
        'description' => resource_description,
        'mimeType' => resource_mime_type,
        'size' => resource_size,
        'annotations' => resource_annotations
      }
    end

    it 'creates a resource from JSON data' do
      resource = described_class.from_json(json_data)
      expect(resource.uri).to eq(resource_uri)
      expect(resource.name).to eq(resource_name)
      expect(resource.title).to eq(resource_title)
      expect(resource.description).to eq(resource_description)
      expect(resource.mime_type).to eq(resource_mime_type)
      expect(resource.size).to eq(resource_size)
      expect(resource.annotations).to eq(resource_annotations)
      expect(resource.server).to be_nil
    end

    it 'associates resource with server when provided' do
      server = MCPClient::ServerBase.new(name: 'test_server')
      resource = described_class.from_json(json_data, server: server)
      expect(resource.server).to eq(server)
    end

    it 'handles minimal JSON data' do
      minimal_json = { 'uri' => resource_uri, 'name' => resource_name }
      resource = described_class.from_json(minimal_json)
      expect(resource.uri).to eq(resource_uri)
      expect(resource.name).to eq(resource_name)
      expect(resource.title).to be_nil
      expect(resource.description).to be_nil
      expect(resource.mime_type).to be_nil
      expect(resource.size).to be_nil
      expect(resource.annotations).to be_nil
    end
  end

  describe 'annotations' do
    context 'with valid annotations' do
      it 'accepts audience array' do
        resource = described_class.new(
          uri: resource_uri,
          name: resource_name,
          annotations: { 'audience' => %w[user assistant] }
        )
        expect(resource.annotations['audience']).to eq(%w[user assistant])
      end

      it 'accepts priority number' do
        resource = described_class.new(
          uri: resource_uri,
          name: resource_name,
          annotations: { 'priority' => 0.8 }
        )
        expect(resource.annotations['priority']).to eq(0.8)
      end

      it 'accepts lastModified timestamp' do
        resource = described_class.new(
          uri: resource_uri,
          name: resource_name,
          annotations: { 'lastModified' => '2025-07-15T10:30:00Z' }
        )
        expect(resource.annotations['lastModified']).to eq('2025-07-15T10:30:00Z')
      end
    end
  end

  describe '#last_modified' do
    it 'returns the lastModified annotation value' do
      resource = described_class.new(
        uri: resource_uri,
        name: resource_name,
        annotations: { 'lastModified' => '2025-07-15T10:30:00Z' }
      )
      expect(resource.last_modified).to eq('2025-07-15T10:30:00Z')
    end

    it 'returns nil when annotations are nil' do
      resource = described_class.new(
        uri: resource_uri,
        name: resource_name
      )
      expect(resource.last_modified).to be_nil
    end

    it 'returns nil when lastModified is not set' do
      resource = described_class.new(
        uri: resource_uri,
        name: resource_name,
        annotations: { 'audience' => ['user'] }
      )
      expect(resource.last_modified).to be_nil
    end
  end
end
