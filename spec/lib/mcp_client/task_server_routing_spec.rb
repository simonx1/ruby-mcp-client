# frozen_string_literal: true

require 'spec_helper'

# Task IDs are only unique within the server that issued them, so a task
# operation that silently defaults to "the first configured server" can hit
# the wrong server in a multi-server client — polling an unrelated task,
# reading another server's result, or cancelling work that was never targeted.
RSpec.describe 'Task operations server routing' do
  let(:server_a) { instance_double(MCPClient::ServerStdio, name: 'alpha') }
  let(:server_b) { instance_double(MCPClient::ServerStdio, name: 'beta') }
  let(:task_caps) { { 'tasks' => { 'requests' => { 'tools' => { 'call' => {} } }, 'list' => {}, 'cancel' => {} } } }

  let(:multi_client) do
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server_a, server_b)
    MCPClient::Client.new(
      mcp_server_configs: [
        { type: 'stdio', command: 'a' },
        { type: 'stdio', command: 'b' }
      ]
    )
  end

  let(:single_client) do
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server_a)
    MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' }])
  end

  before do
    [server_a, server_b].each do |srv|
      allow(srv).to receive(:capabilities).and_return(task_caps)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:capability?).and_return(true)
    end
  end

  describe 'routing by Task handle' do
    it 'sends tasks/get to the server the task came from, not the first server' do
      handle = MCPClient::Task.new(task_id: 'task-1', server: server_b)
      expect(server_b).to receive(:rpc_request)
        .with('tasks/get', { taskId: 'task-1' })
        .and_return({ 'taskId' => 'task-1', 'status' => 'working' })
      expect(server_a).not_to receive(:rpc_request)

      expect(multi_client.get_task(handle).task_id).to eq('task-1')
    end

    it 'sends tasks/result to the task own server' do
      handle = MCPClient::Task.new(task_id: 'task-2', server: server_b)
      expect(server_b).to receive(:rpc_request).with('tasks/result', { taskId: 'task-2' }).and_return({ 'ok' => true })
      expect(server_a).not_to receive(:rpc_request)

      expect(multi_client.get_task_result(handle)).to eq({ 'ok' => true })
    end

    it 'sends tasks/cancel to the task own server' do
      handle = MCPClient::Task.new(task_id: 'task-3', server: server_b)
      expect(server_b).to receive(:rpc_request)
        .with('tasks/cancel', { taskId: 'task-3' })
        .and_return({ 'taskId' => 'task-3', 'status' => 'cancelled' })
      expect(server_a).not_to receive(:rpc_request)

      expect(multi_client.cancel_task(handle).status).to eq('cancelled')
    end

    it 'honors an explicit server: over the handle own server' do
      handle = MCPClient::Task.new(task_id: 'task-4', server: server_b)
      expect(server_a).to receive(:rpc_request)
        .with('tasks/get', { taskId: 'task-4' })
        .and_return({ 'taskId' => 'task-4', 'status' => 'working' })

      multi_client.get_task(handle, server: server_a)
    end
  end

  describe 'ambiguous routing in a multi-server client' do
    it 'refuses a bare task id for tasks/get instead of guessing a server' do
      expect(server_a).not_to receive(:rpc_request)
      expect(server_b).not_to receive(:rpc_request)

      expect { multi_client.get_task('task-1') }
        .to raise_error(ArgumentError, /multiple servers/i)
    end

    it 'refuses a bare task id for tasks/result' do
      expect { multi_client.get_task_result('task-1') }
        .to raise_error(ArgumentError, /multiple servers/i)
    end

    it 'refuses a bare task id for tasks/cancel' do
      expect { multi_client.cancel_task('task-1') }
        .to raise_error(ArgumentError, /multiple servers/i)
    end

    it 'accepts a bare task id when the server is named explicitly' do
      expect(server_b).to receive(:rpc_request)
        .with('tasks/get', { taskId: 'task-1' })
        .and_return({ 'taskId' => 'task-1', 'status' => 'working' })

      multi_client.get_task('task-1', server: 'beta')
    end
  end

  describe 'single-server clients are unaffected' do
    it 'still accepts a bare task id' do
      expect(server_a).to receive(:rpc_request)
        .with('tasks/get', { taskId: 'task-1' })
        .and_return({ 'taskId' => 'task-1', 'status' => 'working' })

      expect(single_client.get_task('task-1').task_id).to eq('task-1')
    end
  end
end
