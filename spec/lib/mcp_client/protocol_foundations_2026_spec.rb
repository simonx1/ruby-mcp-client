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
      it 'raises ResourceNotFound for -32602 (Invalid params) on a modern session' do
        server.instance_variable_set(:@protocol_version, '2026-07-28')
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

# Every response path validates resultType, not only rpc_request: the SSE
# transport delivers stored results through check_for_result, and the stdio
# initialize handshake reads its result directly.
RSpec.describe 'resultType validation on every transport response path' do
  it 'rejects an unrecognized resultType delivered through the SSE result store' do
    server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
    server.instance_variable_get(:@mutex).synchronize do
      server.instance_variable_get(:@sse_results)[7] = { 'resultType' => 'bogus', 'tools' => [] }
    end

    expect { server.send(:check_for_result, 7) }.to raise_error(MCPClient::Errors::InvalidResultError)
  end

  it 'rejects an unrecognized resultType on the stdio initialize result' do
    server = MCPClient::ServerStdio.new(command: 'echo test')
    allow(server).to receive(:next_id).and_return(1)
    allow(server).to receive(:send_request)
    allow(server).to receive(:wait_response).and_return(
      { 'result' => { 'resultType' => 'bogus', 'protocolVersion' => '2025-11-25', 'capabilities' => {} } }
    )

    expect { server.send(:perform_initialize) }.to raise_error(MCPClient::Errors::ConnectionError, /resultType/)
  end

  it 'reports a stdio initialize error response as a ConnectionError carrying the message' do
    server = MCPClient::ServerStdio.new(command: 'echo test')
    allow(server).to receive(:next_id).and_return(1)
    allow(server).to receive(:send_request)
    allow(server).to receive(:wait_response).and_return(
      { 'error' => { 'code' => -32_602, 'message' => 'bad init' } }
    )

    expect { server.send(:perform_initialize) }
      .to raise_error(MCPClient::Errors::ConnectionError, /Initialize failed: bad init/)
  end
end

# MCP 2026-07-28 Streamable HTTP: the spec-defined protocol errors travel in
# the body of an HTTP 400 (HeaderMismatch, UnsupportedProtocolVersion,
# MissingRequiredClientCapability) and an unknown method is a 404 carrying
# -32601. A dual-era client must read those bodies: a recognized modern
# error identifies a modern server, and must not be mistaken for a legacy
# rejection.
RSpec.describe 'typed JSON-RPC errors carried in HTTP error bodies' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  def error_body(code, message, data = nil)
    error = { 'code' => code, 'message' => message }
    error['data'] = data if data
    JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => error)
  end

  shared_examples 'parses JSON-RPC errors out of HTTP error responses' do
    it 'raises UnsupportedProtocolVersionError for a 400 carrying -32022' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 400, body: error_body(-32_022, 'Unsupported protocol version',
                                                 { 'supported' => ['2026-07-28'], 'requested' => 'x' }),
                   headers: { 'Content-Type' => 'application/json' })

      expect { send_request }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
        expect(e.code).to eq(-32_022)
        expect(e.supported).to eq(['2026-07-28'])
        expect(e.modern_protocol_error?).to be(true)
        expect(e.message).to include('400').and include('Unsupported protocol version')
      end
    end

    it 'raises HeaderMismatchError for a 400 carrying -32020' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 400, body: error_body(-32_020, 'Header mismatch'),
                   headers: { 'Content-Type' => 'application/json' })

      expect { send_request }.to raise_error(MCPClient::Errors::HeaderMismatchError)
    end

    it 'raises MissingRequiredClientCapabilityError for a 400 carrying -32021' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 400, body: error_body(-32_021, 'Missing capability',
                                                 { 'requiredCapabilities' => { 'elicitation' => {} } }),
                   headers: { 'Content-Type' => 'application/json' })

      expect { send_request }.to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
        expect(e.required_capabilities).to eq({ 'elicitation' => {} })
      end
    end

    it 'keeps the JSON-RPC code of a 404 carrying -32601 (unknown method on a modern server)' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 404, body: error_body(-32_601, 'Method not found'),
                   headers: { 'Content-Type' => 'application/json' })

      expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
        expect(e.code).to eq(-32_601)
        expect(e.modern_protocol_error?).to be(false)
      end
    end

    it 'raises a plain ServerError without a code for a 400 with no JSON-RPC body' do
      stub_request(:post, "#{base_url}#{endpoint}").to_return(status: 400, body: 'Bad Request')

      expect { send_request }.to raise_error(MCPClient::Errors::ServerError, /\b400\b/) do |e|
        expect(e.code).to be_nil
      end
    end

    it 'raises a plain ServerError for a 400 whose JSON body is not a JSON-RPC error' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 400, body: '{"detail":"nope"}', headers: { 'Content-Type' => 'application/json' })

      expect { send_request }.to raise_error(MCPClient::Errors::ServerError) { |e| expect(e.code).to be_nil }
    end

    it 'does not turn a 5xx into a typed error (it stays retryable)' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 503, body: error_body(-32_022, 'x'), headers: { 'Content-Type' => 'application/json' })

      expect { send_request }.to raise_error(MCPClient::Errors::TransientServerError)
    end
  end

  context 'with ServerStreamableHTTP' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def send_request
      server.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'initialize', 'params' => {} })
    end

    include_examples 'parses JSON-RPC errors out of HTTP error responses'

    it 'decodes a gzip-encoded error body' do
      body = StringIO.new.tap { |io| Zlib::GzipWriter.wrap(io) { |gz| gz.write(error_body(-32_022, 'v')) } }.string
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 400, body: body,
                   headers: { 'Content-Type' => 'application/json', 'Content-Encoding' => 'gzip' })

      expect { send_request }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError)
    end
  end

  context 'with ServerHTTP' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def send_request
      server.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'initialize', 'params' => {} })
    end

    include_examples 'parses JSON-RPC errors out of HTTP error responses'
  end

  context 'with ServerSSE (POST leg)' do
    let(:endpoint) { '/messages' }
    let(:server) { MCPClient::ServerSSE.new(base_url: "#{base_url}/sse", retries: 0) }

    def send_request
      server.instance_variable_set(:@rpc_endpoint, endpoint)
      server.send(:post_json_rpc_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'initialize', 'params' => {} })
    end

    include_examples 'parses JSON-RPC errors out of HTTP error responses'
  end
