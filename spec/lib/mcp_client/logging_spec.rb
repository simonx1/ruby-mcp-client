# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Logging (MCP 2025-06-18)' do
  let(:mock_server) { instance_double(MCPClient::ServerStdio, name: 'stdio-server') }

  before do
    allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
    allow(mock_server).to receive(:on_notification)
    allow(mock_server).to receive(:respond_to?).with(:on_elicitation_request).and_return(true)
    allow(mock_server).to receive(:respond_to?).with(:on_roots_list_request).and_return(true)
    allow(mock_server).to receive(:respond_to?).with(:on_sampling_request).and_return(true)
    allow(mock_server).to receive(:on_elicitation_request)
    allow(mock_server).to receive(:on_roots_list_request)
    allow(mock_server).to receive(:on_sampling_request)
  end

  describe MCPClient::Client do
    describe '#log_level=' do
      let(:client) do
        described_class.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }])
      end

      it 'sets log level on all servers' do
        allow(mock_server).to receive(:log_level=).and_return({})

        client.log_level = 'warning'

        expect(mock_server).to have_received(:log_level=).with('warning')
      end

      context 'when no server is available' do
        let(:empty_client) { described_class.new(mcp_server_configs: []) }

        it 'does not raise error' do
          expect { empty_client.log_level = 'error' }.not_to raise_error
        end
      end
    end

    describe '#handle_log_message' do
      let(:test_logger) { instance_double(Logger) }
      let(:client) do
        described_class.new(
          mcp_server_configs: [{ type: 'stdio', command: 'test' }],
          logger: test_logger
        )
      end

      before do
        allow(test_logger).to receive(:progname=)
        allow(test_logger).to receive(:formatter=)
        allow(test_logger).to receive(:debug)
        allow(test_logger).to receive(:info)
        allow(test_logger).to receive(:warn)
        allow(test_logger).to receive(:error)
      end

      it 'logs debug messages' do
        client.send(:handle_log_message, 'server1', { 'level' => 'debug', 'data' => 'Debug message' })

        expect(test_logger).to have_received(:debug).with('[server1] Debug message')
      end

      it 'logs info messages' do
        client.send(:handle_log_message, 'server1', { 'level' => 'info', 'data' => 'Info message' })

        expect(test_logger).to have_received(:info).with('[server1] Info message')
      end

      it 'logs notice as info' do
        client.send(:handle_log_message, 'server1', { 'level' => 'notice', 'data' => 'Notice message' })

        expect(test_logger).to have_received(:info).with('[server1] Notice message')
      end

      it 'logs warning messages' do
        client.send(:handle_log_message, 'server1', { 'level' => 'warning', 'data' => 'Warning message' })

        expect(test_logger).to have_received(:warn).with('[server1] Warning message')
      end

      it 'logs error messages' do
        client.send(:handle_log_message, 'server1', { 'level' => 'error', 'data' => 'Error message' })

        expect(test_logger).to have_received(:error).with('[server1] Error message')
      end

      it 'logs critical as error' do
        client.send(:handle_log_message, 'server1', { 'level' => 'critical', 'data' => 'Critical message' })

        expect(test_logger).to have_received(:error).with('[server1] Critical message')
      end

      it 'includes logger name in prefix when provided' do
        client.send(:handle_log_message, 'server1', {
                      'level' => 'info',
                      'logger' => 'my_logger',
                      'data' => 'Test message'
                    })

        expect(test_logger).to have_received(:info).with('[server1:my_logger] Test message')
      end

      it 'handles non-string data' do
        client.send(:handle_log_message, 'server1', {
                      'level' => 'info',
                      'data' => { 'key' => 'value' }
                    })

        expect(test_logger).to have_received(:info).with('[server1] {"key"=>"value"}')
      end

      it 'defaults to info level when level not specified' do
        client.send(:handle_log_message, 'server1', { 'data' => 'Message' })

        expect(test_logger).to have_received(:info).with('[server1] Message')
      end
    end

    describe 'notification handling' do
      let(:test_logger) { instance_double(Logger) }
      let(:client) do
        described_class.new(
          mcp_server_configs: [{ type: 'stdio', command: 'test' }],
          logger: test_logger
        )
      end

      before do
        allow(test_logger).to receive(:progname=)
        allow(test_logger).to receive(:formatter=)
        allow(test_logger).to receive(:debug)
        allow(test_logger).to receive(:info)
        allow(test_logger).to receive(:warn)
        allow(test_logger).to receive(:error)
      end

      it 'processes notifications/message notifications' do
        client.send(:process_notification, mock_server, 'notifications/message', {
                      'level' => 'warning',
                      'data' => 'Server warning'
                    })

        expect(test_logger).to have_received(:warn)
      end
    end
  end

  describe MCPClient::ServerStdio do
    describe '#log_level=' do
      let(:server) do
        described_class.new(command: 'test-command', logger: Logger.new(nil))
      end

      before do
        allow(server).to receive(:ensure_initialized)
        allow(server).to receive(:next_id).and_return(1)
        allow(server).to receive(:send_request)
        allow(server).to receive(:wait_response).and_return({ 'id' => 1, 'result' => {} })
      end

      it 'sends logging/setLevel request' do
        server.log_level = 'debug'

        expect(server).to have_received(:send_request).with(
          hash_including('method' => 'logging/setLevel', 'params' => { 'level' => 'debug' })
        )
      end

      it 'raises ServerError on error response' do
        allow(server).to receive(:wait_response).and_return({
                                                              'id' => 1,
                                                              'error' => { 'message' => 'Invalid level' }
                                                            })

        expect do
          server.log_level = 'invalid'
        end.to raise_error(MCPClient::Errors::ServerError)
      end
    end
  end

  describe MCPClient::ServerSSE do
    describe '#log_level=' do
      let(:server) do
        described_class.new(base_url: 'http://example.com/sse', logger: Logger.new(nil))
      end

      before do
        allow(server).to receive(:rpc_request).and_return({})
      end

      it 'calls rpc_request with correct parameters' do
        server.log_level = 'warning'

        expect(server).to have_received(:rpc_request).with('logging/setLevel', { level: 'warning' })
      end
    end
  end

  describe MCPClient::ServerStreamableHTTP do
    describe '#log_level=' do
      let(:server) do
        described_class.new(base_url: 'http://example.com/mcp', logger: Logger.new(nil))
      end

      before do
        allow(server).to receive(:rpc_request).and_return({})
      end

      it 'calls rpc_request with correct parameters' do
        server.log_level = 'error'

        expect(server).to have_received(:rpc_request).with('logging/setLevel', { level: 'error' })
      end
    end
  end

  describe MCPClient::ServerHTTP do
    describe '#log_level=' do
      let(:server) do
        described_class.new(base_url: 'http://example.com/rpc', logger: Logger.new(nil))
      end

      before do
        allow(server).to receive(:rpc_request).and_return({})
      end

      it 'calls rpc_request with correct parameters' do
        server.log_level = 'critical'

        expect(server).to have_received(:rpc_request).with('logging/setLevel', { level: 'critical' })
      end
    end
  end
end
