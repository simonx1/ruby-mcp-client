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

  # The predicate alone: the transport that consults it to decide between a
  # modern verdict and the legacy handshake is the Streamable HTTP branch's,
  # and its examples drive the wire sequence.
  describe 'the modern-server signal a malformed error must not raise' do
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
# read_resource projects `contents` out of the result, so an unfinished result
# reaching the wrapper must surface: presenting a continuation as an empty
# successful read loses the requestState and lies about the outcome. The
# transports below stub the request layer, which pins the wrapper's own guard
# (require_complete_result!) whatever the round-trip resolver does; the stdio
# context drives the real resolver with a round trip it cannot fulfil.
RSpec.describe 'read_resource never presents an unfinished read as an empty one' do
  let(:incomplete) { { 'resultType' => 'input_required', 'requestState' => 'continue-later' } }
  let(:unfinished_message) { /input/ }

  shared_examples 'surfaces an incomplete resources/read result' do
    it 'raises instead of returning an empty content list on a modern session' do
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      stub_read_result(incomplete)

      expect { server.read_resource('file:///x.txt') }
        .to raise_error(MCPClient::Errors::InputRequiredError, unfinished_message) do |e|
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
    # The only context that reaches the round-trip resolver, so its unfinished
    # answer asks for something no handler is registered for: the round trip
    # ends on the first answer instead of being retried ten times.
    let(:incomplete) do
      { 'resultType' => 'input_required', 'requestState' => 'continue-later',
        'inputRequests' => { 'a' => { 'method' => 'elicitation/create', 'params' => { 'message' => 'Who?' } } } }
    end
    let(:unfinished_message) { /no handler is registered/ }

    # Answers exactly one resources/read; a retry finds nothing left, so an
    # unfinished read that is quietly retried fails the example rather than
    # sleeping its way to the round-trip ceiling.
    def stub_read_result(result)
      server.instance_variable_set(:@initialized, true)
      allow(server).to receive(:send_request)
      answers = [{ 'jsonrpc' => '2.0', 'id' => 1, 'result' => result }]
      allow(server).to receive(:wait_response) do
        answers.shift or raise 'resources/read was sent twice'
      end
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

  # Leave two requests in flight and take the ids off the send queue.
  # @return [Hash{String=>Integer}] request id by method
  def two_outstanding_ids(sent)
    ids = {}
    2.times do
      request = take(sent)
      ids[request['method']] = request['id']
    end
    expect(ids.keys).to contain_exactly('tools/list', 'tools/call')
    ids
  end

  shared_examples 'answers each waiter on its own' do
    it 'gives each waiter its own answer and leaves no pending state behind' do
      sent = Queue.new
      intercept_sends(sent)

      listing = Thread.new { server.list_tools }
      calling = Thread.new do
        server.call_tool('t', {})
      rescue MCPClient::Errors::ServerError => e
        e
      end

      ids = two_outstanding_ids(sent)
      answer(ids['tools/call'], 'error' => capability_error)
      answer(ids['tools/list'], 'result' => tool_listing)

      expect(listing.join(5)).not_to be_nil
      expect(calling.join(5)).not_to be_nil
      expect(listing.value.map(&:name)).to eq(['t'])
      expect(calling.value).to be_a(MCPClient::Errors::MissingRequiredClientCapabilityError)
      expect(calling.value.required_capabilities).to eq({ 'elicitation' => {} })
      expect(pending_state.values).to all(be_empty)
    end

    # The example above answers BOTH requests before joining either thread,
    # so a waiter that (wrongly) blocked until every outstanding request had
    # a response would still finish. This one holds the second answer back:
    # the answered caller must return while the other request is still in
    # flight, which is the whole point of routing responses by id.
    it 'completes the answered caller while the other request is still outstanding' do
      sent = Queue.new
      intercept_sends(sent)

      listing = Thread.new { server.list_tools }
      calling = Thread.new do
        server.call_tool('t', {})
      rescue MCPClient::Errors::ServerError => e
        e
      end

      ids = two_outstanding_ids(sent)
      answer(ids['tools/call'], 'error' => capability_error)

      # Well inside the 5s read timeout: the answer has to be delivered when
      # it arrives, not after waiting the other request out.
      expect(calling.join(2)).not_to be_nil
      expect(calling.value).to be_a(MCPClient::Errors::MissingRequiredClientCapabilityError)
      # tools/list has had no answer at all, so its caller is still waiting.
      expect(listing.join(0.2)).to be_nil

      answer(ids['tools/list'], 'result' => tool_listing)
      expect(listing.join(5)).not_to be_nil
      expect(listing.value.map(&:name)).to eq(['t'])
      expect(pending_state.values).to all(be_empty)
    end
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

    def pending_state
      { results: server.instance_variable_get(:@sse_results),
        ids: server.instance_variable_get(:@pending_request_ids) }
    end

    def intercept_sends(queue)
      allow(server).to receive(:post_json_rpc_request) { |request| queue << request and nil }
    end

    include_examples 'answers each waiter on its own'
  end

  context 'with ServerStdio (reader thread -> waiter)' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 5) }

    before { server.instance_variable_set(:@initialized, true) }

    def answer(id, payload)
      server.send(:handle_line, "#{JSON.generate({ 'jsonrpc' => '2.0', 'id' => id }.merge(payload))}\n")
    end

    def pending_state
      { pending: server.instance_variable_get(:@pending),
        awaiting: server.instance_variable_get(:@awaiting) }
    end

    def intercept_sends(queue)
      allow(server).to receive(:send_request) { |request| queue << request and nil }
    end

    include_examples 'answers each waiter on its own'
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

