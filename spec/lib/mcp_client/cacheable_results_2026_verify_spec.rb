# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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
