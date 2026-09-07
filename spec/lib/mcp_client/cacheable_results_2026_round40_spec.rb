# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, fortieth review round: the DiscoverResult is a
# cacheable result like any other, so the capability gate that reuses it
# obeys the same two rules the lists and reads obey — a privately scoped
# result is never reused across authorization contexts or effective
# parameters, and its freshness runs from the receipt of the response, not
# from the moment the client got round to applying it.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 40' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  # A provider whose token the example rotates, the way a refresh or a
  # step-up does between two requests of one session.
  def rotating_provider(token)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) { |req| req.headers['Authorization'] = "Bearer #{token[:value]}" }
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
  end

  # Alice's discovery declares tools alone; Bob's declares completions too,
  # so which token the client discovered under decides whether `complete` is
  # refused or served.
  def stub_discover_per_token(scope:, ttl_ms: 60_000)
    counts = Hash.new(0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      case body['method']
      when 'server/discover'
        capabilities = { 'tools' => {} }
        capabilities['completions'] = {} if request.headers['Authorization'] == 'Bearer bob'
        json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                    'capabilities' => capabilities, 'ttlMs' => ttl_ms, 'cacheScope' => scope })
      when 'completion/complete'
        json_response(body['id'], { 'completion' => { 'values' => ['x'] } })
      else json_response(body['id'], {})
      end
    end
    counts
  end

  def complete(server)
    server.complete(ref: { 'type' => 'ref/prompt', 'name' => 'p' }, argument: { 'name' => 'a', 'value' => '' })
  end

  describe 'a privately scoped server/discover result' do
    # "Private responses MUST NOT be shared across authorization contexts
    # (e.g. a different access token requires a different cache)." The
    # capability gate reuses the DiscoverResult, so it is bound by that rule
    # too: Alice's capabilities never answer for Bob, however much of its
    # ttlMs is left.
    it 'is not reused by the capability gate after the access token changed' do
      token = { value: 'alice' }
      counts = stub_discover_per_token(scope: 'private')
      server = streamable(oauth_provider: rotating_provider(token))
      server.connect
      expect(counts['server/discover']).to eq(1)

      # Alice's session lacks completions, and hers is the only result cached.
      expect { complete(server) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(counts['server/discover']).to eq(1)

      token[:value] = 'bob'
      expect(complete(server)['values']).to eq(['x'])
      expect(counts['server/discover']).to eq(2)
      expect(counts['completion/complete']).to eq(1)
    ensure
      server&.cleanup
    end

    it 'is not reused after the effective request parameters changed' do
      counts = stub_discover_per_token(scope: 'private')
      server = streamable
      server.request_meta = { 'tenant' => 'a' }
      server.connect
      expect(counts['server/discover']).to eq(1)

      server.request_meta = { 'tenant' => 'b' }
      expect { complete(server) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(counts['server/discover']).to eq(2)
    ensure
      server&.cleanup
    end

    # The other half of the rule: a public result may be shared, so a token
    # rotation on its own is no reason to probe again.
    it 'is still reused across tokens when the server declared it public' do
      token = { value: 'alice' }
      counts = stub_discover_per_token(scope: 'public')
      server = streamable(oauth_provider: rotating_provider(token))
      server.connect

      token[:value] = 'bob'
      expect { complete(server) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(counts['server/discover']).to eq(1)
      expect(counts['completion/complete']).to eq(0)
    ensure
      server&.cleanup
    end
  end

  describe 'the freshness of a server/discover result' do
    # "If ttlMs is positive, the client SHOULD consider the result fresh for
    # that many milliseconds" — after receipt. Everything between the
    # response arriving and the client applying it (a notification delivered
    # off the same stream, host middleware, a slow parse) is time the result
    # has already spent, not time it is owed.
    it 'runs from the receipt of the response, not from the moment it was applied' do
      clock = { now: 50.0 }
      server = MCPClient::ServerStdio.new(command: 'echo test')
      allow(server).to receive(:monotonic_now) { clock[:now] }
      discover = { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                   'capabilities' => {}, 'ttlMs' => 1000 }

      # The response arrived at t=50; applying it took until t=51.5.
      server.send(:note_response_received_at, clock[:now])
      clock[:now] += 1.5
      server.send(:apply_discover_result, discover)

      expect(server.cache_info(:discover)).to include(ttl_ms: 1000, received_at: 50.0, fresh: false)
      expect(server.send(:discovery_fresh?)).to be(false)
    end

    it 'is still the whole ttlMs when the response is applied as it arrives' do
      clock = { now: 50.0 }
      server = MCPClient::ServerStdio.new(command: 'echo test')
      allow(server).to receive(:monotonic_now) { clock[:now] }
      discover = { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                   'capabilities' => {}, 'ttlMs' => 1000 }

      server.send(:note_response_received_at, clock[:now])
      server.send(:apply_discover_result, discover)

      expect(server.send(:discovery_fresh?)).to be(true)
      clock[:now] += 0.9
      expect(server.send(:discovery_fresh?)).to be(true)
      clock[:now] += 0.2
      expect(server.cache_info(:discover)[:fresh]).to be(false)
      expect(server.send(:discovery_fresh?)).to be(false)
    end
  end

  describe 'the stale fallback of a private list whose re-fetch fails' do
    # The pair that makes the authorization rule the deciding factor: the
    # entry, the staleness and the failure are identical, and only the
    # credentials the re-fetch goes out with differ. (Round 10's middleware
    # example cannot show this: its parameters are opaque to the entry, so
    # the fallback is already refused before authorization is consulted.)
    def stub_tools_then_fail(counts)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        if body['method'] == 'tools/list'
          raise Faraday::TimeoutError, 'slow' if counts['tools/list'] > 1

          json_response(body['id'],
                        { 'tools' => [{ 'name' => 'alice-tool', 'description' => 'd', 'inputSchema' => {} }],
                          'ttlMs' => 1_000, 'cacheScope' => 'private' })
        else
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => { 'tools' => {} } })
        end
      end
    end

    it 'serves it to the credentials it was fetched under' do
      clock = { now: 100.0 }
      counts = Hash.new(0)
      stub_tools_then_fail(counts)
      server = streamable(headers: { 'Authorization' => 'Bearer alice' })
      allow(server).to receive(:monotonic_now) { clock[:now] }

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      clock[:now] += 2
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(counts['tools/list']).to eq(2)
    ensure
      server&.cleanup
    end

    it 'never serves it to another set of credentials' do
      clock = { now: 100.0 }
      counts = Hash.new(0)
      stub_tools_then_fail(counts)
      server = streamable(headers: { 'Authorization' => 'Bearer alice' })
      allow(server).to receive(:monotonic_now) { clock[:now] }

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      clock[:now] += 2
      server.instance_variable_get(:@headers)['Authorization'] = 'Bearer bob'

      # The failure reaches the caller: nothing of Alice's list is handed to
      # Bob in its place.
      expect { server.list_tools }.to raise_error(MCPClient::Errors::RequestTimeoutError)
      expect(counts['tools/list']).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'the ttlMs of a list, on the wire' do
    # "Servers MUST provide a ttlMs value that is >= 0": every other JSON
    # value is malformed and leaves the result immediately stale. An
    # explicit null is not the same as an absent hint on a 2026-07-28
    # server, but both end at zero.
    [['null', nil], ['a boolean', true], ['an array', [1]], ['an object', { 'ms' => 1 }],
     ['a string', '60000'], ['a negative number', -1]].each do |description, ttl|
      it "treats #{description} as immediately stale" do
        counts = Hash.new(0)
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          counts[body['method']] += 1
          result = if body['method'] == 'tools/list'
                     { 'tools' => [{ 'name' => 't', 'description' => 'd', 'inputSchema' => {} }], 'ttlMs' => ttl }
                   else
                     { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                       'capabilities' => { 'tools' => {} } }
                   end
          json_response(body['id'], result)
        end
        server = streamable

        server.list_tools
        expect(server.cache_info(:tools)).to include(ttl_ms: 0, fresh: false)
        server.list_tools
        expect(counts['tools/list']).to eq(2)
      ensure
        server&.cleanup
      end
    end
  end
end
