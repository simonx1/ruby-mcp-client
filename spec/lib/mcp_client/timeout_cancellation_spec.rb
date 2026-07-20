# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 basic/lifecycle — Timeouts:
# - "When the request has not received a success or error response within the
#   timeout period, the sender SHOULD issue a cancellation notification for
#   that request and stop waiting for a response."
# - "The initialize request MUST NOT be cancelled by clients" (cancellation
#   utility).
# - "SDKs and other middleware SHOULD allow these timeouts to be configured
#   on a per-request basis."
# A timed-out (possibly still-executing, non-idempotent) request must also
# not be silently re-sent by the retry layer.
RSpec.describe 'Request timeouts and cancellation (MCP 2025-11-25)' do
  describe 'stdio transport' do
    let(:stdin_lines) { [] }
    let(:stdin_double) { double('stdin').tap { |d| allow(d).to receive(:puts) { |l| stdin_lines << l } } }
    let(:server) do
      MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 0.05, retries: 2).tap do |s|
        s.instance_variable_set(:@initialized, true)
        s.instance_variable_set(:@stdin, stdin_double)
      end
    end

    it 'raises RequestTimeoutError and sends notifications/cancelled for the abandoned request' do
      expect { server.rpc_request('tools/list', {}) }.to raise_error(MCPClient::Errors::RequestTimeoutError)

      cancelled = stdin_lines.map { |l| JSON.parse(l) }.find { |m| m['method'] == 'notifications/cancelled' }
      expect(cancelled).not_to be_nil
      expect(cancelled['params']['requestId']).to eq(1)
      expect(cancelled['params']['reason']).to match(/timed out|timeout/i)
    end

    it 'does not re-send a timed-out request despite configured retries' do
      expect { server.rpc_request('tools/list', {}) }.to raise_error(MCPClient::Errors::RequestTimeoutError)

      sent = stdin_lines.map { |l| JSON.parse(l) }.select { |m| m['method'] == 'tools/list' }
      expect(sent.size).to eq(1)
    end

    it 'does not send a cancellation for a timed-out initialize' do
      allow(server).to receive(:connect)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      server.instance_variable_set(:@initialized, false)

      expect { server.send(:perform_initialize) }.to raise_error(MCPClient::Errors::RequestTimeoutError)
      cancelled = stdin_lines.map { |l| JSON.parse(l) }.find { |m| m['method'] == 'notifications/cancelled' }
      expect(cancelled).to be_nil
    end

    it 'honors a per-request timeout override' do
      expect(server).to receive(:wait_response).with(1, timeout: 7).and_return({ 'result' => {} })

      server.rpc_request('tools/list', {}, timeout: 7)
    end
  end

  describe 'HTTP transports' do
    let(:base_url) { 'https://example.com' }
    let(:server) do
      MCPClient::ServerHTTP.new(base_url: base_url, endpoint: '/rpc', retries: 2).tap do |s|
        s.instance_variable_set(:@connection_established, true)
        s.instance_variable_set(:@initialized, true)
      end
    end

    it 'maps a Faraday timeout to RequestTimeoutError and sends notifications/cancelled' do
      conn = double('conn')
      allow(server).to receive(:http_connection).and_return(conn)
      calls = []
      allow(conn).to receive(:post) do |_endpoint, &blk|
        req = Struct.new(:headers, :body, :options).new({}, nil, Struct.new(:timeout).new(nil))
        blk&.call(req)
        body = req.body && JSON.parse(req.body)
        calls << body
        raise Faraday::TimeoutError, 'execution expired' if body && body['method'] == 'tools/list'

        Struct.new(:status, :headers, :body, :success?).new(202, {}, '', true)
      end

      expect { server.rpc_request('tools/list', {}) }.to raise_error(MCPClient::Errors::RequestTimeoutError)

      cancelled = calls.compact.find { |m| m['method'] == 'notifications/cancelled' }
      expect(cancelled).not_to be_nil
      expect(cancelled['params']['reason']).to match(/timed out|timeout/i)

      list_posts = calls.compact.select { |m| m['method'] == 'tools/list' }
      expect(list_posts.size).to eq(1)
    end

    it 'applies a per-request timeout to the outgoing request' do
      captured_options = nil
      conn = double('conn')
      allow(server).to receive(:http_connection).and_return(conn)
      allow(conn).to receive(:post) do |_endpoint, &blk|
        req = Struct.new(:headers, :body, :options).new({}, nil, Struct.new(:timeout).new(nil))
        blk&.call(req)
        captured_options = req.options
        Struct.new(:status, :headers, :body, :success?).new(
          200, { 'content-type' => 'application/json' },
          JSON.generate(jsonrpc: '2.0', id: 1, result: {}), true
        )
      end

      server.rpc_request('tools/list', {}, timeout: 42)

      expect(captured_options.timeout).to eq(42)
    end
  end

  describe 'SSE transport' do
    let(:server) do
      MCPClient::ServerSSE.new(base_url: 'https://example.com/sse').tap do |s|
        s.instance_variable_set(:@initialized, true)
        s.instance_variable_set(:@connection_established, true)
        s.instance_variable_set(:@sse_connected, true)
      end
    end

    it 'sends notifications/cancelled when a request times out' do
      allow(server).to receive(:connection_active?).and_return(true)
      allow(server).to receive(:post_json_rpc_request) do |msg|
        raise MCPClient::Errors::RequestTimeoutError, 'Timeout waiting for SSE result' if msg['id']

        nil
      end

      expect { server.rpc_request('tools/list', {}) }.to raise_error(MCPClient::Errors::RequestTimeoutError)

      expect(server).to have_received(:post_json_rpc_request).with(
        hash_including('method' => 'notifications/cancelled')
      )
    end

    it 'raises RequestTimeoutError when the SSE result never arrives' do
      allow(server).to receive(:connection_active?).and_return(true)

      expect do
        server.send(:wait_for_result_with_timeout, 99, Time.now - 60, 1)
      end.to raise_error(MCPClient::Errors::RequestTimeoutError)
    end
  end

  describe 'Client#send_rpc per-request timeout' do
    it 'forwards the timeout to the server transport' do
      srv = double('server', name: 's')
      allow(srv).to receive(:rpc_request).with('x/y', { 'a' => 1 }, timeout: 9).and_return({})
      client = MCPClient::Client.new
      client.instance_variable_set(:@servers, [srv])

      client.send_rpc('x/y', params: { 'a' => 1 }, timeout: 9)

      expect(srv).to have_received(:rpc_request).with('x/y', { 'a' => 1 }, timeout: 9)
    end
  end

  describe 'Client cancellation notification recognition' do
    it 'handles notifications/cancelled without treating it as unknown' do
      client = MCPClient::Client.new
      logger = client.instance_variable_get(:@logger)
      srv = double('server', name: 's')

      expect(logger).not_to receive(:debug).with(/Unknown notification/)
      allow(logger).to receive(:debug)

      client.send(:process_notification, srv, 'notifications/cancelled',
                  { 'requestId' => 5, 'reason' => 'user cancelled' })
    end
  end
end
