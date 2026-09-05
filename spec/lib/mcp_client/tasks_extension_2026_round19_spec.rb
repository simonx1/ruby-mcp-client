# frozen_string_literal: true

require 'spec_helper'
require 'timeout'

TASKS_EXT = MCPClient::JsonRpcCommon::TASKS_EXTENSION unless defined?(TASKS_EXT)

# MCP 2026-07-28 tasks extension, nineteenth review round: the caller's
# wait budget bounds the capability probe itself (a spent budget sends
# nothing, a short one does not wait for the transport's own timeout), and a
# null task payload is an invalid result, not an empty working task.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 19' do
  let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }

  def client_for(server)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT])
  end

  it 'sends nothing when the wait budget is already spent' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping).and_raise('the probe must not run')
    allow(stdio).to receive(:rpc_request).and_raise('no request must go out')

    expect { client.wait_for_task('task-1', timeout: 0) }
      .to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(stdio).not_to have_received(:ping)
  end

  it 'bounds the capability probe by the wait budget' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping) { Kernel.sleep(2) }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { client.wait_for_task('task-1', timeout: 0.05) }
      .to raise_error(MCPClient::Errors::TaskError, /timed out/i)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
  end

  it 'still probes within the budget when the server answers in time' do
    client = client_for(stdio)
    allow(stdio).to receive(:ping).and_raise(MCPClient::Errors::ConnectionError, 'down')

    expect { client.wait_for_task('task-1', timeout: 5) }
      .to raise_error(MCPClient::Errors::ConnectionError, /down/)
  end

  it 'rejects a null task payload' do
    [nil, false].each do |payload|
      expect { MCPClient::Task.from_json(payload) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /not an object/), payload.inspect
    end
  end

  it 'logs a parse failure for a task notification without params' do
    output = StringIO.new
    client = MCPClient::Client.new(mcp_server_configs: [], logger: Logger.new(output))

    client.send(:handle_task_status_notification, 'srv', nil)

    expect(output.string).to include('Failed to parse task status notification')
    expect(output.string).to match(/not an object/)
    expect(output.string).not_to include('status: working')
  end
end
