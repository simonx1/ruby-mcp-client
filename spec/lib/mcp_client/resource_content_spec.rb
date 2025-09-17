# frozen_string_literal: true

require 'spec_helper'
require 'base64'

RSpec.describe MCPClient::ResourceContent do
  let(:content_uri) { 'file:///example.txt' }
  let(:content_name) { 'example.txt' }
  let(:content_title) { 'Example Text File' }
  let(:content_mime_type) { 'text/plain' }
  let(:text_content) { 'This is the content of the file' }
  let(:binary_content) { "\x89PNG\r\n\x1A\n" }
  let(:blob_content) { Base64.strict_encode64(binary_content) }
  let(:content_annotations) { { 'audience' => ['user'], 'priority' => 1.0 } }

  describe '#initialize' do
    context 'with text content' do
      let(:resource_content) do
        described_class.new(
          uri: content_uri,
          name: content_name,
          title: content_title,
          mime_type: content_mime_type,
          text: text_content,
          annotations: content_annotations
        )
      end

      it 'sets the attributes correctly' do
        expect(resource_content.uri).to eq(content_uri)
        expect(resource_content.name).to eq(content_name)
        expect(resource_content.title).to eq(content_title)
        expect(resource_content.mime_type).to eq(content_mime_type)
        expect(resource_content.text).to eq(text_content)
        expect(resource_content.blob).to be_nil
        expect(resource_content.annotations).to eq(content_annotations)
      end

      it 'identifies as text content' do
        expect(resource_content.text?).to be true
        expect(resource_content.binary?).to be false
      end

      it 'returns text as content' do
        expect(resource_content.content).to eq(text_content)
      end
    end

    context 'with binary content' do
      let(:resource_content) do
        described_class.new(
          uri: content_uri,
          name: 'example.png',
          title: 'Example Image',
          mime_type: 'image/png',
          blob: blob_content
        )
      end

      it 'sets the attributes correctly' do
        expect(resource_content.uri).to eq(content_uri)
        expect(resource_content.name).to eq('example.png')
        expect(resource_content.mime_type).to eq('image/png')
        expect(resource_content.text).to be_nil
        expect(resource_content.blob).to eq(blob_content)
      end

      it 'identifies as binary content' do
        expect(resource_content.text?).to be false
        expect(resource_content.binary?).to be true
      end

      it 'decodes blob as content' do
        # Compare binary content without modifying frozen strings
        content = resource_content.content
        expected = binary_content
        # Create new strings with proper encoding for comparison
        expect(content.dup.force_encoding('ASCII-8BIT')).to eq(expected.dup.force_encoding('ASCII-8BIT'))
      end
    end

    context 'with both text and blob' do
      it 'raises ArgumentError' do
        expect do
          described_class.new(
            uri: content_uri,
            name: content_name,
            text: text_content,
            blob: blob_content
          )
        end.to raise_error(ArgumentError, 'ResourceContent cannot have both text and blob')
      end
    end

    context 'with neither text nor blob' do
      it 'raises ArgumentError' do
        expect do
          described_class.new(
            uri: content_uri,
            name: content_name
          )
        end.to raise_error(ArgumentError, 'ResourceContent must have either text or blob')
      end
    end
  end

  describe '.from_json' do
    context 'with text content' do
      let(:json_data) do
        {
          'uri' => content_uri,
          'name' => content_name,
          'title' => content_title,
          'mimeType' => content_mime_type,
          'text' => text_content,
          'annotations' => content_annotations
        }
      end

      it 'creates resource content from JSON data' do
        content = described_class.from_json(json_data)
        expect(content.uri).to eq(content_uri)
        expect(content.name).to eq(content_name)
        expect(content.title).to eq(content_title)
        expect(content.mime_type).to eq(content_mime_type)
        expect(content.text).to eq(text_content)
        expect(content.blob).to be_nil
        expect(content.annotations).to eq(content_annotations)
      end
    end

    context 'with binary content' do
      let(:json_data) do
        {
          'uri' => 'file:///image.png',
          'name' => 'image.png',
          'mimeType' => 'image/png',
          'blob' => blob_content
        }
      end

      it 'creates resource content from JSON data' do
        content = described_class.from_json(json_data)
        expect(content.uri).to eq('file:///image.png')
        expect(content.name).to eq('image.png')
        expect(content.mime_type).to eq('image/png')
        expect(content.text).to be_nil
        expect(content.blob).to eq(blob_content)
      end
    end
  end

  describe 'annotations' do
    it 'accepts all valid annotation fields' do
      content = described_class.new(
        uri: content_uri,
        name: content_name,
        text: text_content,
        annotations: {
          'audience' => %w[user assistant],
          'priority' => 0.5,
          'lastModified' => '2025-01-12T15:00:58Z'
        }
      )
      expect(content.annotations['audience']).to eq(%w[user assistant])
      expect(content.annotations['priority']).to eq(0.5)
      expect(content.annotations['lastModified']).to eq('2025-01-12T15:00:58Z')
    end
  end
end