# --- Round 4, finding A: the optional-feature wrappers keep typed errors ----
#
# call_tool, get_prompt and read_resource re-raise a protocol error on every
# transport; completion/complete and logging/setLevel only did so on stdio.
# A -32021 is how a server names the capabilities the client omitted, so
# flattening it into a fresh ServerError (code and data nil) discards the one
# thing a host could act on. These drive the real transports: HTTP and
# Streamable HTTP off stubbed HTTP responses, SSE through its stream reader.
RSpec.describe 'complete and log_level= keep typed protocol errors on every transport' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }
  let(:capability_data) { { 'requiredCapabilities' => { 'elicitation' => { 'form' => {} } } } }
  let(:capability_error) do
    { 'code' => -32_021, 'message' => 'Missing required client capability', 'data' => capability_data }
  end

  def request_completion
    server.complete(ref: { 'type' => 'ref/prompt', 'name' => 'p' }, argument: { 'name' => 'a', 'value' => '' })
  end

  shared_examples 'never flattens a protocol error out of an optional feature' do
    it 'keeps the typed -32021 through #complete' do
      answer_with('error' => capability_error)

      expect { request_completion }.to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
        expect(e.code).to eq(-32_021)
        expect(e.data).to eq(capability_data)
        expect(e.required_capabilities).to eq({ 'elicitation' => { 'form' => {} } })
      end
    end

    it 'keeps the typed -32021 through #log_level=' do
      answer_with('error' => capability_error)

      expect { server.log_level = 'debug' }
        .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
          expect(e.code).to eq(-32_021)
          expect(e.required_capabilities).to eq({ 'elicitation' => { 'form' => {} } })
        end
    end

    it 'keeps an InvalidResultError through #complete' do
      answer_with('result' => { 'resultType' => 'partial_stream', 'completion' => { 'values' => [] } })

      expect { request_completion }.to raise_error(MCPClient::Errors::InvalidResultError, /partial_stream/) do |e|
        expect(e.protocol_error?).to be(true)
      end
    end

    it 'keeps an InvalidResultError through #log_level=' do
      answer_with('result' => { 'resultType' => 'partial_stream' })

      expect { server.log_level = 'debug' }.to raise_error(MCPClient::Errors::InvalidResultError, /partial_stream/)
    end

    it 'still wraps an ordinary application error from #complete' do
      answer_with('error' => { 'code' => -32_000, 'message' => 'boom' })

      expect { request_completion }.to raise_error(MCPClient::Errors::ServerError, /Error requesting completion/)
    end

    it 'still returns the completion of a well-formed answer' do
      answer_with('result' => { 'resultType' => 'complete', 'completion' => { 'values' => %w[a b] } })

      expect(request_completion).to eq({ 'values' => %w[a b] })
    end
  end

  context 'with ServerHTTP (JSON responses)' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@capabilities, { 'completions' => {}, 'logging' => {} })
    end

    def answer_with(payload)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        id = JSON.parse(request.body)['id']
        { status: payload.key?('error') ? 400 : 200,
          body: JSON.generate({ 'jsonrpc' => '2.0', 'id' => id }.merge(payload)),
          headers: { 'Content-Type' => 'application/json' } }
      end
    end

    include_examples 'never flattens a protocol error out of an optional feature'
  end

  context 'with ServerStreamableHTTP (SSE responses)' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@capabilities, { 'completions' => {}, 'logging' => {} })
    end

    def answer_with(payload)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        id = JSON.parse(request.body)['id']
        body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => id }.merge(payload))
        if payload.key?('error')
          { status: 400, body: body, headers: { 'Content-Type' => 'application/json' } }
        else
          { status: 200, body: "event: message\ndata: #{body}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' } }
        end
      end
    end

    include_examples 'never flattens a protocol error out of an optional feature'
  end

  context 'with ServerSSE (stream reader -> waiter)' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
      server.instance_variable_set(:@capabilities, { 'completions' => {}, 'logging' => {} })
    end

    # The id is registered before the POST, so answering inside the stubbed
    # post drives the real parser -> result store -> waiter path.
    def answer_with(payload)
      allow(server).to receive(:post_json_rpc_request) do |request|
        body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => request['id'] }.merge(payload))
        server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
        nil
      end
    end

    include_examples 'never flattens a protocol error out of an optional feature'
  end
