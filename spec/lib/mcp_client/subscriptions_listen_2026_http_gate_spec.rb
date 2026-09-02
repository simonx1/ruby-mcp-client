# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 replaced resources/subscribe and resources/unsubscribe with a
# subscriptions/listen stream carrying resourceSubscriptions. Every transport
# gates the mapping on its own era; the stdio side is pinned by
# subscriptions_listen_2026_spec.rb, and these are the two HTTP transports,
# whose gate the shared SubscriptionSupport code cannot decide for them.
RSpec.describe 'MCP 2026-07-28 resource subscriptions on the HTTP transports' do
  let(:url) { 'https://example.com/mcp' }
  let(:sub_id_meta) { 'io.modelcontextprotocol/subscriptionId' }

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'resources' => { 'subscribe' => true, 'listChanged' => true } } }
  end

  def initialize_result
    { 'protocolVersion' => '2025-11-25', 'serverInfo' => { 'name' => 's', 'version' => '1' },
      'capabilities' => { 'resources' => { 'subscribe' => true, 'listChanged' => true } } }
  end

  # A modern server: server/discover answers the probe, subscriptions/listen
  # is acknowledged on an SSE stream and then held open.
  def stub_modern(sent)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      sent << body
      case body['method']
      when 'server/discover'
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result) }
      when 'subscriptions/listen'
        ack = { 'jsonrpc' => '2.0', 'method' => 'notifications/subscriptions/acknowledged',
                'params' => { '_meta' => { sub_id_meta => body['id'] },
                              'notifications' => body['params']['notifications'] } }
        { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
          body: "event: message\ndata: #{JSON.generate(ack)}\n\n" }
      else
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                              'result' => { 'resultType' => 'complete' }) }
      end
    end
  end

  # A 2025-11-25 server: the legacy handshake, then plain JSON answers.
  def stub_legacy(sent)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      sent << body
      result = body['method'] == 'initialize' ? initialize_result : {}
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result) }
    end
  end

  # The listen stream runs on its own thread, so the POST that opens it is
  # asynchronous: wait for it to be recorded rather than for a fixed margin.
  def wait_for_listen(sent, timeout = 2)
    deadline = Time.now + timeout
    sleep 0.005 until sent.any? { |m| m['method'] == 'subscriptions/listen' } || Time.now > deadline
    sent.find { |m| m['method'] == 'subscriptions/listen' }
  end

  shared_examples 'a transport that maps resource subscriptions onto listen' do
    it 'opens a listen stream for the URI instead of sending resources/subscribe' do
      sent = []
      stub_modern(sent)

      expect(modern_server.subscribe_resource('file:///a')).to be(true)

      listen = wait_for_listen(sent)
      expect(listen['params']['notifications']).to eq({ 'resourceSubscriptions' => ['file:///a'] })
      expect(sent.map { |m| m['method'] }).not_to include('resources/subscribe')
      # The era, not the configuration: this transport is in :auto mode and
      # took the modern branch because the server negotiated 2026-07-28.
      expect(modern_server.protocol_mode).to eq(:auto)
      expect(modern_server).to be_modern
    end

    it 'closes that stream instead of sending resources/unsubscribe' do
      sent = []
      stub_modern(sent)
      modern_server.subscribe_resource('file:///a')
      wait_for_listen(sent)
      subscription = modern_server.resource_subscriptions['file:///a']

      expect(modern_server.unsubscribe_resource('file:///a')).to be(true)

      expect(sent.map { |m| m['method'] }).not_to include('resources/unsubscribe')
      expect(modern_server.resource_subscriptions).to be_empty
      # Dropping the registry entry is not enough: the stream itself has to
      # be closed, which is what cancels the subscription server-side.
      expect(subscription).to be_closed_by_client
      expect(modern_server.send(:listen_threads)).to be_empty
      sleep 0.2
      expect(sent.count { |m| m['method'] == 'subscriptions/listen' }).to eq(1)
    end

    it 'still sends resources/subscribe and resources/unsubscribe to a 2025-11-25 server' do
      sent = []
      stub_legacy(sent)

      legacy_server.subscribe_resource('file:///a')
      legacy_server.unsubscribe_resource('file:///a')

      expect(sent.map { |m| m['method'] }).to include('resources/subscribe', 'resources/unsubscribe')
      expect(sent.map { |m| m['method'] }).not_to include('subscriptions/listen')
    end

    it 'keeps resources/subscribe on an auto-mode transport negotiated down to 2025-11-25' do
      sent = []
      stub_legacy(sent)

      expect(negotiated_legacy_server.subscribe_resource('file:///a')).to be(true)
      negotiated_legacy_server.unsubscribe_resource('file:///a')

      # Nothing about this transport is configured legacy: it probed, the
      # server answered as a 2025-11-25 one, and the era decided the mapping.
      expect(negotiated_legacy_server.protocol_mode).to eq(:auto)
      expect(negotiated_legacy_server.protocol_version).to eq('2025-11-25')
      expect(negotiated_legacy_server).not_to be_modern
      expect(sent.map { |m| m['method'] }).to include('resources/subscribe', 'resources/unsubscribe')
      expect(sent.map { |m| m['method'] }).not_to include('subscriptions/listen')
    end
  end

  describe MCPClient::ServerHTTP do
    let(:modern_server) { described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }
    let(:legacy_server) do
      described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, protocol: :legacy)
    end
    # Same configuration as the modern one: only the server's answer differs.
    let(:negotiated_legacy_server) do
      described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    after do
      modern_server.cleanup
      legacy_server.cleanup
      negotiated_legacy_server.cleanup
    end

    it_behaves_like 'a transport that maps resource subscriptions onto listen'
  end

  describe MCPClient::ServerStreamableHTTP do
    let(:modern_server) do
      described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, read_timeout: 2)
    end
    let(:legacy_server) do
      described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, read_timeout: 2,
                          protocol: :legacy)
    end
    # Same configuration as the modern one: only the server's answer differs.
    let(:negotiated_legacy_server) do
      described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, read_timeout: 2)
    end

    after do
      modern_server.cleanup
      legacy_server.cleanup
      negotiated_legacy_server.cleanup
    end

    it_behaves_like 'a transport that maps resource subscriptions onto listen'
  end
end
