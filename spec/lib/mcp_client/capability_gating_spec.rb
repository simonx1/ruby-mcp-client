# frozen_string_literal: true

require 'spec_helper'

# MCP 2025-11-25 lifecycle (Operation phase): "Both parties MUST ...
# Only use capabilities that were successfully negotiated."
# Optional server features (logging/setLevel, resources/subscribe|unsubscribe,
# completion/complete, tasks/list, tasks/cancel) must therefore be gated on
# the server's negotiated capabilities instead of sent unconditionally.
RSpec.describe 'Capability gating (MCP 2025-11-25)' do
  describe 'ServerBase#capability?' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

    it 'navigates nested negotiated capabilities' do
      server.instance_variable_set(:@capabilities,
                                   { 'resources' => { 'subscribe' => true },
                                     'logging' => {},
                                     'tasks' => { 'list' => {} } })

      expect(server.capability?('logging')).to be true
      expect(server.capability?('resources', 'subscribe')).to be true
      expect(server.capability?('tasks', 'list')).to be true
      expect(server.capability?('tasks', 'cancel')).to be false
      expect(server.capability?('completions')).to be false
    end

    it 'is false when no capabilities were negotiated' do
      expect(server.capability?('logging')).to be false
    end
  end

  describe 'transport-level gating' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

    before do
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@capabilities, { 'tools' => {} })
    end

    it 'refuses resources/subscribe without the resources.subscribe capability' do
      expect(server).not_to receive(:send_request)
      expect { server.subscribe_resource('file:///x') }.to raise_error(
        MCPClient::Errors::CapabilityError, /resources\.subscribe/
      )
    end

    it 'refuses resources/unsubscribe without the resources.subscribe capability' do
      expect(server).not_to receive(:send_request)
      expect { server.unsubscribe_resource('file:///x') }.to raise_error(
        MCPClient::Errors::CapabilityError, /resources\.subscribe/
      )
    end

    it 'refuses completion/complete without the completions capability' do
      expect(server).not_to receive(:send_request)
      expect { server.complete(ref: { 'type' => 'ref/prompt' }, argument: {}) }.to raise_error(
        MCPClient::Errors::CapabilityError, /completions/
      )
    end

    it 'refuses logging/setLevel without the logging capability' do
      expect(server).not_to receive(:send_request)
      expect { server.log_level = 'debug' }.to raise_error(
        MCPClient::Errors::CapabilityError, /logging/
      )
    end

    it 'sends resources/subscribe when the capability was negotiated' do
      server.instance_variable_set(:@capabilities, { 'resources' => { 'subscribe' => true } })
      allow(server).to receive(:send_request)
      allow(server).to receive(:next_id).and_return(7)
      allow(server).to receive(:wait_response).and_return({ 'result' => {} })

      expect(server.subscribe_resource('file:///x')).to be true
      expect(server).to have_received(:send_request)
    end
  end

  describe 'Client#log_level=' do
    it 'skips servers that did not negotiate the logging capability' do
      with_logging = double('srv-a', capability?: true)
      without_logging = double('srv-b')
      allow(without_logging).to receive(:capability?).with('logging').and_return(false)
      allow(with_logging).to receive(:log_level=)
      allow(without_logging).to receive(:log_level=)
      allow(without_logging).to receive(:name).and_return('b')

      client = MCPClient::Client.new
      client.instance_variable_set(:@servers, [with_logging, without_logging])

      client.log_level = 'debug'

      expect(with_logging).to have_received(:log_level=).with('debug')
      expect(without_logging).not_to have_received(:log_level=)
    end
  end

  describe 'Client task operations' do
    let(:srv) do
      double('server', name: 'srv-1')
    end
    let(:client) do
      c = MCPClient::Client.new
      c.instance_variable_set(:@servers, [srv])
      c
    end

    it 'refuses tasks/list when the server did not declare tasks.list' do
      allow(srv).to receive(:capability?).with('tasks', 'list').and_return(false)
      expect(srv).not_to receive(:rpc_request)

      expect { client.list_tasks }.to raise_error(MCPClient::Errors::CapabilityError, /tasks\.list/)
    end

    it 'refuses tasks/cancel when the server did not declare tasks.cancel' do
      allow(srv).to receive(:capability?).with('tasks', 'cancel').and_return(false)
      expect(srv).not_to receive(:rpc_request)

      expect { client.cancel_task('t-1') }.to raise_error(MCPClient::Errors::CapabilityError, /tasks\.cancel/)
    end

    it 'lists tasks when the capability was negotiated' do
      allow(srv).to receive(:capability?).with('tasks', 'list').and_return(true)
      allow(srv).to receive(:rpc_request).with('tasks/list', {}).and_return({ 'tasks' => [] })

      expect(client.list_tasks[:tasks]).to eq([])
    end
  end
end
