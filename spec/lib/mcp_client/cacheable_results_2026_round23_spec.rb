# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twenty-third review round: resource template
# lists are cached like the other lists, a direct (non-SSE) response is
# dated before it is parsed, resource contents are copied iteratively, and
# the client-level snapshot forgets a server's tag with its slice and
# re-checks freshness right before the copy.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 23' do
  let(:url) { 'https://example.com/mcp' }

  def templates_result(name, ttl_ms: 60_000)
    { 'resourceTemplates' => [{ 'uriTemplate' => "file:///{#{name}}", 'name' => name }],
      'ttlMs' => ttl_ms, 'cacheScope' => 'public' }
  end

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def streamable(base = 'https://example.com')
    MCPClient::ServerStreamableHTTP.new(base_url: base, endpoint: '/mcp', retries: 0)
  end

  def scripted(server, answers)
    %i[ensure_connected ensure_initialized].each do |m|
      allow(server).to receive(m) if server.respond_to?(m, true)
    end
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    calls = 0
    allow(server).to receive(:rpc_request) do |method, _params = {}, **_opts|
      raise "unexpected #{method}" unless method == 'resources/templates/list'

      calls += 1
      answers[calls - 1] || answers.last
    end
    -> { calls }
  end

  def http_transports
    { 'Streamable HTTP' => [streamable, url],
      'HTTP' => [MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/rpc', retries: 0),
                 'https://example.com/rpc'] }
  end

  def stub_templates(endpoint, answers)
    lists = 0
    stub_request(:post, endpoint).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'resources/templates/list'
        lists += 1
        json_response(body['id'], answers[lists - 1] || answers.last)
      else
        json_response(body['id'], discover_result)
      end
    end
    -> { lists }
  end

  it 'serves a fresh resource template list without a second request on every HTTP transport' do
    http_transports.each do |label, (server, endpoint)|
      lists = stub_templates(endpoint, [templates_result('one'), templates_result('two')])

      first = server.list_resource_templates
      second = server.list_resource_templates

      expect(first['resourceTemplates'].map(&:name)).to eq(['one']), label
      expect(second['resourceTemplates'].map(&:name)).to eq(['one']), label
      expect(lists.call).to eq(1), label
    end
  end

  it 'serves a fresh resource template list without a second request on HTTP+SSE' do
    server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
    calls = scripted(server, [templates_result('one'), templates_result('two')])

    server.list_resource_templates
    expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['one'])
    expect(calls.call).to eq(1)
  end

  it 'attaches the template list to its entry on stdio so the client-level cache can stay fresh' do
    server = MCPClient::ServerStdio.new(command: 'echo test')
    scripted(server, [templates_result('one')])

    server.list_resource_templates

    expect(server.send(:cache_entry_token, :templates)).not_to be_nil
    expect(server.cache_fresh?(:templates)).to be(true)
  end

  it 're-fetches a template list whose ttlMs is 0 on every access' do
    server = streamable
    calls = scripted(server, [templates_result('one', ttl_ms: 0), templates_result('two', ttl_ms: 0)])

    server.list_resource_templates
    expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['two'])
    expect(calls.call).to eq(2)
  end

  it 'hands out copies of a cached template list' do
    server = streamable
    scripted(server, [templates_result('one')])

    server.list_resource_templates['resourceTemplates'].first.instance_variable_set(:@name, 'tampered')

    expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['one'])
  end

  it 'serves the stale template list when a re-fetch fails transiently' do
    server = streamable
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'resources/templates/list'
        lists += 1
        lists == 1 ? json_response(body['id'], templates_result('one', ttl_ms: 0)) : { status: 503, body: '' }
      else
        json_response(body['id'], discover_result)
      end
    end

    server.list_resource_templates

    expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['one'])
    expect(lists).to eq(2)
  end

  it 'dates a direct (non-SSE) response from its arrival, before parsing' do
    server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
    server.instance_variable_set(:@use_sse, false)
    body = JSON.generate('jsonrpc' => '2.0', 'id' => 7, 'result' => {})
    allow(server).to receive(:post_json_rpc_request).and_return(instance_double(Faraday::Response, body: body,
                                                                                                   status: 200))
    allow(JSON).to receive(:parse).and_wrap_original do |original, *args|
      sleep 0.05
      original.call(*args)
    end

    server.send(:send_jsonrpc_request, { 'jsonrpc' => '2.0', 'id' => 7, 'method' => 'ping' })
    now = server.send(:monotonic_now)

    expect(now - server.send(:response_received_at)).to be >= 0.05
  end

  it 'copies deeply nested resource content without overflowing the stack' do
    deep = 'leaf'
    100_000.times { deep = { 'n' => deep } }
    content = MCPClient::ResourceContent.new(uri: 'file:///a', name: 'a', text: 't', annotations: deep,
                                             meta: { 'k' => [deep] })

    copy = content.dup

    expect(copy.annotations).not_to equal(content.annotations)
    node = copy.annotations
    depth = 0
    while node.is_a?(Hash)
      node = node['n']
      depth += 1
    end
    expect(depth).to eq(100_000)
    expect(node).to eq('leaf')
  end

  describe 'client-level snapshots with two servers' do
    def two_server_client(counts, ttl_ms: 60_000, &during_list)
      servers = { 'https://a.example.com' => streamable('https://a.example.com'),
                  'https://b.example.com' => streamable('https://b.example.com') }
      allow(MCPClient::ServerFactory).to receive(:create) do |config, *_|
        servers.fetch(config[:base_url] || config['base_url'])
      end
      servers.each_key do |base|
        stub_request(:post, "#{base}/mcp").to_return do |request|
          body = JSON.parse(request.body)
          counts[[base, body['method']]] += 1
          if body['method'] == 'tools/list'
            override = during_list&.call(base, counts[[base, 'tools/list']])
            tools = [{ 'name' => "tool-#{base[8]}", 'inputSchema' => { 'type' => 'object' } }]
            override || json_response(body['id'],
                                      { 'tools' => tools, 'ttlMs' => ttl_ms, 'cacheScope' => 'public' })
          else
            json_response(body['id'], discover_result)
          end
        end
      end
      client = MCPClient::Client.new(mcp_server_configs: servers.keys.map do |b|
        { type: 'streamable_http', base_url: b }
      end)
      [client, servers]
    end

    it 'does not serve a partial snapshot after clear_cache when one server failed to refill' do
      counts = Hash.new(0)
      client, servers = two_server_client(counts)
      b = servers['https://b.example.com']

      expect(client.list_tools.map(&:name)).to contain_exactly('tool-a', 'tool-b')
      client.clear_cache
      # B is unreachable during the refill: the client keeps going with A.
      failures = 0
      allow(b).to receive(:list_tools).and_wrap_original do |original, *args|
        failures += 1
        raise MCPClient::Errors::ConnectionError, 'down' if failures == 1

        original.call(*args)
      end
      expect(client.list_tools.map(&:name)).to eq(['tool-a'])

      expect(client.list_tools.map(&:name)).to contain_exactly('tool-a', 'tool-b')
    end

    it 'does not copy a snapshot whose TTL elapsed during the freshness verdict' do
      counts = Hash.new(0)
      client, servers = two_server_client(counts, ttl_ms: 1_000)
      client.list_tools
      a = servers['https://a.example.com']
      allow(client).to receive(:caches_fresh?).and_wrap_original do |original, *args|
        verdict = original.call(*args)
        # Server A's TTL runs out right after the verdict was reached.
        real = a.send(:monotonic_now)
        allow(a).to receive(:monotonic_now).and_return(real + 5)
        verdict
      end

      client.list_tools

      expect(counts[['https://a.example.com', 'tools/list']]).to eq(2)
    end
  end
end
