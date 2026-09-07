# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 cacheable results: regression suite.
#
# These examples were written one adversarial review round at a time, each
# pinning a defect that round found. They are gathered here by subject
# rather than by the round that produced them; the round is noted on each
# section only because the review notes refer to it. Every example here
# covers production code no other spec reaches.

# --- verify ----------------------------------------------------------------

# MCP 2026-07-28 caching, verification round: the credentials and the effective
# parameters a result is bound to are the ones its own request went out with,
# whatever the host's middleware does to the environment afterwards; a cleanup
# gives the cache an identity no request already in flight can match; a raw
# `tools/call` host code nests inside a call records into a slot of its own; a
# cursor the server rejects takes the pages cached under it with it; and a
# template list a legacy server put no hint on is asked for again.
RSpec.describe 'MCP 2026-07-28 cacheable results — verification round' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result, headers = {})
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' }.merge(headers) }
  end

  def error_response(id, code, message)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id,
                                       'error' => { 'code' => code, 'message' => message }),
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

  def template(name)
    { 'uriTemplate' => "file:///{#{name}}", 'name' => name }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def plain_http(**opts)
    MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  # A minimal OAuth provider: it writes whatever bearer it currently holds,
  # and nothing at all once that is nil.
  def provider_holding(token)
    Class.new do
      def initialize(token)
        @token = token
      end

      def apply_authorization(request)
        request.headers['Authorization'] = "Bearer #{@token.value}" if @token.value
      end
    end.new(token)
  end

  describe 'the Authorization a private result is bound to' do
    # No request phase at all, so the freshness probe steps over it and the
    # context stays knowable — but its response phase rewrites the very
    # environment the request was sent from.
    def redacting_middleware
      Class.new(Faraday::Middleware) do
        def on_complete(env)
          env.request_headers.delete('Authorization')
        end
      end
    end

    it 'is what the request carried, not what response middleware left in the environment' do
      reads = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'resources/read'
          bearer = request.headers['Authorization'].to_s.sub(/\ABearer /, '')
          reads << bearer
          json_response(body['id'],
                        { 'contents' => [{ 'uri' => 'file:///secret', 'text' => "#{bearer}-data" }],
                          'ttlMs' => 60_000, 'cacheScope' => 'private' })
        else
          json_response(body['id'], discover_result)
        end
      end

      token = Struct.new(:value).new('alice')
      klass = redacting_middleware
      server = streamable(oauth_provider: provider_holding(token), faraday_config: ->(f) { f.use klass })

      expect(server.read_resource('file:///secret').map(&:text)).to eq(['alice-data'])

      # The credentials are gone; Alice's private result must not answer for
      # the anonymous context ("MUST NOT be shared across authorization
      # contexts").
      token.value = nil
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['-data'])
      # Both reads reached the server: the second under no credentials at all.
      expect(reads).to eq(['alice', ''])
    ensure
      server&.cleanup
    end
  end

  describe 'a request body the host middleware may rewrite' do
    # Writes a locale of its own into the effective parameters, so the request
    # the server answers is not the request the transport built.
    def locale_middleware(locale)
      Class.new(Faraday::Middleware) do
        define_method(:on_request) do |env|
          body = JSON.parse(env.body)
          params = (body['params'] ||= {})
          params['_meta'] = (params['_meta'] || {}).merge('locale' => locale.value)
          env.body = JSON.generate(body)
        end
      end
    end

    it 'is never answered from a public entry another locale produced' do
      locales = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'resources/read'
          locales << body.dig('params', '_meta', 'locale')
          greeting = locales.last == 'fr' ? 'Bonjour' : 'Hello'
          json_response(body['id'],
                        { 'contents' => [{ 'uri' => 'file:///greeting', 'text' => greeting }],
                          'ttlMs' => 60_000, 'cacheScope' => 'public' })
        else
          json_response(body['id'], discover_result)
        end
      end

      locale = Struct.new(:value).new('en')
      klass = locale_middleware(locale)
      server = streamable(faraday_config: ->(f) { f.use klass })

      expect(server.read_resource('file:///greeting').map(&:text)).to eq(['Hello'])

      locale.value = 'fr'
      expect(server.read_resource('file:///greeting').map(&:text)).to eq(['Bonjour'])
      expect(locales).to eq(%w[en fr])
    ensure
      server&.cleanup
    end

    it 'still serves a public entry when the whole stack is framework middleware' do
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'resources/read'
          reads += 1
          json_response(body['id'],
                        { 'contents' => [{ 'uri' => 'file:///greeting', 'text' => 'Hello' }],
                          'ttlMs' => 60_000, 'cacheScope' => 'public' })
        else
          json_response(body['id'], discover_result)
        end
      end

      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', 'static' })

      expect(server.read_resource('file:///greeting').map(&:text)).to eq(['Hello'])
      expect(server.read_resource('file:///greeting').map(&:text)).to eq(['Hello'])
      expect(reads).to eq(1)
    ensure
      server&.cleanup
    end
  end

  describe 'a cleanup that lands while a request is in flight' do
    it 'moves the generation of a key an invalidation already bumped' do
      server = streamable
      before = server.send(:cache_epoch, 'read:file:///a')
      server.send(:invalidate_read_cache, 'file:///a')
      invalidated = server.send(:cache_epoch, 'read:file:///a')

      server.send(:clear_result_cache)

      expect(invalidated).not_to eq(before)
      expect(server.send(:cache_epoch, 'read:file:///a')).not_to eq(invalidated)
      expect(server.send(:cache_epoch, 'read:file:///a')).not_to eq(before)
    ensure
      server&.cleanup
    end

    it 'keeps the response it overtook out of the cache' do
      entered = Queue.new
      release = Queue.new
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'resources/read'
          reads += 1
          if reads == 1
            entered << true
            release.pop
          end
          json_response(body['id'],
                        { 'contents' => [{ 'uri' => 'file:///a', 'text' => "v#{reads}" }],
                          'ttlMs' => 60_000, 'cacheScope' => 'public' })
        else
          json_response(body['id'], discover_result)
        end
      end

      server = streamable
      # One invalidation of this very key: its generation is now one above the
      # base, which is exactly what a base bump alone would produce.
      server.send(:invalidate_read_cache, 'file:///a')

      in_flight = Thread.new { server.read_resource('file:///a').map(&:text) }
      entered.pop
      server.send(:clear_result_cache)
      release << true

      expect(in_flight.value).to eq(['v1'])
      expect(server.read_resource('file:///a').map(&:text)).to eq(['v2'])
      expect(reads).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'a list invalidated while its own fetch was in flight' do
    # Pauses the first response of `method` until the caller releases it.
    def stub_paused_list(method, key, item)
      entered = Queue.new
      release = Queue.new
      sent = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == method
          sent += 1
          if sent == 1
            entered << true
            release.pop
          end
          json_response(body['id'], { key => [item.call(sent)], 'ttlMs' => 60_000, 'cacheScope' => 'public' })
        else
          json_response(body['id'], discover_result)
        end
      end
      [entered, release, -> { sent }]
    end

    it 'is not installed as fresh by an auto-paginated fetch' do
      entered, release, sent = stub_paused_list('tools/list', 'tools', ->(n) { tool("t#{n}") })
      server = streamable

      in_flight = Thread.new { server.list_tools.map(&:name) }
      entered.pop
      # A tools/list_changed notification lands while the fetch is in flight.
      server.send(:invalidate_cache, :tools)
      release << true

      expect(in_flight.value).to eq(['t1'])
      expect(server.list_tools.map(&:name)).to eq(['t2'])
      expect(sent.call).to eq(2)
    ensure
      server&.cleanup
    end

    it 'is not installed as fresh by a single-page fetch' do
      entered, release, sent = stub_paused_list('resources/list', 'resources',
                                                ->(n) { { 'uri' => "file:///r#{n}", 'name' => "r#{n}" } })
      server = streamable

      in_flight = Thread.new { server.list_resources['resources'].map(&:name) }
      entered.pop
      server.send(:invalidate_cache, :resources)
      release << true

      expect(in_flight.value).to eq(['r1'])
      expect(server.list_resources['resources'].map(&:name)).to eq(['r2'])
      expect(sent.call).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe "a host's cache-invalidation callback" do
    it 'runs on an invalidating notification, before the notification is handed on' do
      order = []
      stale = nil
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'tools/list'
          json_response(body['id'], { 'tools' => [tool('t')], 'ttlMs' => 60_000, 'cacheScope' => 'public' })
        else
          json_response(body['id'], discover_result)
        end
      end

      server = streamable
      expect(server.list_tools.map(&:name)).to eq(['t'])
      expect(server.cache_fresh?(:tools)).to be(true)

      server.send(:on_cache_invalidation) do |method, _params|
        order << [:cache, method]
        # The transport's own entry is already stale here, so a cache built on
        # top of it can be dropped in step rather than a moment later.
        stale = server.cache_fresh?(:tools)
      end
      server.on_notification { |method, _params| order << [:host, method] }

      server.send(:route_notification, 'notifications/tools/list_changed', {})

      expect(order).to eq([[:cache, 'notifications/tools/list_changed'],
                           [:host, 'notifications/tools/list_changed']])
      expect(stale).to be(false)
    ensure
      server&.cleanup
    end
  end

  describe 'a raw tools/call a notification listener nests inside a call' do
    def greet(description)
      tool('greet', 'description' => description)
    end

    it 'leaves the outer call the definition its own request went out under' do
      listed = 0
      stub_request(:get, url).to_return(status: 405, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'tools/list'
          listed += 1
          json_response(body['id'], { 'tools' => [greet("v#{listed}"), tool('other')], 'ttlMs' => 0 })
        when 'tools/call'
          if body.dig('params', 'name') == 'greet'
            sse_response([{ 'jsonrpc' => '2.0', 'method' => 'notifications/message',
                            'params' => { 'level' => 'info', 'data' => 'hi' } },
                          { 'jsonrpc' => '2.0', 'id' => body['id'],
                            'result' => { 'content' => [{ 'type' => 'text', 'text' => 'hi' }] } }])
          else
            json_response(body['id'], { 'content' => [{ 'type' => 'text', 'text' => 'ok' }] })
          end
        else json_response(body['id'], discover_result)
        end
      end

      server = streamable
      nested = 0
      server.on_notification do |method, _params|
        next unless method == 'notifications/message'
        next unless nested.zero?

        nested += 1
        # Host code, not the call: a raw request of the very method the open
        # call is waiting on.
        server.rpc_request('tools/call', { 'name' => 'other', 'arguments' => {} })
      end

      taken = server.send(:recording_called_tool_definition) do
        server.call_tool('greet', {})
        server.send(:take_called_tool_definition, 'greet')
      end

      expect(nested).to eq(1)
      expect(taken&.first&.name).to eq('greet')
      expect(taken&.first&.description).to eq('v1')
      expect(Thread.current[server.send(:called_tool_definition_key)]).to be_nil
    ensure
      server&.cleanup
    end
  end

  describe 'a cursor the server no longer accepts' do
    def stub_templates_with_dead_cursor
      cursors = []
      page = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'resources/templates/list'
          cursor = body.dig('params', 'cursor')
          cursors << cursor
          if cursor
            error_response(body['id'], MCPClient::Errors::Codes::INVALID_PARAMS, 'Expired cursor')
          else
            page += 1
            json_response(body['id'],
                          { 'resourceTemplates' => [template("page#{page}")], 'nextCursor' => "cursor-#{page}",
                            'ttlMs' => 60_000, 'cacheScope' => 'public' })
          end
        else
          json_response(body['id'], discover_result)
        end
      end
      cursors
    end

    it 'takes the pages cached under it with it' do
      cursors = stub_templates_with_dead_cursor
      server = streamable

      first = server.list_resource_templates
      expect(first['nextCursor']).to eq('cursor-1')

      expect { server.list_resource_templates(cursor: 'cursor-1') }
        .to raise_error(MCPClient::Errors::ServerError)

      # The sequence that cursor belonged to is gone, so the first page cached
      # from it must not be handed out again.
      expect(server.list_resource_templates['nextCursor']).to eq('cursor-2')
      expect(cursors).to eq([nil, 'cursor-1', nil])
    ensure
      server&.cleanup
    end

    it 'restarts an auto-paginated list once from the first page' do
      cursors = []
      generation = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'tools/list'
          cursor = body.dig('params', 'cursor')
          cursors << cursor
          if cursor.nil?
            generation += 1
            json_response(body['id'], { 'tools' => [tool("a#{generation}")], 'nextCursor' => "page2-#{generation}" })
          elsif generation == 1
            error_response(body['id'], MCPClient::Errors::Codes::INVALID_PARAMS, 'Expired cursor')
          else
            json_response(body['id'], { 'tools' => [tool("b#{generation}")] })
          end
        else
          json_response(body['id'], discover_result)
        end
      end

      server = streamable

      expect(server.list_tools.map(&:name)).to eq(%w[a2 b2])
      expect(cursors).to eq([nil, 'page2-1', nil, 'page2-2'])
    ensure
      server&.cleanup
    end
  end

  describe 'a template list a legacy server put no freshness hint on' do
    # A 2025-11-25 handshake: nothing the server sends carries ttlMs, so the
    # client keeps the behaviour it had before it cached anything.
    def stub_legacy_templates
      listed = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          json_response(body['id'],
                        { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'resources' => {} },
                          'serverInfo' => { 'name' => 'test', 'version' => '1.0' } })
        when 'notifications/initialized' then { status: 202, body: '' }
        when 'resources/templates/list'
          listed += 1
          json_response(body['id'], { 'resourceTemplates' => [template("v#{listed}")] })
        else json_response(body['id'], {})
        end
      end
      -> { listed }
    end

    shared_examples 'a transport that asks a legacy server again' do
      it 'fetches the template list every time' do
        listed = stub_legacy_templates

        expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['v1'])
        expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['v2'])
        expect(listed.call).to eq(2)
      ensure
        server&.cleanup
      end
    end

    context 'with the plain HTTP transport' do
      subject(:server) { plain_http(protocol: :legacy) }

      it_behaves_like 'a transport that asks a legacy server again'
    end

    context 'with the Streamable HTTP transport' do
      subject(:server) { streamable(protocol: :legacy) }

      it_behaves_like 'a transport that asks a legacy server again'
    end

    context 'with the HTTP+SSE transport' do
      subject(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 1) }

      it 'fetches the template list every time' do
        listed = 0
        allow(server).to receive(:ensure_initialized)
        allow(server).to receive(:rpc_request) do |method, _params = {}, **_opts|
          raise "unexpected #{method}" unless method == 'resources/templates/list'

          listed += 1
          { 'resourceTemplates' => [template("v#{listed}")] }
        end

        expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['v1'])
        expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['v2'])
        expect(listed).to eq(2)
      end
    end

    it 'still serves a template list a 2026 server bounded with a positive ttlMs' do
      listed = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'resources/templates/list'
          listed += 1
          json_response(body['id'],
                        { 'resourceTemplates' => [template("v#{listed}")], 'ttlMs' => 60_000,
                          'cacheScope' => 'public' })
        else
          json_response(body['id'], discover_result)
        end
      end

      server = streamable

      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['v1'])
      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['v1'])
      expect(listed).to eq(1)
    ensure
      server&.cleanup
    end
  end

  # The error mapping of a read is exercised through the wire, after a cached
  # copy of that very URI has expired: the failure must not be cached, and the
  # next read must be able to succeed.
  describe 'a cached read whose next fetch fails' do
    def stub_expiring_read(code, era)
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          json_response(body['id'],
                        { 'protocolVersion' => era, 'capabilities' => { 'resources' => {} },
                          'serverInfo' => { 'name' => 'test', 'version' => '1.0' } })
        when 'notifications/initialized' then { status: 202, body: '' }
        when 'resources/read'
          reads += 1
          if reads == 2
            error_response(body['id'], code, 'gone')
          else
            json_response(body['id'],
                          { 'contents' => [{ 'uri' => 'file:///a', 'text' => "v#{reads}" }], 'ttlMs' => 20 })
          end
        else json_response(body['id'], discover_result)
        end
      end
      -> { reads }
    end

    def read_after_expiry(server)
      expect(server.read_resource('file:///a').map(&:text)).to eq(['v1'])
      # Served from the entry while it is fresh: no second request.
      expect(server.read_resource('file:///a').map(&:text)).to eq(['v1'])
      allow(server).to receive(:monotonic_now).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60)
    end

    it 'maps -32602 to ResourceNotFound on a modern server and caches nothing' do
      reads = stub_expiring_read(MCPClient::Errors::Codes::INVALID_PARAMS, '2026-07-28')
      server = streamable
      read_after_expiry(server)

      expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceNotFound)
      expect(server.read_resource('file:///a').map(&:text)).to eq(['v3'])
      expect(reads.call).to eq(3)
    ensure
      server&.cleanup
    end

    it 'maps -32002 to ResourceNotFound on a legacy server and caches nothing' do
      reads = stub_expiring_read(MCPClient::Errors::Codes::LEGACY_RESOURCE_NOT_FOUND, '2025-11-25')
      server = streamable(protocol: :legacy)
      read_after_expiry(server)

      expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceNotFound)
      expect(server.read_resource('file:///a').map(&:text)).to eq(['v3'])
      expect(reads.call).to eq(3)
    ensure
      server&.cleanup
    end

    it 'keeps -32602 a plain Invalid params on a legacy server' do
      reads = stub_expiring_read(MCPClient::Errors::Codes::INVALID_PARAMS, '2025-11-25')
      server = streamable(protocol: :legacy)
      read_after_expiry(server)

      expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceReadError)
      expect(server.read_resource('file:///a').map(&:text)).to eq(['v3'])
      expect(reads.call).to eq(3)
    ensure
      server&.cleanup
    end
  end