end

# --- Round 4, finding B: 404 + -32601 identifies a modern Streamable server -
#
# Streamable HTTP backward compatibility names three answers that mean "this
# peer is modern, do not fall back to initialize / HTTP+SSE": an unsupported
# version, a header-validation failure, and an UNKNOWN METHOD returned as
# HTTP 404 with a JSON-RPC -32601 body. The first two are transport-agnostic
# reserved codes; the third is not, because on stdio a bare -32601 is exactly
# what a legacy peer answers a modern probe with. So it needs a predicate of
# its own rather than a wider code list.
RSpec.describe 'a modern Streamable HTTP server is also identified by 404 + -32601' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  def error_response(status, error)
    stub_request(:post, "#{base_url}#{endpoint}")
      .to_return(status: status, body: JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => error),
                 headers: { 'Content-Type' => 'application/json' })
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    context "with #{klass}" do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }

      def send_request
        server.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'x', 'params' => {} })
      end

      it 'recognizes an unknown method answered with 404' do
        error_response(404, { 'code' => -32_601, 'message' => 'Method not found' })

        expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
          expect(e.modern_http_protocol_error?).to be(true)
          # Still not a transport-agnostic modern signal: stdio must keep
          # falling back to initialize when a peer answers -32601.
          expect(e.modern_protocol_error?).to be(false)
          # And it is an ordinary application error for wrapping purposes.
          expect(e.protocol_error?).to be(false)
        end
      end

      it 'does not recognize -32601 on any other status' do
        error_response(400, { 'code' => -32_601, 'message' => 'Method not found' })

        expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
          expect(e.modern_http_protocol_error?).to be(false)
        end
      end

      it 'does not recognize a 404 carrying some other code' do
        error_response(404, { 'code' => -32_603, 'message' => 'Internal error' })

        expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
          expect(e.modern_http_protocol_error?).to be(false)
        end
      end

      it 'does not recognize a 404 whose body is not a JSON-RPC error response' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 404, body: '{"error":{"code":-32601,"message":"Method not found"}}',
                     headers: { 'Content-Type' => 'application/json' })

        expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
          expect(e.code).to be_nil
          expect(e.modern_http_protocol_error?).to be(false)
        end
      end

      it 'still recognizes the reserved codes it recognized before' do
        error_response(400, { 'code' => -32_020, 'message' => 'Header mismatch' })

        expect { send_request }.to raise_error(MCPClient::Errors::HeaderMismatchError) do |e|
          expect(e.modern_protocol_error?).to be(true)
          expect(e.modern_http_protocol_error?).to be(true)
        end
      end
    end
  end

  it 'is false for a -32601 that never arrived over HTTP (stdio, SSE stream)' do
    expect(MCPClient::Errors::ServerError.new('Method not found', code: -32_601)
             .modern_http_protocol_error?).to be(false)
  end
end

