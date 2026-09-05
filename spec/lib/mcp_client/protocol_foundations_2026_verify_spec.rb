# frozen_string_literal: true

require 'spec_helper'

# Verification pass over the MCP 2026-07-28 protocol foundations.
#
# These examples pin behaviour the first round left unpinned:
# - a JSON-RPC error carried in an HTTP error body must still be recognized
#   when host-configured Faraday middleware has already parsed that body
# - only an error carrying the wire shape its schema mandates (a string
#   message, `supported: string[]`, `requested: string`) may identify a
#   modern server and suppress the legacy fallback
# - `resultType` validation runs on the REAL HTTP transports, through their
#   public operations, for both the JSON and the SSE response shape
# - typed errors keep their code, data and HTTP status through the public
#   wrappers, and reach the SSE caller through parser -> pending request ->
#   waiter rather than through a hand-called helper
# - a peer-controlled gzip error body is never inflated past the inspection
#   bound

# --- Finding 1: a parsed (middleware-decoded) HTTP error body ---------------
#
# Hosts customize the connection (faraday_config) with response middleware.
# With `conn.response :json` the body reaching the transport is a Hash, not a
# String; a 400 carrying -32022 and its data is just as valid then, and must
# not degrade to ServerError(code: nil, data: nil).
RSpec.describe 'JSON-RPC errors in an HTTP error body decoded by response middleware' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  def error_body(code, message, data = nil)
    error = { 'code' => code, 'message' => message }
    error['data'] = data if data
    JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => error)
  end

  def version_body
    error_body(-32_022, 'Unsupported protocol version',
               { 'supported' => %w[2026-07-28 2025-11-25], 'requested' => '1999-01-01' })
  end

  shared_examples 'reads a parsed JSON-RPC error body' do
    it 'raises the typed error with its data intact for a 400 carrying -32022' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 400, body: version_body, headers: { 'Content-Type' => 'application/json' })

      expect { send_request }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
        expect(e.code).to eq(-32_022)
        expect(e.supported).to eq(%w[2026-07-28 2025-11-25])
        expect(e.requested).to eq('1999-01-01')
        expect(e.data).to eq({ 'supported' => %w[2026-07-28 2025-11-25], 'requested' => '1999-01-01' })
        expect(e.http_status).to eq(400)
        expect(e.modern_protocol_error?).to be(true)
      end
    end

    it 'keeps the JSON-RPC code of a 404 whose body arrives already parsed' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 404, body: error_body(-32_601, 'Method not found'),
                   headers: { 'Content-Type' => 'application/json' })

      expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
        expect(e.code).to eq(-32_601)
        expect(e.http_status).to eq(404)
      end
    end

    it 'still ignores a parsed body that is not a JSON-RPC 2.0 error response' do
      stub_request(:post, "#{base_url}#{endpoint}")
        .to_return(status: 400, body: '{"error":{"code":-32022,"message":"blocked"}}',
                   headers: { 'Content-Type' => 'application/json' })

      expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
        expect(e.class).to eq(MCPClient::Errors::ServerError)
        expect(e.code).to be_nil
      end
    end
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    context "with #{klass} and a JSON response middleware" do
      let(:server) do
        klass.new(base_url: base_url, endpoint: endpoint, retries: 0,
                  faraday_config: ->(conn) { conn.response :json })
      end

      def send_request
        server.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'x', 'params' => {} })
      end

      include_examples 'reads a parsed JSON-RPC error body'
    end

    context "with #{klass}, raise_error and a JSON response middleware" do
      let(:server) do
        klass.new(base_url: base_url, endpoint: endpoint, retries: 0,
                  faraday_config: lambda { |conn|
                    conn.response :raise_error
                    conn.response :json
                  })
      end

      def send_request
        server.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'x', 'params' => {} })
      end

      include_examples 'reads a parsed JSON-RPC error body'
    end

    context "with #{klass} and a symbolizing JSON response middleware" do
      let(:server) do
        klass.new(base_url: base_url, endpoint: endpoint, retries: 0,
                  faraday_config: lambda { |conn|
                    conn.response :json, parser_options: { symbolize_names: true }
                  })
      end

      def send_request
        server.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'x', 'params' => {} })
      end

      it 'reads the symbol-keyed error just as well' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 400, body: version_body, headers: { 'Content-Type' => 'application/json' })

        expect { send_request }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
          expect(e.code).to eq(-32_022)
          expect(e.supported).to eq(%w[2026-07-28 2025-11-25])
          expect(e.requested).to eq('1999-01-01')
        end
      end
    end
  end
end

