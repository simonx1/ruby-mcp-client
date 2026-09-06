# frozen_string_literal: true

require 'spec_helper'

# Review round 14 (codex, grok). Four things a subscription's lifetime turns
# on: the open subscriptions of a process that exited reach the replacement
# however the two threads interleave; the acknowledgment watchdog measures a
# request that is actually in flight; an SSE stream that opens with a byte
# order mark is still read; and a JSON-RPC id of the wrong type is a
# different id, on the acknowledgment and delivery paths as it already is on
# the cancellation one.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 14' do
  def sub_meta
    'io.modelcontextprotocol/subscriptionId'
  end

  def discover_result(capabilities: { 'tools' => { 'listChanged' => true },
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

  # A stdio transport whose process, handshake and writes are all stubbed, so
  # an example can drive the restart lifecycle by hand.
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

    def acknowledge(subscription, filter = subscription.requested)
      server.handle_line("#{JSON.generate(ack_message(subscription.id, filter))}\n")
    end

    before do
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@transport_generation,
                                     server.instance_variable_get(:@transport_generation).to_i + 1)
        install_stdin
      end
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      allow(server).to receive(:terminate_server_process)
      allow(server).to receive(:negotiate_protocol) do
        server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
        server.instance_variable_set(:@capabilities, discover_result['capabilities'])
      end
      install_stdin
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      server.instance_variable_set(:@capabilities, discover_result['capabilities'])
      server.instance_variable_set(:@initialized, true)
    end

    after do
      server.instance_variable_set(:@reconnecting_subscriptions, [])
      server.cleanup
    rescue StandardError
      nil
    end
  end

  # --- 1. the replacement is established before the old process is parked ---
  describe 'a stdio exit whose subscriptions are parked after the replacement is up' do
    include_context 'a scripted stdio session'

    # codex [P1] server_stdio.rb: the reader claimed the dead transport and
    # then paused before parking its subscriptions. A host request observed
    # the retirement, established the replacement and re-sent what was on the
    # reconnect queue — nothing, because the reader had not parked yet. The
    # reader then parked, and its own `restart_for_open_subscriptions` found
    # the transport already initialized and returned without sending
    # anything: the replacement never received the listen, and the
    # subscription stayed :reconnecting for good.
    it 're-sends them to the replacement the host established meanwhile' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      acknowledge(subscription)
      expect(subscription).to be_active
      old_stdin = server.instance_variable_get(:@stdin)

      entered = Thread::Queue.new
      release = Thread::Queue.new
      # The reader is held between claiming the dead transport and parking
      # the subscriptions that were open on it. Only the first teardown is
      # held: the example's own cleanup runs one too.
      held = false
      allow(server).to receive(:park_open_subscriptions).and_wrap_original do |original, *args|
        unless held
          held = true
          entered << true
          release.pop
        end
        original.call(*args)
      end

      reader = Thread.new { server.send(:handle_server_exit) }
      entered.pop

      # The host request gets there first: it releases the dead handles,
      # spawns the replacement and finds an empty reconnect queue.
      server.send(:ensure_initialized)
      replacement = server.instance_variable_get(:@stdin)
      expect(replacement).not_to equal(old_stdin)
      expect(listens.size).to eq(1)

      release << true
      reader.join(5)

      # Whichever of the two ran last, the subscription the host still wants
      # is on the replacement (basic/patterns/subscriptions: after a stdio
      # reconnect the client MUST re-send subscriptions/listen).
      expect(listens.size).to eq(2)
      expect(listens.last['id']).to eq(subscription.id)
      expect(server.send(:reconnecting_subscriptions)).to be_empty
      acknowledge(subscription)
      expect(subscription).to be_active
      expect(subscription).not_to be_closed
    end

    # The ordinary interleaving still works the way it did: the reader parks
    # first and the host's own negotiation re-sends them.
    it 'still re-sends them when the parking happens before the replacement' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      acknowledge(subscription)

      server.send(:handle_server_exit)

      expect(listens.size).to eq(2)
      expect(listens.last['id']).to eq(subscription.id)
      expect(server.send(:reconnecting_subscriptions)).to be_empty
    end
  end

  # --- 2. the acknowledgment watchdog and a subscription between requests ---
  describe 'the acknowledgment deadline of a subscription that is reconnecting' do
    include_context 'a scripted stdio session'

    # grok: the deadline is armed on the listen id that went out. Once that
    # request has ended and the transport is waiting to send the next one
    # (`mark_reconnecting`), nothing is in flight for the watchdog to expire —
    # but :reconnecting is not a settled state, so it closed the handle with
    # `by_client: true`, which also makes it unreconnectable. On HTTP the
    # default ack timeout and the maximum backoff are both the read timeout,
    # so a run of 5xx answers ends the subscription instead of re-POSTing;
    # on stdio a spawn slower than the remaining deadline skips the MUST
    # re-send.
    it 'is not expired while the transport is between requests' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      id = subscription.id
      subscription.mark_reconnecting

      expired = subscription.expire_unanswered(id, MCPClient::Errors::RequestTimeoutError.new('too slow'))

      expect(expired).to be_nil
      expect(subscription).not_to be_closed
      expect(subscription).to be_reconnectable
    end

    # The deadline still does its job on the request that is actually out.
    it 'still expires a listen that is in flight and unanswered' do
      subscription = server.listen(notifications: { tools_list_changed: true })

      expired = subscription.expire_unanswered(subscription.id,
                                               MCPClient::Errors::RequestTimeoutError.new('too slow'))

      expect(expired).to eq(:expired)
      expect(subscription).to be_closed
    end

    # And an acknowledged stream is untouched by the deadline of the id it
    # was acknowledged on, however long the next reconnect takes.
    it 'leaves an acknowledged subscription alone' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      acknowledge(subscription)
      id = subscription.id
      subscription.mark_reconnecting

      expect(subscription.expire_unanswered(id, MCPClient::Errors::RequestTimeoutError.new('too slow'))).to be_nil
      expect(subscription).not_to be_closed
    end
  end

  # --- 2b. the same hole, end to end on each transport ----------------------
  describe 'a run of listen requests the server drops' do
    let(:url) { 'https://example.com/mcp' }
    let(:requests) { [] }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp',
                                          retries: 0, read_timeout: 2)
    end

    before do
      # The backoff climbs to its maximum in a few attempts, and the maximum
      # is the acknowledgment deadline — the shape the defaults have, where
      # both are the read timeout.
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 0.02)
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_MAX_RECONNECT_DELAY', 0.08)
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

    # grok: with the defaults the maximum backoff and the acknowledgment
    # deadline are the same number, so a server answering 503 for long enough
    # put the watchdog's expiry inside a wait between requests. It closed the
    # handle `by_client` — unreconnectable — while the client was about to
    # POST again, and the host was unsubscribed from a server that had never
    # refused anything.
    it 'keeps re-issuing once the backoff has grown past the acknowledgment deadline' do
      answers = 0
      stub_listen do |body|
        answers += 1
        if answers <= 4
          { status: 503, headers: { 'Content-Type' => 'application/json' }, body: 'upstream is restarting' }
        else
          sse_response(ack_message(body['id'], { 'toolsListChanged' => true }))
        end
      end

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.05)
      wait_until { subscription.acknowledged }

      expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })
      expect(subscription).not_to be_closed
      expect(subscription.error).to be_nil
      expect(listen_count).to eq(5)
    end
  end

  describe 'a stdio restart slower than the acknowledgment deadline' do
    include_context 'a scripted stdio session'

    # The stdio side of the same hole: an unacknowledged listen whose process
    # dies is parked :reconnecting on its old id, and a spawn slower than the
    # remaining deadline used to expire it — skipping the re-send that
    # basic/patterns/subscriptions requires after a reconnect.
    it 'still re-sends the listen the dead process never acknowledged' do
      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.05)
      expect(subscription).not_to be_active
      first_id = subscription.id

      # The spawn and handshake take longer than the deadline the first
      # listen was armed with, all of it spent parked :reconnecting.
      allow(server).to receive(:negotiate_protocol) do
        sleep 0.15
        server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
        server.instance_variable_set(:@capabilities, discover_result['capabilities'])
      end

      server.send(:handle_server_exit)

      expect(subscription).not_to be_closed
      expect(listens.size).to eq(2)
      expect(listens.last['id']).not_to eq(first_id)
      acknowledge(subscription)
      expect(subscription).to be_active
    end
  end

  # --- 2c. a listen refused for the protocol version ------------------------
  describe 'a listen the server refuses with -32022' do
    let(:url) { 'https://example.com/mcp' }
    let(:requests) { [] }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp',
                                          retries: 0, read_timeout: 2)
    end

    before { stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 0.01) }

    after { server.cleanup }

    def version_rejection(id)
      { status: 400, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate('jsonrpc' => '2.0', 'id' => id,
                            'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                         'data' => { 'supported' => ['2026-11-25'],
                                                     'requested' => '2026-07-28' } }) }
    end

    def listen_count
      requests.count { |body| body['method'] == 'subscriptions/listen' }
    end

    # Listen has request and error paths of its own, so the typed version
    # error the ordinary RPC tests pin says nothing about it. A rejection is
    # an answer, not a drop: the subscription ends carrying what the server
    # said it supports, rather than being re-opened for ever.
    it 'ends the subscription with the versions the server named' do
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << body
        if body['method'] == 'subscriptions/listen'
          version_rejection(body['id'])
        else
          { status: 200, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result) }
        end
      end

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.closed? }

      expect(subscription.error).to be_a(MCPClient::Errors::UnsupportedProtocolVersionError)
      expect(subscription.error.supported).to eq(['2026-11-25'])
      expect(subscription).not_to be_closed_gracefully
      sleep 0.05
      expect(listen_count).to eq(1)
    end
  end

  describe 'a stdio listen refused with -32022' do
    include_context 'a scripted stdio session'

    it 'ends the subscription with the versions the server named' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      server.handle_line("#{JSON.generate('jsonrpc' => '2.0', 'id' => subscription.id,
                                          'error' => { 'code' => -32_022,
                                                       'message' => 'Unsupported protocol version',
                                                       'data' => { 'supported' => ['2026-11-25'] } })}\n")

      wait_until { subscription.closed? }
      expect(subscription.error).to be_a(MCPClient::Errors::UnsupportedProtocolVersionError)
      expect(subscription.error.supported).to eq(['2026-11-25'])
      expect(listens.size).to eq(1)
    end
  end

  # --- 3. the listen stream parser and a byte order mark --------------------
  describe 'a listen stream that opens with a byte order mark' do
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
    end

    after { server.cleanup }

    def subscription_with_id(id)
      MCPClient::Subscription.new(server: server, requested: { 'toolsListChanged' => true }).tap do |subscription|
        subscription.assign_id(id)
        server.send(:register_subscription, subscription)
      end
    end

    def routed_events
      routed = []
      allow(server).to receive(:route_notification).and_wrap_original do |original, method, params|
        routed << [method, params]
        original.call(method, params)
      end
      routed
    end

    # codex [P2] listen_stream.rb: the data lines are picked with
    # `start_with?('data:')`, so a leading BOM — which the SSE processing
    # model says to strip — left every line of the first event unmatched and
    # the whole acknowledgment was dropped. The stream stayed open and its
    # subscription unacknowledged, so the watchdog cancelled it.
    it 'reads the acknowledgment that follows the mark' do
      subscription = subscription_with_id(9)
      routed_events
      event = "\xEF\xBB\xBF".b + "data: #{JSON.generate(ack_message(9, 'toolsListChanged' => true))}\n\n".b

      server.send(:consume_listen_events, +'' << event, subscription, { scanned: 0 })

      expect(subscription).to be_active
      expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })
    end

    it 'reads it when the mark itself arrives split across chunks' do
      subscription = subscription_with_id(9)
      routed_events
      event = "\xEF\xBB\xBF".b + "data: #{JSON.generate(ack_message(9, 'toolsListChanged' => true))}\n\n".b
      buffer = +''
      state = { scanned: 0 }

      server.send(:consume_listen_events, buffer << event.byteslice(0, 2), subscription, state)
      expect(subscription).not_to be_active
      server.send(:consume_listen_events, buffer << event.byteslice(2..), subscription, state)

      expect(subscription).to be_active
    end

    # The mark is stripped once, at the head of the stream: the bytes are not
    # a data line and must not be mistaken for one anywhere else.
    it 'delivers the notifications that follow it' do
      subscription = subscription_with_id(9)
      routed = routed_events
      stream = +'' << ("\xEF\xBB\xBF".b + "data: #{JSON.generate(ack_message(9, 'toolsListChanged' => true))}\n\n".b)
      stream << "data: #{JSON.generate(tagged('notifications/tools/list_changed', 9))}\n\n"

      server.send(:consume_listen_events, stream, subscription, { scanned: 0 })

      # The acknowledgment is routed like any other notification and then
      # handled as subscription bookkeeping; the event after it is delivered.
      expect(routed.map(&:first))
        .to eq(['notifications/subscriptions/acknowledged', 'notifications/tools/list_changed'])
      expect(subscription).to be_active
    end
  end

  # --- 4. a JSON-RPC id of the wrong type is a different id -----------------
  describe 'subscription messages tagged with an id of another type' do
    include_context 'a scripted stdio session'

    def listen_with_numeric_id
      server.listen(notifications: { tools_list_changed: true }).tap do |subscription|
        expect(subscription.id).to be_a(Integer)
      end
    end

    # codex [P2] subscription_support.rb: the registry is keyed by `id.to_s`,
    # so a message tagged with the string "9" found the subscription whose
    # listen went out with the number 9. JSON-RPC ids of different types are
    # different ids — the cancellation path already compares them exactly,
    # and the acknowledgment and delivery paths now do too.
    it 'does not let a string-tagged acknowledgment activate a numeric listen' do
      subscription = listen_with_numeric_id

      server.handle_line("#{JSON.generate(ack_message(subscription.id.to_s, 'toolsListChanged' => true))}\n")

      expect(subscription).not_to be_active
      # The correctly typed acknowledgment still activates it.
      acknowledge(subscription)
      expect(subscription).to be_active
    end

    it 'does not deliver a string-tagged notification to a numeric listen' do
      subscription = listen_with_numeric_id
      acknowledge(subscription)
      received = Thread::Queue.new
      subscription.on_notification { |method, _params| received << method }

      server.handle_line("#{JSON.generate(tagged('notifications/tools/list_changed', subscription.id.to_s))}\n")
      # A correctly tagged notification is the barrier: delivered in order on
      # the subscription's own dispatcher, so anything the mistyped one would
      # have delivered is already here.
      server.handle_line("#{JSON.generate(tagged('notifications/tools/list_changed', subscription.id))}\n")

      expect(received.pop(timeout: 3)).to eq('notifications/tools/list_changed')
      expect(received).to be_empty
    end
  end
end
