# frozen_string_literal: true

require 'spec_helper'
require 'mcp_client/server_stdio/json_rpc_transport'

RSpec.describe MCPClient::ServerStdio::JsonRpcTransport do
  let(:dummy_class) do
    Class.new do
      include MCPClient::ServerStdio::JsonRpcTransport

      attr_accessor :stdin, :mutex, :cond, :pending,
                    :logger, :max_retries, :retry_backoff, :read_timeout

      def initialize
        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @pending = {}
        @next_id = 1
        @logger = Logger.new(StringIO.new)
        @stdin = StringIO.new
        @max_retries = 1
        @retry_backoff = 0.1
        @read_timeout = 0.1
        @initialized = false
      end

      def connect; end
      def start_reader; end
      def perform_initialize; end
      def call_tool(name, params); end
      def get_prompt(name, params); end
    end
  end

  subject(:transport) { dummy_class.new }

  describe '#next_id' do
    it 'increments id atomically' do
      first = transport.next_id
      expect(transport.next_id).to eq(first + 1)
    end
  end

  describe '#send_request' do
    it 'writes JSONRPC request to stdin' do
      req = { 'foo' => 'bar' }
      transport.send_request(req)
      transport.stdin.rewind
      expect(transport.stdin.read.chomp).to eq(req.to_json)
    end

    it 'raises TransportError when write fails' do
      broken = double('stdin')
      allow(broken).to receive(:puts).and_raise(StandardError, 'fail')
      transport.stdin = broken
      expect { transport.send_request('x') }
        .to raise_error(MCPClient::Errors::TransportError, /Failed to send JSONRPC request/)
    end
  end

  describe '#wait_response' do
    it 'returns and clears pending message' do
      id = 42
      transport.pending[id] = 'msg'
      expect(transport.wait_response(id)).to eq('msg')
      expect(transport.pending[id]).to be_nil
    end

    it 'raises on timeout' do
      expect { transport.wait_response(9) }
        .to raise_error(MCPClient::Errors::TransportError, /Timeout waiting for JSONRPC response id=9/)
    end
  end

  describe '#rpc_request' do
    before do
      allow(transport).to receive(:ensure_initialized)
      allow(transport).to receive(:send_request)
      allow(transport).to receive(:wait_response).and_return({ 'result' => 'ok' })
    end

    it 'sends request and returns result' do
      expect(transport.rpc_request('m', {})).to eq('ok')
    end

    it 'retries and eventually raises on errors' do
      allow(transport).to receive(:wait_response).and_raise(MCPClient::Errors::TransportError)
      expect { transport.rpc_request('m') }.to raise_error(MCPClient::Errors::TransportError)
    end
  end

  describe '#rpc_notify' do
    before { allow(transport).to receive(:ensure_initialized) }

    it 'writes notification to stdin' do
      expect(transport.stdin).to receive(:puts)
      transport.rpc_notify('notify', foo: 'bar')
    end
  end
end
