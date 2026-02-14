# frozen_string_literal: true

require 'spec_helper'
require 'base64'

RSpec.describe MCPClient::AudioContent do
  let(:audio_bytes) { "\x00\x01\x02\x03\xFF\xFE\xFD" }
  let(:audio_data) { Base64.strict_encode64(audio_bytes) }
  let(:audio_mime_type) { 'audio/wav' }
  let(:content_annotations) { { 'audience' => ['user'], 'priority' => 0.5 } }

  describe '#initialize' do
    context 'with valid parameters' do
      let(:audio_content) do
        described_class.new(
          data: audio_data,
          mime_type: audio_mime_type,
          annotations: content_annotations
        )
      end

      it 'sets the attributes correctly' do
        expect(audio_content.data).to eq(audio_data)
        expect(audio_content.mime_type).to eq(audio_mime_type)
        expect(audio_content.annotations).to eq(content_annotations)
      end
    end

    context 'without annotations' do
      let(:audio_content) do
        described_class.new(data: audio_data, mime_type: audio_mime_type)
      end

      it 'defaults annotations to nil' do
        expect(audio_content.annotations).to be_nil
      end
    end

    context 'without data' do
      it 'raises ArgumentError for nil data' do
        expect do
          described_class.new(data: nil, mime_type: audio_mime_type)
        end.to raise_error(ArgumentError, 'AudioContent requires data')
      end

      it 'raises ArgumentError for empty data' do
        expect do
          described_class.new(data: '', mime_type: audio_mime_type)
        end.to raise_error(ArgumentError, 'AudioContent requires data')
      end
    end

    context 'without mime_type' do
      it 'raises ArgumentError for nil mime_type' do
        expect do
          described_class.new(data: audio_data, mime_type: nil)
        end.to raise_error(ArgumentError, 'AudioContent requires mime_type')
      end

      it 'raises ArgumentError for empty mime_type' do
        expect do
          described_class.new(data: audio_data, mime_type: '')
        end.to raise_error(ArgumentError, 'AudioContent requires mime_type')
      end
    end
  end

  describe '.from_json' do
    context 'with all fields' do
      let(:json_data) do
        {
          'type' => 'audio',
          'data' => audio_data,
          'mimeType' => audio_mime_type,
          'annotations' => content_annotations
        }
      end

      it 'creates audio content from JSON data' do
        content = described_class.from_json(json_data)
        expect(content.data).to eq(audio_data)
        expect(content.mime_type).to eq(audio_mime_type)
        expect(content.annotations).to eq(content_annotations)
      end
    end

    context 'without annotations' do
      let(:json_data) do
        {
          'type' => 'audio',
          'data' => audio_data,
          'mimeType' => 'audio/mpeg'
        }
      end

      it 'creates audio content with nil annotations' do
        content = described_class.from_json(json_data)
        expect(content.data).to eq(audio_data)
        expect(content.mime_type).to eq('audio/mpeg')
        expect(content.annotations).to be_nil
      end
    end
  end

  describe '#content' do
    let(:audio_content) do
      described_class.new(data: audio_data, mime_type: audio_mime_type)
    end

    it 'decodes base64 data' do
      decoded = audio_content.content
      expect(decoded.dup.force_encoding('ASCII-8BIT')).to eq(audio_bytes.dup.force_encoding('ASCII-8BIT'))
    end
  end

  describe 'annotations' do
    it 'accepts all valid annotation fields' do
      content = described_class.new(
        data: audio_data,
        mime_type: audio_mime_type,
        annotations: {
          'audience' => %w[user assistant],
          'priority' => 0.8,
          'lastModified' => '2025-11-25T10:00:00Z'
        }
      )
      expect(content.annotations['audience']).to eq(%w[user assistant])
      expect(content.annotations['priority']).to eq(0.8)
      expect(content.annotations['lastModified']).to eq('2025-11-25T10:00:00Z')
    end
  end
end
