# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Root do
  describe '#initialize' do
    it 'creates a root with uri only' do
      root = described_class.new(uri: 'file:///home/user/project')
      expect(root.uri).to eq('file:///home/user/project')
      expect(root.name).to be_nil
    end

    it 'creates a root with uri and name' do
      root = described_class.new(uri: 'file:///home/user/project', name: 'My Project')
      expect(root.uri).to eq('file:///home/user/project')
      expect(root.name).to eq('My Project')
    end
  end

  describe '.from_json' do
    it 'parses JSON with string keys' do
      json = { 'uri' => 'file:///path/to/dir', 'name' => 'Test Root' }
      root = described_class.from_json(json)

      expect(root.uri).to eq('file:///path/to/dir')
      expect(root.name).to eq('Test Root')
    end

    it 'parses JSON with symbol keys' do
      json = { uri: 'file:///path/to/dir', name: 'Test Root' }
      root = described_class.from_json(json)

      expect(root.uri).to eq('file:///path/to/dir')
      expect(root.name).to eq('Test Root')
    end

    it 'handles missing name' do
      json = { 'uri' => 'file:///path/to/dir' }
      root = described_class.from_json(json)

      expect(root.uri).to eq('file:///path/to/dir')
      expect(root.name).to be_nil
    end
  end

  describe '#to_h' do
    it 'returns hash with uri only when name is nil' do
      root = described_class.new(uri: 'file:///path')
      expect(root.to_h).to eq({ 'uri' => 'file:///path' })
    end

    it 'returns hash with uri and name when name is present' do
      root = described_class.new(uri: 'file:///path', name: 'My Root')
      expect(root.to_h).to eq({ 'uri' => 'file:///path', 'name' => 'My Root' })
    end
  end

  describe '#to_json' do
    it 'serializes to JSON string' do
      root = described_class.new(uri: 'file:///path', name: 'Test')
      json = root.to_json
      parsed = JSON.parse(json)

      expect(parsed['uri']).to eq('file:///path')
      expect(parsed['name']).to eq('Test')
    end
  end

  describe 'equality' do
    it 'considers roots with same uri and name as equal' do
      root1 = described_class.new(uri: 'file:///path', name: 'Test')
      root2 = described_class.new(uri: 'file:///path', name: 'Test')

      expect(root1).to eq(root2)
      expect(root1.eql?(root2)).to be true
      expect(root1.hash).to eq(root2.hash)
    end

    it 'considers roots with different uri as not equal' do
      root1 = described_class.new(uri: 'file:///path1', name: 'Test')
      root2 = described_class.new(uri: 'file:///path2', name: 'Test')

      expect(root1).not_to eq(root2)
    end

    it 'considers roots with different name as not equal' do
      root1 = described_class.new(uri: 'file:///path', name: 'Test1')
      root2 = described_class.new(uri: 'file:///path', name: 'Test2')

      expect(root1).not_to eq(root2)
    end
  end

  describe '#to_s' do
    it 'returns uri when name is nil' do
      root = described_class.new(uri: 'file:///path')
      expect(root.to_s).to eq('file:///path')
    end

    it 'returns formatted string when name is present' do
      root = described_class.new(uri: 'file:///path', name: 'My Root')
      expect(root.to_s).to eq('My Root (file:///path)')
    end
  end

  describe '#inspect' do
    it 'returns a readable representation' do
      root = described_class.new(uri: 'file:///path', name: 'Test')
      expect(root.inspect).to eq('#<MCPClient::Root uri="file:///path" name="Test">')
    end
  end
end
