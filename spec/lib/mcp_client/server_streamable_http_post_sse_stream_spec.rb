# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 Streamable HTTP: when a POST returns Content-Type: text/event-stream,
# the server MAY send JSON-RPC requests and notifications on that stream before the
# response, MAY send priming events (id + empty data), and MAY omit the `event:` field
# (the SSE default event type is "message"). The client MUST support all of these and
# return the JSON-RPC response that answers the originating request.
RSpec.describe MCPClient::ServerStreamableHTTP, 'POST SSE response stream handling' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  let(:server) do
    described_class.new(
      base_url: base_url,
      endpoint: endpoint,
      read_timeout: 5,
      retries: 0,
      name: 'post-sse-test'
    )
  end

  after do
    server.cleanup
  end

  let(:initialize_response) do
    {
      jsonrpc: '2.0',
      id: 1,
      result: {
        protocolVersion: MCPClient::PROTOCOL_VERSION,
        capabilities: {},
        serverInfo: { name: 'post-sse-test', version: '1.0.0' }
      }
    }
  end

  # The request issued after connect gets JSON-RPC id 2 (initialize used id 1)
  let(:rpc_result) { { 'ok' => true, 'value' => 42 } }
  let(:rpc_response) { { jsonrpc: '2.0', id: 2, result: rpc_result } }

  def sse_event(payload, type: 'message', id: nil)
    lines = []
    lines << "event: #{type}" if type
    lines << "id: #{id}" if id
    lines << "data: #{payload.is_a?(String) ? payload : payload.to_json}"
    "#{lines.join("\n")}\n\n"
  end

  def stub_connect!
    stub_request(:post, "#{base_url}#{endpoint}")
      .with(body: hash_including('method' => 'initialize'))
      .to_return(
        status: 200,
        body: sse_event(initialize_response),
        headers: { 'Content-Type' => 'text/event-stream' }
      )

    stub_request(:post, "#{base_url}#{endpoint}")
      .with(body: hash_including('method' => 'notifications/initialized'))
      .to_return(status: 202, body: '')
  end

  def stub_rpc_call(sse_body)
    stub_request(:post, "#{base_url}#{endpoint}")
      .with(body: hash_including('method' => 'test/method'))
      .to_return(
        status: 200,
        body: sse_body,
        headers: { 'Content-Type' => 'text/event-stream' }
      )
  end

  before do
    stub_connect!
    server.connect
  end

  it 'dispatches an interleaved notification and returns the id-matched response' do
    notifications = []
    server.on_notification { |method, params| notifications << [method, params] }

    progress = {
      jsonrpc: '2.0',
      method: 'notifications/progress',
      params: { progressToken: 'tok', progress: 50, total: 100 }
    }
    stub_rpc_call(sse_event(progress) + sse_event(rpc_response))

    result = server.rpc_request('test/method', {})

    expect(result).to eq(rpc_result)
    expect(notifications).to include(
      ['notifications/progress', { 'progressToken' => 'tok', 'progress' => 50, 'total' => 100 }]
    )
  end

  it 'answers a server ping received on the POST response stream' do
    ping = { jsonrpc: '2.0', id: 'ping-1', method: 'ping' }
    stub_rpc_call(sse_event(ping) + sse_event(rpc_response))

    pong_bodies = []
    stub_request(:post, "#{base_url}#{endpoint}")
      .with(body: hash_including('id' => 'ping-1'))
      .to_return do |request|
        pong_bodies << JSON.parse(request.body)
        { status: 200, body: '' }
      end

    result = server.rpc_request('test/method', {})
    expect(result).to eq(rpc_result)

    deadline = Time.now + 2
    sleep 0.05 while pong_bodies.empty? && Time.now < deadline

    expect(pong_bodies.size).to eq(1)
    expect(pong_bodies.first['result']).to eq({})
    expect(pong_bodies.first['id']).to eq('ping-1')
  end

  it 'parses a response event that omits the event: field (SSE default type is message)' do
    stub_rpc_call("data: #{rpc_response.to_json}\n\n")

    expect(server.rpc_request('test/method', {})).to eq(rpc_result)
  end

  it 'records the id of a priming event with empty data and still returns the response' do
    stub_rpc_call("id: evt-42\ndata:\n\n#{sse_event(rpc_response)}")

    expect(server.rpc_request('test/method', {})).to eq(rpc_result)
    expect(server.instance_variable_get(:@last_event_id)).to eq('evt-42')
  end

  it 'returns the response whose id matches the request, not an earlier stale response' do
    stale = { jsonrpc: '2.0', id: 999, result: { 'stale' => true } }
    stub_rpc_call(sse_event(stale) + sse_event(rpc_response))

    expect(server.rpc_request('test/method', {})).to eq(rpc_result)
  end

  it 'accepts a lone response with a mismatched id for backwards compatibility' do
    lone = { jsonrpc: '2.0', id: 999, result: rpc_result }
    stub_rpc_call(sse_event(lone))

    expect(server.rpc_request('test/method', {})).to eq(rpc_result)
  end

  it 'skips events with invalid JSON and still returns the response' do
    stub_rpc_call(sse_event('this is not json') + sse_event(rpc_response))

    expect(server.rpc_request('test/method', {})).to eq(rpc_result)
  end

  it 'raises TransportError when the stream contains no JSON-RPC response' do
    progress = {
      jsonrpc: '2.0',
      method: 'notifications/progress',
      params: { progressToken: 'tok', progress: 1 }
    }
    stub_rpc_call(sse_event(progress))

    expect { server.rpc_request('test/method', {}) }.to raise_error(
      MCPClient::Errors::TransportError, /No JSON-RPC response found/
    )
  end
end
