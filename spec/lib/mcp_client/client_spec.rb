# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::Client do
  let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }
  let(:mock_tool) do
    MCPClient::Tool.new(
      name: 'test_tool',
      description: 'A test tool',
      schema: { 'type' => 'object', 'properties' => { 'param' => { 'type' => 'string' } } },
      server: mock_server
    )
  end
  let(:mock_prompt) do
    MCPClient::Prompt.new(
      name: 'test_prompt',
      description: 'A test prompt',
      arguments: { 'name' => { 'type' => 'string', 'description' => 'Name to greet' } },
      server: mock_server
    )
  end
  let(:mock_resource) do
    MCPClient::Resource.new(
      uri: 'file:///example.txt',
      name: 'example.txt',
      title: 'Example File',
      description: 'A test file',
      server: mock_server
    )
  end

  before do
    allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
    allow(mock_server).to receive(:on_notification).and_yield('test_event', {})
  end

  describe '#initialize' do
    it 'creates servers from configs' do
      client = described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }])
      expect(client.servers).to contain_exactly(mock_server)
    end

    it 'initializes an empty tool cache' do
      client = described_class.new
      expect(client.tool_cache).to be_empty
    end

    it 'initializes an empty prompt cache' do
      client = described_class.new
      expect(client.prompt_cache).to be_empty
    end

    it 'initializes an empty resource cache' do
      client = described_class.new
      expect(client.resource_cache).to be_empty
    end

    it 'passes logger to ServerFactory' do
      custom_logger = Logger.new(StringIO.new)
      expect(MCPClient::ServerFactory).to receive(:create).with(
        { type: 'stdio', command: 'test' },
        logger: custom_logger
      )

      described_class.new(
        mcp_server_configs: [{ type: 'stdio', command: 'test' }],
        logger: custom_logger
      )
    end
  end

  describe '#list_tools' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool])
    end

    it 'returns tools from all servers' do
      tools = client.list_tools
      expect(tools).to contain_exactly(mock_tool)
    end

    it 'caches tools after first call' do
      client.list_tools
      expect(mock_server).to have_received(:list_tools).once
      client.list_tools
      expect(mock_server).to have_received(:list_tools).once
    end

    it 'refreshes tools when cache is disabled' do
      client.list_tools
      client.list_tools(cache: false)
      expect(mock_server).to have_received(:list_tools).twice
    end
  end

  describe '#list_prompts' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_prompts).and_return([mock_prompt])
    end

    it 'returns prompts from all servers' do
      prompts = client.list_prompts
      expect(prompts).to contain_exactly(mock_prompt)
    end

    it 'caches prompts after first call' do
      client.list_prompts
      expect(mock_server).to have_received(:list_prompts).once
      client.list_prompts
      expect(mock_server).to have_received(:list_prompts).once
    end

    it 'refreshes prompts when cache is disabled' do
      client.list_prompts
      client.list_prompts(cache: false)
      expect(mock_server).to have_received(:list_prompts).twice
    end
  end

  describe '#get_prompt' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:prompt_params) { { name: 'John' } }
    let(:prompt_result) { { 'result' => 'Hello John!' } }

    before do
      allow(mock_server).to receive_messages(list_prompts: [mock_prompt], get_prompt: prompt_result)
    end

    it 'gets the prompt with parameters' do
      result = client.get_prompt('test_prompt', prompt_params)
      expect(mock_server).to have_received(:get_prompt).with('test_prompt', prompt_params)
      expect(result).to eq(prompt_result)
    end

    it "raises PromptNotFound if prompt doesn't exist" do
      expect { client.get_prompt('nonexistent_prompt', {}) }.to raise_error(MCPClient::Errors::PromptNotFound)
    end

    it 'handles disconnected server errors' do
      # Prepare a prompt and server
      test_prompt = mock_prompt
      test_server = mock_server
      client.instance_variable_set(:@prompt_cache, { test_prompt.name => test_prompt })

      # Simulate connection error when getting prompt
      connection_error = MCPClient::Errors::ConnectionError.new('Server connection lost: Connection refused')
      allow(test_server).to receive(:get_prompt).and_raise(connection_error)

      # Should wrap ConnectionError in a PromptGetError with context
      expect do
        client.get_prompt(test_prompt.name, {})
      end.to raise_error(
        MCPClient::Errors::PromptGetError,
        /Error getting prompt .* Server connection lost: Connection refused/
      )
    end

    context 'with server disambiguation' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase, name: 'server2') }
      let(:duplicate_prompt) do
        MCPClient::Prompt.new(
          name: 'test_prompt',
          description: 'Same-named prompt on server2',
          server: mock_server2
        )
      end
      let(:server2_result) { { 'result' => 'from_server2' } }
      let(:multi_client) do
        client = described_class.new(mcp_server_configs: [
                                       { type: 'stdio', command: 'test1' },
                                       { type: 'stdio', command: 'test2' }
                                     ])
        client.instance_variable_set(:@servers, [mock_server, mock_server2])
        client
      end

      before do
        allow(mock_server2).to receive_messages(list_prompts: [duplicate_prompt], get_prompt: server2_result,
                                                on_notification: nil)
        allow(multi_client).to receive(:list_prompts).and_return([mock_prompt, duplicate_prompt])
      end

      it 'raises AmbiguousPromptName when duplicate prompts exist' do
        expect { multi_client.get_prompt('test_prompt', {}) }.to raise_error(MCPClient::Errors::AmbiguousPromptName)
      end

      it 'calls the prompt on the specified server by name' do
        result = multi_client.get_prompt('test_prompt', {}, server: 'server2')
        expect(mock_server2).to have_received(:get_prompt).with('test_prompt', {})
        expect(result).to eq(server2_result)
      end

      it 'calls the prompt on the specified server instance' do
        result = multi_client.get_prompt('test_prompt', {}, server: mock_server2)
        expect(mock_server2).to have_received(:get_prompt).with('test_prompt', {})
        expect(result).to eq(server2_result)
      end
    end
  end

  describe '#list_resources' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_resources).and_return({ 'resources' => [mock_resource], 'nextCursor' => nil })
    end

    it 'returns resources from all servers in hash format' do
      result = client.list_resources
      expect(result['resources']).to contain_exactly(mock_resource)
      expect(result['nextCursor']).to be_nil
    end

    it 'caches resources after first call' do
      client.list_resources
      expect(mock_server).to have_received(:list_resources).once
      client.list_resources
      expect(mock_server).to have_received(:list_resources).once
    end

    it 'refreshes resources when cache is disabled' do
      client.list_resources
      client.list_resources(cache: false)
      expect(mock_server).to have_received(:list_resources).twice
    end
  end

  describe '#read_resource' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:resource_uri) { 'file:///example.txt' }
    let(:resource_result) { { 'contents' => [{ 'uri' => resource_uri, 'text' => 'Hello World!' }] } }

    before do
      allow(mock_server).to receive_messages(
        list_resources: { 'resources' => [mock_resource], 'nextCursor' => nil },
        read_resource: resource_result
      )
    end

    it 'reads the resource by URI' do
      result = client.read_resource(resource_uri)
      expect(mock_server).to have_received(:read_resource).with(resource_uri)
      expect(result).to eq(resource_result)
    end

    it "raises ResourceNotFound if resource doesn't exist" do
      expect { client.read_resource('file:///nonexistent.txt') }.to raise_error(MCPClient::Errors::ResourceNotFound)
    end

    it 'handles disconnected server errors' do
      # Prepare a resource and server
      test_resource = mock_resource
      test_server = mock_server
      client.instance_variable_set(:@resource_cache, { test_resource.uri => test_resource })

      # Simulate connection error when reading resource
      connection_error = MCPClient::Errors::ConnectionError.new('Server connection lost: Connection refused')
      allow(test_server).to receive(:read_resource).and_raise(connection_error)

      # Should wrap ConnectionError in a ResourceReadError with context
      expect do
        client.read_resource(test_resource.uri)
      end.to raise_error(
        MCPClient::Errors::ResourceReadError,
        /Error reading resource .* Server connection lost: Connection refused/
      )
    end

    context 'with server disambiguation' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase, name: 'server2') }
      let(:duplicate_resource) do
        MCPClient::Resource.new(
          uri: 'file:///example.txt',
          name: 'example.txt',
          title: 'Same-named resource on server2',
          server: mock_server2
        )
      end
      let(:server2_result) { { 'contents' => [{ 'uri' => resource_uri, 'text' => 'From server 2!' }] } }
      let(:multi_client) do
        client = described_class.new(mcp_server_configs: [
                                       { type: 'stdio', command: 'test1' },
                                       { type: 'stdio', command: 'test2' }
                                     ])
        client.instance_variable_set(:@servers, [mock_server, mock_server2])
        client
      end

      before do
        allow(mock_server2).to receive_messages(
          list_resources: { 'resources' => [duplicate_resource], 'nextCursor' => nil },
          read_resource: server2_result,
          on_notification: nil
        )
        allow(multi_client).to receive(:list_resources).and_return({
                                                                     'resources' => [mock_resource,
                                                                                     duplicate_resource],
                                                                     'nextCursor' => nil
                                                                   })
      end

      it 'raises AmbiguousResourceURI when duplicate resources exist' do
        expect { multi_client.read_resource(resource_uri) }.to raise_error(MCPClient::Errors::AmbiguousResourceURI)
      end

      it 'reads the resource from the specified server by name' do
        result = multi_client.read_resource(resource_uri, server: 'server2')
        expect(mock_server2).to have_received(:read_resource).with(resource_uri)
        expect(result).to eq(server2_result)
      end

      it 'reads the resource from the specified server instance' do
        result = multi_client.read_resource(resource_uri, server: mock_server2)
        expect(mock_server2).to have_received(:read_resource).with(resource_uri)
        expect(result).to eq(server2_result)
      end
    end
  end

  describe '#call_tool' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:tool_params) { { param: 'value' } }
    let(:tool_result) { { 'result' => 'success' } }

    before do
      allow(mock_server).to receive_messages(list_tools: [mock_tool], call_tool: tool_result)
    end

    it 'calls the tool with parameters' do
      result = client.call_tool('test_tool', tool_params)
      expect(mock_server).to have_received(:call_tool).with('test_tool', tool_params)
      expect(result).to eq(tool_result)
    end

    it "raises ToolNotFound if tool doesn't exist" do
      expect { client.call_tool('nonexistent_tool', {}) }.to raise_error(MCPClient::Errors::ToolNotFound)
    end

    it 'handles disconnected server errors' do
      # Prepare a tool and server
      test_tool = mock_tool
      test_server = mock_server
      client.instance_variable_set(:@tool_cache, { test_tool.name => test_tool })

      # Simulate connection error when calling tool
      connection_error = MCPClient::Errors::ConnectionError.new('Server connection lost: Connection refused')
      allow(test_server).to receive(:call_tool).and_raise(connection_error)

      # Should wrap ConnectionError in a ToolCallError with context
      expect do
        client.call_tool(test_tool.name, {})
      end.to raise_error(
        MCPClient::Errors::ToolCallError,
        /Error calling tool .* Server connection lost: Connection refused \(Server: .*\)/
      )
    end

    context 'with server disambiguation' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase, name: 'server2') }
      let(:duplicate_tool) do
        MCPClient::Tool.new(
          name: 'test_tool',
          description: 'Same-named tool on server2',
          schema: { 'type' => 'object', 'properties' => {} },
          server: mock_server2
        )
      end
      let(:server2_result) { { 'result' => 'from_server2' } }
      let(:multi_client) do
        client = described_class.new(mcp_server_configs: [
                                       { type: 'stdio', command: 'test1' },
                                       { type: 'stdio', command: 'test2' }
                                     ])
        client.instance_variable_set(:@servers, [mock_server, mock_server2])
        client
      end

      before do
        allow(mock_server2).to receive_messages(list_tools: [duplicate_tool], call_tool: server2_result,
                                                on_notification: nil)
        allow(multi_client).to receive(:list_tools).and_return([mock_tool, duplicate_tool])
      end

      it 'raises AmbiguousToolName when duplicate tools exist' do
        expect { multi_client.call_tool('test_tool', {}) }.to raise_error(MCPClient::Errors::AmbiguousToolName)
      end

      it 'calls the tool on the specified server by name' do
        result = multi_client.call_tool('test_tool', {}, server: 'server2')
        expect(mock_server2).to have_received(:call_tool).with('test_tool', {})
        expect(result).to eq(server2_result)
      end

      it 'calls the tool on the specified server instance' do
        result = multi_client.call_tool('test_tool', {}, server: mock_server2)
        expect(mock_server2).to have_received(:call_tool).with('test_tool', {})
        expect(result).to eq(server2_result)
      end
    end
  end

  describe '#call_tools' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:tool_params1) { { param: 'value1' } }
    let(:tool_params2) { { param: 'value2' } }
    let(:tool_result) { { 'result' => 'success' } }
    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool])
      allow(mock_server).to receive(:call_tool).and_return(tool_result)
    end

    it 'calls each tool and returns an array of results' do
      calls = [
        { name: 'test_tool', parameters: tool_params1 },
        { name: 'test_tool', parameters: tool_params2 }
      ]
      results = client.call_tools(calls)
      expect(mock_server).to have_received(:call_tool).twice
      expect(results).to eq([tool_result, tool_result])
    end
  end

  describe '#to_openai_tools' do
    let(:other_tool) do
      MCPClient::Tool.new(
        name: 'other_tool',
        description: 'Another test tool',
        schema: { 'type' => 'object', 'properties' => {} }
      )
    end
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool, other_tool])
    end

    it 'converts tools to OpenAI function specs' do
      openai_tools = client.to_openai_tools
      expect(openai_tools.size).to eq(2)
      # Function object format
      expect(openai_tools.first[:type]).to eq('function')
      expect(openai_tools.first[:function][:name]).to eq('test_tool')
      expect(openai_tools.first[:function][:parameters]).to eq(mock_tool.schema)
    end

    it 'filters tools by name when tool_names are provided' do
      openai_tools = client.to_openai_tools(tool_names: ['other_tool'])
      expect(openai_tools.size).to eq(1)
      expect(openai_tools.first[:function][:name]).to eq('other_tool')
    end

    it 'returns empty array when no tools match the filter' do
      openai_tools = client.to_openai_tools(tool_names: ['nonexistent_tool'])
      expect(openai_tools).to be_empty
    end
  end

  describe '#to_anthropic_tools' do
    let(:other_tool) do
      MCPClient::Tool.new(
        name: 'other_tool',
        description: 'Another test tool',
        schema: { 'type' => 'object', 'properties' => {} }
      )
    end
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool, other_tool])
    end

    it 'converts tools to Anthropic tool specs' do
      anthropic_tools = client.to_anthropic_tools
      expect(anthropic_tools.size).to eq(2)
      expect(anthropic_tools.first[:name]).to eq('test_tool')
      expect(anthropic_tools.first[:input_schema]).to eq(mock_tool.schema)
    end

    it 'filters tools by name when tool_names are provided' do
      anthropic_tools = client.to_anthropic_tools(tool_names: ['other_tool'])
      expect(anthropic_tools.size).to eq(1)
      expect(anthropic_tools.first[:name]).to eq('other_tool')
    end

    it 'returns empty array when no tools match the filter' do
      anthropic_tools = client.to_anthropic_tools(tool_names: ['nonexistent_tool'])
      expect(anthropic_tools).to be_empty
    end
  end

  describe '#to_google_tools' do
    let(:other_tool) do
      MCPClient::Tool.new(
        name: 'other_tool',
        description: 'Another test tool',
        schema: { 'type' => 'object', 'properties' => {} }
      )
    end
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool, other_tool])
    end

    it 'converts tools to Google tool specs' do
      google_tools = client.to_google_tools
      expect(google_tools.size).to eq(2)
      expect(google_tools.first[:name]).to eq('test_tool')
      expect(google_tools.first[:parameters]).to eq(mock_tool.schema)
    end

    it 'filters tools by name when tool_names are provided' do
      google_tools = client.to_google_tools(tool_names: ['other_tool'])
      expect(google_tools.size).to eq(1)
      expect(google_tools.first[:name]).to eq('other_tool')
    end

    it 'returns empty array when no tools match the filter' do
      google_tools = client.to_google_tools(tool_names: ['nonexistent_tool'])
      expect(google_tools).to be_empty
    end
  end

  describe '#cleanup' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:cleanup)
    end

    it 'cleans up all servers' do
      client.cleanup
      expect(mock_server).to have_received(:cleanup)
    end
  end

  describe '#clear_cache' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool])
      allow(mock_server).to receive(:list_prompts).and_return([mock_prompt])
      allow(mock_server).to receive(:list_resources).and_return({ 'resources' => [mock_resource], 'nextCursor' => nil })
    end

    it 'clears the cache and refetches tools on next call' do
      client.list_tools
      client.clear_cache
      client.list_tools
      expect(mock_server).to have_received(:list_tools).twice
    end

    it 'clears the cache and refetches prompts on next call' do
      client.list_prompts
      client.clear_cache
      client.list_prompts
      expect(mock_server).to have_received(:list_prompts).twice
    end

    it 'clears the cache and refetches resources on next call' do
      client.list_resources
      client.clear_cache
      client.list_resources
      expect(mock_server).to have_received(:list_resources).twice
    end
  end

  describe 'convenience methods: #find_tools, #find_tool, and #find_server' do
    let(:other_tool) do
      MCPClient::Tool.new(
        name: 'another_tool',
        description: 'Another test tool',
        schema: { 'type' => 'object', 'properties' => {} },
        server: mock_server
      )
    end
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    before do
      allow(mock_server).to receive(:list_tools).and_return([mock_tool, other_tool])
    end

    it 'returns tools matching a string pattern' do
      matches = client.find_tools('test')
      expect(matches).to contain_exactly(mock_tool)
    end

    it 'returns tools matching a Regexp pattern' do
      matches = client.find_tools(/another_/)
      expect(matches).to contain_exactly(other_tool)
    end

    it 'find_tool returns the first matching tool' do
      tool = client.find_tool(/another_/)
      expect(tool).to eq(other_tool)
    end

    it 'find_server returns a server by name' do
      server = client.find_server('server1')
      expect(server).to eq(mock_server)
    end

    it 'find_server returns nil if server not found' do
      server = client.find_server('nonexistent')
      expect(server).to be_nil
    end
  end

  describe '#call_tool validation' do
    let(:schema_tool) do
      MCPClient::Tool.new(
        name: 'schema_tool',
        description: 'Tool with required params',
        schema: {
          'type' => 'object',
          'properties' => { 'a' => { 'type' => 'string' }, 'b' => { 'type' => 'string' } },
          'required' => %w[a b]
        },
        server: mock_server
      )
    end
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_tools).and_return([schema_tool])
      allow(mock_server).to receive(:call_tool)
    end

    it 'raises ValidationError when required parameters are missing' do
      expect do
        client.call_tool('schema_tool', { 'a' => 'foo' })
      end.to raise_error(MCPClient::Errors::ValidationError, /Missing required parameters: b/)
    end

    it 'calls tool when all required parameters are provided' do
      params = { 'a' => 'foo', 'b' => 'bar' }
      client.call_tool('schema_tool', params)
      expect(mock_server).to have_received(:call_tool).with('schema_tool', params)
    end

    it 'skips validation for required parameters that have a default value' do
      tool_with_default = MCPClient::Tool.new(
        name: 'default_tool',
        description: 'Tool with required param having default',
        schema: {
          'type' => 'object',
          'properties' => {
            'format' => { 'type' => 'string', 'enum' => %w[png jpeg], 'default' => 'png' },
            'url' => { 'type' => 'string' }
          },
          'required' => %w[format url]
        },
        server: mock_server
      )
      allow(mock_server).to receive(:list_tools).and_return([tool_with_default])

      # Only 'url' provided, 'format' has a default so should not raise
      params = { 'url' => 'https://example.com' }
      client.call_tool('default_tool', params)
      expect(mock_server).to have_received(:call_tool).with('default_tool', params)
    end
  end

  describe '#call_tool_streaming' do
    let(:stream_tool) do
      MCPClient::Tool.new(
        name: 'test_tool',
        description: 'A test tool',
        schema: {},
        server: mock_server
      )
    end
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:list_tools).and_return([stream_tool])
    end

    context 'when server does not support streaming' do
      before do
        allow(mock_server).to receive(:call_tool).and_return('single_result')
        allow(mock_server).to receive(:call_tool_streaming).and_return(Enumerator.new { |y| y << 'single_result' })
      end

      it 'returns an Enumerator yielding the single result' do
        enum = client.call_tool_streaming('test_tool', {})
        expect(enum).to be_an(Enumerator)
        expect(enum.to_a).to eq(['single_result'])
      end
    end

    context 'when server supports streaming' do
      let(:stream_enum) { Enumerator.new { |y| [1, 2, 3].each { |i| y << i } } }

      before do
        # Create a new client with a different mock server that supports streaming
        allow(mock_server).to receive(:call_tool_streaming).and_return(stream_enum)
      end

      it 'delegates to server.call_tool_streaming' do
        enum = client.call_tool_streaming('test_tool', {})
        expect(enum).to be_an(Enumerator)
        # We can't directly compare the enumerators, but we can compare their outputs
        expect(enum.to_a).to eq([1, 2, 3])
        # Verify the mock was called
        expect(mock_server).to have_received(:call_tool_streaming).with('test_tool', {})
      end
    end

    context 'with server disambiguation' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase, name: 'server2') }
      let(:duplicate_tool) do
        MCPClient::Tool.new(
          name: 'test_tool',
          description: 'Same-named tool on server2',
          schema: {},
          server: mock_server2
        )
      end
      let(:server2_stream) { Enumerator.new { |y| [4, 5, 6].each { |i| y << i } } }
      let(:multi_client) do
        client = described_class.new(mcp_server_configs: [
                                       { type: 'stdio', command: 'test1' },
                                       { type: 'stdio', command: 'test2' }
                                     ])
        client.instance_variable_set(:@servers, [mock_server, mock_server2])
        client
      end

      before do
        # Make sure mock_server responds to call_tool_streaming
        allow(mock_server).to receive(:call_tool_streaming).and_return(Enumerator.new { |y|
          [1, 2, 3].each do |i|
            y << i
          end
        })
        allow(mock_server).to receive(:respond_to?).with(:call_tool_streaming).and_return(true)
        allow(mock_server).to receive(:respond_to?).with(:on_elicitation_request).and_return(false)
        allow(mock_server).to receive(:respond_to?).with(:on_roots_list_request).and_return(false)
        allow(mock_server).to receive(:respond_to?).with(:on_sampling_request).and_return(false)

        # Setup mock_server2
        allow(mock_server2).to receive(:call_tool_streaming).and_return(server2_stream)
        allow(mock_server2).to receive(:respond_to?).with(:call_tool_streaming).and_return(true)
        allow(mock_server2).to receive(:respond_to?).with(:on_elicitation_request).and_return(false)
        allow(mock_server2).to receive(:respond_to?).with(:on_roots_list_request).and_return(false)
        allow(mock_server2).to receive(:respond_to?).with(:on_sampling_request).and_return(false)
        allow(mock_server2).to receive_messages(list_tools: [duplicate_tool], on_notification: nil)

        # Setup multi_client
        allow(multi_client).to receive(:list_tools).and_return([stream_tool, duplicate_tool])
      end

      it 'raises AmbiguousToolName when duplicate tools exist' do
        expect do
          multi_client.call_tool_streaming('test_tool', {})
        end.to raise_error(MCPClient::Errors::AmbiguousToolName)
      end

      it 'streams from the specified server by name' do
        enum = multi_client.call_tool_streaming('test_tool', {}, server: 'server2')
        expect(mock_server2).to have_received(:call_tool_streaming).with('test_tool', {})
        expect(enum).to eq(server2_stream)
      end
    end
  end

  describe '#ping' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:ping_result) { { 'status' => 'ok' } }

    before do
      allow(mock_server).to receive(:ping).and_return(ping_result)
    end

    it 'pings the first server by default' do
      result = client.ping
      expect(mock_server).to have_received(:ping)
      expect(result).to eq(ping_result)
    end

    it 'pings a specific server when server_index is provided' do
      client.ping(server_index: 0)
      expect(mock_server).to have_received(:ping)
    end

    it 'raises ServerNotFound when no servers are available' do
      empty_client = described_class.new(mcp_server_configs: [])
      expect { empty_client.ping }.to raise_error(MCPClient::Errors::ServerNotFound, 'No server available for ping')
    end

    it 'raises ServerNotFound when invalid server_index is provided' do
      expect do
        client.ping(server_index: 1)
      end.to raise_error(MCPClient::Errors::ServerNotFound, 'Server at index 1 not found')
    end

    context 'with multiple servers' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase) }
      let(:multi_client) do
        client = described_class.new(mcp_server_configs: [
                                       { type: 'stdio', command: 'test1' },
                                       { type: 'stdio', command: 'test2' }
                                     ])
        # Replace the servers with our doubles
        client.instance_variable_set(:@servers, [mock_server, mock_server2])
        client
      end

      before do
        allow(mock_server2).to receive(:ping).and_return({ 'status' => 'ok', 'server' => '2' })
        allow(mock_server2).to receive(:on_notification)
      end

      it 'pings the first server by default' do
        multi_client.ping
        expect(mock_server).to have_received(:ping)
        expect(mock_server2).not_to have_received(:ping)
      end

      it 'pings the specified server when server_index is provided' do
        result = multi_client.ping(server_index: 1)
        expect(mock_server).not_to have_received(:ping)
        expect(mock_server2).to have_received(:ping)
        expect(result).to eq({ 'status' => 'ok', 'server' => '2' })
      end
    end
  end

  describe '#send_rpc' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:rpc_result) { { 'result' => 'success' } }

    before do
      allow(mock_server).to receive(:rpc_request).and_return(rpc_result)
    end

    it 'sends RPC request to the first server by default' do
      result = client.send_rpc('test_method', params: { arg: 'value' })
      expect(mock_server).to have_received(:rpc_request).with('test_method', { arg: 'value' })
      expect(result).to eq(rpc_result)
    end

    it 'sends RPC request to specified server by index' do
      client.send_rpc('test_method', params: { arg: 'value' }, server: 0)
      expect(mock_server).to have_received(:rpc_request).with('test_method', { arg: 'value' })
    end

    context 'with multiple servers' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase, name: 'server2') }
      let(:multi_client) do
        client = described_class.new(mcp_server_configs: [
                                       { type: 'stdio', command: 'test1' },
                                       { type: 'stdio', command: 'test2' }
                                     ])
        client.instance_variable_set(:@servers, [mock_server, mock_server2])
        client
      end

      before do
        allow(mock_server2).to receive(:rpc_request).and_return({ 'result' => 'server2' })
        allow(mock_server2).to receive(:on_notification)
      end

      it 'sends RPC to specified server by index' do
        result = multi_client.send_rpc('test_method', params: { arg: 'value' }, server: 1)
        expect(mock_server2).to have_received(:rpc_request).with('test_method', { arg: 'value' })
        expect(result).to eq({ 'result' => 'server2' })
      end

      it 'sends RPC to server by type string' do
        # Need to mock finding server by type
        expect(multi_client).to receive(:select_server).with('stdio').and_return(mock_server2)

        result = multi_client.send_rpc('test_method', params: { arg: 'value' }, server: 'stdio')
        expect(mock_server2).to have_received(:rpc_request).with('test_method', { arg: 'value' })
        expect(result).to eq({ 'result' => 'server2' })
      end

      it 'sends RPC to server by name' do
        result = multi_client.send_rpc('test_method', params: { arg: 'value' }, server: 'server2')
        expect(mock_server2).to have_received(:rpc_request).with('test_method', { arg: 'value' })
        expect(result).to eq({ 'result' => 'server2' })
      end

      it 'sends RPC to server instance directly' do
        result = multi_client.send_rpc('test_method', params: { arg: 'value' }, server: mock_server2)
        expect(mock_server2).to have_received(:rpc_request).with('test_method', { arg: 'value' })
        expect(result).to eq({ 'result' => 'server2' })
      end
    end
  end

  describe '#send_notification' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }

    before do
      allow(mock_server).to receive(:rpc_notify)
    end

    it 'sends notification to the first server by default' do
      client.send_notification('test_event', params: { arg: 'value' })
      expect(mock_server).to have_received(:rpc_notify).with('test_event', { arg: 'value' })
    end

    it 'sends notification to specified server by index' do
      client.send_notification('test_event', params: { arg: 'value' }, server: 0)
      expect(mock_server).to have_received(:rpc_notify).with('test_event', { arg: 'value' })
    end

    context 'with multiple servers' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase) }
      let(:multi_client) do
        client = described_class.new(mcp_server_configs: [
                                       { type: 'stdio', command: 'test1' },
                                       { type: 'stdio', command: 'test2' }
                                     ])
        client.instance_variable_set(:@servers, [mock_server, mock_server2])
        client
      end

      before do
        allow(mock_server2).to receive(:rpc_notify)
        allow(mock_server2).to receive(:on_notification)
      end

      it 'sends notification to specified server by index' do
        multi_client.send_notification('test_event', params: { arg: 'value' }, server: 1)
        expect(mock_server2).to have_received(:rpc_notify).with('test_event', { arg: 'value' })
      end
    end
  end

  describe '#create_task' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:task_result) do
      { 'id' => 'task-123', 'state' => 'pending', 'progressToken' => 'pt-abc' }
    end

    before do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/create', { method: 'longRunningOp', params: { input: 'data' }, progressToken: 'pt-abc' })
        .and_return(task_result)
    end

    it 'creates a task and returns a Task object' do
      task = client.create_task('longRunningOp', params: { input: 'data' }, progress_token: 'pt-abc')
      expect(task).to be_a(MCPClient::Task)
      expect(task.id).to eq('task-123')
      expect(task.state).to eq('pending')
      expect(task.progress_token).to eq('pt-abc')
      expect(task.server).to eq(mock_server)
    end

    it 'creates a task without progress token' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/create', { method: 'simpleOp', params: {} })
        .and_return({ 'id' => 'task-456', 'state' => 'pending' })

      task = client.create_task('simpleOp')
      expect(task.id).to eq('task-456')
      expect(task.progress_token).to be_nil
    end

    it 'raises TaskError on server error' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/create', { method: 'failOp', params: {} })
        .and_raise(MCPClient::Errors::ServerError.new('Internal error'))

      expect do
        client.create_task('failOp')
      end.to raise_error(MCPClient::Errors::TaskError, /Error creating task/)
    end

    it 'raises TaskError on transport error' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/create', { method: 'failOp', params: {} })
        .and_raise(MCPClient::Errors::TransportError.new('Connection lost'))

      expect do
        client.create_task('failOp')
      end.to raise_error(MCPClient::Errors::TaskError, /Error creating task/)
    end

    context 'with server selection' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase, name: 'server2') }
      let(:multi_client) do
        client = described_class.new(mcp_server_configs: [
                                       { type: 'stdio', command: 'test1' },
                                       { type: 'stdio', command: 'test2' }
                                     ])
        client.instance_variable_set(:@servers, [mock_server, mock_server2])
        client
      end

      before do
        allow(mock_server2).to receive(:on_notification)
        allow(mock_server2).to receive(:rpc_request)
          .with('tasks/create', { method: 'op', params: {} })
          .and_return({ 'id' => 'task-s2', 'state' => 'pending' })
      end

      it 'creates a task on a specific server by name' do
        task = multi_client.create_task('op', server: 'server2')
        expect(task.id).to eq('task-s2')
        expect(task.server).to eq(mock_server2)
      end
    end
  end

  describe '#get_task' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:task_result) do
      { 'id' => 'task-123', 'state' => 'running', 'progress' => 50, 'total' => 100, 'message' => 'Halfway' }
    end

    before do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/get', { id: 'task-123' })
        .and_return(task_result)
    end

    it 'gets a task and returns a Task object' do
      task = client.get_task('task-123')
      expect(task).to be_a(MCPClient::Task)
      expect(task.id).to eq('task-123')
      expect(task.state).to eq('running')
      expect(task.progress).to eq(50)
      expect(task.total).to eq(100)
      expect(task.message).to eq('Halfway')
      expect(task.server).to eq(mock_server)
    end

    it 'raises TaskNotFound when task does not exist' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/get', { id: 'nonexistent' })
        .and_raise(MCPClient::Errors::ServerError.new('Task not found'))

      expect do
        client.get_task('nonexistent')
      end.to raise_error(MCPClient::Errors::TaskNotFound, "Task 'nonexistent' not found")
    end

    it 'raises TaskNotFound for unknown task error' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/get', { id: 'bad-id' })
        .and_raise(MCPClient::Errors::ServerError.new('unknown task'))

      expect do
        client.get_task('bad-id')
      end.to raise_error(MCPClient::Errors::TaskNotFound)
    end

    it 'raises TaskError on other server errors' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/get', { id: 'task-err' })
        .and_raise(MCPClient::Errors::ServerError.new('Internal error'))

      expect do
        client.get_task('task-err')
      end.to raise_error(MCPClient::Errors::TaskError, /Error getting task/)
    end

    it 'raises TaskError on transport error' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/get', { id: 'task-err' })
        .and_raise(MCPClient::Errors::TransportError.new('Connection lost'))

      expect do
        client.get_task('task-err')
      end.to raise_error(MCPClient::Errors::TaskError, /Error getting task/)
    end
  end

  describe '#cancel_task' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:cancel_result) do
      { 'id' => 'task-123', 'state' => 'cancelled', 'message' => 'Cancelled by user' }
    end

    before do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/cancel', { id: 'task-123' })
        .and_return(cancel_result)
    end

    it 'cancels a task and returns updated Task object' do
      task = client.cancel_task('task-123')
      expect(task).to be_a(MCPClient::Task)
      expect(task.id).to eq('task-123')
      expect(task.state).to eq('cancelled')
      expect(task.message).to eq('Cancelled by user')
      expect(task.server).to eq(mock_server)
    end

    it 'raises TaskNotFound when task does not exist' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/cancel', { id: 'nonexistent' })
        .and_raise(MCPClient::Errors::ServerError.new('Task not found'))

      expect do
        client.cancel_task('nonexistent')
      end.to raise_error(MCPClient::Errors::TaskNotFound, "Task 'nonexistent' not found")
    end

    it 'raises TaskError on other server errors' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/cancel', { id: 'task-err' })
        .and_raise(MCPClient::Errors::ServerError.new('Cannot cancel completed task'))

      expect do
        client.cancel_task('task-err')
      end.to raise_error(MCPClient::Errors::TaskError, /Error cancelling task/)
    end

    it 'raises TaskError on transport error' do
      allow(mock_server).to receive(:rpc_request)
        .with('tasks/cancel', { id: 'task-err' })
        .and_raise(MCPClient::Errors::TransportError.new('Connection lost'))

      expect do
        client.cancel_task('task-err')
      end.to raise_error(MCPClient::Errors::TaskError, /Error cancelling task/)
    end

    context 'with server selection' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase, name: 'server2') }
      let(:multi_client) do
        client = described_class.new(mcp_server_configs: [
                                       { type: 'stdio', command: 'test1' },
                                       { type: 'stdio', command: 'test2' }
                                     ])
        client.instance_variable_set(:@servers, [mock_server, mock_server2])
        client
      end

      before do
        allow(mock_server2).to receive(:on_notification)
        allow(mock_server2).to receive(:rpc_request)
          .with('tasks/cancel', { id: 'task-s2' })
          .and_return({ 'id' => 'task-s2', 'state' => 'cancelled' })
      end

      it 'cancels a task on a specific server by name' do
        task = multi_client.cancel_task('task-s2', server: 'server2')
        expect(task.id).to eq('task-s2')
        expect(task.state).to eq('cancelled')
        expect(task.server).to eq(mock_server2)
      end
    end
  end

  describe 'notification handling' do
    let(:client) { described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }]) }
    let(:notification_callback) { double('callback') }

    before do
      allow(notification_callback).to receive(:call)
    end

    it 'registers notification listeners' do
      client.on_notification { |server, method, params| notification_callback.call(server, method, params) }

      # Simulate notification
      server = client.servers.first
      client.instance_variable_get(:@notification_listeners).each do |cb|
        cb.call(server, 'test_event', { data: 'test' })
      end

      expect(notification_callback).to have_received(:call).with(server, 'test_event', { data: 'test' })
    end

    it 'handles tools/list_changed notification by clearing cache' do
      # Stub list_tools to populate the cache
      allow(mock_server).to receive(:list_tools).and_return([mock_tool])

      client.list_tools # Fill cache
      expect(client.tool_cache).not_to be_empty

      # Manually trigger process_notification with tools/list_changed
      client.send(:process_notification, client.servers.first, 'notifications/tools/list_changed', {})

      expect(client.tool_cache).to be_empty
    end
  end
end
