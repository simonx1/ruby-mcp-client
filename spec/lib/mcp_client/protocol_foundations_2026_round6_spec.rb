# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 protocol foundations, sixth review round: the shape check on
# a -32021 follows the published ClientCapabilities schema exactly (and no
# further), a 404 answering with a well-formed -32601 is that answer even on
# a session that carries an id, the SSE waiter hands a legacy `false` back
# promptly through the public request path, concurrent SSE waiters settle
# independently, and ServerSSE's direct JSON responses obey the same rules
# as its event stream.

# --- requiredCapabilities: exactly the schema's constraints -----------------
#
# ClientCapabilities is an open object: `elicitation` types only its `form`
# and `url` members, `sampling` only `context` and `tools`, `experimental`
# and `extensions` map names to objects, `roots` constrains nothing inside
# it, and unknown capabilities may be anything. Round 5 read more into the
# schema than it says (every elicitation member an object, roots.listChanged
# a boolean), which turned schema-valid modern rejections into "legacy" ones
# and stripped their typed interface on the way to the caller.
RSpec.describe 'a -32021 is well formed exactly when requiredCapabilities fits the schema' do
  def build(caps)
    MCPClient::Errors::ServerError.from_jsonrpc(
      'code' => -32_021, 'message' => 'Missing required client capability',
      'data' => { 'requiredCapabilities' => caps }
    )
  end

  {
    'an elicitation object with a vendor member beside form' => { 'elicitation' => { 'form' => {},
                                                                                     'vendorHint' => true } },
    'a sampling object with a scalar member the schema does not name' => { 'sampling' => { 'tools' => {},
                                                                                           'flag' => 1 } },
    'a roots object with whatever member it likes' => { 'roots' => { 'listChanged' => 'yes' } },
    'an unknown capability that is a scalar' => { 'io.example/flag' => true },
    'an empty capability set' => {}
  }.each do |description, caps|
    it "accepts #{description}" do
      error = build(caps)

      expect(error.well_formed?).to be(true)
      expect(error.modern_protocol_error?).to be(true)
      expect(error.required_capabilities).to eq(caps)
    end
  end

  {
    'an elicitation url that is not an object' => { 'elicitation' => { 'url' => 1 } },
    'a sampling context that is an array' => { 'sampling' => { 'context' => [] } },
    'a roots capability that is not an object' => { 'roots' => 1 },
    'an experimental entry that is a scalar' => { 'experimental' => { 'x' => 1 } },
    'an extension entry that is an array' => { 'extensions' => { 'io.example/t' => [] } },
    'a requiredCapabilities that is an array' => []
  }.each do |description, caps|
    it "rejects #{description}" do
      error = build(caps)

      expect(error.well_formed?).to be(false)
      expect(error.modern_protocol_error?).to be(false)
    end
  end

  # The public interface: a schema-valid -32021 reaches the caller of
  # call_tool as the typed error, with its code and capabilities readable,
  # rather than flattened into a ToolCallError message.
  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    it "keeps the typed error and its capabilities through #{klass}#call_tool" do
      caps = { 'elicitation' => { 'form' => {}, 'vendorHint' => true } }
      server = klass.new(base_url: 'https://example.com', endpoint: '/rpc', retries: 0)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      stub_request(:post, 'https://example.com/rpc').to_return do |request|
        { status: 400, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => JSON.parse(request.body)['id'],
                              'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                                           'data' => { 'requiredCapabilities' => caps } }) }
      end

      expect { server.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
          expect(e.code).to eq(-32_021)
          expect(e.required_capabilities).to eq(caps)
          expect(e.protocol_error?).to be(true)
        end
    end
  end
end

# --- 404 + well-formed -32601 answers the request, session id or not --------
#
# MCP 2025-11-25 lets a server answer 404 to a request carrying an expired
# Mcp-Session-Id, and the client then starts a new session. MCP 2026-07-28
# reports an unknown method as 404 with a well-formed -32601 body. The body
# is what tells them apart: a JSON-RPC error answering THIS request is that
# answer, not a session expiry, and restarting the session on it would send
# a fresh initialize and the very same unknown method again.
RSpec.describe 'a 404 answering a well-formed -32601 is method-not-found even on a session with an id' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  def session_server(klass)
    server = klass.new(base_url: base_url, endpoint: endpoint, retries: 0)
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@protocol_version, '2025-11-25')
    server.instance_variable_set(:@session_id, 'session-abc')
    server
  end

  def posted_methods
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys
                            .map { |signature| JSON.parse(signature.body)['method'] }
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    it "raises MethodNotFoundError without restarting the session on #{klass}" do
      server = session_server(klass)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        { status: 404, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => JSON.parse(request.body)['id'],
                              'error' => { 'code' => -32_601, 'message' => 'Method not found' }) }
      end

      expect { server.rpc_request('vendor/unknown') }
        .to raise_error(MCPClient::Errors::MethodNotFoundError) do |e|
          expect(e.code).to eq(-32_601)
          expect(e.http_status).to eq(404)
        end
      expect(posted_methods).to eq(['vendor/unknown'])
      expect(server.instance_variable_get(:@session_id)).to eq('session-abc')
    end

    it "still restarts the session on a 404 that is not a JSON-RPC answer, on #{klass}" do
      server = session_server(klass)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          { status: 200, headers: { 'Content-Type' => 'application/json', 'Mcp-Session-Id' => 'session-fresh' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                              'serverInfo' => { 'name' => 's', 'version' => '1' } }) }
        when 'notifications/initialized'
          { status: 202, body: '' }
        else
          if request.headers['Mcp-Session-Id'] == 'session-abc'
            { status: 404, headers: { 'Content-Type' => 'text/plain' }, body: 'session expired' }
          else
            { status: 200, headers: { 'Content-Type' => 'application/json' },
              body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'answered' => true }) }
          end
        end
      end

      expect(server.rpc_request('ping')).to eq({ 'answered' => true })
      expect(posted_methods.count('ping')).to eq(2)
      expect(posted_methods.count('initialize')).to eq(1)
      expect(server.instance_variable_get(:@session_id)).to eq('session-fresh')
    end
  end
