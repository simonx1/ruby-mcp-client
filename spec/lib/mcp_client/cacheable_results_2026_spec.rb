# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 Caching (server/utilities/caching, SEP-2549): server/discover,
# tools/list, prompts/list, resources/list, resources/templates/list and
# resources/read carry `ttlMs` (a freshness hint: fresh while
# now < t_received + ttlMs; 0 = immediately stale; absent or negative = 0)
# and `cacheScope` ("public" / "private"). Clients re-fetch on access once
# stale (never in the background), invalidate on the matching change
# notification, key cached responses by method and parameters, never cache
# multi round-trip retry results, and MAY serve a stale response when a
# re-fetch fails.
RSpec.describe 'MCP 2026-07-28 cacheable results' do
  describe MCPClient::CachedResult do
    it 'is fresh for ttlMs after receipt and stale afterwards' do
      entry = described_class.from_result({ 'ttlMs' => 60_000, 'cacheScope' => 'public' }, :value, now: 100.0)
      expect(entry.hint?).to be(true)
      expect(entry.ttl_ms).to eq(60_000)
      expect(entry.cache_scope).to eq('public')
      expect(entry.fresh?(now: 159.9)).to be(true)
      expect(entry.fresh?(now: 160.0)).to be(false)
      expect(entry.value).to eq(:value)
    end

    it 'treats ttlMs 0 as immediately stale' do
      entry = described_class.from_result({ 'ttlMs' => 0, 'cacheScope' => 'private' }, :v, now: 1.0)
      expect(entry.fresh?(now: 1.0)).to be(false)
      expect(entry.cache_scope).to eq('private')
    end

    it 'treats a negative or non-numeric ttlMs as 0' do
      expect(described_class.from_result({ 'ttlMs' => -5 }, :v, now: 1.0).fresh?(now: 1.0)).to be(false)
      expect(described_class.from_result({ 'ttlMs' => 'soon' }, :v, now: 1.0).fresh?(now: 1.0)).to be(false)
    end

    it 'carries no hint when ttlMs is absent (older servers) and stays fresh by heuristic' do
      entry = described_class.from_result({ 'tools' => [] }, :v, now: 1.0)
      expect(entry.hint?).to be(false)
      expect(entry.ttl_ms).to be_nil
      # Without an explicit "public" the entry stays within its context.
      expect(entry.cache_scope).to eq('private')
      expect(entry.fresh?(now: 1_000_000.0)).to be(true)
    end

    it 'treats an unknown cacheScope as private and accepts a Float ttlMs' do
      entry = described_class.from_result({ 'ttlMs' => 1500.5, 'cacheScope' => 'shared' }, :v, now: 0.0)
      expect(entry.cache_scope).to eq('private')
      expect(entry.fresh?(now: 1.5)).to be(true)
      expect(entry.fresh?(now: 1.6)).to be(false)
    end

    it 'combines pages conservatively: the shortest TTL wins' do
      first = described_class.from_result({ 'ttlMs' => 60_000, 'cacheScope' => 'public' }, nil, now: 0.0)
      second = described_class.from_result({ 'ttlMs' => 1_000, 'cacheScope' => 'public' }, nil, now: 0.0)
      combined = described_class.combine([first, second], :all, now: 0.0)
      expect(combined.ttl_ms).to eq(1_000)
      expect(combined.fresh?(now: 0.9)).to be(true)
      expect(combined.fresh?(now: 1.1)).to be(false)
    end
  end

  describe 'on Streamable HTTP' do
    let(:url) { 'https://example.com/mcp' }
    let(:log_output) { StringIO.new }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                          logger: Logger.new(log_output))
    end
    let(:clock) { { now: 1000.0 } }

    before { allow(server).to receive(:monotonic_now) { clock[:now] } }

    after { server.cleanup }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    def discover_result
      { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
        'capabilities' => { 'tools' => { 'listChanged' => true }, 'resources' => { 'listChanged' => true } },
        'ttlMs' => 3_600_000, 'cacheScope' => 'public' }
    end

    # Serve list/read results with the given ttl; count requests per method.
    def stub_server(ttl_ms:, tools: [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }])
      counts = Hash.new(0)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        result = case body['method']
                 when 'server/discover' then discover_result
                 when 'tools/list'
                   { 'tools' => tools, 'ttlMs' => ttl_ms, 'cacheScope' => 'public' }
                 when 'prompts/list' then { 'prompts' => [], 'ttlMs' => ttl_ms, 'cacheScope' => 'public' }
                 when 'resources/list'
                   { 'resources' => [{ 'uri' => 'file:///a', 'name' => 'a' }], 'ttlMs' => ttl_ms,
                     'cacheScope' => 'private' }
                 when 'resources/templates/list'
                   { 'resourceTemplates' => [], 'ttlMs' => ttl_ms, 'cacheScope' => 'public' }
                 when 'resources/read'
                   uri = body['params']['uri']
                   { 'contents' => [{ 'uri' => uri, 'text' => "content of #{uri}" }],
                     'ttlMs' => ttl_ms, 'cacheScope' => 'private' }
                 else { 'content' => [] }
                 end
        json_response(body['id'], result)
      end
      counts
    end

    it 'serves tools, prompts and resources from cache while fresh and re-fetches once stale' do
      counts = stub_server(ttl_ms: 60_000)

      server.list_tools
      server.list_tools
      server.list_prompts
      server.list_prompts
      server.list_resources
      server.list_resources
      expect(counts.values_at('tools/list', 'prompts/list', 'resources/list')).to eq([1, 1, 1])

      clock[:now] += 61
      server.list_tools
      server.list_prompts
      server.list_resources
      expect(counts.values_at('tools/list', 'prompts/list', 'resources/list')).to eq([2, 2, 2])
    end

    it 're-fetches on every access when ttlMs is 0' do
      counts = stub_server(ttl_ms: 0)

      3.times { server.list_tools }

      expect(counts['tools/list']).to eq(3)
    end

    it 'exposes the cache hint per operation' do
      stub_server(ttl_ms: 60_000)

      server.list_tools
      server.list_resources
      info = server.cache_info(:tools)

      expect(info).to include(ttl_ms: 60_000, cache_scope: 'public', fresh: true)
      expect(server.cache_info(:resources)[:cache_scope]).to eq('private')
      expect(server.cache_info(:discover)).to include(ttl_ms: 3_600_000, cache_scope: 'public')
      expect(server.cache_info(:prompts)).to be_nil
    end

    it 'invalidates a fresh list on the matching list_changed notification' do
      counts = stub_server(ttl_ms: 60_000)

      server.list_tools
      server.send(:dispatch_server_message, { 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed' })
      server.list_tools

      expect(counts['tools/list']).to eq(2)
      expect(server.cache_info(:tools)[:fresh]).to be(true)
    end

    it 'uses the shortest page TTL for an auto-paginated list' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        result = case body['method']
                 when 'server/discover' then discover_result
                 when 'tools/list'
                   lists += 1
                   if body['params']['cursor']
                     { 'tools' => [{ 'name' => 'b', 'inputSchema' => { 'type' => 'object' } }],
                       'ttlMs' => 1_000, 'cacheScope' => 'public' }
                   else
                     { 'tools' => [{ 'name' => 'a', 'inputSchema' => { 'type' => 'object' } }], 'nextCursor' => 'p2',
                       'ttlMs' => 60_000, 'cacheScope' => 'public' }
                   end
                 end
        json_response(body['id'], result)
      end

      expect(server.list_tools.map(&:name)).to eq(%w[a b])
      expect(server.cache_info(:tools)[:ttl_ms]).to eq(1_000)
      clock[:now] += 1.5
      server.list_tools

      expect(lists).to eq(4)
    end

    it 'caches resources/read per URI while fresh and re-fetches once stale' do
      counts = stub_server(ttl_ms: 60_000)

      server.read_resource('file:///a')
      server.read_resource('file:///a')
      expect(server.read_resource('file:///b').first.text).to eq('content of file:///b')
      expect(counts['resources/read']).to eq(2)
      expect(server.cache_info(:read, 'file:///a')).to include(ttl_ms: 60_000, cache_scope: 'private')

      clock[:now] += 61
      server.read_resource('file:///a')
      expect(counts['resources/read']).to eq(3)
    end

    it 'does not cache a resources/read with ttlMs 0' do
      counts = stub_server(ttl_ms: 0)

      server.read_resource('file:///a')
      server.read_resource('file:///a')

      expect(counts['resources/read']).to eq(2)
    end

    it 'invalidates a cached read on notifications/resources/updated for that URI, and all on list_changed' do
      counts = stub_server(ttl_ms: 60_000)

      server.read_resource('file:///a')
      server.read_resource('file:///b')
      server.send(:dispatch_server_message, { 'jsonrpc' => '2.0', 'method' => 'notifications/resources/updated',
                                              'params' => { 'uri' => 'file:///a' } })
      server.read_resource('file:///a')
      server.read_resource('file:///b')
      expect(counts['resources/read']).to eq(3)

      server.send(:dispatch_server_message, { 'jsonrpc' => '2.0', 'method' => 'notifications/resources/list_changed' })
      server.read_resource('file:///b')
      expect(counts['resources/read']).to eq(4)
    end

    it 'never caches the result of a multi round-trip retry' do
      server.on_elicitation_request { |_k, _p| { 'action' => 'accept', 'content' => {} } }
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        result = case body['method']
                 when 'server/discover' then discover_result
                 when 'resources/read'
                   reads += 1
                   if body['params'].key?('inputResponses')
                     { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'secret' }], 'ttlMs' => 60_000,
                       'cacheScope' => 'private' }
                   else
                     { 'resultType' => 'input_required', 'requestState' => 's',
                       'inputRequests' => { 'k' => { 'method' => 'elicitation/create',
                                                     'params' => { 'message' => 'who?',
                                                                   'requestedSchema' => { 'type' => 'object' } } } } }
                   end
                 end
        json_response(body['id'], result)
      end

      server.read_resource('file:///a')
      server.read_resource('file:///a')

      expect(reads).to eq(4)
      expect(server.cache_info(:read, 'file:///a')).to be_nil
    end

    it 'serves a stale list when the re-fetch fails transiently, and raises when nothing is cached' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'tools/list'
          lists += 1
          if lists == 1
            json_response(body['id'], { 'tools' => [{ 'name' => 'old', 'inputSchema' => { 'type' => 'object' } }],
                                        'ttlMs' => 1_000, 'cacheScope' => 'public' })
          else
            { status: 503, body: '' }
          end
        end
      end

      expect(server.list_tools.map(&:name)).to eq(['old'])
      clock[:now] += 2
      expect(server.list_tools.map(&:name)).to eq(['old'])
      expect(log_output.string).to match(/stale/i)

      fresh = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      expect { fresh.list_tools }.to raise_error(MCPClient::Errors::TransientServerError)
      fresh.cleanup
    end

    it 'keeps caching until a notification for a legacy server (no ttlMs hint)' do
      counts = Hash.new(0)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        case body['method']
        when 'server/discover' then { status: 400, body: '' }
        when 'initialize'
          json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                                      'serverInfo' => { 'name' => 'l', 'version' => '1' } })
        when 'notifications/initialized' then { status: 202, body: '' }
        when 'tools/list' then json_response(body['id'], { 'tools' => [] })
        end
      end
      stub_request(:get, url).to_return(status: 405, body: '')

      server.list_tools
      clock[:now] += 100_000
      server.list_tools

      expect(counts['tools/list']).to eq(1)
      expect(server.cache_info(:tools)).to include(ttl_ms: nil, fresh: true)
    end
  end

  describe 'through MCPClient::Client' do
    let(:url) { 'https://example.com/mcp' }

    def stub_client_server(ttl_ms:)
      counts = Hash.new(0)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        result = case body['method']
                 when 'server/discover'
                   { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                     'capabilities' => { 'tools' => {} } }
                 when 'tools/list'
                   { 'tools' => [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }],
                     'ttlMs' => ttl_ms, 'cacheScope' => 'public' }
                 else { 'content' => [] }
                 end
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end
      counts
    end

    it 're-fetches a stale server list even when the client cache is populated' do
      counts = stub_client_server(ttl_ms: 0)
      client = MCPClient::Client.new(mcp_server_configs: [MCPClient.streamable_http_config(
        base_url: 'https://example.com', endpoint: '/mcp', retries: 0
      )])

      client.list_tools
      client.list_tools
      client.call_tool('t', {})

      # Two client-level lists, the tool resolution for the call, and the
      # x-mcp-header derivation of the call itself (a stale list is never
      # used to mirror arguments into headers).
      expect(counts['tools/list']).to eq(4)
      client.cleanup
    end

    it 'keeps serving the client cache while the server list is fresh' do
      counts = stub_client_server(ttl_ms: 60_000)
      client = MCPClient::Client.new(mcp_server_configs: [MCPClient.streamable_http_config(
        base_url: 'https://example.com', endpoint: '/mcp', retries: 0
      )])

      client.list_tools
      client.list_tools
      client.call_tool('t', {})

      expect(counts['tools/list']).to eq(1)
      client.cleanup
    end
  end

  describe 'on stdio' do
    it 'records the hint so a stale list is re-fetched through the client' do
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
      sent = []
      allow(server).to receive(:send_request) { |req| sent << req }
      lists = 0
      allow(server).to receive(:wait_response) do |id, **_o|
        result = if sent.last['method'] == 'tools/list'
                   lists += 1
                   tools = lists == 1 ? [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }] : []
                   { 'tools' => tools, 'ttlMs' => 0, 'cacheScope' => 'public' }
                 else
                   { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => {} }
                 end
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => result }
      end
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }])

      expect(client.list_tools.size).to eq(1)
      expect(server.cache_info(:tools)).to include(ttl_ms: 0, fresh: false)
      expect(client.list_tools.size).to eq(0)
    end
  end
