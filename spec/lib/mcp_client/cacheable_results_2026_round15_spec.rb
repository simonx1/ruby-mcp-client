# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, fifteenth review round: pages of one paginated
# list fetched under differing effective parameters (the host's request_meta
# changed between pages) are never combined into a result the cache serves
# — on HTTP transports and on stdio alike.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 15' do
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

  # A tenant-varying, two-page tools/list. The tenant read from the
  # request's own _meta names the page's tool. Answering the first page
  # flips the host's tenant (`box`), standing in for a notification
  # callback changing request_meta mid-pagination.
  def page_for(body, box = nil)
    tenant = body.dig('params', '_meta', 'tenant')
    cursor = body.dig('params', 'cursor')
    page = { 'tools' => [tool("#{cursor ? 'second' : 'first'}-#{tenant}")], 'ttlMs' => 60_000,
             'cacheScope' => 'private' }
    page['nextCursor'] = 'c' unless cursor
    box[:tenant] = 'b' if box && !cursor
    page
  end

  it 'never serves a list whose pages were fetched under differing parameters (Streamable HTTP)' do
    counts = Hash.new(0)
    box = { tenant: 'a' }
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      result = body['method'] == 'tools/list' ? page_for(body, box) : discover_result
      json_response(body['id'], result)
    end
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    server.request_meta = -> { { 'tenant' => box[:tenant] } }

    mixed = server.list_tools.map(&:name)
    expect(mixed).to eq(%w[first-a second-b])
    expect(server.cache_fresh?(:tools)).to be(false)

    server.request_meta = { 'tenant' => 'b' }
    expect(server.list_tools.map(&:name)).to eq(%w[first-b second-b])
    expect(counts['tools/list']).to eq(4)
  ensure
    server&.cleanup
  end

  it 'never serves a list whose pages were fetched under differing parameters (stdio)' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    box = { tenant: 'a' }
    allow(server).to receive(:wait_response) do |id, **_opts|
      request = JSON.parse(JSON.generate(sent.last))
      result = request['method'] == 'tools/list' ? page_for(request, box) : discover_result
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => result }
    end
    server.request_meta = -> { { 'tenant' => box[:tenant] } }

    expect(server.list_tools.map(&:name)).to eq(%w[first-a second-b])
    expect(server.cache_fresh?(:tools)).to be(false)

    server.request_meta = { 'tenant' => 'b' }
    expect(server.list_tools.map(&:name)).to eq(%w[first-b second-b])
    expect(sent.count { |r| r[:method] == 'tools/list' || r['method'] == 'tools/list' }).to eq(4)
  end

  it 'keeps serving a paginated list whose pages share their parameters' do
    counts = Hash.new(0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      json_response(body['id'], body['method'] == 'tools/list' ? page_for(body) : discover_result)
    end
    server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    server.request_meta = { 'tenant' => 'a' }

    expect(server.list_tools.map(&:name)).to eq(%w[first-a second-a])
    expect(server.list_tools.map(&:name)).to eq(%w[first-a second-a])
    expect(counts['tools/list']).to eq(2)
  ensure
    server&.cleanup
  end
end
