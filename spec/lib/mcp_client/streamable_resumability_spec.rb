# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 Streamable HTTP — Resumability and Redelivery (SEP-1699):
# - "If the client wishes to resume after a disconnection ... it SHOULD issue
#   an HTTP GET to the MCP endpoint, and include the Last-Event-ID header" —
#   "Resumption is always via HTTP GET with Last-Event-ID", regardless of how
#   the original stream was initiated.
# - "The client MUST respect the retry field, waiting the given number of
#   milliseconds before attempting to reconnect."
# - After a server-initiated close, the client SHOULD poll by reconnecting —
#   not re-POST the original (possibly non-idempotent) request.
RSpec.describe 'Streamable HTTP resumability (SEP-1699)' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }
  let(:server) do
    MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0,
                                        read_timeout: 2, name: 'resume-test')
  end

  after { server.cleanup }

  def init_body
    "event: message\ndata: #{JSON.generate(
      jsonrpc: '2.0', id: 1,
      result: { protocolVersion: MCPClient::PROTOCOL_VERSION, capabilities: {},
                serverInfo: { name: 's', version: '1' } }
    )}\n\n"
  end

  def stub_connect!(get_body: '')
    stub_request(:post, "#{base_url}#{endpoint}")
      .with(body: hash_including('method' => 'initialize'))
      .to_return(status: 200, body: init_body, headers: { 'Content-Type' => 'text/event-stream' })
    stub_request(:post, "#{base_url}#{endpoint}")
      .with(body: hash_including('method' => 'notifications/initialized'))
      .to_return(status: 202, body: '')
    stub_request(:get, "#{base_url}#{endpoint}")
      .to_return(status: 200, body: get_body, headers: { 'Content-Type' => 'text/event-stream' })
  end

  describe 'Last-Event-ID placement' do
    it 'is not attached to JSON-RPC POSTs' do
      stub_connect!
      server.connect
      server.instance_variable_set(:@last_event_id, 'evt-7')

      post_requests = []
      stub_request(:post, "#{base_url}#{endpoint}")
        .with(body: hash_including('method' => 'tools/list'))
        .to_return do |request|
          post_requests << request
          { status: 200,
            body: "event: message\ndata: #{JSON.generate(jsonrpc: '2.0', id: 2, result: { tools: [] })}\n\n",
            headers: { 'Content-Type' => 'text/event-stream' } }
        end

      server.rpc_request('tools/list', {})

      expect(post_requests.first.headers).not_to have_key('Last-Event-Id')
      expect(post_requests.first.headers).not_to have_key('Last-Event-ID')
    end

    it 'is attached to the GET events request when a cursor exists' do
      server.instance_variable_set(:@last_event_id, 'evt-9')
      req = Struct.new(:headers).new({})
      server.send(:apply_events_headers, req)

      expect(req.headers['Last-Event-ID']).to eq('evt-9')
    end
  end

  describe 'retry directive' do
    it 'records the retry field from the GET events stream' do
      server.send(:parse_and_handle_event, "retry: 250\ndata: \n")

      expect(server.instance_variable_get(:@sse_retry_ms)).to eq(250)
    end

    it 'records the retry field from a POST SSE response' do
      body = "retry: 5000\nevent: message\ndata: #{JSON.generate(jsonrpc: '2.0', id: 3, result: {})}\n\n"
      server.send(:parse_sse_response, body, 3)

      expect(server.instance_variable_get(:@sse_retry_ms)).to eq(5000)
    end

    it 'uses the server retry directive as the reconnect delay' do
      server.instance_variable_set(:@sse_retry_ms, 250)
      expect(server.send(:events_reconnect_delay, 4)).to eq(0.25)
    end

    it 'falls back to the caller delay without a directive' do
      expect(server.send(:events_reconnect_delay, 4)).to eq(4)
    end
  end

  describe 'polling pattern: stream closed before the response' do
    it 'resumes via GET with Last-Event-ID instead of re-POSTing' do
      # POST answers with a priming event (id, no data) and a fast retry
      # directive, then the stream ends — the SEP-1699 polling pattern.
      post_stub = stub_request(:post, "#{base_url}#{endpoint}")
                  .with(body: hash_including('method' => 'tools/call'))
                  .to_return(status: 200, body: "retry: 100\nid: evt-42\ndata:\n\n",
                             headers: { 'Content-Type' => 'text/event-stream' })

      stub_connect!
      # The replayed response arrives on a GET carrying the cursor (registered
      # after the general GET stub so it takes precedence for cursor requests)
      resumed = { jsonrpc: '2.0', id: 2, result: { 'content' => [] } }
      stub_request(:get, "#{base_url}#{endpoint}")
        .with(headers: { 'Last-Event-ID' => 'evt-42' })
        .to_return(status: 200, body: "id: evt-43\nevent: message\ndata: #{resumed.to_json}\n\n",
                   headers: { 'Content-Type' => 'text/event-stream' })
      server.connect

      result = server.rpc_request('tools/call', { 'name' => 'x' })

      expect(result).to eq({ 'content' => [] })
      expect(post_stub).to have_been_requested.once
    end

    it 'raises a non-retryable error when resumption fails, without re-POSTing' do
      post_stub = stub_request(:post, "#{base_url}#{endpoint}")
                  .with(body: hash_including('method' => 'tools/call'))
                  .to_return(status: 200, body: "retry: 100\nid: evt-42\ndata:\n\n",
                             headers: { 'Content-Type' => 'text/event-stream' })
      stub_connect!
      server.connect

      expect { server.rpc_request('tools/call', { 'name' => 'x' }) }.to raise_error(
        MCPClient::Errors::ServerError, /resum/i
      )
      expect(post_stub).to have_been_requested.once
    end
  end
end
