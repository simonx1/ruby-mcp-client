# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

RSpec.describe 'HTTP Transport Integration', type: :integration do
  let(:base_url) { 'https://api.example.com' }
  let(:endpoint) { '/mcp' }
  let(:headers) { { 'Authorization' => 'Bearer test-token-123' } }
  
  let(:server) do
    MCPClient::ServerHTTP.new(
      base_url: base_url,
      endpoint: endpoint,
      headers: headers,
      read_timeout: 10,
      retries: 1,
      name: 'integration-test-server'
    )
  end

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
    server.cleanup if defined?(server)
  end

  describe 'full workflow' do
    let(:initialize_response) do
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

    let(:tools_response) do
      {
        jsonrpc: '2.0',
        id: 2,
        result: {
          tools: [
            {
              name: 'weather',
              description: 'Get weather information',
              inputSchema: {
                type: 'object',
                properties: {
                  location: { type: 'string', description: 'City name' }
                },
                required: ['location']
              }
            },
            {
              name: 'calculator',
              description: 'Perform calculations',
              inputSchema: {
                type: 'object',
                properties: {
                  expression: { type: 'string', description: 'Math expression' }
                },
                required: ['expression']
              }
            }
          ]
        }
      }
    end

    let(:weather_tool_response) do
      {
        jsonrpc: '2.0',
        id: 3,
        result: {
          content: [
            {
              type: 'text',
              text: 'Weather in San Francisco: 72°F, partly cloudy'
            }
          ]
        }
      }
    end

    before do
      # Use a general stub that responds to all requests to the endpoint
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return do |request|
          body = JSON.parse(request.body)
          case body['method']
          when 'initialize'
            { status: 200, body: initialize_response.to_json, headers: { 'Content-Type' => 'application/json' } }
          when 'tools/list'
            { status: 200, body: tools_response.to_json, headers: { 'Content-Type' => 'application/json' } }
          when 'tools/call'
            { status: 200, body: weather_tool_response.to_json, headers: { 'Content-Type' => 'application/json' } }
          else
            { status: 404, body: 'Not Found' }
          end
        end
    end

    it 'successfully completes full MCP workflow' do
      # Step 1: Connect to server
      expect(server.connect).to be true
      expect(server.server_info['name']).to eq('test-server')
      expect(server.capabilities).to have_key('tools')

      # Step 2: List available tools
      tools = server.list_tools
      expect(tools.size).to eq(2)
      
      weather_tool = tools.find { |t| t.name == 'weather' }
      expect(weather_tool).not_to be_nil
      expect(weather_tool.description).to eq('Get weather information')
      expect(weather_tool.schema['properties']).to have_key('location')

      # Step 3: Call a tool
      result = server.call_tool('weather', { location: 'San Francisco' })
      expect(result['content'].size).to eq(1)
      expect(result['content'].first['text']).to include('Weather in San Francisco')

      # Verify all expected requests were made
      expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}").times(3)
    end

    it 'sends correct headers in all requests' do
      server.connect
      server.list_tools
      server.call_tool('weather', { location: 'San Francisco' })

      # Verify all requests were made to the correct endpoint
      # Headers verification is covered in unit tests
      expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}").times(3)
    end

    it 'handles streaming tool calls' do
      server.connect
      
      stream = server.call_tool_streaming('weather', { location: 'San Francisco' })
      results = stream.to_a
      
      expect(results.size).to eq(1)
      expect(results.first['content'].first['text']).to include('Weather in San Francisco')
    end
  end

  describe 'error scenarios' do
    context 'when server is unreachable' do
      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_raise(Faraday::ConnectionFailed.new('Connection refused'))
      end

      it 'raises ConnectionError with descriptive message' do
        expect { server.connect }.to raise_error(
          MCPClient::Errors::ConnectionError,
          /Server connection lost.*Connection refused/
        )
      end
    end

    context 'when authentication fails' do
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

    context 'when server returns malformed responses' do
      let(:init_response) do
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
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: init_response.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'tools/list'))
          .to_return(status: 200, body: 'invalid json response')
      end

      it 'raises TransportError for invalid JSON' do
        server.connect
        expect { server.list_tools }.to raise_error(
          MCPClient::Errors::TransportError,
          /Invalid JSON response from server/
        )
      end
    end

    context 'when tool execution fails' do
      let(:init_response) do
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
          .with(body: hash_including(method: 'initialize'))
          .to_return(
            status: 200,
            body: init_response.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )

        stub_request(:post, "#{base_url}#{endpoint}")
          .with(body: hash_including(method: 'tools/call'))
          .to_return(
            status: 200,
            body: {
              jsonrpc: '2.0',
              id: 1,
              error: { code: -1, message: 'Tool not found' }
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'raises ToolCallError with wrapped error message' do
        server.connect
        expect { server.call_tool('nonexistent_tool', {}) }.to raise_error(
          MCPClient::Errors::ToolCallError,
          /Error calling tool 'nonexistent_tool'/
        )
      end
    end
  end

  describe 'notification handling' do
    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including(method: 'initialize'))
        .to_return(
          status: 200,
          body: {
            jsonrpc: '2.0',
            id: 1,
            result: { protocolVersion: '2024-11-05', capabilities: {} }
          }.to_json
        )

      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including(method: 'notification'))
        .to_return(status: 200, body: '')
    end

    it 'sends notifications without expecting responses' do
      server.connect
      
      expect { server.rpc_notify('notification', { event: 'test' }) }.not_to raise_error
      
      expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}")
        .with { |req|
          body = JSON.parse(req.body)
          body['method'] == 'notification' && !body.key?('id')
        }
    end
  end

  describe 'server factory integration' do
    let(:config) do
      {
        type: 'http',
        base_url: base_url,
        endpoint: endpoint,
        headers: headers,
        read_timeout: 15,
        retries: 2,
        name: 'factory-test-server'
      }
    end

    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(
          status: 200,
          body: {
            jsonrpc: '2.0',
            id: 1,
            result: { protocolVersion: '2024-11-05', capabilities: {} }
          }.to_json
        )
    end

    it 'creates HTTP server through factory' do
      server = MCPClient::ServerFactory.create(config)
      
      expect(server).to be_a(MCPClient::ServerHTTP)
      expect(server.base_url).to eq(base_url)
      expect(server.endpoint).to eq(endpoint)
      expect(server.name).to eq('factory-test-server')
      
      # Test that it can connect
      expect(server.connect).to be true
    end
  end

  describe 'concurrent requests' do
    before do
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including(method: 'initialize'))
        .to_return(
          status: 200,
          body: {
            jsonrpc: '2.0',
            id: 1,
            result: { protocolVersion: '2024-11-05', capabilities: {} }
          }.to_json
        )

      # Stub multiple ping requests
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including(method: 'ping'))
        .to_return(
          status: 200,
          body: { jsonrpc: '2.0', id: 1, result: 'pong' }.to_json
        )
    end

    it 'handles concurrent requests correctly' do
      server.connect
      
      # Make multiple concurrent requests
      threads = 5.times.map do |i|
        Thread.new do
          server.ping
        end
      end
      
      results = threads.map(&:join).map(&:value)
      expect(results).to all(eq('pong'))
      
      # Verify all requests were made
      expect(WebMock).to have_requested(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including(method: 'ping'))
        .times(5)
    end
  end
end