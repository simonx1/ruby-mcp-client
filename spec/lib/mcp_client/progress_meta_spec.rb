# frozen_string_literal: true

require 'spec_helper'

# MCP 2025-11-25 basic/utilities/progress + RequestParams._meta:
# "When a party wants to receive progress updates for a request, it includes
# a progressToken in the request metadata" — request-level _meta, not a tool
# argument. "Senders and receivers SHOULD track active progress tokens."
RSpec.describe 'Progress tokens and request _meta (MCP 2025-11-25)' do
  let(:meta) { { 'progressToken' => 'tok-1' } }
  let(:args_with_meta) { { 'x' => 1, '_meta' => meta } }

  describe 'request-level _meta hoisting' do
    it 'stdio call_tool sends _meta at params level, not inside arguments' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      server.instance_variable_set(:@initialized, true)
      captured = nil
      allow(server).to receive(:send_request) { |req| captured = req }
      allow(server).to receive(:next_id).and_return(5)
      allow(server).to receive(:wait_response).and_return({ 'result' => {} })

      server.call_tool('t', args_with_meta)

      expect(captured['params']['_meta']).to eq(meta)
      expect(captured['params']['arguments']).to eq({ 'x' => 1 })
    end

    it 'stdio get_prompt sends _meta at params level' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      server.instance_variable_set(:@initialized, true)
      captured = nil
      allow(server).to receive(:send_request) { |req| captured = req }
      allow(server).to receive(:next_id).and_return(6)
      allow(server).to receive(:wait_response).and_return({ 'result' => { 'messages' => [] } })

      server.get_prompt('p', args_with_meta)

      expect(captured['params']['_meta']).to eq(meta)
      expect(captured['params']['arguments']).to eq({ 'x' => 1 })
    end

    it 'SSE call_tool sends _meta at params level' do
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
      captured = nil
      allow(server).to receive(:rpc_request) { |_m, params| captured = params and {} }

      server.call_tool('t', args_with_meta)

      expect(captured['_meta'] || captured[:_meta]).to eq(meta)
      arguments = captured['arguments'] || captured[:arguments]
      expect(arguments).to eq({ 'x' => 1 })
    end

    it 'plain HTTP call_tool sends _meta at params level' do
      server = MCPClient::ServerHTTP.new(base_url: 'https://example.com')
      captured = nil
      allow(server).to receive(:rpc_request) { |_m, params| captured = params and {} }

      server.call_tool('t', args_with_meta)

      expect(captured['_meta'] || captured[:_meta]).to eq(meta)
      expect(captured['arguments'] || captured[:arguments]).to eq({ 'x' => 1 })
    end

    it 'Streamable HTTP call_tool honors the string _meta key too' do
      server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com')
      captured = nil
      allow(server).to receive(:rpc_request) { |_m, params| captured = params and {} }

      server.call_tool('t', args_with_meta)

      expect(captured['_meta'] || captured[:_meta]).to eq(meta)
      expect(captured['arguments'] || captured[:arguments]).to eq({ 'x' => 1 })
    end
  end

  describe 'Client#call_tool progress callback' do
    let(:tool_json) do
      { 'name' => 'slow', 'description' => 'd', 'inputSchema' => { 'type' => 'object', 'properties' => {} } }
    end
    let(:srv) { double('server', name: 's') }
    let(:client) do
      c = MCPClient::Client.new
      c.instance_variable_set(:@servers, [srv])
      c
    end

    before do
      tool = MCPClient::Tool.from_json(tool_json, server: srv)
      allow(srv).to receive(:list_tools).and_return([tool])
      allow(srv).to receive(:capabilities).and_return({})
      allow(srv).to receive(:on_notification)
    end

    it 'auto-generates a progressToken, routes matching notifications, and drops stale ones' do
      sent_params = nil
      allow(srv).to receive(:call_tool) do |_name, params|
        sent_params = params
        { 'content' => [] }
      end

      updates = []
      client.call_tool('slow', { 'a' => 1 }, progress: lambda { |progress, total, message|
        updates << [progress, total, message]
      })

      token = sent_params.dig('_meta', 'progressToken')
      expect(token).not_to be_nil
      expect(sent_params['a']).to eq(1)

      # During the request the token is active; simulate a progress notification
      # arriving mid-flight by re-registering, then completing.
      client.send(:register_progress_callback, token, ->(p, t, m) { updates << [p, t, m] })
      client.send(:process_notification, srv, 'notifications/progress',
                  { 'progressToken' => token, 'progress' => 50, 'total' => 100, 'message' => 'half' })
      expect(updates).to include([50, 100, 'half'])

      client.send(:unregister_progress_callback, token)
      client.send(:process_notification, srv, 'notifications/progress',
                  { 'progressToken' => token, 'progress' => 100, 'total' => 100, 'message' => 'done' })
      expect(updates).not_to include([100, 100, 'done'])
    end

    it 'invokes the progress callback while the request is in flight' do
      updates = []
      allow(srv).to receive(:call_tool) do |_name, params|
        token = params.dig('_meta', 'progressToken')
        client.send(:process_notification, srv, 'notifications/progress',
                    { 'progressToken' => token, 'progress' => 10, 'total' => 100 })
        { 'content' => [] }
      end

      client.call_tool('slow', {}, progress: ->(p, t, _m) { updates << [p, t] })

      expect(updates).to eq([[10, 100]])
    end

    it 'ignores progress for unknown tokens without raising' do
      expect do
        client.send(:process_notification, srv, 'notifications/progress',
                    { 'progressToken' => 'stale', 'progress' => 1 })
      end.not_to raise_error
    end
  end
end