end

# --- round8 ----------------------------------------------------------------

# MCP 2026-07-28 caching, eighth review round: a hint recorded without its
# list never gates serving a previous list, HTTP+SSE binds results to the
# credentials of the POST that fetched them, a re-fetch that never recorded
# its credentials has no stale fallback, a malformed resources/read result
# is rejected, and a read's receipt time precedes its conversion.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 8' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def scripted_provider(tokens)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) do |req|
      token = tokens.size > 1 ? tokens.shift : tokens.first
      raise token if token.is_a?(Exception)

      req.headers['Authorization'] = "Bearer #{token}" if token
    end
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
  end

  def streamable(provider = nil, headers: {})
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                        oauth_provider: provider, headers: headers)
  end

  # Alice lists private tools; Bob's re-fetch records a fresh public hint
  # whose list cannot be converted. Nothing may serve Alice's list to Bob.
  def stub_failed_refetch
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

      lists += 1
      result = case lists
               when 1 then { 'tools' => [tool('admin-secret')], 'ttlMs' => 0, 'cacheScope' => 'private' }
               when 2 then { 'tools' => ['malformed'], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
               else { 'tools' => [tool('bob-tool')], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
               end
      json_response(body['id'], result)
    end
    -> { lists }
  end

  it 'never serves the previous list under a hint recorded without one' do
    lists = stub_failed_refetch
    server = streamable(scripted_provider(%w[alice alice bob]))

    expect(server.list_tools.map(&:name)).to eq(['admin-secret'])
    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError)
    expect(server.cache_fresh?(:tools)).to be(false)
    expect(server.list_tools.map(&:name)).to eq(['bob-tool'])
    expect(lists.call).to eq(3)
  ensure
    server&.cleanup
  end

  it 'does not let the client serve its own tool cache under a hint recorded without a list' do
    stub_failed_refetch
    server = streamable(scripted_provider(%w[alice alice bob]))
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: url }])

    expect(client.list_tools.map(&:name)).to eq(['admin-secret'])
    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError)
    expect(client.list_tools.map(&:name)).to eq(['bob-tool'])
  ensure
    server&.cleanup
  end

  it 'has no stale fallback for a re-fetch that never recorded its credentials' do
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

      lists += 1
      json_response(body['id'], { 'tools' => [tool('admin-secret')], 'ttlMs' => 0, 'cacheScope' => 'private' })
    end
    provider = scripted_provider(['alice'])
    server = streamable(provider)

    expect(server.list_tools.map(&:name)).to eq(['admin-secret'])
    # Bob's token is known to the probe, but applying it to the real
    # request fails before the request's headers are recorded.
    allow(provider).to receive(:apply_authorization) do |req|
      unless req.is_a?(MCPClient::HttpTransportBase::CacheSupport::HeaderProbe)
        raise MCPClient::Errors::ConnectionError, 'token endpoint unreachable'
      end

      req.headers['Authorization'] = 'Bearer bob'
    end
    expect { server.list_tools }.to raise_error(MCPClient::Errors::ConnectionError, /token endpoint/)
    expect(lists).to eq(1)
  ensure
    server&.cleanup
  end

  it 'dates a cached read from its receipt, not from the end of its conversion' do
    reads = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      result = if body['method'] == 'resources/read'
                 reads += 1
                 { 'contents' => [{ 'uri' => 'file:///a', 'text' => "read #{reads}" }], 'ttlMs' => 100 }
               else
                 discover_result
               end
      json_response(body['id'], result)
    end
    server = streamable
    clock = { now: 0.0 }
    allow(server).to receive(:monotonic_now) { clock[:now] }
    # Converting the contents takes longer than the TTL.
    allow(MCPClient::ResourceContent).to receive(:from_json).and_wrap_original do |original, *args|
      clock[:now] += 0.2
      original.call(*args)
    end

    expect(server.read_resource('file:///a').first.text).to eq('read 1')
    expect(server.cache_info(:read, 'file:///a')).to include(fresh: false)
    expect(server.read_resource('file:///a').first.text).to eq('read 2')
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
      server.instance_variable_set(:@use_sse, false)
      server.instance_variable_set(:@rpc_endpoint, '/messages')
    end

    it 'binds a private result to the credentials of the POST that fetched it' do
      counts = Hash.new(0)
      stub_request(:post, 'https://example.com/messages').to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        result = case body['method']
                 when 'tools/list'
                   { 'tools' => [tool('mine')], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
                 when 'resources/read'
                   { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'secret' }], 'ttlMs' => 60_000,
                     'cacheScope' => 'private' }
                 end
        json_response(body['id'], result)
      end

      2.times { expect(server.list_tools.map(&:name)).to eq(['mine']) }
      2.times { expect(server.read_resource('file:///a').first.text).to eq('secret') }

      expect(counts).to eq('tools/list' => 1, 'resources/read' => 1)
    end

    # A modern server's result is already checked at the protocol level; a
    # legacy server's malformed read must not turn into an empty resource.
    it 'rejects a resources/read result that is not an object' do
      results = [[], 'text', 7]
      allow(server).to receive(:rpc_request).with('resources/read', anything) { results.shift }

      3.times do
        expect { server.read_resource('file:///a') }
          .to raise_error(MCPClient::Errors::TransportError, %r{resources/read})
      end
    end
  end
end

# --- round9 ----------------------------------------------------------------

