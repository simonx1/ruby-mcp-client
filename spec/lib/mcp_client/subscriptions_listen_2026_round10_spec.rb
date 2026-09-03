# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Review round 10 (codex, grok), on four things the earlier rounds left or
# built:
#
# * **the reader thread, blocked ahead of the queueing.** Round 3 moved the
#   subscription's listeners off the transport's reader precisely so one could
#   issue a request of its own. Rounds 6-8 then ordered the host's
#   `on_notification` callback ahead of the delivery, and that callback still
#   runs on the reader — so a host callback that makes a synchronous RPC
#   stalled the sole stdio reader *before* the subscription event was queued,
#   and the listeners waited on the very thread that had to answer it. The
#   delivery is now queued first and the host callback runs last.
#
# * **the queue of subscriptions waiting for a process.** A plain Array
#   `concat`ed from `cleanup` and `<<`ed from a deferred hand-over, with a
#   comment naming the race. Concurrent mutation of an Array is undefined in
#   MRI: the same window can drop a stream the spec says MUST be re-sent, or
#   queue it twice and send two listen requests for it.
#
# * **the listen ids a cancellation names.** `notifications/cancelled` named
#   only the id the subscription happened to be on, so a second listen written
#   for it on the same process stayed open on the server for ever.
#
# * **a mapped resource subscription that is discarded.** Only the URI mapping
#   was dropped, leaving a reconnectable stream nothing pointed at: it could
#   re-open and deliver the same updates beside its replacement, and
#   `unsubscribe_resource` could no longer find or cancel it.
#
# * **a listen POST answered with a temporary 5xx.** Classified transient, and
#   then used to finish the subscription for good — while a connection failure
#   or a timeout on the very same request re-opens it.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 10' do
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
  # an example can drive the lifecycle by hand.
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

    def cancellations
      written.select { |message| message['method'] == 'notifications/cancelled' }
    end

    def cancelled_ids
      cancellations.map { |message| message['params']['requestId'] }
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

  # --- 1. what the transport's reader thread waits for -------------------
  #
  # codex [P1] subscription_support.rb:128-129. The delivery is queued, never
  # run, on the routing thread — that is the whole point of the dispatcher —
  # so putting it ahead of the host callback costs nothing and takes the
  # reader out from behind host code that may block for as long as it likes.
  # Everything the earlier rounds established survives the move: the caches
  # are still dropped before any listener can run, and the callback still
  # cannot drop or redirect a delivery, now because the delivery has already
  # been made rather than because its target was resolved first.
  describe 'a host on_notification callback that blocks the reader' do
    include_context 'a scripted stdio session'

    def listen_line(id)
      JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                    'params' => { '_meta' => { sub_meta => id } })
    end

    it 'queues the subscription delivery before the callback runs' do
      release = Thread::Queue.new
      entered = Thread::Queue.new
      server.on_notification do |_method, _params|
        entered << :in
        # Stands for the synchronous RPC a host callback may make: on stdio
        # only this thread can read the response it waits for.
        release.pop
      end
      delivered = Thread::Queue.new
      subscription = server.listen(notifications: { tools_list_changed: true }) { |method, _p| delivered << method }

      reader = Thread.new { server.handle_line(listen_line(subscription.id)) }

      expect(delivered.pop(timeout: 3)).to eq('notifications/tools/list_changed')
      expect(entered.pop(timeout: 3)).to eq(:in)
      release << :go
      expect(reader.join(3)).to be_truthy
      subscription.close
    end

    it 'still delivers when the callback raises, and still runs it' do
      seen = []
      server.on_notification do |method, _params|
        seen << method
        raise 'host handler exploded'
      end
      delivered = Thread::Queue.new
      subscription = server.listen(notifications: { tools_list_changed: true }) { |method, _p| delivered << method }

      expect { server.handle_line(listen_line(subscription.id)) }.not_to raise_error

      expect(delivered.pop(timeout: 3)).to eq('notifications/tools/list_changed')
      expect(seen).to eq(['notifications/tools/list_changed'])
      subscription.close
    end

    # The callback is handed the very hash the delivery was routed by, and by
    # the time it can touch it the delivery has already been queued.
    it 'ignores a callback that deletes the subscription tag' do
      server.on_notification { |_method, params| params.delete('_meta') }
      delivered = Thread::Queue.new
      subscription = server.listen(notifications: { tools_list_changed: true }) { |method, _p| delivered << method }

      server.handle_line(listen_line(subscription.id))

      expect(delivered.pop(timeout: 3)).to eq('notifications/tools/list_changed')
      subscription.close
    end
  end

  describe 'the order routing puts the three steps in' do
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    it 'invalidates, delivers, then calls the host back' do
      order = []
      allow(server).to receive(:invalidate_cache_for_notification) { order << :transport_cache }
      allow(server).to receive(:deliver_subscription_notification) { order << :listeners }
      server.on_notification { |_method, _params| order << :host_callback }

      server.route_notification('notifications/tools/list_changed', {})

      expect(order).to eq(%i[transport_cache listeners host_callback])
    end

    # Round 6's guarantee, which the move must not weaken: a listener reacting
    # to a list_changed notification never reads the entry it says is stale.
    it 'still drops the caches before a listener can read them' do
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

      server.route_notification('notifications/tools/list_changed', { '_meta' => { sub_meta => 7 } })

      transport_cache, client_cache = seen.pop(timeout: 3)
      expect(transport_cache).to be_nil
      expect(client_cache).to be_empty
      subscription.finish
    end
  end

  # --- 2. the queue of subscriptions waiting for a process ---------------
  describe 'a cleanup that overlaps a deferred hand-over' do
    include_context 'a scripted stdio session'

    def open_subscription
      server.listen(notifications: { tools_list_changed: true })
    end

    # `cleanup` takes the registry snapshot, marks every subscription
    # reconnecting and only then writes them to the queue. The stub below runs
    # a deferred hand-over on another thread inside exactly that window, which
    # is the overlap the comment at json_rpc_transport.rb:125 named and tried
    # to paper over with an `equal?` scan of an Array two threads were
    # mutating. Concurrent `concat`/`<<` is undefined in MRI: the same window
    # can lose the entry (stranding a stream the spec says MUST be re-sent) or
    # duplicate it.
    def defer_during_cleanup(subscription)
      deferred = false
      allow(subscription).to receive(:mark_reconnecting).and_wrap_original do |original|
        original.call
        next if deferred

        deferred = true
        Thread.new do
          server.send(:defer_reestablished_attempt, subscription, subscription.id,
                      MCPClient::Errors::TransportError.new('Broken pipe'))
        end.join
      end
    end

    it 'queues the subscription exactly once' do
      subscription = open_subscription
      defer_during_cleanup(subscription)

      server.cleanup

      queued = server.instance_variable_get(:@reconnecting_subscriptions)
      expect(queued.count { |entry| entry.equal?(subscription) }).to eq(1)
      expect(subscription).to be_reconnecting
    end

    it 'sends one listen request to the process that replaces it' do
      subscription = open_subscription
      defer_during_cleanup(subscription)

      server.cleanup
      server.send(:restart_for_open_subscriptions)

      expect(listens.size).to eq(2)
      expect(listens.last['id']).not_to eq(listens.first['id'])
      expect(subscription.id).to eq(listens.last['id'])
    end
  end

  describe 'the listen ids a cancellation names' do
    include_context 'a scripted stdio session'

    # grok [2] server_stdio.rb:836-839: `cancel_subscription` named only
    # `subscription.id`, so a second listen written for the same subscription
    # on one process left the server holding the first stream with no
    # `notifications/cancelled` for it — the very thing the spec requires of a
    # client that stops reading a stream.
    it 'cancels every listen this client wrote for the subscription' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      first = listens.last['id']
      server.send(:open_subscription, subscription)
      second = listens.last['id']
      expect(second).not_to eq(first)

      subscription.close

      expect(cancelled_ids).to contain_exactly(first, second)
    end

    # ...and only those: an id written to a process that is gone is not
    # outstanding anywhere, and must not be cancelled on the one that
    # replaced it.
    it 'does not name a dead process\'s listen id on the process that replaced it' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      first = listens.last['id']
      server.send(:handle_server_exit)
      second = listens.last['id']
      expect(second).not_to eq(first)

      subscription.close

      expect(cancelled_ids).to eq([second])
    end

    it 'still cancels the one listen of an ordinary subscription exactly once' do
      subscription = server.listen(notifications: { tools_list_changed: true })

      subscription.close

      expect(cancelled_ids).to eq([listens.last['id']])
    end
  end

  # --- 3. a mapped resource subscription that is discarded ---------------
  describe 'a mapped resource subscription that never becomes a live watch' do
    include_context 'a scripted stdio session'

    let(:uri) { 'file:///watched.txt' }

    before do
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      # Nothing here waits on an acknowledgment that is not coming.
      allow(server).to receive(:subscription_ack_timeout).and_return(0)
    end

    def mapped_subscription
      subscription = MCPClient::Subscription.new(server: server, requested: { 'resourceSubscriptions' => [uri] })
      subscription.assign_id(11)
      server.register_subscription(subscription)
      server.route_notification('notifications/subscriptions/acknowledged',
                                { '_meta' => { sub_meta => 11 }, 'notifications' => {
                                  'resourceSubscriptions' => [uri]
                                } })
      server.subscriptions_mutex.synchronize { server.resource_subscriptions[uri] = subscription }
      subscription
    end

    # codex [P2] subscription_support.rb:293-295: dropping the mapping left a
    # stream that is still reconnectable and now unreachable — it can re-open
    # beside the replacement and deliver the same updates twice, and
    # `unsubscribe_resource`, which looks through the mapping, can no longer
    # close it.
    it 'closes and cancels the stream it discards' do
      subscription = mapped_subscription
      subscription.mark_reconnecting

      expect(server.send(:settled_resource_subscription, uri)).to be_nil

      expect(subscription).to be_closed
      expect(subscription).not_to be_reconnectable
      expect(server.resource_subscriptions).to be_empty
      expect(cancelled_ids).to eq([11])
    end

    it 'opens the replacement with the discarded stream already closed' do
      subscription = mapped_subscription
      subscription.mark_reconnecting
      allow(server).to receive(:send_request).and_wrap_original do |original, request|
        original.call(request)
        next unless request['method'] == 'subscriptions/listen'

        server.route_notification('notifications/subscriptions/acknowledged',
                                  { '_meta' => { sub_meta => request['id'] },
                                    'notifications' => { 'resourceSubscriptions' => [uri] } })
      end

      replacement = server.subscribe_resource_via_listen(uri)

      expect(replacement).not_to equal(subscription)
      expect(subscription).to be_closed
      expect(server.resource_subscriptions[uri]).to equal(replacement)
    end
  end

  # --- 4. a listen POST answered with a temporary 5xx --------------------
  describe 'a listen request the server answers with a 5xx' do
    let(:url) { 'https://example.com/mcp' }
    let(:requests) { [] }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp',
                                          retries: 0, read_timeout: 2)
    end

    before { stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 0.01) }

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

    # codex [P2] listen_stream.rb:340-343: `listen_rejection_error` already
    # calls a 5xx transient, and the call site then finished the subscription
    # and returned :closed, which the loop does not retry. A brief 503 killed
    # a long-lived subscription outright while a dropped socket re-opened it.
    it 're-opens the stream instead of ending the subscription' do
      answers = 0
      stub_listen do |body|
        answers += 1
        if answers == 1
          { status: 503, headers: { 'Content-Type' => 'application/json' }, body: 'upstream is restarting' }
        else
          sse_response(ack_message(body['id'], { 'toolsListChanged' => true }))
        end
      end

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.acknowledged }

      expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })
      expect(subscription.error).to be_nil
      expect(listen_count).to eq(2)
    end

    it 're-opens it through raise_error middleware too' do
      server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                                   faraday_config: ->(c) { c.response :raise_error })
      answers = 0
      stub_listen do |body|
        answers += 1
        if answers == 1
          { status: 500, headers: { 'Content-Type' => 'application/json' }, body: 'boom' }
        else
          sse_response(ack_message(body['id'], { 'toolsListChanged' => true }))
        end
      end

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.acknowledged }

      expect(subscription.error).to be_nil
      expect(listen_count).to eq(2)
      server.cleanup
    end

    # A 4xx is still the server refusing the subscription, and still ends it.
    it 'still fails the subscription on a 4xx' do
      stub_listen do |body|
        { status: 400, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                              'error' => { 'code' => -32_602, 'message' => 'unknown filter' }) }
      end

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.closed? }

      expect(subscription.error).to be_a(MCPClient::Errors::MCPError)
      expect(listen_count).to eq(1)
    end
  end
end
