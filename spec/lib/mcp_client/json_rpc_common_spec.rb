# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::JsonRpcCommon do
  # Create a test class that includes the module
  let(:test_class) do
    Class.new do
      include MCPClient::JsonRpcCommon

      attr_accessor :max_retries, :retry_backoff, :logger

      def initialize
        @max_retries = 2
        @retry_backoff = 0.01
        @logger = Logger.new(StringIO.new)
      end

      # Mock method to satisfy the ping method's dependency
      def rpc_request(_method, _params = {})
        { 'result' => 'success' }
      end
    end
  end

  let(:instance) { test_class.new }

  describe '#with_retry' do
    it 'returns the result of the block when successful' do
      result = instance.with_retry { 'success' }
      expect(result).to eq('success')
    end

    it 'retries the block on transient errors' do
      attempts = 0

      result = instance.with_retry do
        attempts += 1
        raise MCPClient::Errors::TransportError, 'Transient error' if attempts < 2

        'success after retry'
      end

      expect(attempts).to eq(2)
      expect(result).to eq('success after retry')
    end

    it 'raises the error after max_retries attempts' do
      attempts = 0

      expect do
        instance.with_retry do
          attempts += 1
          raise MCPClient::Errors::TransportError, 'Persistent error'
        end
      end.to raise_error(MCPClient::Errors::TransportError, 'Persistent error')

      expect(attempts).to eq(3) # Initial + 2 retries
    end
  end

  describe '#ping' do
    it 'calls rpc_request with ping method' do
      expect(instance).to receive(:rpc_request).with('ping').and_return('ping result')
      result = instance.ping
      expect(result).to eq('ping result')
    end
  end

  describe '#build_jsonrpc_request' do
    it 'builds a proper JSON-RPC request object' do
      request = instance.build_jsonrpc_request('test_method', { param1: 'value1' }, 123)
      expect(request).to eq({
                              'jsonrpc' => '2.0',
                              'id' => 123,
                              'method' => 'test_method',
                              'params' => { param1: 'value1' }
                            })
    end
  end

  describe '#build_jsonrpc_notification' do
    it 'builds a proper JSON-RPC notification object (no id)' do
      notification = instance.build_jsonrpc_notification('test_notification', { param1: 'value1' })
      expect(notification).to eq({
                                   'jsonrpc' => '2.0',
                                   'method' => 'test_notification',
                                   'params' => { param1: 'value1' }
                                 })
    end
  end

  describe '#initialization_params' do
    it 'returns the correct initialization parameters' do
      params = instance.initialization_params
      expect(params).to include(
        'protocolVersion' => MCPClient::PROTOCOL_VERSION,
        'capabilities' => {},
        'clientInfo' => {
          'name' => 'ruby-mcp-client',
          'version' => MCPClient::VERSION
        }
      )
    end
  end

  describe '#process_jsonrpc_response' do
    it 'returns the result field from the response' do
      response = { 'result' => { 'success' => true } }
      result = instance.process_jsonrpc_response(response)
      expect(result).to eq({ 'success' => true })
    end

    it 'raises ServerError when the response contains an error' do
      response = { 'error' => { 'message' => 'Something went wrong' } }
      expect do
        instance.process_jsonrpc_response(response)
      end.to raise_error(MCPClient::Errors::ServerError, 'Something went wrong')
    end
  end
end
