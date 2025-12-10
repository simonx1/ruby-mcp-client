# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'MCPClient.connect' do
  describe 'transport detection' do
    describe '.detect_transport (private)' do
      it 'detects SSE for URLs ending in /sse' do
        expect(MCPClient.send(:detect_transport, 'http://example.com/sse')).to eq(:sse)
        expect(MCPClient.send(:detect_transport, 'https://api.example.com/v1/sse')).to eq(:sse)
        expect(MCPClient.send(:detect_transport, 'http://localhost:8000/SSE')).to eq(:sse)
      end

      it 'detects Streamable HTTP for URLs ending in /mcp' do
        expect(MCPClient.send(:detect_transport, 'http://example.com/mcp')).to eq(:streamable_http)
        expect(MCPClient.send(:detect_transport, 'https://api.example.com/api/mcp')).to eq(:streamable_http)
        expect(MCPClient.send(:detect_transport, 'http://localhost:8931/MCP')).to eq(:streamable_http)
      end

      it 'detects stdio for Array commands' do
        expect(MCPClient.send(:detect_transport, ['npx', '-y', 'server'])).to eq(:stdio)
        expect(MCPClient.send(:detect_transport, %w[python server.py])).to eq(:stdio)
      end

      it 'detects stdio for stdio:// URLs' do
        expect(MCPClient.send(:detect_transport, 'stdio://npx server')).to eq(:stdio)
        expect(MCPClient.send(:detect_transport, 'stdio://python server.py')).to eq(:stdio)
      end

      it 'detects stdio for common command patterns' do
        expect(MCPClient.send(:detect_transport, 'npx -y @modelcontextprotocol/server')).to eq(:stdio)
        expect(MCPClient.send(:detect_transport, 'python server.py')).to eq(:stdio)
        expect(MCPClient.send(:detect_transport, 'python3 server.py')).to eq(:stdio)
        expect(MCPClient.send(:detect_transport, 'node server.js')).to eq(:stdio)
        expect(MCPClient.send(:detect_transport, 'ruby server.rb')).to eq(:stdio)
        expect(MCPClient.send(:detect_transport, 'java -jar server.jar')).to eq(:stdio)
        expect(MCPClient.send(:detect_transport, 'cargo run --release')).to eq(:stdio)
        expect(MCPClient.send(:detect_transport, 'go run main.go')).to eq(:stdio)
      end

      it 'returns :auto for ambiguous HTTP URLs' do
        expect(MCPClient.send(:detect_transport, 'http://example.com/api')).to eq(:auto)
        expect(MCPClient.send(:detect_transport, 'https://api.example.com')).to eq(:auto)
        expect(MCPClient.send(:detect_transport, 'http://localhost:8080/')).to eq(:auto)
      end

      it 'raises TransportDetectionError for non-HTTP URLs' do
        expect do
          MCPClient.send(:detect_transport, 'ftp://example.com')
        end.to raise_error(MCPClient::Errors::TransportDetectionError, /non-HTTP URL/)
      end

      it 'raises TransportDetectionError for invalid URLs' do
        expect do
          MCPClient.send(:detect_transport, ':::invalid:::')
        end.to raise_error(MCPClient::Errors::TransportDetectionError, /Invalid URL/)
      end
    end

    describe '.stdio_target? (private)' do
      it 'returns false for Array commands (handled by stdio_command_array?)' do
        expect(MCPClient.send(:stdio_target?, %w[npx server])).to be false
      end

      it 'returns true for stdio:// prefix' do
        expect(MCPClient.send(:stdio_target?, 'stdio://command')).to be true
      end

      it 'returns true for common command prefixes' do
        %w[npx node python python3 ruby php java cargo].each do |cmd|
          expect(MCPClient.send(:stdio_target?, "#{cmd} something")).to be true
        end
        expect(MCPClient.send(:stdio_target?, 'go run main.go')).to be true
      end

      it 'returns false for URLs' do
        expect(MCPClient.send(:stdio_target?, 'http://example.com')).to be false
        expect(MCPClient.send(:stdio_target?, 'https://example.com/sse')).to be false
      end
    end

    describe '.stdio_command_array? (private)' do
      it 'returns true for command arrays starting with known executables' do
        expect(MCPClient.send(:stdio_command_array?, %w[npx -y server])).to be true
        expect(MCPClient.send(:stdio_command_array?, %w[python server.py])).to be true
        expect(MCPClient.send(:stdio_command_array?, %w[node server.js])).to be true
        expect(MCPClient.send(:stdio_command_array?, %w[ruby server.rb])).to be true
      end

      it 'returns true for command arrays with non-URL elements' do
        expect(MCPClient.send(:stdio_command_array?, %w[my-command --flag value])).to be true
      end

      it 'returns false for arrays containing URLs' do
        expect(MCPClient.send(:stdio_command_array?, ['http://server1/mcp', 'http://server2/sse'])).to be false
      end

      it 'returns false for arrays starting with URLs' do
        expect(MCPClient.send(:stdio_command_array?, ['http://example.com/mcp'])).to be false
      end

      it 'returns false for empty arrays' do
        expect(MCPClient.send(:stdio_command_array?, [])).to be false
      end
    end

    describe '.parse_stdio_command (private)' do
      it 'returns Array commands as-is' do
        cmd = %w[npx -y server]
        expect(MCPClient.send(:parse_stdio_command, cmd)).to eq(cmd)
      end

      it 'strips stdio:// prefix from commands' do
        expect(MCPClient.send(:parse_stdio_command, 'stdio://npx server')).to eq('npx server')
      end

      it 'returns regular commands as-is' do
        expect(MCPClient.send(:parse_stdio_command, 'python server.py')).to eq('python server.py')
      end
    end
  end

  describe '.connect' do
    let(:mock_server) do
      instance_double(MCPClient::ServerBase, connect: true, name: 'test-server')
    end
    let(:mock_client) do
      instance_double(MCPClient::Client, servers: [mock_server], logger: nil)
    end

    before do
      allow(MCPClient::Client).to receive(:new).and_return(mock_client)
    end

    context 'with SSE URL (ending in /sse)' do
      it 'creates SSE config and connects' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'sse', base_url: 'http://example.com/sse')])
        )
        expect(mock_server).to receive(:connect)

        MCPClient.connect('http://example.com/sse')
      end

      it 'passes headers option' do
        headers = { 'Authorization' => 'Bearer token' }
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'sse', headers: headers)])
        )

        MCPClient.connect('http://example.com/sse', headers: headers)
      end
    end

    context 'with Streamable HTTP URL (ending in /mcp)' do
      it 'creates streamable_http config and connects' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(
            mcp_server_configs: [hash_including(type: 'streamable_http', base_url: 'http://example.com/mcp')]
          )
        )
        expect(mock_server).to receive(:connect)

        MCPClient.connect('http://example.com/mcp')
      end

      it 'passes endpoint option' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'streamable_http', endpoint: '/custom')])
        )

        MCPClient.connect('http://example.com/mcp', endpoint: '/custom')
      end
    end

    context 'with stdio command' do
      it 'creates stdio config for Array command' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'stdio', command: %w[npx -y server])])
        )

        MCPClient.connect(%w[npx -y server])
      end

      it 'creates stdio config for string command' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'stdio', command: 'npx -y server')])
        )

        MCPClient.connect('npx -y server')
      end

      it 'creates stdio config for stdio:// URL' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'stdio', command: 'python server.py')])
        )

        MCPClient.connect('stdio://python server.py')
      end

      it 'passes env option' do
        env = { 'MY_VAR' => 'value' }
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'stdio', env: env)])
        )

        MCPClient.connect('npx server', env: env)
      end
    end

    context 'with common options' do
      it 'passes read_timeout' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(read_timeout: 60)])
        )

        MCPClient.connect('http://example.com/sse', read_timeout: 60)
      end

      it 'passes retries' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(retries: 5)])
        )

        MCPClient.connect('http://example.com/sse', retries: 5)
      end

      it 'passes name' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(name: 'my-server')])
        )

        MCPClient.connect('http://example.com/sse', name: 'my-server')
      end

      it 'passes logger' do
        logger = Logger.new($stdout)
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(logger: logger)
        )

        MCPClient.connect('http://example.com/sse', logger: logger)
      end
    end

    context 'with forced transport option' do
      it 'uses :http transport when specified' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'http')])
        )

        MCPClient.connect('http://example.com/api', transport: :http)
      end

      it 'uses :streamable_http transport when specified' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'streamable_http')])
        )

        MCPClient.connect('http://example.com/api', transport: :streamable_http)
      end

      it 'uses :sse transport when specified' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'sse')])
        )

        MCPClient.connect('http://example.com/api', transport: :sse)
      end

      it 'accepts string transport option' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'http')])
        )

        MCPClient.connect('http://example.com/api', transport: 'http')
      end
    end

    context 'with multiple URLs' do
      let(:mock_server2) { instance_double(MCPClient::ServerBase, connect: true, name: 'server-2') }

      before do
        allow(mock_client).to receive(:servers).and_return([mock_server, mock_server2])
      end

      it 'connects to multiple servers' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: array_including(
            hash_including(type: 'streamable_http', base_url: 'http://server1/mcp'),
            hash_including(type: 'sse', base_url: 'http://server2/sse')
          ))
        )
        expect(mock_server).to receive(:connect)
        expect(mock_server2).to receive(:connect)

        MCPClient.connect(['http://server1/mcp', 'http://server2/sse'])
      end

      it 'assigns sequential names to servers' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: array_including(
            hash_including(name: 'server_0'),
            hash_including(name: 'server_1')
          ))
        )

        MCPClient.connect(['http://server1/mcp', 'http://server2/sse'])
      end

      it 'uses custom name prefix when provided' do
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: array_including(
            hash_including(name: 'myapp_0'),
            hash_including(name: 'myapp_1')
          ))
        )

        MCPClient.connect(['http://server1/mcp', 'http://server2/sse'], name: 'myapp')
      end
    end

    context 'with Faraday block' do
      it 'passes block to http config' do
        block_called = false
        faraday_block = proc { block_called = true }

        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'http', faraday_config: faraday_block)])
        )

        MCPClient.connect('http://example.com/api', transport: :http, &faraday_block)
      end

      it 'passes block to streamable_http config' do
        faraday_block = proc { |f| f.ssl.verify = false }

        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'streamable_http', faraday_config: faraday_block)])
        )

        MCPClient.connect('http://example.com/mcp', &faraday_block)
      end
    end

    context 'error handling' do
      it 'raises TransportDetectionError for unknown forced transport' do
        expect do
          MCPClient.connect('http://example.com', transport: :unknown)
        end.to raise_error(MCPClient::Errors::TransportDetectionError, /Unknown transport/)
      end
    end
  end

  describe '.connect with fallback' do
    # These tests verify the fallback behavior when transport cannot be detected from URL

    let(:mock_server) { instance_double(MCPClient::ServerBase, connect: true, name: 'test') }
    let(:mock_client) { instance_double(MCPClient::Client, servers: [mock_server], logger: nil) }

    context 'when ambiguous URL is provided' do
      before do
        allow(MCPClient::Client).to receive(:new).and_return(mock_client)
      end

      it 'tries streamable_http first for ambiguous URLs' do
        # First call should be streamable_http
        expect(MCPClient::Client).to receive(:new).with(
          hash_including(mcp_server_configs: [hash_including(type: 'streamable_http')])
        ).and_return(mock_client)
        allow(mock_server).to receive(:connect)

        MCPClient.connect('http://example.com/api')
      end

      it 'falls back to SSE when streamable_http fails' do
        # First attempt with streamable_http fails
        streamable_client = instance_double(MCPClient::Client, servers: [mock_server])
        allow(MCPClient::Client).to receive(:new)
          .with(hash_including(mcp_server_configs: [hash_including(type: 'streamable_http')]))
          .and_return(streamable_client)
        allow(mock_server).to receive(:connect).and_raise(MCPClient::Errors::ConnectionError, 'streamable failed')

        # Second attempt with SSE succeeds
        sse_server = instance_double(MCPClient::ServerBase, connect: true, name: 'sse')
        sse_client = instance_double(MCPClient::Client, servers: [sse_server])
        allow(MCPClient::Client).to receive(:new)
          .with(hash_including(mcp_server_configs: [hash_including(type: 'sse')]))
          .and_return(sse_client)

        result = MCPClient.connect('http://example.com/api')
        expect(result).to eq(sse_client)
      end

      it 'falls back to HTTP when both streamable_http and SSE fail' do
        # First attempt with streamable_http fails
        streamable_server = instance_double(MCPClient::ServerBase, name: 'streamable')
        streamable_client = instance_double(MCPClient::Client, servers: [streamable_server])
        allow(MCPClient::Client).to receive(:new)
          .with(hash_including(mcp_server_configs: [hash_including(type: 'streamable_http')]))
          .and_return(streamable_client)
        allow(streamable_server).to receive(:connect).and_raise(MCPClient::Errors::ConnectionError, 'streamable failed')

        # Second attempt with SSE fails
        sse_server = instance_double(MCPClient::ServerBase, name: 'sse')
        sse_client = instance_double(MCPClient::Client, servers: [sse_server])
        allow(MCPClient::Client).to receive(:new)
          .with(hash_including(mcp_server_configs: [hash_including(type: 'sse')]))
          .and_return(sse_client)
        allow(sse_server).to receive(:connect).and_raise(MCPClient::Errors::TransportError, 'sse failed')

        # Third attempt with HTTP succeeds
        http_server = instance_double(MCPClient::ServerBase, connect: true, name: 'http')
        http_client = instance_double(MCPClient::Client, servers: [http_server])
        allow(MCPClient::Client).to receive(:new)
          .with(hash_including(mcp_server_configs: [hash_including(type: 'http')]))
          .and_return(http_client)

        result = MCPClient.connect('http://example.com/api')
        expect(result).to eq(http_client)
      end

      it 'raises ConnectionError with all errors when all transports fail' do
        # All transports fail
        %w[streamable_http sse http].each do |type|
          server = instance_double(MCPClient::ServerBase, name: type)
          client = instance_double(MCPClient::Client, servers: [server])
          allow(MCPClient::Client).to receive(:new)
            .with(hash_including(mcp_server_configs: [hash_including(type: type)]))
            .and_return(client)
          allow(server).to receive(:connect).and_raise(MCPClient::Errors::ConnectionError, "#{type} failed")
        end

        expect do
          MCPClient.connect('http://example.com/api')
        end.to raise_error(MCPClient::Errors::ConnectionError) do |error|
          expect(error.message).to include('Tried all transports')
          expect(error.message).to include('Streamable HTTP: streamable_http failed')
          expect(error.message).to include('SSE: sse failed')
          expect(error.message).to include('HTTP: http failed')
        end
      end
    end
  end

  describe 'option extraction helpers (private)' do
    describe '.extract_common_options' do
      it 'extracts common options' do
        options = {
          name: 'test',
          logger: Logger.new($stdout),
          read_timeout: 60,
          retries: 3,
          retry_backoff: 2,
          headers: { 'X-Custom' => 'value' } # Should not be included
        }

        result = MCPClient.send(:extract_common_options, options)

        expect(result).to include(name: 'test', read_timeout: 60, retries: 3, retry_backoff: 2)
        expect(result).to have_key(:logger)
        expect(result).not_to have_key(:headers)
      end

      it 'removes nil values' do
        options = { name: nil, read_timeout: 30 }
        result = MCPClient.send(:extract_common_options, options)

        expect(result).not_to have_key(:name)
        expect(result).to include(read_timeout: 30)
      end
    end

    describe '.extract_http_options' do
      it 'includes headers and endpoint' do
        options = {
          name: 'test',
          headers: { 'Auth' => 'token' },
          endpoint: '/custom',
          read_timeout: 30
        }

        result = MCPClient.send(:extract_http_options, options)

        expect(result).to include(
          name: 'test',
          headers: { 'Auth' => 'token' },
          endpoint: '/custom',
          read_timeout: 30
        )
      end

      it 'defaults headers to empty hash' do
        result = MCPClient.send(:extract_http_options, {})
        expect(result).to include(headers: {})
      end
    end

    describe '.extract_sse_options' do
      it 'includes headers and ping' do
        options = {
          name: 'test',
          headers: { 'Auth' => 'token' },
          ping: 15,
          read_timeout: 30
        }

        result = MCPClient.send(:extract_sse_options, options)

        expect(result).to include(
          name: 'test',
          headers: { 'Auth' => 'token' },
          ping: 15,
          read_timeout: 30
        )
      end
    end

    describe '.extract_stdio_options' do
      it 'includes env' do
        options = {
          name: 'test',
          env: { 'PATH' => '/custom' },
          read_timeout: 30
        }

        result = MCPClient.send(:extract_stdio_options, options)

        expect(result).to include(
          name: 'test',
          env: { 'PATH' => '/custom' },
          read_timeout: 30
        )
      end

      it 'defaults env to empty hash' do
        result = MCPClient.send(:extract_stdio_options, {})
        expect(result).to include(env: {})
      end
    end
  end
end