# --- Round 4, finding C: an SSE result of null or false IS an answer --------
#
# The SSE result store keeps whatever `result` member arrived, so a response
# of `{"result": null}` or `{"result": false}` was stored as nil/false and the
# waiter's truthiness check could not tell it from "nothing has arrived yet".
# The caller waited out its whole read timeout and sent a cancellation for a
# request the server had already answered.
RSpec.describe 'an SSE response whose result is null or false is delivered, not waited out' do
  let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 2, retries: 0) }

  before do
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@sse_connected, true)
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
  end

  def answer_with(payload)
    allow(server).to receive(:post_json_rpc_request) do |request|
      next nil if request['method'] == 'notifications/cancelled'

      body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => request['id'] }.merge(payload))
      server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
      nil
    end
  end

  it 'raises the invalid-result error for a null result on a modern session' do
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    answer_with('result' => nil)

    expect { server.send(:rpc_request, 'tools/list', {}) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /object/)
  end

  it 'raises the invalid-result error for a false result on a modern session' do
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    answer_with('result' => false)

    expect { server.send(:rpc_request, 'tools/list', {}) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /object/)
  end

  it 'never times out or cancels a request the server already answered' do
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    answer_with('result' => nil)
    cancellations = []
    allow(server).to receive(:send_cancellation_notification) { |id| cancellations << id }

    started = Time.now
    expect { server.send(:rpc_request, 'tools/list', {}) }.to raise_error(MCPClient::Errors::InvalidResultError)
    expect(Time.now - started).to be < 2
    expect(cancellations).to be_empty
  end

  it 'delivers a null result to the caller on a legacy session' do
    server.instance_variable_set(:@protocol_version, '2025-11-25')
    answer_with('result' => nil)

    expect(server.send(:rpc_request, 'logging/setLevel', {})).to be_nil
  end

  it 'still waits when nothing has arrived for the request' do
    allow(server).to receive(:post_json_rpc_request).and_return(nil)

    expect { server.send(:rpc_request, 'tools/list', {}) }
      .to raise_error(MCPClient::Errors::RequestTimeoutError)
  end
end

# --- Round 4, finding D: requiredCapabilities must BE ClientCapabilities ----
#
# The schema types -32021's data.requiredCapabilities as ClientCapabilities,
# whose members are all objects. "Is a Hash" alone let a malformed body
# ({"elicitation": []}) claim the signal that is supposed to separate a
# well-formed modern rejection from a legacy peer or an intermediary.
RSpec.describe 'a -32021 is well formed only when requiredCapabilities is ClientCapabilities' do
  def build(data)
    MCPClient::Errors::ServerError.from_jsonrpc(
      'code' => -32_021, 'message' => 'Missing required client capability', 'data' => data
    )
  end

  it 'accepts capability members that are objects' do
    error = build({ 'requiredCapabilities' => { 'elicitation' => { 'form' => {} }, 'sampling' => {} } })

    expect(error).to be_a(MCPClient::Errors::MissingRequiredClientCapabilityError)
    expect(error.modern_protocol_error?).to be(true)
    expect(error.well_formed?).to be(true)
  end

  it 'accepts an empty capability object' do
    expect(build({ 'requiredCapabilities' => {} }).modern_protocol_error?).to be(true)
  end

  it 'rejects a capability member that is an array' do
    error = build({ 'requiredCapabilities' => { 'elicitation' => [] } })

    expect(error.well_formed?).to be(false)
    expect(error.modern_protocol_error?).to be(false)
  end

  it 'rejects a capability member that is a scalar' do
    expect(build({ 'requiredCapabilities' => { 'elicitation' => true } }).modern_protocol_error?).to be(false)
    expect(build({ 'requiredCapabilities' => { 'sampling' => 'yes' } }).modern_protocol_error?).to be(false)
  end

  it 'rejects a capability member that is null' do
    expect(build({ 'requiredCapabilities' => { 'elicitation' => nil } }).modern_protocol_error?).to be(false)
  end

  it 'still rejects requiredCapabilities that is not an object at all' do
    expect(build({ 'requiredCapabilities' => [] }).modern_protocol_error?).to be(false)
    expect(build({}).modern_protocol_error?).to be(false)
  end

  it 'keeps the code and data of a malformed one for the caller to inspect' do
    error = build({ 'requiredCapabilities' => { 'elicitation' => [] } })

    expect(error.code).to eq(-32_021)
    expect(error.data).to eq({ 'requiredCapabilities' => { 'elicitation' => [] } })
    # required_capabilities still answers with the object it was handed, so a
    # host inspecting it sees the peer's claim rather than a silent {}.
    expect(error.required_capabilities).to eq({ 'elicitation' => [] })
  end
