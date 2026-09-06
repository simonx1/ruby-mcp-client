# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'zlib'
require 'stringio'

# MCP 2026-07-28 Streamable HTTP modern mode, sixth review round:
# - a gzip body that lost only its footer still delivered its answer, and a
#   delivered answer settles the request (re-issuing would run it again);
# - the readers that inflate a gzip body as it arrives, and the salvage of a
#   compressed answer, never allocate past the configured expansion bound.
RSpec.describe 'MCP 2026-07-28 Streamable HTTP — round 6' do
  let(:url) { 'https://example.com/mcp' }
  let(:discover_result) do
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
  end
  let(:server) do
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                        max_decompressed_body_bytes: 1024)
  end

  before { stub_request(:get, url).to_return(status: 405, body: '') }
  after { server.cleanup }

  def gzip(text)
    StringIO.new.tap { |io| Zlib::GzipWriter.wrap(io) { |gz| gz.write(text) } }.string
  end

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  # Every POST answered by method; returns the bodies seen.
  def stub_posts(responders)
    seen = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      seen << body
      responder = responders.fetch(body['method'])
      responder.respond_to?(:call) ? responder.call(body) : json_response(body['id'], responder)
    end
    seen
  end

  def gzip_response(bytes, content_type)
    { status: 200, body: bytes, headers: { 'Content-Type' => content_type, 'Content-Encoding' => 'gzip' } }
  end

  def sse_event(message)
    "event: message\ndata: #{JSON.generate(message)}\n\n"
  end

  describe 'a gzip body missing only its footer' do
    # The eight footer bytes carry a CRC and a length; the deflate stream
    # before them is complete, so the final SSE event was delivered in
    # full. That is a delivered answer, not a lost in-flight request.
    it 'settles a tools/call with the result it delivered instead of re-issuing it' do
      event = sse_event('jsonrpc' => '2.0', 'id' => 'whatever', 'result' => { 'content' => [] })
      requests = stub_posts(
        'server/discover' => discover_result,
        'tools/call' => lambda do |body|
          compressed = gzip(sse_event('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] }))
          gzip_response(compressed[0, compressed.bytesize - 8], 'text/event-stream')
        end
      )
      expect(event).to include('data:')

      expect(server.call_tool('t', {})).to eq({ 'content' => [] })
      expect(requests.count { |r| r['method'] == 'tools/call' }).to eq(1)
    end

    it 'raises the JSON-RPC error it delivered instead of re-issuing the request' do
      requests = stub_posts(
        'server/discover' => discover_result,
        'tools/call' => lambda do |body|
          compressed = gzip(sse_event('jsonrpc' => '2.0', 'id' => body['id'],
                                      'error' => { 'code' => -32_000, 'message' => 'tool exploded' }))
          gzip_response(compressed[0, compressed.bytesize - 8], 'text/event-stream')
        end
      )

      expect { server.rpc_request('tools/call', { 'name' => 't', 'arguments' => {} }) }
        .to raise_error(MCPClient::Errors::ServerError, /tool exploded/) do |error|
          expect(error).not_to be_a(MCPClient::Errors::ResponseStreamClosedError)
        end
      expect(requests.count { |r| r['method'] == 'tools/call' }).to eq(1)
    end

    it 'settles a request answered with a plain JSON body the same way' do
      requests = stub_posts(
        'server/discover' => discover_result,
        'tools/call' => lambda do |body|
          compressed = gzip(JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] }))
          gzip_response(compressed[0, compressed.bytesize - 8], 'application/json')
        end
      )

      expect(server.call_tool('t', {})).to eq({ 'content' => [] })
      expect(requests.count { |r| r['method'] == 'tools/call' }).to eq(1)
    end

    # The socket path has the same rule (verify spec); here the loss is one
    # the gzip decoder reports rather than the socket.
    it 'still re-issues a request whose deflate data stops short of the final event' do
      calls = 0
      requests = stub_posts(
        'server/discover' => discover_result,
        'tools/call' => lambda do |body|
          calls += 1
          compressed = gzip(sse_event('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] }))
          bytes = calls == 1 ? compressed[0, compressed.bytesize - 24] : compressed
          gzip_response(bytes, 'text/event-stream')
        end
      )

      expect(server.call_tool('t', {})).to eq({ 'content' => [] })
      tool_calls = requests.select { |r| r['method'] == 'tools/call' }
      expect(tool_calls.size).to eq(2)
      expect(tool_calls[0]['id']).not_to eq(tool_calls[1]['id'])
    end

    it 'treats a body whose footer CRC is wrong as a bad response, not a broken stream' do
      requests = stub_posts(
        'server/discover' => discover_result,
        'tools/call' => lambda do |body|
          compressed = gzip(sse_event('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'content' => [] })).b
          at = compressed.bytesize - 6
          compressed[at] = (compressed.getbyte(at) ^ 0xFF).chr
          gzip_response(compressed, 'text/event-stream')
        end
      )

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::TransportError) do |error|
        expect(error).not_to be_a(MCPClient::Errors::ResponseStreamClosedError)
      end
      expect(requests.count { |r| r['method'] == 'tools/call' }).to eq(1)
    end
  end

  # 2026-07-28 removed SSE resumability: an event id on a modern response
  # stream is not a cursor, is never retained and never sent back.
  describe 'event ids on a modern response stream' do
    it 'neither retains nor echoes them' do
      headers = []
      stub_request(:post, url).to_return do |request|
        headers << request.headers
        body = JSON.parse(request.body)
        if body['method'] == 'server/discover'
          json_response(body['id'], discover_result)
        else
          event = "id: evt-1\nevent: message\ndata: #{JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                                                    'result' => { 'content' => [] })}\n\n"
          { status: 200, body: event, headers: { 'Content-Type' => 'text/event-stream' } }
        end
      end

      expect(server.call_tool('t', {})).to eq({ 'content' => [] })
      expect(server.instance_variable_get(:@last_event_id)).to be_nil
      expect(server.call_tool('t', {})).to eq({ 'content' => [] })
      expect(headers).to all(satisfy { |h| !h.key?('Last-Event-Id') && !h.key?('Last-Event-ID') })
    end
  end

  describe 'the expansion bound on compressed bodies' do
    let(:bomb) { gzip("#{'a' * (8 * 1024 * 1024)}\n\n#{sse_event('jsonrpc' => '2.0', 'id' => 1, 'result' => {})}") }

    def inflated_pieces
      inflated = 0
      allow_any_instance_of(Zlib::Inflate).to receive(:inflate).and_wrap_original do |original, bytes, &block|
        if block
          original.call(bytes) do |piece|
            inflated += piece.bytesize
            block.call(piece)
          end
        else
          original.call(bytes).tap { |text| inflated += text.bytesize }
        end
      end
      -> { inflated }
    end

    # A small compressed body the peer breaks off afterwards would otherwise
    # be inflated whole by the salvage, past the bound the completed-body
    # decoder enforces. The bound is reported as such (round 7): an answer
    # this client refuses to expand is not one the stream lost, and treating
    # it as lost would re-issue a request the server already ran.
    it 'never inflates a salvaged answer past the bound' do
      inflated = inflated_pieces

      expect { server.send(:inflate_delivered_gzip, bomb) }
        .to raise_error(MCPClient::Errors::ResponseTooLargeError, /1024 bytes/)
      expect(inflated.call).to be <= 1024 + (64 * 1024)
    end

    # A deflate stream that stopped short hands back only the bytes it did
    # expand — never the bound's refusal. The salvage then finds no answer in
    # them and the caller re-issues, which is the right outcome for a stream
    # that really did lose the response.
    it 'hands back what a deflate stream that stopped short did expand' do
      answer = sse_event('jsonrpc' => '2.0', 'id' => 1, 'result' => {})
      truncated = gzip(answer)[0, 12]

      salvaged = server.send(:inflate_delivered_gzip, truncated)

      expect(salvaged).not_to include('"result"')
      expect(server.send(:body_carries_response?, salvaged.to_s, false, 1)).to be(false)
    end

    it 'still inflates a salvaged answer within the bound' do
      compressed = gzip(sse_event('jsonrpc' => '2.0', 'id' => 1, 'result' => {}))

      expect(server.send(:inflate_delivered_gzip, compressed)).to include('"result"')
    end
  end
end
