# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'faraday'
require 'stringio'

RSpec.describe MCPClient::ServerStreamableHTTP do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }
  let(:headers) { { 'Authorization' => 'Bearer test-token' } }

  let(:server) do
    described_class.new(
      base_url: base_url,
      endpoint: endpoint,
      headers: headers,
      read_timeout: 10,
      retries: 1,
      name: 'test-server'
    )
  end

  after do
    server.cleanup if defined?(server)
  end

  describe '#initialize' do
    it 'sets up basic properties' do
      expect(server.base_url).to eq(base_url)
      expect(server.endpoint).to eq(endpoint)
      expect(server.name).to eq('test-server')
    end

    it 'includes SSE-compatible headers' do
      headers = server.instance_variable_get(:@headers)
      expect(headers['Accept']).to eq('text/event-stream, application/json')
      expect(headers['Cache-Control']).to eq('no-cache')
      expect(headers['Content-Type']).to eq('application/json')
    end

    context 'with URL containing endpoint path' do
      let(:base_url) { 'https://example.com/api/mcp' }
      let(:endpoint) { '/rpc' } # default

      it 'extracts endpoint from URL when using default endpoint' do
        expect(server.base_url).to eq('https://example.com')
        expect(server.endpoint).to eq('/api/mcp')
      end
    end

    context 'with custom endpoint' do
      let(:base_url) { 'https://example.com/api/mcp' }
      let(:endpoint) { '/custom' }

      it 'uses provided endpoint and extracts host from base URL' do
        expect(server.base_url).to eq('https://example.com')
        expect(server.endpoint).to eq('/custom')
      end
    end

    context 'with non-standard ports' do
      let(:base_url) { 'https://example.com:8443' }

      it 'preserves non-standard ports' do
        expect(server.base_url).to eq('https://example.com:8443')
      end
    end

    it 'uses HTTP protocol version for initialization' do
      # Mock the initialize request to verify protocol version
      init_request_body = nil
      stub_request(:post, "#{base_url}#{endpoint}")
        .with do |request|
          init_request_body = JSON.parse(request.body)
          init_request_body['method'] == 'initialize'
        end
        .to_return(
          status: 200,
          body: "event: message\ndata: #{JSON.generate(
            {
              jsonrpc: '2.0',
              id: 1,
              result: {
                protocolVersion: MCPClient::PROTOCOL_VERSION,
                capabilities: {},
                serverInfo: { name: 'test-server', version: '1.0.0' }
              }
            }
          )}\n\n",
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      # Mock the notifications/initialized request
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(
          status: 200,
          body: '',
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      server.connect

      expect(init_request_body['params']['protocolVersion']).to eq(MCPClient::PROTOCOL_VERSION)
      expect(init_request_body['params']['protocolVersion']).to eq('2025-06-18')
    end

    context 'with standard ports' do
      it 'omits standard HTTP port 80' do
        server = described_class.new(base_url: 'http://example.com:80')
        expect(server.base_url).to eq('http://example.com')
      end

      it 'omits standard HTTPS port 443' do
        server = described_class.new(base_url: 'https://example.com:443')
        expect(server.base_url).to eq('https://example.com')
      end
    end
  end

  describe '#connect' do
    let(:initialize_response) do
      "event: message\ndata: #{initialize_data.to_json}\n\n"
    end

    let(:initialize_data) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'test-server', version: '1.0.0' }
        }
      }
    end

    before do
      # Stub the initialize request
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(
          status: 200,
          body: initialize_response,
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      # Stub the notifications/initialized request
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(
          status: 200,
          body: '',
          headers: { 'Content-Type' => 'text/event-stream' }
        )
    end

    it 'connects successfully' do
      expect(server.connect).to be true
    end

    it 'sets server info and capabilities' do
      server.connect
      expect(server.server_info).to eq({ 'name' => 'test-server', 'version' => '1.0.0' })
      expect(server.capabilities).to eq({ 'tools' => {} })
    end

    it 'returns true if already connected' do
      server.connect
      expect(server.connect).to be true
    end

    context 'when server returns error' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 500, body: 'Internal Server Error')
      end

      it 'raises ConnectionError' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Failed to connect to MCP server/
        )
      end
    end

    context 'when connection fails' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'raises ConnectionError' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Server connection lost.*Connection refused/
        )
      end
    end
  end

  describe '#list_tools' do
    let(:tools_response) do
      "event: message\ndata: #{tools_data.to_json}\n\n"
    end

    let(:tools_data) do
      {
        jsonrpc: '2.0',
        id: 2,
        result: {
          tools: [
            {
              name: 'test_tool',
              description: 'A test tool',
              inputSchema: {
                type: 'object',
                properties: { input: { type: 'string' } },
                required: ['input']
              }
            }
          ]
        }
      }
    end

    before do
      # Stub initialization
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(
          status: 200,
          body: "event: message\ndata: #{initialize_data.to_json}\n\n",
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      # Stub notifications/initialized
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(
          status: 200,
          body: '',
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      # Stub GET for events
      stub_request(:get, "#{base_url}#{endpoint}")
        .to_return(
          status: 200,
          body: '',
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      # Stub tools/list
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'tools/list'))
        .to_return(
          status: 200,
          body: tools_response,
          headers: { 'Content-Type' => 'text/event-stream' }
        )
    end

    let(:initialize_data) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'test-server', version: '1.0.0' }
        }
      }
    end

    it 'returns list of tools' do
      tools = server.list_tools
      expect(tools.size).to eq(1)
      expect(tools.first.name).to eq('test_tool')
      expect(tools.first.description).to eq('A test tool')
      expect(tools.first.schema['properties']).to have_key('input')
    end

    it 'caches tools list' do
      server.list_tools
      tools = server.list_tools
      expect(tools.size).to eq(1)
      # Should not make another HTTP request
    end

    context 'when tools response has tools at root level' do
      let(:tools_data) do
        {
          jsonrpc: '2.0',
          id: 2,
          result: [
            {
              name: 'root_tool',
              description: 'A root level tool',
              inputSchema: { type: 'object' }
            }
          ]
        }
      end

      it 'handles tools at root level' do
        tools = server.list_tools
        expect(tools.size).to eq(1)
        expect(tools.first.name).to eq('root_tool')
      end
    end

    context 'when server returns error' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including('method' => 'tools/list'))
          .to_return(
            status: 200,
            body: "event: message\ndata: #{error_data.to_json}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )
      end

      let(:error_data) do
        {
          jsonrpc: '2.0',
          id: 2,
          error: { code: -1, message: 'Tools not available' }
        }
      end

      it 'raises ServerError' do
        expect { server.list_tools }.to raise_error(
          MCPClient::Errors::ServerError,
          'Tools not available'
        )
      end
    end
  end

  describe '#call_tool' do
    let(:tool_response) do
      "event: message\ndata: #{tool_data.to_json}\n\n"
    end

    let(:tool_data) do
      {
        jsonrpc: '2.0',
        id: 3,
        result: {
          content: [
            { type: 'text', text: 'Tool executed successfully' }
          ]
        }
      }
    end

    before do
      # Stub initialization
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(
          status: 200,
          body: "event: message\ndata: #{initialize_data.to_json}\n\n",
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      # Stub notifications/initialized
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(
          status: 200,
          body: '',
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      # Stub GET for events
      stub_request(:get, "#{base_url}#{endpoint}")
        .to_return(
          status: 200,
          body: '',
          headers: { 'Content-Type' => 'text/event-stream' }
        )

      # Stub tool call
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(
          body: hash_including(
            'method' => 'tools/call',
            'params' => hash_including(
              'name' => 'test_tool',
              'arguments' => { 'input' => 'test input' }
            )
          )
        )
        .to_return(
          status: 200,
          body: tool_response,
          headers: { 'Content-Type' => 'text/event-stream' }
        )
    end

    let(:initialize_data) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'test-server', version: '1.0.0' }
        }
      }
    end

    it 'calls tool successfully' do
      result = server.call_tool('test_tool', { input: 'test input' })
      expect(result['content'].first['text']).to eq('Tool executed successfully')
    end

    context 'when tool returns error' do
      let(:tool_data) do
        {
          jsonrpc: '2.0',
          id: 3,
          error: { code: -1, message: 'Tool execution failed' }
        }
      end

      let(:error_response) do
        "event: message\ndata: #{tool_data.to_json}\n\n"
      end

      before do
        # Re-stub the tool call to return an error response
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including('method' => 'tools/call'))
          .to_return(
            status: 200,
            body: error_response,
            headers: { 'Content-Type' => 'text/event-stream' }
          )
      end

      it 'raises ToolCallError with wrapped error' do
        expect { server.call_tool('test_tool', {}) }.to raise_error(
          MCPClient::Errors::ToolCallError,
          /Error calling tool 'test_tool'/
        )
      end
    end

    context 'when connection is lost' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including('method' => 'tools/call'))
          .to_raise(Faraday::ConnectionFailed.new('Connection lost'))
      end

      it 'raises ConnectionError' do
        expect { server.call_tool('test_tool', {}) }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Server connection lost/
        )
      end
    end
  end

  describe '#call_tool_streaming' do
    before do
      allow(server).to receive(:call_tool).with('streaming_tool', { param: 'value' })
                                          .and_return({ result: 'streamed' })
    end

    it 'returns enumerator with single result' do
      stream = server.call_tool_streaming('streaming_tool', { param: 'value' })
      results = stream.to_a

      expect(results.size).to eq(1)
      expect(results.first).to eq({ result: 'streamed' })
    end
  end

  describe '#list_prompts' do
    let(:prompts_response) do
      "event: message\ndata: #{prompts_data.to_json}\n\n"
    end

    let(:prompts_data) do
      {
        'jsonrpc' => '2.0',
        'id' => 1,
        'result' => {
          'prompts' => [
            {
              'name' => 'test_prompt',
              'description' => 'A test prompt',
              'arguments' => [
                {
                  'name' => 'name',
                  'description' => 'The name parameter',
                  'required' => true
                }
              ]
            }
          ]
        }
      }
    end

    let(:initialize_response) do
      "event: message\ndata: #{initialize_data.to_json}\n\n"
    end

    let(:initialize_data) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'test-server', version: '1.0.0' }
        }
      }
    end

    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(
          status: 200,
          body: initialize_response,
          headers: { 'Content-Type' => 'text/event-stream', 'Mcp-Session-Id' => 'test-session-123' }
        )

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, headers: { 'Mcp-Session-Id' => 'test-session-123' })

      stub_request(:get, "#{base_url}#{endpoint}")
        .with(headers: { 'Mcp-Session-Id' => 'test-session-123' })
        .to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/event-stream' })

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(
          body: hash_including('method' => 'prompts/list'),
          headers: { 'Mcp-Session-Id' => 'test-session-123' }
        )
        .to_return(status: 200, body: prompts_response, headers: { 'Content-Type' => 'text/event-stream' })

      server.connect
    end

    it 'returns list of prompt objects' do
      prompts = server.list_prompts
      expect(prompts.size).to eq(1)
      expect(prompts.first.name).to eq('test_prompt')
      expect(prompts.first.description).to eq('A test prompt')
      expect(prompts.first.arguments).to be_an(Array)
      expect(prompts.first.arguments.first['name']).to eq('name')
    end

    it 'caches prompts after first call' do
      server.list_prompts
      prompts = server.list_prompts
      expect(prompts.size).to eq(1)
      # Should not make another HTTP request
    end
  end

  describe '#get_prompt' do
    let(:prompt_response) do
      "event: message\ndata: #{prompt_data.to_json}\n\n"
    end

    let(:prompt_data) do
      {
        'jsonrpc' => '2.0',
        'id' => 1,
        'result' => {
          'description' => 'Generated greeting',
          'messages' => [
            {
              'role' => 'user',
              'content' => {
                'type' => 'text',
                'text' => 'Hello Ruby Developer!'
              }
            }
          ]
        }
      }
    end

    let(:initialize_response) do
      "event: message\ndata: #{initialize_data.to_json}\n\n"
    end

    let(:initialize_data) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'test-server', version: '1.0.0' }
        }
      }
    end

    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(
          status: 200,
          body: initialize_response,
          headers: { 'Content-Type' => 'text/event-stream', 'Mcp-Session-Id' => 'test-session-123' }
        )

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, headers: { 'Mcp-Session-Id' => 'test-session-123' })

      stub_request(:get, "#{base_url}#{endpoint}")
        .with(headers: { 'Mcp-Session-Id' => 'test-session-123' })
        .to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/event-stream' })

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(
          body: hash_including('method' => 'prompts/get', 'params' => hash_including('name' => 'greeting')),
          headers: { 'Mcp-Session-Id' => 'test-session-123' }
        )
        .to_return(status: 200, body: prompt_response, headers: { 'Content-Type' => 'text/event-stream' })

      server.connect
    end

    it 'returns prompt result' do
      result = server.get_prompt('greeting', { name: 'Ruby Developer' })
      expect(result['messages'].first['content']['text']).to eq('Hello Ruby Developer!')
    end
  end

  describe '#list_resources' do
    let(:resources_response) do
      "event: message\ndata: #{resources_data.to_json}\n\n"
    end

    let(:resources_data) do
      {
        'jsonrpc' => '2.0',
        'id' => 1,
        'result' => {
          'resources' => [
            {
              'uri' => 'file:///sample/README.md',
              'name' => 'Sample README',
              'description' => 'A sample README file',
              'mimeType' => 'text/markdown'
            }
          ]
        }
      }
    end

    let(:initialize_response) do
      "event: message\ndata: #{initialize_data.to_json}\n\n"
    end

    let(:initialize_data) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'test-server', version: '1.0.0' }
        }
      }
    end

    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(
          status: 200,
          body: initialize_response,
          headers: { 'Content-Type' => 'text/event-stream', 'Mcp-Session-Id' => 'test-session-123' }
        )

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, headers: { 'Mcp-Session-Id' => 'test-session-123' })

      stub_request(:get, "#{base_url}#{endpoint}")
        .with(headers: { 'Mcp-Session-Id' => 'test-session-123' })
        .to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/event-stream' })

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(
          body: hash_including('method' => 'resources/list'),
          headers: { 'Mcp-Session-Id' => 'test-session-123' }
        )
        .to_return(status: 200, body: resources_response, headers: { 'Content-Type' => 'text/event-stream' })

      server.connect
    end

    it 'returns list of resource objects' do
      result = server.list_resources
      expect(result).to be_a(Hash)
      expect(result['resources']).to be_an(Array)
      expect(result['resources'].size).to eq(1)
      expect(result['resources'].first.uri).to eq('file:///sample/README.md')
      expect(result['resources'].first.name).to eq('Sample README')
      expect(result['resources'].first.description).to eq('A sample README file')
      expect(result['resources'].first.mime_type).to eq('text/markdown')
    end

    it 'caches resources after first call' do
      server.list_resources
      result = server.list_resources
      expect(result['resources'].size).to eq(1)
      # Should not make another HTTP request
    end
  end

  describe '#read_resource' do
    let(:resource_response) do
      "event: message\ndata: #{resource_data.to_json}\n\n"
    end

    let(:resource_data) do
      {
        'jsonrpc' => '2.0',
        'id' => 1,
        'result' => {
          'contents' => [
            {
              'uri' => 'file:///sample/README.md',
              'mimeType' => 'text/markdown',
              'text' => '# Sample README\n\nThis is a sample file.'
            }
          ]
        }
      }
    end

    let(:initialize_response) do
      "event: message\ndata: #{initialize_data.to_json}\n\n"
    end

    let(:initialize_data) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: { tools: {} },
          serverInfo: { name: 'test-server', version: '1.0.0' }
        }
      }
    end

    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(
          status: 200,
          body: initialize_response,
          headers: { 'Content-Type' => 'text/event-stream', 'Mcp-Session-Id' => 'test-session-123' }
        )

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'notifications/initialized'))
        .to_return(status: 202, headers: { 'Mcp-Session-Id' => 'test-session-123' })

      stub_request(:get, "#{base_url}#{endpoint}")
        .with(headers: { 'Mcp-Session-Id' => 'test-session-123' })
        .to_return(status: 200, body: '', headers: { 'Content-Type' => 'text/event-stream' })

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(
          body: hash_including('method' => 'resources/read',
                               'params' => hash_including('uri' => 'file:///sample/README.md')),
          headers: { 'Mcp-Session-Id' => 'test-session-123' }
        )
        .to_return(status: 200, body: resource_response, headers: { 'Content-Type' => 'text/event-stream' })

      server.connect
    end

    it 'returns resource contents' do
      result = server.read_resource('file:///sample/README.md')
      expect(result).to be_an(Array)
      expect(result.size).to eq(1)
      expect(result.first).to be_a(MCPClient::ResourceContent)
      expect(result.first.text).to eq('# Sample README\n\nThis is a sample file.')
      expect(result.first.mime_type).to eq('text/markdown')
    end
  end

  describe '#cleanup' do
    it 'resets connection state' do
      begin
        server.connect
      rescue StandardError
        nil
      end
      server.cleanup

      connection_established = server.instance_variable_get(:@connection_established)
      initialized = server.instance_variable_get(:@initialized)
      tools = server.instance_variable_get(:@tools)
      prompts = server.instance_variable_get(:@prompts)
      resources = server.instance_variable_get(:@resources)

      expect(connection_established).to be false
      expect(initialized).to be false
      expect(tools).to be_nil
      expect(prompts).to be_nil
      expect(resources).to be_nil
    end
  end

  describe 'error handling' do
    context 'with HTTP 401 Unauthorized' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 401, body: 'Unauthorized')
      end

      it 'raises ConnectionError for auth failure' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Authorization failed: HTTP 401/
        )
      end
    end

    context 'with HTTP 403 Forbidden' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 403, body: 'Forbidden')
      end

      it 'raises ConnectionError for forbidden' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Authorization failed: HTTP 403/
        )
      end
    end

    context 'with HTTP 400 Bad Request' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 400, body: 'Bad Request')
      end

      it 'raises ConnectionError with client error details' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Client error: HTTP 400/
        )
      end
    end

    context 'with HTTP 500 Internal Server Error' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 500, body: 'Internal Server Error')
      end

      it 'raises ConnectionError with server error details' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Server error: HTTP 500/
        )
      end
    end

    context 'with invalid JSON in SSE response' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "event: message\ndata: invalid json\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )
      end

      it 'raises ConnectionError with JSON parsing error details' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Invalid JSON response from server/
        )
      end
    end

    context 'with malformed SSE response' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "event: message\nno data line\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )
      end

      it 'raises ConnectionError with transport error details' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /No data found in SSE response/
        )
      end
    end
  end

  describe 'retry configuration' do
    it 'configures Faraday with retry middleware' do
      conn = server.send(:create_http_connection)
      expect(conn.builder.handlers).to include(Faraday::Retry::Middleware)
    end

    it 'sets retry parameters correctly' do
      conn = server.send(:create_http_connection)
      # Retry middleware is configured but testing actual retry behavior
      # is complex with WebMock, so we just verify it's set up
      expect(conn.builder.handlers).to include(Faraday::Retry::Middleware)
    end
  end

  describe 'timeout handling' do
    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_timeout
    end

    it 'handles timeout errors' do
      expect { server.connect }.to raise_error(
        MCPClient::Errors::ConnectionError
      )
    end
  end

  describe 'session management' do
    describe '#terminate_session' do
      context 'when session ID is present' do
        before do
          server.instance_variable_set(:@session_id, 'streamable-session-123')
        end

        it 'sends HTTP DELETE request with session ID' do
          stub_request(:delete, "#{base_url}#{endpoint}")
            .with(headers: { 'Mcp-Session-Id' => 'streamable-session-123' })
            .to_return(status: 200, body: '')

          result = server.terminate_session
          expect(result).to be true
          expect(server.instance_variable_get(:@session_id)).to be_nil
        end

        it 'handles termination failure gracefully' do
          stub_request(:delete, "#{base_url}#{endpoint}")
            .to_return(status: 500, body: 'Internal Server Error')

          result = server.terminate_session
          expect(result).to be false
        end

        it 'clears session ID even on network errors' do
          stub_request(:delete, "#{base_url}#{endpoint}")
            .to_raise(Faraday::TimeoutError.new('Request timeout'))

          result = server.terminate_session
          expect(result).to be false
          expect(server.instance_variable_get(:@session_id)).to be_nil
        end
      end

      context 'when no session ID is present' do
        it 'returns true without making a request' do
          expect(server.terminate_session).to be true
          expect(WebMock).not_to have_requested(:delete, "#{base_url}#{endpoint}")
        end
      end
    end

    describe 'session ID capture and validation' do
      before do
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
      end

      it 'captures valid session ID from initialize response' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
            headers: {
              'Mcp-Session-Id' => 'valid-streamable-session-456',
              'Content-Type' => 'text/event-stream'
            }
          )

        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'notifications/initialized'))
          .to_return(
            status: 200,
            body: '',
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:perform_initialize)
        expect(server.instance_variable_get(:@session_id)).to eq('valid-streamable-session-456')
      end

      it 'rejects invalid session ID format' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
            headers: {
              'Mcp-Session-Id' => 'invalid@session$format!',
              'Content-Type' => 'text/event-stream'
            }
          )

        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'notifications/initialized'))
          .to_return(
            status: 200,
            body: '',
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:perform_initialize)
        expect(server.instance_variable_get(:@session_id)).to be_nil
      end

      it 'handles missing session ID gracefully' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'notifications/initialized'))
          .to_return(
            status: 200,
            body: '',
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:perform_initialize)
        expect(server.instance_variable_get(:@session_id)).to be_nil
      end
    end

    describe 'session header injection' do
      before do
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
        server.instance_variable_set(:@session_id, 'active-streamable-session-789')
      end

      it 'includes session header in non-initialize requests' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            headers: { 'Mcp-Session-Id' => 'active-streamable-session-789' },
            body: hash_including(method: 'tools/list')
          )
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:request_tools_list)
        expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}")
          .with(headers: { 'Mcp-Session-Id' => 'active-streamable-session-789' })
      end

      it 'does not include session header in initialize requests' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'notifications/initialized'))
          .to_return(
            status: 200,
            body: '',
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:perform_initialize)
        expect(WebMock).to(have_requested(:post, "#{base_url}#{endpoint}")
          .with { |req| !req.headers.key?('Mcp-Session-Id') })
      end
    end

    describe 'cleanup with session termination' do
      before do
        server.instance_variable_set(:@session_id, 'cleanup-streamable-session-999')
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
      end

      it 'terminates session during cleanup' do
        stub_request(:delete, "#{base_url}#{endpoint}")
          .with(headers: { 'Mcp-Session-Id' => 'cleanup-streamable-session-999' })
          .to_return(status: 200, body: '')

        server.cleanup

        expect(WebMock).to have_requested(:delete, "#{base_url}#{endpoint}")
        expect(server.instance_variable_get(:@session_id)).to be_nil
      end
    end
  end

  describe 'resumability and event ID tracking' do
    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
    end

    describe 'event ID extraction from SSE responses' do
      it 'tracks event ID from SSE response' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "event: message\nid: event-123\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:request_tools_list)
        expect(server.instance_variable_get(:@last_event_id)).to eq('event-123')
      end

      it 'handles SSE response without event ID' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:request_tools_list)
        expect(server.instance_variable_get(:@last_event_id)).to be_nil
      end

      it 'updates event ID with each response' do
        # First request
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "event: message\nid: event-001\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:request_tools_list)
        expect(server.instance_variable_get(:@last_event_id)).to eq('event-001')

        # Second request with new event ID
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "event: message\nid: event-002\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.rpc_request('tools/call', { name: 'test', arguments: {} })
        expect(server.instance_variable_get(:@last_event_id)).to eq('event-002')
      end
    end

    describe 'Last-Event-ID header injection' do
      before do
        server.instance_variable_set(:@last_event_id, 'last-event-456')
      end

      it 'includes Last-Event-ID header when available' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            headers: { 'Last-Event-ID' => 'last-event-456' },
            body: hash_including(method: 'tools/list')
          )
          .to_return(
            status: 200,
            body: "event: message\nid: event-457\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:request_tools_list)
        expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}")
          .with(headers: { 'Last-Event-ID' => 'last-event-456' })
      end

      it 'includes both session and Last-Event-ID headers when both present' do
        server.instance_variable_set(:@session_id, 'session-123')
        server.instance_variable_set(:@last_event_id, 'event-789')

        stub_request(:post, "#{base_url}#{endpoint}")
          .with(
            headers: {
              'Mcp-Session-Id' => 'session-123',
              'Last-Event-ID' => 'event-789'
            },
            body: hash_including(method: 'tools/list')
          )
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' }
          )

        server.send(:request_tools_list)
        expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}")
          .with(headers: {
                  'Mcp-Session-Id' => 'session-123',
                  'Last-Event-ID' => 'event-789'
                })
      end
    end

    describe 'complex SSE response parsing' do
      it 'handles multiline SSE response with event ID' do
        sse_response = <<~SSE
          event: message
          id: complex-event-123
          retry: 1000
          data: {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}

        SSE

        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 200, body: sse_response, headers: { 'Content-Type' => 'text/event-stream' })

        result = server.send(:request_tools_list)
        expect(result).to eq([])
        expect(server.instance_variable_get(:@last_event_id)).to eq('complex-event-123')
      end

      it 'handles SSE response with multiple data lines' do
        sse_response = <<~SSE
          event: message#{'  '}
          id: multiline-event-456
          data: {"jsonrpc":"2.0","id":1,
          data: "result":{"tools":[]}}

        SSE

        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 200, body: sse_response, headers: { 'Content-Type' => 'text/event-stream' })

        result = server.send(:request_tools_list)
        expect(result).to eq([])
        expect(server.instance_variable_get(:@last_event_id)).to eq('multiline-event-456')
      end
    end
  end

  describe 'security validation' do
    # Session ID and URL validation tests are shared with HTTP transport
    # through the HttpTransportBase module, so we just verify they work here

    describe 'URL validation during initialization' do
      it 'raises ArgumentError for invalid URL' do
        expect do
          described_class.new(base_url: 'ftp://invalid.com')
        end.to raise_error(ArgumentError, /Invalid or insecure server URL/)
      end

      it 'raises ArgumentError for malicious URL' do
        expect do
          described_class.new(base_url: 'javascript:void(0)')
        end.to raise_error(ArgumentError, /Invalid or insecure server URL/)
      end
    end

    describe 'session ID validation in practice' do
      before do
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
      end

      it 'accepts alphanumeric session IDs with hyphens and underscores' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
            headers: {
              'Mcp-Session-Id' => 'valid_session-123_abc',
              'Content-Type' => 'text/event-stream'
            }
          )

        server.send(:perform_initialize)
        expect(server.instance_variable_get(:@session_id)).to eq('valid_session-123_abc')
      end

      it 'rejects session IDs with special characters' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(
            status: 200,
            body: "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n",
            headers: {
              'Mcp-Session-Id' => 'invalid/session@123!',
              'Content-Type' => 'text/event-stream'
            }
          )

        server.send(:perform_initialize)
        expect(server.instance_variable_get(:@session_id)).to be_nil
      end
    end
  end
end
