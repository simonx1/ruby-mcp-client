# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::ServerBase do
  let(:base_server) do
    # create an anonymous subclass without implementing abstract methods
    Class.new(MCPClient::ServerBase) do
      # no overrides
    end.new
  end

  describe '#initialize' do
    it 'sets name to nil by default' do
      server = described_class.new
      expect(server.name).to be_nil
    end

    it 'sets name when provided' do
      server = described_class.new(name: 'test_server')
      expect(server.name).to eq('test_server')
    end
  end

  describe '#connect' do
    it 'raises NotImplementedError' do
      expect { base_server.connect }.to raise_error(NotImplementedError)
    end
  end

  describe '#list_prompts' do
    it 'raises NotImplementedError' do
      expect { base_server.list_prompts }.to raise_error(NotImplementedError)
    end
  end

  describe '#get_prompt' do
    it 'raises NotImplementedError' do
      expect { base_server.get_prompt('prompt', {}) }.to raise_error(NotImplementedError)
    end
  end

  describe '#list_tools' do
    it 'raises NotImplementedError' do
      expect { base_server.list_tools }.to raise_error(NotImplementedError)
    end
  end

  describe '#call_tool' do
    it 'raises NotImplementedError' do
      expect { base_server.call_tool('tool', {}) }.to raise_error(NotImplementedError)
    end
  end

  describe '#cleanup' do
    it 'raises NotImplementedError' do
      expect { base_server.cleanup }.to raise_error(NotImplementedError)
    end
  end

  describe '#call_tool_streaming' do
    it 'creates an enumerator that yields call_tool result' do
      # Stub call_tool to return a dummy value
      allow(base_server).to receive(:call_tool).and_return('test_result')
      enum = base_server.call_tool_streaming('tool', {})
      expect(enum).to be_an(Enumerator)
      expect(enum.to_a).to eq(['test_result'])
    end
  end
end
