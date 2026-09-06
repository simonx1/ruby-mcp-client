# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'zlib'

# MCP 2026-07-28 protocol foundations, seventh review round: the 404 that
# tells a session expiry (2025-11-25) from a modern server's well-formed
# -32601 answer is read the way every other HTTP error body is — a JSON-RPC
# 2.0 envelope, size-bounded, gunzipped when compressed — on the response
# path and through a host's raise_error middleware alike; the stdio
# subscription operations validate the result discriminator; an invalid
# result never holds up a sibling waiter.
RSpec.describe 'MCP 2026-07-28 protocol foundations — round 7' do
  describe 'a session-bearing 404 read like every other HTTP error body' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/rpc' }
    let(:method_not_found) { { 'code' => -32_601, 'message' => 'Method not found' } }

    # The era is deliberately left unestablished: these examples are about
    # how the 404 BODY is decoded, and on a session negotiated under
    # 2025-11-25 the expiry rule is unconditional on the body (round 8).
    def session_server(klass, **opts)
      server = klass.new(base_url: base_url, endpoint: endpoint, retries: 0, **opts)
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@session_id, 'session-abc')
      server
    end

    def posted_methods
      WebMock::RequestRegistry.instance.requested_signatures.hash.keys
                              .map { |signature| JSON.parse(signature.body)['method'] }
    end

    def gzip(text)
      StringIO.new.tap { |io| Zlib::GzipWriter.wrap(io) { |gz| gz.write(text) } }.string
    end

    # The old session answers the request with `expired`; a fresh initialize
    # is accepted and the replayed request answered.
    def serve_expiry(expired)
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          { status: 200, headers: { 'Content-Type' => 'application/json', 'Mcp-Session-Id' => 'session-fresh' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                              'serverInfo' => { 'name' => 's', 'version' => '1' } }) }
        when 'notifications/initialized'
          { status: 202, body: '' }
        else
          if request.headers['Mcp-Session-Id'] == 'session-abc'
            expired
          else
            { status: 200, headers: { 'Content-Type' => 'application/json' },
              body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'answered' => true }) }
          end
        end
      end
    end

    def not_found(payload, headers = {})
      { status: 404, headers: { 'Content-Type' => 'application/json' }.merge(headers), body: payload }
    end

    shared_examples 'classifies the 404 by its decoded JSON-RPC body' do
      it 'restarts the session on a 404 whose body is not a JSON-RPC 2.0 envelope' do
        serve_expiry(not_found(JSON.generate('error' => { 'code' => -32_601, 'message' => 'gone' })))

        expect(server.rpc_request('vendor/unknown')).to eq({ 'answered' => true })
        expect(posted_methods).to eq(%w[vendor/unknown initialize notifications/initialized vendor/unknown])
        expect(server.instance_variable_get(:@session_id)).to eq('session-fresh')
      end

      it 'restarts the session on a 404 whose envelope names another JSON-RPC version' do
        serve_expiry(not_found(JSON.generate('jsonrpc' => '1.0', 'id' => 1, 'error' => method_not_found)))

        expect(server.rpc_request('vendor/unknown')).to eq({ 'answered' => true })
        expect(posted_methods.count('initialize')).to eq(1)
      end

      it 'restarts the session on a malformed -32601 (no message) even with a session id' do
        serve_expiry(not_found(JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => { 'code' => -32_601 })))

        expect(server.rpc_request('vendor/unknown')).to eq({ 'answered' => true })
        expect(posted_methods.count('initialize')).to eq(1)
      end

      it 'restarts the session on a 404 whose body is over the inspection ceiling' do
        padding = 'x' * (MCPClient::JsonRpcCommon::MAX_ERROR_BODY_BYTES + 1)
        oversized = JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => method_not_found.merge('data' => padding))
        serve_expiry(not_found(oversized))

        expect(server.rpc_request('vendor/unknown')).to eq({ 'answered' => true })
        expect(posted_methods.count('initialize')).to eq(1)
      end

      it 'answers a gzip-encoded well-formed -32601 as MethodNotFoundError without a restart' do
        serve_expiry(not_found(gzip(JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => method_not_found)),
                               'Content-Encoding' => 'gzip'))

        expect { server.rpc_request('vendor/unknown') }
          .to raise_error(MCPClient::Errors::MethodNotFoundError) { |e| expect(e.http_status).to eq(404) }
        expect(posted_methods).to eq(['vendor/unknown'])
        expect(server.instance_variable_get(:@session_id)).to eq('session-abc')
      end

      it 'treats a gzip 404 body that inflates past the ceiling as a session expiry' do
        padding = 'x' * (MCPClient::JsonRpcCommon::MAX_ERROR_BODY_BYTES + 1)
        huge = JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'error' => method_not_found.merge('data' => padding))
        serve_expiry(not_found(gzip(huge), 'Content-Encoding' => 'gzip'))

        expect(server.rpc_request('vendor/unknown')).to eq({ 'answered' => true })
        expect(posted_methods.count('initialize')).to eq(1)
      end
    end

    [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
      context "with #{klass} on the response path" do
        let(:server) { session_server(klass) }

        include_examples 'classifies the 404 by its decoded JSON-RPC body'
      end

      context "with #{klass} through a host's raise_error middleware" do
        let(:server) { session_server(klass, faraday_config: ->(conn) { conn.response :raise_error }) }

        include_examples 'classifies the 404 by its decoded JSON-RPC body'
      end
    end
  end

  describe 'the stdio subscription operations validate the result discriminator' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

    def answer(result)
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response).and_return({ 'jsonrpc' => '2.0', 'id' => 1, 'result' => result })
    end

    before do
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@capabilities, { 'resources' => { 'subscribe' => true } })
    end

    %i[subscribe_resource unsubscribe_resource].each do |operation|
      it "raises InvalidResultError from #{operation} for an unknown discriminator on a legacy session" do
        server.instance_variable_set(:@protocol_version, '2025-11-25')
        answer({ 'resultType' => 'weird' })

        expect { server.public_send(operation, 'file:///x') }
          .to raise_error(MCPClient::Errors::InvalidResultError, /weird/)
      end

      it "accepts a #{operation} result without a discriminator on a legacy session" do
        server.instance_variable_set(:@protocol_version, '2025-11-25')
        answer({})

        expect(server.public_send(operation, 'file:///x')).to be(true)
      end

      it "raises InvalidResultError from #{operation} for an unknown discriminator on a modern session" do
        server.instance_variable_set(:@protocol_version, '2026-07-28')
        answer({ 'resultType' => 'weird' })

        expect { server.public_send(operation, 'file:///x') }.to raise_error(MCPClient::Errors::InvalidResultError)
      end
    end
  end

  describe 'the SSE handshake names the versions a modern-only server supports' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }
    let(:rejection) do
      MCPClient::Errors::ServerError.from_jsonrpc(
        'code' => -32_022, 'message' => 'Unsupported protocol version',
        'data' => { 'supported' => ['2026-07-28'], 'requested' => '2025-11-25' }
      )
    end

    it 'raises a ConnectionError naming them, with the typed error as the cause' do
      allow(server).to receive(:send_jsonrpc_request).and_raise(rejection)

      expect { server.send(:perform_initialize) }.to raise_error(MCPClient::Errors::ConnectionError) do |e|
        expect(e.message).to include('server supports: 2026-07-28')
        expect(e.cause).to be_a(MCPClient::Errors::UnsupportedProtocolVersionError)
        expect(e.cause.supported).to eq(['2026-07-28'])
      end
      expect(server.protocol_version).to be_nil
    end
  end
end