end

RSpec.describe 'MCP 2026-07-28 cacheable results — round 2' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  # A stdio server driven by scripted responses (no subprocess).
  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  it 'does not serve a stale list when the re-fetch fails with an authorization error' do
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    clock = { now: 1000.0 }
    allow(server).to receive(:monotonic_now) { clock[:now] }
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        lists += 1
        if lists == 1
          json_response(body['id'], { 'tools' => [tool('t')], 'ttlMs' => 1000, 'cacheScope' => 'public' })
        else
          { status: 401, headers: { 'WWW-Authenticate' => 'Bearer realm="mcp"' }, body: '' }
        end
      else
        json_response(body['id'], discover_result)
      end
    end

    expect(server.list_tools.size).to eq(1)
    clock[:now] += 5
    expect { server.list_tools }.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed/)
  ensure
    server&.cleanup
  end

  it 'keeps the multi round-trip marker local to the requesting thread' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    allow(server).to receive(:sleep)
    responses = [{ 'resultType' => 'input_required', 'requestState' => 's' }, { 'resultType' => 'complete' }]

    seen_in_thread = nil
    Thread.new do
      server.send(:resolve_input_round_trips, 'resources/read', {}) { responses.shift }
      seen_in_thread = server.send(:last_result_from_round_trip?)
    end.join

    expect(seen_in_thread).to be(true)
    expect(server.send(:last_result_from_round_trip?)).to be(false)
  end

  it 'drops removed items from the client cache when a stale list is refreshed' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    clock = { now: 0.0 }
    allow(server).to receive(:monotonic_now) { clock[:now] }
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'tools' => [tool('a'), tool('b')], 'ttlMs' => 60_000 } },
                          { 'result' => { 'tools' => [tool('a')], 'ttlMs' => 60_000 } }])
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }])

    expect(client.list_tools.map(&:name)).to eq(%w[a b])
    clock[:now] += 100
    expect(client.list_tools.map(&:name)).to eq(%w[a])
    expect(client.list_tools.map(&:name)).to eq(%w[a])
  end

  it 'expires an auto-paginated list at its earliest page expiry' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    clock = { now: 0.0 }
    allow(server).to receive(:monotonic_now) { clock[:now] }
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'tools' => [tool('a')], 'ttlMs' => 1000, 'nextCursor' => 'p2' } },
                          lambda { |_req|
                            clock[:now] = 5.0
                            { 'result' => { 'tools' => [tool('b')], 'ttlMs' => 60_000 } }
                          }])

    expect(server.list_tools.size).to eq(2)
    expect(server.cache_fresh?(:tools)).to be(false)
  end
