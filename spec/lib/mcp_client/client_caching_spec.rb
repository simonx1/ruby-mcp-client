# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Client, 'caching' do
  let(:logger) { Logger.new(nil) }
  let(:server1_config) do
    {
      type: 'stdio',
      name: 'server1',
      command: 'echo',
      args: ['hello']
    }
  end
  let(:server2_config) do
    {
      type: 'stdio',
      name: 'server2',
      command: 'echo',
      args: ['world']
    }
  end

  subject(:client) do
    described_class.new(
      mcp_server_configs: [server1_config, server2_config],
      logger: logger
    )
  end

  describe 'tool caching with same-named tools from different servers' do
    let(:server1) { instance_double(MCPClient::ServerStdio, name: 'server1') }
    let(:server2) { instance_double(MCPClient::ServerStdio, name: 'server2') }

    let(:tool1_from_server1) do
      MCPClient::Tool.new(
        name: 'duplicate_tool',
        description: 'Tool from server 1',
        schema: {},
        server: server1
      )
    end

    let(:tool2_from_server2) do
      MCPClient::Tool.new(
        name: 'duplicate_tool',
        description: 'Tool from server 2',
        schema: {},
        server: server2
      )
    end

    let(:unique_tool_from_server1) do
      MCPClient::Tool.new(
        name: 'unique_tool',
        description: 'Unique tool from server 1',
        schema: {},
        server: server1
      )
    end

    before do
      client.instance_variable_set(:@servers, [server1, server2])
      allow(server1).to receive(:list_tools).and_return([tool1_from_server1, unique_tool_from_server1])
      allow(server2).to receive(:list_tools).and_return([tool2_from_server2])
      allow(server1).to receive(:object_id).and_return(123456)
      allow(server2).to receive(:object_id).and_return(789012)
    end

    it 'caches both tools with same name from different servers' do
      client.list_tools

      # Both tools should be in the cache with different keys
      expect(client.tool_cache.size).to eq(3)
      expect(client.tool_cache["123456:duplicate_tool"]).to eq(tool1_from_server1)
      expect(client.tool_cache["789012:duplicate_tool"]).to eq(tool2_from_server2)
      expect(client.tool_cache["123456:unique_tool"]).to eq(unique_tool_from_server1)
    end

    it 'returns all tools including duplicates' do
      tools = client.list_tools

      expect(tools.size).to eq(3)
      expect(tools).to include(tool1_from_server1)
      expect(tools).to include(tool2_from_server2)
      expect(tools).to include(unique_tool_from_server1)
    end

    it 'uses cached tools on subsequent calls' do
      # First call populates cache
      client.list_tools

      # Second call should not hit servers
      expect(server1).not_to receive(:list_tools)
      expect(server2).not_to receive(:list_tools)

      tools = client.list_tools(cache: true)
      expect(tools.size).to eq(3)
    end

    it 'refreshes cache when cache: false' do
      # First call populates cache
      client.list_tools

      # Second call with cache: false should hit servers again
      expect(server1).to receive(:list_tools).and_return([tool1_from_server1])
      expect(server2).to receive(:list_tools).and_return([tool2_from_server2])

      tools = client.list_tools(cache: false)
      expect(tools.size).to eq(2)
    end
  end

  describe 'prompt caching with same-named prompts from different servers' do
    let(:server1) { instance_double(MCPClient::ServerStdio, name: 'server1') }
    let(:server2) { instance_double(MCPClient::ServerStdio, name: 'server2') }

    let(:prompt1_from_server1) do
      MCPClient::Prompt.new(
        name: 'duplicate_prompt',
        description: 'Prompt from server 1',
        arguments: {},
        server: server1
      )
    end

    let(:prompt2_from_server2) do
      MCPClient::Prompt.new(
        name: 'duplicate_prompt',
        description: 'Prompt from server 2',
        arguments: {},
        server: server2
      )
    end

    before do
      client.instance_variable_set(:@servers, [server1, server2])
      allow(server1).to receive(:list_prompts).and_return([prompt1_from_server1])
      allow(server2).to receive(:list_prompts).and_return([prompt2_from_server2])
      allow(server1).to receive(:object_id).and_return(123456)
      allow(server2).to receive(:object_id).and_return(789012)
    end

    it 'caches both prompts with same name from different servers' do
      client.list_prompts

      expect(client.prompt_cache.size).to eq(2)
      expect(client.prompt_cache["123456:duplicate_prompt"]).to eq(prompt1_from_server1)
      expect(client.prompt_cache["789012:duplicate_prompt"]).to eq(prompt2_from_server2)
    end

    it 'returns all prompts including duplicates' do
      prompts = client.list_prompts

      expect(prompts.size).to eq(2)
      expect(prompts).to include(prompt1_from_server1)
      expect(prompts).to include(prompt2_from_server2)
    end
  end

  describe 'resource caching with same URIs from different servers' do
    let(:server1) { instance_double(MCPClient::ServerStdio, name: 'server1') }
    let(:server2) { instance_double(MCPClient::ServerStdio, name: 'server2') }

    let(:resource1_from_server1) do
      MCPClient::Resource.new(
        uri: 'file://shared.txt',
        name: 'shared_resource',
        description: 'Resource from server 1',
        server: server1
      )
    end

    let(:resource2_from_server2) do
      MCPClient::Resource.new(
        uri: 'file://shared.txt',
        name: 'shared_resource',
        description: 'Resource from server 2',
        server: server2
      )
    end

    before do
      client.instance_variable_set(:@servers, [server1, server2])
      allow(server1).to receive(:list_resources).and_return([resource1_from_server1])
      allow(server2).to receive(:list_resources).and_return([resource2_from_server2])
      allow(server1).to receive(:object_id).and_return(123456)
      allow(server2).to receive(:object_id).and_return(789012)
    end

    it 'caches both resources with same URI from different servers' do
      client.list_resources

      expect(client.resource_cache.size).to eq(2)
      expect(client.resource_cache["123456:file://shared.txt"]).to eq(resource1_from_server1)
      expect(client.resource_cache["789012:file://shared.txt"]).to eq(resource2_from_server2)
    end

    it 'returns all resources including those with duplicate URIs' do
      resources = client.list_resources

      expect(resources.size).to eq(2)
      expect(resources).to include(resource1_from_server1)
      expect(resources).to include(resource2_from_server2)
    end
  end

  describe 'cache clearing' do
    let(:server1) { instance_double(MCPClient::ServerStdio, name: 'server1') }

    let(:tool) do
      MCPClient::Tool.new(
        name: 'test_tool',
        description: 'Test tool',
        schema: {},
        server: server1
      )
    end

    let(:prompt) do
      MCPClient::Prompt.new(
        name: 'test_prompt',
        description: 'Test prompt',
        arguments: {},
        server: server1
      )
    end

    let(:resource) do
      MCPClient::Resource.new(
        uri: 'file://test.txt',
        name: 'test_resource',
        server: server1
      )
    end

    before do
      client.instance_variable_set(:@servers, [server1])
      allow(server1).to receive(:list_tools).and_return([tool])
      allow(server1).to receive(:list_prompts).and_return([prompt])
      allow(server1).to receive(:list_resources).and_return([resource])
      allow(server1).to receive(:object_id).and_return(123456)
    end

    it 'clears all caches when clear_cache is called' do
      # Populate caches
      client.list_tools
      client.list_prompts
      client.list_resources

      expect(client.tool_cache).not_to be_empty
      expect(client.prompt_cache).not_to be_empty
      expect(client.resource_cache).not_to be_empty

      client.clear_cache

      expect(client.tool_cache).to be_empty
      expect(client.prompt_cache).to be_empty
      expect(client.resource_cache).to be_empty
    end
  end

  describe 'ambiguous name handling' do
    let(:server1) { instance_double(MCPClient::ServerStdio, name: 'server1') }
    let(:server2) { instance_double(MCPClient::ServerStdio, name: 'server2') }

    let(:tool1) do
      MCPClient::Tool.new(
        name: 'shared_tool',
        description: 'Tool from server 1',
        schema: {},
        server: server1
      )
    end

    let(:tool2) do
      MCPClient::Tool.new(
        name: 'shared_tool',
        description: 'Tool from server 2',
        schema: {},
        server: server2
      )
    end

    before do
      # Replace the actual servers with our mocks
      client.instance_variable_set(:@servers, [server1, server2])
      allow(server1).to receive(:list_tools).and_return([tool1])
      allow(server2).to receive(:list_tools).and_return([tool2])
      allow(server1).to receive(:object_id).and_return(123456)
      allow(server2).to receive(:object_id).and_return(789012)
      allow(server1).to receive(:call_tool).with('shared_tool', {}).and_return('result1')
      allow(server2).to receive(:call_tool).with('shared_tool', {}).and_return('result2')
    end

    it 'raises AmbiguousToolName error when tool name is ambiguous without server specification' do
      client.list_tools # Populate cache

      expect {
        client.call_tool('shared_tool', {})
      }.to raise_error(MCPClient::Errors::AmbiguousToolName, /Multiple tools named 'shared_tool' found/)
    end

    it 'calls correct tool when server is specified by name' do
      client.list_tools # Populate cache

      result = client.call_tool('shared_tool', {}, server: 'server1')
      expect(result).to eq('result1')

      result = client.call_tool('shared_tool', {}, server: 'server2')
      expect(result).to eq('result2')
    end
  end
end