# --- Finding 2: modern-error recognition matches the schema's wire shape ----
#
# `modern_protocol_error?` suppresses the legacy initialize fallback, so it
# must only answer true for an error the client can actually act on: a string
# message (JSON-RPC 2.0 requires one) plus the data members the 2026-07-28
# schema mandates.
RSpec.describe 'modern protocol error recognition matches the schema wire shape' do
  def unsupported(data, message: 'Unsupported protocol version')
    error = { 'code' => -32_022 }
    error['message'] = message unless message.nil?
    error['data'] = data unless data.nil?
    MCPClient::Errors::ServerError.from_jsonrpc(error)
  end

  describe 'UnsupportedProtocolVersion data' do
    it 'rejects a supported list that is not string[]' do
      error = unsupported({ 'supported' => [42], 'requested' => '2025-11-25' })
      expect(error).to be_a(MCPClient::Errors::UnsupportedProtocolVersionError)
      expect(error.supported).to eq([])
      expect(error.modern_protocol_error?).to be(false)
      expect(error.protocol_error?).to be(false)
    end

    it 'rejects a supported list mixing strings with other types' do
      expect(unsupported({ 'supported' => ['2026-07-28', 42], 'requested' => 'x' }).modern_protocol_error?)
        .to be(false)
    end

    # The schema types these members, it does not constrain their length. A
    # server that names no mutually usable version has still identified
    # itself as modern: "no compatible version" and "not a modern server"
    # are different conditions, and conflating them would send the client
    # back to an initialize handshake this server does not implement.
    it 'accepts an empty supported list: no compatible version is still a modern rejection' do
      error = unsupported({ 'supported' => [], 'requested' => 'x' })
      expect(error.modern_protocol_error?).to be(true)
      expect(error.supported).to eq([])
    end

    it 'accepts a supported list carrying an empty version string' do
      expect(unsupported({ 'supported' => ['2026-07-28', ''], 'requested' => 'x' }).modern_protocol_error?)
        .to be(true)
    end

    it 'accepts an empty requested version' do
      expect(unsupported({ 'supported' => ['2026-07-28'], 'requested' => '' }).modern_protocol_error?).to be(true)
    end

    it 'rejects a supported member that is not an array' do
      expect(unsupported({ 'supported' => '2026-07-28', 'requested' => 'x' }).modern_protocol_error?).to be(false)
    end

    it 'rejects an absent requested member' do
      error = unsupported({ 'supported' => ['2026-07-28'] })
      expect(error.requested).to be_nil
      expect(error.modern_protocol_error?).to be(false)
    end

    it 'rejects a non-string requested member' do
      expect(unsupported({ 'supported' => ['2026-07-28'], 'requested' => 20_260_728 }).modern_protocol_error?)
        .to be(false)
    end

    it 'accepts the shape the schema defines' do
      error = unsupported({ 'supported' => ['2026-07-28'], 'requested' => '2025-11-25' })
      expect(error.modern_protocol_error?).to be(true)
      expect(error.protocol_error?).to be(true)
    end

    it 'accepts the symbol-keyed spelling of the same shape' do
      error = MCPClient::Errors::ServerError.from_jsonrpc(
        code: -32_022, message: 'v', data: { supported: ['2026-07-28'], requested: '2025-11-25' }
      )
      expect(error.modern_protocol_error?).to be(true)
    end
  end

  describe 'the JSON-RPC message member' do
    it 'does not let the substituted message stand in for a missing one' do
      error = unsupported({ 'supported' => ['2026-07-28'], 'requested' => 'x' }, message: nil)
      expect(error.message).to eq('Unknown server error')
      expect(error.modern_protocol_error?).to be(false)
      # Malformed at the JSON-RPC level: no typed class, but code and data
      # still reach the caller.
      expect(error.class).to eq(MCPClient::Errors::ServerError)
      expect(error.code).to eq(-32_022)
      expect(error.data).to eq({ 'supported' => ['2026-07-28'], 'requested' => 'x' })
    end

    it 'rejects a non-string message' do
      raw = { 'code' => -32_021, 'message' => 42, 'data' => { 'requiredCapabilities' => { 'elicitation' => {} } } }
      expect(MCPClient::Errors::ServerError.from_jsonrpc(raw).modern_protocol_error?).to be(false)
    end

    # JSON-RPC 2.0 requires `message` to be a String; it does not require it
    # to be a non-empty one, and an empty one still discriminates nothing —
    # a legacy endpoint misusing a reserved code would send prose, not "".
    it 'accepts an empty message, which JSON-RPC still counts as a string' do
      raw = { 'code' => -32_020, 'message' => '' }
      error = MCPClient::Errors::ServerError.from_jsonrpc(raw)
      expect(error).to be_a(MCPClient::Errors::HeaderMismatchError)
      expect(error.modern_protocol_error?).to be(true)
    end

    it 'accepts an empty message on an otherwise schema-valid -32022' do
      error = unsupported({ 'supported' => ['2026-07-28'], 'requested' => '2025-11-25' }, message: '')
      expect(error).to be_a(MCPClient::Errors::UnsupportedProtocolVersionError)
      expect(error.modern_protocol_error?).to be(true)
      expect(error.supported).to eq(['2026-07-28'])
    end

    it 'still recognizes -32020, which mandates no data, when the message is there' do
      expect(MCPClient::Errors::ServerError.from_jsonrpc('code' => -32_020, 'message' => 'h')
                                           .modern_protocol_error?).to be(true)
    end

    it 'requires requiredCapabilities to be an object for -32021' do
      raw = { 'code' => -32_021, 'message' => 'm', 'data' => { 'requiredCapabilities' => ['elicitation'] } }
      error = MCPClient::Errors::ServerError.from_jsonrpc(raw)
      expect(error.required_capabilities).to eq({})
      expect(error.modern_protocol_error?).to be(false)
    end
  end

  describe 'the legacy fallback a malformed error must not suppress' do
    it 'leaves a malformed -32022 out of the modern-server signal' do
      malformed = unsupported({ 'supported' => [42] })
      well_formed = unsupported({ 'supported' => ['2026-07-28'], 'requested' => 'x' })

      expect([malformed.modern_protocol_error?, well_formed.modern_protocol_error?]).to eq([false, true])
    end
  end
