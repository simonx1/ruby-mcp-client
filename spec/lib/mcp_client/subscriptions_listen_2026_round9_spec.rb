# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Review round 9 (codex, grok), at the edges of the two mechanisms round 8
# rewrote rather than inside them:
#
# * **what counts as a grant.** A stream that dropped keeps the last
#   acknowledgment on record until the replacement request takes a new id
#   after the backoff, and `subscribe_resource` looking for a stream to reuse
#   read that record as the current grant — reporting a watch for the whole
#   HTTP backoff (or stdio handshake) on a stream the server no longer holds,
#   and which the replacement may reject. A *grant* is now only what a
#   running stream carries; the *answer* a caller waiting on its own listen
#   request was given still stands until a replacement request goes out, and
#   "nothing re-sent yet" is now distinguished from "re-sent and unanswered"
#   by a flag written where those two things happen rather than by which of
#   them the backoff happens to reach first.
#
# * **whose stream a failed listen write is.** Round 8 left a `:reconnecting`
#   subscription alone, but taking the new listen id has already moved it to
#   `:pending` by the time the write fails — so an EPIPE on the very hand-over
#   a restart is performing closed the stream the spec says MUST be re-sent.
#
# * **what a queued notification is charged.** The queue retains the method
#   name and the byte charge serialized only the params, so tagged
#   notifications with multi-megabyte method names and `{}` params cost two
#   bytes each and a thousand of them slipped the ceiling entirely.
#
# * **which process the crash-loop bound judges.** The record of the process
#   that last carried the subscriptions outlived the question it answers: once
#   a refusal had closed them, a subscription opened directly on the healthy
#   replacement was still judged by the corpse, and that process's own exit —
#   after any amount of uptime — read as another crash loop.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 9' do
  def sub_meta
    'io.modelcontextprotocol/subscriptionId'
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'resources' => { 'subscribe' => true, 'listChanged' => true } } }
  end

  def ack_message(id, filter)
    { 'jsonrpc' => '2.0', 'method' => 'notifications/subscriptions/acknowledged',
      'params' => { '_meta' => { sub_meta => id }, 'notifications' => filter } }
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

  # --- 1. the acknowledgment a resource watch is read from ----------------
  #
  # Two different questions used to share one answer. "Is the server watching
  # this URI on this stream *right now*?" — which is what reusing a mapped
  # stream asks — is answered only by a stream that is running. "Did the
  # server answer the listen request I am waiting for?" — which is what the
  # subscriber that opened the stream asks — is answered by the acknowledgment
  # on record, and a connection that merely dropped does not unanswer it.
  describe 'what counts as a grant for a resource URI' do
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

    # The transport re-sending a dropped stream: a new listen request the
    # server holds no state for and has not answered.
    def resend(subscription, id)
      subscription.assign_id(id)
      server.register_subscription(subscription)
    end

    # codex [P1] subscription.rb:258-263 / grok [2]: the stream is marked
    # reconnecting the moment it drops but keeps its acknowledgment until the
    # replacement takes an id after the backoff, and the reuse path read that
    # record as the grant for the whole window.
    it 'does not read a dropped stream as watching on the strength of its old acknowledgment' do
      subscription = mapped_subscription
      acknowledge({ 'resourceSubscriptions' => [uri] })
      expect(server.live_resource_subscription(uri)).to equal(subscription)

      subscription.mark_reconnecting

      expect(server.live_resource_subscription(uri)).to be_nil
      expect(subscription.await_live_resource_watch(uri, 0)).to eq(:timeout)
    end

    it 'waits for the replacement of a dropped stream instead of answering from the old grant' do
      subscription = mapped_subscription
      acknowledge({ 'resourceSubscriptions' => [uri] })
      subscription.mark_reconnecting
      answered = Thread::Queue.new

      subscriber = Thread.new { answered << server.subscribe_resource_via_listen(uri) }
      sleep 0.05
      expect(answered).to be_empty

      resend(subscription, 12)
      acknowledge({ 'resourceSubscriptions' => [uri] }, id: 12)

      expect(subscriber.join(3)).to be_truthy
      expect(answered.pop).to equal(subscription)
      expect(listens).to be_empty
    end

    # Round 4's contract, kept: the drop must not unanswer the question the
    # subscriber that opened the stream is blocked on, or it would wait out
    # its whole acknowledgment timeout for an answer it already had.
    it 'still answers the caller waiting on the request the server acknowledged' do
      subscription = mapped_subscription
      acknowledge({ 'resourceSubscriptions' => [uri] })
      subscription.mark_reconnecting

      expect(subscription.await_resource_watch(uri, 0)).to eq(:watching)
      expect(subscription.wait_until_settled(0)).to eq(:active)
    end

    # ...and the distinction that keeps it honest is written where the two
    # things happen, not read off whichever the backoff reached first: a
    # request that has actually gone out is unanswered until the server
    # answers *it*.
    it 'stops reporting the old answer once a replacement request has gone out' do
      subscription = mapped_subscription
      acknowledge({ 'resourceSubscriptions' => [uri] })
      subscription.mark_reconnecting
      resend(subscription, 12)

      expect(subscription.await_resource_watch(uri, 0)).to eq(:timeout)
      expect(subscription.wait_until_settled(0)).to be_nil
    end
  end

  describe 'a Streamable HTTP stream that dropped and is waiting to re-open' do
    let(:url) { 'https://example.com/mcp' }
    let(:uri) { 'file:///a' }
    let(:requests) { [] }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp',
                                          retries: 0, read_timeout: 2)
    end

    # Long enough that nothing re-opens on its own schedule: the example
    # decides when the backoff ends.
    before { stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 30) }

    after { server.cleanup }

    def sse_response(*events)
      { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
        body: events.map { |event| "event: message\ndata: #{JSON.generate(event)}\n\n" }.join }
    end

    def json_response(id, result)
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result) }
    end

    def stub_listen(&listen)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << body
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'subscriptions/listen' then listen.call(body)
        else json_response(body['id'], {})
        end
      end
    end

    def listen_count
      requests.count { |body| body['method'] == 'subscriptions/listen' }
    end

    # codex [P1] / grok [2]: `subscribe_resource` answered `true` for the
    # whole backoff from the acknowledgment of the stream that had already
    # dropped — no server-side stream existed, and the request that replaces
    # it may be rejected or acknowledged without the URI.
    it 'does not answer a later subscriber from the acknowledgment it had' do
      stub_listen { |body| sse_response(ack_message(body['id'], { 'resourceSubscriptions' => [uri] })) }
      expect(server.subscribe_resource(uri)).to be(true)
      subscription = server.resource_subscriptions[uri]
      wait_until { subscription.state == :reconnecting }

      answered = Thread::Queue.new
      subscriber = Thread.new { answered << server.subscribe_resource(uri) }
      sleep 0.05
      expect(answered).to be_empty

      # The only way this example lets the wait end: the stream nothing is
      # watching goes away, and the subscriber opens one of its own.
      subscription.close

      expect(subscriber.join(3)).to be_truthy
      expect(answered.pop).to be(true)
      expect(listen_count).to eq(2)
    end
  end

  # --- 2. whose stream a failed listen write is --------------------------
  describe 'a listen write that fails while a new process is being handed the subscriptions' do
    include_context 'a scripted stdio session'

    def open_subscription
      server.listen(notifications: { tools_list_changed: true })
    end

    # From here on every listen write fails, as one to a child whose stdin is
    # already broken would.
    def break_listen_writes
      allow(server).to receive(:send_request).and_wrap_original do |original, request|
        if request['method'] == 'subscriptions/listen'
          raise MCPClient::Errors::TransportError, 'Failed to send JSONRPC request: Broken pipe'
        end

        original.call(request)
      end
    end

    # grok [1] json_rpc_transport.rb:91-104: taking the new listen id has
    # already moved the subscription from :reconnecting to :pending, so the
    # guard round 8 added never fired on the hand-over itself and an EPIPE
    # there closed the stream the restart was in the middle of re-sending.
    it 'leaves the subscription for the next process instead of closing it' do
      subscription = open_subscription
      break_listen_writes

      server.send(:handle_server_exit)

      expect(subscription).not_to be_closed
      expect(subscription).to be_reconnecting
      expect(server.instance_variable_get(:@reconnecting_subscriptions)).to include(subscription)
    end

    it 'still fails a first listen the transport could not write at all' do
      break_listen_writes

      expect { open_subscription }.to raise_error(MCPClient::Errors::TransportError, /Broken pipe/)
    end

    # Deferring is not retrying for ever: a server that breaks under every
    # hand-over still runs out of the crash-loop bound.
    it 'still stops re-sending when every process breaks under the hand-over' do
      stub_const('MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL', 0.05)
      subscription = open_subscription
      break_listen_writes

      4.times { server.send(:handle_server_exit) }

      expect(subscription).to be_closed
      # Closed by the bound on respawning, not by the write that failed: the
      # deferral handed it on, and the next hand-over is what refused it.
      expect(subscription.error.message).to match(/exited again/)
      expect(listens.size).to eq(1)
    end
  end

  # --- 3. what a queued notification is charged --------------------------
  describe 'what a queued notification is charged for' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    # A subscription whose dispatcher is parked inside the first delivery, so
    # everything queued behind it is subject to the ceilings.
    def blocked_subscription
      entered = Thread::Queue.new
      release = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |method, _params|
        next unless method == 'notifications/blocker'

        entered << :in
        release.pop
      end
      subscription.assign_id(1)
      subscription.deliver('notifications/blocker', {})
      entered.pop(timeout: 3)
      [subscription, release]
    end

    # codex [P1] notification_dispatcher.rb:115-116: the entry retains the
    # method name in its identity and in the delivery, but the charge
    # serialized only the params — so a peer tagging `{}` params with a
    # multi-megabyte method name paid two bytes for each of them.
    it 'includes the method name it retains' do
      subscription, release = blocked_subscription
      method = "notifications/#{'m' * 4096}"

      subscription.deliver(method, {})

      expect(subscription.pending_notification_bytes).to be >= method.bytesize
      release.close
      subscription.finish
    end

    it 'holds the byte ceiling against notifications whose size is all method name' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES', 4096)
      subscription, release = blocked_subscription

      12.times { |index| subscription.deliver("notifications/#{'m' * 1024}/#{index}", {}) }

      expect(subscription.pending_notification_bytes).to be <= 4096
      expect(subscription.dropped_notifications).to be_positive
      release.close
      subscription.finish
    end
  end

  # --- 4. which process the crash-loop bound judges ----------------------
  describe 'the record the crash-loop bound consults' do
    include_context 'a scripted stdio session'

    before { stub_const('MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL', 0.05) }

    def open_subscription
      server.listen(notifications: { tools_list_changed: true })
    end

    # codex [P2] json_rpc_transport.rb:194-197: the record of the process that
    # last carried the subscriptions stayed on the transport after the refusal
    # had already closed them, so the next hand-over — of a subscription that
    # process never saw, opened on a replacement that ran healthily — was
    # judged by the corpse and refused as another crash loop.
    it 'does not judge a new subscription by the process that never carried it' do
      doomed = open_subscription
      server.send(:handle_server_exit)
      server.send(:handle_server_exit)
      expect(doomed).to be_closed

      fresh = open_subscription
      # The process it was opened on serves it for longer than the interval.
      sleep 0.1
      server.send(:handle_server_exit)

      expect(fresh).not_to be_closed
      expect(fresh.state).to eq(:pending)
      expect(listens.size).to eq(4)
      expect(listens.last['id']).not_to eq(listens[2]['id'])
    end
  end
end
