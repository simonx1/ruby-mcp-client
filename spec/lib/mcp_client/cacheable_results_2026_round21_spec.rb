# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twenty-first review round: folding per-URI
# invalidation generations never lets a key's generation stand still, a
# configured Authorization header is found whatever its spelling, and a
# queued response is dated from the moment its line or event arrived.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 21' do
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

  def stub_server(counts)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      if body['method'] == 'tools/list'
        json_response(body['id'], { 'tools' => [{ 'name' => 'tool', 'inputSchema' => { 'type' => 'object' } }],
                                    'ttlMs' => 60_000, 'cacheScope' => 'private' })
      else
        json_response(body['id'], discover_result)
      end
    end
  end

  it 'advances every read generation across a fold' do
    server = streamable
    server.send(:invalidate_read_cache, 'file:///a')
    before = server.send(:cache_epoch, 'read:file:///a')
    untouched_before = server.send(:cache_epoch, 'read:file:///never')

    (MCPClient::ResultCaching::MAX_READ_GENERATIONS + 5).times { |i| server.send(:invalidate_read_cache, "file:///r#{i}") }

    folded = server.send(:cache_epoch, 'read:file:///a')
    expect(folded).not_to eq(before)
    expect(server.send(:cache_epoch, 'read:file:///never')).not_to eq(untouched_before)

    # And nothing the fold left behind can come back: a read still in flight
    # captured one of these, and no later invalidation may hand it out again.
    server.send(:invalidate_read_cache, 'file:///a')
    expect([before, untouched_before, folded]).not_to include(server.send(:cache_epoch, 'read:file:///a'))
  end

  spellings = [{ Authorization: 'Bearer alice' }, { 'AUTHORIZATION' => 'Bearer alice' },
               { authorization: 'Bearer alice' }]
  spellings.each do |hdr|
    it "recognises the configured credential spelled #{hdr.keys.first.inspect}" do
      counts = Hash.new(0)
      stub_server(counts)
      server = streamable(headers: hdr)

      server.list_tools
      server.list_tools

      expect(counts['tools/list']).to eq(1)
      expect(server.send(:current_authorization_context, :tools)).to eq(Digest::SHA256.hexdigest('Bearer alice'))
    end
  end

  it 'finds the credential on the HTTP+SSE transport whatever its spelling' do
    canonical = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse',
                                         headers: { 'Authorization' => 'Bearer x' })
    symbol = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', headers: { authorization: 'Bearer x' })

    expect(symbol.send(:current_authorization_context)).to eq(canonical.send(:current_authorization_context))
    expect(symbol.send(:current_authorization_context)).not_to be_nil
  end

  it 'dates a stdio response from the arrival of its line, before parsing' do
    server = MCPClient::ServerStdio.new(command: 'echo test')
    server.instance_variable_get(:@awaiting)[7] = true
    allow(JSON).to receive(:parse).and_wrap_original do |original, *args|
      sleep 0.05
      original.call(*args)
    end

    server.send(:handle_line, JSON.generate('jsonrpc' => '2.0', 'id' => 7, 'result' => {}))
    now = server.send(:monotonic_now)

    expect(now - server.instance_variable_get(:@response_arrivals)[7]).to be >= 0.05
  end

  it 'dates an SSE response from the arrival of its event, before parsing' do
    server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
    server.instance_variable_get(:@pending_request_ids) << 7
    allow(JSON).to receive(:parse).and_wrap_original do |original, *args|
      sleep 0.05
      original.call(*args)
    end

    server.send(:handle_message_event, { data: JSON.generate('jsonrpc' => '2.0', 'id' => 7, 'result' => {}) })
    now = server.send(:monotonic_now)

    expect(now - server.instance_variable_get(:@sse_result_arrivals)[7]).to be >= 0.05
  end
end