end

# --- Finding 3: resultType validation on the real HTTP transports -----------
#
# Disabling validate_result_type! on ServerHTTP/ServerStreamableHTTP must
# break something: these examples drive the PUBLIC operations against stubbed
# HTTP responses (JSON for ServerHTTP, SSE for ServerStreamableHTTP), so the
# guarantee is pinned end to end rather than through a mocked rpc_request.
RSpec.describe 'resultType validation on the real HTTP transports' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  shared_examples 'validates resultType through public operations' do
    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
    end

    it 'raises InvalidResultError from list_tools for an unknown discriminator' do
      respond_with('result' => { 'resultType' => 'partial_stream', 'tools' => [] })

      expect { server.list_tools }
        .to raise_error(MCPClient::Errors::InvalidResultError, /partial_stream/)
    end

    it 'raises InvalidResultError from call_tool for an unknown discriminator' do
      respond_with('result' => { 'resultType' => 'partial_stream', 'content' => [] })

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InvalidResultError) do |e|
        expect(e).not_to be_a(MCPClient::Errors::ToolCallError)
        expect(e.protocol_error?).to be(true)
      end
    end

    it 'raises InvalidResultError from read_resource for an unknown discriminator' do
      respond_with('result' => { 'resultType' => 'partial_stream', 'contents' => [] })

      expect { server.read_resource('file:///x') }.to raise_error(MCPClient::Errors::InvalidResultError)
    end

    it 'raises InvalidResultError for an explicit null resultType' do
      respond_with('result' => { 'resultType' => nil, 'tools' => [] })

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError)
    end

    it 'raises InvalidResultError for a non-string resultType' do
      respond_with('result' => { 'resultType' => 42, 'tools' => [] })

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError)
    end

    it 'accepts a complete result' do
      respond_with('result' => { 'resultType' => 'complete',
                                 'tools' => [{ 'name' => 't', 'description' => 'd', 'inputSchema' => {} }] })

      expect(server.list_tools.map(&:name)).to eq(['t'])
    end

    it 'accepts an absent resultType from an established legacy session' do
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      respond_with('result' => { 'tools' => [{ 'name' => 't', 'description' => 'd', 'inputSchema' => {} }] })

      expect(server.list_tools.map(&:name)).to eq(['t'])
    end

    it 'rejects a non-object result from an established modern session' do
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      respond_with('result' => [])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError, /object/)
    end
  end

  context 'with ServerHTTP (JSON responses)' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def respond_with(response)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        id = JSON.parse(request.body)['id']
        { status: 200, body: JSON.generate({ 'jsonrpc' => '2.0', 'id' => id }.merge(response)),
          headers: { 'Content-Type' => 'application/json' } }
      end
    end

    include_examples 'validates resultType through public operations'
  end

  context 'with ServerStreamableHTTP (SSE responses)' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def respond_with(response)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        id = JSON.parse(request.body)['id']
        payload = JSON.generate({ 'jsonrpc' => '2.0', 'id' => id }.merge(response))
        { status: 200, body: "event: message\ndata: #{payload}\n\n",
          headers: { 'Content-Type' => 'text/event-stream' } }
      end
    end

    include_examples 'validates resultType through public operations'
  end
end

# --- Finding 4d: an explicit null resultType is invalid in EITHER era -------
RSpec.describe 'an explicit null resultType is invalid in every protocol era' do
  let(:transport) do
    Class.new do
      include MCPClient::JsonRpcCommon

      attr_accessor :protocol_version

      def initialize
        @logger = Logger.new(StringIO.new)
      end
    end.new
  end

  [nil, '2025-11-25', '2026-07-28'].each do |version|
    it "rejects it when the session version is #{version.inspect}" do
      transport.protocol_version = version

      expect { transport.process_jsonrpc_response({ 'id' => 1, 'result' => { 'resultType' => nil } }) }
        .to raise_error(MCPClient::Errors::InvalidResultError)
      expect { transport.process_jsonrpc_response({ 'id' => 1, 'result' => { 'resultType' => 42 } }) }
        .to raise_error(MCPClient::Errors::InvalidResultError)
      expect { transport.process_jsonrpc_response({ 'id' => 1, 'result' => { 'resultType' => 'partial' } }) }
        .to raise_error(MCPClient::Errors::InvalidResultError)
    end
  end
end

