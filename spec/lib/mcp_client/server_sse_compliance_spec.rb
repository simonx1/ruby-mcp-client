# frozen_string_literal: true

require 'spec_helper'

# MCP spec compliance tests for the legacy HTTP+SSE transport.
#
# Spec references:
# - MCP 2025-11-25 basic/lifecycle.mdx (Error Handling, Version Negotiation,
#   Initialization)
# - MCP 2024-11-05 basic/transports (HTTP with SSE: the server MUST send an
#   `endpoint` event containing a URI for the client to use for sending
#   messages; all subsequent client messages MUST be POSTed to this endpoint)
RSpec.describe MCPClient::ServerSSE do
  let(:base_url) { 'https://example.com/mcp' }
  let(:rpc_url) { 'https://example.com/messages' }
  let(:server) { described_class.new(base_url: base_url) }

  # Put the server into a "connected over SSE" state without opening a real
  # SSE stream, mirroring the conventions in server_sse_spec.rb.
  def mark_connected(rpc_endpoint: '/messages')
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@sse_connected, true)
    server.instance_variable_set(:@rpc_endpoint, rpc_endpoint)
  end

  describe 'JSON-RPC error response delivery over SSE (lifecycle.mdx Error Handling)' do
    # MCP 2025-11-25 basic/lifecycle.mdx: "Implementations SHOULD be prepared
    # to handle these error cases: Protocol version mismatch, Failure to
    # negotiate required capabilities, Request timeouts". An error RESPONSE
    # (id-bearing) must reach the pending request instead of being swallowed
    # until the request times out.
    before do
      mark_connected
      server.instance_variable_set(:@initialized, true)
      stub_request(:post, rpc_url).to_return(status: 202, body: '')
    end

    it 'stores an id-bearing error response for the waiting caller instead of swallowing it' do
      error_response = {
        jsonrpc: '2.0',
        id: 42,
        error: { code: -32_602, message: 'Unsupported protocol version' }
      }
      server.send(:parse_and_handle_sse_event, "event: message\ndata: #{error_response.to_json}\n\n")

      sse_results = server.instance_variable_get(:@sse_results)
      expect(sse_results).to have_key(42)
    end

    it 'raises ServerError with the server error message for a pending request' do
      error_response = {
        jsonrpc: '2.0',
        id: 1,
        error: { code: -32_602, message: 'Unsupported protocol version' }
      }
      # Deliver the error response first so the waiter finds it immediately
      server.send(:parse_and_handle_sse_event, "event: message\ndata: #{error_response.to_json}\n\n")

      request = { 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call', 'params' => {} }
      expect do
        server.send(:send_jsonrpc_request, request)
      end.to raise_error(MCPClient::Errors::ServerError, /Unsupported protocol version/)
    end

    it 'does not hang until timeout when the server responds with an error' do
      server.instance_variable_set(:@read_timeout, 3)
      error_response = { jsonrpc: '2.0', id: 2, error: { code: -32_601, message: 'Method not found' } }
      server.send(:parse_and_handle_sse_event, "event: message\ndata: #{error_response.to_json}\n\n")

      request = { 'jsonrpc' => '2.0', 'id' => 2, 'method' => 'nope', 'params' => {} }
      started = Time.now
      expect do
        server.send(:send_jsonrpc_request, request)
      end.to raise_error(MCPClient::Errors::ServerError, /Method not found/)
      expect(Time.now - started).to be < 2
    end

    it 'still applies connection-level auth handling to id-less error payloads' do
      # Errors that cannot be routed to a pending request (no id) keep the
      # existing connection-level authorization handling.
      error_payload = { jsonrpc: '2.0', error: { code: 401, message: 'Unauthorized: bad token' } }
      expect do
        server.send(:parse_and_handle_sse_event, "event: message\ndata: #{error_payload.to_json}\n\n")
      end.to raise_error(MCPClient::Errors::ConnectionError, /Authorization failed/)
    end
  end

  describe 'endpoint event URI resolution (2024-11-05 HTTP with SSE)' do
    # MCP 2024-11-05 basic/transports (HTTP with SSE): "the server MUST send
    # an `endpoint` event containing a URI for the client to use for sending
    # messages. All subsequent client messages MUST be sent as HTTP POST
    # requests to this endpoint." The endpoint URI is a URI reference and must
    # be resolved against the SSE connection URL (RFC 3986 section 5.1.3).
    it 'resolves a relative endpoint URI against the SSE connection URL' do
      server = described_class.new(base_url: 'https://example.com/api/v1/sse')
      server.send(:parse_and_handle_sse_event, "event: endpoint\ndata: messages?sessionId=abc\n\n")

      expect(server.instance_variable_get(:@rpc_endpoint))
        .to eq('https://example.com/api/v1/messages?sessionId=abc')
    end

    it 'resolves a path-absolute endpoint URI against the SSE connection origin' do
      server = described_class.new(base_url: 'https://example.com/api/v1/sse')
      server.send(:parse_and_handle_sse_event, "event: endpoint\ndata: /messages?sessionId=xyz\n\n")

      expect(server.instance_variable_get(:@rpc_endpoint))
        .to eq('https://example.com/messages?sessionId=xyz')
    end

    it 'keeps an absolute endpoint URI as-is' do
      server = described_class.new(base_url: 'https://example.com/sse')
      server.send(:parse_and_handle_sse_event,
                  "event: endpoint\ndata: https://example.com/messages?sessionId=1\n\n")

      expect(server.instance_variable_get(:@rpc_endpoint))
        .to eq('https://example.com/messages?sessionId=1')
    end

    it 'POSTs subsequent messages to the resolved endpoint' do
      server = described_class.new(base_url: 'https://example.com/api/v1/sse')
      server.instance_variable_set(:@use_sse, false)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.send(:parse_and_handle_sse_event, "event: endpoint\ndata: messages?sessionId=abc\n\n")

      stub_request(:post, 'https://example.com/api/v1/messages?sessionId=abc')
        .to_return(status: 200, body: { result: {} }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      server.rpc_request('ping')

      expect(WebMock).to have_requested(:post, 'https://example.com/api/v1/messages?sessionId=abc')
    end
  end

  describe 'MCP-Protocol-Version header (lifecycle.mdx Version Negotiation)' do
    # MCP 2025-11-25 basic/lifecycle.mdx: "If using HTTP, the client MUST
    # include the `MCP-Protocol-Version: <protocol-version>` HTTP header on
    # all subsequent requests to the MCP server."
    let(:initialize_result) do
      {
        jsonrpc: '2.0',
        id: 1,
        result: {
          protocolVersion: '2025-11-25',
          capabilities: {},
          serverInfo: { name: 'test-server', version: '1.0' }
        }
      }
    end

    before do
      mark_connected
      # Direct (non-SSE) response mode so initialize gets its result from the
      # HTTP response body, following existing spec conventions.
      server.instance_variable_set(:@use_sse, false)

      stub_request(:post, rpc_url)
        .with(body: /"method":"initialize"/)
        .to_return(status: 200, body: initialize_result.to_json,
                   headers: { 'Content-Type' => 'application/json' })
      stub_request(:post, rpc_url)
        .with(body: %r{notifications/initialized})
        .to_return(status: 202, body: '')
      stub_request(:post, rpc_url)
        .with(body: %r{tools/list})
        .to_return(status: 200, body: { result: { tools: [] } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    end

    it 'captures the negotiated protocol version from the initialize result' do
      server.send(:perform_initialize)
      expect(server.instance_variable_get(:@protocol_version)).to eq('2025-11-25')
    end

    it 'sends Mcp-Protocol-Version on all requests after initialize, but not on initialize itself' do
      server.rpc_request('tools/list')

      expect(WebMock).to have_requested(:post, rpc_url)
        .with(body: %r{tools/list}, headers: { 'Mcp-Protocol-Version' => '2025-11-25' })
      # The initialized notification is itself a "subsequent request"
      expect(WebMock).to have_requested(:post, rpc_url)
        .with(body: %r{notifications/initialized}, headers: { 'Mcp-Protocol-Version' => '2025-11-25' })
      # The initialize POST precedes version negotiation, so no header there
      expect(WebMock).to(have_requested(:post, rpc_url).with(body: /"method":"initialize"/) do |req|
        !req.headers.key?('Mcp-Protocol-Version')
      end)
    end

    it 'sends Mcp-Protocol-Version on responses to server-initiated requests' do
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server.instance_variable_set(:@initialized, true)
      stub_request(:post, rpc_url).to_return(status: 202, body: '')

      server.post_jsonrpc_response({ 'jsonrpc' => '2.0', 'id' => 9, 'result' => {} })

      expect(WebMock).to have_requested(:post, rpc_url)
        .with(headers: { 'Mcp-Protocol-Version' => '2025-11-25' })
    end
  end

  describe 'initialize result validation (lifecycle.mdx Initialization)' do
    # MCP 2025-11-25 basic/lifecycle.mdx: "After successful initialization,
    # the client MUST send an `initialized` notification". A truthy non-object
    # initialize result is not a successful initialization: the client must
    # not silently continue the session without ever sending
    # notifications/initialized.
    before do
      mark_connected
      server.instance_variable_set(:@use_sse, false)
    end

    it 'raises ConnectionError when the initialize result is not a JSON object' do
      stub_request(:post, rpc_url)
        .to_return(status: 200, body: { jsonrpc: '2.0', id: 1, result: 'unexpected' }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      expect do
        server.send(:perform_initialize)
      end.to raise_error(MCPClient::Errors::ConnectionError, /initialize/i)

      # The mandatory initialized notification must not have been sent on a
      # failed handshake.
      expect(WebMock).not_to have_requested(:post, rpc_url)
        .with(body: %r{notifications/initialized})
    end

    it 'does not mark the session initialized on an invalid initialize result' do
      stub_request(:post, rpc_url)
        .to_return(status: 200, body: { jsonrpc: '2.0', id: 1, result: 'unexpected' }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      expect { server.rpc_request('tools/list') }.to raise_error(MCPClient::Errors::ConnectionError)
      expect(server.instance_variable_get(:@initialized)).to be_falsey
    end
  end

  describe 'review hardening (Codex findings)' do
    it 'fails the handshake on an unresolvable endpoint URI' do
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')

      expect do
        server.send(:handle_endpoint_event, 'http://[invalid uri')
      end.to raise_error(MCPClient::Errors::TransportError, /endpoint URI/)
      expect(server.instance_variable_get(:@connection_established)).to be_falsey
    end

    it 'surfaces an invalid endpoint promptly via wait_for_connection instead of timing out' do
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')

      # In the real connection path the SSE worker thread swallows the
      # TransportError with a generic rescue, so the failure must also be
      # recorded for the connect caller blocked in wait_for_connection.
      begin
        server.send(:handle_endpoint_event, 'http://[invalid uri')
      rescue MCPClient::Errors::TransportError
        # Swallowed, mirroring the worker thread's generic rescue.
      end

      started = Time.now
      expect do
        server.send(:wait_for_connection, timeout: 5)
      end.to raise_error(MCPClient::Errors::ConnectionError,
                         %r{Invalid endpoint URI in SSE endpoint event: "http://\[invalid uri"})
      expect(Time.now - started).to be < 2
    end

    it 'clears the negotiated protocol version on cleanup' do
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
      server.instance_variable_set(:@protocol_version, '2025-06-18')

      server.cleanup

      expect(server.instance_variable_get(:@protocol_version)).to be_nil
    end
  end
end
