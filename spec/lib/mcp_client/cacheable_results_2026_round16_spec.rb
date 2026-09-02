# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, sixteenth review round: the client-level list
# caches are bound to the effective parameters they were filled under and
# hand out copies, and a result's TTL runs from the moment its response was
# received — not from the end of the notification callbacks its response
# dispatched.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 16' do
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

  def progress_notification
    { 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
      'params' => { 'progressToken' => 'p', 'progress' => 1 } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def client_for(server)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
  end

  # A server whose private tool list varies by the vendor `tenant` metadata.
  # `framed` answers tools/list as an SSE stream that first dispatches a
  # progress notification.
  def stub_tenant_server(counts, framed: false)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      if body['method'] == 'tools/list'
        tenant = body.dig('params', '_meta', 'tenant')
        result = { 'tools' => [tool("tool-#{tenant}")], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
        if framed
          sse_response([progress_notification, { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => result }])
        else
          json_response(body['id'], result)
        end
      else
        json_response(body['id'], discover_result)
      end
    end
  end

  it 'does not serve the client cache once a transport fetch ran under other parameters' do
    counts = Hash.new(0)
    stub_tenant_server(counts)
    server = streamable
    server.request_meta = { 'tenant' => 'a' }
    client = client_for(server)

    expect(client.list_tools.map(&:name)).to eq(['tool-a'])
    expect(client.list_tools.map(&:name)).to eq(['tool-a'])
    expect(counts['tools/list']).to eq(1)

    server.request_meta = { 'tenant' => 'b' }
    expect(server.list_tools.map(&:name)).to eq(['tool-b'])
    expect(client.list_tools.map(&:name)).to eq(['tool-b'])
  ensure
    server&.cleanup
  end

  it 'does not serve the client cache after a callback switched parameters mid-fetch' do
    counts = Hash.new(0)
    stub_tenant_server(counts, framed: true)
    server = streamable
    server.request_meta = { 'tenant' => 'a' }
    client = client_for(server)
    nested = 0
    client.on_notification do |_srv, method, _params|
      next unless method == 'notifications/progress' && nested.zero?

      nested += 1
      server.request_meta = { 'tenant' => 'b' }
      server.list_tools
    end

    expect(client.list_tools.map(&:name)).to eq(['tool-a'])
    expect(nested).to eq(1)
    expect(client.list_tools.map(&:name)).to eq(['tool-b'])
  ensure
    server&.cleanup
  end

  it 'hands out copies from the client cache' do
    counts = Hash.new(0)
    stub_tenant_server(counts)
    server = streamable
    server.request_meta = { 'tenant' => 'a' }
    client = client_for(server)

    first = client.list_tools
    first.first.instance_variable_set(:@name, 'tampered')
    expect(client.list_tools.map(&:name)).to eq(['tool-a'])
    client.list_tools.first.instance_variable_set(:@name, 'tampered-hit')
    expect(client.list_tools.map(&:name)).to eq(['tool-a'])
    expect(counts['tools/list']).to eq(1)
  ensure
    server&.cleanup
  end

  it 'starts a list TTL when the response was received, before its notification callbacks ran' do
    counts = Hash.new(0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      if body['method'] == 'tools/list'
        result = { 'tools' => [tool('slow')], 'ttlMs' => 200 }
        sse_response([progress_notification, { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => result }])
      else
        json_response(body['id'], discover_result)
      end
    end
    server = streamable
    server.on_notification { |method, _params| sleep 0.4 if method == 'notifications/progress' }

    expect(server.list_tools.map(&:name)).to eq(['slow'])
    expect(server.cache_fresh?(:tools)).to be(false)
    server.list_tools
    expect(counts['tools/list']).to eq(2)
  ensure
    server&.cleanup
  end

  it 'starts a read TTL when the response was received, before its notification callbacks ran' do
    counts = Hash.new(0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      if body['method'] == 'resources/read'
        result = { 'contents' => [{ 'uri' => 'file:///x', 'text' => 'x' }], 'ttlMs' => 200 }
        sse_response([progress_notification, { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => result }])
      else
        json_response(body['id'], discover_result)
      end
    end
    server = streamable
    server.on_notification { |method, _params| sleep 0.4 if method == 'notifications/progress' }

    expect(server.read_resource('file:///x').first.text).to eq('x')
    server.read_resource('file:///x')
    expect(counts['resources/read']).to eq(2)
  ensure
    server&.cleanup
  end
end