# --- Finding 4a: the HTTP wrappers preserve every actionable field ----------
RSpec.describe 'typed errors keep code, data and HTTP status through the HTTP wrappers' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }
  let(:capability_data) { { 'requiredCapabilities' => { 'elicitation' => { 'form' => {} } } } }

  def capability_body
    JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                  'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                               'data' => capability_data })
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    context "with #{klass}" do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }
      let(:raise_error_server) do
        klass.new(base_url: base_url, endpoint: endpoint, retries: 0,
                  faraday_config: ->(conn) { conn.response :raise_error })
      end

      before do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 400, body: capability_body, headers: { 'Content-Type' => 'application/json' })
      end

      def send_request(target)
        target.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'x', 'params' => {} })
      end

      it 'preserves code, data and status on the response path' do
        expect { send_request(server) }
          .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
            expect(e.code).to eq(-32_021)
            expect(e.data).to eq(capability_data)
            expect(e.required_capabilities).to eq({ 'elicitation' => { 'form' => {} } })
            expect(e.http_status).to eq(400)
            expect(e.modern_protocol_error?).to be(true)
            expect(e.message).to include('400').and include('Missing required client capability')
          end
      end

      it 'preserves code, data and status on the raise_error middleware path' do
        expect { send_request(raise_error_server) }
          .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
            expect(e.code).to eq(-32_021)
            expect(e.data).to eq(capability_data)
            expect(e.required_capabilities).to eq({ 'elicitation' => { 'form' => {} } })
            expect(e.http_status).to eq(400)
            expect(e.modern_protocol_error?).to be(true)
          end
      end
    end
  end

  def raise_from_body(error)
    server = MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0)
    stub_request(:post, "#{base_url}#{endpoint}")
      .to_return(status: 400, body: JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => error),
                 headers: { 'Content-Type' => 'application/json' })
    server.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'x', 'params' => {} })
  end

  it 'does not let the wrapper promote an error with malformed data to a modern one' do
    expect { raise_from_body('code' => -32_022, 'message' => 'v', 'data' => { 'supported' => ['2026-07-28'] }) }
      .to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
        expect(e.code).to eq(-32_022)
        expect(e.supported).to eq(['2026-07-28'])
        expect(e.http_status).to eq(400)
        expect(e.modern_protocol_error?).to be(false)
      end
  end

  it 'does not let the wrapper promote an error with no JSON-RPC message to a modern one' do
    expect { raise_from_body('code' => -32_022, 'data' => { 'supported' => ['2026-07-28'], 'requested' => 'x' }) }
      .to raise_error(MCPClient::Errors::ServerError) do |e|
        expect(e.class).to eq(MCPClient::Errors::ServerError)
        expect(e.code).to eq(-32_022)
        expect(e.data).to eq({ 'supported' => ['2026-07-28'], 'requested' => 'x' })
        expect(e.http_status).to eq(400)
        expect(e.modern_protocol_error?).to be(false)
      end
  end
end

# --- Finding 4b: the SSE transport delivers through parser -> waiter --------
#
# The response is fed in as a raw SSE chunk, exactly as the stream reader
# would, and collected by the caller blocked in wait_for_sse_result: nothing
# is written into @sse_results by hand and no error helper is called directly.
RSpec.describe 'SSE responses reach the caller through the parser and the pending-request waiter' do
  let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 2, retries: 0) }

  before do
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@sse_connected, true)
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
  end

  # Stand in for the POST leg: the server answers on the SSE stream, so the
  # raw event chunk is handed to the wire parser while the caller waits.
  def stream_back(payload)
    allow(server).to receive(:post_json_rpc_request) do |request|
      body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => request['id'] }.merge(payload))
      server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
      nil
    end
  end

  it 'delivers a typed protocol error with its data to the waiting caller' do
    stream_back('error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                             'data' => { 'requiredCapabilities' => { 'elicitation' => {} } } })

    expect { server.call_tool('t', {}) }
      .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
        expect(e.code).to eq(-32_021)
        expect(e.required_capabilities).to eq({ 'elicitation' => {} })
        expect(e.modern_protocol_error?).to be(true)
        expect(e.message).to include('Missing required client capability').and include('-32021')
      end
  end

  it 'delivers an unsupported-version error with the versions to retry with' do
    stream_back('error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                             'data' => { 'supported' => ['2026-07-28'], 'requested' => '2025-11-25' } })

    expect { server.list_tools }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
      expect(e.supported).to eq(['2026-07-28'])
      expect(e.requested).to eq('2025-11-25')
      expect(e.modern_protocol_error?).to be(true)
    end
  end

  it 'rejects an unrecognized resultType arriving on the stream' do
    stream_back('result' => { 'resultType' => 'partial_stream', 'tools' => [] })

    expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError, /partial_stream/)
  end

  it 'rejects an explicit null resultType arriving on the stream' do
    stream_back('result' => { 'resultType' => nil, 'content' => [] })

    expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InvalidResultError)
  end

  it 'passes a complete result through' do
    stream_back('result' => { 'resultType' => 'complete', 'content' => [{ 'type' => 'text', 'text' => 'ok' }] })

    expect(server.call_tool('t', {})).to eq({ 'resultType' => 'complete',
                                              'content' => [{ 'type' => 'text', 'text' => 'ok' }] })
  end

  it 'passes a result with no resultType through (earlier-protocol server)' do
    stream_back('result' => { 'content' => [{ 'type' => 'text', 'text' => 'ok' }] })

    expect(server.call_tool('t', {})).to eq({ 'content' => [{ 'type' => 'text', 'text' => 'ok' }] })
  end
end

# --- Finding 4c: InvalidResultError propagates out of EVERY stdio method ----
RSpec.describe 'InvalidResultError propagates from every public stdio method' do
  let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

  before do
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@capabilities, { 'completions' => {}, 'logging' => {},
                                                   'resources' => { 'subscribe' => true } })
    allow(server).to receive(:send_request)
    allow(server).to receive(:wait_response).and_return(
      { 'jsonrpc' => '2.0', 'id' => 1, 'result' => { 'resultType' => 'partial_stream', 'tools' => [] } }
    )
  end

  it 'never degrades it into a ToolCallError, PromptGetError or ResourceReadError' do
    [-> { server.call_tool('t', {}) }, -> { server.list_tools }, -> { server.get_prompt('p', {}) },
     -> { server.list_prompts }, -> { server.list_resources }, -> { server.read_resource('file:///x') },
     -> { server.list_resource_templates }, -> { server.subscribe_resource('file:///x') },
     -> { server.unsubscribe_resource('file:///x') },
     -> { server.complete(ref: { 'type' => 'ref/prompt', 'name' => 'p' }, argument: { 'name' => 'a', 'value' => '' }) },
     -> { server.log_level = 'debug' }].each do |call|
      expect(&call).to raise_error(MCPClient::Errors::InvalidResultError, /partial_stream/)
    end
  end
