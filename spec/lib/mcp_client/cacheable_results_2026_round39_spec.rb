# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirty-ninth review round: a response read as a
# stream is dated from the chunk that completed the result, not from an
# earlier keep-alive or progress chunk; the stale fallback is exercised end
# to end for prompt and resource lists on both HTTP transports; and a read
# whose contents are empty, or several, is cached whole.
# A Faraday adapter that hands the response to the request's on_data
# callback chunk by chunk, calling a hook between chunks so an example can
# move the clock while the stream is still open.
class Round39ChunkedAdapter < Faraday::Adapter
  def initialize(app, replies, between_chunks)
    super(app)
    @replies = replies
    @between_chunks = between_chunks
  end

  def call(env)
    request = JSON.parse(env.body.to_s)
    super
    content_type, chunks = @replies.call(request)
    chunks.each_with_index do |chunk, index|
      @between_chunks.call(index) if index.positive?
      env.request.on_data&.call(chunk, chunk.bytesize, env)
    end
    save_response(env, 200, chunks.join, { 'Content-Type' => content_type })
    @app.call(env)
  end
end
Faraday::Adapter.register_middleware(round39_chunked: Round39ChunkedAdapter)

RSpec.describe 'MCP 2026-07-28 cacheable results — round 39' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def plain_http(**opts)
    MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def sse_event(message)
    "event: message\ndata: #{JSON.generate(message)}\n\n"
  end

  describe 'a response read as a stream, chunk by chunk' do
    def replies_for(reads)
      lambda do |request|
        case request['method']
        when 'server/discover'
          ['application/json', [JSON.generate('jsonrpc' => '2.0', 'id' => request['id'], 'result' => discover_result)]]
        when 'resources/read'
          reads[:count] += 1
          # A keep-alive, then a progress notification, then -- two seconds
          # after the stream opened -- the result itself, and one more
          # keep-alive a second later before the server closes the stream.
          ['text/event-stream',
           [": keep-alive\n\n",
            sse_event({ 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
                        'params' => { 'progressToken' => 't', 'progress' => 1 } }),
            sse_event({ 'jsonrpc' => '2.0', 'id' => request['id'],
                        'result' => { 'contents' => [{ 'uri' => 'file:///x', 'text' => "v#{reads[:count]}" }],
                                      'ttlMs' => 1_000, 'cacheScope' => 'public' } }),
            ": keep-alive\n\n"]]
        else raise "unexpected #{request['method']}"
        end
      end
    end

    shared_examples 'dated from the chunk that completed the result' do
      it 'is dated from the chunk that completed the result, not from the keep-alive that opened the stream' do
        clock = { now: 0.0 }
        reads = { count: 0 }
        between = ->(_index) { clock[:now] += 1.0 }
        server = build.call(->(f) { f.adapter :round39_chunked, replies_for(reads), between })
        allow(server).to receive(:monotonic_now) { clock[:now] }
        progress = 0
        server.on_notification { |method, _params| progress += 1 if method == 'notifications/progress' }

        expect(server.read_resource('file:///x').map(&:text)).to eq(['v1'])
        expect(progress).to eq(1)

        # The stream opened at t=0, the result arrived at t=2 with a
        # one-second TTL and the stream closed at t=3: fresh until t=3,
        # whatever came down the stream before the result or after it (MCP
        # 2026-07-28 caching, "Freshness Calculation").
        info = server.cache_info(:read, 'file:///x')
        expect(info[:received_at]).to eq(2.0)
        clock[:now] = 2.9
        expect(server.cache_info(:read, 'file:///x')[:fresh]).to be(true)
        expect(server.read_resource('file:///x').map(&:text)).to eq(['v1'])
        expect(reads[:count]).to eq(1)

        clock[:now] = 3.5
        expect(server.cache_info(:read, 'file:///x')[:fresh]).to be(false)
        expect(server.read_resource('file:///x').map(&:text)).to eq(['v2'])
        expect(reads[:count]).to eq(2)
      ensure
        server&.cleanup
      end
    end

    context 'on plain HTTP' do
      let(:build) { ->(config) { plain_http(faraday_config: config) } }

      include_examples 'dated from the chunk that completed the result'
    end

    context 'on Streamable HTTP' do
      let(:build) { ->(config) { streamable(faraday_config: config) } }

      include_examples 'dated from the chunk that completed the result'
    end
  end

  describe 'the stale fallback for prompt and resource lists' do
    def prompts_result(name, ttl_ms:)
      { 'prompts' => [{ 'name' => name }], 'ttlMs' => ttl_ms, 'cacheScope' => 'public' }
    end

    def resources_result(name, ttl_ms:)
      { 'resources' => [{ 'uri' => "file:///#{name}", 'name' => name }], 'ttlMs' => ttl_ms, 'cacheScope' => 'public' }
    end

    # The first list is served with a one-second TTL; every later list of
    # that kind fails with a 503 -- a transient failure the stale copy
    # covers (MCP 2026-07-28 caching: a stale result MAY be served when a
    # re-fetch fails).
    def stub_lists(method, first)
      lists = { count: 0 }
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == method
          lists[:count] += 1
          lists[:count] == 1 ? json_response(body['id'], first) : { status: 503, body: '' }
        else
          json_response(body['id'], discover_result)
        end
      end
      lists
    end

    shared_examples 'a stale list served over a transient failure' do
      it 'serves the stale prompt list when the re-fetch fails transiently' do
        clock = { now: 100.0 }
        lists = stub_lists('prompts/list', prompts_result('old', ttl_ms: 1_000))
        server = build.call
        allow(server).to receive(:monotonic_now) { clock[:now] }

        expect(server.list_prompts.map(&:name)).to eq(['old'])
        clock[:now] += 2
        expect(server.list_prompts.map(&:name)).to eq(['old'])
        expect(lists[:count]).to eq(2)
        expect(server.cache_info(:prompts)[:fresh]).to be(false)
      ensure
        server&.cleanup
      end

      it 'serves the stale resource list when the re-fetch fails transiently' do
        clock = { now: 100.0 }
        lists = stub_lists('resources/list', resources_result('old', ttl_ms: 1_000))
        server = build.call
        allow(server).to receive(:monotonic_now) { clock[:now] }

        expect(server.list_resources['resources'].map(&:name)).to eq(['old'])
        clock[:now] += 2
        expect(server.list_resources['resources'].map(&:name)).to eq(['old'])
        expect(lists[:count]).to eq(2)
        expect(server.cache_info(:resources)[:fresh]).to be(false)
      ensure
        server&.cleanup
      end
    end

    context 'on plain HTTP' do
      let(:build) { -> { plain_http } }

      include_examples 'a stale list served over a transient failure'
    end

    context 'on Streamable HTTP' do
      let(:build) { -> { streamable } }

      include_examples 'a stale list served over a transient failure'
    end
  end

  describe 'a cached read' do
    def stub_reads(contents)
      reads = { count: 0 }
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        reads[:count] += 1
        json_response(body['id'], { 'contents' => contents, 'ttlMs' => 60_000, 'cacheScope' => 'public' })
      end
      reads
    end

    it 'keeps every content item, in order, on a hit' do
      contents = [{ 'uri' => 'file:///dir/b', 'text' => 'second' },
                  { 'uri' => 'file:///dir/a', 'text' => 'first' },
                  { 'uri' => 'file:///dir/c', 'blob' => Base64.strict_encode64('third'),
                    'mimeType' => 'application/octet-stream' }]
      reads = stub_reads(contents)
      server = streamable

      first = server.read_resource('file:///dir')
      again = server.read_resource('file:///dir')

      expect(reads[:count]).to eq(1)
      expect(again.map(&:uri)).to eq(%w[file:///dir/b file:///dir/a file:///dir/c])
      expect(again.map(&:text)).to eq(['second', 'first', nil])
      expect(again.last.blob).to eq(Base64.strict_encode64('third'))
      expect(again.map(&:uri)).to eq(first.map(&:uri))
    ensure
      server&.cleanup
    end

    it 'caches an empty successful read for the TTL it carries' do
      reads = stub_reads([])
      server = streamable

      expect(server.read_resource('file:///empty')).to eq([])
      expect(server.read_resource('file:///empty')).to eq([])

      expect(reads[:count]).to eq(1)
      expect(server.cache_info(:read, 'file:///empty')).to include(ttl_ms: 60_000, fresh: true)
    ensure
      server&.cleanup
    end
  end
end