end

RSpec.describe 'MCP 2026-07-28 cacheable results — round 3' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'resources' => {} } }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  def contents(text)
    { 'contents' => [{ 'uri' => 'file:///a', 'text' => text }] }
  end

  it 'does not cache resources/read from a legacy server' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, protocol: :legacy)
    script_stdio(server, [{ 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                          'serverInfo' => { 'name' => 's', 'version' => '1' } } },
                          { 'result' => contents('one') }, { 'result' => contents('two') }])

    expect(server.read_resource('file:///a').first.text).to eq('one')
    expect(server.read_resource('file:///a').first.text).to eq('two')
  end

  it 'treats a resources/read without ttlMs from a modern server as immediately stale' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => contents('one') }, { 'result' => contents('two') }])

    expect(server.read_resource('file:///a').first.text).to eq('one')
    expect(server.read_resource('file:///a').first.text).to eq('two')
  end

  it 'forgets cached results and hints on cleanup' do
    reads = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      result = case body['method']
               when 'resources/read'
                 reads += 1
                 contents("read #{reads}").merge('ttlMs' => 60_000, 'cacheScope' => 'private')
               when 'tools/list' then { 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
               else discover_result
               end
      json_response(body['id'], result)
    end
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)

    expect(server.read_resource('file:///a').first.text).to eq('read 1')
    server.list_tools
    server.cleanup

    expect(server.cache_info(:read, 'file:///a')).to be_nil
    expect(server.cache_info(:tools)).to include(fresh: false)
    expect(server.read_resource('file:///a').first.text).to eq('read 2')
  ensure
    server&.cleanup
  end

  it 'drops private entries when the authorization context changes, keeping public ones' do
    token = { value: 'alice' }
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) { |req| req.headers['Authorization'] = "Bearer #{token[:value]}" }
    allow(provider).to receive(:respond_to?).and_return(true)
    counts = Hash.new(0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      result = case body['method']
               when 'resources/read'
                 contents(request.headers['Authorization']).merge('ttlMs' => 60_000, 'cacheScope' => 'private')
               when 'tools/list' then { 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
               else discover_result
               end
      json_response(body['id'], result)
    end
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                                 oauth_provider: provider)

    expect(server.read_resource('file:///a').first.text).to eq('Bearer alice')
    server.list_tools
    token[:value] = 'bob'
    expect(server.read_resource('file:///a').first.text).to eq('Bearer bob')
    server.list_tools

    expect(counts['resources/read']).to eq(2)
    expect(counts['tools/list']).to eq(1)
  ensure
    server&.cleanup
  end

  it 'marks a list stale (not unknown) when its change notification arrives' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'tools' => [], 'ttlMs' => 60_000 } },
                          { 'result' => { 'resourceTemplates' => [], 'ttlMs' => 60_000 } }])
    server.list_tools
    server.list_resource_templates
    expect(server.cache_fresh?(:tools)).to be(true)
    expect(server.cache_fresh?(:templates)).to be(true)

    server.send(:invalidate_cache_for_notification, 'notifications/tools/list_changed')
    server.send(:invalidate_cache_for_notification, 'notifications/resources/list_changed')

    expect(server.cache_fresh?(:tools)).to be(false)
    expect(server.cache_fresh?(:templates)).to be(false)
  end

  describe 'on HTTP+SSE' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse') }
    let(:clock) { { now: 0.0 } }

    before do
      allow(server).to receive(:monotonic_now) { clock[:now] }
      allow(server).to receive(:ensure_initialized)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
    end

    it 'serves lists only while fresh and re-fetches once stale' do
      lists = 0
      allow(server).to receive(:rpc_request).with('tools/list', anything) do
        lists += 1
        { 'tools' => [{ 'name' => "t#{lists}", 'inputSchema' => { 'type' => 'object' } }], 'ttlMs' => 1000 }
      end

      expect(server.list_tools.map(&:name)).to eq(['t1'])
      expect(server.list_tools.map(&:name)).to eq(['t1'])
      clock[:now] += 5
      expect(server.list_tools.map(&:name)).to eq(['t2'])
    end

    it 'drops its list on the change notification and caches reads while fresh' do
      lists = 0
      reads = 0
      allow(server).to receive(:rpc_request).with('prompts/list', anything) do
        lists += 1
        { 'prompts' => [{ 'name' => "p#{lists}" }], 'ttlMs' => 60_000 }
      end
      allow(server).to receive(:rpc_request).with('resources/read', anything) do
        reads += 1
        contents("read #{reads}").merge('ttlMs' => 60_000)
      end

      expect(server.list_prompts.map(&:name)).to eq(['p1'])
      server.send(:invalidate_cache_for_notification, 'notifications/prompts/list_changed')
      expect(server.list_prompts.map(&:name)).to eq(['p2'])

      expect(server.read_resource('file:///a').first.text).to eq('read 1')
      expect(server.read_resource('file:///a').first.text).to eq('read 1')
      server.send(:invalidate_cache_for_notification, 'notifications/resources/updated', { 'uri' => 'file:///a' })
      expect(server.read_resource('file:///a').first.text).to eq('read 2')
    end
  end