# MCP 2026-07-28 caching, ninth review round: a list attaches only to the
# entry its own fetch recorded, a stale copy is judged by the entry that
# supplied it, and an Authorization header added by Faraday middleware is
# part of the cache context.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 9' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def entry_for(server, kind)
    server.send(:cache_entries_mutex).synchronize { server.send(:cache_entries)[kind] }
  end

  it 'attaches a list only to the entry its own fetch recorded' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    alice_recorded = Queue.new
    bob_recorded = Queue.new
    private_hint = { 'tools' => [tool('admin-secret')], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
    public_hint = { 'tools' => [tool('public')], 'ttlMs' => 60_000, 'cacheScope' => 'public' }

    alice = Thread.new do
      server.send(:note_request_authorization, 'Bearer alice')
      server.send(:record_paginated_cache_hint, :tools, [private_hint])
      alice_recorded << true
      bob_recorded.pop
      # Alice converts last: her private list must not land on Bob's entry.
      server.send(:attach_list_value, :tools, [:alice_secret_tools])
    end
    bob = Thread.new do
      alice_recorded.pop
      server.send(:note_request_authorization, 'Bearer bob')
      server.send(:record_paginated_cache_hint, :tools, [public_hint])
      bob_recorded << true
    end
    [alice, bob].each(&:join)

    entry = entry_for(server, :tools)
    expect(entry.cache_scope).to eq('public')
    expect(entry.value).to be_nil
    expect(server.cache_fresh?(:tools)).to be(false)
  end

  it 'still attaches a list to the entry its own fetch recorded' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:note_request_authorization, 'Bearer alice')
    server.send(:record_paginated_cache_hint, :tools, [{ 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'private' }])
    server.send(:attach_list_value, :tools, [:alice_tools])

    expect(entry_for(server, :tools).value).to eq([:alice_tools])
  end

  it 'judges a stale copy by the entry that supplied it, not by the entry installed meanwhile' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:note_request_authorization, 'Bearer alice')
    server.send(:record_cache_hint, :tools, { 'ttlMs' => 0, 'cacheScope' => 'private' }, [:alice_secret])
    stale = server.send(:stale_list_entry, :tools)

    expect do
      server.send(:refetch_or_serve_stale, :tools, stale) do
        # A concurrent request under Bob's credentials installs Bob's entry,
        # then Alice's re-fetch (now carrying Bob's token) fails.
        server.send(:note_request_authorization, 'Bearer bob')
        server.send(:record_cache_hint, :tools, { 'ttlMs' => 60_000, 'cacheScope' => 'private' }, [:bob_tools])
        raise MCPClient::Errors::TransientServerError, 'HTTP 503'
      end
    end.to raise_error(MCPClient::Errors::TransientServerError)
  end

  it 'serves a stale copy to the context that produced it' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:note_request_authorization, 'Bearer alice')
    server.send(:record_cache_hint, :tools, { 'ttlMs' => 0, 'cacheScope' => 'private' }, [:alice_tools])
    stale = server.send(:stale_list_entry, :tools)

    served = server.send(:refetch_or_serve_stale, :tools, stale) do
      server.send(:note_request_authorization, 'Bearer alice')
      raise MCPClient::Errors::TransientServerError, 'HTTP 503'
    end

    expect(served).to eq([:alice_tools])
  end

  it 'keeps only a bare fetch identity on the thread, never the entry or its list' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:record_paginated_cache_hint, :tools, [{ 'tools' => [], 'ttlMs' => 60_000 }])

    remembered = Thread.current[server.send(:recorded_entries_key)][:tools]
    expect(remembered).not_to be_nil
    expect(remembered).not_to be_a(MCPClient::CachedResult)
    expect(remembered.instance_variables).to be_empty
  end

  it 'makes a fetch invalidated in flight fetch again instead of handing back another list' do
    server = streamable
    server.instance_variable_set(:@tools, [:someone_elses_list])
    generation = server.send(:tools_generation)

    expect(server.send(:store_tools, [:mine], generation - 1)).to be_nil
  end

  it 'rejects a null resources/read result on stdio' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    allow(server).to receive(:ensure_initialized)
    allow(server).to receive(:rpc_request).and_return(nil)

    expect { server.read_resource('file:///x') }.to raise_error(MCPClient::Errors::TransportError, %r{resources/read})
  end

  describe 'Authorization added by Faraday middleware' do
    let(:token) { { value: 'alice' } }
    let(:seen) { [] }

    def stub_private_tools
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        seen << request.headers['Authorization']
        json_response(body['id'], { 'tools' => [tool("tool-#{seen.size}")], 'ttlMs' => 60_000,
                                    'cacheScope' => 'private' })
      end
    end

    def middleware_server
      current = token
      streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', -> { current[:value] } })
    end

    # A static credential the probe may model: a callable one is state the
    # probe refuses to run (it could vend a different value every call), so
    # its context reads as unknown and nothing private is served for it.
    def static_middleware_server
      streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', 'alice' })
    end

    it 'binds a private list to the token the middleware sent' do
      stub_private_tools
      server = static_middleware_server

      expect(server.list_tools.map(&:name)).to eq(['tool-1'])
      expect(server.list_tools.map(&:name)).to eq(['tool-1'])
      expect(seen).to eq(['Bearer alice'])
      expect(server.cache_info(:tools)[:fresh]).to be(true)
    ensure
      server&.cleanup
    end

    it 'does not serve a private list under a token the middleware changed' do
      stub_private_tools
      server = middleware_server
      server.list_tools

      token[:value] = 'bob'

      expect(server.cache_fresh?(:tools)).to be(false)
      expect(server.list_tools.map(&:name)).to eq(['tool-2'])
      expect(seen).to eq(['Bearer alice', 'Bearer bob'])
    ensure
      server&.cleanup
    end
  end
end

# --- round10 ---------------------------------------------------------------

# MCP 2026-07-28 caching, tenth review round: raw list pages are never
# handed from one fetch to another, a request that fails before any response
# under Faraday middleware has an unknown authorization context, and SSE
# resource lists are dated from receipt.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 10' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  describe 'raw list pages' do
    let(:seen) { [] }

    def stub_lists
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'].end_with?('/list')

        seen << [body['method'], request.headers['Authorization']]
        owner = request.headers['Authorization'].to_s.sub('Bearer ', '')
        result = case body['method']
                 when 'tools/list' then { 'tools' => [tool("#{owner}-tool")] }
                 when 'prompts/list' then { 'prompts' => [{ 'name' => "#{owner}-prompt" }] }
                 else { 'resources' => [{ 'uri' => "file:///#{owner}", 'name' => owner }] }
                 end
        json_response(body['id'], result.merge('ttlMs' => 0, 'cacheScope' => 'private'))
      end
    end

    it 'never answers a fetch under other credentials from a previous fetch (Streamable HTTP)' do
      stub_lists
      server = streamable(headers: { 'Authorization' => 'Bearer alice' })
      server.list_tools
      server.list_prompts
      server.list_resources
      seen.clear

      server.instance_variable_get(:@headers)['Authorization'] = 'Bearer bob'
      expect(server.send(:request_tools_list).map { |t| t['name'] }).to eq(['bob-tool'])
      expect(server.send(:request_prompts_list).map { |p| p['name'] }).to eq(['bob-prompt'])
      expect(server.send(:request_resources_list).map { |r| r['name'] }).to eq(['bob'])
      expect(seen.map(&:last).uniq).to eq(['Bearer bob'])
    ensure
      server&.cleanup
    end

    it 'never answers a fetch under other credentials from a previous fetch (HTTP)' do
      stub_lists
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                         headers: { 'Authorization' => 'Bearer alice' })
      server.list_tools
      seen.clear

      server.instance_variable_get(:@headers)['Authorization'] = 'Bearer bob'
      expect(server.send(:request_tools_list).map { |t| t['name'] }).to eq(['bob-tool'])
      expect(seen.map(&:last)).to eq(['Bearer bob'])
    ensure
      server&.cleanup
    end
  end

  describe 'a request that fails before any response under Faraday middleware' do
    let(:token) { { value: 'alice' } }

    # What this pins is the middleware case: the token the request goes out
    # with is the middleware's, so the entry's parameters are opaque and the
    # fallback is refused before authorization is ever consulted. The
    # authorization rule itself is pinned in round 40, on knowable
    # parameters, where disabling the match really does redden an example.
    it 'has no private stale fallback' do
      calls = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        calls += 1
        raise Faraday::ConnectionFailed, 'reset' if calls > 1

        json_response(body['id'], { 'tools' => [tool('alice-secret')], 'ttlMs' => 0, 'cacheScope' => 'private' })
      end
      # The configured header matches the entry's context; the middleware
      # rewrites it, so it alone decides the token the request carries.
      rewriting = Class.new(Faraday::Middleware) do
        def initialize(app, holder)
          super(app)
          @holder = holder
        end

        def on_request(env)
          env.request_headers['Authorization'] = "Bearer #{@holder[:value]}"
        end
      end
      current = token
      server = streamable(headers: { 'Authorization' => 'Bearer alice' },
                          faraday_config: ->(f) { f.use rewriting, current })
      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])

      token[:value] = 'bob'

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ConnectionError)
    ensure
      server&.cleanup
    end
  end

  describe 'Faraday middleware credentials' do
    let(:token) { { value: 'alice' } }
    let(:requests) { [] }

    def stub_private_tools(fail_after: nil)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        requests << request.headers['Authorization']
        raise Faraday::TimeoutError, 'slow' if fail_after && requests.size > fail_after

        json_response(body['id'], { 'tools' => [tool('alice-secret')], 'ttlMs' => fail_after ? 0 : 60_000,
                                    'cacheScope' => 'private' })
      end
    end

    it 'serves a fresh private list when the host also installs raise_error' do
      stub_private_tools
      # A static credential, so the probe models the request rather than
      # running a callable the live stack shares (which may vend a different
      # value on every call).
      server = streamable(faraday_config: lambda { |f|
        f.request :authorization, 'Bearer', 'alice'
        f.response :raise_error
      })

      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])
      expect(server.cache_fresh?(:tools)).to be(true)
      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])
      expect(requests).to eq(['Bearer alice'])
    ensure
      server&.cleanup
    end

    it 'serves the stale private list to the middleware credentials when the re-fetch times out' do
      stub_private_tools(fail_after: 1)
      current = token
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', -> { current[:value] } })
      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])

      expect(server.list_tools.map(&:name)).to eq(['alice-secret'])
      expect(requests).to eq(['Bearer alice', 'Bearer alice'])
    ensure
      server&.cleanup
    end
  end

  describe 'SSE resource lists' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', retries: 0) }

    before do
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      allow(server).to receive(:ensure_initialized)
    end

    it 'dates a resources list from receipt, not from the end of conversion' do
      allow(server).to receive(:rpc_request).and_return(
        { 'resources' => [{ 'uri' => 'file:///a', 'name' => 'a' }], 'ttlMs' => 40, 'cacheScope' => 'public' }
      )
      allow(MCPClient::Resource).to receive(:from_json).and_wrap_original do |m, *args, **kwargs|
        sleep 0.06
        m.call(*args, **kwargs)
      end

      server.list_resources

      expect(server.cache_info(:resources)[:fresh]).to be(false)
    end

    it 'dates a templates list from receipt, not from the end of conversion' do
      allow(server).to receive(:rpc_request).and_return(
        { 'resourceTemplates' => [{ 'uriTemplate' => 'file:///{p}', 'name' => 't' }], 'ttlMs' => 40,
          'cacheScope' => 'public' }
      )
      allow(MCPClient::ResourceTemplate).to receive(:from_json).and_wrap_original do |m, *args, **kwargs|
        sleep 0.06
        m.call(*args, **kwargs)
      end

      server.list_resource_templates

      expect(server.cache_info(:templates)[:fresh]).to be(false)
    end
  end
end

# --- round11 ---------------------------------------------------------------