end

# --- Round 4, finding E: no wrapper flattens an unfinished result -----------
#
# MRTR permits an InputRequiredResult only on tools/call, prompts/get and
# resources/read. read_resource was pinned in round 3; every other wrapper
# that projects a field out of the result still turned an unfinished answer
# into a successful empty one -- an empty tool list, a dropped second page,
# On a method the round-trip pattern does not cover, an unfinished answer
# is malformed rather than a continuation to drive: the resolver names the
# three methods it is valid for and carries the whole answer on the error.
# or an empty completion -- discarding the requestState with it.
RSpec.describe 'no list or completion wrapper flattens an unfinished result' do
  let(:incomplete) { { 'resultType' => 'input_required', 'requestState' => 'continue-later' } }

  shared_examples 'surfaces an unfinished list or completion' do
    it 'raises instead of returning an empty tool list' do
      answer_with(incomplete)

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
        expect(e.data).to eq(incomplete)
        expect(e).not_to be_a(MCPClient::Errors::ToolCallError)
      end
    end

    it 'raises instead of returning an empty prompt list' do
      answer_with(incomplete)

      expect { server.list_prompts }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
        expect(e.data).to eq(incomplete)
        expect(e).not_to be_a(MCPClient::Errors::PromptGetError)
      end
    end

    it 'raises instead of returning an empty resource list' do
      answer_with(incomplete)

      expect { server.list_resources }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
    end

    it 'raises instead of returning an empty resource template list' do
      answer_with(incomplete)

      expect { server.list_resource_templates }
        .to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
    end

    it 'raises instead of returning an empty completion' do
      answer_with(incomplete)
      request = lambda do
        server.complete(ref: { 'type' => 'ref/prompt', 'name' => 'p' }, argument: { 'name' => 'a', 'value' => '' })
      end

      expect(&request).to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
        expect(e.data).to eq(incomplete)
      end
    end
  end

  context 'with ServerStdio' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

    before do
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.instance_variable_set(:@capabilities, { 'completions' => {}, 'logging' => {} })
      allow(server).to receive(:send_request)
    end

    def answer_with(result)
      allow(server).to receive(:wait_response).and_return({ 'jsonrpc' => '2.0', 'id' => 1, 'result' => result })
    end

    include_examples 'surfaces an unfinished list or completion'
  end

  context 'with ServerHTTP (JSON responses)' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/rpc', retries: 0) }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.instance_variable_set(:@capabilities, { 'completions' => {}, 'logging' => {} })
    end

    def answer_with(result)
      stub_request(:post, 'https://example.com/rpc').to_return do |request|
        id = JSON.parse(request.body)['id']
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end
    end

    include_examples 'surfaces an unfinished list or completion'

    it 'raises instead of silently dropping an unfinished second page' do
      tool = { 'name' => 't', 'description' => 'd', 'inputSchema' => {} }
      pages = [{ 'resultType' => 'complete', 'tools' => [tool], 'nextCursor' => 'p2' }, incomplete]
      stub_request(:post, 'https://example.com/rpc').to_return do |request|
        id = JSON.parse(request.body)['id']
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => pages.shift),
          headers: { 'Content-Type' => 'application/json' } }
      end

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/)
    end
  end
end

