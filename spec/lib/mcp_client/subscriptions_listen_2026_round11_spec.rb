# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'socket'
require 'stringio'

# Review round 11 (codex, grok), on the code round 10 left. Four races and
# omissions in the lifecycle bookkeeping, each pinned against the invariant:
#
# * **whose failure a failed listen write is** — asked and acted on in one
#   step. The ownership check and the transition it guarded were two locked
#   operations, and a restart could re-open the subscription under a new id
#   and have it acknowledged between them; the old attempt then closed the
#   healthy replacement.
# * **which request an acknowledgment deadline bounds.** The watchdog waited
#   on the mutable handle and expired whatever request it was on by then, so
#   a first request's timer closed the replacement a restart had issued,
#   naming the replacement and the wrong deadline; and an acknowledgment that
#   landed between the wait and the close was thrown away.
# * **a resource watch re-issued with no deadline.** `subscribe_resource`
#   opened its stream with `ack_timeout: false` so that its own synchronous
#   wait was the only deadline — and that setting disabled every watchdog a
#   restart or reconnect would otherwise arm, leaving a replacement nobody
#   acknowledged pending for ever while the host only waited for updates.
# * **a listen whose request could not be built.** Construction ran before
#   the subscription took its id, so a failure there compared the fresh id
#   against a still-nil one and was filed as a superseded attempt: `listen`
#   returned a pending handle with nothing written and no error.
#
# And the SHOULD grok found half-done: the acknowledged filter is checked
# against the requested one on every stream, not only the resource ones.

# A peer on a loopback socket, so the closing of the response stream — the
# cancellation signal on Streamable HTTP — is observed by the peer rather
# than inferred from Net::HTTP's bookkeeping.
class RoundElevenListenPeer
  attr_reader :port, :events

  # @yieldparam socket [TCPSocket] the listen stream, headers already sent
  # @yieldparam message [Hash] the listen request
  def initialize(&script)
    @script = script
    @events = Thread::Queue.new
    @listener = TCPServer.new('127.0.0.1', 0)
    @port = @listener.addr[1]
    @threads = []
    @thread = Thread.new { accept_loop }
  end

  def base_url
    "http://127.0.0.1:#{@port}"
  end

  def stop
    @thread.kill
    @threads.each(&:kill)
    @listener.close
  rescue IOError
    nil
  end

  private

  def accept_loop
    loop do
      socket = @listener.accept
      @threads << Thread.new { serve(socket) }
    end
  rescue StandardError
    nil
  end

  def serve(socket)
    return unless socket.gets

    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(':', 2)
      headers[name.downcase] = value.to_s.strip
    end
    message = JSON.parse(socket.read(headers['content-length'].to_i).to_s)
    if message['method'] == 'subscriptions/listen'
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n")
      socket.flush
      @script&.call(socket, message)
      # Read until the client closes the stream.
      socket.read
      @events << [:eof, message['id']]
    else
      result = { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                 'capabilities' => { 'tools' => { 'listChanged' => true },
                                     'resources' => { 'subscribe' => true, 'listChanged' => true } } }
      body = JSON.generate('jsonrpc' => '2.0', 'id' => message['id'], 'result' => result)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n#{body}")
    end
  rescue StandardError
    nil
  ensure
    socket.close unless socket.closed?
  end
end

RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 11' do
  def sub_meta
    'io.modelcontextprotocol/subscriptionId'
  end

  def discover_result(capabilities: { 'tools' => { 'listChanged' => true }, 'prompts' => { 'listChanged' => true },
                                      'resources' => { 'subscribe' => true, 'listChanged' => true } })
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => capabilities }
  end

  def ack_message(id, filter)
    { 'jsonrpc' => '2.0', 'method' => 'notifications/subscriptions/acknowledged',
      'params' => { '_meta' => { sub_meta => id }, 'notifications' => filter } }
  end

  def tagged(method, id, params = {})
    { 'jsonrpc' => '2.0', 'method' => method, 'params' => params.merge('_meta' => { sub_meta => id }) }
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise 'condition not met in time' unless yield
  end

  # A stdio transport whose process, handshake and writes are stubbed, so an
  # example can drive the lifecycle by hand. Writes go through the real
  # send_request to a recording stdin.
  shared_context 'a scripted stdio session' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }

    def install_stdin
      server.instance_variable_set(:@stdin, double('stdin', flush: nil, closed?: false, close: nil).tap do |handle|
        allow(handle).to receive(:puts) { |line| written << JSON.parse(line) }
      end)
    end

    def listens
      written.select { |message| message['method'] == 'subscriptions/listen' }
    end

    def cancelled_ids
      written.select { |message| message['method'] == 'notifications/cancelled' }
             .map { |message| message['params']['requestId'] }
    end

    def acknowledge(subscription, filter = subscription.requested)
      server.handle_line("#{JSON.generate(ack_message(subscription.id, filter))}\n")
    end

    # Acknowledge the first listen as it is written, and only that one.
    def acknowledge_first_listen
      acknowledged = false
      allow(server).to receive(:open_subscription).and_wrap_original do |original, subscription|
        original.call(subscription)
        next if acknowledged

        acknowledged = true
        acknowledge(subscription)
      end
    end

    before do
      allow(server).to receive(:connect) { install_stdin && true }
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      install_stdin
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      server.instance_variable_set(:@capabilities, discover_result['capabilities'])
      allow(server).to receive(:wait_response) do |id, **_options|
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => discover_result }
      end
    end
  end

  # A modern Streamable HTTP transport whose listen answers come from a block.
  shared_context 'a scripted HTTP session' do
    let(:url) { 'https://example.com/mcp' }
    let(:requests) { [] }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
    end

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
        requests << { headers: request.headers, body: body }
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'subscriptions/listen' then listen.call(body)
        else json_response(body['id'], {})
        end
      end
    end

    def listen_requests
      requests.select { |request| request[:body]['method'] == 'subscriptions/listen' }
    end
  end

  # --- 1. whose failure a failed listen write is ---------------------------
  describe 'a listen write whose failure lands after a restart re-opened and acknowledged the subscription' do
    include_context 'a scripted stdio session'

    # codex [P2] json_rpc_transport.rb:147: `open_as?(id)` and the transition
    # it guarded were separate locked operations. A restart re-opened the
    # subscription under a new id and had it acknowledged between them, and
    # the old attempt then finished the replacement — a closed handle carrying
    # "old pipe broke" beside a live registration nothing would cancel.
    it 'leaves the acknowledged replacement alone' do
      entered = Thread::Queue.new
      release = Thread::Queue.new
      failed = false
      allow(server).to receive(:send_request).and_wrap_original do |original, request, **options|
        if request['method'] == 'subscriptions/listen' && !failed
          failed = true
          written << request
          raise MCPClient::Errors::TransportError, 'old pipe broke'
        end
        original.call(request, **options)
      end
      # A barrier between the attempt's ownership check and its transition.
      allow(server).to receive(:unregister_subscription_id).and_wrap_original do |original, *args|
        entered << :in
        release.pop
        original.call(*args)
      end

      opened = nil
      failure = nil
      opener = Thread.new do
        opened = server.listen(notifications: { tools_list_changed: true })
      rescue StandardError => e
        failure = e
      end
      entered.pop(timeout: 3)

      # The process exits under the failing attempt; the restart re-sends the
      # subscription under a new id and the replacement acknowledges it.
      server.send(:handle_server_exit)
      subscription = server.subscriptions.values.first
      expect(subscription).not_to be_nil
      replacement = subscription.id
      acknowledge(subscription)
      expect(subscription).to be_active

      release << :go
      opener.join(3)

      expect(failure).to be_nil
      expect(opened).to equal(subscription)
      expect(subscription).to be_active
      expect(subscription.error).to be_nil
      expect(server.subscription_by_id(replacement)).to equal(subscription)
      expect(cancelled_ids).to be_empty
      expect(listens.size).to eq(2)
    end
  end

  # --- 2. which request an acknowledgment deadline bounds ------------------
  describe 'the acknowledgment deadline of a request that was replaced' do
    include_context 'a scripted stdio session'

    # codex [P2] subscription_support.rb:89: the watchdog waited on the
    # mutable handle. Request A (deadline 0.6s) was replaced after 0.2s by
    # request B with its own 0.6s deadline, and A's timer closed B at 0.6s —
    # naming B and a deadline B had not missed.
    it 'is retired with its request, and the replacement is bounded by its own deadline' do
      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.6)
      first = subscription.id
      sleep 0.2
      server.send(:handle_server_exit)
      second = subscription.id
      expect(second).not_to eq(first)

      # A's deadline has passed; B's has not.
      sleep 0.5
      expect(subscription).not_to be_closed

      expect(subscription.wait_until_settled(5)).to eq(:closed)
      expect(subscription.error).to be_a(MCPClient::Errors::RequestTimeoutError)
      expect(subscription.error.message).to include(second.to_s)
      expect(cancelled_ids).to eq([second])
    end

    it 'does not expire a subscription that has moved to a newer listen id' do
      subscription = MCPClient::Subscription.new(server: server, requested: { 'toolsListChanged' => true })
      subscription.assign_id(1)
      watchdog = server.await_acknowledgment_deadline(subscription, 0.05)
      subscription.with_open_id(2) { nil }

      watchdog.join(3)

      expect(subscription).not_to be_closed
      expect(cancelled_ids).to be_empty
    end

    # The race between `wait_until_settled` returning nil and `finish`: an
    # acknowledgment that lands in that window is the server's answer, and
    # expiring the request anyway threw it away.
    it 'keeps a subscription the server acknowledged just as its deadline expired' do
      subscription = MCPClient::Subscription.new(server: server, requested: { 'toolsListChanged' => true })
      subscription.assign_id(7)
      subscription.record_outstanding_listen(7)
      subscription.mark_listen_written(7)
      server.register_subscription(subscription)
      allow(subscription).to receive(:wait_until_settled).and_wrap_original do |original, *args|
        original.call(*args)
        subscription.acknowledge({ 'toolsListChanged' => true })
        nil
      end

      server.await_acknowledgment_deadline(subscription, 0.01).join(3)

      expect(subscription).to be_active
      expect(subscription.error).to be_nil
      expect(cancelled_ids).to be_empty
    end
  end

  # --- 3. a resource watch re-issued with no deadline ----------------------
  describe 'a resource watch whose replacement is never acknowledged' do
    include_context 'a scripted stdio session'

    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 0.3) }
    let(:uri) { 'file:///watched.txt' }

    # codex [P2] subscription_support.rb:505: `ack_timeout: false` disabled
    # every later watchdog too. A host merely waiting for updates was never
    # told the replacement had gone unanswered.
    it 'ends the handle within the read timeout and cancels the request' do
      acknowledge_first_listen
      expect(server.subscribe_resource(uri)).to be(true)
      subscription = server.resource_subscriptions[uri]
      first = subscription.id
      expect(subscription).to be_active

      server.send(:handle_server_exit)
      second = listens.last['id']
      expect(second).not_to eq(first)

      expect(subscription.wait_until_settled(5)).to eq(:closed)
      expect(subscription.error).to be_a(MCPClient::Errors::RequestTimeoutError)
      expect(subscription.error.message).to include(second.to_s)
      expect(cancelled_ids).to eq([second])
      expect(server.resource_subscriptions).to be_empty
    end

    # The synchronous wait `subscribe_resource` does is still the caller's own
    # answer: a first stream nobody acknowledges is reported by it, on its
    # timeout, not through a handle a watchdog closed under it.
    it 'still reports a first stream nobody acknowledges as the subscriber\'s own timeout' do
      expect { server.subscribe_resource(uri) }
        .to raise_error(MCPClient::Errors::ResourceReadError, /timed out after 0.3s/)
      expect(cancelled_ids).to eq([listens.last['id']])
    end
  end

  # --- 4. a listen whose request could not be built ------------------------
  describe 'a listen whose request could not be built' do
    include_context 'a scripted stdio session'

    # codex [P2] json_rpc_transport.rb:81: construction ran before the
    # subscription took its id, so the failure compared the fresh id with a
    # nil one and was filed as a superseded attempt — `listen` returned a
    # pending handle with nothing written and no error.
    it 'is reported to the caller, with nothing registered or written' do
      server.request_meta = -> { raise 'metadata unavailable' }

      expect { server.listen(notifications: { tools_list_changed: true }) }
        .to raise_error(MCPClient::Errors::TransportError, /metadata unavailable/)
      expect(server.subscriptions).to be_empty
      expect(listens).to be_empty
    end

    # codex round 5 [P2]: a hand-over whose request could not even be built was
    # put back on the queue "for the next process" — but the process it was
    # being handed to is healthy, so no next process was coming: the
    # subscription stayed :reconnecting for ever, its previous acknowledgment
    # keeping the watchdog from expiring it, and the host was never told. A
    # failure before the request took an id says nothing about the process;
    # it is the subscription's own, and the subscription ends with it.
    it 'ends a subscription whose re-issued request could not be built, so the host is told' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      acknowledge(subscription)
      # Only the listen's own construction fails: a provider that raised for
      # every request would take the restart's server/discover down with it.
      allow(server).to receive(:build_jsonrpc_request).and_wrap_original do |original, method, *rest|
        raise 'metadata unavailable' if method == 'subscriptions/listen'

        original.call(method, *rest)
      end

      server.send(:handle_server_exit)

      expect(subscription).to be_closed
      expect(subscription.error).to be_a(MCPClient::Errors::TransportError)
      expect(subscription.error.message).to include('metadata unavailable')
      expect(server.reconnecting_subscriptions).to be_empty
      expect(server.subscriptions).to be_empty
      expect(listens.size).to eq(1)
    end

    it 'still leaves a hand-over whose write failed for the next process' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      allow(server).to receive(:send_request).and_wrap_original do |original, request, **options|
        raise Errno::EPIPE if request['method'] == 'subscriptions/listen' && listens.size >= 1

        original.call(request, **options)
      end

      server.send(:handle_server_exit)

      expect(subscription).not_to be_closed
      expect(subscription).to be_reconnecting
      expect(server.reconnecting_subscriptions).to include(subscription)
    end
  end

  # --- 5. every open subscription is re-sent ------------------------------
  describe 'a restart with several subscriptions open' do
    include_context 'a scripted stdio session'

    it 're-sends every live one under a fresh id, none the host closed, and delivers on the new ids' do
      tools = server.listen(notifications: { tools_list_changed: true })
      prompts = server.listen(notifications: { prompts_list_changed: true })
      closed = server.listen(notifications: { resources_list_changed: true })
      closed.close
      old_ids = [tools.id, prompts.id]

      server.send(:handle_server_exit)

      reissued = listens.drop(3)
      expect(reissued.map { |message| message['params']['notifications'] })
        .to contain_exactly({ 'toolsListChanged' => true }, { 'promptsListChanged' => true })
      expect(reissued.map { |message| message['id'] }).to contain_exactly(tools.id, prompts.id)
      expect([tools.id, prompts.id] & old_ids).to be_empty
      expect(closed).to be_closed

      received = Thread::Queue.new
      tools.on_notification { |method, _params| received << [:tools, method] }
      prompts.on_notification { |method, _params| received << [:prompts, method] }
      server.handle_line("#{JSON.generate(tagged('notifications/tools/list_changed', tools.id))}\n")
      server.handle_line("#{JSON.generate(tagged('notifications/prompts/list_changed', prompts.id))}\n")
      # A notification tagged with an id the restart retired reaches nobody.
      server.handle_line("#{JSON.generate(tagged('notifications/tools/list_changed', old_ids.first))}\n")

      expect(received.pop(timeout: 3)).to eq([:tools, 'notifications/tools/list_changed'])
      expect(received.pop(timeout: 3)).to eq([:prompts, 'notifications/prompts/list_changed'])
      sleep 0.05
      expect(received).to be_empty
    end

    it 'cancels one of two live streams without touching the other' do
      first = server.listen(notifications: { tools_list_changed: true })
      second = server.listen(notifications: { prompts_list_changed: true })

      first.close

      expect(cancelled_ids).to eq([first.id])
      expect(second).not_to be_closed
      expect(server.subscription_by_id(second.id)).to equal(second)
    end
  end

  # --- 6. an unsubscribe racing the acknowledgment -------------------------
  describe 'an unsubscribe that races the acknowledgment of the subscribe' do
    include_context 'a scripted stdio session'

    let(:uri) { 'file:///watched.txt' }

    it 'waits for the mapping, then cancels the stream and leaves nothing behind' do
      entered = Thread::Queue.new
      release = Thread::Queue.new
      allow(server).to receive(:open_subscription).and_wrap_original do |original, subscription|
        original.call(subscription)
        entered << :in
        release.pop
        acknowledge(subscription)
      end

      subscriber = Thread.new { server.subscribe_resource(uri) }
      entered.pop(timeout: 3)
      unsubscriber = Thread.new { server.unsubscribe_resource(uri) }
      sleep 0.05
      expect(unsubscriber).to be_alive

      release << :go
      expect(subscriber.join(3)&.value).to be(true)
      unsubscriber.join(3)

      expect(server.resource_subscriptions).to be_empty
      expect(server.subscriptions).to be_empty
      expect(cancelled_ids).to eq([listens.last['id']])
    end
  end

  # --- 7. listener isolation ----------------------------------------------
  describe 'a subscription listener that raises' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'does not stop the other listeners or the notifications queued after it' do
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |_method, _params|
        raise 'listener one exploded'
      end
      seen = Thread::Queue.new
      subscription.on_notification { |method, _params| seen << method }
      subscription.assign_id(1)

      subscription.deliver('notifications/tools/list_changed', {})
      subscription.deliver('notifications/prompts/list_changed', {})

      expect(seen.pop(timeout: 3)).to eq('notifications/tools/list_changed')
      expect(seen.pop(timeout: 3)).to eq('notifications/prompts/list_changed')
      subscription.finish
    end
  end

  # --- 8. the client caches a listener may read ---------------------------
  describe 'the client prompt and resource caches' do
    include_context 'a scripted stdio session'

    let(:client) do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'echo test' }])
    end

    def registered_subscription(&listener)
      subscription = MCPClient::Subscription.new(server: server, requested: {}, &listener)
      subscription.assign_id(11)
      server.register_subscription(subscription)
      subscription
    end

    it 'are gone before a subscription listener sees the list_changed notification' do
      client.prompt_cache['server'] = ['a prompt']
      client.resource_cache['server'] = ['a resource']
      seen = Thread::Queue.new
      subscription = registered_subscription do |method, _params|
        seen << [method, client.prompt_cache.dup, client.resource_cache.dup]
      end

      server.route_notification('notifications/prompts/list_changed', { '_meta' => { sub_meta => 11 } })
      expect(seen.pop(timeout: 5)).to eq(['notifications/prompts/list_changed', {}, { 'server' => ['a resource'] }])

      server.route_notification('notifications/resources/list_changed', { '_meta' => { sub_meta => 11 } })
      expect(seen.pop(timeout: 5)).to eq(['notifications/resources/list_changed', {}, {}])
      subscription.finish
    end

    it 'are dropped by an untagged notification too, through the host callback path' do
      client.prompt_cache['server'] = ['a prompt']
      client.resource_cache['server'] = ['a resource']

      server.route_notification('notifications/prompts/list_changed', {})
      expect(client.prompt_cache).to be_empty
      expect(client.resource_cache).not_to be_empty

      server.route_notification('notifications/resources/list_changed', {})
      expect(client.resource_cache).to be_empty
    end
  end

  # --- 9. the acknowledged filter is checked (grok) -------------------------
  describe 'a listen acknowledged with a subset of the flags it asked for' do
    include_context 'a scripted stdio session'

    # grok [1] subscription_support.rb:37-49: "the client SHOULD check the
    # acknowledged filter against what it requested and handle any
    # unsupported types gracefully". The URIs were checked
    # (subscribe_resource fails closed); the flags of a plain `listen` were
    # not so much as logged.
    it 'is active, reports the declined types, and says so in the log' do
      output = StringIO.new
      server.instance_variable_set(:@logger, Logger.new(output))
      subscription = server.listen(notifications: { tools_list_changed: true, prompts_list_changed: true })

      acknowledge(subscription, { 'toolsListChanged' => true })

      expect(subscription).to be_active
      expect(subscription.unsupported).to eq(['promptsListChanged'])
      expect(output.string).to match(/subscription #{subscription.id}.*promptsListChanged/)
    end

    it 'logs nothing when the whole filter was granted' do
      output = StringIO.new
      server.instance_variable_set(:@logger, Logger.new(output))
      subscription = server.listen(notifications: { tools_list_changed: true })

      acknowledge(subscription)

      expect(subscription.unsupported).to be_empty
      expect(output.string).not_to match(/declined|not acknowledged|unsupported/i)
    end
  end

  # --- 10. a listen response arriving after close (grok) ---------------------
  describe 'a response to a listen request the host has already closed' do
    include_context 'a scripted stdio session'

    it 'is ignored: the handle stays closed by the client, with no error' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      id = subscription.id
      subscription.close

      handled = server.handle_subscription_response({ 'jsonrpc' => '2.0', 'id' => id,
                                                      'error' => { 'code' => -32_602, 'message' => 'late' } })
      closing = { 'jsonrpc' => '2.0', 'id' => id, 'result' => { 'resultType' => 'complete' } }
      server.handle_line("#{JSON.generate(closing)}\n")

      expect(handled).to be_nil
      expect(subscription).to be_closed_by_client
      expect(subscription).not_to be_closed_gracefully
      expect(subscription.error).to be_nil
    end
  end

  # --- 11. transports and eras that refuse listen (grok) ---------------------
  describe 'the transports and eras that refuse subscriptions/listen' do
    it 'is refused by the deprecated HTTP+SSE transport' do
      sse = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
      allow(sse).to receive(:ensure_connected)

      expect { sse.listen(notifications: { tools_list_changed: true }) }
        .to raise_error(MCPClient::Errors::CapabilityError, /2026-07-28/)
    end

    it 'is refused by a stdio transport in :auto mode whose server negotiated 2025-11-25' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: false, close: nil))

      expect(server.protocol_mode).to eq(:auto)
      expect { server.listen(notifications: { tools_list_changed: true }) }
        .to raise_error(MCPClient::Errors::CapabilityError, /2025-11-25/)
    end

    it 'gates resource subscriptions on the resources.subscribe capability on Streamable HTTP' do
      url = 'https://example.com/mcp'
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << body
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                              'result' => discover_result(capabilities: { 'resources' => { 'listChanged' => true } })) }
      end
      server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)

      expect { server.subscribe_resource('file:///a') }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(sent.map { |message| message['method'] }).not_to include('subscriptions/listen', 'resources/subscribe')
      server.cleanup
    end
  end

  # --- 12. the Client wrapper ----------------------------------------------
  describe 'Client#listen' do
    include_context 'a scripted stdio session'

    # codex round 13: with one server, always choosing the first would have
    # satisfied this example; the selector is pinned against two.
    it 'forwards the server selector, the deadline and the listener' do
      other = MCPClient::ServerStdio.new(command: 'echo other', read_timeout: 1)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(other, server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'echo other', name: 'zero' },
                                                          { type: 'stdio', command: 'echo test', name: 'one' }])
      allow(other).to receive(:name).and_return('zero')
      allow(server).to receive(:name).and_return('one')
      expect(other).not_to receive(:listen)
      listener = proc {}
      expect(server).to receive(:listen).with(notifications: { tools_list_changed: true }, ack_timeout: 0.5) do |&block|
        expect(block).to equal(listener)
        :handle
      end

      expect(client.listen(notifications: { tools_list_changed: true }, server: 'one', ack_timeout: 0.5,
                           &listener)).to eq(:handle)
      expect { client.listen(notifications: { tools_list_changed: true }, server: 'two') }
        .to raise_error(MCPClient::Errors::ServerNotFound)
    end
  end

  # --- 13. the stream parser at chunk boundaries ---------------------------
  describe 'the listen stream parser' do
    include_context 'a scripted HTTP session'

    def routed_events
      routed = []
      allow(server).to receive(:route_notification) { |method, params| routed << [method, params] }
      routed
    end

    it 'keeps an event whose CRLF terminator arrives split across chunks' do
      subscription = MCPClient::Subscription.new(server: server, requested: {})
      subscription.assign_id(9)
      routed = routed_events
      event = JSON.generate(tagged('notifications/resources/updated', 9, 'uri' => 'file:///a'))
      buffer = +''
      state = { scanned: 0 }

      server.send(:consume_listen_events, buffer << "data: #{event}\r", subscription, state)
      expect(routed).to be_empty
      server.send(:consume_listen_events, buffer << "\n\r\n", subscription, state)

      expect(routed.map(&:first)).to eq(['notifications/resources/updated'])
    end

    it 'keeps an event split inside a multibyte character, delivered as the binary chunks a socket yields' do
      subscription = MCPClient::Subscription.new(server: server, requested: {})
      subscription.assign_id(9)
      routed = routed_events
      event = "data: #{JSON.generate(tagged('notifications/resources/updated', 9, 'uri' => 'file:///café'))}\n\n".b
      cut = event.index("\xC3".b) + 1 # inside the two bytes of "é"
      buffer = +''
      state = { scanned: 0 }

      server.send(:consume_listen_events, buffer << event.byteslice(0, cut), subscription, state)
      expect(routed).to be_empty
      server.send(:consume_listen_events, buffer << event.byteslice(cut..), subscription, state)

      expect(routed.map(&:first)).to eq(['notifications/resources/updated'])
      expect(routed.first.last['uri']).to eq('file:///café')
    end
  end

  # --- 14. a reconnect after a real connection failure ----------------------
  describe 'a stream whose re-open fails at the connection' do
    include_context 'a scripted HTTP session'

    # codex round 13: the maximum delay is pinned too — removing the clamp
    # used to leave the first two delays, and this example, untouched.
    it 'backs off with growing delays up to the maximum and re-issues once the connection is back' do
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 0.01)
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_MAX_RECONNECT_DELAY', 0.03)
      posts = 0
      stub_listen do |body|
        posts += 1
        raise Errno::ECONNRESET, 'peer went away' if posts <= 4

        sse_response(ack_message(body['id'], { 'toolsListChanged' => true }))
      end
      delays = []
      allow(server).to receive(:wait_before_reopen).and_wrap_original do |original, subscription, delay|
        delays << delay
        original.call(subscription, delay)
      end

      subscription = server.listen(notifications: { tools_list_changed: true })

      expect(subscription.wait_until_settled(5)).to eq(:active)
      expect(listen_requests.map { |request| request[:body]['id'] }.uniq.size).to eq(5)
      expect(delays.first(4)).to eq([0.01, 0.02, 0.03, 0.03])
    end
  end

  # --- 15. two streams at once, and no GET (grok) --------------------------
  describe 'two listen streams on one Streamable HTTP transport' do
    include_context 'a scripted HTTP session'

    it 'are distinct requests, each delivered its own notifications, and open no GET stream' do
      stub_listen do |body|
        filter = body['params']['notifications']
        kind = filter.key?('toolsListChanged') ? 'tools' : 'prompts'
        method = "notifications/#{kind}/list_changed"
        sse_response(ack_message(body['id'], filter), tagged(method, body['id']),
                     { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'resultType' => 'complete' } })
      end
      received = Thread::Queue.new

      tools = server.listen(notifications: { tools_list_changed: true }) { |method, _p| received << [:tools, method] }
      prompts = server.listen(notifications: { prompts_list_changed: true }) do |method, _p|
        received << [:prompts, method]
      end

      wait_until { tools.closed? && prompts.closed? }
      expect(tools).to be_closed_gracefully
      expect(prompts).to be_closed_gracefully
      expect(listen_requests.map { |request| request[:body]['id'] }.uniq.size).to eq(2)
      deliveries = [received.pop(timeout: 3), received.pop(timeout: 3)]
      expect(deliveries).to contain_exactly([:tools, 'notifications/tools/list_changed'],
                                            [:prompts, 'notifications/prompts/list_changed'])
      expect(a_request(:get, url)).not_to have_been_made
    end
  end

  # --- 16. over a real socket -----------------------------------------------
  describe 'a listen stream over a real socket' do
    # WebMock is switched off, not merely opened: spec_helper's catch-all
    # stub answers every server/discover probe with a 404, and a stub wins
    # over an allowed connection, so the probe would never reach the peer.
    before { WebMock.disable! }

    # WebMock is restored whatever the fixtures do: a `peer` that failed to
    # construct would fail again here, and every mocked example after this
    # one would then try a real connection.
    after do
      server&.cleanup
      peer&.stop
    ensure
      WebMock.enable!
      WebMock.disable_net_connect!(allow_localhost: true)
    end

    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: peer.base_url, endpoint: '/mcp', retries: 0, read_timeout: 5)
    end

    def sse_event(payload)
      "event: message\ndata: #{JSON.generate(payload)}\n\n"
    end

    context 'when the acknowledgment deadline expires' do
      let(:peer) { RoundElevenListenPeer.new { |_socket, _message| nil } }

      it 'closes the response stream, and the peer sees EOF' do
        subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.3)

        expect(subscription.wait_until_settled(10)).to eq(:closed)
        expect(subscription.error).to be_a(MCPClient::Errors::RequestTimeoutError)
        expect(peer.events.pop(timeout: 5)).to eq([:eof, subscription.id])
      end
    end

    context 'when the host closes the subscription' do
      let(:peer) do
        RoundElevenListenPeer.new do |socket, message|
          socket.write(sse_event(ack_message(message['id'], message['params']['notifications'])))
          socket.flush
          # An update split inside a multibyte character, as a socket may
          # deliver it.
          event = sse_event(tagged('notifications/resources/updated', message['id'], 'uri' => 'file:///café')).b
          cut = event.index("\xC3".b) + 1
          socket.write(event.byteslice(0, cut))
          socket.flush
          sleep 0.05
          socket.write(event.byteslice(cut..))
          socket.flush
        end
      end

      it 'delivers what arrived in pieces, then closes the stream so the peer sees EOF' do
        received = Thread::Queue.new
        subscription = server.listen(notifications: { resource_subscriptions: ['file:///café'] }) do |method, params|
          received << [method, params['uri']]
        end

        expect(subscription.wait_until_settled(10)).to eq(:active)
        expect(received.pop(timeout: 5)).to eq(['notifications/resources/updated', 'file:///café'])
        subscription.close
        expect(peer.events.pop(timeout: 5)).to eq([:eof, subscription.id])
      end
    end
  end
end
