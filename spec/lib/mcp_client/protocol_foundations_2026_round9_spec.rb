# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 protocol foundations, ninth review round: the README offers
# Faraday's JSON middleware for reading a server's error bodies, and that
# middleware decodes EVERY response, so the success path must survive it too —
# on both HTTP transports, and whichever spelling the middleware was told to
# produce. A decoded envelope is read for the same members as a parsed one,
# and a decoded body is never handed to a string parser a second time.
RSpec.describe 'MCP 2026-07-28 protocol foundations — round 9' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/rpc' }

  def server_for(klass, config, era: '2025-11-25')
    server = klass.new(base_url: base_url, endpoint: endpoint, retries: 0, faraday_config: config)
    server.instance_variable_set(:@connection_established, true)
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@protocol_version, era)
    server
  end

  def answer(payload)
    stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
      body = JSON.parse(request.body)
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate({ 'jsonrpc' => '2.0', 'id' => body['id'] }.merge(payload)) }
    end
  end

  # The two spellings a host can ask Faraday's JSON middleware for. The
  # client reads the envelope the peer sent, not the spelling the host's
  # middleware happened to produce.
  {
    'a decoding JSON response middleware' => ->(conn) { conn.response :json },
    'a symbolizing JSON response middleware' => lambda { |conn|
      conn.response :json, parser_options: { symbolize_names: true }
    }
  }.each do |middleware_name, config|
    [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
      context "with #{klass} and #{middleware_name}" do
        it 'hands the caller the result the server sent' do
          server = server_for(klass, config)
          answer('result' => { 'content' => [{ 'type' => 'text', 'text' => 'hi' }] })

          result = server.rpc_request('tools/call', { 'name' => 't' })

          expect(MCPClient::JsonRpcCommon.result_type(result)).to eq('complete')
          expect(result.to_a.flatten.map(&:to_s)).to include('content')
        end

        # A 200 carrying a JSON-RPC error is a failed call, never a success:
        # reporting it as one would hand the caller a nil result for a tool
        # the server refused to run.
        it 'raises the error a 200 envelope carries rather than reporting success' do
          server = server_for(klass, config)
          answer('error' => { 'code' => -32_020, 'message' => 'Tool failed' })

          expect { server.rpc_request('tools/call', { 'name' => 't' }) }
            .to raise_error(MCPClient::Errors::ServerError) { |e| expect(e.code).to eq(-32_020) }
        end

        # "A resultType of any value unrecognized by the client MUST be
        # considered invalid" — the discriminator is read off the envelope the
        # middleware produced, so an unknown one is still refused.
        it 'refuses an unrecognized resultType on a modern session' do
          server = server_for(klass, config, era: '2026-07-28')
          answer('result' => { 'resultType' => 'bogus' })

          expect { server.rpc_request('tools/call', { 'name' => 't' }) }
            .to raise_error(MCPClient::Errors::InvalidResultError, /unrecognized resultType/)
        end
      end
    end
  end

  # The SSE branch of Streamable HTTP is untouched by that middleware: an
  # event-stream body is not JSON, so it arrives as the text it was sent as.
  context 'with ServerStreamableHTTP answering an SSE stream under the same middleware' do
    it 'still reads the response out of the stream' do
      server = server_for(MCPClient::ServerStreamableHTTP, ->(conn) { conn.response :json })
      stub_request(:post, "#{base_url}#{endpoint}").to_return do |request|
        id = JSON.parse(request.body)['id']
        { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
          body: "event: message\ndata: #{JSON.generate('jsonrpc' => '2.0', 'id' => id,
                                                       'result' => { 'ok' => true })}\n\n" }
      end

      expect(server.rpc_request('tools/call', { 'name' => 't' })).to eq({ 'ok' => true })
    end
  end
end
