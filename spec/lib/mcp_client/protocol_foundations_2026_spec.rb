# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 base-protocol foundations (basic/index.mdx):
# - protocol version constants for the modern (per-request metadata) era
# - the error-code allocation policy and the three spec-defined codes
#   (-32020 HeaderMismatch, -32021 MissingRequiredClientCapability,
#   -32022 UnsupportedProtocolVersion), surfaced as typed errors
# - the required `resultType` field: absent means "complete" (older servers),
#   unrecognized values MUST be considered invalid
# - resource not found is -32602 (Invalid params); -32002 is still accepted
RSpec.describe 'MCP 2026-07-28 protocol foundations' do
  describe 'protocol version constants' do
    it 'names 2026-07-28 as the latest protocol version' do
      expect(MCPClient::LATEST_PROTOCOL_VERSION).to eq('2026-07-28')
    end

    it 'lists 2026-07-28 among the modern (per-request metadata) versions' do
      expect(MCPClient::MODERN_PROTOCOL_VERSIONS).to include('2026-07-28')
    end

    it 'keeps every initialize-handshake revision in the legacy set' do
      expect(MCPClient::LEGACY_PROTOCOL_VERSIONS).to eq(%w[2025-11-25 2025-06-18 2025-03-26 2024-11-05])
    end

    it 'supports the union of modern and legacy versions' do
      expect(MCPClient::SUPPORTED_PROTOCOL_VERSIONS)
        .to match_array(MCPClient::MODERN_PROTOCOL_VERSIONS + MCPClient::LEGACY_PROTOCOL_VERSIONS)
    end

    it 'keeps PROTOCOL_VERSION (the initialize request version) on the latest legacy revision' do
      expect(MCPClient::PROTOCOL_VERSION).to eq('2025-11-25')
      expect(MCPClient::LEGACY_PROTOCOL_VERSIONS.first).to eq(MCPClient::PROTOCOL_VERSION)
    end
  end

  describe 'error codes' do
    it 'defines the codes reserved by the 2026-07-28 specification' do
      expect(MCPClient::Errors::Codes::HEADER_MISMATCH).to eq(-32_020)
      expect(MCPClient::Errors::Codes::MISSING_REQUIRED_CLIENT_CAPABILITY).to eq(-32_021)
      expect(MCPClient::Errors::Codes::UNSUPPORTED_PROTOCOL_VERSION).to eq(-32_022)
    end

    it 'defines the standard JSON-RPC codes' do
      expect(MCPClient::Errors::Codes::PARSE_ERROR).to eq(-32_700)
      expect(MCPClient::Errors::Codes::INVALID_REQUEST).to eq(-32_600)
      expect(MCPClient::Errors::Codes::METHOD_NOT_FOUND).to eq(-32_601)
      expect(MCPClient::Errors::Codes::INVALID_PARAMS).to eq(-32_602)
      expect(MCPClient::Errors::Codes::INTERNAL_ERROR).to eq(-32_603)
    end

    it 'recognizes exactly the spec-defined modern codes' do
      expect(MCPClient::Errors::Codes.modern_error_code?(-32_020)).to be(true)
      expect(MCPClient::Errors::Codes.modern_error_code?(-32_021)).to be(true)
      expect(MCPClient::Errors::Codes.modern_error_code?(-32_022)).to be(true)
      # Reserved for the spec but not (yet) defined: unknown to this client.
      expect(MCPClient::Errors::Codes.modern_error_code?(-32_023)).to be(false)
      # Legacy sub-range and standard JSON-RPC codes are not "modern".
      expect(MCPClient::Errors::Codes.modern_error_code?(-32_001)).to be(false)
      expect(MCPClient::Errors::Codes.modern_error_code?(-32_601)).to be(false)
      expect(MCPClient::Errors::Codes.modern_error_code?(nil)).to be(false)
    end

    it 'treats -32602 and the legacy -32002 as resource-not-found codes' do
      expect(MCPClient::Errors::Codes.resource_not_found_code?(-32_602)).to be(true)
      expect(MCPClient::Errors::Codes.resource_not_found_code?(-32_002)).to be(true)
      expect(MCPClient::Errors::Codes.resource_not_found_code?(-32_603)).to be(false)
    end
  end

  describe MCPClient::Errors::ServerError do
    it 'still accepts a bare message' do
      error = described_class.new('boom')
      expect(error.message).to eq('boom')
      expect(error.code).to be_nil
      expect(error.data).to be_nil
    end

    it 'carries the JSON-RPC error code and data' do
      error = described_class.new('bad', code: -32_602, data: { 'uri' => 'file:///x' })
      expect(error.code).to eq(-32_602)
      expect(error.data).to eq({ 'uri' => 'file:///x' })
    end

    describe '.from_jsonrpc' do
      it 'builds an UnsupportedProtocolVersionError exposing supported and requested versions' do
        error = described_class.from_jsonrpc(
          'code' => -32_022, 'message' => 'Unsupported protocol version',
          'data' => { 'supported' => %w[2026-07-28 2025-11-25], 'requested' => '1900-01-01' }
        )
        expect(error).to be_a(MCPClient::Errors::UnsupportedProtocolVersionError)
        expect(error).to be_a(described_class)
        expect(error.code).to eq(-32_022)
        expect(error.supported).to eq(%w[2026-07-28 2025-11-25])
        expect(error.requested).to eq('1900-01-01')
        expect(error.message).to eq('Unsupported protocol version')
      end

      it 'tolerates an UnsupportedProtocolVersionError without data' do
        error = described_class.from_jsonrpc('code' => -32_022, 'message' => 'nope')
        expect(error.supported).to eq([])
        expect(error.requested).to be_nil
      end

      it 'builds a MissingRequiredClientCapabilityError exposing the required capabilities' do
        error = described_class.from_jsonrpc(
          'code' => -32_021, 'message' => 'Missing required client capability',
          'data' => { 'requiredCapabilities' => { 'elicitation' => {} } }
        )
        expect(error).to be_a(MCPClient::Errors::MissingRequiredClientCapabilityError)
        expect(error.required_capabilities).to eq({ 'elicitation' => {} })
      end

      it 'defaults required capabilities to an empty object when data is absent' do
        error = described_class.from_jsonrpc('code' => -32_021, 'message' => 'missing')
        expect(error.required_capabilities).to eq({})
      end

      it 'builds a HeaderMismatchError for -32020' do
        error = described_class.from_jsonrpc('code' => -32_020, 'message' => 'Header mismatch')
        expect(error).to be_a(MCPClient::Errors::HeaderMismatchError)
        expect(error.code).to eq(-32_020)
      end

      it 'builds a plain ServerError for any other code, keeping code and data' do
        error = described_class.from_jsonrpc('code' => -32_601, 'message' => 'Method not found', 'data' => 'x')
        expect(error.class).to eq(described_class)
        expect(error.code).to eq(-32_601)
        expect(error.data).to eq('x')
        expect(error.message).to eq('Method not found')
      end

      it 'copes with a malformed error object' do
        expect(described_class.from_jsonrpc(nil).message).to eq('Unknown server error')
        expect(described_class.from_jsonrpc('code' => 'x').code).to be_nil
      end

      it 'reports whether the error is a recognized modern protocol error' do
        expect(described_class.from_jsonrpc('code' => -32_022, 'message' => 'v').modern_protocol_error?).to be(true)
        expect(described_class.from_jsonrpc('code' => -32_601, 'message' => 'm').modern_protocol_error?).to be(false)
      end
    end
  end

  describe 'JSON-RPC response processing' do
    let(:transport) do
      Class.new do
        include MCPClient::JsonRpcCommon

        def initialize
          @logger = Logger.new(StringIO.new)
        end
      end.new
    end

    it 'raises the typed error for a modern error response' do
      response = { 'jsonrpc' => '2.0', 'id' => 1,
                   'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                'data' => { 'supported' => ['2026-07-28'], 'requested' => 'x' } } }
      expect { transport.process_jsonrpc_response(response) }
        .to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) { |e| expect(e.supported).to eq(['2026-07-28']) }
    end

    it 'keeps the code on a plain error response' do
      response = { 'jsonrpc' => '2.0', 'id' => 1, 'error' => { 'code' => -32_602, 'message' => 'Resource not found' } }
      expect { transport.process_jsonrpc_response(response) }
        .to raise_error(MCPClient::Errors::ServerError, 'Resource not found') { |e| expect(e.code).to eq(-32_602) }
    end

    it 'returns a result whose resultType is "complete"' do
      result = { 'resultType' => 'complete', 'tools' => [] }
      expect(transport.process_jsonrpc_response({ 'id' => 1, 'result' => result })).to eq(result)
    end

    it 'treats an absent resultType as "complete" (earlier-protocol servers)' do
      result = { 'tools' => [] }
      expect(transport.process_jsonrpc_response({ 'id' => 1, 'result' => result })).to eq(result)
      expect(MCPClient::JsonRpcCommon.result_type(result)).to eq('complete')
    end

    it 'passes through an "input_required" result for the caller to handle' do
      result = { 'resultType' => 'input_required', 'requestState' => 'blob' }
      expect(transport.process_jsonrpc_response({ 'id' => 1, 'result' => result })).to eq(result)
      expect(MCPClient::JsonRpcCommon.result_type(result)).to eq('input_required')
    end

    it 'rejects an unrecognized resultType as an invalid response' do
      result = { 'resultType' => 'bogus' }
      expect { transport.process_jsonrpc_response({ 'id' => 1, 'result' => result }) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /resultType.*bogus/)
    end

    it 'rejects a non-string resultType' do
      expect { transport.process_jsonrpc_response({ 'id' => 1, 'result' => { 'resultType' => 42 } }) }
        .to raise_error(MCPClient::Errors::InvalidResultError)
    end

    it 'lets a transport widen the accepted result types (extensions)' do
      transport.define_singleton_method(:accepted_result_types) { %w[complete input_required task] }
      result = { 'resultType' => 'task', 'taskId' => 't1' }
      expect(transport.process_jsonrpc_response({ 'id' => 1, 'result' => result })).to eq(result)
    end

    it 'is lenient with non-object results from older servers' do
      expect(transport.process_jsonrpc_response({ 'id' => 1, 'result' => [] })).to eq([])
      expect(MCPClient::JsonRpcCommon.result_type([])).to eq('complete')
    end

    it 'InvalidResultError is a ServerError, so it is never retried as transient' do
      expect(MCPClient::Errors::InvalidResultError).to be < MCPClient::Errors::ServerError
      expect(MCPClient::Errors::InvalidResultError).not_to be < MCPClient::Errors::TransientServerError
    end
  end

  describe 'resource not found mapping' do
    shared_examples 'maps resource-not-found codes' do
      it 'raises ResourceNotFound for -32602 (Invalid params)' do
        stub_read_error(-32_602, 'Resource not found')
        expect { server.read_resource('file:///missing.txt') }
          .to raise_error(MCPClient::Errors::ResourceNotFound, %r{file:///missing.txt.*Resource not found})
      end

      it 'raises ResourceNotFound for the legacy -32002 code' do
        stub_read_error(-32_002, 'Resource not found')
        expect { server.read_resource('file:///missing.txt') }.to raise_error(MCPClient::Errors::ResourceNotFound)
      end

      it 'keeps other server errors as ResourceReadError' do
        stub_read_error(-32_603, 'Internal error')
        expect { server.read_resource('file:///missing.txt') }
          .to raise_error(MCPClient::Errors::ResourceReadError, /Internal error/)
      end
    end

    context 'with ServerStdio' do
      let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

      def stub_read_error(code, message)
        server.instance_variable_set(:@initialized, true)
        allow(server).to receive(:send_request)
        allow(server).to receive(:wait_response).and_return(
          { 'jsonrpc' => '2.0', 'id' => 1, 'error' => { 'code' => code, 'message' => message } }
        )
      end

      include_examples 'maps resource-not-found codes'
    end

    context 'with ServerHTTP' do
      let(:server) { MCPClient::ServerHTTP.new(base_url: 'https://example.com') }

      def stub_read_error(code, message)
        allow(server).to receive(:rpc_request).and_raise(MCPClient::Errors::ServerError.new(message, code: code))
      end

      include_examples 'maps resource-not-found codes'
    end

    context 'with ServerStreamableHTTP' do
      let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com') }

      def stub_read_error(code, message)
        allow(server).to receive(:rpc_request).and_raise(MCPClient::Errors::ServerError.new(message, code: code))
      end

      include_examples 'maps resource-not-found codes'
    end

    context 'with ServerSSE' do
      let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse') }

      def stub_read_error(code, message)
        allow(server).to receive(:rpc_request).and_raise(MCPClient::Errors::ServerError.new(message, code: code))
      end

      include_examples 'maps resource-not-found codes'
    end
  end

  describe 'stdio error responses' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

    it 'surfaces the JSON-RPC error code from rpc_request' do
      server.instance_variable_set(:@initialized, true)
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response).and_return(
        { 'jsonrpc' => '2.0', 'id' => 1,
          'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                       'data' => { 'requiredCapabilities' => { 'elicitation' => {} } } } }
      )

      expect { server.rpc_request('tools/call', { name: 'x' }) }
        .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
          expect(e.required_capabilities).to eq({ 'elicitation' => {} })
        end
    end

    it 'rejects an unrecognized resultType on list responses' do
      server.instance_variable_set(:@initialized, true)
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response).and_return(
        { 'jsonrpc' => '2.0', 'id' => 1, 'result' => { 'resultType' => 'weird', 'tools' => [] } }
      )

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /resultType/)
    end
  end

  describe 'SSE error responses' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse') }

    it 'surfaces the JSON-RPC error code' do
      error = { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                'data' => { 'supported' => ['2026-07-28'], 'requested' => 'x' } }
      expect { server.send(:raise_sse_error_response, error) }
        .to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
          expect(e.code).to eq(-32_022)
          expect(e.supported).to eq(['2026-07-28'])
          expect(e.message).to eq('Unsupported protocol version (code -32022)')
        end
    end
  end
end
