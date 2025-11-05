# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCPClient::ServerStdio, 'Elicitation (MCP 2025-06-18)' do
  let(:command) { ['python', 'test_server.py'] }
  let(:server) { described_class.new(command: command) }
  let(:stdin_mock) { StringIO.new }
  let(:stdout_mock) { StringIO.new }
  let(:stderr_mock) { StringIO.new }
  let(:wait_thread_mock) { double('wait_thread', pid: 12_345, alive?: true) }

  before do
    allow(Open3).to receive(:popen3).and_return([stdin_mock, stdout_mock, stderr_mock, wait_thread_mock])
    allow(Process).to receive(:kill)
    server.instance_variable_set(:@stdin, stdin_mock)
    server.instance_variable_set(:@stdout, stdout_mock)
    server.instance_variable_set(:@stderr, stderr_mock)
    server.instance_variable_set(:@wait_thread, wait_thread_mock)
    server.instance_variable_set(:@initialized, true)
  end

  describe '#on_elicitation_request' do
    it 'registers an elicitation callback' do
      callback = ->(_request_id, _params) { { 'action' => 'accept' } }
      server.on_elicitation_request(&callback)
      expect(server.instance_variable_get(:@elicitation_request_callback)).to eq(callback)
    end
  end

  describe '#handle_server_request' do
    let(:request_id) { 123 }
    let(:params) do
      {
        'message' => 'Enter your name:',
        'requestedSchema' => {
          'type' => 'object',
          'properties' => {
            'name' => { 'type' => 'string' }
          }
        }
      }
    end

    context 'when method is elicitation/create' do
      let(:message) do
        {
          'id' => request_id,
          'method' => 'elicitation/create',
          'params' => params
        }
      end

      it 'calls handle_elicitation_create' do
        expect(server).to receive(:handle_elicitation_create).with(request_id, params)
        server.handle_server_request(message)
      end
    end

    context 'when method is unknown' do
      let(:message) do
        {
          'id' => request_id,
          'method' => 'unknown/method',
          'params' => {}
        }
      end

      it 'sends error response for unknown method' do
        expect(server).to receive(:send_error_response).with(request_id, -32_601, 'Method not found: unknown/method')
        server.handle_server_request(message)
      end
    end

    context 'when an exception occurs' do
      let(:message) do
        {
          'id' => request_id,
          'method' => 'elicitation/create',
          'params' => params
        }
      end

      it 'sends error response for internal error' do
        allow(server).to receive(:handle_elicitation_create).and_raise(StandardError, 'Test error')
        expect(server).to receive(:send_error_response).with(request_id, -32_603, 'Internal error: Test error')
        server.handle_server_request(message)
      end
    end
  end

  describe '#handle_elicitation_create' do
    let(:request_id) { 123 }
    let(:params) do
      {
        'message' => 'Enter your name:',
        'requestedSchema' => {
          'type' => 'object',
          'properties' => {
            'name' => { 'type' => 'string' }
          }
        }
      }
    end

    context 'when no callback is registered' do
      it 'sends decline response' do
        expect(server).to receive(:send_elicitation_response).with(request_id, { 'action' => 'decline' })
        server.handle_elicitation_create(request_id, params)
      end

      it 'logs a warning' do
        allow(server).to receive(:send_elicitation_response)
        logger = server.instance_variable_get(:@logger)
        expect(logger).to receive(:warn).with('Received elicitation request but no callback registered, declining')
        server.handle_elicitation_create(request_id, params)
      end
    end

    context 'when callback is registered' do
      let(:callback_result) { { 'action' => 'accept', 'content' => { 'name' => 'John' } } }

      before do
        callback = ->(_req_id, _params) { callback_result }
        server.on_elicitation_request(&callback)
      end

      it 'calls the registered callback' do
        callback = lambda do |req_id, prms|
          expect(req_id).to eq(request_id)
          expect(prms).to eq(params)
          callback_result
        end
        server.on_elicitation_request(&callback)

        allow(server).to receive(:send_elicitation_response)
        server.handle_elicitation_create(request_id, params)
      end

      it 'sends the callback result as response' do
        expect(server).to receive(:send_elicitation_response).with(request_id, callback_result)
        server.handle_elicitation_create(request_id, params)
      end
    end
  end

  describe '#send_elicitation_response' do
    let(:request_id) { 123 }
    let(:result) { { 'action' => 'accept', 'content' => { 'name' => 'John' } } }

    it 'sends JSON-RPC response with result' do
      expected_response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'result' => result
      }

      expect(server).to receive(:send_message).with(expected_response)
      server.send_elicitation_response(request_id, result)
    end
  end

  describe '#send_error_response' do
    let(:request_id) { 123 }
    let(:error_code) { -32_601 }
    let(:error_message) { 'Method not found' }

    it 'sends JSON-RPC error response' do
      expected_response = {
        'jsonrpc' => '2.0',
        'id' => request_id,
        'error' => {
          'code' => error_code,
          'message' => error_message
        }
      }

      expect(server).to receive(:send_message).with(expected_response)
      server.send_error_response(request_id, error_code, error_message)
    end
  end

  describe '#send_message' do
    it 'writes JSON to stdin and flushes' do
      message = { 'test' => 'data' }
      server.send_message(message)

      stdin_mock.rewind
      written_data = stdin_mock.read
      expect(written_data).to eq("#{JSON.generate(message)}\n")
    end

    context 'when an error occurs' do
      it 'logs the error' do
        allow(stdin_mock).to receive(:puts).and_raise(StandardError, 'Write error')
        logger = server.instance_variable_get(:@logger)
        expect(logger).to receive(:error).with('Error sending message: Write error')

        server.send_message({ 'test' => 'data' })
      end
    end
  end

  describe '#handle_line' do
    context 'with server request (has id and method)' do
      it 'dispatches to handle_server_request' do
        message = {
          'id' => 123,
          'method' => 'elicitation/create',
          'params' => { 'message' => 'Test' }
        }

        stdout_mock.puts(JSON.generate(message))
        stdout_mock.rewind

        expect(server).to receive(:handle_server_request).with(message)
        server.handle_line(stdout_mock.readline)
      end
    end

    context 'with notification (has method, no id)' do
      it 'calls notification callback' do
        message = {
          'method' => 'notifications/test',
          'params' => { 'data' => 'value' }
        }

        callback = double('callback')
        server.instance_variable_set(:@notification_callback, callback)

        expect(callback).to receive(:call).with('notifications/test', { 'data' => 'value' })
        server.handle_line(JSON.generate(message))
      end

      it 'does not dispatch to handle_server_request' do
        message = {
          'method' => 'notifications/test',
          'params' => {}
        }

        expect(server).not_to receive(:handle_server_request)
        server.handle_line(JSON.generate(message))
      end
    end

    context 'with response (has id, no method)' do
      it 'stores in pending responses' do
        message = {
          'id' => 123,
          'result' => { 'success' => true }
        }

        server.handle_line(JSON.generate(message))
        pending = server.instance_variable_get(:@pending)
        expect(pending[123]).to eq(message)
      end

      it 'does not dispatch to handle_server_request' do
        message = {
          'id' => 123,
          'result' => {}
        }

        expect(server).not_to receive(:handle_server_request)
        server.handle_line(JSON.generate(message))
      end
    end
  end

  describe 'integration: full elicitation flow' do
    it 'handles complete request-response cycle' do
      # Setup callback
      user_response = { 'action' => 'accept', 'content' => { 'name' => 'Alice' } }
      server.on_elicitation_request do |_req_id, params|
        expect(params['message']).to eq('Enter your name:')
        user_response
      end

      # Server sends elicitation request
      request_message = {
        'id' => 456,
        'method' => 'elicitation/create',
        'params' => {
          'message' => 'Enter your name:',
          'requestedSchema' => {
            'type' => 'object',
            'properties' => {
              'name' => { 'type' => 'string' }
            }
          }
        }
      }

      # Client processes and responds
      server.handle_line(JSON.generate(request_message))

      # Verify response was sent to stdin
      stdin_mock.rewind
      written_data = stdin_mock.read
      response = JSON.parse(written_data)

      expect(response['jsonrpc']).to eq('2.0')
      expect(response['id']).to eq(456)
      expect(response['result']).to eq(user_response)
    end
  end
end
