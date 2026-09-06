# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 protocol foundations, fifth review round: a 404 + -32601 body
# with no JSON-RPC message is malformed and identifies nobody, -32021's
# requiredCapabilities is checked against ClientCapabilities all the way
# down, and the unfinished-result guards and continuations are pinned on
# every transport through its real delivery path.

# --- 404 + -32601 needs a well-formed JSON-RPC error object ----------------
#
# Streamable HTTP backward compatibility recognizes an unknown method answered
# with HTTP 404 and a JSON-RPC -32601 body. JSON-RPC 2.0 requires the error
# object to carry a string `message`; a body without one is malformed at the
# JSON-RPC level — an intermediary's 404 page dressed as JSON-RPC, say — and
# must not be taken for the modern-server signal any more than a bare -3202x.
RSpec.describe 'a 404 + -32601 without a JSON-RPC message identifies no modern server' do
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

      it 'does not recognize a 404 + -32601 whose error object has no message' do
        error_response(404, { 'code' => -32_601 })

        expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
          expect(e.http_status).to eq(404)
          expect(e.code).to eq(-32_601)
          expect(e.modern_http_protocol_error?).to be(false)
        end
      end

      it 'does not recognize a 404 + -32601 whose message is not a string' do
        error_response(404, { 'code' => -32_601, 'message' => ['Method not found'] })

        expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
          expect(e.code).to eq(-32_601)
          expect(e.modern_http_protocol_error?).to be(false)
        end
      end

      it 'still recognizes a 404 + -32601 with an empty string message' do
        error_response(404, { 'code' => -32_601, 'message' => '' })

        expect { send_request }.to raise_error(MCPClient::Errors::ServerError) do |e|
          expect(e.modern_http_protocol_error?).to be(true)
        end
      end
    end
  end

  it 'is false straight from the factory when the message is missing, whatever the status' do
    error = MCPClient::Errors::ServerError.from_jsonrpc('code' => -32_601)
    error.http_status = 404

    expect(error.modern_http_protocol_error?).to be(false)
  end
end

# --- requiredCapabilities is ClientCapabilities all the way down -----------
#
# ClientCapabilities types its members: `elicitation` and `sampling` hold
# objects under the names the schema gives them (form/url, context/tools),
# and `experimental` and `extensions` map names to objects. Checking only
# the first level let {"elicitation": {"form": []}} claim the modern-server
# signal. (Round 6 pins the other direction: nothing beyond that is checked.)
RSpec.describe 'a -32021 is well formed only when its capability members follow the schema' do
  def build(caps)
    MCPClient::Errors::ServerError.from_jsonrpc(
      'code' => -32_021, 'message' => 'Missing required client capability',
      'data' => { 'requiredCapabilities' => caps }
    )
  end

  {
    'an elicitation mode that is an array' => { 'elicitation' => { 'form' => [] } },
    'a sampling feature that is a boolean' => { 'sampling' => { 'tools' => false } },
    'an extension entry that is an array' => { 'extensions' => { 'io.example/test' => [] } },
    'an experimental entry that is a number' => { 'experimental' => { 'x' => 1 } }
  }.each do |description, caps|
    it "rejects #{description}" do
      error = build(caps)

      expect(error.well_formed?).to be(false)
      expect(error.modern_protocol_error?).to be(false)
      # The peer's claim still reaches the caller.
      expect(error.required_capabilities).to eq(caps)
    end
  end

  {
    'nested capability objects' => { 'elicitation' => { 'form' => {}, 'url' => {} },
                                     'sampling' => { 'context' => {}, 'tools' => {} } },
    'extension and experimental objects' => { 'extensions' => { 'io.example/test' => { 'v' => 1 } },
                                              'experimental' => { 'x' => {} } },
    'a roots object, whose members the schema leaves open' => { 'roots' => { 'listChanged' => 'yes' } },
    'an unknown capability with whatever members it likes' => { 'io.example/custom' => { 'anything' => 1 } }
  }.each do |description, caps|
    it "accepts #{description}" do
      error = build(caps)

      expect(error.well_formed?).to be(true)
      expect(error.modern_protocol_error?).to be(true)
    end
  end
end

