# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Review round 4 (grok, codex), on the code round 3 added: an HTTP
# cancellation that could not close a stream whose socket it had not seen open
# — and let a listen POST go out after `close`; a shutdown that killed the
# reader and missed a subscription caught between two listen ids; a dispatch
# queue that a chatty server could grow without bound; SSE framing applied to
# an `application/json` listen answer; a malformed closing response accepted as
# a graceful close; and a dropped stream that still reported `active?` while it
# backed off.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 4' do
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

  describe 'on Streamable HTTP' do
    let(:url) { 'https://example.com/mcp' }
    let(:requests) { [] }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    # Nothing here wants a re-open on its own schedule.
    before { stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 30) }

    after do
      @gate&.close
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

    # A modern server whose subscriptions/listen answers come from the block.
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

    # A listen answer that does not arrive until the example releases it, so a
    # cancellation lands while the request is genuinely in flight.
    def stub_gated_listen(&answer)
      @gate = Thread::Queue.new
      stub_listen do |body|
        @gate.pop
        answer ? answer.call(body) : sse_response(ack_message(body['id'], {}))
      end
      @gate
    end

    def listen_sessions
      server.send(:listen_sessions)
    end

    def armed_sessions
      sessions = []
      allow(server).to receive(:arm_listen_session).and_wrap_original do |original, subscription, http|
        original.call(subscription, http)
        sessions << http
      end
      sessions
    end

    describe 'cancellation' do
      # codex [P2] listen_stream.rb:215-218 / grok [1]: the closed check ran
      # only inside on_data, so a close that landed after the subscription was
      # registered but before the stream thread reached its POST still sent it.
      it 'never sends the listen request when a close beats the stream thread to it' do
        stub_listen { |body| sse_response(ack_message(body['id'], {})) }
        release = Thread::Queue.new
        cancelled = Thread::Queue.new
        allow(server).to receive(:run_listen_stream).and_wrap_original do |original, subscription|
          release.pop
          original.call(subscription)
        end
        allow(server).to receive(:close_listen_stream).and_wrap_original do |original, subscription|
          original.call(subscription).tap { cancelled << :closed }
        end

        subscription = server.listen(notifications: { tools_list_changed: true })
        closer = Thread.new { subscription.close }
        cancelled.pop(timeout: 3)
        release << :go

        expect(closer.join(3)).to be_truthy
        expect(subscription).to be_closed_by_client
        expect(requests.map { |body| body['method'] }).not_to include('subscriptions/listen')
      end

      # The same race one step later: the request is already on its way into
      # Faraday when the close lands, so the check that stops it is the one
      # the connection makes as it is about to open its socket.
      it 'stops a request whose subscription is closed while its connection is being built' do
        stub_const('MCPClient::HttpTransportBase::ListenStream::THREAD_JOIN_TIMEOUT_FOR_LISTEN', 0.1)
        stub_listen { |body| sse_response(ack_message(body['id'], {})) }
        building = Thread::Queue.new
        release = Thread::Queue.new
        allow(server).to receive(:listen_connection).and_wrap_original do |original, subscription|
          original.call(subscription).tap do
            building << :in
            release.pop
          end
        end

        subscription = server.listen(notifications: { tools_list_changed: true })
        building.pop(timeout: 3)
        closer = Thread.new { subscription.close }
        wait_until { subscription.closed? }
        release << :go

        expect(closer.join(3)).to be_truthy
        expect(requests.map { |body| body['method'] }).not_to include('subscriptions/listen')
      end

      # grok [1]: closing the response stream is the cancellation signal.
      it 'closes the response stream of a listen request that is in flight' do
        gate = stub_gated_listen
        sessions = armed_sessions

        subscription = server.listen(notifications: { tools_list_changed: true })
        wait_until { sessions.any? && sessions.first.started? }
        closer = Thread.new { subscription.close }
        wait_until { !sessions.first.started? }
        gate << :go

        expect(closer.join(3)).to be_truthy
        expect(subscription).to be_closed_by_client
      end

      # grok [1]: a session that has been armed but whose socket is not open
      # yet cannot be closed — and silently doing nothing left the stream
      # running until the 300-second read timeout. Round 5 made the close come
      # back for it until the socket really is open, instead of once.
      it 'closes a stream whose socket was still opening when the cancellation arrived' do
        stub_const('MCPClient::HttpTransportBase::ListenStream::THREAD_JOIN_TIMEOUT_FOR_LISTEN', 0.5)
        gate = stub_gated_listen
        sessions = armed_sessions
        attempts = Thread::Queue.new
        allow(server).to receive(:close_listen_session).and_wrap_original do |original, subscription|
          original.call(subscription).tap { |closed| attempts << closed }
        end

        subscription = server.listen(notifications: { tools_list_changed: true })
        wait_until { sessions.any? && sessions.first.started? }
        opening = true
        allow(sessions.first).to(receive(:started?).and_wrap_original { |original| opening ? false : original.call })

        closer = Thread.new { subscription.close }
        expect(attempts.pop(timeout: 3)).to eq(:opening)
        opening = false
        outcome = attempts.pop(timeout: 3)
        outcome = attempts.pop(timeout: 3) while outcome == :opening
        expect(outcome).to eq(:closed)
        gate << :go
        expect(closer.join(3)).to be_truthy
      end

      # grok: an HTTP listen followed immediately by close.
      it 'leaves no stream, session or thread behind when a listen is closed at once' do
        stub_listen { |body| sse_response(ack_message(body['id'], {})) }

        subscription = server.listen(notifications: { tools_list_changed: true })
        subscription.close

        expect(subscription).to be_closed_by_client
        expect(server.send(:listen_threads)).to be_empty
        expect(server.subscriptions).to be_empty
        wait_until { listen_sessions.empty? && server.send(:listen_wakeups).empty? }
      end
    end

    describe 'shutdown' do
      # grok [2]: a stream between two listen ids is in neither registry, so
      # the shutdown never closed it and it re-opened onto a dead transport.
      it 'closes a subscription caught between two listen ids' do
        stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 0.01)
        stub_listen { |body| sse_response(ack_message(body['id'], { 'toolsListChanged' => true })) }
        gap = Thread::Queue.new
        resume = Thread::Queue.new
        allow(server).to receive(:unregister_subscription).and_wrap_original do |original, subscription|
          original.call(subscription)
          next unless subscription.state == :reconnecting

          gap << :in
          resume.pop
        end

        subscription = server.listen(notifications: { tools_list_changed: true })
        gap.pop(timeout: 5)
        cleaner = Thread.new { server.cleanup }
        expect(cleaner.join(5)).to be_truthy
        wait_until { subscription.closed? }
        resume << :go

        expect(server.subscriptions).to be_empty
        wait_until { server.send(:listen_threads).empty? }
        expect(requests.count { |body| body['method'] == 'subscriptions/listen' }).to eq(1)
      end

      # grok [2]: the reader is left to unwind on its own — a kill interrupts
      # it wherever it happens to be, and waiting for it under the transport
      # lock the reader itself needs is what hangs a later close or listen.
      it 'never kills the stream thread and never waits for it under the transport lock' do
        gate = stub_gated_listen
        subscription = server.listen(notifications: { tools_list_changed: true })
        wait_until { server.send(:listen_threads).any? }
        thread = server.send(:listen_threads).values.first
        allow(thread).to receive(:kill).and_call_original

        server.cleanup

        expect(thread).not_to have_received(:kill)
        expect(subscription).to be_closed
        gate << :go
        wait_until { !thread.alive? }
        expect(listen_sessions).to be_empty
      end
    end

    describe 'the framing of a listen answer' do
      # codex [P2] listen_stream.rb:221-223: SSE parsing was applied before the
      # Content-Type was inspected, so a compact JSON answer with a trailing
      # blank line was consumed as an event with no data lines and the empty
      # buffer made a clean close look like a dropped stream.
      it 'reads an application/json answer with a trailing blank line as the closing response' do
        stub_listen do |body|
          { status: 200, headers: { 'Content-Type' => 'application/json' },
            body: "#{JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                   'result' => { 'resultType' => 'complete' })}\n\n" }
        end

        subscription = server.listen(notifications: { tools_list_changed: true })
        wait_until { subscription.closed? }

        expect(subscription).to be_closed_gracefully
        expect(subscription.error).to be_nil
        expect(requests.count { |body| body['method'] == 'subscriptions/listen' }).to eq(1)
      end

      it 'keeps the typed error of a JSON rejection with a trailing blank line' do
        stub_listen do |body|
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: "#{JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                   'error' => { 'code' => -32_602, 'message' => 'unknown notification' })}\n\n" }
        end

        subscription = server.listen(notifications: { tools_list_changed: true })
        wait_until { subscription.closed? }

        expect(subscription.error).to be_a(MCPClient::Errors::ServerError)
        expect(subscription.error.message).to include('unknown notification')
      end
    end

    describe 'the closing response' do
      # codex [P2] subscription_support.rb:139-145: every other RPC path runs
      # validate_result_type!; skipping it here made malformed server data
      # indistinguishable from a clean close.
      def expect_invalid_close(result)
        stub_listen do |body|
          response = { 'jsonrpc' => '2.0', 'id' => body['id'] }
          response['result'] = result unless result == :omitted
          sse_response(response)
        end

        subscription = server.listen(notifications: { tools_list_changed: true })
        wait_until { subscription.closed? }

        expect(subscription).not_to be_closed_gracefully
        expect(subscription.error).to be_a(MCPClient::Errors::InvalidResultError)
        subscription
      end

      it 'fails the subscription when the result carries an unrecognized resultType' do
        expect_invalid_close({ 'resultType' => 'wat' })
      end

      it 'fails the subscription when the response omits result entirely' do
        expect_invalid_close(:omitted)
      end

      it 'fails the subscription when the result is a scalar' do
        expect_invalid_close('done')
      end
    end

    describe 'a stream that drops after it was acknowledged' do
      # codex [P2] listen_stream.rb:157-162: the :dropped path entered backoff
      # without mark_reconnecting, so active? stayed true while no server-side
      # subscription existed.
      it 'stops reporting active? while it waits to re-open' do
        stub_listen { |body| sse_response(ack_message(body['id'], { 'toolsListChanged' => true })) }

        subscription = server.listen(notifications: { tools_list_changed: true })
        wait_until { subscription.state == :reconnecting }

        expect(subscription).not_to be_active
        expect(subscription).not_to be_closed
        subscription.close
      end

      # Settling is one-way: the drop must not un-answer the question a
      # subscribe_resource is blocked on, or the call would wait out its whole
      # acknowledgment timeout for an acknowledgment it already had.
      it 'still reports the acknowledgment a caller was waiting for' do
        stub_listen { |body| sse_response(ack_message(body['id'], { 'resourceSubscriptions' => ['file:///a'] })) }

        expect(server.subscribe_resource('file:///a')).to be(true)
        subscription = server.resource_subscriptions['file:///a']
        wait_until { subscription.state == :reconnecting }

        expect(subscription.wait_until_settled(0)).to eq(:active)
        subscription.close
      end
    end

    describe 'subscribe_resource' do
      let(:server) do
        MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp',
                                            retries: 0, read_timeout: 0.2)
      end

      # grok: the acknowledgment never arrives because the listen request is
      # still in flight — the wait must end on the client's own deadline.
      it 'raises when the request is still in flight at the acknowledgment deadline' do
        stub_const('MCPClient::HttpTransportBase::ListenStream::THREAD_JOIN_TIMEOUT_FOR_LISTEN', 0.1)
        gate = stub_gated_listen

        expect { server.subscribe_resource('file:///a') }
          .to raise_error(MCPClient::Errors::MCPError, /timed out/)
        gate << :go

        expect(server.resource_subscriptions).to be_empty
      end

      # Round 3 implemented both of these branches without pinning them.
      it 'raises when the stream closes before the acknowledgment' do
        stub_listen do |body|
          sse_response({ 'jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'resultType' => 'complete' } })
        end

        expect { server.subscribe_resource('file:///a') }
          .to raise_error(MCPClient::Errors::MCPError, %r{closed the subscription for 'file:///a'})
        expect(server.resource_subscriptions).to be_empty
      end

      it 'raises when the acknowledgment never arrives on an open stream' do
        stub_listen do |_body|
          { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: ": keep-alive\n\n" }
        end

        expect { server.subscribe_resource('file:///a') }
          .to raise_error(MCPClient::Errors::MCPError, /timed out/)
        expect(server.resource_subscriptions).to be_empty
      end
    end
  end

  # grok [3]: round 3 made deliver enqueue and return, which removed the
  # deadlock and the backpressure with it. The queue is peer-fed, so it needs
  # a ceiling, and every MCP notification is a "look again" signal, so a
  # repeat of one already queued is the notification to lose. Round 5 replaced
  # "the oldest" with "the oldest of the same thing" — dropping by arrival
  # order alone discarded the only queued update for a quiet resource on a
  # mixed filter (see the round 5 spec); what stands here is the ceiling
  # itself, which one notification per thing cannot exercise.
  describe 'the notification queue' do
    let(:server) { double('server') }

    def update(uri)
      ['notifications/resources/updated', { 'uri' => uri }]
    end

    it 'bounds its depth and counts what it dropped' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 4)
      entered = Thread::Queue.new
      release = Thread::Queue.new
      delivered = []
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |_method, params|
        delivered << params['uri']
        next unless params['uri'] == 'file:///0'

        entered << :in
        release.pop
      end
      subscription.assign_id(1)

      subscription.deliver(*update('file:///0'))
      entered.pop(timeout: 3)
      20.times { |index| subscription.deliver(*update("file:///#{index + 1}")) }

      expect(subscription.pending_notifications).to eq(4)
      expect(subscription.dropped_notifications).to eq(16)
      release << :go
      wait_until { delivered.size == 5 }
      expect(delivered).to eq(['file:///0', 'file:///17', 'file:///18', 'file:///19', 'file:///20'])
      subscription.finish
    end

    it 'never blocks the transport reader that delivers' do
      stub_const('MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS', 2)
      release = Thread::Queue.new
      entered = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |_method, _params|
        entered << :in
        release.pop
      end
      subscription.assign_id(1)

      subscription.deliver(*update('file:///first'))
      entered.pop(timeout: 3)
      reader = Thread.new { 50.times { |index| subscription.deliver(*update("file:///#{index}")) } }

      expect(reader.join(3)).to be_truthy
      expect(subscription.pending_notifications).to eq(2)
      release.close
      subscription.finish
    end
  end
end
