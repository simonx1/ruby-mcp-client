# frozen_string_literal: true

require 'spec_helper'

# Review round 6 (codex, grok), on the code round 5 left: a notification queue
# bounded by count but not by memory, so a blocked listener let a peer retain
# a thousand payloads of whatever size it liked; a listener that could observe
# the caches its notification was about to invalidate; a re-opened resource
# subscription whose fresh acknowledgment was never rechecked against the URIs
# it was mapped to; and a stdio crash-loop bound measured from the moment a
# restart was attempted rather than from the moment the process became ready.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 6' do
  def sub_meta
    'io.modelcontextprotocol/subscriptionId'
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'resources' => { 'subscribe' => true, 'listChanged' => true } } }
  end

  def wait_until(timeout = 3)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise 'condition not met in time' unless yield
  end

  # codex [P1] notification_dispatcher.rb:71: MAX_PENDING_NOTIFICATIONS bounds
  # the queue by count, and a count is not a memory bound — an HTTP listen
  # event may approach 32 MiB and a stdio line has no inbound limit at all, so
  # a thousand of them is tens of gigabytes retained on behalf of a listener
  # that is not draining.
  describe 'the memory the pending notifications retain' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def updated(uri, payload)
      ['notifications/resources/updated',
       { 'uri' => uri, 'blob' => payload, '_meta' => { sub_meta => 1 } }]
    end

    def uri_of
      ->(params) { params['uri'] }
    end

    # A subscription whose dispatcher is parked inside the first delivery, so
    # everything queued behind it is subject to the overflow policy.
    def blocked_subscription(delivered)
      entered = Thread::Queue.new
      release = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |_method, params|
        delivered << uri_of.call(params)
        next unless uri_of.call(params) == 'file:///blocker'

        entered << :in
        release.pop
      end
      subscription.assign_id(1)
      subscription.deliver(*updated('file:///blocker', 'x'))
      entered.pop(timeout: 3)
      [subscription, release]
    end

    it 'stops queueing at the byte ceiling, long before the count ceiling' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES', 40_000)
      delivered = []
      subscription, release = blocked_subscription(delivered)

      50.times { |index| subscription.deliver(*updated("file:///#{index}", 'x' * 10_000)) }

      expect(subscription.pending_notifications).to be <= 4
      expect(subscription.pending_notification_bytes).to be <= 40_000
      expect(subscription.dropped_notifications).to be >= 45
      release << :go
      subscription.finish
    end

    it 'still drops repeats before the only notice of a quiet resource' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES', 40_000)
      delivered = []
      subscription, release = blocked_subscription(delivered)
      payload = 'x' * 10_000

      subscription.deliver(*updated('file:///cold', payload))
      10.times { subscription.deliver(*updated('file:///hot', payload)) }

      release << :go
      wait_until { subscription.pending_notifications.zero? && delivered.size > 2 }
      expect(delivered.first(2)).to eq(['file:///blocker', 'file:///cold'])
      expect(delivered.count('file:///hot')).to be_between(1, 3)
      subscription.finish
    end

    it 'still delivers a single notification larger than the whole budget' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES', 1_000)
      delivered = []
      subscription, release = blocked_subscription(delivered)

      subscription.deliver(*updated('file:///huge', 'x' * 20_000))

      release << :go
      wait_until { delivered.include?('file:///huge') }
      expect(subscription.dropped_notifications).to eq(0)
      subscription.finish
    end
  end

  # codex [P2] subscription_support.rb:109-111: a listener reacting to a
  # list_changed notification by calling a cached list method ran on its own
  # thread as soon as the delivery was queued — which was before the transport
  # and client caches the notification invalidates had been dropped.
  describe 'the caches a listener may read when its notification arrives' do
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    it 'invalidates the transport and client caches before the listener runs' do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'x' }])
      server.instance_variable_set(:@tools, ['a tool'])
      client.tool_cache['server:tool'] = 'a tool'
      seen = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |_method, _params|
        seen << [server.instance_variable_get(:@tools), client.tool_cache.dup]
      end
      subscription.assign_id(7)
      server.register_subscription(subscription)
      # Invalidation is made slow so that the ordering under test is the one
      # the dispatcher thread would win: queued first, it delivers while the
      # routing thread is still inside the invalidation.
      allow(server).to receive(:invalidate_cache_for_notification).and_wrap_original do |original, *args|
        sleep 0.2
        original.call(*args)
      end

      server.route_notification('notifications/tools/list_changed', { '_meta' => { sub_meta => 7 } })

      transport_cache, client_cache = seen.pop(timeout: 3)
      expect(transport_cache).to be_nil
      expect(client_cache).to be_empty
      subscription.finish
    end

    it 'orders every invalidation ahead of the delivery to the listeners' do
      order = []
      allow(server).to receive(:invalidate_cache_for_notification) { order << :transport_cache }
      allow(server).to receive(:deliver_subscription_notification) { order << :listeners }
      server.on_notification { |_method, _params| order << :host_callback }

      server.route_notification('notifications/tools/list_changed', {})

      expect(order).to eq(%i[transport_cache host_callback listeners])
    end
  end

  # codex [P2] subscription_support.rb:93: an acknowledgment only recorded the
  # filter the server granted. A re-opened stream is acknowledged afresh and
  # the server MAY grant a subset, so a URI the new acknowledgment leaves out
  # was no longer watched while live_resource_subscription kept saying it was.
  describe 'a resource subscription whose stream is acknowledged again' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }
    let(:uri) { 'file:///watched.txt' }

    before do
      stdin = double('stdin', flush: nil, closed?: true, close: nil)
      allow(stdin).to receive(:puts) { |line| written << JSON.parse(line) }
      server.instance_variable_set(:@stdin, stdin)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
    end

    def mapped_subscription
      subscription = MCPClient::Subscription.new(server: server, requested: { 'resourceSubscriptions' => [uri] })
      subscription.assign_id(11)
      server.register_subscription(subscription)
      server.subscriptions_mutex.synchronize { server.resource_subscriptions[uri] = subscription }
      subscription
    end

    def acknowledge(filter)
      server.route_notification('notifications/subscriptions/acknowledged',
                                { '_meta' => { sub_meta => 11 }, 'notifications' => filter })
    end

    it 'closes the stream and drops the mapping when the URI is not acknowledged again' do
      subscription = mapped_subscription
      acknowledge({ 'resourceSubscriptions' => [uri] })
      expect(server.live_resource_subscription(uri)).to eq(subscription)

      acknowledge({ 'toolsListChanged' => true })

      expect(server.live_resource_subscription(uri)).to be_nil
      expect(subscription).to be_closed
      expect(written.map { |m| m['method'] }).to include('notifications/cancelled')
    end

    it 'keeps the mapping when the URI is acknowledged again' do
      subscription = mapped_subscription

      acknowledge({ 'resourceSubscriptions' => [uri] })
      acknowledge({ 'resourceSubscriptions' => [uri] })

      expect(server.live_resource_subscription(uri)).to eq(subscription)
      expect(subscription).to be_active
    end

    it 'drops the mapping on Streamable HTTP too, from the stream thread that routes it' do
      http = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      subscription = MCPClient::Subscription.new(server: http, requested: { 'resourceSubscriptions' => [uri] })
      subscription.assign_id(11)
      http.register_subscription(subscription)
      http.subscriptions_mutex.synchronize { http.resource_subscriptions[uri] = subscription }

      # The re-acknowledgment is routed on the stream's own thread, so closing
      # from inside it must not wait for that thread to finish.
      Thread.new do
        http.route_notification('notifications/subscriptions/acknowledged',
                                { '_meta' => { sub_meta => 11 }, 'notifications' => {} })
      end.join(3)

      expect(http.live_resource_subscription(uri)).to be_nil
      expect(subscription).to be_closed
    end
  end

  # codex [P2] / grok [1] json_rpc_transport.rb:109-124: the crash-loop bound
  # measured from the moment the restart was attempted, so a server whose
  # handshake takes longer than the interval and which then exits at once
  # looked healthy every time and was respawned for ever.
  describe 'a stdio server that dies as soon as a slow handshake finishes' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }

    def install_stdin
      server.instance_variable_set(:@stdin, double('stdin', flush: nil, closed?: true, close: nil).tap do |handle|
        allow(handle).to receive(:puts) { |line| written << JSON.parse(line) }
      end)
    end

    before do
      allow(server).to receive(:connect) { install_stdin && true }
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      install_stdin
      allow(server).to receive(:send_request) { |request| written << request }
      allow(server).to receive(:wait_response) do |id, **_options|
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => discover_result }
      end
    end

    def listens
      written.select { |message| message['method'] == 'subscriptions/listen' }
    end

    # The handshake outlasts the crash-loop interval, so the time since the
    # restart was *attempted* says "healthy" while the process that died had
    # been usable for no time at all.
    def slow_handshake(seconds)
      allow(server).to receive(:negotiate_protocol).and_wrap_original do |original, *args|
        sleep seconds
        original.call(*args)
      end
    end

    it 'gives up when the process dies immediately after a handshake longer than the interval' do
      stub_const('MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL', 0.05)
      slow_handshake(0.1)
      subscription = server.listen(notifications: { tools_list_changed: true })

      server.send(:handle_server_exit)
      server.send(:handle_server_exit)

      expect(listens.size).to eq(2)
      expect(subscription).to be_closed
      expect(subscription.error).to be_a(MCPClient::Errors::MCPError)
      expect(subscription.error.message).to match(/exited/i)
    end

    it 'restarts again when the restarted process stayed up longer than the interval' do
      stub_const('MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL', 0.05)
      subscription = server.listen(notifications: { tools_list_changed: true })

      server.send(:handle_server_exit)
      sleep 0.1
      server.send(:handle_server_exit)

      expect(listens.size).to eq(3)
      expect(subscription).not_to be_closed
    end
  end
end