# --- the unfinished-result guards on ServerSSE and ServerStreamableHTTP ----
#
# Round 4 pinned "no wrapper flattens an unfinished result" on stdio and
# ServerHTTP only; the SSE and Streamable HTTP wrappers duplicate that code
# and their guards could be removed without a failure.
RSpec.describe 'ServerSSE and ServerStreamableHTTP surface an unfinished list or completion' do
  let(:incomplete) { { 'resultType' => 'input_required', 'requestState' => 'continue-later' } }
  let(:tool) { { 'name' => 't', 'description' => 'd', 'inputSchema' => {} } }

  shared_examples 'surfaces an unfinished list or completion' do
    it 'raises instead of returning an empty tool list' do
      answer_with([incomplete])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
        expect(e.data).to eq(incomplete)
        expect(e).not_to be_a(MCPClient::Errors::ToolCallError)
      end
    end

    it 'raises instead of returning an empty prompt list' do
      answer_with([incomplete])

      expect { server.list_prompts }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
        expect(e.data).to eq(incomplete)
      end
    end

    it 'raises instead of returning an empty resource list' do
      answer_with([incomplete])

      expect { server.list_resources }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
        expect(e.data).to eq(incomplete)
      end
    end

    it 'raises instead of returning an empty resource template list' do
      answer_with([incomplete])

      expect { server.list_resource_templates }
        .to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
        expect(e.data).to eq(incomplete)
      end
    end

    it 'raises instead of returning an empty completion' do
      answer_with([incomplete])
      request = lambda do
        server.complete(ref: { 'type' => 'ref/prompt', 'name' => 'p' }, argument: { 'name' => 'a', 'value' => '' })
      end

      expect(&request).to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
        expect(e.data).to eq(incomplete)
      end
    end

    it 'raises instead of silently dropping an unfinished second page' do
      answer_with([{ 'resultType' => 'complete', 'tools' => [tool], 'nextCursor' => 'p2' }, incomplete])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
        expect(e.data).to eq(incomplete)
      end
    end
  end

  context 'with ServerStreamableHTTP (SSE responses off the wire)' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/rpc', retries: 0) }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.instance_variable_set(:@capabilities, { 'completions' => {}, 'logging' => {} })
    end

    def answer_with(results)
      stub_request(:post, 'https://example.com/rpc').to_return do |request|
        id = JSON.parse(request.body)['id']
        payload = JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => results.shift)
        { status: 200, body: "event: message\ndata: #{payload}\n\n",
          headers: { 'Content-Type' => 'text/event-stream' } }
      end
    end

    include_examples 'surfaces an unfinished list or completion'
  end

  context 'with ServerSSE (POST -> SSE event -> result store -> waiter)' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.instance_variable_set(:@capabilities, { 'completions' => {}, 'logging' => {} })
      server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
    end

    def answer_with(results)
      allow(server).to receive(:post_json_rpc_request) do |request|
        body = JSON.generate('jsonrpc' => '2.0', 'id' => request['id'], 'result' => results.shift)
        server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
        nil
      end
    end

    include_examples 'surfaces an unfinished list or completion'
  end
end

