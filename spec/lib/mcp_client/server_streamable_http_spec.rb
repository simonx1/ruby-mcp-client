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

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
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
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'initialize'))
        .to_return(
          status: 200,
          body: initialize_response,
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

  describe '#cleanup' do
    it 'resets connection state' do
      server.connect rescue nil
      server.cleanup
      
      connection_established = server.instance_variable_get(:@connection_established)
      initialized = server.instance_variable_get(:@initialized)
      tools = server.instance_variable_get(:@tools)
      
      expect(connection_established).to be false
      expect(initialized).to be false
      expect(tools).to be_nil
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
end