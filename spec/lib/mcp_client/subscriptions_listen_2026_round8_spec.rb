# frozen_string_literal: true

require 'spec_helper'

# Review round 8 (codex, grok). Two of these had survived three rounds of
# patching and are pinned here against the invariant rather than against the
# interleaving that happened to be reported:
#
# * the stdio crash-loop bound. Rounds 6 and 7 kept the answer in flags and a
#   stamp on the transport that concurrent restarts raced over. The invariant
#   is now: *the open subscriptions are re-sent onto a new process unless the
#   process that last received them died less than
#   SUBSCRIPTION_RESTART_MIN_INTERVAL after receiving them* — two facts
#   recorded on the record of that process, at the two moments they happen,
#   and asked in the one place that re-sends.
#
# * the notification queue. Rounds 5-7 decided "which entry goes" and "how
#   many bytes are charged" by rules that disagreed, so an eviction could free
#   nothing and the only notice of a resource was spent on pressure it did not
#   relieve. The invariant is now: *every queued notification is charged
#   exactly what it retains, and every eviction removes an entry whose removal
#   relieves the pressure that caused it* — so overflow always makes progress
#   and what it costs is chosen by identity, a repeat before the only notice of
#   something.
#
# The ordinary findings: a mapped resource subscription reused while it was
# between listen attempts; an acknowledgment stored as the peer's own mutable
# hash; a host callback that could drop or redirect a delivery by editing
# _meta; a failed listen write that tore down a stream a restart was about to
# re-send, or swallowed a failure the replacement had already suffered; and an
# unsanitized peer-controlled method name in the log.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 8' do
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

  # --- A. the crash-loop bound -------------------------------------------
  #
  # The subscriptions are re-sent onto a new process unless the process that
  # last received them died less than SUBSCRIPTION_RESTART_MIN_INTERVAL after
  # receiving them. Both facts belong to that process: it is stamped when the
  # subscriptions are handed to it and again when its handles are torn down,
  # and the question is asked where they are re-sent — so no interleaving of a
  # host re-init and a reader's restart can answer it on another process's
  # behalf.
  describe 'a stdio server that keeps exiting under its subscriptions' do
    include_context 'a scripted stdio session'

    before { stub_const('MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL', 0.05) }

    def open_subscription
      server.listen(notifications: { tools_list_changed: true })
    end

    it 'ends them when the process they were re-sent to dies straight away' do
      subscription = open_subscription

      server.send(:handle_server_exit)
      server.send(:handle_server_exit)

      expect(listens.size).to eq(2)
      expect(subscription).to be_closed
      expect(subscription.error).to be_a(MCPClient::Errors::MCPError)
      expect(subscription.error.message).to match(/exited/i)
    end

    # codex round 8: the restart flag and the readiness stamp lived on the
    # transport, so a host request that re-established the process before the
    # reader's restart got there left the stamp unwritten — and every later
    # exit read a crash-looping server as a healthy one.
    it 'ends them when a host request re-establishes the process before the restart does' do
      subscription = open_subscription
      # Every exit is followed at once by the host's own next request, which
      # re-establishes the process and re-sends the subscriptions itself; the
      # reader's restart then finds nothing left to do.
      allow(server).to receive(:cleanup).and_wrap_original do |original, *args|
        original.call(*args)
        server.send(:ensure_initialized)
      end

      4.times { server.send(:handle_server_exit) }

      expect(subscription).to be_closed
      expect(subscription.error.message).to match(/exited/i)
      expect(listens.size).to eq(2)
    end

    # However the exits, the host's requests and the reader's restarts
    # interleave, the client stops re-sending: a bound that only holds for one
    # ordering is not a bound.
    it 'stops re-sending them however the exits and host requests interleave' do
      subscription = open_subscription

      12.times do |index|
        server.send(:handle_server_exit)
        server.send(:ensure_initialized) if index.even?
      end

      expect(subscription).to be_closed
      expect(listens.size).to be <= 3
    end

    # grok round 7: the process one restart spawns can exit while that restart
    # is still re-sending to it, so a second restart begins on the new
    # process's reader thread before the first has returned.
    it 'still counts the process a nested restart established' do
      subscription = open_subscription
      nested = nil

      allow(server).to receive(:reopen_subscriptions).and_wrap_original do |original, *args|
        if nested.nil?
          sleep 0.1 # outlive the interval, so this exit is not itself a loop
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

    # codex/grok round 6: uptime counted from the moment the restart was
    # attempted credited a server with its own handshake, so one that takes
    # longer to start than the interval and then exits looked healthy for ever.
    it 'still counts a process whose handshake outlasted the interval' do
      allow(server).to receive(:negotiate_protocol).and_wrap_original do |original, *args|
        sleep 0.1
        original.call(*args)
      end
      subscription = open_subscription

      server.send(:handle_server_exit)
      server.send(:handle_server_exit)

      expect(listens.size).to eq(2)
      expect(subscription).to be_closed
      expect(subscription.error.message).to match(/exited/i)
    end

    it 'keeps re-sending them to a process that stays up longer than the interval' do
      subscription = open_subscription

      server.send(:handle_server_exit)
      sleep 0.1
      server.send(:handle_server_exit)

      expect(listens.size).to eq(3)
      expect(subscription).not_to be_closed
    end

    it 'leaves a process nothing is waiting on to the next request' do
      subscription = open_subscription
      subscription.close

      server.send(:handle_server_exit)

      expect(listens.size).to eq(1)
    end
  end

  # --- B. what the notification queue gives up ---------------------------
  #
  # Every queued notification is charged exactly what it retains, and every
  # eviction removes an entry whose removal relieves the pressure that caused
  # it. A payload larger than the whole budget has a slot of its own, at most
  # one, so retained memory is the budget plus one peer-sized payload and
  # nothing is ever spent on pressure it cannot relieve.
  describe 'what the notification queue gives up when it overflows' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def updated(uri, payload = '')
      ['notifications/resources/updated',
       { 'uri' => uri, 'blob' => payload, '_meta' => { sub_meta => 1 } }]
    end

    # Everything the entry retains, method name included (round 9: the charge
    # used to serialize the params alone).
    def bytes_of(uri, payload = '')
      method, params = updated(uri, payload)
      method.bytesize + JSON.generate(params).bytesize
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
      subscription.deliver(*updated('file:///blocker'))
      entered.pop(timeout: 3)
      [subscription, release]
    end

    # codex/grok round 8: the oversized payload was exempt from the charge but
    # not from eviction, so ordinary traffic that overflowed the budget spent
    # the only notice of its resource on pressure that removing it did not
    # relieve.
    it 'never gives up an entry whose removal would free nothing it is short of' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES', 1_000)
      delivered = []
      subscription, release = blocked_subscription(delivered)

      subscription.deliver(*updated('file:///huge', 'x' * 20_000))
      3.times { |index| subscription.deliver(*updated("file:///small#{index}", 'y' * 300)) }

      # The oversized payload is charged to nothing the newcomers are short
      # of, so discarding it would relieve nothing: the budget gives up the
      # oldest entry it does charge, and only as many as it has to.
      expect(subscription.pending_notifications).to eq(3)
      expect(subscription.dropped_notifications).to eq(1)
      release << :go
      wait_until { delivered.size == 4 }
      expect(delivered).to eq(['file:///blocker', 'file:///huge', 'file:///small1', 'file:///small2'])
      subscription.finish
    end

    it 'charges exactly what it retains' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES', 1_000)
      delivered = []
      subscription, release = blocked_subscription(delivered)

      subscription.deliver(*updated('file:///huge', 'x' * 20_000))
      subscription.deliver(*updated('file:///small', 'y' * 300))

      expect(subscription.pending_notifications).to eq(2)
      expect(subscription.pending_notification_bytes)
        .to eq(bytes_of('file:///huge', 'x' * 20_000) + bytes_of('file:///small', 'y' * 300))
      release << :go
      wait_until { subscription.pending_notifications.zero? }
      expect(subscription.pending_notification_bytes).to eq(0)
      subscription.finish
    end

    # grok round 7.
    it 'keeps an oversized notice when the next notice of something else arrives' do
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

    # grok round 7: one such payload may sit behind a stalled listener, never a
    # queueful of them.
    it 'retains only one oversized payload' do
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

    # codex round 6: a count is not a memory bound.
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

    # grok round 5: one stream can carry a mixed filter, and a repeat is the
    # notification to lose.
    it 'still gives up repeats before the only notice of a quiet resource' do
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

    it 'still gives up the oldest of the most-queued identity under the count ceiling' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 3)
      delivered = []
      subscription, release = blocked_subscription(delivered)

      subscription.deliver(*updated('file:///cold'))
      2.times { subscription.deliver(*updated('file:///hot')) }
      subscription.deliver(*updated('file:///warm'))

      release << :go
      wait_until { delivered.size == 4 }
      expect(delivered).to eq(['file:///blocker', 'file:///cold', 'file:///hot', 'file:///warm'])
      expect(subscription.dropped_notifications).to eq(1)
      subscription.finish
    end

    it 'still bounds the queue when every queued notification names its own thing' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 3)
      delivered = []
      subscription, release = blocked_subscription(delivered)

      10.times { |index| subscription.deliver(*updated("file:///#{index}")) }

      expect(subscription.pending_notifications).to eq(3)
      expect(subscription.dropped_notifications).to eq(7)
      release << :go
      wait_until { delivered.size == 4 }
      expect(delivered).to eq(['file:///blocker', 'file:///7', 'file:///8', 'file:///9'])
      subscription.finish
    end
  end

  # --- 1. reusing the stream mapped to a resource URI ---------------------
  describe 'the stream subscribe_resource reuses for a URI' do
    include_context 'a scripted stdio session'

    let(:uri) { 'file:///watched.txt' }

    before { server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION) }

    def acknowledge(filter, id: 11)
      server.route_notification('notifications/subscriptions/acknowledged',
                                { '_meta' => { sub_meta => id }, 'notifications' => filter })
    end

    def mapped_subscription
      subscription = MCPClient::Subscription.new(server: server, requested: { 'resourceSubscriptions' => [uri] })
      subscription.assign_id(11)
      server.register_subscription(subscription)
      server.subscriptions_mutex.synchronize { server.resource_subscriptions[uri] = subscription }
      subscription
    end

    # What a transport does when it re-establishes a dropped stream: the
    # subscription goes back to :reconnecting and is then re-sent as a new
    # listen request, which the server holds no state for and has not answered.
    def resend(subscription, id)
      subscription.mark_reconnecting
      subscription.assign_id(id)
      server.register_subscription(subscription)
    end

    # codex [P2] / grok [4]: every handle that was not closed counted as a live
    # watch, so a stream whose replacement request was still in flight was
    # reused — and `subscribe_resource` answered true before the server had
    # acknowledged that request, or rejected it.
    it 'does not count a stream between listen attempts as a live watch' do
      subscription = mapped_subscription
      acknowledge({ 'resourceSubscriptions' => [uri] })
      expect(server.live_resource_subscription(uri)).to equal(subscription)

      resend(subscription, 12)

      expect(server.live_resource_subscription(uri)).to be_nil
    end

    it 'waits for the replacement request to be acknowledged before answering' do
      subscription = mapped_subscription
      acknowledge({ 'resourceSubscriptions' => [uri] })
      resend(subscription, 12)
      answered = Thread::Queue.new

      subscriber = Thread.new { answered << server.subscribe_resource_via_listen(uri) }
      sleep 0.05
      expect(answered).to be_empty

      acknowledge({ 'resourceSubscriptions' => [uri] }, id: 12)

      expect(subscriber.join(3)).to be_truthy
      expect(answered.pop).to equal(subscription)
      expect(listens).to be_empty
    end

    it 'raises when the replacement is acknowledged without the URI' do
      subscription = mapped_subscription
      acknowledge({ 'resourceSubscriptions' => [uri] })
      resend(subscription, 12)
      Thread.new do
        sleep 0.05
        acknowledge({ 'toolsListChanged' => true }, id: 12)
      end

      expect { server.subscribe_resource_via_listen(uri) }
        .to raise_error(MCPClient::Errors::MCPError, /#{Regexp.escape(uri)}/)
      expect(server.subscriptions_mutex.synchronize { server.resource_subscriptions }).to be_empty
    end

    # grok [4] subscription.rb:210-217: unacknowledged_resource_uris answers []
    # for a stream nothing has acknowledged, and the recheck read that as
    # success.
    it 'does not read a missing acknowledgment as a watch when it rechecks the mapping' do
      subscription = mapped_subscription
      Thread.new do
        sleep 0.05
        acknowledge({ 'toolsListChanged' => true })
      end

      expect { server.send(:recheck_mapped_resource_subscription, subscription, uri) }
        .to raise_error(MCPClient::Errors::MCPError, /#{Regexp.escape(uri)}/)
    end
  end

  # --- 2. the acknowledgment a subscription records ----------------------
  describe 'the acknowledgment a subscription records' do
    include_context 'a scripted stdio session'

    let(:uri) { 'file:///watched.txt' }

    def acknowledged_subscription(filter)
      subscription = MCPClient::Subscription.new(server: server, requested: { 'resourceSubscriptions' => [uri] })
      subscription.assign_id(7)
      server.register_subscription(subscription)
      server.route_notification('notifications/subscriptions/acknowledged',
                                { '_meta' => { sub_meta => 7 }, 'notifications' => filter })
      subscription
    end

    # codex [P2] subscription.rb:297-299: the stored acknowledgment was the
    # peer's own hash, which the host callback and the listeners are handed —
    # so adding the URI it left out made a waiting subscribe_resource report a
    # watch the server never granted.
    it 'is not rewritten by a host callback that edits the notification' do
      server.on_notification { |_method, params| params['notifications']['resourceSubscriptions'] << uri }

      subscription = acknowledged_subscription({ 'resourceSubscriptions' => [] })

      expect(subscription.unacknowledged_resource_uris).to eq([uri])
      expect(subscription.unsupported).to eq(['resourceSubscriptions'])
      expect(subscription.acknowledged['resourceSubscriptions']).to eq([])
    end

    it 'is frozen through and through' do
      subscription = acknowledged_subscription({ 'resourceSubscriptions' => [uri.dup] })

      acknowledged = subscription.acknowledged
      expect(acknowledged).to be_frozen
      expect(acknowledged['resourceSubscriptions']).to be_frozen
      expect(acknowledged['resourceSubscriptions'].first).to be_frozen
      expect { acknowledged['resourceSubscriptions'] = [] }.to raise_error(FrozenError)
    end
  end

  # --- 3. the payload the host callback is handed ------------------------
  describe 'a host notification callback that rewrites the payload' do
    include_context 'a scripted stdio session'

    def listening_subscription(id)
      seen = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |method, _params|
        seen << [id, method]
      end
      subscription.assign_id(id)
      server.register_subscription(subscription)
      [subscription, seen]
    end

    # codex [P2] subscription_support.rb:121-124: notify_host was given the
    # very hash the delivery is routed by, so a callback could drop the
    # delivery round 7 promised it could not prevent.
    it 'cannot stop the delivery by deleting the subscription id' do
      subscription, seen = listening_subscription(7)
      server.on_notification { |_method, params| params.delete('_meta') }

      server.route_notification('notifications/tools/list_changed', { '_meta' => { sub_meta => 7 } })

      expect(seen.pop(timeout: 3)).to eq([7, 'notifications/tools/list_changed'])
      subscription.finish
    end

    it 'cannot redirect the delivery to another subscription' do
      mine, seen = listening_subscription(7)
      theirs, other_seen = listening_subscription(8)
      server.on_notification { |_method, params| params['_meta'][sub_meta] = 8 }

      server.route_notification('notifications/tools/list_changed', { '_meta' => { sub_meta => 7 } })

      expect(seen.pop(timeout: 3)).to eq([7, 'notifications/tools/list_changed'])
      expect(other_seen).to be_empty
      mine.finish
      theirs.finish
    end
  end

  # --- 4/5. a listen write that fails ------------------------------------
  describe 'a listen write that fails' do
    include_context 'a scripted stdio session'

    # grok [1]: the write can fail after cleanup closed stdin, with the listen
    # id unchanged — and finishing it killed the stream the restart that
    # follows was about to re-send.
    it 'leaves a subscription a restart has already claimed for re-sending open' do
      failed = false
      allow(server).to receive(:send_request) do |request|
        written << request
        next unless request['method'] == 'subscriptions/listen' && !failed

        failed = true
        # The process died under the write: cleanup marks the subscription
        # :reconnecting and queues it for the restart that follows.
        server.send(:cleanup)
        raise MCPClient::Errors::TransportError, 'Failed to send JSONRPC request: closed stream'
      end

      subscription = server.listen(notifications: { tools_list_changed: true })

      expect(subscription).not_to be_closed
      expect(subscription.state).to eq(:reconnecting)

      server.send(:ensure_initialized)

      expect(listens.size).to eq(2)
      expect(server.subscription_by_id(subscription.id)).to equal(subscription)
      expect(subscription).not_to be_closed
    end

    # grok [3]: a superseded failure is only harmless while the stream that
    # superseded it stands.
    it 'raises when the stream that superseded it has itself already failed' do
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

      failure = nil
      opener = Thread.new do
        server.listen(notifications: { tools_list_changed: true })
      rescue StandardError => e
        failure = e
      end
      entered.pop(timeout: 3)

      server.send(:handle_server_exit)
      subscription = server.subscriptions.values.first
      expect(subscription.id).not_to eq(blocked_id)
      # The stream that replaced the blocked attempt is rejected in its turn.
      server.handle_subscription_response({ 'jsonrpc' => '2.0', 'id' => subscription.id,
                                            'error' => { 'code' => -32_602, 'message' => 'bad filter' } })

      release << :go
      opener.join(3)

      expect(failure).to be_a(MCPClient::Errors::MCPError)
      expect(failure.message).to match(/bad filter/)
    end

    # The round 7 case: a healthy replacement is still left alone.
    it 'leaves the stream a restart opened alone while it stands' do
      entered = Thread::Queue.new
      release = Thread::Queue.new
      blocked = false
      allow(server).to receive(:send_request) do |request|
        written << request
        next unless request['method'] == 'subscriptions/listen' && !blocked

        blocked = true
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

      server.send(:handle_server_exit)
      subscription = server.subscriptions.values.first
      release << :go
      opener.join(3)

      expect(failure).to be_nil
      expect(opened).to equal(subscription)
      expect(subscription).not_to be_closed
      expect(listens.size).to eq(2)
    end
  end

  # --- 6. what notify_host writes to the log -----------------------------
  describe 'the log line a failing host callback leaves' do
    include_context 'a scripted stdio session'

    # grok [6]: the method name is peer-controlled and this codebase has
    # sanitize_log_text for exactly that.
    it 'escapes the peer-controlled method name' do
      output = StringIO.new
      server.instance_variable_set(:@logger, Logger.new(output))
      server.on_notification { |_method, _params| raise 'host handler exploded' }

      server.route_notification("notifications/evil\u0000\nWARN forged", {})

      expect(output.string).to include('notifications/evil\x00\x0AWARN forged')
      expect(output.string).not_to include("notifications/evil\u0000")
    end
  end
end
