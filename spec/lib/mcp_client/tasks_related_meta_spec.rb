# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2025-11-25 tasks (basic/utilities/tasks, experimental):
# - "All requests, notifications, and responses related to a task MUST
#   include the io.modelcontextprotocol/related-task key in their _meta
#   field" — the client's responses to task-related server requests
#   (elicitation/sampling during input_required) must echo it.
# - Tool-Level Negotiation rule 1: "If a server's capabilities do not include
#   tasks.requests.tools.call, then clients MUST NOT attempt to use task
#   augmentation on that server's tools, regardless of the
#   execution.taskSupport value" — i.e. taskSupport='required' is only
#   enforced when the capability precondition holds; otherwise the tool is
#   called normally.
RSpec.describe 'Task-related _meta echo and taskSupport gating (MCP 2025-11-25)' do
  let(:related) { { 'taskId' => 'task-123' } }
  let(:meta_params) do
    {
      'message' => 'Need input',
      '_meta' => { 'io.modelcontextprotocol/related-task' => related }
    }
  end

  describe 'stdio transport' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

    it 'echoes related-task _meta on elicitation responses' do
      server.on_elicitation_request { |_id, _params| { 'action' => 'decline' } }
      captured = nil
      allow(server).to receive(:send_message) { |msg| captured = msg }

      server.handle_elicitation_create(7, meta_params)

      expect(captured['result']['_meta']).to eq('io.modelcontextprotocol/related-task' => related)
    end

    it 'echoes related-task _meta on sampling responses' do
      server.on_sampling_request { |_id, _params| { 'role' => 'assistant' } }
      captured = nil
      allow(server).to receive(:send_message) { |msg| captured = msg }

      server.handle_sampling_create_message(8, meta_params)

      expect(captured['result']['_meta']).to eq('io.modelcontextprotocol/related-task' => related)
    end
  end

  describe 'SSE transport' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse') }

    it 'echoes related-task _meta on elicitation responses' do
      server.on_elicitation_request { |_id, _params| { 'action' => 'accept', 'content' => {} } }
      captured = nil
      allow(server).to receive(:send_elicitation_response) { |_id, result| captured = result }

      server.handle_elicitation_create(9, meta_params)

      expect(captured['_meta']).to eq('io.modelcontextprotocol/related-task' => related)
    end
  end

  describe 'Streamable HTTP transport' do
    let(:base_url) { 'https://example.com' }
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: '/rpc') }

    after { server.cleanup }

    it 'echoes related-task _meta on the POSTed elicitation response' do
      server.send(:on_elicitation_request) { |_id, _params| { 'action' => 'decline' } }

      response_stub = stub_request(:post, "#{base_url}/rpc")
                      .with(body: hash_including(
                        'id' => 11,
                        'result' => {
                          'action' => 'decline',
                          '_meta' => { 'io.modelcontextprotocol/related-task' => related }
                        }
                      ))
                      .to_return(status: 200, body: '')

      request = { 'jsonrpc' => '2.0', 'id' => 11, 'method' => 'elicitation/create', 'params' => meta_params }
      server.send(:handle_server_message, JSON.generate(request))

      deadline = Time.now + 2
      sleep 0.05 until response_stub.to_s.include?('was requested') || Time.now > deadline
      expect(response_stub).to have_been_requested.once
    end
  end

  describe 'handler-returned _meta preservation' do
    it 'keeps _meta from a symbol-keyed elicitation handler result' do
      handler = ->(_m, _p) { { action: :decline, _meta: { 'x' => 1 } } }
      client = MCPClient::Client.new(elicitation_handler: handler)

      result = client.send(:handle_elicitation_request, 1, { 'message' => 'hi' })

      expect(result).to eq({ 'action' => 'decline', '_meta' => { 'x' => 1 } })
    end
  end

  describe 'taskSupport=required without the server tasks capability' do
    it 'invokes the tool as a plain call (rule 1 disregards taskSupport)' do
      mock_server = double('server', name: 'srv')
      required_tool = MCPClient::Tool.from_json(
        { 'name' => 'must_task', 'description' => 'd', 'inputSchema' => {},
          'execution' => { 'taskSupport' => 'required' } }, server: mock_server
      )
      allow(mock_server).to receive(:list_tools).and_return([required_tool])
      allow(mock_server).to receive(:capabilities).and_return({}) # no tasks capability
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })

      client = MCPClient::Client.new
      client.instance_variable_set(:@servers, [mock_server])

      expect(client.call_tool('must_task', {})).to eq({ 'content' => [] })
      expect(mock_server).to have_received(:call_tool).with('must_task', {})
    end
  end
end