# --- Round 4, finding F: final-output validation waits for a finished result
#
# A tool declaring an outputSchema must carry structuredContent in a
# SUCCESSFUL result. An InputRequiredResult is not one: it carries the
# continuation instead. Running the conformance check on it raised a
# ValidationError that named the wrong problem and dropped the continuation
# in :strict mode, and logged a false conformance warning in :warn mode.
RSpec.describe 'Client#call_tool does not run output validation on an unfinished result' do
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }
  let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }
  let(:tool) do
    MCPClient::Tool.new(
      name: 'get_weather', description: 'Get weather data',
      schema: { 'type' => 'object', 'properties' => {} },
      output_schema: { 'type' => 'object', 'properties' => { 'temperature' => { 'type' => 'number' } },
                       'required' => ['temperature'] },
      server: mock_server
    )
  end
  # The built-in transports resolve a continuation themselves (the multi
  # round-trip branch) and never hand one up; a transport of the host's own
  # that does is what this pins, so the Client's output validation gate is
  # exercised directly on the published InputRequests wire shape.
  let(:unfinished) do
    { 'resultType' => 'input_required', 'requestState' => 'continue-later',
      'inputRequests' => { 'city' => { 'method' => 'elicitation/create',
                                       'params' => { 'mode' => 'form', 'message' => 'which city?',
                                                     'requestedSchema' => { 'type' => 'object' } } } } }
  end

  before do
    allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
    allow(mock_server).to receive(:on_notification)
    allow(mock_server).to receive(:list_tools).and_return([tool])
    allow(mock_server).to receive(:call_tool).and_return(unfinished)
  end

  def build_client(**opts)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger, **opts)
  end

  it 'returns the continuation untouched in :strict mode' do
    expect(build_client(validate_structured_content: :strict).call_tool('get_weather', {})).to eq(unfinished)
  end

  it 'logs no conformance warning in :warn mode' do
    expect(build_client.call_tool('get_weather', {})).to eq(unfinished)
    expect(log_output.string).not_to include('structuredContent')
  end

  it 'still validates a completed result' do
    allow(mock_server).to receive(:call_tool).and_return({ 'resultType' => 'complete', 'content' => [] })

    expect { build_client(validate_structured_content: :strict).call_tool('get_weather', {}) }
      .to raise_error(MCPClient::Errors::ValidationError, /no structuredContent/)
  end
end

# --- Round 4, finding G: an unfinished result off the real HTTP wire --------
#
# The round-3 examples stubbed rpc_request on the HTTP transports, so nothing
# proved those transports ACCEPT an input_required result at all: making them
# reject every resultType but "complete" left the whole file green. These
# drive the public operations against stubbed HTTP responses instead, and
# assert the continuation itself rather than merely that something raised.
RSpec.describe 'an unfinished result survives the HTTP transports off the wire' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }
  # The schema's InputRequests wire shape: a map from server-assigned key to
  # a request object (here an ElicitRequest).
  let(:city_request) do
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'which city?', 'requestedSchema' => { 'type' => 'object' } } }
  end
  let(:unfinished) do
    # inputRequests is a MAP of server-assigned key => request object, not a
    # list: the resolver keys its inputResponses by the same names.
    { 'resultType' => 'input_required', 'requestState' => 'continue-later',
      'inputRequests' => { 'city' => city_request } }
  end

  # Anything the operation under test needs on the way (a modern call_tool
  # reads tools/list first) answers complete, so only the call itself is
  # unfinished.
  let(:complete_list) { { 'result' => { 'resultType' => 'complete', 'tools' => [], 'prompts' => [] } } }

  shared_examples 'accepts and preserves a continuation' do
    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
    end

    # The discriminator is recognized -- this is not the "unrecognized
    # resultType" rejection -- and the whole answer, inputRequests included,
    # rides on the error so a host can drive the round trip itself. Driving
    # it is what the multi round-trip resolver above adds.
    %w[call_tool get_prompt].each do |operation|
      it "surfaces the continuation from #{operation}" do
        respond_with('result' => unfinished)

        expect { server.public_send(operation, 'x', {}) }
          .to raise_error(MCPClient::Errors::InputRequiredError, /no handler is registered/) do |e|
            expect(e.data).to eq(unfinished)
            expect(e.request_state).to eq('continue-later')
            expect(e.input_requests).to eq({ 'city' => city_request })
          end
      end
    end

    it 'surfaces it from read_resource with the continuation on the error data' do
      respond_with('result' => unfinished)

      expect { server.read_resource('file:///x') }
        .to raise_error(MCPClient::Errors::InputRequiredError, /no handler is registered/) do |e|
          expect(e.data).to eq(unfinished)
          expect(e.data['inputRequests'].keys).to eq(['city'])
        end
    end

    # A client that drives multi round-trip requests surfaces a continuation
    # it cannot fulfil as the typed error; the requests-only shape is kept whole.
    it 'keeps a continuation that carries inputRequests without requestState' do
      stateless = unfinished.except('requestState')
      respond_with('result' => stateless)

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError) do |e|
        expect(e.data).to eq(stateless)
        expect(e.input_requests).to eq({ 'city' => city_request })
        expect(e.request_state).to be_nil
      end
    end

    it 'rejects it on a session that negotiated a handshake revision' do
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      respond_with('result' => unfinished)

      # The refused result travels with the error: nothing the server sent is
      # lost, and the discovery probe reads it to tell a modern server's
      # unusable answer from a legacy endpoint's (see the Streamable HTTP
      # branch's probe).
      expect { server.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /unrecognized resultType/) do |e|
          expect(e.data).to eq(unfinished)
        end
    end
  end

  context 'with ServerHTTP (JSON responses)' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def respond_with(response)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        body = JSON.parse(request.body)
        # Only the operation under test answers unfinished: a modern call_tool
        # reads tools/list first, to derive its Mcp-Param-* headers, and a list
        # answering this way would fail before the call ever went out.
        answer = MCPClient::JsonRpcCommon::MRTR_METHODS.include?(body['method']) ? response : complete_list
        { status: 200, body: JSON.generate({ 'jsonrpc' => '2.0', 'id' => body['id'] }.merge(answer)),
          headers: { 'Content-Type' => 'application/json' } }
      end
    end

    include_examples 'accepts and preserves a continuation'
  end

  context 'with ServerStreamableHTTP (SSE responses)' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def respond_with(response)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        body = JSON.parse(request.body)
        answer = MCPClient::JsonRpcCommon::MRTR_METHODS.include?(body['method']) ? response : complete_list
        payload = JSON.generate({ 'jsonrpc' => '2.0', 'id' => body['id'] }.merge(answer))
        { status: 200, body: "event: message\ndata: #{payload}\n\n",
          headers: { 'Content-Type' => 'text/event-stream' } }
      end
    end

    include_examples 'accepts and preserves a continuation'
  end
