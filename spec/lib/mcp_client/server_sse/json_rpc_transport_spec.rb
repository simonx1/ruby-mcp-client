# frozen_string_literal: true

require 'spec_helper'
require 'mcp_client/server_sse/json_rpc_transport'

RSpec.describe MCPClient::ServerSSE::JsonRpcTransport do
  let(:dummy_class) do
    Class.new do
      include MCPClient::ServerSSE::JsonRpcTransport

      attr_accessor :headers, :logger, :base_url, :rpc_endpoint, :rpc_conn, :read_timeout, :max_retries,
                    :retry_backoff, :use_sse

      def initialize
        @headers = {}
        @logger = Logger.new(StringIO.new)
        @base_url = 'http://example.com'
        @rpc_endpoint = '/rpc'
        @read_timeout = 1
        @max_retries = 0
        @retry_backoff = 0
        @use_sse = false
      end

      def record_activity; end
      def connection_active? = true
      def cleanup; end
      def connect; end
      def perform_initialize; end
    end
  end

  subject(:transport) { dummy_class.new }

  describe '#send_http_request' do
    let(:conn) { instance_double(Faraday::Connection) }

    it 'sets JSON headers and returns the response' do
      resp = instance_double(Faraday::Response, status: 200, reason_phrase: 'OK', success?: true, body: '{"x":1}')
      expect(conn).to receive(:post).with('/rpc') do |&block|
        req = double('req')
        allow(req).to receive(:headers).and_return({})
        allow(req).to receive(:body=)
        block.call(req)
        expect(req.headers['Content-Type']).to eq('application/json')
        expect(req.headers['Accept']).to eq('application/json')
      end.and_return(resp)

      expect(transport.send(:send_http_request, conn, '/rpc', { foo: 'bar' })).to eq(resp)
    end

    it 'logs without body when response has no body method' do
      resp = instance_double(Faraday::Response, status: 202, success?: true)
      allow(transport.logger).to receive(:debug)
      allow(conn).to receive(:post).and_return(resp)
      transport.send(:send_http_request, conn, '/rpc', { foo: 'bar' })
      expect(transport.logger).to have_received(:debug).with('Received JSON-RPC response: 202')
    end
  end

  describe '#rpc_notify' do
    before { allow(transport).to receive(:ensure_initialized) }

    it 'wraps server and connection errors in TransportError' do
      allow(transport).to receive(:post_json_rpc_request).and_raise(Faraday::ConnectionFailed.new('fail'))
      expect do
        transport.rpc_notify('m', {})
      end.to raise_error(MCPClient::Errors::TransportError, /Failed to send notification/)
    end
  end

  describe '#parse_direct_response' do
    it 'parses JSON and returns result key' do
      resp = double('resp', body: '{"result":{"ok":true}}')
      expect(transport.send(:parse_direct_response, resp)).to eq({ 'ok' => true })
    end

    it 'raises TransportError for invalid JSON' do
      resp = double('resp', body: '{bad}')
      expect { transport.send(:parse_direct_response, resp) }.to raise_error(MCPClient::Errors::TransportError)
    end
  end

  describe '#check_for_result' do
    it 'returns and deletes available result' do
      transport.instance_variable_set(:@mutex, Mutex.new)
      transport.instance_variable_set(:@sse_results, { 1 => 'v' })
      expect(transport.send(:check_for_result, 1)).to eq('v')
      expect(transport.instance_variable_get(:@sse_results)).to be_empty
    end

    it 'returns nil when no result' do
      transport.instance_variable_set(:@mutex, Mutex.new)
      transport.instance_variable_set(:@sse_results, {})
      expect(transport.send(:check_for_result, 2)).to be_nil
    end
  end
end