# MCP 2026-07-28 caching, eleventh review round: the freshness probe sees
# the request shape the real POST has (endpoint, body) and gives up rather
# than guess when host middleware cannot be run faithfully; the read-cache
# epoch is taken after the session exists; an old epoch never overwrites a
# newer entry; the per-URI read cache is bounded and expires.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 11' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  describe 'the freshness probe' do
    let(:requests) { [] }

    def stub_private_tools
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        owner = request.headers['Authorization'].to_s.sub('Bearer ', '')
        requests << owner
        json_response(body['id'], { 'tools' => [tool("#{owner}-tool")], 'ttlMs' => 60_000,
                                    'cacheScope' => 'private' })
      end
    end

    # The middleware below has a request phase of its own, which the probe
    # never runs: the context is unknown, and a private entry is never
    # matched to an unknown context. What this pins is that rotation under
    # such middleware is never served the previous principal's list -- not
    # that the probe saw the endpoint (nothing it can run looks at one).
    it 'never serves a private list across a rotation made by middleware the probe cannot run' do
      stub_private_tools
      holder = { value: 'alice' }
      # Path-aware middleware: only requests to the endpoint get the token.
      path_aware = Class.new(Faraday::Middleware) do
        def initialize(app, holder)
          super(app)
          @holder = holder
        end

        def on_request(env)
          return unless env.url.path == '/mcp' && env.body.to_s.include?('"jsonrpc"')

          env.request_headers['Authorization'] = "Bearer #{@holder[:value]}"
        end
      end
      server = streamable(headers: { 'Authorization' => 'Bearer alice' },
                          faraday_config: ->(f) { f.use path_aware, holder })
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])

      holder[:value] = 'bob'

      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])
      expect(requests).to eq(%w[alice bob])
    ensure
      server&.cleanup
    end

    it 'treats the context as unknown when host middleware cannot be run without sending' do
      stub_private_tools
      opaque = Class.new(Faraday::Middleware) do
        def call(env)
          env.request_headers['Authorization'] = 'Bearer alice'
          @app.call(env)
        end
      end
      server = streamable(headers: { 'Authorization' => 'Bearer alice' }, faraday_config: ->(f) { f.use opaque })
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])

      expect(server.send(:current_authorization_context)).to eq(:unknown)
      # A private entry cannot be matched to an unknown context: re-fetch.
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(requests.size).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'the read-cache epoch on a fresh connection' do
    def stub_reads(reads)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'resources/read'
          reads << body['params']['uri']
          json_response(body['id'], { 'contents' => [{ 'uri' => body['params']['uri'], 'text' => 'hi' }],
                                      'ttlMs' => 60_000 })
        when 'resources/templates/list'
          json_response(body['id'], { 'resourceTemplates' => [], 'ttlMs' => 60_000 })
        else json_response(body['id'], {})
        end
      end
    end

    it 'caches the first read on a fresh plain HTTP transport' do
      reads = []
      stub_reads(reads)
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)

      server.read_resource('file:///a')
      server.read_resource('file:///a')

      expect(reads).to eq(['file:///a'])
      expect(server.cache_info(:read, 'file:///a')[:fresh]).to be(true)
    ensure
      server&.cleanup
    end

    it 'serves the templates it bounded on a fresh plain HTTP transport' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/templates/list'

        lists += 1
        json_response(body['id'],
                      { 'resourceTemplates' => [{ 'uriTemplate' => 'file:///{p}', 'name' => 't' }],
                        'ttlMs' => 60_000 })
      end
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)

      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['t'])
      # Recording the hint is not serving from it: the second listing must be
      # answered from the entry, without a request of its own.
      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['t'])

      expect(lists).to eq(1)
      expect(server.cache_info(:templates)[:fresh]).to be(true)
    ensure
      server&.cleanup
    end

    it 'caches the first read on a fresh Streamable HTTP transport' do
      reads = []
      stub_reads(reads)
      server = streamable

      server.read_resource('file:///a')
      server.read_resource('file:///a')

      expect(reads).to eq(['file:///a'])
    ensure
      server&.cleanup
    end
  end

  describe 'an old epoch completing after a newer entry' do
    let(:server) { streamable }

    it 'keeps the newer list entry' do
      server.record_cache_hint(:tools, { 'ttlMs' => 60_000, 'cacheScope' => 'public' }, ['old'],
                               epoch: server.cache_epoch(:tools))
      old_epoch = server.cache_epoch(:tools)
      server.invalidate_cache(:tools)
      newer = server.record_cache_hint(:tools, { 'ttlMs' => 60_000, 'cacheScope' => 'public' }, ['new'],
                                       epoch: server.cache_epoch(:tools))

      late = server.record_cache_hint(:tools, { 'ttlMs' => 60_000, 'cacheScope' => 'public' }, ['late'],
                                      epoch: old_epoch)

      expect(server.cache_entries[:tools]).to equal(newer)
      expect(server.cache_fresh?(:tools)).to be(true)
      expect(late).not_to be_fresh(now: server.monotonic_now)
    end

    it 'keeps the newer paginated entry' do
      old_epoch = server.cache_epoch(:prompts)
      server.invalidate_cache(:prompts)
      newer = server.record_paginated_cache_hint(:prompts, [{ 'ttlMs' => 60_000, 'cacheScope' => 'public' }], ['new'],
                                                 epoch: server.cache_epoch(:prompts))

      server.record_paginated_cache_hint(:prompts, [{ 'ttlMs' => 60_000, 'cacheScope' => 'public' }], ['late'],
                                         epoch: old_epoch)

      expect(server.cache_entries[:prompts]).to equal(newer)
    end
  end

  describe 'the per-URI read cache' do
    let(:reads) { [] }

    def stub_reads(ttl_for)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        uri = body['params']['uri']
        reads << uri
        result = { 'contents' => [{ 'uri' => uri, 'text' => 'x' * 10 }] }
        ttl = ttl_for.call(uri)
        result['ttlMs'] = ttl unless ttl.nil?
        json_response(body['id'], result)
      end
    end

    def read_keys(server)
      server.cache_entries.keys.grep(/\Aread:/)
    end

    it 'does not retain reads that are never fresh' do
      stub_reads(->(uri) { uri.end_with?('zero') ? 0 : nil })
      server = streamable
      server.read_resource('file:///zero')
      server.read_resource('file:///absent')

      expect(read_keys(server)).to be_empty
    ensure
      server&.cleanup
    end

    it 'is bounded and evicts the oldest reads first' do
      stub_reads(->(_uri) { 60_000 })
      server = streamable
      limit = MCPClient::ResultCaching::MAX_CACHED_READS
      (limit + 5).times { |i| server.read_resource("file:///r#{i}") }

      expect(read_keys(server).size).to eq(limit)
      expect(read_keys(server)).not_to include('read:file:///r0')
      expect(read_keys(server)).to include("read:file:///r#{limit + 4}")
    ensure
      server&.cleanup
    end

    it 'drops expired reads when a new one is stored' do
      stub_reads(->(uri) { uri.end_with?('short') ? 1 : 60_000 })
      server = streamable
      server.read_resource('file:///short')
      sleep 0.01
      server.read_resource('file:///long')

      expect(read_keys(server)).to eq(['read:file:///long'])
    ensure
      server&.cleanup
    end
  end
end

# --- round12 ---------------------------------------------------------------

