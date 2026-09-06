# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirty-eighth review round: a read is keyed by the
# URI its request went out with, whatever a host does to the string it
# passed; a plain-HTTP response read as a stream is dated from its first
# chunk, before anything that chunk carried was handled; a plain read that
# finishes beside a multi round-trip read is cached whichever finishes
# first; an empty-string cursor is followed like any other; an unfinished
# list is stored nowhere; a caller-managed restart after a dead cursor; and
# a negotiated 2025-11-25 session's unhinted lists.
# A Faraday adapter that hands the response to the request's on_data
# callback the way a streaming adapter does -- in one chunk -- so that the
# transport's live dispatch runs before the response is complete.
class Round38StreamingAdapter < Faraday::Adapter
  def initialize(app, replies)
    super(app)
    @replies = replies
  end

  def call(env)
    request = JSON.parse(env.body.to_s)
    super
    content_type, body = @replies.call(request)
    env.request.on_data&.call(body, body.bytesize, env)
    save_response(env, 200, body, { 'Content-Type' => content_type })
    @app.call(env)
  end
end
Faraday::Adapter.register_middleware(round38_streaming: Round38StreamingAdapter)

RSpec.describe 'MCP 2026-07-28 cacheable results — round 38' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def error_response(id, code, message)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id,
                                       'error' => { 'code' => code, 'message' => message }),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def initialize_result(era)
    { 'protocolVersion' => era, 'capabilities' => { 'resources' => {}, 'tools' => {}, 'prompts' => {} },
      'serverInfo' => { 'name' => 'test', 'version' => '1.0' } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def template(name)
    { 'uriTemplate' => "file:///#{name}/{x}", 'name' => name }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def plain_http(**opts)
    MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def contents_of(uri, text, **hint)
    { 'contents' => [{ 'uri' => uri, 'text' => text }], 'ttlMs' => 60_000, 'cacheScope' => 'public' }.merge(hint)
  end

  describe 'the URI a read is keyed by' do
    it 'is the one its request went out with, whatever the caller does to the string afterwards' do
      wire = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        uri = body.dig('params', 'uri')
        wire << uri
        json_response(body['id'], contents_of(uri, "#{uri}-contents"))
      end
      server = streamable
      uri = +'file:///a'
      # The host rewrites, in place, the string it handed the transport --
      # after the entry for it was looked up, before the request carrying it
      # was serialized.
      allow(server).to receive(:cache_epoch).and_wrap_original do |original, *args|
        uri.replace('file:///b') if uri == 'file:///a'
        original.call(*args)
      end

      # One URI names the request, its key and its contents: the snapshot
      # taken on entry, not whatever the string says by the time it is sent.
      expect(server.read_resource(uri).map(&:text)).to eq(['file:///a-contents'])
      expect(wire).to eq(['file:///a'])

      expect(server.read_resource('file:///a').map(&:text)).to eq(['file:///a-contents'])
      expect(wire).to eq(['file:///a'])
      expect(server.read_resource('file:///b').map(&:text)).to eq(['file:///b-contents'])
      expect(wire).to eq(['file:///a', 'file:///b'])
    ensure
      server&.cleanup
    end
  end

  describe 'a plain-HTTP response read as a stream' do
    def sse(*messages)
      messages.map { |message| "event: message\ndata: #{JSON.generate(message)}\n\n" }.join
    end

    it 'is dated from its first chunk, before the notification that chunk carried was handled' do
      clock = { now: 0.0 }
      reads = 0
      replies = lambda do |request|
        case request['method']
        when 'server/discover'
          ['application/json', JSON.generate('jsonrpc' => '2.0', 'id' => request['id'], 'result' => discover_result)]
        when 'resources/read'
          reads += 1
          ['text/event-stream',
           sse({ 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
                 'params' => { 'progressToken' => 't', 'progress' => 1 } },
               { 'jsonrpc' => '2.0', 'id' => request['id'],
                 'result' => contents_of('file:///x', "v#{reads}", 'ttlMs' => 1_000) })]
        else raise "unexpected #{request['method']}"
        end
      end
      server = plain_http(faraday_config: ->(f) { f.adapter :round38_streaming, replies })
      allow(server).to receive(:monotonic_now) { clock[:now] }
      handled = 0
      server.on_notification do |method, _params|
        next unless method == 'notifications/progress'

        handled += 1
        clock[:now] += 5
      end

      expect(server.read_resource('file:///x').map(&:text)).to eq(['v1'])
      expect(handled).to eq(1)
      # Received at t=0 with a one-second TTL; the callback ran until t=5.
      expect(server.cache_info(:read, 'file:///x')[:fresh]).to be(false)
      expect(server.read_resource('file:///x').map(&:text)).to eq(['v2'])
      expect(reads).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'a plain read finishing beside a multi round-trip read' do
    def stub_reads
      counts = Hash.new(0)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        uri = body.dig('params', 'uri')
        counts[uri] += 1
        if uri == 'file:///mrtr' && !body.dig('params', 'requestState')
          json_response(body['id'], { 'resultType' => 'input_required', 'requestState' => 's' })
        else
          json_response(body['id'], contents_of(uri, "#{uri}:#{counts[uri]}"))
        end
      end
      counts
    end

    it 'is cached when the round trip completes while the plain read is between its answer and the cache' do
      counts = stub_reads
      server = streamable
      server.connect
      gate = Queue.new
      plain_thread = nil
      # The plain read parks right after its answer arrived and right before
      # it is stored -- the moment another thread's round trip completes.
      allow(server).to receive(:response_received_at).and_wrap_original do |original, **kwargs|
        gate.pop if Thread.current.equal?(plain_thread)
        original.call(**kwargs)
      end

      plain_thread = Thread.new { server.read_resource('file:///plain').first.text }
      Timeout.timeout(5) { sleep 0.01 until gate.num_waiting == 1 }
      expect(server.read_resource('file:///mrtr').first.text).to eq('file:///mrtr:2')
      gate << true
      expect(plain_thread.value).to eq('file:///plain:1')

      # The round trip was this thread's, not the plain read's: the plain
      # read is served from its entry, the retried read is asked for again.
      expect(server.read_resource('file:///plain').first.text).to eq('file:///plain:1')
      expect(counts['file:///plain']).to eq(1)
      expect(server.read_resource('file:///mrtr').first.text).to eq('file:///mrtr:4')
    ensure
      server&.cleanup
    end

    it 'leaves the round trip uncached when the plain read is stored between its answer and the cache' do
      counts = stub_reads
      server = streamable
      server.connect
      gate = Queue.new
      round_trip_thread = nil
      # The other order: the round trip parks right after its final answer
      # and right before it would be stored -- while the plain read arrives
      # and is stored on this thread.
      allow(server).to receive(:response_received_at).and_wrap_original do |original, **kwargs|
        gate.pop if Thread.current.equal?(round_trip_thread)
        original.call(**kwargs)
      end

      round_trip_thread = Thread.new { server.read_resource('file:///mrtr').first.text }
      Timeout.timeout(5) { sleep 0.01 until gate.num_waiting == 1 }
      expect(server.read_resource('file:///plain').first.text).to eq('file:///plain:1')
      gate << true
      expect(round_trip_thread.value).to eq('file:///mrtr:2')

      expect(server.read_resource('file:///plain').first.text).to eq('file:///plain:1')
      expect(counts['file:///plain']).to eq(1)
      expect(server.read_resource('file:///mrtr').first.text).to eq('file:///mrtr:4')
    ensure
      server&.cleanup
    end
  end

  describe 'an empty-string cursor' do
    it 'is a cursor like any other: followed, and the aggregate cached under the hint' do
      cursors = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        cursor = body.dig('params', 'cursor')
        cursors << cursor
        page = cursor.nil? ? { 'tools' => [tool('t1')], 'nextCursor' => '' } : { 'tools' => [tool('t2')] }
        json_response(body['id'], page.merge('ttlMs' => 60_000, 'cacheScope' => 'public'))
      end
      server = streamable

      expect(server.list_tools.map(&:name)).to eq(%w[t1 t2])
      expect(cursors).to eq([nil, ''])
      expect(server.list_tools.map(&:name)).to eq(%w[t1 t2])
      expect(cursors.size).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'an unfinished list' do
    it 'is stored nowhere: the next call asks again' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        lists += 1
        json_response(body['id'], { 'resultType' => 'input_required', 'requestState' => 's', 'ttlMs' => 60_000 })
      end
      server = streamable

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError)
      expect(server.cache_info(:tools)).to be_nil
      expect { server.list_tools }.to raise_error(MCPClient::Errors::InvalidResultError)
      expect(lists).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'a caller-managed restart after a dead cursor' do
    it 'runs from the first page to the end on the cursors of the new sequence' do
      cursors = []
      page = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/templates/list'

        cursor = body.dig('params', 'cursor')
        cursors << cursor
        case cursor
        when nil
          page += 1
          json_response(body['id'], { 'resourceTemplates' => [template("page#{page}")],
                                      'nextCursor' => "cursor-#{page}", 'ttlMs' => 60_000, 'cacheScope' => 'public' })
        when 'cursor-1' then error_response(body['id'], MCPClient::Errors::Codes::INVALID_PARAMS, 'Expired cursor')
        else json_response(body['id'], { 'resourceTemplates' => [template('last')], 'ttlMs' => 60_000,
                                         'cacheScope' => 'public' })
        end
      end
      server = streamable

      first = server.list_resource_templates
      expect(first['nextCursor']).to eq('cursor-1')
      expect { server.list_resource_templates(cursor: 'cursor-1') }.to raise_error(MCPClient::Errors::ServerError)

      # The caller starts over: a fresh first page, then its cursor to the end.
      restarted = server.list_resource_templates
      expect(restarted['nextCursor']).to eq('cursor-2')
      last = server.list_resource_templates(cursor: 'cursor-2')
      expect(last['resourceTemplates'].map(&:name)).to eq(['last'])
      expect(last['nextCursor']).to be_nil
      expect(cursors).to eq([nil, 'cursor-1', nil, 'cursor-2'])
    ensure
      server&.cleanup
    end
  end

  describe 'a session negotiated to 2025-11-25 over Streamable HTTP' do
    it 'keeps an unhinted list until the server says it changed, as before' do
      counts = Hash.new(0)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        case body['method']
        when 'initialize' then json_response(body['id'], initialize_result('2025-11-25'))
        when 'notifications/initialized' then { status: 202, body: '' }
        when 'prompts/list' then json_response(body['id'],
                                               { 'prompts' => [{ 'name' => "p#{counts['prompts/list']}" }] })
        when 'resources/list'
          json_response(body['id'], { 'resources' => [{ 'uri' => "file:///r#{counts['resources/list']}",
                                                        'name' => 'r' }] })
        else raise "unexpected #{body['method']}"
        end
      end
      server = streamable(protocol: :legacy)

      expect(server.list_prompts.map(&:name)).to eq(['p1'])
      expect(server.list_prompts.map(&:name)).to eq(['p1'])
      expect(server.list_resources['resources'].map(&:uri)).to eq(['file:///r1'])
      expect(server.list_resources['resources'].map(&:uri)).to eq(['file:///r1'])
      expect(counts.values_at('initialize', 'prompts/list', 'resources/list')).to eq([1, 1, 1])
      # No hint on a 2025-11-25 session is not "stale now": the list stays
      # until the server says it changed (the client's own heuristic the
      # spec allows for), and cache_info says as much.
      expect(server.cache_info(:prompts)).to include(ttl_ms: nil, fresh: true)

      server.send(:dispatch_server_message, { 'jsonrpc' => '2.0', 'method' => 'notifications/prompts/list_changed' })
      server.send(:dispatch_server_message, { 'jsonrpc' => '2.0', 'method' => 'notifications/resources/list_changed' })
      expect(server.list_prompts.map(&:name)).to eq(['p2'])
      expect(server.list_resources['resources'].map(&:uri)).to eq(['file:///r2'])
    ensure
      server&.cleanup
    end
  end
end