end

RSpec.describe 'resource-not-found mapping is protocol-era aware' do
  # On a legacy (2025-11-25 and earlier) session -32602 is plain Invalid
  # params — not found was -32002 — so only a modern server's -32602 means
  # the resource does not exist.
  it 'treats -32602 as not found only on modern sessions' do
    expect(MCPClient::Errors::Codes.resource_not_found_code?(-32_602, modern: true)).to be(true)
    expect(MCPClient::Errors::Codes.resource_not_found_code?(-32_602, modern: false)).to be(false)
    expect(MCPClient::Errors::Codes.resource_not_found_code?(-32_002, modern: true)).to be(true)
    expect(MCPClient::Errors::Codes.resource_not_found_code?(-32_002, modern: false)).to be(true)
  end

  it 'keeps a legacy server -32602 as ResourceReadError' do
    server = MCPClient::ServerHTTP.new(base_url: 'https://example.com')
    server.instance_variable_set(:@protocol_version, '2025-11-25')
    allow(server).to receive(:rpc_request).and_raise(MCPClient::Errors::ServerError.new('Invalid params',
                                                                                        code: -32_602))

    expect { server.read_resource('file:///x') }.to raise_error(MCPClient::Errors::ResourceReadError, /Invalid params/)
  end

  it 'maps a modern server -32602 to ResourceNotFound' do
    server = MCPClient::ServerHTTP.new(base_url: 'https://example.com')
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    allow(server).to receive(:rpc_request).and_raise(MCPClient::Errors::ServerError.new('Resource not found',
                                                                                        code: -32_602))

    expect { server.read_resource('file:///x') }.to raise_error(MCPClient::Errors::ResourceNotFound)
  end

  it 'exposes the protocol era on every transport' do
    server = MCPClient::ServerStdio.new(command: 'echo')
    expect(server.protocol_version).to be_nil
    expect(server.modern?).to be(false)
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    expect(server.modern?).to be(true)
  end
end

RSpec.describe 'initialize handshake against the modern era' do
  it 'disconnects when a server answers initialize with a modern (per-request metadata) version' do
    server = MCPClient::ServerStdio.new(command: 'echo test')
    allow(server).to receive(:next_id).and_return(1)
    allow(server).to receive(:send_request)
    allow(server).to receive(:wait_response).and_return(
      { 'result' => { 'protocolVersion' => '2026-07-28', 'capabilities' => {} } }
    )
    expect(server).to receive(:cleanup)

    expect { server.send(:perform_initialize) }
      .to raise_error(MCPClient::Errors::ConnectionError, /2026-07-28/)
  end

  it 'names the versions a modern-only server advertises when it rejects initialize' do
    server = MCPClient::ServerStdio.new(command: 'echo test')
    allow(server).to receive(:next_id).and_return(1)
    allow(server).to receive(:send_request)
    allow(server).to receive(:wait_response).and_return(
      { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                     'data' => { 'supported' => %w[2026-07-28 2027-01-01], 'requested' => '2025-11-25' } } }
    )

    expect { server.send(:perform_initialize) }
      .to raise_error(MCPClient::Errors::ConnectionError, /server supports: 2026-07-28, 2027-01-01/)
  end
end