# MCP 2026-07-28 caching, twelfth review round: the freshness probe models
# the request of the operation whose cache is checked, a result stays bound
# to the credentials of its own request even when its response dispatched a
# notification that sent another request on the same thread, and an old
# fetch spanning two contexts never replaces a newer entry.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 12' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def sse_response(messages)
    body = messages.map { |m| "event: message\ndata: #{JSON.generate(m)}\n\n" }.join
    { status: 200, body: body, headers: { 'Content-Type' => 'text/event-stream' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def private_tools(owner)
    { 'tools' => [tool("#{owner}-tool")], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  # Host middleware that picks the bearer by the JSON-RPC method sent.
  def method_aware_middleware
    Class.new(Faraday::Middleware) do
      def initialize(app, holder)
        super(app)
        @holder = holder
      end

      def on_request(env)
        method = JSON.parse(env.body.to_s)['method'] rescue nil # rubocop:disable Style/RescueModifier
        token = @holder[method] || @holder[:other]
        env.request_headers['Authorization'] = "Bearer #{token}" if token
      end
    end
  end

  # A minimal OAuth provider writing whatever bearer it currently holds: the
  # probe asks it, so the context is knowable and a same-context hit is real.
  def provider_holding(token)
    Class.new do
      def initialize(token)
        @token = token
      end

      def apply_authorization(request)
        request.headers['Authorization'] = "Bearer #{@token.value}" if @token.value
      end
    end.new(token)
  end

  describe 'the freshness probe' do
    # Nothing the probe may run chooses a credential by method, so the
    # request it models is pinned directly: it is the operation whose cache
    # is being checked, not whatever was sent last.
    it 'models the very operation whose cache is checked' do
      server = streamable
      server.instance_variable_set(:@probe_method, 'resources/read')

      expect(server.send(:probe_request_for, :tools)).to eq(['tools/list', {}])
      expect(server.send(:probe_request_for, :prompts)).to eq(['prompts/list', {}])
      expect(server.send(:probe_request_for, :resources)).to eq(['resources/list', {}])
      expect(server.send(:probe_request_for, :templates)).to eq(['resources/templates/list', {}])
      expect(server.send(:probe_request_for, :discover)).to eq(['server/discover', {}])
      expect(server.send(:probe_request_for, 'read:file:///a')).to eq(['resources/read', { 'uri' => 'file:///a' }])
      expect(server.send(:probe_request_for, nil)).to eq(['resources/read', {}])
    ensure
      server&.cleanup
    end

    # Middleware with a request phase of its own is never run by the probe:
    # the context is unknown, so a private list is fetched again -- whatever
    # principal the middleware would pick, and whatever was sent last.
    it 'refetches a private list under middleware that picks the principal by method' do
      tools_requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        owner = request.headers['Authorization'].to_s.sub('Bearer ', '')
        case body['method']
        when 'tools/list'
          tools_requests << owner
          json_response(body['id'], private_tools(owner))
        when 'resources/read'
          json_response(body['id'], { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'hi' }] })
        else json_response(body['id'], discover_result)
        end
      end
      holder = { 'tools/list' => 'alice', other: 'alice' }
      server = streamable(faraday_config: ->(f) { f.use method_aware_middleware, holder })
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])

      # The principal for tools changes; a read (another principal) is the
      # last request sent before the tools cache is consulted again.
      holder['tools/list'] = 'bob'
      server.read_resource('file:///a')

      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])
      expect(tools_requests).to eq(%w[alice bob])
    ensure
      server&.cleanup
    end
  end

  describe 'a response that dispatches a notification' do
    it 'keeps the result bound to the credentials of its own request' do
      tools_requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        owner = request.headers['Authorization'].to_s.sub('Bearer ', '')
        case body['method']
        when 'tools/list'
          tools_requests << owner
          sse_response([{ 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
                          'params' => { 'progressToken' => 'p', 'progress' => 1 } },
                        { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => private_tools(owner) }])
        else json_response(body['id'], discover_result)
        end
      end
      token = Struct.new(:value).new('alice')
      # No host middleware: the probe can tell the context, so a hit is
      # possible and the rotation below proves something.
      server = streamable(oauth_provider: provider_holding(token))
      nested = 0
      server.on_notification do |method, _params|
        next unless method == 'notifications/progress' && nested.zero?

        # The callback switches principal and sends a request of its own on
        # this very thread while the outer tools/list is still being handled.
        nested += 1
        token.value = 'bob'
        server.ping
      end

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(nested).to eq(1)

      # The list is Alice's, not the nested ping's: back under her
      # credentials it answers without a request. Without this hit the
      # re-fetch below would prove nothing about the binding.
      token.value = 'alice'
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(tools_requests).to eq(%w[alice])

      # Bob holds the credentials now, and must not be served it.
      token.value = 'bob'
      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])
      expect(tools_requests).to eq(%w[alice bob])
    ensure
      server&.cleanup
    end
  end

  describe 'an old fetch spanning two contexts' do
    it 'never replaces a newer entry recorded after an invalidation' do
      stub_request(:post, url).to_return { |request| json_response(JSON.parse(request.body)['id'], discover_result) }
      server = streamable
      old_epoch = server.cache_epoch(:tools)
      server.send(:invalidate_cache, :tools)
      fresh = { 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
      server.send(:record_cache_hint, :tools, fresh, ['fresh'], epoch: server.cache_epoch(:tools))

      mixed = [{ 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'private' }] * 2
      server.send(:record_paginated_cache_hint, :tools, mixed, nil, contexts: %w[alice bob], epoch: old_epoch)

      expect(server.send(:stale_list_value, :tools)).to eq(['fresh'])
      expect(server.cache_info(:tools)[:fresh]).to be(true)
    ensure
      server&.cleanup
    end
  end
end

# --- round20 ---------------------------------------------------------------

# MCP 2026-07-28 caching, twentieth review round: cache_info hands out
# detached values, per-URI invalidation generations are bounded, client
# identity is part of what a cached result is bound to, and a freshness
# callback that clears the client cache cannot deadlock.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 20' do
  let(:url) { 'https://example.com/mcp' }
  let(:uri) { 'file:///secret' }

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

  def stub_server(counts)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      case body['method']
      when 'resources/read'
        json_response(body['id'], { 'contents' => [{ 'uri' => uri, 'text' => 'top secret' }],
                                    'ttlMs' => 60_000, 'cacheScope' => 'private' })
      when 'tools/list'
        json_response(body['id'], { 'tools' => [{ 'name' => 'tool', 'inputSchema' => { 'type' => 'object' } }],
                                    'ttlMs' => 60_000 })
      else
        json_response(body['id'], discover_result)
      end
    end
  end

  it 'hands out cache_info values detached from the entry' do
    counts = Hash.new(0)
    stub_server(counts)
    server = streamable(headers: { 'Authorization' => 'Bearer alice' })
    server.read_resource(uri)

    scope = server.cache_info(:read, uri)[:cache_scope]
    scope.upcase! unless scope.frozen?
    expect(server.cache_info(:read, uri)[:cache_scope]).to eq('private')

    server.instance_variable_get(:@headers)['Authorization'] = 'Bearer bob'
    server.read_resource(uri)
    expect(counts['resources/read']).to eq(2)
  end

  it 'bounds the per-URI invalidation generations' do
    server = streamable

    2_000.times { |i| server.send(:invalidate_read_cache, "file:///r#{i}") }

    generations = server.instance_variable_get(:@cache_generations) || {}
    expect(generations.size).to be <= MCPClient::ResultCaching::MAX_READ_GENERATIONS + 1
  end

  it 'varies the parameters fingerprint with the client identity' do
    server = streamable
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    before = server.send(:current_params_fingerprint)

    server.client_info = { name: 'other-host', version: '9.9' }
    after = server.send(:current_params_fingerprint)
    server.send_client_info = false
    without = server.send(:current_params_fingerprint)

    expect(after).not_to eq(before)
    expect(without).not_to eq(after)
  end

  it 'does not deadlock when a freshness callback clears the client cache' do
    counts = Hash.new(0)
    stub_server(counts)
    server = streamable
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
    client.list_tools
    server.request_meta = lambda {
      client.clear_cache
      {}
    }

    expect { client.list_tools }.not_to raise_error
    expect(client.list_tools.map(&:name)).to eq(['tool'])
  end
end

# --- round25 ---------------------------------------------------------------

# MCP 2026-07-28 caching, twenty-fifth review round: the freshness probe
# leaves the request state of the connection alone (it starts from a detached
# copy of the header table, and gives up on middleware that shares mutable
# state with the live stack), and a completed list snapshot is served from
# the client cache even when every server's list is empty.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 25' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def oauth_provider(token)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) do |req|
      req.headers['Authorization'] = "Bearer #{token[:value]}" if token[:value]
    end
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
  end

  # Answers tools/list with a private list named after the bearer the
  # request carried, and records those bearers.
  def stub_tools_by_bearer
    bearers = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        bearer = request.headers['Authorization'].to_s.sub(/\ABearer /, '')
        bearers << bearer
        json_response(body['id'],
                      { 'tools' => [tool("#{bearer}-tool")], 'ttlMs' => 60_000, 'cacheScope' => 'private' })
      else
        json_response(body['id'], discover_result)
      end
    end
    bearers
  end

  describe 'the header table the probe starts from' do
    it 'is detached from the transport headers when they are a Faraday table' do
      # A host may hand the transport Faraday's own header table; the probe
      # lets the OAuth provider write into what it is given, so it must not
      # be given the very table every request is built from.
      token = { value: 'alice' }
      server = streamable(headers: Faraday::Utils::Headers.new('X-Tenant' => 'acme'),
                          oauth_provider: oauth_provider(token))

      expect(server.send(:current_authorization_context, :tools)).to eq(Digest::SHA256.hexdigest('Bearer alice'))

      # The provider has no token any more: nothing may be left over from
      # the probe that made the request look authorized.
      token[:value] = nil

      expect(server.send(:current_authorization_context, :tools)).to be_nil
      expect(server.instance_variable_get(:@headers)['Authorization']).to be_nil
    end

    it 'does not let a probe send the credentials of an earlier one' do
      bearers = stub_tools_by_bearer
      token = { value: 'alice' }
      server = streamable(headers: Faraday::Utils::Headers.new('X-Tenant' => 'acme'),
                          oauth_provider: oauth_provider(token))

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])

      token[:value] = nil

      # Without the provider's header the request goes out unauthorized;
      # the bearer of the probed context must not linger in @headers.
      server.list_tools
      expect(bearers).to eq(['alice', ''])
    end
  end

  describe 'host middleware that shares mutable state with the live stack' do
    # Spends a nonce on every tools/list it sends. The counter is the host's,
    # so a freshly built copy shares it: running the copy's request hook
    # would consume a credential no request ever carried.
    def nonce_middleware
      Class.new(Faraday::Middleware) do
        def initialize(app, counter)
          super(app)
          @counter = counter
        end

        def on_request(env)
          return unless env.body.to_s.include?('"tools/list"')

          @counter[:used] += 1
          env.request_headers['Authorization'] = "Bearer nonce#{@counter[:used]}"
        end
      end
    end

    it 'reports the unknown context instead of spending a shared nonce' do
      stub_tools_by_bearer
      counter = { used: 0 }
      server = streamable(faraday_config: ->(f) { f.use nonce_middleware, counter })
      server.list_tools

      expect(server.send(:current_authorization_context, :tools))
        .to eq(MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT)
      expect(counter[:used]).to eq(1)
    end

    it 'never skips a one-time credential of the next real request' do
      bearers = stub_tools_by_bearer
      counter = { used: 0 }
      server = streamable(faraday_config: ->(f) { f.use nonce_middleware, counter })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(counter[:used]).to eq(2)
    end

    it 'still serves a private entry behind pure framework middleware' do
      bearers = stub_tools_by_bearer
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', 'alice' })

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(bearers).to eq(['alice'])
    end
  end

  describe 'a client snapshot whose lists are all empty' do
    def stdio_server(method, result)
      server = MCPClient::ServerStdio.new(command: 'echo test')
      allow(server).to receive(:ensure_initialized)
      calls = 0
      allow(server).to receive(:rpc_request) do |called, _params = {}, **_opts|
        raise "unexpected #{called}" unless called == method

        calls += 1
        result
      end
      [server, -> { calls }]
    end

    def client_for(*servers)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(*servers)
      MCPClient::Client.new(mcp_server_configs: servers.map { { type: 'stdio', command: 'echo test' } })
    end

    it 'serves an empty tool list without asking the server again' do
      server, calls = stdio_server('tools/list', { 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' })
      client = client_for(server)

      expect(client.list_tools).to eq([])
      expect(client.list_tools).to eq([])
      expect(calls.call).to eq(1)
    end

    it 'serves an empty prompt list without asking the server again' do
      server, calls = stdio_server('prompts/list', { 'prompts' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' })
      client = client_for(server)

      expect(client.list_prompts).to eq([])
      expect(client.list_prompts).to eq([])
      expect(calls.call).to eq(1)
    end

    it 'serves an empty resource list without asking the server again' do
      server, calls = stdio_server('resources/list', { 'resources' => [], 'ttlMs' => 60_000,
                                                       'cacheScope' => 'public' })
      client = client_for(server)

      expect(client.list_resources['resources']).to eq([])
      expect(client.list_resources['resources']).to eq([])
      expect(calls.call).to eq(1)
    end

    it 'asks again once the empty list has gone stale' do
      server, calls = stdio_server('tools/list', { 'tools' => [], 'ttlMs' => 0, 'cacheScope' => 'public' })
      client = client_for(server)

      client.list_tools
      client.list_tools

      expect(calls.call).to eq(2)
    end

    it 'does not serve a snapshot a server has no slice of' do
      first, = stdio_server('tools/list',
                            { 'tools' => [{ 'name' => 'early', 'inputSchema' => { 'type' => 'object' } }],
                              'ttlMs' => 60_000, 'cacheScope' => 'public' })
      second = MCPClient::ServerStdio.new(command: 'echo test')
      allow(second).to receive(:ensure_initialized)
      attempts = 0
      allow(second).to receive(:list_tools) do
        attempts += 1
        raise MCPClient::Errors::ConnectionError, 'server unreachable' if attempts == 1

        [MCPClient::Tool.new(name: 'late', description: 'l', schema: { 'type' => 'object' }, server: second)]
      end
      client = client_for(first, second)

      # The failed server never filled a slice: the snapshot is incomplete
      # however many tools the other server put in it.
      expect(client.list_tools.map(&:name)).to eq(['early'])
      expect(client.list_tools.map(&:name)).to eq(%w[early late])
    end
  end
end

# --- round27 ---------------------------------------------------------------

# MCP 2026-07-28 caching, twenty-seventh review round: the freshness probe
# neither builds nor runs middleware that can reach the live stack's mutable
# state (a fresh options hash around the very same vendor is not a stand-in),
# a list is copied out of the cache only while its entry is still the one the
# map holds, the probe models the request with the metadata held for the
# decision, stdio serves a still-fresh hinted list, and a TTL-driven tool
# refresh is announced to the client.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 27' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  # Answers tools/list with a private list named after the bearer the
  # request carried, and records those bearers.
  def stub_tools_by_bearer
    bearers = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        bearer = request.headers['Authorization'].to_s.sub(/\ABearer /, '')
        bearers << bearer
        json_response(body['id'],
                      { 'tools' => [tool("#{bearer}-tool")], 'ttlMs' => 60_000, 'cacheScope' => 'private' })
      else
        json_response(body['id'], discover_result)
      end
    end
    bearers
  end

  # Vends one-time bearers and counts what it has spent.
  def nonce_vendor
    Class.new do
      attr_reader :used

      def initialize
        @used = 0
      end

      def next_nonce
        @used += 1
        "nonce#{@used}"
      end
    end.new
  end

  def unknown_context
    MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT
  end

  describe 'a probe against middleware that copies its options around a shared vendor' do
    # Faraday rebuilds middleware as `klass.new(app, **kwargs)`, so a `**opts`
    # parameter is a fresh hash on every build — holding the very same vendor.
    def kwargs_nonce_middleware
      Class.new(Faraday::Middleware) do
        def initialize(app, **opts)
          super(app)
          @opts = opts
        end

        def on_request(env)
          return unless env.body.to_s.include?('"tools/list"')

          env.request_headers['Authorization'] = "Bearer #{@opts[:vendor].next_nonce}"
        end
      end
    end

    it 'reports the unknown context instead of spending the shared vendor' do
      stub_tools_by_bearer
      vendor = nonce_vendor
      server = streamable(faraday_config: ->(f) { f.use kwargs_nonce_middleware, vendor: vendor })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(vendor.used).to eq(1)
    end

    it 'never skips the one-time credential of the next real request' do
      bearers = stub_tools_by_bearer
      vendor = nonce_vendor
      server = streamable(faraday_config: ->(f) { f.use kwargs_nonce_middleware, vendor: vendor })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(vendor.used).to eq(2)
    end

    it 'reads literal configuration but never a vendor of its own' do
      server = streamable
      vendor = nonce_vendor

      expect(server.send(:probe_static_value?, { token: 'abc' })).to be true
      expect(server.send(:probe_static_value?, [1, :two, 'three'])).to be true
      expect(server.send(:probe_static_value?, { vendor: vendor })).to be false
      expect(server.send(:probe_static_value?, -> { 'abc' })).to be false
    end
  end

  describe 'a probe against middleware whose constructor spends a credential' do
    def constructor_nonce_middleware
      Class.new(Faraday::Middleware) do
        def initialize(app, vendor)
          super(app)
          @nonce = vendor.next_nonce
        end

        def on_request(env)
          env.request_headers['Authorization'] = "Bearer #{@nonce}"
        end
      end
    end

    it 'never builds it, so the credential it would consume is not spent' do
      bearers = stub_tools_by_bearer
      vendor = nonce_vendor
      server = streamable(faraday_config: ->(f) { f.use constructor_nonce_middleware, vendor })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(vendor.used).to eq(1)
      expect(bearers).to eq(['nonce1'])
    end
  end

  describe 'a probe run for a decision that read the host request_meta' do
    # Picks the bearer out of the request body's own metadata, the way a host
    # middleware that authenticates by trace context would.
    def trace_middleware
      Class.new(Faraday::Middleware) do
        def on_request(env)
          meta = JSON.parse(env.body.to_s).dig('params', '_meta') || {}
          env.request_headers['Authorization'] = "Bearer #{meta['traceparent']}"
        rescue JSON::ParserError
          nil
        end
      end
    end

    it 'spends no evaluation of the host request_meta on a probe that sends nothing' do
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << body.dig('params', '_meta', 'traceparent')
        json_response(body['id'],
                      if body['method'] == 'tools/list'
                        { 'tools' => [tool('t')], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
                      else
                        discover_result
                      end)
      end
      spent = 0
      server = streamable(faraday_config: ->(f) { f.use trace_middleware })
      server.request_meta = lambda {
        spent += 1
        { 'traceparent' => "t#{spent}" }
      }

      server.list_tools
      server.list_tools

      # Every evaluation of the host's callable went out on the wire: none was
      # spent on a probe that sends nothing.
      expect(sent).to eq((1..spent).map { |i| "t#{i}" })
    end
  end

  describe 'a list invalidated while it is being served' do
    it 'fetches again instead of copying the invalidated tool list' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'tools/list'
          lists += 1
          json_response(body['id'],
                        { 'tools' => [tool("t#{lists}")], 'ttlMs' => 60_000, 'cacheScope' => 'public' })
        else
          json_response(body['id'], discover_result)
        end
      end
      server = streamable
      expect(server.list_tools.map(&:name)).to eq(['t1'])

      # The notification lands after the entry was looked up and before its
      # list is handed out.
      original = server.method(:private_entry_for_current_context)
      armed = true
      allow(server).to receive(:private_entry_for_current_context) do |kind|
        entry = original.call(kind)
        if armed && kind == :tools && entry
          armed = false
          server.send(:invalidate_cache_for_notification, 'notifications/tools/list_changed')
        end
        entry
      end

      expect(server.list_tools.map(&:name)).to eq(['t2'])
      expect(lists).to eq(2)
    end
  end

  describe 'a stdio server that hinted how long its lists stay fresh' do
    def stdio_server(method, result)
      server = MCPClient::ServerStdio.new(command: 'echo test')
      allow(server).to receive(:ensure_initialized)
      calls = 0
      allow(server).to receive(:rpc_request) do |called, _params = {}, **_opts|
        raise "unexpected #{called}" unless called == method

        calls += 1
        result
      end
      [server, -> { calls }]
    end

    it 'serves a still-fresh tool list without asking again' do
      server, calls = stdio_server('tools/list', { 'tools' => [tool('t')], 'ttlMs' => 60_000,
                                                   'cacheScope' => 'public' })

      expect(server.list_tools.map(&:name)).to eq(['t'])
      expect(server.list_tools.map(&:name)).to eq(['t'])
      expect(calls.call).to eq(1)
    end

    it 'serves a still-fresh prompt list without asking again' do
      server, calls = stdio_server('prompts/list', { 'prompts' => [{ 'name' => 'p' }], 'ttlMs' => 60_000,
                                                     'cacheScope' => 'public' })

      expect(server.list_prompts.map(&:name)).to eq(['p'])
      expect(server.list_prompts.map(&:name)).to eq(['p'])
      expect(calls.call).to eq(1)
    end

    it 'serves a still-fresh resource list without asking again' do
      server, calls = stdio_server('resources/list',
                                   { 'resources' => [{ 'uri' => 'file:///a.txt', 'name' => 'a' }],
                                     'ttlMs' => 60_000, 'cacheScope' => 'public' })

      expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(calls.call).to eq(1)
    end

    it 'asks again once the hint has expired' do
      server, calls = stdio_server('tools/list', { 'tools' => [tool('t')], 'ttlMs' => 1, 'cacheScope' => 'public' })

      expect(server.list_tools.map(&:name)).to eq(['t'])
      allow(server).to(receive(:monotonic_now).and_wrap_original { |method| method.call + 3600 })
      expect(server.list_tools.map(&:name)).to eq(['t'])
      expect(calls.call).to eq(2)
    end
  end

  describe 'a tool list a TTL refresh replaced during a call' do
    it 'validates the result against the definitions the call was answered under' do
      version = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'tools/list'
          version += 1
          json_response(body['id'],
                        { 'tools' => [{ 'name' => 'greet', 'inputSchema' => { 'type' => 'object' },
                                        'outputSchema' => {
                                          'type' => 'object',
                                          'properties' => { "v#{version}" => { 'type' => 'string' } },
                                          'required' => ["v#{version}"]
                                        } }],
                          'ttlMs' => 60_000 })
        when 'tools/call'
          json_response(body['id'], { 'content' => [], 'structuredContent' => { "v#{version}" => 'ok' } })
        else
          json_response(body['id'], discover_result)
        end
      end
      server = streamable
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }],
        validate_structured_content: :strict
      )
      expect(client.list_tools.map(&:name)).to eq(['greet'])

      # The hint expires after the tool was resolved, so the transport
      # re-fetches the list while the call itself is being sent.
      expired = false
      allow(server).to(receive(:monotonic_now).and_wrap_original { |method| method.call + (expired ? 3600 : 0) })
      validate_params = client.method(:validate_params!)
      allow(client).to receive(:validate_params!) do |*args|
        expired = true
        validate_params.call(*args)
      end

      expect { client.call_tool('greet', {}) }.not_to raise_error
      expect(version).to eq(2)
    end
  end
end

# --- round32 ---------------------------------------------------------------

# MCP 2026-07-28 caching, thirty-second review round: a freshness check that
# aborts on one server lets go of the metadata every server was holding, a
# post-call re-resolve reads the definition the call went out under instead of
# listing again, and a transport's cleanup drops its thread-local slots after
# the session-termination request rather than before it.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 32' do
  def json_response(id, result, headers = {})
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' }.merge(headers) }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name, extra = {})
    { 'name' => name, 'description' => name, 'inputSchema' => { 'type' => 'object' } }.merge(extra)
  end

  def streamable(host: 'example.com', **opts)
    MCPClient::ServerStreamableHTTP.new(base_url: "https://#{host}", endpoint: '/mcp', retries: 0, **opts)
  end

  def client_for(*servers, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(*servers)
    MCPClient::Client.new(mcp_server_configs: servers.map { { type: 'stdio', command: 'echo test' } }, **opts)
  end

  describe 'a freshness check that aborts on a later server' do
    let(:a_url) { 'https://a.example.com/mcp' }
    let(:b_url) { 'https://b.example.com/mcp' }

    # Answers a modern handshake, a bounded tools/list and ping, recording the
    # trace identifier every request carried.
    def stub_host(url, name, scope)
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << body.dig('params', '_meta', 'traceparent')
        result = case body['method']
                 when 'tools/list'
                   { 'tools' => [tool("#{name}-tool")], 'ttlMs' => 60_000, 'cacheScope' => scope }
                 when 'ping' then {}
                 else discover_result
                 end
        json_response(body['id'], result)
      end
      sent
    end

    # An OAuth provider whose token refresh fails while `refusing` says so.
    def refusing_provider(refusing)
      provider_class = Class.new do
        def initialize(&block)
          @block = block
        end

        def apply_authorization(request)
          @block.call(request)
        end
      end
      provider_class.new do |request|
        raise MCPClient::Errors::ConnectionError, 'token refresh failed' if refusing[:now]

        request.headers['Authorization'] = 'Bearer b'
      end
    end

    it 'lets go of the metadata an earlier server was holding' do
      a_sent = stub_host(a_url, 'a', 'public')
      stub_host(b_url, 'b', 'private')
      refusing = { now: false }
      server_a = streamable(host: 'a.example.com')
      server_b = streamable(host: 'b.example.com', oauth_provider: refusing_provider(refusing))

      # The tenant is what the cached list is bound to and never changes;
      # the trace identifier is fresh for every request, which is exactly
      # what a leaked evaluation would send twice.
      evaluated = []
      recording = nil
      server_a.request_meta = lambda do
        value = "00-trace#{evaluated.size + 1}"
        evaluated << value
        recording&.<<(value)
        { 'baggage' => 'tenant=acme', 'traceparent' => value }
      end
      client = client_for(server_a, server_b)
      expect(client.list_tools.map(&:name)).to contain_exactly('a-tool', 'b-tool')

      # The first server's slice is still fresh (its evaluation is held for
      # the fetch the check is deciding on); the second server's probe then
      # fails its token refresh, so no fetch follows for either of them.
      refusing[:now] = true
      recording = []
      expect { client.list_tools }.to raise_error(MCPClient::Errors::ConnectionError)
      aborted = recording
      recording = nil

      expect(aborted).not_to be_empty
      expect(Thread.current[server_a.send(:held_request_meta_key)]).to be_nil

      # The next request on this thread reads the host afresh instead of
      # carrying the tenant/nonce the aborted decision evaluated.
      refusing[:now] = false
      server_a.ping
      expect(a_sent.last).to eq(evaluated.last)
      expect(aborted).not_to include(a_sent.last)
    ensure
      server_a&.cleanup
      server_b&.cleanup
    end
  end

  describe 'the tool definition a post-call re-resolve validates against' do
    let(:url) { 'https://example.com/mcp' }

    def greet(output_required)
      tool('greet',
           'outputSchema' => { 'type' => 'object', 'properties' => { output_required => { 'type' => 'string' } },
                               'required' => [output_required] })
    end

    # tools/list answers from `definitions` in order (the last one repeats),
    # always with `ttlMs: 0`, so every access re-fetches. Returns the counter
    # of tools/list requests actually made.
    def stub_tool_versions(definitions)
      listed = { count: 0 }
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        result = case body['method']
                 when 'tools/list'
                   listed[:count] += 1
                   listing = definitions[[listed[:count] - 1, definitions.size - 1].min]
                   { 'tools' => listing.is_a?(Array) ? listing : [listing], 'ttlMs' => 0 }
                 when 'tools/call'
                   { 'content' => [{ 'type' => 'text', 'text' => 'hi' }],
                     'structuredContent' => { 'greeting' => 'hi' } }
                 else discover_result
                 end
        json_response(body['id'], result)
      end
      listed
    end

    it 'is the one the wire request went out under, not a newer re-fetch' do
      # The header derivation re-fetches mid-call and gets the definition the
      # call is answered under; a third fetch afterwards would validate the
      # result against a definition the call never carried.
      listed = stub_tool_versions([tool('greet'), greet('greeting'), greet('farewell')])
      server = streamable
      client = client_for(server, validate_structured_content: :strict)

      result = client.call_tool('greet', {})

      expect(result['structuredContent']).to eq({ 'greeting' => 'hi' })
      expect(listed[:count]).to eq(2)
    ensure
      server&.cleanup
    end

    it 'keeps the definition the call was made with when the list dropped the tool' do
      listed = stub_tool_versions([tool('greet'), []])
      server = streamable
      client = client_for(server, validate_structured_content: :strict)

      expect(client.call_tool('greet', {})['structuredContent']).to eq({ 'greeting' => 'hi' })
      expect(listed[:count]).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe "a cleanup that terminates the transport's session" do
    let(:base_url) { 'https://example.com' }
    let(:url) { 'https://example.com/mcp' }
    let(:session_id) { 'session_abc123' }

    # A legacy handshake that hands out a session id, so cleanup sends the
    # DELETE that terminates it.
    def stub_session
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          json_response(body['id'],
                        { 'protocolVersion' => '2025-06-18', 'capabilities' => { 'tools' => {} },
                          'serverInfo' => { 'name' => 'test', 'version' => '1.0' } },
                        { 'Mcp-Session-Id' => session_id })
        when 'notifications/initialized' then { status: 202, body: '' }
        else json_response(body['id'], { 'tools' => [] })
        end
      end
      stub_request(:delete, url).to_return(status: 200, body: '')
    end

    shared_examples 'a transport that forgets its thread state after terminating' do
      it 'leaves no authorization fingerprint behind for the worker thread' do
        stub_session
        server.list_tools

        server.cleanup

        expect(a_request(:delete, url)).to have_been_made
        expect(Thread.current[server.send(:request_authorization_key)]).to be_nil
        expect(server.send(:request_authorization_recorded?)).to be(false)
      end
    end

    context 'with the plain HTTP transport' do
      subject(:server) do
        MCPClient::ServerHTTP.new(base_url: base_url, endpoint: '/mcp', retries: 0, protocol: :legacy,
                                  headers: { 'Authorization' => 'Bearer static' })
      end

      it_behaves_like 'a transport that forgets its thread state after terminating'
    end

    context 'with the Streamable HTTP transport' do
      subject(:server) do
        MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: '/mcp', retries: 0, protocol: :legacy,
                                            headers: { 'Authorization' => 'Bearer static' })
      end

      it_behaves_like 'a transport that forgets its thread state after terminating'
    end
  end
end

# --- round33 ---------------------------------------------------------------

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

# --- round36 ---------------------------------------------------------------

# MCP 2026-07-28 caching, thirty-sixth review round: what a cached result is
# bound to is settled by the request that produced it, and by nothing that
# happens afterwards. Host metadata the caller goes on mutating, the
# `notifications/cancelled` sent for a request that was abandoned, a request a
# host `on_complete` nests inside a failing one, and a connection whose
# middleware stack was locked before the recorder could be installed all name
# a caller other than the one whose result is in hand.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 36' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def plain_http(**opts)
    MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  # A minimal OAuth provider writing whatever bearer it currently holds.
  def provider_holding(token)
    Class.new do
      def initialize(token)
        @token = token
      end

      def apply_authorization(request)
        request.headers['Authorization'] = "Bearer #{@token.value}" if @token.value
      end
    end.new(token)
  end

  def bearer_of(request)
    request.headers['Authorization'].to_s.sub(/\ABearer /, '')
  end

  describe 'host metadata rewritten while the request that carries it is in flight' do
    it 'binds a read to the tenant its own request went out with' do
      tenant = +'alice'
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        carried = body.dig('params', '_meta', 'example.com/tenant')
        sent << carried
        # The host rewrites, in place, the very string it handed the
        # transport — while this response is on its way back.
        tenant.replace('bob')
        json_response(body['id'],
                      { 'contents' => [{ 'uri' => 'file:///secret', 'text' => "#{carried}-secret" }],
                        'ttlMs' => 60_000, 'cacheScope' => 'private' })
      end

      server = streamable
      server.request_meta = { 'example.com/tenant' => tenant }
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['alice-secret'])
      expect(sent).to eq(['alice'])

      # The host asks as bob now. Alice's contents answer alice's tenant and
      # nobody else's: the entry describes the request that produced it, not
      # the metadata as it stands once the answer is in.
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['bob-secret'])
      expect(sent).to eq(%w[alice bob])
    ensure
      server&.cleanup
    end

    it 'binds a list to the nested metadata its own request went out with' do
      scope = { 'id' => 'alice' }
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        carried = body.dig('params', '_meta', 'example.com/scope', 'id')
        sent << carried
        # In place, in a container the host still holds a reference to.
        scope['id'] = 'bob'
        json_response(body['id'],
                      { 'tools' => [tool("#{carried}-tool")], 'ttlMs' => 60_000, 'cacheScope' => 'private' })
      end

      server = plain_http
      server.request_meta = { 'example.com/scope' => scope }
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])
      expect(sent).to eq(%w[alice bob])
    ensure
      server&.cleanup
    end
  end

  describe 'a request once it is built' do
    it 'carries a copy of the host metadata, so nothing the host still holds can change it' do
      tenant = +'alice'
      server = streamable
      server.request_meta = { 'example.com/tenant' => tenant }
      request = server.send(:build_jsonrpc_request, 'resources/read', { 'uri' => 'file:///a' }, 1)
      fingerprint = server.send(:request_params_fingerprint)

      tenant.replace('bob')

      # The body is generated when the request is sent, the fingerprint when
      # it is built: they describe the same request only because neither can
      # follow the host's own object.
      expect(request.dig('params', '_meta', 'example.com/tenant')).to eq('alice')
      expect(server.send(:params_fingerprint_of, request['params'])).to eq(fingerprint)
    ensure
      server&.cleanup
    end

    it 'is bound to the fingerprint taken when it was built, not to one taken from it afterwards' do
      server = streamable
      server.request_meta = { 'example.com/tenant' => 'alice' }
      request = server.send(:build_jsonrpc_request, 'tools/list', {}, 7)
      built = server.send(:request_params_fingerprint)
      response = instance_double(Faraday::Response, env: double('env', request_headers: {}))
      allow(server).to receive(:send_http_request).and_return(response)
      allow(server).to receive(:parse_response) do
        # Whatever reaches the request between its going out and its answer
        # being bound to it, the exchange is bound to what it sent.
        request['params']['_meta']['example.com/tenant'] = 'bob'
        { 'tools' => [] }
      end

      server.send(:exchange_jsonrpc, request)

      expect(server.send(:request_params_fingerprint)).to eq(built)
    ensure
      server&.cleanup
    end
  end

  describe 'a re-fetch that fails after the credentials moved on' do
    def legacy_initialize_result
      { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
        'serverInfo' => { 'name' => 'test', 'version' => '1.0' } }
    end

    it 'does not judge a timed-out re-fetch by the cancellation it sent afterwards' do
      token = Struct.new(:value).new('bob')
      seen = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        seen << [body['method'], bearer_of(request)]
        case body['method']
        when 'initialize' then json_response(body['id'], legacy_initialize_result)
        when 'tools/list'
          # Alice's re-fetch never answers; by the time the client gives up
          # on it the host holds bob's credentials again.
          if bearer_of(request) == 'alice'
            token.value = 'bob'
            raise Faraday::TimeoutError, 'execution expired'
          end

          json_response(body['id'], { 'tools' => [tool('bob-tool')], 'ttlMs' => 0, 'cacheScope' => 'private' })
        else { status: 202, body: '' }
        end
      end

      server = plain_http(protocol: :legacy, oauth_provider: provider_holding(token))
      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])

      token.value = 'alice'
      # The `notifications/cancelled` the client sends for the abandoned
      # request goes out with bob's credentials, on this very thread. It does
      # not make bob's private list alice's to serve ("MUST NOT be shared
      # across authorization contexts").
      expect { server.list_tools }.to raise_error(MCPClient::Errors::RequestTimeoutError)
      expect(seen).to include(['tools/list', 'alice'], ['notifications/cancelled', 'bob'])
    ensure
      server&.cleanup
    end

    it 'does not judge a failed exchange by a request its own response phase nested' do
      token = Struct.new(:value).new('bob')
      state = { server: nil, nested: false }
      nesting = Class.new(Faraday::Middleware) do
        define_method(:on_complete) do |env|
          request = begin
            JSON.parse(env.request_body.to_s)
          rescue StandardError
            nil
          end
          next unless request.is_a?(Hash) && request['method'] == 'tools/list'
          next if state[:nested] || token.value != 'alice'

          state[:nested] = true
          # The host rotates and sends a request of its own on this thread,
          # then the exchange it is nested in fails.
          token.value = 'bob'
          state[:server].read_resource('file:///public')
          # A failure the transport cannot salvage a delivered body from (a
          # stall after the response arrived would be the response).
          raise Faraday::SSLError, 'SSL_connect returned=1 errno=0 state=error: certificate verify failed'
        end
      end

      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'tools/list'
          json_response(body['id'],
                        { 'tools' => [tool("#{bearer_of(request)}-tool")], 'ttlMs' => 0, 'cacheScope' => 'private' })
        when 'resources/read'
          json_response(body['id'],
                        { 'contents' => [{ 'uri' => 'file:///public', 'text' => 'public' }], 'ttlMs' => 0 })
        else json_response(body['id'], discover_result)
        end
      end

      server = streamable(oauth_provider: provider_holding(token), faraday_config: ->(f) { f.use nesting })
      state[:server] = server
      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])

      token.value = 'alice'
      expect { server.list_tools }.to raise_error(MCPClient::Errors::ConnectionError)
      expect(state[:nested]).to be(true)
    ensure
      server&.cleanup
    end
  end

  describe 'a connection locked before the Authorization recorder could be installed' do
    it 'does not file an authenticated read under the anonymous context' do
      token = Struct.new(:value).new('alice')
      reads = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        bearer = bearer_of(request)
        reads << bearer
        json_response(body['id'],
                      { 'contents' => [{ 'uri' => 'file:///secret',
                                         'text' => "#{bearer.empty? ? 'anonymous' : bearer}-secret" }],
                        'ttlMs' => 60_000, 'cacheScope' => 'private' })
      end

      redacting = Class.new(Faraday::Middleware) do
        def on_complete(env)
          # A host that keeps credentials out of what it logs.
          env.request_headers.delete('Authorization')
        end
      end
      config = lambda do |f|
        f.use redacting
        # The host builds the stack itself; Faraday locks it, and the
        # recorder can no longer be installed.
        f.builder.app
      end

      server = streamable(oauth_provider: provider_holding(token), faraday_config: config)
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['alice-secret'])

      token.value = nil
      # Nothing on this connection recorded what alice's request went out
      # with, so nothing says her contents may answer an anonymous caller.
      expect(server.read_resource('file:///secret').map(&:text)).to eq(['anonymous-secret'])
      expect(reads).to eq(['alice', ''])
    ensure
      server&.cleanup
    end
  end

  describe 'a resources/list page asked for by cursor' do
    def stub_resource_pages(counts)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/list'

        cursor = body.dig('params', 'cursor')
        counts[cursor] += 1
        result = if cursor
                   { 'resources' => [{ 'uri' => 'file:///b', 'name' => 'b' }], 'ttlMs' => 60_000,
                     'cacheScope' => 'public' }
                 else
                   { 'resources' => [{ 'uri' => 'file:///a', 'name' => 'a' }], 'nextCursor' => 'p2',
                     'ttlMs' => 60_000, 'cacheScope' => 'public' }
                 end
        json_response(body['id'], result)
      end
    end

    shared_examples 'a cursor that is part of the cache key' do
      it 'is never answered from the page cached without one' do
        counts = Hash.new(0)
        stub_resource_pages(counts)
        server = build_server

        expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
        # The first page is fresh, and a second no-cursor listing is served
        # from it without a request.
        expect(server.list_resources['resources'].map(&:name)).to eq(['a'])
        expect(counts[nil]).to eq(1)

        # A cursor names a different position in the sequence, so it is a
        # different cache key: the spec's own example of parameters that
        # affect the result ("MUST NOT serve a cached response for a
        # different method or parameters").
        expect(server.list_resources(cursor: 'p2')['resources'].map(&:name)).to eq(['b'])
        expect(counts['p2']).to eq(1)
        expect(counts[nil]).to eq(1)
      ensure
        server&.cleanup
      end
    end

    context 'on Streamable HTTP' do
      def build_server = streamable

      it_behaves_like 'a cursor that is part of the cache key'
    end

    context 'on plain HTTP' do
      def build_server = plain_http

      it_behaves_like 'a cursor that is part of the cache key'
    end
  end

  describe 'a list whose pages disagree about their scope' do
    it 'is private as soon as one page is' do
      now = 1000.0
      pages = [{ 'ttlMs' => 60_000, 'cacheScope' => 'public' },
               { 'ttlMs' => 30_000, 'cacheScope' => 'private' }]
              .map { |result| MCPClient::CachedResult.from_result(result, nil, now: now) }

      combined = MCPClient::CachedResult.combine(pages, ['x'], now: now)

      # A server that mixes them breaks its own MUST; taking the first
      # page's scope would then share the private page across callers.
      expect(combined.cache_scope).to eq('private')
    end

    it 'is not served across authorization contexts, page 1 being public' do
      token = Struct.new(:value).new('alice')
      lists = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        bearer = bearer_of(request)
        cursor = body.dig('params', 'cursor')
        lists << [bearer, cursor]
        result = if cursor
                   { 'tools' => [tool("#{bearer}-private")], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
                 else
                   { 'tools' => [tool('shared')], 'nextCursor' => 'p2', 'ttlMs' => 60_000, 'cacheScope' => 'public' }
                 end
        json_response(body['id'], result)
      end

      server = streamable(oauth_provider: provider_holding(token))
      expect(server.list_tools.map(&:name)).to eq(%w[shared alice-private])
      expect(server.cache_info(:tools)[:cache_scope]).to eq('private')

      token.value = 'bob'
      expect(server.list_tools.map(&:name)).to eq(%w[shared bob-private])
      expect(lists).to eq([['alice', nil], %w[alice p2], ['bob', nil], %w[bob p2]])
    ensure
      server&.cleanup
    end
  end

  describe 'a resources/read whose re-fetch fails' do
    it 'raises rather than serving the stale contents, as lists may' do
      clock = { now: 1000.0 }
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        reads += 1
        next { status: 503, body: 'down' } if reads > 1

        json_response(body['id'],
                      { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'secret' }],
                        'ttlMs' => 1_000, 'cacheScope' => 'private' })
      end

      server = streamable
      allow(server).to receive(:monotonic_now) { clock[:now] }
      expect(server.read_resource('file:///a').map(&:text)).to eq(['secret'])

      clock[:now] += 2
      # "Clients MAY serve stale responses if errors occur during
      # re-fetching" — this client does so for lists and for nothing else.
      expect { server.read_resource('file:///a') }.to raise_error(MCPClient::Errors::ResourceReadError)
      expect(reads).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'a cached read handed to a caller' do
    it 'carries a copy of its binary contents, which the caller may change' do
      reads = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'resources/read'

        reads += 1
        json_response(body['id'],
                      { 'contents' => [{ 'uri' => 'file:///a', 'mimeType' => 'image/png',
                                         'blob' => Base64.strict_encode64('original') }],
                        'ttlMs' => 60_000, 'cacheScope' => 'public' })
      end

      server = streamable
      first = server.read_resource('file:///a').first
      first.blob.replace(Base64.strict_encode64('rewritten'))

      # The next caller of the same cached read gets what the server sent,
      # not what the last one made of it.
      expect(server.read_resource('file:///a').first.content).to eq('original')
      expect(reads).to eq(1)
    ensure
      server&.cleanup
    end
  end

  describe 'a ttlMs that runs out with nobody asking' do
    it 'is not a poll interval: nothing is fetched until the next access' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        next json_response(body['id'], discover_result) unless body['method'] == 'tools/list'

        lists += 1
        json_response(body['id'], { 'tools' => [tool("t#{lists}")], 'ttlMs' => 50, 'cacheScope' => 'public' })
      end

      server = streamable
      expect(server.list_tools.map(&:name)).to eq(['t1'])
      # Sampled after the fetch: whatever a request needs while it runs (the
      # modern HTTP branch gives each one a deadline watchdog) is already
      # accounted for. What this pins is that the idle expiry that follows
      # starts nothing of its own.
      idle_threads = Thread.list.size

      # Real time, so that anything scheduled to run at expiry would have
      # run: the TTL is long gone, nothing was fetched and nothing was
      # started to fetch ("clients SHOULD NOT treat ttlMs as a polling
      # interval"); the entry is simply stale when it is next read.
      sleep 0.2
      expect(lists).to eq(1)
      expect(Thread.list.size).to be <= idle_threads
      expect(server.cache_info(:tools)[:fresh]).to be(false)

      expect(server.list_tools.map(&:name)).to eq(['t2'])
      expect(lists).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'the client cache above the transport' do
    def stub_lists(counts, tools:)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        result = case body['method']
                 when 'tools/list' then { 'tools' => tools, 'ttlMs' => 60_000, 'cacheScope' => 'public' }
                 when 'prompts/list'
                   { 'prompts' => [{ 'name' => 'p' }], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
                 when 'resources/list'
                   { 'resources' => [{ 'uri' => 'file:///a', 'name' => 'a' }], 'ttlMs' => 60_000,
                     'cacheScope' => 'public' }
                 else discover_result
                 end
        json_response(body['id'], result)
      end
    end

    # Counting wire requests cannot tell the two caches apart: the transport
    # entry would answer a second transport fetch just as silently. Counting
    # the transport calls is what makes a client hit observable.
    def counted(server, operation)
      asked = 0
      allow(server).to receive(operation).and_wrap_original do |original, *args, **kwargs|
        asked += 1
        original.call(*args, **kwargs)
      end
      -> { asked }
    end

    def client_for(server)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
    end

    it 'answers a second prompts listing without reaching the transport' do
      counts = Hash.new(0)
      stub_lists(counts, tools: [tool('a')])
      server = streamable
      asked = counted(server, :list_prompts)
      client = client_for(server)

      expect(client.list_prompts.map(&:name)).to eq(['p'])
      expect(client.list_prompts.map(&:name)).to eq(['p'])
      expect(asked.call).to eq(1)
      expect(counts['prompts/list']).to eq(1)
    ensure
      server&.cleanup
    end

    it 'answers a second resources listing without reaching the transport' do
      counts = Hash.new(0)
      stub_lists(counts, tools: [tool('a')])
      server = streamable
      asked = counted(server, :list_resources)
      client = client_for(server)

      expect(client.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(client.list_resources['resources'].map(&:name)).to eq(['a'])
      expect(asked.call).to eq(1)
      expect(counts['resources/list']).to eq(1)
    ensure
      server&.cleanup
    end

    it 'answers a second listing of an empty, hinted list without reaching the transport' do
      counts = Hash.new(0)
      stub_lists(counts, tools: [])
      server = streamable
      asked = counted(server, :list_tools)
      client = client_for(server)

      # A server may list nothing, and its ttlMs says so for as long as it
      # holds: an empty snapshot is a hit like any other.
      expect(client.list_tools).to eq([])
      expect(client.list_tools).to eq([])
      expect(asked.call).to eq(1)
      expect(counts['tools/list']).to eq(1)
    ensure
      server&.cleanup
    end
  end
end

# --- round39 ---------------------------------------------------------------

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

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
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

  describe 'a stale server/discover result' do
    # The probe answers without completions and a short TTL; every later
    # discover declares completions.
    def stub_discover(ttl_ms:, later_capabilities:)
      counts = Hash.new(0)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        counts[body['method']] += 1
        case body['method']
        when 'server/discover'
          capabilities = counts['server/discover'] == 1 ? { 'tools' => {} } : later_capabilities
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => capabilities, 'ttlMs' => ttl_ms, 'cacheScope' => 'public' })
        when 'completion/complete'
          json_response(body['id'], { 'completion' => { 'values' => ['x'] } })
        else json_response(body['id'], {})
        end
      end
      counts
    end

    it 'is refreshed once its ttlMs has elapsed before a capability it lacked is refused, on Streamable HTTP' do
      clock = { now: 10.0 }
      counts = stub_discover(ttl_ms: 500, later_capabilities: { 'tools' => {}, 'completions' => {} })
      server = streamable
      allow(server).to receive(:monotonic_now) { clock[:now] }
      server.connect
      expect(server.cache_info(:discover)).to include(ttl_ms: 500, fresh: true)

      # Still fresh: the capability the stale-to-be result lacks is refused
      # without another probe.
      expect do
        server.complete(ref: { 'type' => 'ref/prompt', 'name' => 'p' }, argument: { 'name' => 'a', 'value' => '' })
      end
        .to raise_error(MCPClient::Errors::CapabilityError)
      expect(counts['server/discover']).to eq(1)

      clock[:now] += 1.0
      expect(server.cache_info(:discover)[:fresh]).to be(false)
      values = server.complete(ref: { 'type' => 'ref/prompt', 'name' => 'p' },
                               argument: { 'name' => 'a', 'value' => '' })
      expect(values['values']).to eq(['x'])
      expect(counts['server/discover']).to eq(2)
      expect(counts['completion/complete']).to eq(1)
    ensure
      server&.cleanup
    end

    it 'is refreshed once, and the refusal stands when the fresh result lacks the capability too' do
      clock = { now: 10.0 }
      counts = stub_discover(ttl_ms: 500, later_capabilities: { 'tools' => {} })
      server = plain_http
      allow(server).to receive(:monotonic_now) { clock[:now] }
      server.connect
      clock[:now] += 1.0

      expect do
        server.complete(ref: { 'type' => 'ref/prompt', 'name' => 'p' }, argument: { 'name' => 'a', 'value' => '' })
      end
        .to raise_error(MCPClient::Errors::CapabilityError)
      expect(counts['server/discover']).to eq(2)
      expect(counts['completion/complete']).to eq(0)
    ensure
      server&.cleanup
    end

    # One rule for every reading of the hint, on one clock, so the freshness
    # the capability gate acts on is the one cache_info(:discover) reports.
    it 'is judged by the same rule and clock as cache_info(:discover), on stdio' do
      clock = { now: 50.0 }
      server = MCPClient::ServerStdio.new(command: 'echo test')
      allow(server).to receive(:monotonic_now) { clock[:now] }
      discover = { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => {} }

      server.send(:apply_discover_result, discover.merge('ttlMs' => -1))
      expect(server.cache_info(:discover)[:fresh]).to be(false)
      expect(server.send(:discovery_fresh?)).to be(false)

      server.send(:apply_discover_result, discover.merge('ttlMs' => 1500.5))
      expect(server.cache_info(:discover)).to include(ttl_ms: 1500.5, fresh: true)
      expect(server.send(:discovery_fresh?)).to be(true)
      clock[:now] += 1.6
      expect(server.cache_info(:discover)[:fresh]).to be(false)
      expect(server.send(:discovery_fresh?)).to be(false)

      # No hint: "if ttlMs is absent, clients SHOULD assume 0" -- the result
      # is stale at once, on both readings, and re-read on the next access
      # that needs it (the stateless stdio branch pins the re-discovery).
      server.send(:apply_discover_result, discover)
      expect(server.cache_info(:discover)).to include(ttl_ms: 0, fresh: false)
      expect(server.send(:discovery_fresh?)).to be(false)
    end
  end

  describe 'an expired list whose re-fetch fails on the SSE transport' do
    it 'raises rather than serving the stale copy, which is the HTTP transports\' fallback' do
      clock = { now: 0.0 }
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', retries: 0)
      allow(server).to receive(:monotonic_now) { clock[:now] }
      allow(server).to receive(:ensure_initialized)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      lists = 0
      allow(server).to receive(:rpc_request).with('tools/list', anything) do
        lists += 1
        raise MCPClient::Errors::TransientServerError, 'HTTP 503' if lists > 1

        { 'tools' => [{ 'name' => 'old', 'inputSchema' => { 'type' => 'object' } }], 'ttlMs' => 1_000 }
      end

      expect(server.list_tools.map(&:name)).to eq(['old'])
      clock[:now] += 2
      expect { server.list_tools }.to raise_error(MCPClient::Errors::MCPError)
      expect(lists).to eq(2)
    end
  end

  describe 'an empty list an older server put no hint on' do
    def stub_legacy_lists(tools_by_call)
      lists = { count: 0 }
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then { status: 404, body: '' }
        when 'initialize'
          json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                                      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
        when 'tools/list'
          lists[:count] += 1
          json_response(body['id'], { 'tools' => tools_by_call.call(lists[:count]) })
        else { status: 202, body: '' }
        end
      end
      lists
    end

    it 'is asked for again on the next call, while a non-empty one is kept until a change notification' do
      lists = stub_legacy_lists(->(n) { n < 3 ? [] : [tool('late')] })
      server = streamable

      expect(server.list_tools).to eq([])
      expect(server.list_tools).to eq([])
      expect(lists[:count]).to eq(2)
      expect(server.list_tools.map(&:name)).to eq(['late'])
      expect(server.list_tools.map(&:name)).to eq(['late'])
      expect(lists[:count]).to eq(3)
    ensure
      server&.cleanup
    end
  end
end
