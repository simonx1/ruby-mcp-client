# frozen_string_literal: true

require 'spec_helper'

# Dropping a field the revision removed is a protocol decision; saying so in
# the log is a courtesy. A logger that raises must cost the notice, never the
# elicitation — the same isolation MCPClient::Deprecations.warn already has.
RSpec.describe 'MCP 2026-07-28 URL-mode elicitation — a failing logger' do
  let(:raising_logger) do
    Class.new do
      attr_accessor :progname, :formatter

      def level = Logger::WARN
      def warn(*) = raise(IOError, 'log device is gone')
      def debug(*) = nil
      def info(*) = nil
      def error(*) = nil
    end.new
  end

  let(:handler) { ->(message, metadata) { @seen = [message, metadata] and { 'action' => 'accept' } } }
  let(:client) do
    MCPClient::Client.new(mcp_server_configs: [], logger: raising_logger, elicitation_handler: handler)
  end
  let(:modern_server) do
    instance_double(MCPClient::ServerStdio).tap do |srv|
      allow(srv).to receive(:respond_to?).with(:modern?).and_return(true)
      allow(srv).to receive(:modern?).and_return(true)
    end
  end
  let(:params) do
    { 'mode' => 'url', 'message' => 'Sign in', 'url' => 'https://auth.example/start',
      'elicitationId' => 'corr-1' }
  end

  it 'still serves the elicitation when the notice cannot be written' do
    expect { client.send(:handle_elicitation_request, 1, params, modern_server) }.not_to raise_error
    expect(@seen.first).to eq('Sign in')
    expect(@seen.last).to eq({ 'mode' => 'url', 'url' => 'https://auth.example/start' })
  end

  it 'drops the removed field whether or not the notice was written' do
    metadata = client.send(:url_elicitation_metadata, params, modern_server)

    expect(metadata).not_to have_key('elicitationId')
  end
end
