# frozen_string_literal: true

require 'spec_helper'
require 'mcp_client/server_sse/reconnect_monitor'

RSpec.describe MCPClient::ServerSSE::ReconnectMonitor do
  let(:dummy_class) do
    Class.new do
      include MCPClient::ServerSSE::ReconnectMonitor

      attr_accessor :mutex, :connection_cv, :logger, :base_url,
                    :max_retries, :retry_backoff,
                    :connection_established, :sse_connected,
                    :last_activity_time, :auth_error

      def initialize
        @mutex = Mutex.new
        cv = Object.new
        def cv.wait(_timeout = nil)
          nil
        end

        def cv.broadcast; end
        @connection_cv = cv
        @logger = Logger.new(StringIO.new)
        @base_url = 'http://example.com/base'
        @max_retries = 1
        @retry_backoff = 0.1
      end

      def cleanup; end
      def connect; end
      def ping; end
    end
  end

  subject(:monitor) { dummy_class.new }

  describe '#connection_active?' do
    it 'returns true only when both connection_established and sse_connected are true' do
      monitor.connection_established = true
      monitor.sse_connected = false
      expect(monitor.connection_active?).to be false
      monitor.sse_connected = true
      expect(monitor.connection_active?).to be true
    end
  end

  describe '#record_activity' do
    it 'updates last_activity_time' do
      old_time = Time.at(0)
      monitor.last_activity_time = old_time
      monitor.record_activity
      expect(monitor.last_activity_time).to be > old_time
    end
  end

  describe '#handle_sse_auth_error' do
    it 'logs error, sets auth_error, resets connection_established, and broadcasts' do
      err = double(response: { status: 401 })
      monitor.connection_established = true
      expect(monitor.logger).to receive(:error).with('Authorization failed: HTTP 401')
      expect(monitor.connection_cv).to receive(:broadcast)
      monitor.handle_sse_auth_error(err)
      expect(monitor.auth_error).to eq('Authorization failed: HTTP 401')
      expect(monitor.connection_established).to be false
    end
  end

  describe '#reset_connection_state' do
    it 'resets connection_established and broadcasts' do
      monitor.connection_established = true
      expect(monitor.connection_cv).to receive(:broadcast)
      monitor.reset_connection_state
      expect(monitor.connection_established).to be false
    end
  end

  describe '#wait_for_connection' do
    context 'when auth_error is present' do
      it 'raises ConnectionError with auth_error message' do
        monitor.auth_error = 'fail auth'
        expect { monitor.wait_for_connection(timeout: 0) }
          .to raise_error(MCPClient::Errors::ConnectionError, 'fail auth')
      end
    end

    context 'when connection_established is true' do
      it 'returns without error' do
        monitor.connection_established = true
        expect { monitor.wait_for_connection(timeout: 0) }.not_to raise_error
      end
    end
  end

  describe '#setup_sse_connection' do
    it 'returns a Faraday::Connection with expected configuration' do
      uri = URI.parse('http://host:1234/path')
      conn = monitor.setup_sse_connection(uri)
      expect(conn.url_prefix.to_s).to eq('http://host:1234/')
      expect(conn.builder.handlers).to include(Faraday::Response::RaiseError)
      expect(conn.options.open_timeout).to eq(10)
      expect(conn.options.timeout).to be_nil
    end
  end
end