end

# --- Round 4, finding H: SSE resource errors off the real stream ------------
#
# The era-aware not-found mapping and the unfinished-read guard were pinned
# on ServerSSE against a stubbed rpc_request, so a broken SSE error store or
# result store would not have failed them. These drive the whole path:
# POST -> registered id -> SSE event -> parser -> result store -> waiter ->
# wrapper.
RSpec.describe 'ServerSSE resource errors and unfinished reads off the stream' do
  let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }

  before do
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@sse_connected, true)
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
  end

  def answer_with(payload)
    allow(server).to receive(:post_json_rpc_request) do |request|
      body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => request['id'] }.merge(payload))
      server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
      nil
    end
  end

  it 'maps -32602 to ResourceNotFound on a modern session' do
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    answer_with('error' => { 'code' => -32_602, 'message' => 'Resource not found' })

    expect { server.read_resource('file:///missing') }
      .to raise_error(MCPClient::Errors::ResourceNotFound, %r{file:///missing})
  end

  it 'leaves -32602 a generic read error on a handshake-era session' do
    server.instance_variable_set(:@protocol_version, '2025-11-25')
    answer_with('error' => { 'code' => -32_602, 'message' => 'Invalid params' })

    expect { server.read_resource('file:///missing') }.to raise_error(MCPClient::Errors::ResourceReadError) do |e|
      expect(e).not_to be_a(MCPClient::Errors::ResourceNotFound)
    end
  end

  %w[2026-07-28 2025-11-25].each do |version|
    it "still accepts the legacy -32002 as not-found on a #{version} session" do
      server.instance_variable_set(:@protocol_version, version)
      answer_with('error' => { 'code' => -32_002, 'message' => 'Resource not found' })

      expect { server.read_resource('file:///missing') }.to raise_error(MCPClient::Errors::ResourceNotFound)
    end
  end

  it 'keeps a typed -32021 whole rather than turning it into a read error' do
    answer_with('error' => { 'code' => -32_021, 'message' => 'Missing capability',
                             'data' => { 'requiredCapabilities' => { 'elicitation' => {} } } })

    expect { server.read_resource('file:///x') }
      .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
        expect(e).not_to be_a(MCPClient::Errors::ResourceReadError)
        expect(e.required_capabilities).to eq({ 'elicitation' => {} })
      end
  end

  it 'surfaces an unfinished read with the continuation on the error data' do
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    unfinished = { 'resultType' => 'input_required', 'requestState' => 'continue-later',
                   'inputRequests' => { 'city' => { 'method' => 'elicitation/create',
                                                    'params' => { 'mode' => 'form', 'message' => 'which city?' } } } }
    answer_with('result' => unfinished)

    # The transport drives the round trip; with no handler for the request
    # it raises the typed error carrying the whole continuation.
    expect { server.read_resource('file:///x') }
      .to raise_error(MCPClient::Errors::InputRequiredError, /no handler is registered/) do |e|
        expect(e.data).to eq(unfinished)
      end
  end

  it 'still returns the contents of a completed read' do
    answer_with('result' => { 'resultType' => 'complete',
                              'contents' => [{ 'uri' => 'file:///x', 'text' => 'hi' }] })

    expect(server.read_resource('file:///x').map(&:uri)).to eq(['file:///x'])
  end
end

# --- Round 4, finding I: a 4xx other than 400/404 carries the same body -----
#
# Streamable HTTP backward compatibility lists 405 next to 400 and 404 as an
# answer a modern server can give a legacy request. The body parser covers
# the whole 4xx range; nothing pinned that.
RSpec.describe 'a JSON-RPC error body is read from any 4xx status' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    context "with #{klass}" do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }

      def send_request
        server.send(:send_http_request, { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'x', 'params' => {} })
      end

      it 'reads a typed -32022 out of a 405' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 405,
                     body: JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                                         'error' => { 'code' => -32_022, 'message' => 'Unsupported version',
                                                      'data' => { 'supported' => ['2026-07-28'],
                                                                  'requested' => '2025-11-25' } }),
                     headers: { 'Content-Type' => 'application/json' })

        expect { send_request }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
          expect(e.supported).to eq(['2026-07-28'])
          expect(e.http_status).to eq(405)
          expect(e.modern_protocol_error?).to be(true)
        end
      end

      it 'leaves a 5xx a retryable transport failure even with a JSON-RPC body' do
        stub_request(:post, "#{base_url}#{endpoint}")
          .to_return(status: 503,
                     body: JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                                         'error' => { 'code' => -32_022, 'message' => 'Unsupported version' }),
                     headers: { 'Content-Type' => 'application/json' })

        expect { send_request }.to raise_error(MCPClient::Errors::TransientServerError) do |e|
          expect(e.modern_protocol_error?).to be(false)
        end
      end
    end
  end
