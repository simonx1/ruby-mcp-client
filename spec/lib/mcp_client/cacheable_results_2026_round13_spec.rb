# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirteenth review round: an uncacheable read
# never evicts another context's or a newer fetch's entry, the freshness
# probe carries the headers a real modern POST carries, cached lists are
# handed out as copies, and a few assertions are made exact.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 13' do
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

  def read_result(text, **hint)
    { 'contents' => [{ 'uri' => 'file:///x', 'text' => text }] }.merge(hint)
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def rotate_token(server, token)
    server.instance_variable_get(:@headers)['Authorization'] = "Bearer #{token}"
  end

  describe 'an uncacheable read' do
    it "leaves another context's fresh private entry in place" do
      reads = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        owner = request.headers['Authorization'].to_s.sub('Bearer ', '')
        case body['method']
        when 'resources/read'
          reads << owner
          if owner == 'alice'
            json_response(body['id'], read_result('secret', 'ttlMs' => 60_000, 'cacheScope' => 'private'))
          else
            json_response(body['id'], read_result('nothing')) # no ttlMs: never cached
          end
        else json_response(body['id'], discover_result)
        end
      end
      server = streamable(headers: { 'Authorization' => 'Bearer alice' })
      expect(server.read_resource('file:///x').first.text).to eq('secret')

      rotate_token(server, 'bob')
      expect(server.read_resource('file:///x').first.text).to eq('nothing')

      rotate_token(server, 'alice')
      expect(server.read_resource('file:///x').first.text).to eq('secret')
      expect(reads).to eq(%w[alice bob])
      expect(server.cache_info(:read, 'file:///x')[:fresh]).to be(true)
    ensure
      server&.cleanup
    end

    it 'leaves a newer entry recorded while it was in flight' do
      stub_request(:post, url).to_return { |request| json_response(JSON.parse(request.body)['id'], discover_result) }
      server = streamable
      fresh = read_result('new', 'ttlMs' => 60_000, 'cacheScope' => 'public')

      server.send(:read_resource_with_cache, 'file:///x') do
        # A later read completes first and is cached; this one comes back
        # without a hint and must not take the slot with it.
        server.send(:read_resource_with_cache, 'file:///x') { fresh }
        read_result('old')
      end

      expect(server.cache_info(:read, 'file:///x')[:fresh]).to be(true)
      expect(server.read_resource('file:///x').first.text).to eq('new')
    ensure
      server&.cleanup
    end

    it 'still replaces the stale entry of its own context' do
      stub_request(:post, url).to_return { |request| json_response(JSON.parse(request.body)['id'], discover_result) }
      server = streamable
      server.send(:read_resource_with_cache, 'file:///x') { read_result('old', 'ttlMs' => 60_000) }
      expect(server.cache_info(:read, 'file:///x')).not_to be_nil
      server.send(:invalidate_cache, 'read:file:///x')

      server.send(:read_resource_with_cache, 'file:///x') { read_result('again') }

      expect(server.cache_info(:read, 'file:///x')).to be_nil
    ensure
      server&.cleanup
    end
  end

  describe 'the freshness probe' do
    it 'carries the routing headers of a real modern request' do
      tools_requests = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'tools/list'
          tools_requests += 1
          json_response(body['id'], { 'tools' => [tool('t')], 'ttlMs' => 60_000, 'cacheScope' => 'private' })
        else
          json_response(body['id'], discover_result)
        end
      end
      # Faraday's own Authorization middleware is the one stack the probe
      # models a request for, so the request it models is inspectable here.
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', 'lister' })

      expect(server.list_tools.map(&:name)).to eq(['t'])
      expect(server.list_tools.map(&:name)).to eq(['t'])

      expect(tools_requests).to eq(1)
      probe = server.send(:middleware_request_headers, {}, 'resources/read', { 'uri' => 'file:///x' })
      expect(probe['MCP-Protocol-Version']).to eq('2026-07-28')
      expect(probe['Mcp-Method']).to eq('resources/read')
      expect(probe['Mcp-Name']).to eq('file:///x')
      expect(probe['Authorization']).to eq('Bearer lister')
    ensure
      server&.cleanup
    end

    it 'is exactly unknown when host middleware cannot be run without sending' do
      stub_request(:post, url).to_return { |request| json_response(JSON.parse(request.body)['id'], discover_result) }
      opaque = Class.new(Faraday::Middleware) do
        def call(env)
          env.request_headers['Authorization'] = 'Bearer alice'
          @app.call(env)
        end
      end
      server = streamable(faraday_config: ->(f) { f.use opaque })

      expect(server.send(:current_authorization_context)).to eq(:unknown)
      expect(server.send(:current_authorization_context, :tools)).to eq(:unknown)
    ensure
      server&.cleanup
    end
  end

  describe 'cached lists' do
    it 'are handed out as copies so a caller cannot change the cache' do
      requests = Hash.new(0)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests[body['method']] += 1
        case body['method']
        when 'tools/list'
          json_response(body['id'], { 'tools' => [tool('t').merge('annotations' => { 'title' => 'T' })],
                                      'ttlMs' => 60_000 })
        when 'prompts/list'
          json_response(body['id'], { 'prompts' => [{ 'name' => 'p', 'arguments' => [] }], 'ttlMs' => 60_000 })
        when 'resources/list'
          json_response(body['id'], { 'resources' => [{ 'uri' => 'file:///r', 'name' => 'r' }], 'ttlMs' => 60_000 })
        else json_response(body['id'], discover_result)
        end
      end
      server = streamable

      tools = server.list_tools
      tools.first.name << '-x'
      tools.first.annotations['title'] << '!'
      tools.clear
      prompts = server.list_prompts
      prompts.first.name << '-x'
      prompts.clear
      resources = server.list_resources
      resources['resources'].first.name << '-x'
      resources['resources'].clear

      expect(server.list_tools.map(&:name)).to eq(['t'])
      expect(server.list_tools.first.annotations).to eq({ 'title' => 'T' })
      expect(server.list_prompts.map(&:name)).to eq(['p'])
      expect(server.list_resources['resources'].map(&:name)).to eq(['r'])
      expect(server.send(:known_tools_for_headers).map(&:name)).to eq(['t'])
      expect(requests.values_at('tools/list', 'prompts/list', 'resources/list')).to eq([1, 1, 1])
    ensure
      server&.cleanup
    end
  end

  describe 'mixed-credential pagination' do
    it 'records a stale placeholder no context matches when the epoch did not move' do
      stub_request(:post, url).to_return { |request| json_response(JSON.parse(request.body)['id'], discover_result) }
      server = streamable
      mixed = [{ 'tools' => [], 'ttlMs' => 60_000, 'cacheScope' => 'private' }] * 2

      server.send(:record_paginated_cache_hint, :tools, mixed, ['mixed'], contexts: %w[alice bob],
                                                                          epoch: server.cache_epoch)

      expect(server.cache_info(:tools)[:fresh]).to be(false)
      expect(server.send(:stale_fallback_for, :tools, server.send(:stale_list_entry, :tools), context: 'alice'))
        .to be_nil
    ensure
      server&.cleanup
    end
  end
end