end

RSpec.describe 'MCP 2026-07-28 cacheable results — round 4' do
  let(:url) { 'https://example.com/mcp' }
  let(:sub_id_meta) { 'io.modelcontextprotocol/subscriptionId' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def contents(text)
    { 'contents' => [{ 'uri' => 'file:///a', 'text' => text }] }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  # A Streamable HTTP server whose reads/lists are counted per method and
  # whose private read echoes the Authorization it was served under.
  def counting_stub(delay_for: nil, fail_tools_after: nil)
    counts = Hash.new(0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      sleep(delay_for[:seconds]) if delay_for && request.headers['Authorization'] == delay_for[:authorization]
      result = case body['method']
               when 'resources/read'
                 contents(request.headers['Authorization'].to_s).merge('ttlMs' => 60_000, 'cacheScope' => 'private')
               when 'tools/list'
                 next { status: 503, body: '' } if fail_tools_after && counts['tools/list'] > fail_tools_after

                 { 'tools' => [tool(request.headers['Authorization'].to_s)], 'ttlMs' => 60_000,
                   'cacheScope' => 'private' }
               when 'prompts/list' then { 'prompts' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
               else discover_result
               end
      json_response(body['id'], result)
    end
    counts
  end

  def oauth_provider(token)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) do |req|
      req.headers['Authorization'] = "Bearer #{token[:value]}" if token[:value]
    end
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
  end

  def streamable(provider)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                        oauth_provider: provider)
  end

  it 'does not serve a private entry cached without credentials once a token is in use' do
    token = { value: nil }
    counts = counting_stub
    server = streamable(oauth_provider(token))

    expect(server.read_resource('file:///a').first.text).to eq('')
    token[:value] = 'bob'
    expect(server.read_resource('file:///a').first.text).to eq('Bearer bob')
    expect(counts['resources/read']).to eq(2)
  ensure
    server&.cleanup
  end

  it 'binds a private entry to the credentials of the request that produced it' do
    token = { value: 'alice' }
    counts = counting_stub(delay_for: { authorization: 'Bearer alice', seconds: 0.3 })
    server = streamable(oauth_provider(token))
    server.ping

    slow = Thread.new { server.read_resource('file:///a').first.text }
    sleep(0.1)
    token[:value] = 'bob'
    expect(server.read_resource('file:///a').first.text).to eq('Bearer bob')
    expect(slow.value).to eq('Bearer alice')

    # Alice's answer arrived last; it must not be served to Bob.
    expect(server.read_resource('file:///a').first.text).to eq('Bearer bob')
    expect(counts['resources/read']).to eq(3)
  ensure
    server&.cleanup
  end

  it 'does not fall back to a stale private list after the credentials changed' do
    token = { value: 'alice' }
    counting_stub(fail_tools_after: 1)
    server = streamable(oauth_provider(token))

    expect(server.list_tools.map(&:name)).to eq(['Bearer alice'])
    token[:value] = 'bob'

    expect { server.list_tools }.to raise_error(MCPClient::Errors::MCPError)
  ensure
    server&.cleanup
  end

  it 'treats a modern list without ttlMs as immediately stale but keeps the legacy heuristic' do
    modern = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(modern, [{ 'result' => discover_result }, { 'result' => { 'tools' => [tool('a')] } },
                          { 'result' => { 'tools' => [tool('a'), tool('b')] } }])
    expect(modern.list_tools.size).to eq(1)
    expect(modern.cache_fresh?(:tools)).to be(false)
    expect(modern.list_tools.size).to eq(2)

    legacy = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, protocol: :legacy)
    script_stdio(legacy, [{ 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                          'serverInfo' => { 'name' => 's', 'version' => '1' } } },
                          { 'result' => { 'tools' => [tool('a')] } }])
    expect(legacy.list_tools.size).to eq(1)
    expect(legacy.cache_fresh?(:tools)).to be(true)
  end

  it 'treats a page without ttlMs as expired when combining modern pages' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'tools' => [tool('a')], 'ttlMs' => 60_000, 'nextCursor' => 'p2' } },
                          { 'result' => { 'tools' => [tool('b')] } }])

    expect(server.list_tools.size).to eq(2)
    expect(server.cache_fresh?(:tools)).to be(false)
  end

  it 'invalidates caches before a subscription listener sees the notification' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => contents('one').merge('ttlMs' => 60_000) },
                          { 'result' => contents('two').merge('ttlMs' => 60_000) }])
    expect(server.read_resource('file:///a').first.text).to eq('one')

    seen = nil
    subscription = MCPClient::Subscription.new(server: server,
                                               requested: { 'resourceSubscriptions' => ['file:///a'] }) do
      seen = server.read_resource('file:///a').first.text
    end
    subscription.assign_id(7)
    server.send(:register_subscription, subscription)
    server.send(:route_notification, 'notifications/resources/updated',
                { 'uri' => 'file:///a', '_meta' => { sub_id_meta => 7 } })

    # Listeners are delivered on the subscription's own dispatcher thread, so
    # the read happens after this returns; what matters is that when it does,
    # the cache the notification invalidated is already gone.
    deadline = Time.now + 2
    sleep 0.005 while seen.nil? && Time.now < deadline
    expect(seen).to eq('two')
  end

  it 'replaces a server slice of the client prompt and resource caches on refresh' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    clock = { now: 0.0 }
    allow(server).to receive(:monotonic_now) { clock[:now] }
    prompts = ->(names) { { 'result' => { 'prompts' => names.map { |n| { 'name' => n } }, 'ttlMs' => 60_000 } } }
    resources = lambda { |names|
      { 'result' => { 'resources' => names.map { |n| { 'uri' => "file:///#{n}", 'name' => n } }, 'ttlMs' => 60_000 } }
    }
    script_stdio(server, [{ 'result' => discover_result }, prompts.call(%w[a b]), resources.call(%w[a b]),
                          prompts.call(%w[a]), resources.call(%w[a])])
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }])

    expect(client.list_prompts.map(&:name)).to eq(%w[a b])
    expect(client.list_resources['resources'].map(&:name)).to eq(%w[a b])
    clock[:now] += 100
    expect(client.list_prompts.map(&:name)).to eq(%w[a])
    expect(client.list_resources['resources'].map(&:name)).to eq(%w[a])
    expect(client.list_prompts.map(&:name)).to eq(%w[a])
    expect(client.list_resources['resources'].map(&:name)).to eq(%w[a])
  end

  describe 'on plain HTTP' do
    it 'forgets its lists on cleanup instead of serving them as fresh afterwards' do
      lists = Hash.new(0)
      stub_request(:post, 'https://example.com/rpc').to_return do |request|
        body = JSON.parse(request.body)
        lists[body['method']] += 1
        result = case body['method']
                 when 'prompts/list' then { 'prompts' => [{ 'name' => "p#{lists[body['method']]}" }],
                                            'ttlMs' => 60_000 }
                 when 'resources/list'
                   { 'resources' => [{ 'uri' => 'file:///a', 'name' => "r#{lists[body['method']]}" }],
                     'ttlMs' => 60_000 }
                 else discover_result
                 end
        json_response(body['id'], result)
      end
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/rpc', retries: 0)

      expect(server.list_prompts.map(&:name)).to eq(['p1'])
      expect(server.list_resources['resources'].map(&:name)).to eq(['r1'])
      server.cleanup

      expect(server.list_prompts.map(&:name)).to eq(['p2'])
      expect(server.list_resources['resources'].map(&:name)).to eq(['r2'])
    ensure
      server&.cleanup
    end
  end

  describe 'on HTTP+SSE' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse') }

    before do
      allow(server).to receive(:ensure_initialized)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
    end

    it 'forgets cached reads and lists on cleanup' do
      reads = 0
      lists = 0
      allow(server).to receive(:rpc_request).with('resources/read', anything) do
        reads += 1
        contents("read #{reads}").merge('ttlMs' => 60_000, 'cacheScope' => 'private')
      end
      allow(server).to receive(:rpc_request).with('prompts/list', anything) do
        lists += 1
        { 'prompts' => [{ 'name' => "p#{lists}" }], 'ttlMs' => 60_000 }
      end

      expect(server.read_resource('file:///a').first.text).to eq('read 1')
      expect(server.list_prompts.map(&:name)).to eq(['p1'])
      server.cleanup

      expect(server.read_resource('file:///a').first.text).to eq('read 2')
      expect(server.list_prompts.map(&:name)).to eq(['p2'])
    end

    it 'routes notifications from the SSE stream through cache invalidation' do
      lists = 0
      allow(server).to receive(:rpc_request).with('prompts/list', anything) do
        lists += 1
        { 'prompts' => [{ 'name' => "p#{lists}" }], 'ttlMs' => 60_000 }
      end
      delivered = []
      server.on_notification { |method, _params| delivered << method }

      expect(server.list_prompts.map(&:name)).to eq(['p1'])
      server.send(:process_notification?, { 'method' => 'notifications/prompts/list_changed', 'params' => {} })

      expect(delivered).to eq(['notifications/prompts/list_changed'])
      expect(server.list_prompts.map(&:name)).to eq(['p2'])
    end
  end
