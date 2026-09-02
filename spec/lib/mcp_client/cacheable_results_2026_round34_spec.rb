# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirty-fourth review round: a reservation of the
# host's `request_meta` belongs to the one operation it was opened for. It is
# adopted only by that operation -- never by a later one that happens to use
# the same method first -- and it is spent only by the request that operation
# sends: a raw `rpc_request` (or `send_rpc`, or a public `fetch_*_list`) that
# host code issues from a notification listener or a server-request handler
# reads the host afresh, whatever method it names. And `clear_cache` promises
# fresh data all the way down, including a list a transport is holding under a
# positive `ttlMs`.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 34' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def sse_response(events)
    { status: 200, body: events.map { |event| "event: message\ndata: #{JSON.generate(event)}\n\n" }.join,
      headers: { 'Content-Type' => 'text/event-stream' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'description' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def client_for(*servers, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(*servers)
    MCPClient::Client.new(mcp_server_configs: servers.map { { type: 'stdio', command: 'echo test' } }, **opts)
  end

  # One host callable, shared by every server in a test, vending a fresh value
  # each time it is read: the value a request carries names the evaluation it
  # was built from, and no two requests can carry the same one by accident.
  # @param servers [Array<MCPClient::ServerBase>]
  # @return [Proc] returns how many evaluations have been made so far
  def shared_nonce_meta(*servers)
    issued = 0
    servers.each do |server|
      server.request_meta = lambda {
        issued += 1
        { 'baggage' => "nonce=#{issued}" }
      }
    end
    -> { issued }
  end

  # @param message [Hash] a JSON-RPC message
  # @return [Integer, nil] the nonce its host metadata carried
  def nonce_of(message)
    baggage = message.dig('params', '_meta', 'baggage')
    baggage && Integer(baggage[/\d+/])
  end

  # A stdio transport that never spawns anything: the messages it builds are
  # the ones a real one would send, which is where the rule lives.
  def unconnected_stdio
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
    shared_nonce_meta(server)
    server
  end

  describe 'the operation a reservation belongs to' do
    it 'is not the next operation that happens to use the same method' do
      server = unconnected_stdio
      reservation = server.send(:open_request_meta_hold, 'tools/list')

      begin
        # The listing weighs its decision on what its own fetch would carry.
        weighed = server.send(:current_params_fingerprint)

        # Another listing begins before that fetch does -- a list a
        # notification listener runs on a server the loop has not reached.
        other = server.send(:holding_request_meta, 'tools/list') do
          server.send(:current_params_fingerprint)
          server.send(:build_jsonrpc_request, 'tools/list', {}, 1)
        end

        # It reserved its own evaluation and left this one alone.
        expect(nonce_of(other)).to eq(2)
        expect(server.send(:current_params_fingerprint)).to eq(weighed)

        # The fetch the reservation was opened for adopts it by name.
        server.send(:offer_request_meta_hold, reservation)
        own = server.send(:holding_request_meta, 'tools/list') do
          server.send(:build_jsonrpc_request, 'tools/list', {}, 2)
        end
        expect(nonce_of(own)).to eq(1)
      ensure
        server.send(:close_request_meta_hold)
      end
    ensure
      server&.cleanup
    end

    it 'adopts a reservation offered to it once, and never again' do
      server = unconnected_stdio
      reservation = server.send(:open_request_meta_hold, 'tools/list')

      begin
        server.send(:current_params_fingerprint)
        server.send(:offer_request_meta_hold, reservation)
        first = server.send(:holding_request_meta, 'tools/list') do
          server.send(:build_jsonrpc_request, 'tools/list', {}, 1)
        end
        second = server.send(:holding_request_meta, 'tools/list') do
          server.send(:build_jsonrpc_request, 'tools/list', {}, 2)
        end

        expect(nonce_of(first)).to eq(1)
        expect(nonce_of(second)).to eq(2)
      ensure
        server.send(:close_request_meta_hold)
      end
    ensure
      server&.cleanup
    end

    it 'is withdrawn again when the operation it was offered to never runs' do
      server = unconnected_stdio
      reservation = server.send(:open_request_meta_hold, 'tools/list')

      begin
        server.send(:current_params_fingerprint)
        server.send(:offer_request_meta_hold, reservation)
        server.send(:withdraw_request_meta_hold)
        later = server.send(:holding_request_meta, 'tools/list') do
          server.send(:build_jsonrpc_request, 'tools/list', {}, 1)
        end

        expect(nonce_of(later)).to eq(2)
      ensure
        server.send(:close_request_meta_hold)
      end
    ensure
      server&.cleanup
    end

    it 'is out of reach of every request host code issues, whatever its method' do
      server = unconnected_stdio

      built = server.send(:holding_request_meta, 'tools/list') do
        server.send(:current_params_fingerprint)
        # The transport hands control to a notification listener, which
        # issues a raw request of the very method the listing holds.
        raw = server.send(:outside_request_meta_hold) do
          [server.send(:build_jsonrpc_request, 'tools/list', {}, 1),
           server.send(:build_jsonrpc_request, 'tools/call', {}, 2)]
        end
        expect(raw.map { |message| nonce_of(message) }).to eq([2, 3])
        server.send(:build_jsonrpc_request, 'tools/list', {}, 3)
      end

      expect(nonce_of(built)).to eq(1)
    ensure
      server&.cleanup
    end
  end

  describe 'a client listing across its servers' do
    # A stdio transport whose wire is scripted: every request it builds is
    # recorded exactly as it was built, and answered in place.
    # @param sent [Array<Hash>] the log every request is appended to
    # @yield [Hash] each request, before it is answered
    def scripted_stdio(sent, &listener)
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 2)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      allow(server).to receive(:ensure_initialized)
      allow(server).to receive(:send_request) do |request|
        sent << request
        listener&.call(request)
        answer_stdio(server, request)
      end
      server
    end

    def answer_stdio(server, request)
      result = case request['method']
               when 'tools/list' then { 'tools' => [tool('t')], 'ttlMs' => 0 }
               else {}
               end
      server.instance_variable_get(:@mutex).synchronize do
        server.instance_variable_get(:@pending)[request['id']] =
          { 'jsonrpc' => '2.0', 'id' => request['id'], 'result' => result }
        server.instance_variable_get(:@cond).broadcast
      end
    end

    it "leaves a sibling server's reservation to the fetch it was opened for" do
      sent = []
      nested = { count: 0 }
      second = scripted_stdio(sent)
      first = scripted_stdio(sent) do |request|
        next unless request['method'] == 'tools/list' && nested[:count].zero?

        # A listener the first server's exchange runs lists the second
        # server -- which the loop has not reached, and whose reservation is
        # therefore still waiting for the fetch it was opened for.
        nested[:count] += 1
        second.list_tools
      end
      issued = shared_nonce_meta(first, second)
      client = client_for(first, second)

      client.list_tools

      expect(nested[:count]).to eq(1)
      # Three requests went out, each carrying its own evaluation in the order
      # they were made: the nested list reserved one of its own, and the fetch
      # the client weighed for the second server carried the one it weighed.
      expect(sent.map { |request| nonce_of(request) }).to eq([1, 2, 3])
      expect(issued.call).to eq(3)
    ensure
      first&.cleanup
      second&.cleanup
    end
  end

  describe 'a raw request a notification listener issues inside a listing' do
    it 'reads the host afresh and leaves the reservation to the list holding it' do
      log = []
      armed = { now: false }
      raw = { count: 0 }
      server = nil
      stub_request(:get, url).to_return(status: 405, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        log << [body['method'], nonce_of(body)]
        case body['method']
        when 'tools/list' then json_response(body['id'], { 'tools' => [tool('t')], 'ttlMs' => 60_000 })
        when 'server/discover'
          # A Streamable HTTP response may carry server messages before the
          # response itself; they are dispatched synchronously, on this thread.
          sse_response([{ 'jsonrpc' => '2.0', 'method' => 'notifications/message',
                          'params' => { 'level' => 'info', 'data' => 'hi' } },
                        { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result }])
        else { status: 202, body: '' }
        end
      end

      server = streamable
      shared_nonce_meta(server)
      server.on_notification do |method, _params|
        next unless method == 'notifications/message'
        next unless armed[:now] && raw[:count].zero?

        raw[:count] += 1
        server.rpc_request('tools/list', {})
      end

      server.list_tools
      # The listener only fires inside the reconnect the second list triggers,
      # after that list has already reserved the evaluation it weighed.
      armed[:now] = true
      server.instance_variable_set(:@initialized, false)
      server.list_tools

      expect(raw[:count]).to eq(1)
      lists = log.filter_map { |method, nonce| nonce if method == 'tools/list' }
      expect(lists.size).to eq(3)
      # The listing's own fetch carries the evaluation its decision was
      # weighed on; the listener's raw request read the host afresh, later.
      expect(lists.last).to be < lists[1]
    ensure
      server&.cleanup
    end
  end

  describe 'MCPClient::Client#clear_cache' do
    def stdio_listing(method, result)
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      allow(server).to receive(:ensure_initialized)
      calls = 0
      allow(server).to receive(:rpc_request) do |called, _params = {}, **_opts|
        raise "unexpected #{called}" unless called == method

        calls += 1
        result
      end
      [server, -> { calls }]
    end

    {
      tools: ['tools/list', { 'tools' => [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }] }],
      prompts: ['prompts/list', { 'prompts' => [{ 'name' => 'p' }] }],
      resources: ['resources/list', { 'resources' => [{ 'uri' => 'file:///a.txt', 'name' => 'a' }] }]
    }.each do |kind, (method, payload)|
      it "really re-lists #{kind} a transport is holding under a positive ttlMs" do
        server, calls = stdio_listing(method, payload.merge('ttlMs' => 60_000, 'cacheScope' => 'public'))
        client = client_for(server)

        client.public_send(:"list_#{kind}")
        client.clear_cache
        client.public_send(:"list_#{kind}")

        expect(calls.call).to eq(2)
      ensure
        server&.cleanup
      end
    end

    it 'reaches the transports behind a cleanup too' do
      server, calls = stdio_listing('tools/list',
                                    { 'tools' => [{ 'name' => 't', 'inputSchema' => { 'type' => 'object' } }],
                                      'ttlMs' => 60_000, 'cacheScope' => 'public' })
      allow(server).to receive(:cleanup)
      client = client_for(server)

      client.list_tools
      client.cleanup
      client.list_tools

      expect(calls.call).to eq(2)
    end
  end
end