end

# --- Finding 4e: the gzip error body is never fully inflated ----------------
RSpec.describe 'a gzip HTTP error body is decompressed within the inspection bound' do
  let(:bound) { MCPClient::JsonRpcCommon::MAX_ERROR_BODY_BYTES }
  let(:server) { MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/rpc', retries: 0) }

  def gzip(payload)
    StringIO.new.tap { |io| Zlib::GzipWriter.wrap(io) { |w| w.write(payload) } }.string
  end

  def stub_gzip_body(payload)
    stub_request(:post, 'https://example.com/rpc')
      .to_return(status: 400, body: gzip(payload),
                 headers: { 'Content-Type' => 'application/json', 'Content-Encoding' => 'gzip' })
  end

  def send_request
    server.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'x', 'params' => {} })
  end

  # Record what the production code asks the gzip reader for AND what it got
  # back. An implementation that inflated the whole body before measuring it
  # would read with no bound (nil); one that looped would stay under the
  # per-read bound while producing far more than it — both are killed here.
  # @return [Hash{Symbol=>Array<Integer, nil>}] :requested sizes, :produced bytes
  def record_gzip_reads
    reads = { requested: [], produced: [] }
    allow(Zlib::GzipReader).to receive(:new).and_wrap_original do |original, *args|
      reader = original.call(*args)
      allow(reader).to receive(:read).and_wrap_original do |original_read, *read_args|
        reads[:requested] << read_args.first
        original_read.call(*read_args).tap { |chunk| reads[:produced] << chunk.to_s.bytesize }
      end
      reader
    end
    reads
  end

  # A JSON-RPC error response whose serialization is exactly `size` bytes.
  def payload_of_size(size)
    error = { 'code' => -32_022, 'message' => '',
              'data' => { 'supported' => ['2026-07-28'], 'requested' => '2025-11-25' } }
    body = { 'jsonrpc' => '2.0', 'id' => 1, 'error' => error }
    padding = size - JSON.generate(body).bytesize
    raise ArgumentError, "cannot build a payload of #{size} bytes" if padding.negative?

    error['message'] = 'x' * padding
    JSON.generate(body)
  end

  it 'never asks the reader for more than the bound, even for a 4 MiB expansion' do
    payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"#{'x' * (4 * 1024 * 1024)}\"}}"
    expect(payload.bytesize).to be > bound
    stub_gzip_body(payload)
    reads = record_gzip_reads

    expect { send_request }.to raise_error(MCPClient::Errors::ServerError) { |e| expect(e.code).to be_nil }
    expect(reads[:requested]).not_to be_empty
    expect(reads[:requested]).to all(be_a(Integer))
    expect(reads[:requested].max).to be <= bound + 1
    # The cumulative bound, not just the per-read one: however many reads it
    # takes, the client never materializes more than the inspection ceiling.
    expect(reads[:produced].sum).to be <= bound + 1
  end

  it 'still reads a small gzip error body through the same bounded path' do
    stub_gzip_body(JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                                 'error' => { 'code' => -32_022, 'message' => 'v',
                                              'data' => { 'supported' => ['2026-07-28'],
                                                          'requested' => '2025-11-25' } }))
    reads = record_gzip_reads

    expect { send_request }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
      expect(e.supported).to eq(['2026-07-28'])
    end
    expect(reads[:requested]).to all(be_a(Integer))
    expect(reads[:produced].sum).to be <= bound + 1
  end

  it 'still parses a body that expands to exactly the bound' do
    payload = payload_of_size(bound)
    expect(payload.bytesize).to eq(bound)
    stub_gzip_body(payload)
    reads = record_gzip_reads

    expect { send_request }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
      expect(e.code).to eq(-32_022)
      expect(e.supported).to eq(['2026-07-28'])
    end
    expect(reads[:produced].sum).to eq(bound)
  end

  it 'gives up on a body one byte past the bound' do
    payload = payload_of_size(bound + 1)
    expect(payload.bytesize).to eq(bound + 1)
    stub_gzip_body(payload)

    expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
      expect(e.code).to be_nil
      expect(e.message).to include('400')
    end
  end

  it 'falls back to a plain error when the gzip body is malformed' do
    stub_request(:post, 'https://example.com/rpc')
      .to_return(status: 400, body: 'not gzip at all',
                 headers: { 'Content-Type' => 'application/json', 'Content-Encoding' => 'gzip' })

    expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
      expect(e.code).to be_nil
      expect(e).not_to be_a(MCPClient::Errors::TransientServerError)
    end
  end
end