# --- a continuation survives stdio and SSE through their real parsers ------
#
# Round 4 proved the HTTP transports accept an input_required tool/prompt
# result off the wire; stdio's reader path and the SSE result store were
# left to stubbed rpc_request examples, so rejecting every input_required
# result there left the whole suite green. The fixture is the schema's
# InputRequests wire shape: a map from identifier to request.
RSpec.describe 'an unfinished tool or prompt result survives stdio and SSE off the wire' do
  let(:city_schema) { { 'type' => 'object', 'properties' => { 'city' => { 'type' => 'string' } } } }
  # The published InputRequests wire shape: a map from server-assigned key to
  # a request object (here an ElicitRequest).
  let(:unfinished) do
    { 'resultType' => 'input_required', 'requestState' => 'continue-later',
      'inputRequests' => { 'city' => { 'method' => 'elicitation/create',
                                       'params' => { 'mode' => 'form', 'message' => 'which city?',
                                                     'requestedSchema' => city_schema } } } }
  end

  shared_examples 'accepts and preserves a continuation' do
    it 'returns the whole continuation from call_tool' do
      answer_with('result' => unfinished)

      expect(server.call_tool('t', {})).to eq(unfinished)
    end

    it 'returns the whole continuation from get_prompt' do
      answer_with('result' => unfinished)

      expect(server.get_prompt('p', {})).to eq(unfinished)
    end

    it 'keeps the InputRequests map intact' do
      answer_with('result' => unfinished)

      expect(server.call_tool('t', {})['inputRequests'].keys).to eq(['city'])
      expect(server.call_tool('t', {}).dig('inputRequests', 'city', 'method')).to eq('elicitation/create')
    end

    # "At least one of inputRequests or requestState MUST be present": a
    # continuation may carry the requests alone.
    it 'keeps a continuation that carries inputRequests without requestState' do
      stateless = unfinished.except('requestState')
      answer_with('result' => stateless)

      expect(server.call_tool('t', {})).to eq(stateless)
    end

    it 'surfaces it from read_resource with the continuation on the error data' do
      answer_with('result' => unfinished)

      expect { server.read_resource('file:///x') }
        .to raise_error(MCPClient::Errors::InvalidResultError, /input_required/) do |e|
          expect(e.data).to eq(unfinished)
        end
    end

    it 'rejects it on a session that negotiated a handshake revision' do
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      answer_with('result' => unfinished)

      expect { server.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /unrecognized resultType/)
    end
  end

  context 'with ServerStdio (line -> reader dispatch -> waiter)' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 5) }

    before do
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
    end

    def answer_with(payload)
      allow(server).to receive(:send_request) do |request|
        line = JSON.generate({ 'jsonrpc' => '2.0', 'id' => request['id'] }.merge(payload))
        server.send(:handle_line, "#{line}\n")
      end
    end

    include_examples 'accepts and preserves a continuation'
  end

  context 'with ServerSSE (POST -> SSE event -> result store -> waiter)' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
    end

    def answer_with(payload)
      allow(server).to receive(:post_json_rpc_request) do |request|
        body = JSON.generate({ 'jsonrpc' => '2.0', 'id' => request['id'] }.merge(payload))
        server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
        nil
      end
    end

    include_examples 'accepts and preserves a continuation'
  end
end

# --- the SSE result store: false is an answer, a bad answer is one waiter's -
RSpec.describe 'the SSE result store delivers false and isolates an invalid result' do
  let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }

  before do
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@protocol_version, '2025-11-25')
  end

  def deliver(id, result)
    body = JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result)
    server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
  end

  it 'delivers a legacy `result: false` as the answer rather than waiting it out' do
    server.send(:register_pending_request, 7)
    deliver(7, false)

    expect(server.send(:check_for_result, 7)).to be(false)
    expect(server.send(:check_for_result, 7)).to be(MCPClient::ServerSSE::JsonRpcTransport::NO_RESULT)
  end

  it 'raises an invalid result to its own waiter and leaves another caller outstanding' do
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:register_pending_request, 1)
    server.send(:register_pending_request, 2)
    deliver(1, { 'resultType' => 'bogus' })

    expect { server.send(:check_for_result, 1) }
      .to raise_error(MCPClient::Errors::InvalidResultError, /unrecognized resultType/)
    expect(server.send(:check_for_result, 2)).to be(MCPClient::ServerSSE::JsonRpcTransport::NO_RESULT)

    deliver(2, { 'resultType' => 'complete', 'ok' => true })
    expect(server.send(:check_for_result, 2)).to eq({ 'resultType' => 'complete', 'ok' => true })
  end
end

# --- connect surfaces the versions a modern-only server names -------------
#
# A modern-only server SHOULD name the versions it supports when rejecting
# initialize, "so this message may be the only diagnostic legacy clients
# can surface to users". Stdio surfaced them; the HTTP transports wrapped
# the typed -32022 into a generic ConnectionError whose message carried only
# the peer's prose — the list lives in `data`, not in `message`.
RSpec.describe 'HTTP connect surfaces the versions a modern-only server supports' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  before do
    stub_request(:post, "#{base_url}#{endpoint}").to_return(
      status: 400, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate('jsonrpc' => '2.0', 'id' => 1,
                          'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                       'data' => { 'supported' => ['2026-07-28'], 'requested' => '2025-11-25' } })
    )
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    it "names the supported versions and keeps the typed error as the cause on #{klass}" do
      server = klass.new(base_url: base_url, endpoint: endpoint, retries: 0)

      expect { server.connect }.to raise_error(MCPClient::Errors::ConnectionError) do |e|
        expect(e.message).to include('server supports: 2026-07-28')
        expect(e.cause).to be_a(MCPClient::Errors::UnsupportedProtocolVersionError)
        expect(e.cause.supported).to eq(['2026-07-28'])
      end
      expect(server.protocol_version).to be_nil
    end
  end
end
