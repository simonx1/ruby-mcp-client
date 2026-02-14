# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::ResourceLink do
  let(:link_uri) { 'file:///project/README.md' }
  let(:link_name) { 'README.md' }
  let(:link_description) { 'Project documentation' }
  let(:link_mime_type) { 'text/markdown' }
  let(:link_annotations) { { 'audience' => ['user'], 'priority' => 0.8 } }

  describe '#initialize' do
    context 'with all attributes' do
      let(:resource_link) do
        described_class.new(
          uri: link_uri,
          name: link_name,
          description: link_description,
          mime_type: link_mime_type,
          annotations: link_annotations
        )
      end

      it 'sets the attributes correctly' do
        expect(resource_link.uri).to eq(link_uri)
        expect(resource_link.name).to eq(link_name)
        expect(resource_link.description).to eq(link_description)
        expect(resource_link.mime_type).to eq(link_mime_type)
        expect(resource_link.annotations).to eq(link_annotations)
      end

      it 'returns resource_link as the type' do
        expect(resource_link.type).to eq('resource_link')
      end
    end

    context 'with required attributes only' do
      let(:resource_link) do
        described_class.new(uri: link_uri, name: link_name)
      end

      it 'sets required attributes and defaults optional ones to nil' do
        expect(resource_link.uri).to eq(link_uri)
        expect(resource_link.name).to eq(link_name)
        expect(resource_link.description).to be_nil
        expect(resource_link.mime_type).to be_nil
        expect(resource_link.annotations).to be_nil
      end
    end
  end

  describe '.from_json' do
    context 'with all fields' do
      let(:json_data) do
        {
          'type' => 'resource_link',
          'uri' => link_uri,
          'name' => link_name,
          'description' => link_description,
          'mimeType' => link_mime_type,
          'annotations' => link_annotations
        }
      end

      it 'creates a resource link from JSON data' do
        link = described_class.from_json(json_data)
        expect(link.uri).to eq(link_uri)
        expect(link.name).to eq(link_name)
        expect(link.description).to eq(link_description)
        expect(link.mime_type).to eq(link_mime_type)
        expect(link.annotations).to eq(link_annotations)
      end
    end

    context 'with required fields only' do
      let(:json_data) do
        {
          'type' => 'resource_link',
          'uri' => link_uri,
          'name' => link_name
        }
      end

      it 'creates a resource link with nil optional fields' do
        link = described_class.from_json(json_data)
        expect(link.uri).to eq(link_uri)
        expect(link.name).to eq(link_name)
        expect(link.description).to be_nil
        expect(link.mime_type).to be_nil
        expect(link.annotations).to be_nil
      end
    end
  end

  describe '#type' do
    it 'returns resource_link' do
      link = described_class.new(uri: link_uri, name: link_name)
      expect(link.type).to eq('resource_link')
    end
  end

  describe 'annotations' do
    it 'accepts all valid annotation fields' do
      link = described_class.new(
        uri: link_uri,
        name: link_name,
        annotations: {
          'audience' => %w[user assistant],
          'priority' => 0.5,
          'lastModified' => '2025-11-25T10:00:00Z'
        }
      )
      expect(link.annotations['audience']).to eq(%w[user assistant])
      expect(link.annotations['priority']).to eq(0.5)
      expect(link.annotations['lastModified']).to eq('2025-11-25T10:00:00Z')
    end
  end
end
