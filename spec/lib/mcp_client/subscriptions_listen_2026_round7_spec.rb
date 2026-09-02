# frozen_string_literal: true

require 'spec_helper'

# Review round 7 (codex, grok), on the code round 6 left: a listen write that
# failed after a restart had already re-opened the same subscription and tore
# the healthy replacement down; a readiness stamp a nested restart wiped, so
# the crash-loop bound round 6 introduced never fired; subscriptions stranded
# :reconnecting when the restarted process turned out to be legacy; a host
# notification callback whose exception swallowed the delivery to the
# subscription's listeners; a byte ceiling that evicted the only notice of one
# resource to admit a notice of another; a resource re-acknowledgment that
# landed before the URI was mapped and was therefore not checked; a requested
# filter that kept the caller's own mutable array; and an acknowledgment that
# counted as support merely by naming the field.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 7' do
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

  # A stdio transport whose process, handshake and writes are all stubbed, so
  # an example can drive the restart lifecycle by hand.
  shared_context 'a scripted stdio session' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }

    def install_stdin
      server.instance_variable_set(:@stdin, double('stdin', flush: nil, closed?: true, close: nil).tap do |handle|
        allow(handle).to receive(:puts) { |line| written << JSON.parse(line) }
      end)
    end

    def listens
      written.select { |message| message['method'] == 'subscriptions/listen' }
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
  end

  # codex [P1] json_rpc_transport.rb:68-69: the child can exit while the
  # initial listen write is blocked; the EOF handler restarts the process and
  # re-opens the very same Subscription under a new id, and the older write's
  # rescue then unregistered *that* id and finished the subscription — closing
  # the healthy replacement stream.
  describe 'a listen write that fails after a restart re-opened the subscription' do
    include_context 'a scripted stdio session'

    it 'leaves the stream the restart opened alone' do
      entered = Thread::Queue.new
      release = Thread::Queue.new
      blocked_id = nil
      allow(server).to receive(:send_request) do |request|
        written << request
        next unless request['method'] == 'subscriptions/listen' && blocked_id.nil?

        blocked_id = request['id']
        entered << :in
        release.pop
        raise MCPClient::Errors::TransportError, 'Failed to send JSONRPC request: closed stream'
      end

      opened = nil
      failure = nil
      opener = Thread.new do
        opened = server.listen(notifications: { tools_list_changed: true })
      rescue StandardError => e
        failure = e
      end
      entered.pop(timeout: 3)

      # The process exits under the blocked write and the restart re-sends the
      # subscription with a fresh id.
      server.send(:handle_server_exit)
      subscription = server.subscriptions.values.first
      expect(subscription).not_to be_nil
      expect(subscription.id).not_to eq(blocked_id)
      reopened_id = subscription.id

      release << :go
      opener.join(3)

      expect(failure).to be_nil
      expect(opened).to equal(subscription)
      expect(subscription).not_to be_closed
      expect(server.subscription_by_id(reopened_id)).to equal(subscription)
      expect(listens.size).to eq(2)
    end
  end

  # grok [1] json_rpc_transport.rb:37-40, 132-138 with server_stdio.rb:797-803:
  # a second restart beginning while the first is still inside
  # ensure_initialized cleared the shared "restarting" flag on its way out, so
  # the session the second restart established stamped nil and every later
  # exit read the crash loop as a healthy server.
  describe 'a restart that begins while the previous one is still finishing' do
    include_context 'a scripted stdio session'

    it 'still counts the session the nested restart established against the crash-loop bound' do
      stub_const('MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL', 0.05)
      subscription = server.listen(notifications: { tools_list_changed: true })
      nested = nil

      # The process the first restart spawned exits while that restart is
      # still re-sending subscriptions to it: its reader runs
      # handle_server_exit on its own thread, which blocks on the init lock
      # the first restart is holding.
      allow(server).to receive(:reopen_subscriptions).and_wrap_original do |original, *args|
        if nested.nil?
          sleep 0.1 # outlive the crash-loop interval, so this exit is not itself a loop
          nested = Thread.new { server.send(:handle_server_exit) }
          wait_until { nested.status == 'sleep' }
        end
        original.call(*args)
      end

      server.send(:handle_server_exit)
      nested.join(3)
      server.send(:handle_server_exit)

      expect(subscription).to be_closed
      expect(subscription.error).to be_a(MCPClient::Errors::MCPError)
      expect(subscription.error.message).to match(/exited/i)
    end
  end

  # codex [P2] json_rpc_transport.rb:77-78: cleanup has already moved the open
  # subscriptions into @reconnecting_subscriptions, so returning from
  # reopen_subscriptions on a legacy session neither re-opened nor closed
  # them: their handles stayed :reconnecting for ever.
  describe 'a restarted stdio process that negotiates a legacy version' do
    include_context 'a scripted stdio session'

    it 'fails the subscriptions the new session cannot carry' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      allow(server).to receive(:negotiate_protocol) do
        server.instance_variable_set(:@protocol_version, '2025-11-25')
      end

      server.send(:handle_server_exit)

      expect(subscription).to be_closed
      expect(subscription.error).to be_a(MCPClient::Errors::CapabilityError)
      expect(subscription.error.message).to include('2025-11-25')
      expect(subscription.state).to eq(:closed)
    end
  end

  # grok [4] subscription_support.rb:101-106: round 6 moved the delivery to the
  # subscription's listeners behind the host callback so the caches would be
  # invalidated first — which let a host callback that raises drop the
  # notification the listeners were waiting for.
  describe 'a host notification callback that raises' do
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    it 'still invalidates both caches first and still reaches the listeners' do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'x' }])
      server.instance_variable_set(:@tools, ['a tool'])
      client.tool_cache['server:tool'] = 'a tool'
      client.on_notification { |_srv, _method, _params| raise 'host handler exploded' }
      seen = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |method, _params|
        seen << [method, server.instance_variable_get(:@tools), client.tool_cache.dup]
      end
      subscription.assign_id(7)
      server.register_subscription(subscription)

      expect do
        server.route_notification('notifications/tools/list_changed', { '_meta' => { sub_meta => 7 } })
      end.not_to raise_error

      method, transport_cache, client_cache = seen.pop(timeout: 3)
      expect(method).to eq('notifications/tools/list_changed')
      expect(transport_cache).to be_nil
      expect(client_cache).to be_empty
      subscription.finish
    end
  end

  # grok [2] notification_dispatcher.rb:155-188: a payload larger than the whole
  # budget is queued alone by design, but charging it against the budget left
  # the queue permanently overflowing — so the next notice of anything else
  # evicted it, which is the "only notice of one thing" loss the policy exists
  # to prevent.
  describe 'a queued notification larger than the whole byte budget' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def updated(uri, payload)
      ['notifications/resources/updated',
       { 'uri' => uri, 'blob' => payload, '_meta' => { sub_meta => 1 } }]
    end

    # A subscription whose dispatcher is parked inside the first delivery, so
    # everything queued behind it is subject to the overflow policy.
    def blocked_subscription(delivered)
      entered = Thread::Queue.new
      release = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |_method, params|
        delivered << params['uri']
        next unless params['uri'] == 'file:///blocker'

        entered << :in
        release.pop
      end
      subscription.assign_id(1)
      subscription.deliver(*updated('file:///blocker', 'x'))
      entered.pop(timeout: 3)
      [subscription, release]
    end

    it 'is not evicted by the next notice of something else' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES', 1_000)
      delivered = []
      subscription, release = blocked_subscription(delivered)

      subscription.deliver(*updated('file:///huge', 'x' * 20_000))
      subscription.deliver(*updated('file:///small', 'y'))

      expect(subscription.dropped_notifications).to eq(0)
      release << :go
      wait_until { delivered.include?('file:///huge') && delivered.include?('file:///small') }
      subscription.finish
    end

    it 'is still the only oversized payload the queue retains' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES', 1_000)
      delivered = []
      subscription, release = blocked_subscription(delivered)

      3.times { |index| subscription.deliver(*updated("file:///huge#{index}", 'x' * 20_000)) }

      expect(subscription.pending_notifications).to eq(1)
      expect(subscription.pending_notification_bytes).to be < 25_000
      expect(subscription.dropped_notifications).to eq(2)
      release << :go
      subscription.finish
    end
  end

  # grok [3] subscription_support.rb:238-254, 265-275: round 6's revalidation
  # reads the resource_subscriptions mapping, which open_resource_subscription
  # only writes after confirm_resource_subscription has returned — so a
  # narrowing re-acknowledgment inside that window was invisible and the stream
  # was stored as a live watch.
  describe 'a resource subscription re-acknowledged before its URI is mapped' do
    include_context 'a scripted stdio session'

    let(:uri) { 'file:///watched.txt' }

    before { server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION) }

    def acknowledge(id, filter)
      server.route_notification('notifications/subscriptions/acknowledged',
                                { '_meta' => { sub_meta => id }, 'notifications' => filter })
    end

    it 'does not store a watch the server stopped honouring in that window' do
      allow(server).to receive(:confirm_resource_subscription).and_wrap_original do |original, subscription, wanted|
        acknowledge(subscription.id, { 'resourceSubscriptions' => [wanted] })
        original.call(subscription, wanted)
        # The stream is re-opened and acknowledged again before the caller
        # has had a chance to map the URI to it.
        acknowledge(subscription.id, { 'toolsListChanged' => true })
      end

      expect { server.subscribe_resource_via_listen(uri) }
        .to raise_error(MCPClient::Errors::ResourceReadError, /without '#{Regexp.escape(uri)}'/)
      expect(server.live_resource_subscription(uri)).to be_nil
      expect(server.subscriptions_mutex.synchronize { server.resource_subscriptions }).to be_empty
    end
  end

  # codex [P2] subscription.rb:106: an array-valued filter kept the caller's own
  # array and its mutable strings, and Streamable HTTP serializes the request on
  # a background thread after listen has returned.
  describe 'the filter a listen request carries' do
    include_context 'a scripted stdio session'

    it 'detaches and freezes an array-valued filter from the caller' do
      uris = ['file:///a'.dup]
      subscription = server.listen(notifications: { resource_subscriptions: uris })

      uris << 'file:///b'
      uris.first << '/mutated'

      expect(subscription.requested['resourceSubscriptions']).to eq(['file:///a'])
      expect(subscription.requested['resourceSubscriptions']).to be_frozen
      expect(subscription.requested['resourceSubscriptions'].first).to be_frozen
      expect(subscription.requested).to be_frozen
    end

    it 'keeps the request a later reconnect would send unchanged' do
      uris = ['file:///a'.dup]
      filter = MCPClient::Subscription.normalize_filter('resourceSubscriptions' => uris)

      uris.first.replace('file:///elsewhere')

      expect(JSON.generate(filter)).to eq(JSON.generate({ 'resourceSubscriptions' => ['file:///a'] }))
    end
  end

  # codex [P2] subscription.rb:192: unsupported compared field names only, so a
  # server that echoed resourceSubscriptions with an empty array reported the
  # field as supported although it had accepted none of the URIs.
  describe 'what an acknowledgment has to grant to count as supported' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def subscription_for(filter)
      MCPClient::Subscription.new(server: server, requested: MCPClient::Subscription.normalize_filter(filter))
    end

    it 'reports a resource subscription the server granted no URI of as unsupported' do
      subscription = subscription_for('resourceSubscriptions' => ['file:///a'])

      subscription.acknowledge({ 'resourceSubscriptions' => [] })

      expect(subscription.unsupported).to eq(['resourceSubscriptions'])
      expect(subscription.unacknowledged_resource_uris).to eq(['file:///a'])
    end

    it 'reports a flag the server acknowledged as false as unsupported' do
      subscription = subscription_for('toolsListChanged' => true)

      subscription.acknowledge({ 'toolsListChanged' => false })

      expect(subscription.unsupported).to eq(['toolsListChanged'])
    end

    it 'still reports a partially granted list as supported' do
      subscription = subscription_for('resourceSubscriptions' => ['file:///a', 'file:///b'],
                                      'toolsListChanged' => true)

      subscription.acknowledge({ 'resourceSubscriptions' => ['file:///a'], 'toolsListChanged' => true })

      expect(subscription.unsupported).to be_empty
      expect(subscription.unacknowledged_resource_uris).to eq(['file:///b'])
    end

    it 'still reports a field the server left out as unsupported' do
      subscription = subscription_for('taskIds' => ['task-1'], 'toolsListChanged' => true)

      subscription.acknowledge({ 'toolsListChanged' => true })

      expect(subscription.unsupported).to eq(['taskIds'])
    end
  end
end