end

# --- the SSE waiter and a legacy `false` -----------------------------------
#
# Round 5 pinned `false` on the result store; the waiting loop above it was
# never driven, and a loop that discards `false` and waits out the timeout
# survived every example.
RSpec.describe 'the SSE waiter hands a legacy false back through the public request path' do
  let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }
  let(:posted) { [] }

  before do
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@sse_connected, true)
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@protocol_version, '2025-11-25')
    server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
    allow(server).to receive(:connection_active?).and_return(true)
  end

  def deliver(id, result)
    body = JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result)
    server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
  end

  it 'returns false promptly, sends no cancellation and leaves nothing pending' do
    allow(server).to receive(:post_json_rpc_request) do |request|
      posted << request
      deliver(request['id'], false) if request['method'] == 'ping'
      nil
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect(server.rpc_request('ping')).to be(false)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(posted.map { |request| request['method'] }).to eq(['ping'])
    expect(server.instance_variable_get(:@sse_results)).to be_empty
    expect(server.instance_variable_get(:@pending_request_ids)).to be_empty
  end
end

# --- concurrent SSE waiters settle independently ---------------------------
RSpec.describe 'concurrent SSE waiters settle independently' do
  let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }
  let(:ids) { {} }

  before do
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@sse_connected, true)
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
    allow(server).to receive(:connection_active?).and_return(true)
    allow(server).to receive(:post_json_rpc_request) do |request|
      server.instance_variable_get(:@mutex).synchronize { ids[request['method']] = request['id'] }
      nil
    end
  end

  def deliver(id, result)
    body = JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result)
    server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
  end

  it 'raises the invalid result to its own waiter and answers the other' do
    invalid = Thread.new do
      server.rpc_request('one')
    rescue MCPClient::Errors::MCPError => e
      e
    end
    valid = Thread.new { server.rpc_request('two') }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until ids.size == 2 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    expect(ids.keys).to contain_exactly('one', 'two')

    deliver(ids['one'], { 'resultType' => 'bogus' })

    # The invalid caller finishes on its own answer while its sibling is
    # still waiting: nothing about the bad result touches the other slot.
    expect(invalid.value).to be_a(MCPClient::Errors::InvalidResultError)
    expect(valid).to be_alive
    expect(valid.join(0.2)).to be_nil

    deliver(ids['two'], { 'resultType' => 'complete', 'ok' => true })
    expect(valid.value).to eq({ 'resultType' => 'complete', 'ok' => true })
    expect(server.instance_variable_get(:@sse_results)).to be_empty
    expect(server.instance_variable_get(:@pending_request_ids)).to be_empty
  end