end

# --- Round 4, finding J: the HTTP handshake rejects a modern era ------------
#
# initialize is a handshake-era method: a server answering it with
# "2026-07-28" has not negotiated a modern session, it has answered with a
# version this client cannot speak that way. Only stdio pinned that. On the
# HTTP transports the connection must also be left unusable and the
# mandatory initialized notification must never be sent.
RSpec.describe 'the HTTP handshake refuses an initialize result naming a modern version' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  shared_examples 'refuses a modern initialize result' do
    it 'raises, stays disconnected and never sends notifications/initialized' do
      posted = respond_to_initialize_with('protocolVersion' => '2026-07-28', 'capabilities' => {},
                                          'serverInfo' => { 'name' => 's', 'version' => '1' })

      expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError, /2026-07-28/)
      # The modern probe runs first and is refused, so the handshake is what
      # answers with the version this transport cannot speak that way.
      expect(posted).to eq(%w[server/discover initialize])
      expect(server.instance_variable_get(:@initialized)).to be_falsey
      expect(server.instance_variable_get(:@connection_established)).to be_falsey
    end

    it 'still completes the handshake for a legacy version' do
      posted = respond_to_initialize_with('protocolVersion' => '2025-11-25', 'capabilities' => {},
                                          'serverInfo' => { 'name' => 's', 'version' => '1' })

      expect(server.connect).to be(true)
      expect(posted).to include('initialize', 'notifications/initialized')
    end
  end

  context 'with ServerHTTP (JSON responses)' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def respond_to_initialize_with(result)
      posted = []
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        body = JSON.parse(request.body)
        posted << body['method']
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end
      posted
    end

    include_examples 'refuses a modern initialize result'
  end

  context 'with ServerStreamableHTTP (SSE responses)' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    def respond_to_initialize_with(result)
      posted = []
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        body = JSON.parse(request.body)
        posted << body['method']
        payload = JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result)
        { status: 200, body: "event: message\ndata: #{payload}\n\n",
          headers: { 'Content-Type' => 'text/event-stream' } }
      end
      posted
    end

    include_examples 'refuses a modern initialize result'
  end
end
