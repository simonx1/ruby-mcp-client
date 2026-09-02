# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Review round 5 (codex, grok), on the code round 4 added: a cancellation that
# still could not reach Faraday's connect phase, so a listen POST could go out
# after `close`/`cleanup` and the thread that sent it was already gone from the
# registry a later cleanup would look in; a drop-oldest queue policy that
# discards the only queued update for a quiet resource to keep newer ones for a
# busy one, which loses the signal it was meant to preserve; and a stdio server
# that exits on its own, leaving every subscription :reconnecting for ever when
# the host only waits for notifications.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 5' do
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

  # codex [P1] / grok [1]: closing the response stream is the cancellation
  # signal, and a session whose socket is still being opened has none. Round 4
  # answered :opening and gave up after two joins — with the thread already
  # removed from the registry — so a connect that outlasted them still POSTed
  # a subscription the host had closed, and nothing was left for a later
  # cleanup to close.
  describe 'a cancellation that lands while the socket is being opened' do
    let(:url) { 'https://example.com/mcp' }
    let(:requests) { [] }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    before { stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 30) }

    after do
      @release&.close
      server.cleanup
    end

    def sse_response(*events)
      { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
        body: events.map { |event| "event: message\ndata: #{JSON.generate(event)}\n\n" }.join }
    end

    def json_response(id, result)
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result) }
    end

    def stub_listen
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << body
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'subscriptions/listen' then sse_response(ack_message(body['id'], {}))
        else json_response(body['id'], {})
        end
      end
    end

    # Hold the stream's thread where Faraday hands the session over: armed,
    # but with its socket not opened yet — exactly the window a cancellation
    # cannot close. Returns the sessions it armed.
    def stall_in_connect
      armed = Thread::Queue.new
      @release = Thread::Queue.new
      sessions = []
      allow(server).to receive(:arm_listen_session).and_wrap_original do |original, subscription, http|
        original.call(subscription, http)
        sessions << http
        armed << :armed
        @release.pop
      end
      [armed, sessions]
    end

    def listen_threads
      server.send(:listen_threads)
    end

    it 'never sends the listen request when the socket finishes opening after the close' do
      stub_const('MCPClient::HttpTransportBase::ListenStream::THREAD_JOIN_TIMEOUT_FOR_LISTEN', 0.05)
      stub_listen
      armed, = stall_in_connect

      subscription = server.listen(notifications: { tools_list_changed: true })
      armed.pop(timeout: 3)
      thread = listen_threads.values.first
      subscription.close
      @release << :go

      expect(thread.join(3)).to be_truthy
      expect(subscription).to be_closed_by_client
      expect(requests.map { |body| body['method'] }).not_to include('subscriptions/listen')
    end

    it 'leaves a stream it gave up on registered, so a later cleanup still closes it' do
      stub_const('MCPClient::HttpTransportBase::ListenStream::THREAD_JOIN_TIMEOUT_FOR_LISTEN', 0.05)
      stub_listen
      armed, sessions = stall_in_connect

      subscription = server.listen(notifications: { tools_list_changed: true })
      armed.pop(timeout: 3)
      session = sessions.first
      allow(session).to receive(:finish).and_call_original
      opened = false
      allow(session).to(receive(:started?).and_wrap_original { |original| opened || original.call })
      subscription.close

      # The thread is the only handle on that session: forgetting it here is
      # what left the server holding a stream nothing would ever close.
      expect(listen_threads.keys).to eq([subscription])
      opened = true
      server.cleanup

      expect(session).to have_received(:finish)
    end

    it 'never sends the listen request of a stream the transport shut down mid-connect' do
      stub_listen
      armed, = stall_in_connect

      server.listen(notifications: { tools_list_changed: true })
      armed.pop(timeout: 3)
      thread = listen_threads.values.first
      server.cleanup
      @release << :go

      expect(thread.join(3)).to be_truthy
      expect(requests.map { |body| body['method'] }).not_to include('subscriptions/listen')
    end

    it 'closes the response stream as soon as the socket it was waiting for opens' do
      stub_const('MCPClient::HttpTransportBase::ListenStream::THREAD_JOIN_TIMEOUT_FOR_LISTEN', 0.3)
      stub_listen
      armed, sessions = stall_in_connect

      subscription = server.listen(notifications: { tools_list_changed: true })
      armed.pop(timeout: 3)
      session = sessions.first
      allow(session).to receive(:finish).and_call_original
      opened = false
      allow(session).to(receive(:started?).and_wrap_original { |original| opened || original.call })
      closer = Thread.new { subscription.close }
      sleep 0.15
      # The socket opens long after the first close attempt found nothing.
      opened = true

      expect(closer.join(3)).to be_truthy
      expect(session).to have_received(:finish)
    end
  end

  # codex [P2] / grok [2]: with a mixed filter — several resource URIs or task
  # ids on one stream — dropping strictly by arrival order discards the only
  # queued update for a quiet thing to keep newer ones for a busy thing, and
  # nothing that survives tells the listener to re-read the quiet one. Overflow
  # must cost a listener a repeated notice of the same thing, never its only
  # notice of one thing.
  describe 'the notification queue under a mixed filter' do
    let(:server) { double('server') }

    def updated(uri)
      ['notifications/resources/updated', { 'uri' => uri, '_meta' => { sub_meta => 1 } }]
    end

    def task_status(task_id)
      ['notifications/tasks/status', { 'taskId' => task_id, '_meta' => { sub_meta => 1 } }]
    end

    # A subscription whose dispatcher is parked inside the first delivery, so
    # everything queued behind it is subject to the overflow policy.
    def blocked_subscription(identify, blocker, delivered)
      entered = Thread::Queue.new
      release = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |_method, params|
        delivered << identify.call(params)
        next unless identify.call(params) == blocker

        entered << :in
        release.pop
      end
      subscription.assign_id(1)
      [subscription, entered, release]
    end

    def uri_of
      ->(params) { params['uri'] }
    end

    it 'keeps the only queued update for a quiet resource when a busy one overflows the queue' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 4)
      delivered = []
      subscription, entered, release = blocked_subscription(uri_of, 'file:///blocker', delivered)

      subscription.deliver(*updated('file:///blocker'))
      entered.pop(timeout: 3)
      subscription.deliver(*updated('file:///cold'))
      20.times { subscription.deliver(*updated('file:///hot')) }

      expect(subscription.pending_notifications).to eq(4)
      expect(subscription.dropped_notifications).to eq(17)
      release << :go
      wait_until { delivered.size == 5 }

      expect(delivered).to eq(['file:///blocker', 'file:///cold', 'file:///hot', 'file:///hot', 'file:///hot'])
      subscription.finish
    end

    it 'keeps the only queued notice for a quiet task when a busy one overflows the queue' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 3)
      delivered = []
      identify = ->(params) { params['taskId'] }
      subscription, entered, release = blocked_subscription(identify, 'blocker', delivered)

      subscription.deliver(*task_status('blocker'))
      entered.pop(timeout: 3)
      subscription.deliver(*task_status('cold'))
      10.times { subscription.deliver(*task_status('hot')) }

      release << :go
      wait_until { delivered.size == 4 }

      expect(delivered).to eq(%w[blocker cold hot hot])
      subscription.finish
    end

    it 'never drops the only notice of one thing while another has more than one queued' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 3)
      delivered = []
      subscription, entered, release = blocked_subscription(uri_of, 'file:///blocker', delivered)

      subscription.deliver(*updated('file:///blocker'))
      entered.pop(timeout: 3)
      subscription.deliver(*updated('file:///cold'))
      2.times { subscription.deliver(*updated('file:///hot')) }
      # A fourth thing arrives with the queue full and nothing of its own in
      # it: the redundant hot update goes, not the single cold one.
      subscription.deliver(*updated('file:///warm'))

      release << :go
      wait_until { delivered.size == 4 }

      expect(delivered).to eq(['file:///blocker', 'file:///cold', 'file:///hot', 'file:///warm'])
      expect(subscription.dropped_notifications).to eq(1)
      subscription.finish
    end

    it 'tells two notifications about the same resource apart by their method' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 2)
      delivered = []
      identify = ->(params) { params['uri'] }
      subscription, entered, release = blocked_subscription(identify, 'file:///blocker', delivered)
      methods = []
      subscription.on_notification { |method, _params| methods << method }

      subscription.deliver(*updated('file:///blocker'))
      entered.pop(timeout: 3)
      subscription.deliver('notifications/resources/list_changed', { 'uri' => 'file:///a' })
      3.times { subscription.deliver(*updated('file:///a')) }

      release << :go
      wait_until { delivered.size == 3 }

      expect(methods.last(2)).to eq(['notifications/resources/list_changed', 'notifications/resources/updated'])
      subscription.finish
    end

    it 'still bounds the queue when every queued notification names a different thing' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 3)
      delivered = []
      subscription, entered, release = blocked_subscription(uri_of, 'file:///blocker', delivered)

      subscription.deliver(*updated('file:///blocker'))
      entered.pop(timeout: 3)
      10.times { |index| subscription.deliver(*updated("file:///#{index}")) }

      expect(subscription.pending_notifications).to eq(3)
      expect(subscription.dropped_notifications).to eq(7)
      release << :go
      wait_until { delivered.size == 4 }

      expect(delivered).to eq(['file:///blocker', 'file:///7', 'file:///8', 'file:///9'])
      subscription.finish
    end

    it 'never blocks the transport reader that delivers' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 2)
      delivered = []
      subscription, entered, release = blocked_subscription(uri_of, 'file:///blocker', delivered)

      subscription.deliver(*updated('file:///blocker'))
      entered.pop(timeout: 3)
      reader = Thread.new { 50.times { |index| subscription.deliver(*updated("file:///#{index}")) } }

      expect(reader.join(3)).to be_truthy
      expect(subscription.pending_notifications).to eq(2)
      release.close
      subscription.finish
    end
  end

  # codex [P1] server_stdio.rb:780-784: a host that only waits for
  # notifications never makes the request that re-establishes the process, so
  # an unexpected exit left every subscription :reconnecting for ever.
  describe 'on stdio, when the server process exits on its own' do
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

    it 're-establishes the process for a subscription nobody follows with a request' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      first_id = subscription.id

      server.send(:handle_server_exit)

      expect(listens.size).to eq(2)
      expect(subscription.id).to eq(listens.last['id'])
      expect(subscription.id).not_to eq(first_id)
      expect(subscription.state).to eq(:pending)
      expect(server.subscriptions.values).to eq([subscription])
    end

    it 'leaves the process to the next request when no subscription is open' do
      server.ping
      written.clear

      server.send(:handle_server_exit)

      expect(written).to be_empty
      expect(server.instance_variable_get(:@initialized)).to be(false)
    end

    it 'closes the subscriptions with the error when the process cannot be restarted' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      allow(server).to receive(:connect).and_raise(MCPClient::Errors::ConnectionError, 'command not found')

      server.send(:handle_server_exit)

      expect(subscription).to be_closed
      expect(subscription.error).to be_a(MCPClient::Errors::MCPError)
      expect(subscription.error.message).to include('command not found')
      expect(listens.size).to eq(1)
    end

    it 'gives up on a process that keeps exiting instead of restarting it for ever' do
      subscription = server.listen(notifications: { tools_list_changed: true })

      server.send(:handle_server_exit)
      server.send(:handle_server_exit)

      expect(listens.size).to eq(2)
      expect(subscription).to be_closed
      expect(subscription.error).to be_a(MCPClient::Errors::MCPError)
      expect(subscription.error.message).to match(/exited/i)
    end

    it 'does not re-establish the process for a subscription the host closed' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      subscription.close
      written.clear

      server.send(:handle_server_exit)

      expect(written).to be_empty
    end
  end
end
