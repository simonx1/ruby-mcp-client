# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirty-third review round: the evaluation of the
# host's `request_meta` that a cache decision reserves belongs to the request
# it was reserved for. It is spent by that request and by nothing else -- not
# by a reconnect's handshake, a re-opened `subscriptions/listen`, a
# cancellation, or a request a notification listener nests inside the
# operation -- and it never outlives the operation that reserved it, whichever
# way that operation ends. A `tools/call` keeps the tool definition it went
# out under in the same way, and a forced refresh really re-lists.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 33' do
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

  def tool(name, extra = {})
    { 'name' => name, 'description' => name, 'inputSchema' => { 'type' => 'object' } }.merge(extra)
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def client_for(*servers, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(*servers)
    MCPClient::Client.new(mcp_server_configs: servers.map { { type: 'stdio', command: 'echo test' } }, **opts)
  end

  # A host callable that vends a fresh value every time it is read, so the
  # evaluation one request carries can be told from any other.
  # @param server [MCPClient::ServerBase]
  # @return [Proc] returns how many evaluations have been made so far
  def nonce_meta(server)
    issued = 0
    server.request_meta = lambda {
      issued += 1
      { 'baggage' => "nonce=#{issued}" }
    }
    -> { issued }
  end

  # @param message [Hash] a JSON-RPC message
  # @return [Integer, nil] the nonce its host metadata carried
  def nonce_of(message)
    baggage = message.dig('params', '_meta', 'baggage')
    baggage && Integer(baggage[/\d+/])
  end

  # @param log [Array<Array(String, Integer)>] method/nonce pairs
  # @param method [String]
  # @return [Integer] the nonce the last message of that method carried
  def last_nonce(log, method)
    entry = log.reverse.find { |sent, _| sent == method }
    raise "no #{method} was sent" unless entry

    entry.last
  end

  describe 'the invariant a reservation holds' do
    # A stdio transport, unconnected: the messages are built rather than sent,
    # which is where the rule lives -- a message claims the reservation only
    # when it is the request the reservation was made for.
    def unconnected_stdio
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      nonce_meta(server)
      server
    end

    it 'is spent by the request it was reserved for and by nothing else' do
      server = unconnected_stdio

      built = server.send(:holding_request_meta, 'tools/list') do
        # The cache decision reads what the coming tools/list would carry.
        server.send(:current_params_fingerprint)
        # Everything a reconnect, a timeout or a callback sends meanwhile.
        { discover: server.send(:build_jsonrpc_request, 'server/discover', {}, 1),
          initialized: server.send(:build_jsonrpc_notification, 'notifications/initialized', {}),
          listen: server.send(:build_jsonrpc_request, 'subscriptions/listen',
                              { 'notifications' => ['notifications/tools/list_changed'] }, 2),
          cancelled: server.send(:build_jsonrpc_notification, 'notifications/cancelled', { 'requestId' => 2 }),
          nested: server.send(:build_jsonrpc_request, 'prompts/list', {}, 3),
          list: server.send(:build_jsonrpc_request, 'tools/list', {}, 4) }
      end

      # The decision weighed the first evaluation, and the list it led to is
      # the message that carries it.
      expect(nonce_of(built[:list])).to eq(1)
      # Every other message read the host afresh, each exactly once.
      expect(built.values_at(:discover, :initialized, :listen, :cancelled, :nested).map { |m| nonce_of(m) })
        .to eq([2, 3, 4, 5, 6])
    ensure
      server&.cleanup
    end

    it 'is never spent twice: a second list of the same operation reads afresh' do
      server = unconnected_stdio

      pages = server.send(:holding_request_meta, 'tools/list') do
        server.send(:current_params_fingerprint)
        [server.send(:build_jsonrpc_request, 'tools/list', {}, 1),
         server.send(:build_jsonrpc_request, 'tools/list', { 'cursor' => 'c' }, 2)]
      end

      expect(pages.map { |page| nonce_of(page) }).to eq([1, 2])
    ensure
      server&.cleanup
    end

    it 'does not outlive the operation, however that operation ends' do
      server = unconnected_stdio
      key = server.send(:held_request_meta_key)

      expect do
        server.send(:holding_request_meta, 'tools/list') do
          server.send(:current_params_fingerprint)
          raise MCPClient::Errors::ConnectionError, 'the reconnect failed'
        end
      end.to raise_error(MCPClient::Errors::ConnectionError)
      expect(Thread.current[key]).to be_nil

      # So the next operation reads the host afresh instead of sending the
      # tenant, baggage or nonce the aborted one evaluated.
      after = server.send(:holding_request_meta, 'tools/list') do
        server.send(:build_jsonrpc_request, 'tools/list', {}, 1)
      end
      expect(nonce_of(after)).to eq(2)
      expect(Thread.current[key]).to be_nil
    ensure
      server&.cleanup
    end

    it 'is not stolen by an operation nested inside the one that reserved it' do
      server = unconnected_stdio

      outer = server.send(:holding_request_meta, 'tools/list') do
        server.send(:current_params_fingerprint)
        # The operation is talking to the server now; a listener the response
        # dispatch runs starts an operation of its own.
        server.send(:build_jsonrpc_request, 'server/discover', {}, 1)
        nested = server.send(:holding_request_meta, 'tools/list') do
          server.send(:current_params_fingerprint)
          server.send(:build_jsonrpc_request, 'tools/list', {}, 2)
        end
        expect(nonce_of(nested)).to eq(3)
        server.send(:build_jsonrpc_request, 'tools/list', {}, 3)
      end

      expect(nonce_of(outer)).to eq(1)
    ensure
      server&.cleanup
    end
  end

  describe 'a list whose reconnect fails' do
    # Answers a modern handshake and a bounded tools/list, recording the
    # method and nonce of every request. `broken` makes server/discover fail.
    def stub_recording(broken)
      log = []
      stub_request(:get, url).to_return(status: 405, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        log << [body['method'], nonce_of(body)]
        next { status: 503, body: '' } if broken[:now] && body['method'] == 'server/discover'

        case body['method']
        when 'tools/list' then json_response(body['id'], { 'tools' => [tool('t')], 'ttlMs' => 60_000 })
        when 'prompts/list' then json_response(body['id'], { 'prompts' => [], 'ttlMs' => 60_000 })
        when 'resources/list' then json_response(body['id'], { 'resources' => [], 'ttlMs' => 60_000 })
        when 'server/discover' then json_response(body['id'], discover_result)
        else { status: 202, body: '' }
        end
      end
      log
    end

    it 'leaves nothing on the thread for the next request to send' do
      broken = { now: false }
      log = stub_recording(broken)
      server = streamable
      issued = nonce_meta(server)

      server.list_tools
      # The session is gone and the reconnect the next list triggers fails,
      # after the decision reserved its evaluation for that list.
      server.instance_variable_set(:@initialized, false)
      broken[:now] = true
      expect { server.list_tools }.to raise_error(MCPClient::Errors::MCPError)
      aborted = issued.call

      expect(Thread.current[server.send(:held_request_meta_key)]).to be_nil

      broken[:now] = false
      server.instance_variable_set(:@initialized, false)
      server.list_tools
      # The list that finally goes out reads the host afresh; it never sends
      # the nonce the aborted attempt evaluated.
      expect(last_nonce(log, 'tools/list')).to be > aborted
    ensure
      server&.cleanup
    end

    %w[tools prompts resources].each do |kind|
      it "leaves nothing behind when the client's #{kind} loop aborts" do
        broken = { now: false }
        log = stub_recording(broken)
        server = streamable
        issued = nonce_meta(server)
        client = client_for(server)

        client.public_send(:"list_#{kind}")
        server.instance_variable_set(:@initialized, false)
        broken[:now] = true
        begin
          client.public_send(:"list_#{kind}")
        rescue MCPClient::Errors::MCPError
          nil
        end
        aborted = issued.call

        expect(Thread.current[server.send(:held_request_meta_key)]).to be_nil

        broken[:now] = false
        server.instance_variable_set(:@initialized, false)
        client.public_send(:"list_#{kind}")
        expect(last_nonce(log, "#{kind}/list")).to be > aborted
      ensure
        server&.cleanup
      end
    end
  end

  describe "a request a notification listener nests inside a reconnect's handshake" do
    it 'reads the host afresh instead of consuming the list its reconnect serves' do
      log = []
      nested_done = { count: 0 }
      armed = { now: false }
      server = nil
      stub_request(:get, url).to_return(status: 405, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        log << [body['method'], nonce_of(body)]
        case body['method']
        when 'tools/list' then json_response(body['id'], { 'tools' => [tool('t')], 'ttlMs' => 60_000 })
        when 'prompts/list' then json_response(body['id'], { 'prompts' => [], 'ttlMs' => 0 })
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
      issued = nonce_meta(server)
      server.on_notification do |method, _params|
        next unless method == 'notifications/message'
        next unless armed[:now] && nested_done[:count].zero?

        nested_done[:count] += 1
        server.list_prompts
      end

      server.list_tools
      # The listener only nests inside the reconnect the second list triggers.
      armed[:now] = true
      server.instance_variable_set(:@initialized, false)
      server.list_tools

      expect(nested_done[:count]).to eq(1)
      expect(issued.call).to be >= 4
      # The nested list read the host after the reconnected list's decision
      # had already reserved its own evaluation, and left that one alone.
      expect(last_nonce(log, 'tools/list')).to be < last_nonce(log, 'prompts/list')
      expect(last_nonce(log, 'tools/list')).to be < last_nonce(log, 'server/discover')
    ensure
      server&.cleanup
    end
  end

  describe 'the tool definition a call is validated against' do
    def greet(required)
      tool('greet',
           'outputSchema' => { 'type' => 'object', 'properties' => { required => { 'type' => 'string' } },
                               'required' => [required] })
    end

    it 'survives a call a notification listener nests inside it' do
      listed = { count: 0 }
      nested = { count: 0 }
      client = nil
      stub_request(:get, url).to_return(status: 405, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'tools/list'
          listed[:count] += 1
          # The list the outer call derives its headers from is the one it
          # goes out under; a later one carries a definition it was never
          # answered under.
          definition = listed[:count] <= 2 ? greet('greeting') : greet('farewell')
          json_response(body['id'], { 'tools' => [definition, tool('other')], 'ttlMs' => 0 })
        when 'tools/call'
          if body.dig('params', 'name') == 'greet'
            sse_response([{ 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed', 'params' => {} },
                          { 'jsonrpc' => '2.0', 'id' => body['id'],
                            'result' => { 'content' => [{ 'type' => 'text', 'text' => 'hi' }],
                                          'structuredContent' => { 'greeting' => 'hi' } } }])
          else
            json_response(body['id'], { 'content' => [{ 'type' => 'text', 'text' => 'ok' }] })
          end
        else json_response(body['id'], discover_result)
        end
      end

      server = streamable
      client = client_for(server, validate_structured_content: :strict)
      server.on_notification do |method, _params|
        next unless method == 'notifications/tools/list_changed'
        next unless nested[:count].zero?

        nested[:count] += 1
        client.call_tool('other', {})
      end

      result = client.call_tool('greet', {})

      expect(nested[:count]).to eq(1)
      expect(result['structuredContent']).to eq({ 'greeting' => 'hi' })
      expect(Thread.current[server.send(:called_tool_definition_key)]).to be_nil
    ensure
      server&.cleanup
    end

    it 'belongs to the call that recorded it, never to a nested one' do
      server = streamable
      outer = MCPClient::Tool.new(name: 'greet', description: 'g', schema: { 'type' => 'object' }, server: server)
      inner = MCPClient::Tool.new(name: 'other', description: 'o', schema: { 'type' => 'object' }, server: server)
      taken = nil

      server.send(:recording_called_tool_definition) do
        server.send(:recording_called_tool_definition) do
          server.send(:note_called_tool_definition, 'greet', outer)
          # The response dispatch runs a listener that calls another tool.
          server.send(:recording_called_tool_definition) do
            server.send(:recording_called_tool_definition) do
              server.send(:note_called_tool_definition, 'other', inner)
            end
            expect(server.send(:take_called_tool_definition, 'other')).to eq([inner])
          end
        end
        taken = server.send(:take_called_tool_definition, 'greet')
      end

      expect(taken).to eq([outer])
      expect(Thread.current[server.send(:called_tool_definition_key)]).to be_nil
    ensure
      server&.cleanup
    end
  end

  describe 'a forced refresh against a transport holding a bounded list' do
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
      it "really re-lists #{kind} the server bounded with a positive ttlMs" do
        server, calls = stdio_listing(method, payload.merge('ttlMs' => 60_000, 'cacheScope' => 'public'))
        client = client_for(server)

        client.public_send(:"list_#{kind}")
        client.public_send(:"list_#{kind}", cache: false)
        client.public_send(:"list_#{kind}", cache: false)

        expect(calls.call).to eq(3)
      ensure
        server&.cleanup
      end

      it "still serves a fresh #{kind} list when the cache is allowed" do
        server, calls = stdio_listing(method, payload.merge('ttlMs' => 60_000, 'cacheScope' => 'public'))
        client = client_for(server)

        client.public_send(:"list_#{kind}")
        client.public_send(:"list_#{kind}")

        expect(calls.call).to eq(1)
      ensure
        server&.cleanup
      end
    end
  end
end
