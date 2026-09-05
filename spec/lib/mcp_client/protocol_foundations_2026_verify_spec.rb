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

    it 'rejects an empty supported list (no version left to retry with)' do
      expect(unsupported({ 'supported' => [], 'requested' => 'x' }).modern_protocol_error?).to be(false)
    end

    it 'rejects a supported list carrying an empty version string' do
      expect(unsupported({ 'supported' => ['2026-07-28', ''], 'requested' => 'x' }).modern_protocol_error?)
        .to be(false)
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

    it 'rejects an empty message' do
      raw = { 'code' => -32_020, 'message' => '' }
      expect(MCPClient::Errors::ServerError.from_jsonrpc(raw).modern_protocol_error?).to be(false)
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

  # Record every size argument the production code asks the gzip reader for.
  # An implementation that inflated the whole body before measuring it would
  # read with no bound (nil) — which is exactly the mutation this kills.
  def record_gzip_reads
    reads = []
    allow(Zlib::GzipReader).to receive(:new).and_wrap_original do |original, *args|
      reader = original.call(*args)
      allow(reader).to receive(:read).and_wrap_original do |original_read, *read_args|
        reads << read_args.first
        original_read.call(*read_args)
      end
      reader
    end
    reads
  end

  it 'never asks the reader for more than the bound, even for a 4 MiB expansion' do
    payload = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32022,\"message\":\"#{'x' * (4 * 1024 * 1024)}\"}}"
    expect(payload.bytesize).to be > bound
    stub_gzip_body(payload)
    reads = record_gzip_reads

    expect { send_request }.to raise_error(MCPClient::Errors::ServerError) { |e| expect(e.code).to be_nil }
    expect(reads).not_to be_empty
    expect(reads).to all(be_a(Integer))
    expect(reads.max).to be <= bound + 1
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
    expect(reads).to all(be_a(Integer))
  end
end
