# frozen_string_literal: true

require 'bundler/setup'
require 'mcp_client'
require 'webmock'
require 'json'

WebMock.enable!
WebMock.disable_net_connect!

url = 'https://example.com/mcp'

def json_response(id, result)
  { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
    headers: { 'Content-Type' => 'application/json' } }
end

discover = { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
             'capabilities' => { 'tools' => {} } }

server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                             headers: { 'Authorization' => 'Bearer alice' })
lists = 0
WebMock.stub_request(:post, url).to_return do |request|
  body = JSON.parse(request.body)
  case body['method']
  when 'server/discover'
    json_response(body['id'], discover)
  when 'tools/list'
    lists += 1
    if lists == 1
      json_response(body['id'], { 'tools' => [{ 'name' => 'secret-alice', 'inputSchema' => { 'type' => 'object' } }],
                                  'ttlMs' => 0, 'cacheScope' => 'private' })
    else
      server.cleanup
      { status: 503, body: '' }
    end
  else
    json_response(body['id'], {})
  end
end

first = server.list_tools.map(&:name)
puts "first=#{first.inspect} lists=#{lists}"
begin
  second = server.list_tools.map(&:name)
  puts "second=#{second.inspect} lists=#{lists} SERVED_STALE_AFTER_CLEANUP"
rescue StandardError => e
  puts "second_raised=#{e.class} #{e.message} lists=#{lists}"
end
puts "cache_fresh=#{server.cache_fresh?(:tools)} info=#{server.cache_info(:tools).inspect}"