# --- Round 3, finding A: input_required belongs to the modern era only ------
#
# `resultType` and the multi round-trip pattern that "input_required" names
# were introduced by 2026-07-28. A session that negotiated a handshake
# revision has no such pattern, so a legacy answer claiming an unfinished
# result is malformed — and must never be quietly flattened into an empty
# successful one by a wrapper that projects a field out of the result.
RSpec.describe 'input_required is a modern-era result type' do
  let(:transport) do
    Class.new do
      include MCPClient::JsonRpcCommon

      attr_accessor :protocol_version

      def initialize
        @logger = Logger.new(StringIO.new)
      end
    end.new
  end

  def process(result)
    transport.process_jsonrpc_response({ 'jsonrpc' => '2.0', 'id' => 1, 'result' => result })
  end

  it 'accepts it once a modern revision is established' do
    transport.protocol_version = '2026-07-28'
    result = { 'resultType' => 'input_required', 'requestState' => 'continue-later' }

    # The parser hands it on: the multi round-trip resolver that wraps every
    # request is what drives it to a finished answer, and what reports the
    # condition when it cannot.
    expect(process(result)).to eq(result)
    expect(transport.accepted_result_types).to include('input_required')
  end

  it 'rejects it from a session that negotiated a handshake revision' do
    transport.protocol_version = '2025-11-25'

    expect { process({ 'resultType' => 'input_required', 'requestState' => 'continue-later' }) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
    expect(transport.accepted_result_types).to eq(['complete'])
  end

  it 'rejects it before any revision is established' do
    expect { process({ 'resultType' => 'input_required' }) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
  end

  it 'still accepts a complete result in the legacy era' do
    transport.protocol_version = '2025-11-25'
    expect(process({ 'resultType' => 'complete', 'tools' => [] })).to eq({ 'resultType' => 'complete', 'tools' => [] })
  end
end

# --- Round 3, finding B: a read must never be flattened while incomplete ----
#
# read_resource projects `contents` out of the result. This client does not
# drive multi round-trip requests yet, so an InputRequiredResult reaching the
# wrapper must surface — presenting a continuation as an empty successful
# read loses the requestState and lies about the outcome.
RSpec.describe 'read_resource never presents an unfinished read as an empty one' do
  let(:incomplete) { { 'resultType' => 'input_required', 'requestState' => 'continue-later' } }

  shared_examples 'surfaces an incomplete resources/read result' do
    it 'raises instead of returning an empty content list on a modern session' do
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      stub_read_result(incomplete)

      expect { server.read_resource('file:///x.txt') }
        .to raise_error(MCPClient::Errors::InputRequiredError, /input/) do |e|
          expect(e).not_to be_a(MCPClient::Errors::ResourceReadError)
          expect(e.protocol_error?).to be(true)
          # The continuation is preserved, not discarded: a host can drive
          # the round trip itself from the opaque requestState.
          expect(e.data).to eq(incomplete)
          expect(e.request_state).to eq('continue-later')
        end
    end

    it 'still returns the contents of a completed read' do
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      stub_read_result({ 'resultType' => 'complete',
                         'contents' => [{ 'uri' => 'file:///x.txt', 'text' => 'hi' }] })

      expect(server.read_resource('file:///x.txt').map(&:uri)).to eq(['file:///x.txt'])
    end
  end

  context 'with ServerStdio' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

    def stub_read_result(result)
      server.instance_variable_set(:@initialized, true)
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response).and_return({ 'jsonrpc' => '2.0', 'id' => 1, 'result' => result })
    end

    include_examples 'surfaces an incomplete resources/read result'
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP, MCPClient::ServerSSE].each do |klass|
    context "with #{klass}" do
      let(:server) do
        if klass == MCPClient::ServerSSE
          klass.new(base_url: 'https://example.com/sse')
        else
          klass.new(base_url: 'https://example.com')
        end
      end

      def stub_read_result(result)
        allow(server).to receive(:rpc_request).and_return(result)
      end

      include_examples 'surfaces an incomplete resources/read result'
    end
  end
end

# --- Round 3, finding C: an unrecognized discriminator stays invalid --------
#
# Deliberate policy, pinned here so it cannot be relaxed by accident:
# `resultType` is a name the 2026-07-28 revision coined, so a server that
# sends one at all is 2026-aware whatever era this client believes it
# negotiated. Treating a value it does not recognize as "complete" is the
# silent-truncation failure the spec's MUST exists to prevent, so the rule
# is applied in every era — unlike the bare-array results legacy servers were
# actually observed to send, which stay tolerated.
RSpec.describe 'an unrecognized resultType is invalid in every era' do
  let(:transport) do
    Class.new do
      include MCPClient::JsonRpcCommon

      attr_accessor :protocol_version

      def initialize
        @logger = Logger.new(StringIO.new)
      end
    end.new
  end

  ['2026-07-28', '2025-11-25', '2024-11-05', nil].each do |version|
    it "rejects it with the session version #{version.inspect}" do
      transport.protocol_version = version

      expect { transport.process_jsonrpc_response({ 'id' => 1, 'result' => { 'resultType' => 'vendor_summary' } }) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /vendor_summary/)
    end
  end

  it 'reads a symbol-keyed resultType, as a symbolizing middleware would leave it' do
    expect(MCPClient::JsonRpcCommon.result_type({ resultType: 'input_required' })).to eq('input_required')
    expect(MCPClient::JsonRpcCommon.result_type({ resultType: 'vendor_summary' })).to eq('vendor_summary')

    transport.protocol_version = '2026-07-28'
    expect { transport.process_jsonrpc_response({ 'id' => 1, 'result' => { resultType: 'vendor_summary' } }) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /vendor_summary/)
    expect(transport.process_jsonrpc_response({ 'id' => 1, 'result' => { resultType: 'complete' } }))
      .to eq({ resultType: 'complete' })
  end

  it 'rejects a symbol-keyed input_required from a legacy session too' do
    transport.protocol_version = '2025-11-25'
    expect { transport.process_jsonrpc_response({ 'id' => 1, 'result' => { resultType: 'input_required' } }) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
  end
end

# --- Round 3, finding D: an invalid result is answered, never re-sent -------
#
# InvalidResultError being a ServerError is only half the guarantee; this
# drives a real request with retries configured and counts the wire sends.
RSpec.describe 'an invalid result is never retried on the wire' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  it 'sends tools/list exactly once even with retries configured' do
    server = MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 3, retry_backoff: 0)
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@initialized, true)
    stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
      { status: 200,
        body: JSON.generate('jsonrpc' => '2.0', 'id' => JSON.parse(request.body)['id'],
                            'result' => { 'resultType' => 'vendor_summary', 'tools' => [] }),
        headers: { 'Content-Type' => 'application/json' } }
    end

    expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError)
    expect(a_request(:post, "#{base_url}#{endpoint}")).to have_been_made.once
  end

  it 'still retries a 5xx for the same request, so the count means something' do
    server = MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 2, retry_backoff: 0)
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@initialized, true)
    stub_request(:post, "#{base_url}#{endpoint}").to_return(status: 503, body: 'nope')

    expect { server.list_tools }.to raise_error(MCPClient::Errors::TransientServerError)
    expect(a_request(:post, "#{base_url}#{endpoint}")).to have_been_made.times(3)
  end
