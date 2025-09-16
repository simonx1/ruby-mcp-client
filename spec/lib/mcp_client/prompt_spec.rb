# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Prompt do
  let(:prompt_name) { 'test_prompt' }
  let(:prompt_description) { 'A test prompt for testing' }
  let(:prompt_arguments) { { 'name' => { 'type' => 'string', 'description' => 'Name to greet' } } }

  let(:prompt) do
    described_class.new(
      name: prompt_name,
      description: prompt_description,
      arguments: prompt_arguments
    )
  end

  describe '#initialize' do
    it 'sets the attributes correctly' do
      expect(prompt.name).to eq(prompt_name)
      expect(prompt.description).to eq(prompt_description)
      expect(prompt.arguments).to eq(prompt_arguments)
      expect(prompt.server).to be_nil
    end

    it 'sets server when provided' do
      server = MCPClient::ServerBase.new(name: 'test_server')
      prompt_with_server = described_class.new(
        name: prompt_name,
        description: prompt_description,
        arguments: prompt_arguments,
        server: server
      )
      expect(prompt_with_server.server).to eq(server)
    end

    it 'defaults arguments to empty hash when not provided' do
      prompt = described_class.new(
        name: prompt_name,
        description: prompt_description
      )
      expect(prompt.arguments).to eq({})
    end
  end

  describe '.from_json' do
    let(:json_data) do
      {
        'name' => prompt_name,
        'description' => prompt_description,
        'arguments' => prompt_arguments
      }
    end

    it 'creates a prompt from JSON data' do
      prompt = described_class.from_json(json_data)
      expect(prompt.name).to eq(prompt_name)
      expect(prompt.description).to eq(prompt_description)
      expect(prompt.arguments).to eq(prompt_arguments)
      expect(prompt.server).to be_nil
    end

    it 'associates prompt with server when provided' do
      server = MCPClient::ServerBase.new(name: 'test_server')
      prompt = described_class.from_json(json_data, server: server)
      expect(prompt.server).to eq(server)
    end

    it 'handles missing arguments field' do
      json_data_without_arguments = json_data.except('arguments')
      prompt = described_class.from_json(json_data_without_arguments)
      expect(prompt.arguments).to eq({})
    end
  end
end
