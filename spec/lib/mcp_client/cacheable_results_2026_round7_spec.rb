# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, seventh review round: mixed-credential lists are
# never a fallback, list values and their hints are stored together,
# x-mcp-header derivation uses a fresh tool list, cached resource contents
# are copied field by field, and the authorization probe sees the
# configured headers.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 7' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name, header: nil)
    schema = { 'type' => 'object', 'properties' => { 'region' => { 'type' => 'string' } } }
    schema['properties']['region']['x-mcp-header'] = header if header
    { 'name' => name, 'inputSchema' => schema }
  end

  def scripted_provider(tokens)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) do |req|
      token = tokens.size > 1 ? tokens.shift : tokens.first
      req.headers['Authorization'] = "Bearer #{token}" if token
    end
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
  end

  def streamable(provider = nil, headers: {})
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                        oauth_provider: provider, headers: headers)
  end

  it 'never offers a mixed-credential private list as a fallback to an unauthenticated request' do
    # discover (alice), page 1 (alice), page 2 (bob), then no token at all
    provider = scripted_provider(['alice', 'alice', 'bob', nil])
    lists = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        lists += 1
        next { status: 503, body: '' } if request.headers['Authorization'].nil?

        page = if body.dig('params',
                           'cursor')
                 { 'tools' => [tool('b')] }
               else
                 { 'tools' => [tool('a')], 'nextCursor' => 'p2' }
               end
        json_response(body['id'], page.merge('ttlMs' => 60_000, 'cacheScope' => 'private'))
      else
        json_response(body['id'], discover_result)
      end
    end
    server = streamable(provider)

    expect(server.list_tools.size).to eq(2)
    expect { server.list_tools }.to raise_error(MCPClient::Errors::MCPError)
  ensure
    server&.cleanup
  end

  it 'serves a cached list from the entry that carries its hint' do
    provider = scripted_provider(['alice'])
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      result = if body['method'] == 'tools/list'
                 { 'tools' => [tool('mine')], 'ttlMs' => 60_000, 'cacheScope' => 'private' }
               else
                 discover_result
               end
      json_response(body['id'], result)
    end
    server = streamable(provider)
    expect(server.list_tools.map(&:name)).to eq(['mine'])

    # A value stored without its hint (another request's leftovers) is not what gets served.
    server.instance_variable_set(:@tools, [MCPClient::Tool.new(name: 'foreign', description: '', schema: {})])

    expect(server.list_tools.map(&:name)).to eq(['mine'])
  ensure
    server&.cleanup
  end

  it 'derives x-mcp-header values from a fresh tool list' do
    lists = 0
    seen_headers = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      case body['method']
      when 'tools/list'
        lists += 1
        # The header annotation disappears on the second listing.
        json_response(body['id'], { 'tools' => [tool('t', header: lists == 1 ? 'Region' : nil)], 'ttlMs' => 0 })
      when 'tools/call'
        seen_headers << request.headers['Mcp-Param-Region']
        json_response(body['id'], { 'content' => [] })
      else
        json_response(body['id'], discover_result)
      end
    end
    server = streamable

    server.list_tools
    server.call_tool('t', { 'region' => 'eu' })

    expect(lists).to eq(2)
    expect(seen_headers).to eq([nil])
  ensure
    server&.cleanup
  end

  it 'copies every mutable field of a cached resource content' do
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      result = if body['method'] == 'resources/read'
                 { 'contents' => [{ 'uri' => 'file:///a', 'name' => 'a', 'title' => 'A', 'mimeType' => 'text/plain',
                                    'text' => 'secret', 'annotations' => { 'audience' => ['user'] },
                                    '_meta' => { 'k' => 'v' } }],
                   'ttlMs' => 60_000 }
               else
                 discover_result
               end
      json_response(body['id'], result)
    end
    server = streamable
    first = server.read_resource('file:///a').first
    first.uri << '?edited'
    first.name << '!'
    first.title << '!'
    first.mime_type << ';charset=x'
    first.annotations['audience'] << 'assistant'
    first.meta['k'] << 'x'

    second = server.read_resource('file:///a').first
    expect([second.uri, second.name, second.title, second.mime_type]).to eq(['file:///a', 'a', 'A', 'text/plain'])
    expect(second.annotations).to eq({ 'audience' => ['user'] })
    expect(second.meta).to eq({ 'k' => 'v' })
  ensure
    server&.cleanup
  end

  it 'lets the authorization probe see the configured headers when the provider has no token' do
    reads = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      result = if body['method'] == 'resources/read'
                 reads += 1
                 { 'contents' => [{ 'uri' => 'file:///a', 'text' => "read #{reads}" }], 'ttlMs' => 60_000,
                   'cacheScope' => 'private' }
               else
                 discover_result
               end
      json_response(body['id'], result)
    end
    server = streamable(scripted_provider([nil]), headers: { 'Authorization' => 'Bearer static' })

    expect(server.read_resource('file:///a').first.text).to eq('read 1')
    expect(server.read_resource('file:///a').first.text).to eq('read 1')
    expect(reads).to eq(1)
  ensure
    server&.cleanup
  end
end
