# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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

  describe 'the freshness probe' do
    it 'models the operation whose cache is checked, not the last request sent' do
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
      holder = { other: 'alice' }
      server = streamable(faraday_config: ->(f) { f.use method_aware_middleware, holder })
      nested = 0
      server.on_notification do |method, _params|
        next unless method == 'notifications/progress' && nested.zero?

        # The callback switches principal and sends a request of its own on
        # this very thread while the outer tools/list is still being handled.
        nested += 1
        holder[:other] = 'bob'
        server.ping
      end

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(nested).to eq(1)

      # Bob must not be served Alice's private list.
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
      old_epoch = server.cache_epoch
      server.send(:invalidate_cache, :tools)
      fresh = { 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'public' }
      server.send(:record_cache_hint, :tools, fresh, ['fresh'], epoch: server.cache_epoch)

      mixed = [{ 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'private' }] * 2
      server.send(:record_paginated_cache_hint, :tools, mixed, nil, contexts: %w[alice bob], epoch: old_epoch)

      expect(server.send(:stale_list_value, :tools)).to eq(['fresh'])
      expect(server.cache_info(:tools)[:fresh]).to be(true)
    ensure
      server&.cleanup
    end
  end
end
