# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'timeout'

# MCP 2026-07-28 tasks extension, ninth review round: a rejected update
# gives its keys back, a poll that ran past the deadline ends the wait, the
# caller deadline and the TTL stay separate (a later, longer TTL extends
# the wait; the seed TTL bounds polls that time out), a handler failure
# never releases keys another caller submitted, streamed task results are
# validated, and the client file loads on its own.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 9' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  def task_result(id: 'task-1', ttl_ms: 60_000)
    now = Time.now.utc.iso8601
    { 'resultType' => 'task', 'taskId' => id, 'status' => 'working', 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => ttl_ms, 'pollIntervalMs' => 1 }
  end

  def detailed_task(status:, id: 'task-1', ttl_ms: 60_000, poll_ms: 1, **extra)
    # Millisecond precision: short TTLs in these examples start now, not at
    # the last whole second.
    now = Time.now.utc.iso8601(3)
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now,
      'ttlMs' => ttl_ms, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def tool_list(output_schema: nil)
    tool = { 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }
    tool['outputSchema'] = output_schema if output_schema
    { 'result' => { 'tools' => [tool], 'ttlMs' => 60_000 } }
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def elicit_request
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => 'Name?',
                    'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } } } }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      # A single trailing responder answers every remaining request.
      responder = responses.first.respond_to?(:call) && responses.size == 1 ? responses.first : responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  it 'presents an input request again after the server rejected its update' do
    handled = 0
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      handled += 1
      { action: 'accept', content: { 'n' => 'x' } }
    })
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                { 'error' => { 'code' => -32_602, 'message' => 'inputResponses: bad content' } },
                                { 'result' => detailed_task(status: 'input_required',
                                                            'inputRequests' => { 'k1' => elicit_request }) },
                                { 'result' => {} },
                                { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::TaskError, /bad content/)
    expect(client.wait_for_task(task)).to be_completed
    expect(handled).to eq(2)
    expect(sent.count { |r| r['method'] == 'tasks/update' }).to eq(2)
  end

  it 'ends the wait when a poll came back after the deadline' do
    client = client_for(stdio)
    sent = script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                                lambda { |_req|
                                  Kernel.sleep 0.1
                                  { 'result' => detailed_task(status: 'working') }
                                }])
    task = client.call_tool_as_task('slow', {})

    expect { client.wait_for_task(task, timeout: 0.05) }.to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(sent.count { |r| r['method'] == 'tasks/get' }).to eq(1)
    expect(client).not_to have_received(:sleep)
  end

  it 'lets a later, longer ttlMs extend a wait that has no caller timeout' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         ->(_req) { { 'result' => detailed_task(status: 'working', ttl_ms: 200) } },
                         lambda { |_req|
                           Kernel.sleep 0.25
                           { 'result' => detailed_task(status: 'working', ttl_ms: 3_600_000) }
                         },
                         { 'result' => detailed_task(status: 'completed', 'result' => call_result) }])

    expect(client.call_tool('slow', {})['isError']).to be(false)
  end

  it 'bounds a wait whose polls all time out by the TTL of the created task' do
    client = client_for(stdio)
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result(ttl_ms: 300) },
                         ->(_req) { raise MCPClient::Errors::RequestTimeoutError, 'stalled' }])
    allow(stdio).to receive(:rpc_request).and_call_original
    task = client.call_tool_as_task('slow', {})

    Timeout.timeout(5) do
      expect { client.wait_for_task(task) }.to raise_error(MCPClient::Errors::TaskError, /TTL/)
    end
  end

  it 'keeps a key submitted through update_task when a handler fails afterwards' do
    started = Queue.new
    release = Queue.new
    client = client_for(stdio, elicitation_handler: lambda { |_m, _s|
      started << true
      release.pop
      raise 'handler broke'
    })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list, { 'result' => task_result },
                         { 'result' => detailed_task(status: 'input_required',
                                                     'inputRequests' => { 'k1' => elicit_request }) },
                         { 'result' => {} }])
    task = client.call_tool_as_task('slow', {})
    detailed = client.get_task(task)

    waiter = Thread.new do
      client.send(:answer_task_input_requests, detailed, client.send(:answered_task_keys, stdio, 'task-1'), stdio)
    end
    started.pop
    client.update_task(task, { 'k1' => { 'action' => 'decline' } })
    release << true
    expect { waiter.join }.to raise_error(MCPClient::Errors::InputRequiredError, /handler/)

    expect(client.send(:answered_task_keys, stdio, 'task-1')).to include('k1')
  end

  it 'validates the structured content of a task resolved on the streaming path' do
    client = client_for(stdio, validate_structured_content: :strict)
    schema = { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer' } }, 'required' => ['n'] }
    result = call_result.merge('structuredContent' => { 'n' => 'x' })
    script_stdio(stdio, [{ 'result' => discover_result }, tool_list(output_schema: schema), { 'result' => task_result },
                         { 'result' => detailed_task(status: 'completed', 'result' => result) }])

    expect { client.call_tool_streaming('slow', {}).to_a }.to raise_error(MCPClient::Errors::ValidationError)
  end

  it 'sanitizes the legacy tasks/result transport error' do
    client = client_for(stdio)
    allow(stdio).to receive(:capabilities).and_return({ 'tasks' => { 'result' => {} } })
    allow(stdio).to receive(:modern?).and_return(false)
    allow(stdio).to receive(:ping)
    allow(stdio).to receive(:rpc_request).with('tasks/result', anything)
                                         .and_raise(MCPClient::Errors::TransportError, "boom\nWARN forged")

    expect { client.get_task_result("t\nWARN forged") }.to raise_error(MCPClient::Errors::TaskError) { |e|
      expect(e.message).not_to include("\nWARN forged")
    }
  end

  it 'forwards the extensions option through MCPClient.connect' do
    allow(stdio).to receive(:connect).and_return(true)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)

    client = MCPClient.connect(%w[echo test], extensions: [TASKS_EXT])

    expect(client).to be_tasks_extension
  end

  it 'loads the client file on its own' do
    lib = File.expand_path('../../../lib', __dir__)
    _out, err, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-e', "require 'mcp_client/client'")

    expect(status).to be_success, err
  end
end
