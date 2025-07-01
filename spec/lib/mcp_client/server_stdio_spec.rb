# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::ServerStdio do
  let(:command) { 'echo test' }
  let(:server) { described_class.new(command: command) }

  describe '#initialize' do
    it 'sets the command' do
      expect(server.command).to eq('echo test')
    end

    it 'converts array command to string' do
      server = described_class.new(command: %w[echo test])
      expect(server.command).to eq('echo test')
    end
  end

  describe '#connect' do
    it 'starts the command process with Open3' do
      expect(Open3).to receive(:popen3).with(command).and_return([double, double, double, double])
      expect(server.connect).to be true
    end

    it 'passes environment variables when env is provided' do
      env = { 'FOO' => 'bar' }
      server_env = described_class.new(command: command, env: env)
      expect(Open3).to receive(:popen3).with(env, command).and_return([double, double, double, double])
      expect(server_env.connect).to be true
    end

    it 'raises ConnectionError on failure' do
      allow(Open3).to receive(:popen3).and_raise(StandardError.new('Failed to start process'))
      expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /Failed to connect to MCP server/)
    end
  end

  describe '#list_prompts' do
    let(:prompt_data) do
      {
        'name' => 'test_prompt',
        'description' => 'A test prompt'
      }
    end
    let(:response) do
      {
        'jsonrpc' => '2.0',
        'id' => 1,
        'result' => {
          'prompts' => [prompt_data]
        }
      }
    end

    before do
      # Setup mocks for the server connection
      @stdin = StringIO.new
      @stdout = StringIO.new
      @stderr = StringIO.new
      @wait_thread = double('wait_thread', pid: 12_345, alive?: true)

      allow(Open3).to receive(:popen3).and_return([@stdin, @stdout, @wait_thread, @stderr])
      allow(Process).to receive(:kill)

      # Mock the response handling
      allow(server).to receive(:ensure_initialized).and_call_original
      allow(server).to receive(:connect)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:perform_initialize)
      allow(server).to receive(:wait_response).and_return(response)
      allow(server).to receive(:capabilities).and_return('prompts' => { 'listChanged' => true })
    end

    before do
      # Properly initialize the server to avoid nil errors
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@stdin, StringIO.new)
    end

    it 'ensures the server is initialized' do
      expect(server).to receive(:ensure_initialized)
      server.list_prompts
    end

    it 'sends a JSONRPC request' do
      expect(server).to receive(:send_request) do |req|
        expect(req['method']).to eq('prompts/list')
        expect(req['params']).to eq({})
      end
      server.list_prompts
    end

    it 'returns an array of Prompt objects' do
      prompts = server.list_prompts
      expect(prompts).to be_an(Array)
      expect(prompts.length).to eq(1)
      expect(prompts.first).to be_a(MCPClient::Prompt)
      expect(prompts.first.name).to eq('test_prompt')
    end

    it 'raises PromptGetError when server returns an error' do
      error_response = {
        'jsonrpc' => '2.0',
        'id' => 1,
        'error' => {
          'code' => -32_000,
          'message' => 'Server error'
        }
      }
      allow(server).to receive(:wait_response).and_return(error_response)
      expect { server.list_prompts }.to raise_error(MCPClient::Errors::PromptGetError, /Error listing prompts/)
    end

    it 'raises PromptGetError on other errors' do
      allow(server).to receive(:send_request).and_raise(StandardError.new('Communication error'))
      expect { server.list_prompts }.to raise_error(MCPClient::Errors::PromptGetError, /Error listing prompts/)
    end
  end

  describe '#get_prompt' do
    let(:prompt_name) { 'test_prompt' }
    let(:parameters) { { 'message' => 'John' } }
    let(:result) { { 'output' => 'hello John' } }
    let(:response) do
      {
        'jsonrpc' => '2.0',
        'id' => 1,
        'result' => result
      }
    end

    before do
      # Setup mocks for the server connection
      @stdin = StringIO.new
      @stdout = StringIO.new
      @stderr = StringIO.new
      @wait_thread = double('wait_thread', pid: 12_345, alive?: true)

      allow(Open3).to receive(:popen3).and_return([@stdin, @stdout, @wait_thread, @stderr])
      allow(Process).to receive(:kill)

      # Mock the response handling
      allow(server).to receive(:ensure_initialized).and_call_original
      allow(server).to receive(:connect)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:perform_initialize)
      allow(server).to receive(:wait_response).and_return(response)
      allow(server).to receive(:capabilities).and_return('prompts' => { 'listChanged' => true })

      # Properly initialize the server to avoid nil errors
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@stdin, StringIO.new)
    end

    it 'ensures the server is initialized' do
      expect(server).to receive(:ensure_initialized)
      server.get_prompt(prompt_name, parameters)
    end

    it 'sends a JSONRPC request with the prompt name and parameters' do
      expect(server).to receive(:send_request) do |req|
        expect(req['method']).to eq('prompts/get')
        expect(req['params']['name']).to eq(prompt_name)
        expect(req['params']['arguments']).to eq(parameters)
      end
      server.get_prompt(prompt_name, parameters)
    end

    it 'returns the result from the response' do
      response = server.get_prompt(prompt_name, parameters)
      expect(response).to eq(result)
    end

    it 'raises PromptGetError when server returns an error' do
      error_response = {
        'jsonrpc' => '2.0',
        'id' => 1,
        'error' => {
          'code' => -32_000,
          'message' => 'Server error'
        }
      }
      allow(server).to receive(:wait_response).and_return(error_response)
      expect do
        server.get_prompt(prompt_name, parameters)
      end.to raise_error(MCPClient::Errors::PromptGetError, /Error calling prompt/)
    end

    it 'raises PromptGetError on other errors' do
      allow(server).to receive(:send_request).and_raise(StandardError.new('Communication error'))
      expect do
        server.get_prompt(prompt_name, parameters)
      end.to raise_error(MCPClient::Errors::PromptGetError, /Error calling prompt/)
    end
  end

  describe '#list_tools' do
    let(:tool_data) do
      {
        'name' => 'test_tool',
        'description' => 'A test tool',
        'parameters' => {
          'type' => 'object',
          'required' => ['foo'],
          'properties' => {
            'foo' => { 'type' => 'string' }
          }
        }
      }
    end

    let(:response) do
      {
        'jsonrpc' => '2.0',
        'id' => 1,
        'result' => {
          'tools' => [tool_data]
        }
      }
    end

    before do
      # Setup mocks for the server connection
      @stdin = StringIO.new
      @stdout = StringIO.new
      @stderr = StringIO.new
      @wait_thread = double('wait_thread', pid: 12_345, alive?: true)

      allow(Open3).to receive(:popen3).and_return([@stdin, @stdout, @wait_thread, @stderr])
      allow(Process).to receive(:kill)

      # Mock the response handling
      allow(server).to receive(:ensure_initialized).and_call_original
      allow(server).to receive(:connect)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:perform_initialize)
      allow(server).to receive(:wait_response).and_return(response)
      allow(server).to receive(:capabilities).and_return('tools' => { 'listChanged' => true })
    end

    before do
      # Properly initialize the server to avoid nil errors
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@stdin, StringIO.new)
    end

    it 'ensures the server is initialized' do
      expect(server).to receive(:ensure_initialized)
      server.list_tools
    end

    it 'sends a JSONRPC request' do
      expect(server).to receive(:send_request) do |req|
        expect(req['method']).to eq('tools/list')
        expect(req['params']).to eq({})
      end
      server.list_tools
    end

    it 'returns an array of Tool objects' do
      tools = server.list_tools
      expect(tools).to be_an(Array)
      expect(tools.length).to eq(1)
      expect(tools.first).to be_a(MCPClient::Tool)
      expect(tools.first.name).to eq('test_tool')
    end

    it 'raises ToolCallError when server returns an error' do
      error_response = {
        'jsonrpc' => '2.0',
        'id' => 1,
        'error' => {
          'code' => -32_000,
          'message' => 'Server error'
        }
      }
      allow(server).to receive(:wait_response).and_return(error_response)
      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /Error listing tools/)
    end

    it 'raises ToolCallError on other errors' do
      allow(server).to receive(:send_request).and_raise(StandardError.new('Communication error'))
      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /Error listing tools/)
    end
  end

  describe '#call_tool' do
    let(:tool_name) { 'test_tool' }
    let(:parameters) { { 'foo' => 'bar' } }
    let(:result) { { 'output' => 'success' } }
    let(:response) do
      {
        'jsonrpc' => '2.0',
        'id' => 1,
        'result' => result
      }
    end

    before do
      # Setup mocks for the server connection
      @stdin = StringIO.new
      @stdout = StringIO.new
      @stderr = StringIO.new
      @wait_thread = double('wait_thread', pid: 12_345, alive?: true)

      allow(Open3).to receive(:popen3).and_return([@stdin, @stdout, @wait_thread, @stderr])
      allow(Process).to receive(:kill)

      # Mock the response handling
      allow(server).to receive(:ensure_initialized).and_call_original
      allow(server).to receive(:connect)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:perform_initialize)
      allow(server).to receive(:wait_response).and_return(response)
      allow(server).to receive(:capabilities).and_return('tools' => { 'listChanged' => true })

      # Properly initialize the server to avoid nil errors
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@stdin, StringIO.new)
    end

    it 'ensures the server is initialized' do
      expect(server).to receive(:ensure_initialized)
      server.call_tool(tool_name, parameters)
    end

    it 'sends a JSONRPC request with the tool name and parameters' do
      expect(server).to receive(:send_request) do |req|
        expect(req['method']).to eq('tools/call')
        expect(req['params']['name']).to eq(tool_name)
        expect(req['params']['arguments']).to eq(parameters)
      end
      server.call_tool(tool_name, parameters)
    end

    it 'returns the result from the response' do
      response = server.call_tool(tool_name, parameters)
      expect(response).to eq(result)
    end

    it 'raises ToolCallError when server returns an error' do
      error_response = {
        'jsonrpc' => '2.0',
        'id' => 1,
        'error' => {
          'code' => -32_000,
          'message' => 'Server error'
        }
      }
      allow(server).to receive(:wait_response).and_return(error_response)
      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCPClient::Errors::ToolCallError, /Error calling tool/)
    end

    it 'raises ToolCallError on other errors' do
      allow(server).to receive(:send_request).and_raise(StandardError.new('Communication error'))
      expect do
        server.call_tool(tool_name, parameters)
      end.to raise_error(MCPClient::Errors::ToolCallError, /Error calling tool/)
    end
  end

  describe '#cleanup' do
    before do
      @stdin = double('stdin', close: nil, closed?: false)
      @stdout = double('stdout', close: nil, closed?: false)
      @stderr = double('stderr', close: nil, closed?: false)
      @wait_thread = double('wait_thread', pid: 12_345, alive?: true, join: nil)
      @reader_thread = double('reader_thread', kill: nil)

      allow(Open3).to receive(:popen3).and_return([@stdin, @stdout, @stderr, @wait_thread])
      allow(Process).to receive(:kill)

      server.instance_variable_set(:@stdin, @stdin)
      server.instance_variable_set(:@stdout, @stdout)
      server.instance_variable_set(:@stderr, @stderr)
      server.instance_variable_set(:@wait_thread, @wait_thread)
      server.instance_variable_set(:@reader_thread, @reader_thread)
    end

    it 'closes the streams' do
      expect(@stdin).to receive(:close)
      expect(@stdout).to receive(:close)
      expect(@stderr).to receive(:close)
      server.cleanup
    end

    it 'kills the process' do
      expect(Process).to receive(:kill).with('TERM', @wait_thread.pid)
      expect(@wait_thread).to receive(:join).with(1)
      server.cleanup
    end

    it 'kills the reader thread' do
      expect(@reader_thread).to receive(:kill)
      server.cleanup
    end

    it 'handles already closed streams' do
      allow(@stdin).to receive(:closed?).and_return(true)
      expect(@stdin).not_to receive(:close)
      server.cleanup
    end

    it 'resets all connection variables' do
      server.cleanup
      expect(server.instance_variable_get(:@stdin)).to be_nil
      expect(server.instance_variable_get(:@stdout)).to be_nil
      expect(server.instance_variable_get(:@stderr)).to be_nil
      expect(server.instance_variable_get(:@wait_thread)).to be_nil
      expect(server.instance_variable_get(:@reader_thread)).to be_nil
    end
  end

  describe '#ping' do
    it 'delegates to rpc_request and returns the result' do
      allow(server).to receive(:rpc_request).with('ping').and_return({})
      expect(server.ping).to eq({})
    end
  end

  describe 'private methods' do
    describe '#next_id' do
      it 'generates sequential IDs' do
        id1 = server.send(:next_id)
        id2 = server.send(:next_id)
        expect(id2).to eq(id1 + 1)
      end
    end

    describe '#send_request' do
      before do
        @stdin = StringIO.new
        allow(Open3).to receive(:popen3).and_return([@stdin, StringIO.new, StringIO.new, double])
        server.connect
      end

      it 'sends a JSON-encoded request to stdin' do
        req = { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'test' }
        server.send(:send_request, req)
        @stdin.rewind
        expect(JSON.parse(@stdin.read.strip)).to eq(req)
      end

      it 'raises TransportError on error' do
        allow(@stdin).to receive(:puts).and_raise(IOError.new('Stream closed'))
        expect do
          server.send(:send_request, {})
        end.to raise_error(MCPClient::Errors::TransportError, /Failed to send JSONRPC request/)
      end
    end

    describe '#wait_response' do
      it 'returns the pending response for the given ID' do
        server.instance_variable_set(:@pending, { 1 => { 'result' => 'success' } })
        response = server.send(:wait_response, 1)
        expect(response).to eq({ 'result' => 'success' })
      end

      it 'raises TransportError on timeout' do
        server.instance_variable_set(:@pending, {})
        # Set a very short timeout for the test
        stub_const('MCPClient::ServerStdio::READ_TIMEOUT', 0.1)
        expect { server.send(:wait_response, 1) }.to raise_error(MCPClient::Errors::TransportError, /Timeout waiting/)
      end
    end

    describe '#handle_line' do
      it 'parses JSON and stores response by ID' do
        response = { 'jsonrpc' => '2.0', 'id' => 1, 'result' => 'success' }
        server.send(:handle_line, response.to_json)
        expect(server.instance_variable_get(:@pending)[1]).to eq(response)
      end

      it 'ignores responses without an ID' do
        response = { 'jsonrpc' => '2.0', 'method' => 'notification' }
        server.send(:handle_line, response.to_json)
        expect(server.instance_variable_get(:@pending)).not_to include(response)
      end

      it 'ignores non-JSON lines' do
        expect { server.send(:handle_line, 'not json') }.not_to raise_error
      end
    end
  end
end
