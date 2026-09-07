# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 deprecations, fifteenth review round: the diagnostics a
# deprecated operation writes never change the answer the peer gets — a
# logger that fails on the way to a sampling refusal still leaves -32602 on
# the wire — and the transport-direct sampling paths are pinned end to end
# (no handler → -32601, declared tools → served), while the one write failure
# a standard Logger hides from its caller is named as the boundary of the
# notice's retry guarantee.
RSpec.describe 'MCP 2026-07-28 deprecations (round 15)' do
  let(:output) { StringIO.new }
  let(:logger) { Logger.new(output) }

  around do |example|
    MCPClient::Deprecations.enabled = true
    MCPClient::Deprecations.reset!
    example.run
  ensure
    MCPClient::Deprecations.reset!
    MCPClient::Deprecations.enabled = false
  end

  # A host logger whose WARN level is broken (its device raises on that
  # path) while every other level still writes.
  def warn_raising_logger
    Class.new(Logger) do
      def warn(*)
        raise IOError, 'warn device gone'
      end
    end.new(output)
  end

  let(:answer) { { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'x' }, 'model' => 'm' } }
  let(:tool_request) do
    { 'messages' => [], 'maxTokens' => 5, 'tools' => [{ 'name' => 'lookup', 'inputSchema' => {} }],
      'toolChoice' => { 'mode' => 'auto' } }
  end

  describe 'a sampling request served by a stdio transport driven directly' do
    let(:sent) { [] }

    def stdio(log)
      server = MCPClient::ServerStdio.new(command: 'true', logger: log)
      allow(server).to receive(:send_message) { |message| sent << message }
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server
    end

    def serve(server, id, params)
      server.send(:handle_server_request, { 'id' => id, 'method' => 'sampling/createMessage', 'params' => params })
    end

    # A capability this host never registered for is an unsupported method,
    # not a rejected request: -32601, the envelope complete, and no notice
    # for a feature the host does not use.
    it 'answers a host with no sampling handler with -32601 and spends no notice' do
      serve(stdio(logger), 2, { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'thisServer' })

      expect(sent).to eq([{ 'jsonrpc' => '2.0', 'id' => 2,
                            'error' => { 'code' => -32_601, 'message' => 'Sampling not supported' } }])
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(false)
      expect(MCPClient::Deprecations.emitted?(:include_context)).to be(false)
      expect(output.string).not_to match(/deprecated/)
    end

    # SEP-1577's refusal is the transport's answer to the peer; the line it
    # logs about it is a courtesy to the host. A logger that fails on that
    # line must not turn Invalid params into Internal error.
    it 'still refuses undeclared tool use with -32602 when the logger fails on the warning' do
      server = stdio(warn_raising_logger)
      served = []
      server.on_sampling_request do |_id, params|
        served << params
        answer
      end

      serve(server, 3, tool_request)

      expect(served).to be_empty
      expect(sent.size).to eq(1)
      expect(sent.first['error']).to include('code' => -32_602)
      expect(sent.first['error']['message']).to match(/sampling\.tools/)
    end

    it 'serves a tool-enabled request, parameters intact, once the host declared sampling.tools' do
      server = stdio(logger)
      server.declare_sampling_tools
      served = []
      server.on_sampling_request do |_id, params|
        served << params
        answer
      end

      serve(server, 4, tool_request)

      expect(served).to eq([tool_request])
      expect(sent).to eq([{ 'jsonrpc' => '2.0', 'id' => 4, 'result' => answer }])
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
    end
  end

  describe 'a sampling request routed by an HTTP transport whose logger fails on the warning' do
    let(:posted) { [] }

    {
      'the HTTP+SSE transport' => lambda { |logger|
        MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger)
      },
      'the Streamable HTTP transport' => lambda { |logger|
        MCPClient::ServerStreamableHTTP.new(base_url: 'http://localhost:1/mcp', logger: logger)
      }
    }.each do |label, build|
      it "still refuses undeclared tool use with -32602 on #{label}" do
        server = build.call(warn_raising_logger)
        allow(server).to receive(:ensure_initialized) if server.respond_to?(:ensure_initialized, true)
        allow(server).to receive(:post_jsonrpc_response) { |response| posted << response }
        served = []
        server.on_sampling_request do |_id, params|
          served << params
          answer
        end

        server.send(:handle_server_request,
                    { 'id' => 5, 'method' => 'sampling/createMessage', 'params' => tool_request })

        expect(served).to be_empty
        expect(posted.size).to eq(1)
        expect(posted.first['error']).to include('code' => -32_602)
        expect(posted.first['error']['message']).to match(/sampling\.tools/)
      end
    end
  end

  # ::Logger's device catches its own write failure and reports it on
  # $stderr only ("log writing failed."), so `logger.warn` returns as if it
  # had written. A device that is closed is recognised and the notice kept
  # owed; a device that is open and fails to write is beyond reach — the
  # boundary of the retry guarantee, pinned here so it is not mistaken for a
  # promise.
  describe 'a standard logger whose open device fails to write' do
    let(:failing_device) do
      Class.new(StringIO) do
        def write(*)
          raise IOError, 'disk gone'
        end
      end.new
    end
    let(:failing_logger) { Logger.new(failing_device) }

    it 'spends the notice, reporting the failure only where ::Logger does' do
      stderr = StringIO.new
      original = $stderr
      $stderr = stderr
      begin
        expect(MCPClient::Deprecations.warn(:roots, failing_logger)).to be(true)
      ensure
        $stderr = original
      end

      expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
      expect(stderr.string).to include('log writing failed')
      expect(MCPClient::Deprecations.warn(:roots, logger)).to be(false)
      expect(output.string).to be_empty
    end
  end
end