end

# --- Round 3, finding E: typed errors keep their data through call_tool -----
RSpec.describe 'a typed HTTP error keeps code, data and status through the public wrappers' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }
  let(:capability_data) { { 'requiredCapabilities' => { 'elicitation' => { 'form' => {} } } } }

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    context "with #{klass}" do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }

      before do
        server.instance_variable_set(:@connection_established, true)
        server.instance_variable_set(:@initialized, true)
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 400,
                     body: JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                                         'error' => { 'code' => -32_021, 'message' => 'Missing capability',
                                                      'data' => capability_data }),
                     headers: { 'Content-Type' => 'application/json' })
      end

      it 'keeps them through call_tool rather than wrapping them in ToolCallError' do
        expect { server.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
            expect(e).not_to be_a(MCPClient::Errors::ToolCallError)
            expect(e.code).to eq(-32_021)
            expect(e.data).to eq(capability_data)
            expect(e.required_capabilities).to eq({ 'elicitation' => { 'form' => {} } })
            expect(e.http_status).to eq(400)
          end
      end

      it 'keeps them through read_resource rather than wrapping them in ResourceReadError' do
        expect { server.read_resource('file:///x') }
          .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
            expect(e).not_to be_a(MCPClient::Errors::ResourceReadError)
            expect(e.code).to eq(-32_021)
            expect(e.http_status).to eq(400)
          end
      end

      it 'keeps them through get_prompt rather than wrapping them in PromptGetError' do
        expect { server.get_prompt('p', {}) }
          .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
            expect(e).not_to be_a(MCPClient::Errors::PromptGetError)
            expect(e.data).to eq(capability_data)
            expect(e.http_status).to eq(400)
          end
      end
    end
  end
end

# --- Round 3, finding F: two outstanding requests, answered out of order ----
#
# The earlier SSE and stdio examples answer inside the mocked send, so one
# waiter is never actually blocked while another request is outstanding.
# These leave two requests in flight, answer the SECOND one first, and check
# that each answer reaches its own caller and that the pending bookkeeping is
# emptied either way.
RSpec.describe 'two outstanding requests are answered independently and out of order' do
  # Take one posted request, failing loudly instead of blocking forever.
  def take(queue)
    deadline = Time.now + 5
    loop do
      begin
        return queue.pop(true)
      rescue ThreadError
        raise 'no request was sent within 5s' if Time.now > deadline
      end
      sleep 0.01
    end
  end

  let(:capability_error) do
    { 'code' => -32_021, 'message' => 'Missing required client capability',
      'data' => { 'requiredCapabilities' => { 'elicitation' => {} } } }
  end
  let(:tool_listing) do
    { 'resultType' => 'complete', 'tools' => [{ 'name' => 't', 'description' => 'd', 'inputSchema' => {} }] }
  end

  context 'with ServerSSE (stream reader -> waiter)' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
    end

    def answer(id, payload)
      body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => id }.merge(payload))
      server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
    end

    it 'gives each waiter its own answer and leaves no pending state behind' do
      sent = Queue.new
      allow(server).to receive(:post_json_rpc_request) { |request| sent << request and nil }

      listing = Thread.new { server.list_tools }
      calling = Thread.new do
        server.call_tool('t', {})
      rescue MCPClient::Errors::ServerError => e
        e
      end

      ids = {}
      2.times do
        request = take(sent)
        ids[request['method']] = request['id']
      end
      expect(ids.keys).to contain_exactly('tools/list', 'tools/call')

      answer(ids['tools/call'], 'error' => capability_error)
      answer(ids['tools/list'], 'result' => tool_listing)

      expect(listing.join(5)).not_to be_nil
      expect(calling.join(5)).not_to be_nil
      expect(listing.value.map(&:name)).to eq(['t'])
      expect(calling.value).to be_a(MCPClient::Errors::MissingRequiredClientCapabilityError)
      expect(calling.value.required_capabilities).to eq({ 'elicitation' => {} })
      expect(server.instance_variable_get(:@sse_results)).to be_empty
      expect(server.instance_variable_get(:@pending_request_ids)).to be_empty
    end
  end

  context 'with ServerStdio (reader thread -> waiter)' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 5) }

    before { server.instance_variable_set(:@initialized, true) }

    def answer(id, payload)
      server.send(:handle_line, "#{JSON.generate({ 'jsonrpc' => '2.0', 'id' => id }.merge(payload))}\n")
    end

    it 'gives each waiter its own answer and leaves no pending state behind' do
      sent = Queue.new
      allow(server).to receive(:send_request) { |request| sent << request and nil }

      listing = Thread.new { server.list_tools }
      calling = Thread.new do
        server.call_tool('t', {})
      rescue MCPClient::Errors::ServerError => e
        e
      end

      ids = {}
      2.times do
        request = take(sent)
        ids[request['method']] = request['id']
      end
      expect(ids.keys).to contain_exactly('tools/list', 'tools/call')

      answer(ids['tools/call'], 'error' => capability_error)
      answer(ids['tools/list'], 'result' => tool_listing)

      expect(listing.join(5)).not_to be_nil
      expect(calling.join(5)).not_to be_nil
      expect(listing.value.map(&:name)).to eq(['t'])
      expect(calling.value).to be_a(MCPClient::Errors::MissingRequiredClientCapabilityError)
      expect(calling.value.required_capabilities).to eq({ 'elicitation' => {} })
      expect(server.instance_variable_get(:@pending)).to be_empty
      expect(server.instance_variable_get(:@awaiting)).to be_empty
    end
  end
