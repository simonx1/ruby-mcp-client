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
      expect(entry.cache_scope).to be_nil
      expect(entry.fresh?(now: 1_000_000.0)).to be(true)
    end

    it 'normalizes an unknown cacheScope to nil and accepts a Float ttlMs' do
      entry = described_class.from_result({ 'ttlMs' => 1500.5, 'cacheScope' => 'shared' }, :v, now: 0.0)
      expect(entry.cache_scope).to be_nil
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

      expect(counts['tools/list']).to eq(3)
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
    expect(server.cache_info(:tools)).to be_nil
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
