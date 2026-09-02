# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, seventeenth review round: the client-level caches
# are tagged with the parameters of the list they hold (never a leftover of
# another request), prompts are cached as copies, the client maps are read
# and cleared under one lock, an outer request's context survives a parse
# failure, and a queued response is dated from its arrival.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 17' do
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

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  def client_for(server)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com' }])
  end

  # A server whose private lists vary by the vendor `tenant` metadata.
  def stub_tenant_server(counts)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      counts[body['method']] += 1
      tenant = body.dig('params', '_meta', 'tenant')
      case body['method']
      when 'tools/list'
        json_response(body['id'], { 'tools' => [tool("tool-#{tenant}")], 'ttlMs' => 60_000,
                                    'cacheScope' => 'private' })
      when 'prompts/list'
        json_response(body['id'], { 'prompts' => [{ 'name' => "prompt-#{tenant}" }], 'ttlMs' => 60_000,
                                    'cacheScope' => 'private' })
      else
        json_response(body['id'], discover_result)
      end
    end
  end

  it 'tags the client cache with the parameters of the list it holds, not a leftover request' do
    counts = Hash.new(0)
    stub_tenant_server(counts)
    server = streamable
    client = client_for(server)

    server.request_meta = { 'tenant' => 'a' }
    expect(client.list_tools.map(&:name)).to eq(['tool-a'])
    server.request_meta = { 'tenant' => 'b' }
    expect(server.list_tools.map(&:name)).to eq(['tool-b'])
    server.request_meta = { 'tenant' => 'c' }
    server.ping # leaves a request fingerprint for tenant c on this thread
    server.request_meta = { 'tenant' => 'b' }
    expect(client.list_tools.map(&:name)).to eq(['tool-b']) # served from the transport entry
    server.request_meta = { 'tenant' => 'c' }
    expect(server.list_tools.map(&:name)).to eq(['tool-c'])

    expect(client.list_tools.map(&:name)).to eq(['tool-c'])
  end

  it 'caches prompts as copies so a caller cannot poison the client cache' do
    counts = Hash.new(0)
    stub_tenant_server(counts)
    server = streamable
    server.request_meta = { 'tenant' => 'a' }
    client = client_for(server)

    first = client.list_prompts
    first.first.instance_variable_set(:@name, 'tampered')

    expect(client.list_prompts.map(&:name)).to eq(['prompt-a'])
    expect(client.prompt_cache.values.map(&:name)).to eq(['prompt-a'])
    expect(counts['prompts/list']).to eq(1)
  end

  it 'serves one atomic snapshot while a list_changed notification waits for the lock' do
    counts = Hash.new(0)
    stub_tenant_server(counts)
    server = streamable
    server.request_meta = { 'tenant' => 'a' }
    client = client_for(server)
    client.list_tools

    inside = Queue.new
    release = Queue.new
    allow(client).to receive(:caches_fresh?).and_wrap_original do |m, *args|
      fresh = m.call(*args)
      if fresh
        inside << true
        release.pop
      end
      fresh
    end
    reader = Thread.new do
      inside.pop
      client.send(:process_notification, server, 'notifications/tools/list_changed', {})
      :cleared
    end
    hit = Thread.new { client.list_tools }
    inside.pop if reader.alive? && inside.size.positive?
    sleep 0.05
    expect(reader).to be_alive # the clear waits for the snapshot
    release << true

    expect(hit.value.map(&:name)).to eq(['tool-a'])
    expect(reader.value).to eq(:cleared)
    expect(client.tool_cache).to be_empty
  end

  it 'restores the outer request context when parsing the response raises' do
    server = streamable(headers: { 'Authorization' => 'Bearer alice' })
    outer = { '_meta' => { 'tenant' => 'a' } }
    request = { 'jsonrpc' => '2.0', 'id' => 7, 'method' => 'tools/list', 'params' => outer }
    response = instance_double(Faraday::Response,
                               env: double('env', request_headers: { 'Authorization' => 'Bearer alice' }))
    allow(server).to receive(:send_http_request).and_return(response)
    allow(server).to receive(:parse_response) do
      # A notification callback made a nested request as someone else.
      server.send(:note_request_authorization, 'Bearer bob')
      server.send(:note_request_params, { '_meta' => { 'tenant' => 'b' } })
      raise MCPClient::Errors::TransportError, 'stream ended without a response'
    end

    expect { server.send(:exchange_jsonrpc, request) }.to raise_error(MCPClient::Errors::TransportError)

    expect(server.send(:request_authorization_context)).to eq(server.send(:authorization_fingerprint, 'Bearer alice'))
    expect(server.send(:request_params_fingerprint)).to eq(server.send(:params_fingerprint_of, outer))
  end

  it 'dates a queued stdio response from its arrival, not from when the waiter woke' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 2)
    server.instance_variable_get(:@awaiting)[9] = true
    arrival = nil
    Thread.new do
      sleep 0.05
      arrival = server.send(:monotonic_now)
      server.send(:handle_line, JSON.generate('jsonrpc' => '2.0', 'id' => 9, 'result' => {}))
    end
    sleep 0.3
    server.send(:wait_response, 9)

    noted = server.send(:response_received_at)
    expect(noted).to be_within(0.05).of(arrival)
  end

  it 'dates a queued SSE response from its arrival, not from when the waiter polled' do
    server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
    server.send(:register_pending_request, 9)
    arrival = server.send(:monotonic_now)
    server.send(:process_response?, { 'id' => 9, 'result' => {} })
    sleep 0.3
    expect(server.send(:check_for_result, 9)).to eq({})

    noted = server.send(:response_received_at)
    expect(noted).to be_within(0.05).of(arrival)
  end
end