end

# --- Round 3, finding G: resource errors and pages off the real wire --------
#
# The resource-not-found mapping and the discriminator check are exercised
# here against stubbed HTTP responses (JSON for ServerHTTP, SSE for
# ServerStreamableHTTP) rather than a mocked rpc_request, and across a
# paginated list where only the SECOND page is malformed.
RSpec.describe 'resource errors and paginated results off the wire' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  shared_examples 'maps wire-level resource errors' do
    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
    end

    it 'maps a modern -32602 to ResourceNotFound' do
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      respond_with('error' => { 'code' => -32_602, 'message' => 'No such resource' })

      expect { server.read_resource('file:///gone') }
        .to raise_error(MCPClient::Errors::ResourceNotFound, %r{file:///gone})
    end

    it 'keeps a legacy -32602 a ResourceReadError' do
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      respond_with('error' => { 'code' => -32_602, 'message' => 'Invalid params' })

      expect { server.read_resource('file:///gone') }
        .to raise_error(MCPClient::Errors::ResourceReadError, /Invalid params/) do |e|
          expect(e).not_to be_a(MCPClient::Errors::ResourceNotFound)
        end
    end

    it 'maps the legacy -32002 to ResourceNotFound in either era' do
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      respond_with('error' => { 'code' => -32_002, 'message' => 'Resource not found' })

      expect { server.read_resource('file:///gone') }.to raise_error(MCPClient::Errors::ResourceNotFound)
    end

    it 'treats an absent resultType as complete on a modern session too' do
      # "clients MUST treat an absent resultType as 'complete'" is a
      # backward-compatibility rule, not a legacy-only one.
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      respond_with('result' => { 'contents' => [{ 'uri' => 'file:///x', 'text' => 'hi' }] })

      expect(server.read_resource('file:///x').map(&:uri)).to eq(['file:///x'])
    end

    it 'rejects an unrecognized discriminator on a later pagination page' do
      pages = [
        { 'result' => { 'resultType' => 'complete', 'nextCursor' => 'page-2',
                        'tools' => [{ 'name' => 'first', 'description' => 'd', 'inputSchema' => {} }] } },
        { 'result' => { 'resultType' => 'vendor_summary',
                        'tools' => [{ 'name' => 'second', 'description' => 'd', 'inputSchema' => {} }] } }
      ]
      respond_in_sequence(pages)

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError, /vendor_summary/)
    end
  end

  context 'with ServerHTTP (JSON responses)' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def encode(id, payload)
      { status: 200, body: JSON.generate({ 'jsonrpc' => '2.0', 'id' => id }.merge(payload)),
        headers: { 'Content-Type' => 'application/json' } }
    end

    def respond_with(payload)
      stub_request(:post, "#{base_url}#{endpoint}").to_return { |r| encode(JSON.parse(r.body)['id'], payload) }
    end

    def respond_in_sequence(payloads)
      remaining = payloads.dup
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        encode(JSON.parse(request.body)['id'], remaining.shift || payloads.last)
      end
    end

    include_examples 'maps wire-level resource errors'
  end

  context 'with ServerStreamableHTTP (SSE responses)' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def encode(id, payload)
      body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => id }.merge(payload))
      { status: 200, body: "event: message\ndata: #{body}\n\n",
        headers: { 'Content-Type' => 'text/event-stream' } }
    end

    def respond_with(payload)
      stub_request(:post, "#{base_url}#{endpoint}").to_return { |r| encode(JSON.parse(r.body)['id'], payload) }
    end

    def respond_in_sequence(payloads)
      remaining = payloads.dup
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        encode(JSON.parse(request.body)['id'], remaining.shift || payloads.last)
      end
    end

    include_examples 'maps wire-level resource errors'
  end
end