end

# --- ServerSSE direct JSON responses -----------------------------------------
#
# A POST to the SSE transport's message endpoint may be answered directly
# with JSON instead of over the stream; that path shares nothing with the
# event store and has to apply the same rules.
RSpec.describe 'ServerSSE direct JSON responses obey the same rules as the stream' do
  let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }

  def direct(payload)
    server.send(:parse_direct_response, double('response', body: JSON.generate({ 'jsonrpc' => '2.0',
                                                                                 'id' => 1 }.merge(payload))))
  end

  it 'raises a well-formed -32021 as the typed error' do
    caps = { 'elicitation' => { 'form' => {} } }
    expect { direct('error' => { 'code' => -32_021, 'message' => 'm', 'data' => { 'requiredCapabilities' => caps } }) }
      .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
        expect(e.modern_protocol_error?).to be(true)
        expect(e.required_capabilities).to eq(caps)
      end
  end

  it 'raises a well-formed -32022 as the typed error naming the supported versions' do
    data = { 'supported' => ['2026-07-28'], 'requested' => '2025-11-25' }
    expect { direct('error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version', 'data' => data }) }
      .to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError) do |e|
        expect(e.supported).to eq(['2026-07-28'])
        expect(e.modern_protocol_error?).to be(true)
      end
  end

  it 'rejects an unrecognized resultType on a modern session' do
    server.instance_variable_set(:@protocol_version, '2026-07-28')

    expect { direct('result' => { 'resultType' => 'bogus' }) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /bogus/)
  end

  it 'returns a complete result on a legacy session' do
    server.instance_variable_set(:@protocol_version, '2025-11-25')

    expect(direct('result' => { 'resultType' => 'complete', 'ok' => true }))
      .to eq({ 'resultType' => 'complete', 'ok' => true })
  end

  %w[2026-07-28 2025-11-25].each do |version|
    it "rejects an empty-string resultType, which is present and so not \"complete\", on #{version}" do
      server.instance_variable_set(:@protocol_version, version)

      expect { direct('result' => { 'resultType' => '' }) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /resultType ""/)
    end
  end
end

# --- an invalid result is never retried on Streamable HTTP either -----------
RSpec.describe 'an invalid result is never retried on Streamable HTTP' do
  it 'sends tools/list exactly once even with retries configured' do
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 3,
                                                 retry_backoff: 0)
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@initialized, true)
    stub_request(:post, 'https://example.com/mcp').to_return do |request|
      { status: 200,
        body: JSON.generate('jsonrpc' => '2.0', 'id' => JSON.parse(request.body)['id'],
                            'result' => { 'resultType' => 'vendor_summary', 'tools' => [] }),
        headers: { 'Content-Type' => 'application/json' } }
    end

    expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError)
    expect(a_request(:post, 'https://example.com/mcp')).to have_been_made.once
  end
end
