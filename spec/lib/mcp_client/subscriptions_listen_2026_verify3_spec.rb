# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Third verification pass over subscriptions/listen.
#
# * **a re-issued listen with no deadline.** The acknowledgment watchdog was
#   armed only by the public `listen` call, and it retires at the first
#   acknowledgment. Every reconnect and every stdio restart sends a *new*
#   JSON-RPC request that the same "implementations SHOULD establish timeouts
#   for all sent requests" applies to, and none of them re-armed it: a server
#   that accepts the replacement and then never acknowledges left the handle
#   pending with nothing to tell the host why.
#
# * **a cancellation naming a listen the process was never sent.** The listen
#   ids a subscription has outstanding were recorded without the pipe they were
#   written to, so a write that was still deciding which id to record when the
#   process was torn down put that id back after the teardown had forgotten
#   everything — and `close` then named it on the process that replaced it.
#
# * **a listen whose write raises after the request reached the pipe.** The
#   post-write cancellation for a `close` that had already run sat on the
#   success path only, so a write that put `listen(n)` on the pipe and then
#   failed left the server serving a stream this client never named.
#
# * **coverage the two reviews asked for**: the Authorization header on the
#   listen POST and on the POST a reconnect re-issues, the response stream
#   actually being closed when an acknowledgment deadline expires, a 404 /
#   -32601 refusal told apart from the 5xx re-open path, a sub-resource
#   `notifications/resources/updated`, and the streamed buffer cap.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen, verification pass 3' do
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

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise 'condition not met in time' unless yield
  end

  # A stdio transport whose process, handshake and writes are stubbed, so an
  # example can drive the lifecycle by hand.
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

    def acknowledge(subscription)
      server.handle_line("#{JSON.generate(ack_message(subscription.id, subscription.requested))}\n")
    end

    before do
      allow(server).to receive(:connect) { install_stdin && true }
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      install_stdin
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
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
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                          oauth_provider: oauth_provider)
    end
    # Nil unless an example wants one; the OAuth examples override it.
    let(:oauth_provider) { nil }

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

    # The Net::HTTP sessions the streams were armed with, so an example can see
    # the response stream be closed.
    def armed_sessions
      sessions = []
      allow(server).to receive(:arm_listen_session).and_wrap_original do |original, subscription, http|
        original.call(subscription, http)
        sessions << http
      end
      sessions
    end
  end

  # codex [P2] subscription_support.rb:48 / grok [C1]: the watchdog is armed by
  # `listen` alone and retires at the first acknowledgment, so every request a
  # reconnect or a restart re-issues went out with no deadline at all —
  # "implementations SHOULD establish timeouts for all sent requests ... [and]
  # SHOULD issue a cancellation notification for that request"
  # (basic/patterns/cancellation "Timeouts") applies to each of them.
  describe 'the acknowledgment deadline of a re-issued listen' do
    describe 'on stdio' do
      include_context 'a scripted stdio session'

      # Acknowledge the first listen as it is written, and only that one: the
      # handle is `:active` before `listen` even arms its deadline, so the first
      # watchdog retires at once and what follows is the restart's alone.
      def acknowledge_first_listen
        acknowledged = false
        allow(server).to receive(:open_subscription).and_wrap_original do |original, subscription|
          original.call(subscription)
          next if acknowledged

          acknowledged = true
          acknowledge(subscription)
        end
      end

      it 'ends the handle when the replacement process never acknowledges, and cancels that request' do
        acknowledge_first_listen

        subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.2)
        first = listens.last['id']
        expect(subscription).to be_active

        # The process exits; the restart re-sends the listen under a new id, and
        # the replacement accepts it and says nothing more.
        server.send(:handle_server_exit)
        second = listens.last['id']
        expect(second).not_to eq(first)

        expect(subscription.wait_until_settled(5)).to eq(:closed)
        expect(subscription.error).to be_a(MCPClient::Errors::RequestTimeoutError)
        expect(subscription.error.message).to include(second.to_s)
        expect(cancelled_ids).to eq([second])
      end
    end

    describe 'on Streamable HTTP' do
      include_context 'a scripted HTTP session'

      it 'ends the handle when the stream a reconnect re-opens is never acknowledged' do
        held = Thread::Queue.new
        posts = 0
        stub_listen do |body|
          posts += 1
          # The first stream is acknowledged and then ends without a closing
          # response: a drop, which re-opens under a new id. The second is held
          # open by a server that never acknowledges it.
          next sse_response(ack_message(body['id'], { 'toolsListChanged' => true })) if posts == 1

          held.pop
          sse_response
        end
        stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 0.01)

        subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.5)
        begin
          wait_until { listen_requests.size == 2 }
          reopened = listen_requests.last[:body]['id']

          expect(subscription.wait_until_settled(10)).to eq(:closed)
          expect(subscription.error).to be_a(MCPClient::Errors::RequestTimeoutError)
          # Named in the error, so a first watchdog that fired late could not
          # pass for the deadline of the request the reconnect re-issued.
          expect(subscription.error.message).to include(reopened.to_s)
        ensure
          held << :go
        end
        expect(listen_requests.size).to eq(2)
      end
    end
  end

  # grok [2]: closing the response stream is the cancellation signal on
  # Streamable HTTP, so an acknowledgment deadline that expires has to close it
  # — `RequestTimeoutError` on the handle says nothing to the peer.
  describe 'an HTTP acknowledgment deadline that expires' do
    include_context 'a scripted HTTP session'

    it 'closes the response stream the quiet server is holding open' do
      held = Thread::Queue.new
      stub_listen do
        held.pop
        sse_response
      end
      sessions = armed_sessions

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.2)
      begin
        wait_until { sessions.any? && sessions.first.started? }

        expect(subscription.wait_until_settled(10)).to eq(:closed)
        expect(subscription.error).to be_a(MCPClient::Errors::RequestTimeoutError)
        # The peer sees EOF: this is the cancellation, and there is no
        # notifications/cancelled on this transport to stand in for it.
        wait_until { !sessions.first.started? }
      ensure
        held << :go
      end
      expect(listen_requests.size).to eq(1)
      expect(requests.map { |request| request[:body]['method'] }).not_to include('notifications/cancelled')
    end
  end

  # codex [P3]: the listen ids a subscription has outstanding were recorded
  # without the pipe they went to, and the teardown of a process forgets them by
  # clearing that record. A write still choosing its id when the teardown ran
  # put one back afterwards, and `close` then sent `notifications/cancelled` for
  # it to the process that replaced it — "the cancelled request MUST have been
  # previously issued" (basic/patterns/cancellation), and that process never
  # was.
  describe 'a stdio listen recorded after the process it was written to was torn down' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:old_writes) { [] }
    let(:new_writes) { [] }

    def recording_handle(sink)
      double('stdio', flush: nil, closed?: false, close: nil).tap do |handle|
        allow(handle).to receive(:puts) { |line| sink << JSON.parse(line) }
      end
    end

    def listen_ids(writes)
      writes.select { |message| message['method'] == 'subscriptions/listen' }.map { |message| message['id'] }
    end

    def cancelled_ids(writes)
      writes.select { |message| message['method'] == 'notifications/cancelled' }
            .map { |message| message['params']['requestId'] }
    end

    before do
      server.instance_variable_set(:@stdin, recording_handle(old_writes))
      server.instance_variable_set(:@stdout, double('stdout', closed?: true, close: nil))
      server.instance_variable_set(:@stderr, double('stderr', closed?: true, close: nil))
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@stdin, recording_handle(new_writes))
        true
      end
      allow(server).to receive(:wait_response) do |id, **_options|
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => discover_result }
      end
    end

    it 'never names it on the process that replaced it' do
      subscription = MCPClient::Subscription.new(server: server, requested: { 'toolsListChanged' => true })
      entered = Thread::Queue.new
      release = Thread::Queue.new
      paused = false
      allow(subscription).to receive(:record_outstanding_listen).and_wrap_original do |original, *args|
        next original.call(*args) if paused

        # Paused *before* the id is recorded, which is the window the teardown's
        # "forget what this process was sent" cannot reach.
        paused = true
        entered << args.first
        release.pop
        original.call(*args)
      end

      opener = Thread.new { server.open_subscription(subscription) }
      stale_id = entered.pop(timeout: 10)

      server.send(:handle_server_exit)
      reopened_id = subscription.id
      expect(reopened_id).not_to eq(stale_id)

      release << :go
      opener.join(10)
      expect(listen_ids(old_writes)).to eq([stale_id])
      expect(listen_ids(new_writes)).to eq([reopened_id])

      subscription.close

      expect(cancelled_ids(new_writes)).to eq([reopened_id])
    end
  end

  # grok [C2]: the cancellation a `close` that ran during the write is owed
  # sat after `send_request`, so a write that put the request on the pipe and
  # then raised skipped it — the server is serving `listen(n)` and this client
  # never names it. `take_outstanding_listens` deliberately refuses an id whose
  # write has not finished, so nothing else sends it either.
  describe 'a stdio close racing a listen write that raises' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }

    before do
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      handle = double('stdin', flush: nil, closed?: false, close: nil)
      allow(handle).to receive(:puts) do |line|
        message = JSON.parse(line)
        written << message
        # The line is on the pipe and the write fails afterwards: the client
        # cannot know how much of it the peer saw.
        raise Errno::EPIPE if message['method'] == 'subscriptions/listen'
      end
      server.instance_variable_set(:@stdin, handle)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
    end

    it 'still cancels the request the failed write put on the pipe, and only after it' do
      writing = Thread::Queue.new
      release = Thread::Queue.new
      allow(server).to receive(:send_request).and_wrap_original do |original, request, **options|
        if request['method'] == 'subscriptions/listen'
          writing << :in
          release.pop
        end
        original.call(request, **options)
      end

      opener = Thread.new do
        Thread.current.report_on_exception = false
        server.listen(notifications: { tools_list_changed: true }, ack_timeout: false)
      end
      writing.pop(timeout: 10)
      subscription = server.subscriptions.values.first
      # Runs while the listen is still unwritten, so it cancels nothing itself.
      subscription.close
      release << :go
      # The write failed, and `listen` still says so: the cancellation below is
      # owed whether or not the caller is handed the stream.
      expect { opener.join(10) }.to raise_error(MCPClient::Errors::TransportError, /Broken pipe/)

      methods = written.map { |message| message['method'] }
      expect(methods.first).to eq('subscriptions/listen')
      cancelled = written.select { |message| message['method'] == 'notifications/cancelled' }
      expect(cancelled.map { |message| message['params']['requestId'] }).to eq([subscription.id])
    end
  end

  # grok [1]: "authorization MUST be included in every HTTP request from client
  # to server" (basic/authorization "Access Token Usage"). The listen POST is
  # one, and so is the POST a reconnect re-issues.
  describe 'OAuth on the listen POST' do
    include_context 'a scripted HTTP session'

    let(:oauth_provider) do
      provider = instance_double(MCPClient::Auth::OAuthProvider)
      allow(provider).to receive(:apply_authorization) { |req| req.headers['Authorization'] = 'Bearer listen-token' }
      provider
    end

    it 'carries the token on the first POST and on the one the reconnect re-issues' do
      posts = 0
      stub_listen do |body|
        posts += 1
        next sse_response(ack_message(body['id'], { 'toolsListChanged' => true })) if posts == 1

        sse_response(ack_message(body['id'], { 'toolsListChanged' => true }),
                     { 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'resultType' => 'complete' } })
      end
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 0.01)

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: false)
      wait_until { subscription.closed? }

      expect(listen_requests.size).to eq(2)
      expect(listen_requests.map { |request| request[:headers]['Authorization'] })
        .to eq(['Bearer listen-token', 'Bearer listen-token'])
    end
  end

  # grok [3]: Streamable HTTP answers an unknown method with 404 and JSON-RPC
  # -32601. That is the server refusing the subscription, not the temporary
  # unavailability a 5xx stands for, and the two are one status class apart.
  describe 'a listen answered with 404 and -32601' do
    include_context 'a scripted HTTP session'

    it 'ends the subscription with the method-not-found error instead of re-opening it' do
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 0.01)
      stub_listen do |body|
        { status: 404, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                              'error' => { 'code' => -32_601, 'message' => 'Method not found' }) }
      end

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: false)
      wait_until { subscription.closed? }

      expect(subscription.error).to be_a(MCPClient::Errors::ServerError)
      expect(subscription.error.code).to eq(-32_601)
      expect(subscription).not_to be_reconnectable
      sleep 0.1
      expect(listen_requests.size).to eq(1)
    end
  end

  # grok [4]: "the uri ... might be a sub-resource of the one the client
  # subscribed to" (server/resources). Delivery is by subscription id, so a
  # sub-resource update reaches the listener the same way — nothing filters the
  # URI, and nothing may start to.
  describe 'a resources/updated notification for a sub-resource' do
    include_context 'a scripted stdio session'

    it 'is delivered to the listener that subscribed to the parent URI' do
      received = Thread::Queue.new
      subscription = server.listen(notifications: { resource_subscriptions: ['file:///project'] },
                                   ack_timeout: false) { |_method, params| received << params['uri'] }
      acknowledge(subscription)

      server.handle_line("#{JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/resources/updated',
                                          'params' => { 'uri' => 'file:///project/src/main.rb',
                                                        '_meta' => { sub_meta => subscription.id } })}\n")

      expect(received.pop(timeout: 5)).to eq('file:///project/src/main.rb')
    end
  end

  # codex [P2]: the cap on a listen stream's partial-event buffer was only ever
  # invoked directly by an example, so removing its call from the streaming
  # reader left the whole suite green — and a peer that never terminates an
  # event could grow the buffer without bound.
  describe 'a listen stream whose event never ends' do
    include_context 'a scripted HTTP session'

    it 'fails the subscription instead of buffering the peer\'s bytes without bound' do
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_MAX_BUFFER_BYTES', 512)
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 30)
      stub_listen do
        { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
          body: "event: message\ndata: #{'x' * 4096}" }
      end

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: false)
      wait_until { subscription.closed? }

      expect(subscription.error).to be_a(MCPClient::Errors::ConnectionError)
      expect(subscription.error.message).to include('maximum buffered size')
      expect(listen_requests.size).to eq(1)
    end
  end
end
