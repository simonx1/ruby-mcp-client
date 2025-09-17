# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::ResourceTemplate do
  let(:template_uri) { 'file:///{path}' }
  let(:template_name) { 'Project Files' }
  let(:template_title) { '📁 Project Files' }
  let(:template_description) { 'Access files in the project directory' }
  let(:template_mime_type) { 'application/octet-stream' }
  let(:template_annotations) { { 'audience' => %w[user assistant], 'priority' => 0.5 } }

  let(:resource_template) do
    described_class.new(
      uri_template: template_uri,
      name: template_name,
      title: template_title,
      description: template_description,
      mime_type: template_mime_type,
      annotations: template_annotations
    )
  end

  describe '#initialize' do
    it 'sets the attributes correctly' do
      expect(resource_template.uri_template).to eq(template_uri)
      expect(resource_template.name).to eq(template_name)
      expect(resource_template.title).to eq(template_title)
      expect(resource_template.description).to eq(template_description)
      expect(resource_template.mime_type).to eq(template_mime_type)
      expect(resource_template.annotations).to eq(template_annotations)
      expect(resource_template.server).to be_nil
    end

    it 'sets server when provided' do
      server = MCPClient::ServerBase.new(name: 'test_server')
      template_with_server = described_class.new(
        uri_template: template_uri,
        name: template_name,
        server: server
      )
      expect(template_with_server.server).to eq(server)
    end

    it 'accepts minimal required parameters' do
      minimal_template = described_class.new(
        uri_template: template_uri,
        name: template_name
      )
      expect(minimal_template.uri_template).to eq(template_uri)
      expect(minimal_template.name).to eq(template_name)
      expect(minimal_template.title).to be_nil
      expect(minimal_template.description).to be_nil
      expect(minimal_template.mime_type).to be_nil
      expect(minimal_template.annotations).to be_nil
    end
  end

  describe '.from_json' do
    let(:json_data) do
      {
        'uriTemplate' => template_uri,
        'name' => template_name,
        'title' => template_title,
        'description' => template_description,
        'mimeType' => template_mime_type,
        'annotations' => template_annotations
      }
    end

    it 'creates a resource template from JSON data' do
      template = described_class.from_json(json_data)
      expect(template.uri_template).to eq(template_uri)
      expect(template.name).to eq(template_name)
      expect(template.title).to eq(template_title)
      expect(template.description).to eq(template_description)
      expect(template.mime_type).to eq(template_mime_type)
      expect(template.annotations).to eq(template_annotations)
      expect(template.server).to be_nil
    end

    it 'associates template with server when provided' do
      server = MCPClient::ServerBase.new(name: 'test_server')
      template = described_class.from_json(json_data, server: server)
      expect(template.server).to eq(server)
    end

    it 'handles minimal JSON data' do
      minimal_json = { 'uriTemplate' => template_uri, 'name' => template_name }
      template = described_class.from_json(minimal_json)
      expect(template.uri_template).to eq(template_uri)
      expect(template.name).to eq(template_name)
      expect(template.title).to be_nil
      expect(template.description).to be_nil
      expect(template.mime_type).to be_nil
      expect(template.annotations).to be_nil
    end
  end

  describe 'annotations validation' do
    context 'with valid annotations' do
      it 'accepts audience array' do
        template = described_class.new(
          uri_template: template_uri,
          name: template_name,
          annotations: { 'audience' => %w[user assistant] }
        )
        expect(template.annotations['audience']).to eq(%w[user assistant])
      end

      it 'accepts priority number' do
        template = described_class.new(
          uri_template: template_uri,
          name: template_name,
          annotations: { 'priority' => 0.8 }
        )
        expect(template.annotations['priority']).to eq(0.8)
      end

      it 'accepts lastModified timestamp' do
        template = described_class.new(
          uri_template: template_uri,
          name: template_name,
          annotations: { 'lastModified' => '2025-01-12T15:00:58Z' }
        )
        expect(template.annotations['lastModified']).to eq('2025-01-12T15:00:58Z')
      end
    end
  end
end