end

RSpec.describe 'MCP 2026-07-28 cacheable results — round 5' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def contents(text)
    { 'contents' => [{ 'uri' => 'file:///a', 'text' => text }] }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  # An OAuth provider whose token is taken from a script, one entry per
  # apply_authorization call (the last entry repeats).
  def scripted_provider(tokens)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) do |req|
      token = tokens.size > 1 ? tokens.shift : tokens.first
      req.headers['Authorization'] = "Bearer #{token}" if token
    end
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
  end

  def streamable(provider = nil)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                        oauth_provider: provider)
  end

  it 'drops a read whose cache entry was invalidated while the request was in flight' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(server, [{ 'result' => discover_result },
                          lambda { |_req|
                            server.send(:invalidate_cache_for_notification, 'notifications/resources/updated',
                                        { 'uri' => 'file:///a' })
                            { 'result' => contents('stale').merge('ttlMs' => 60_000) }
                          },
                          { 'result' => contents('fresh').merge('ttlMs' => 60_000) }])

    expect(server.read_resource('file:///a').first.text).to eq('stale')
    expect(server.read_resource('file:///a').first.text).to eq('fresh')
  end

  it 'returns a copy of the freshly read contents, not the cached array' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(server, [{ 'result' => discover_result }, { 'result' => contents('one').merge('ttlMs' => 60_000) }])

    first = server.read_resource('file:///a')
    first.clear

    expect(server.read_resource('file:///a').size).to eq(1)
  end

  it 'revalidates the stale candidate against the credentials the failed re-fetch used' do
    # alice: first list; alice: the pre-fetch probe; bob: the re-fetch itself
    provider = scripted_provider(%w[alice alice bob])
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        lists += 1
        next { status: 503, body: '' } if request.headers['Authorization'] == 'Bearer bob'

        json_response(body['id'], { 'tools' => [tool('alice-tool')], 'ttlMs' => 0, 'cacheScope' => 'private' })
      else
        json_response(body['id'], discover_result)
      end
    end
    server = streamable(provider)

    expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
    expect { server.list_tools }.to raise_error(MCPClient::Errors::MCPError)
  ensure
    server&.cleanup
  end

  it 'keeps the scope and context on a stale placeholder so a change notification cannot unlock a fallback' do
    token = { value: 'alice' }
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) { |req| req.headers['Authorization'] = "Bearer #{token[:value]}" }
    allow(provider).to receive(:respond_to?).and_return(true)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      result = if body['method'] == 'tools/list'
                 { 'tools' => [tool('alice-tool')], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
               else
                 discover_result
               end
      json_response(body['id'], result)
    end
    server = streamable(provider)
    expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
    token[:value] = 'bob'
    # Bob's re-fetch goes out, sees the change notification land, then fails.
    allow(server).to receive(:fetch_tools_list) do
      server.send(:note_request_authorization, 'Bearer bob')
      server.send(:invalidate_cache_for_notification, 'notifications/tools/list_changed')
      raise MCPClient::Errors::TransientServerError, 'HTTP 503'
    end

    expect { server.list_tools }.to raise_error(MCPClient::Errors::TransientServerError)
  ensure
    server&.cleanup
  end

  it 'expires a private list whose pages were fetched under different credentials' do
    # discover, page 1, page 2 (bob), then bob's re-fetches
    provider = scripted_provider(%w[alice alice bob bob])
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        lists += 1
        page = if body.dig('params',
                           'cursor')
                 { 'tools' => [tool('b')] }
               else
                 { 'tools' => [tool('a')], 'nextCursor' => 'p2' }
               end
        json_response(body['id'], page.merge('ttlMs' => 60_000, 'cacheScope' => 'private'))
      else
        json_response(body['id'], discover_result)
      end
    end
    server = streamable(provider)

    expect(server.list_tools.size).to eq(2)
    expect(server.cache_fresh?(:tools)).to be(false)
  ensure
    server&.cleanup
  end

  describe 'on HTTP+SSE' do
    let(:server) do
      MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', headers: { 'Authorization' => 'Bearer alice' })
    end

    before do
      allow(server).to receive(:ensure_initialized)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
    end

    it 'records the resource templates hint' do
      allow(server).to receive(:rpc_request).with('resources/templates/list', anything)
                                            .and_return({ 'resourceTemplates' => [], 'ttlMs' => 60_000 })

      server.list_resource_templates

      expect(server.cache_info(:templates)).to include(ttl_ms: 60_000, fresh: true)
    end

    it 'does not serve a private entry after the Authorization header changes' do
      reads = 0
      allow(server).to receive(:rpc_request).with('resources/read', anything) do
        reads += 1
        contents("read #{reads}").merge('ttlMs' => 60_000, 'cacheScope' => 'private')
      end

      expect(server.read_resource('file:///a').first.text).to eq('read 1')
      server.instance_variable_get(:@headers)['Authorization'] = 'Bearer bob'

      expect(server.read_resource('file:///a').first.text).to eq('read 2')
    end
  end
end

RSpec.describe 'MCP 2026-07-28 cacheable results — round 6' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def contents(text)
    { 'contents' => [{ 'uri' => 'file:///a', 'text' => text }] }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  def provider_with(token)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) { |req| req.headers['Authorization'] = "Bearer #{token[:value]}" }
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
  end

  it 'treats a hinted result without cacheScope as private' do
    token = { value: 'alice' }
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        lists += 1
        json_response(body['id'], { 'tools' => [tool(request.headers['Authorization'])], 'ttlMs' => 60_000 })
      else
        json_response(body['id'], discover_result)
      end
    end
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                                 oauth_provider: provider_with(token))

    expect(server.list_tools.map(&:name)).to eq(['Bearer alice'])
    token[:value] = 'bob'
    expect(server.list_tools.map(&:name)).to eq(['Bearer bob'])
    expect(lists).to eq(2)
    expect(server.cache_info(:tools)).to include(cache_scope: 'private')
  ensure
    server&.cleanup
  end

  it 'leaves the lists stale (not unknown) after cleanup so the client re-fetches' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'tools' => [tool('a')], 'ttlMs' => 60_000 } },
                          { 'result' => discover_result },
                          { 'result' => { 'tools' => [tool('b')], 'ttlMs' => 60_000 } }])
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }])

    expect(client.list_tools.map(&:name)).to eq(['a'])
    server.cleanup
    expect(server.cache_fresh?(:tools)).to be(false)
    expect(server.cache_info(:tools)).to include(fresh: false)
    expect(client.list_tools.map(&:name)).to eq(['b'])
  end

  it 'hands out independent copies of cached resource contents' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'secret',
                                                           'annotations' => { 'audience' => ['user'] } }],
                                          'ttlMs' => 60_000 } }])

    first = server.read_resource('file:///a')
    first.first.text << ' [redacted]'
    first.first.annotations['audience'] << 'assistant'

    second = server.read_resource('file:///a')
    expect(second.first.text).to eq('secret')
    expect(second.first.annotations['audience']).to eq(['user'])
  end

  it 'does not retain raw credentials in the request context' do
    token = { value: 'alice' }
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      json_response(body['id'], body['method'] == 'tools/list' ? { 'tools' => [], 'ttlMs' => 60_000 } : discover_result)
    end
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                                 oauth_provider: provider_with(token))

    server.list_tools

    context = server.send(:request_authorization_context)
    expect(context).to be_a(String)
    expect(context).not_to include('alice')
    expect(Thread.current.keys.map(&:to_s).grep(/mcp_client/).map { |k| Thread.current[k.to_sym].to_s })
      .to all(satisfy { |v| !v.include?('alice') })
  ensure
    server&.cleanup
  end

  it 'does not store a resources/list that was invalidated while in flight' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    script_stdio(server, [{ 'result' => discover_result },
                          lambda { |_req|
                            server.send(:invalidate_cache_for_notification, 'notifications/resources/list_changed')
                            { 'result' => { 'resources' => [{ 'uri' => 'file:///a', 'name' => 'a' }],
                                            'ttlMs' => 60_000 } }
                          }])

    server.list_resources

    expect(server.cache_fresh?(:resources)).to be(false)
  end
end
