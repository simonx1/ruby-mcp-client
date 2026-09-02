# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, nineteenth review round: cleanup racing an
# in-flight first list leaves no hintless transport copy to serve, and a
# client-level slice is never identified by "no transport entry".
RSpec.describe 'MCP 2026-07-28 cacheable results — round 19' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def streamable
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
  end

  # tools/list answers with ttlMs 0 (re-fetch on every access); the block
  # runs while the request is in flight.
  def stub_server(counts, &during_list)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      if body['method'] == 'tools/list'
        during_list&.call
        json_response(body['id'], { 'tools' => [{ 'name' => "tool-#{counts['tools/list']}",
                                                  'inputSchema' => { 'type' => 'object' } }],
                                    'ttlMs' => 0 })
      else
        json_response(body['id'], discover_result)
      end
    end
  end

  it 'does not serve a transport copy after cleanup raced the first list fetch' do
    counts = Hash.new(0)
    server = streamable
    cleaned = false
    stub_server(counts) do
      next if cleaned

      cleaned = true
      server.cleanup
    end

    first = server.list_tools.map(&:name)
    second = server.list_tools.map(&:name)

    expect(first).to eq(['tool-1'])
    expect(second).to eq(['tool-2'])
    expect(counts['tools/list']).to eq(2)
  end

  it 'does not keep a client slice for a fetch that recorded no transport entry' do
    counts = Hash.new(0)
    server = streamable
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
    cleaned = false
    stub_server(counts) do
      next if cleaned

      cleaned = true
      server.cleanup
    end

    client.list_tools
    client.list_tools

    expect(counts['tools/list']).to eq(2)
  end

  it 'marks every list kind stale on cleanup even when nothing was recorded yet' do
    server = streamable

    server.send(:clear_result_cache)

    %i[tools prompts resources templates].each do |kind|
      expect(server.send(:cache_fresh?, kind)).to be(false), kind.to_s
    end
    expect(server.send(:fresh_list_value, :tools) { [:transport_copy] }).to be_nil
  end
end
