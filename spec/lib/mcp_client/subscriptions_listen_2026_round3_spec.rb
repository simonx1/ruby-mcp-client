# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Review round 3 (codex, grok). subscribe_resource used to start a listen
# stream and drop the handle, so it answered true for a stream the server had
# rejected; a stdio listener ran on the sole stdout reader thread, so an RPC
# issued from it could never be answered; HTTP cancellation killed the stream
# thread instead of closing the response stream (the spec's cancellation
# signal); two threads could open two streams for one URI; a reconnect could
# re-send a subscription the host had closed, leaving it uncancellable; the
# per-URI registry was cleared outside its lock; and SSE events were only
# recognized with LF or CRLF line endings.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 3' do
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

  describe 'the HTTP transports' do
    let(:url) { 'https://example.com/mcp' }
    let(:requests) { [] }

    # No example wants a re-open: the streams here end as soon as WebMock has
    # handed over the whole body.
    before { stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 30) }

    def json_response(id, result)
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result) }
    end

    def sse_response(*events)
      { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
        body: events.map { |event| "event: message\ndata: #{JSON.generate(event)}\n\n" }.join }
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

    shared_examples 'subscribe_resource that waits for the acknowledgment' do
      it 'returns true once the server acknowledged the URI' do
        stub_listen { |body| sse_response(ack_message(body['id'], { 'resourceSubscriptions' => ['file:///a'] })) }

        expect(server.subscribe_resource('file:///a')).to be(true)
        # The stub's stream ends as soon as it has handed over the
        # acknowledgment, which leaves the subscription re-opening rather than
        # active (round 4); what the call promises is that the server answered.
        registered = server.resource_subscriptions['file:///a']
        expect(registered).not_to be_closed
        expect(registered.acknowledged).to eq({ 'resourceSubscriptions' => ['file:///a'] })
      end

      it 'raises instead of reporting success when the listen request is rejected' do
        stub_listen do |body|
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_602, 'message' => 'unknown resource' }) }
        end

        expect { server.subscribe_resource('file:///a') }
          .to raise_error(MCPClient::Errors::MCPError, /unknown resource/)
        expect(server.resource_subscriptions).to be_empty
      end

      it 'raises when the acknowledgment does not cover the URI' do
        stub_listen { |body| sse_response(ack_message(body['id'], { 'resourceSubscriptions' => [] })) }

        expect { server.subscribe_resource('file:///a') }
          .to raise_error(MCPClient::Errors::ResourceReadError, %r{file:///a})
        expect(server.resource_subscriptions).to be_empty
        expect(requests.count { |body| body['method'] == 'subscriptions/listen' }).to eq(1)
      end
    end

    describe MCPClient::ServerHTTP do
      let(:server) { described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

      after { server.cleanup }

      it_behaves_like 'subscribe_resource that waits for the acknowledgment'
    end

    describe MCPClient::ServerStreamableHTTP do
      let(:server) do
        described_class.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, read_timeout: 3)
      end

      after { server.cleanup }

      it_behaves_like 'subscribe_resource that waits for the acknowledgment'
    end

    describe 'SSE framing' do
      let(:server) do
        MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      end

      after { server.cleanup }

      it 'consumes events terminated with CR, LF or CRLF' do
        stub_listen do |body|
          ack = JSON.generate(ack_message(body['id'], { 'toolsListChanged' => true }))
          update = JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                                 'params' => { '_meta' => { sub_meta => body['id'] } })
          closing = JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                  'result' => { 'resultType' => 'complete' })
          { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
            body: "event: message\rdata: #{ack}\r\r" \
                  "data: #{update}\n\r" \
                  "data: #{closing}\r\n\r\n" }
        end

        received = []
        subscription = server.listen(notifications: { tools_list_changed: true }) { |method, _p| received << method }
        wait_until { subscription.closed? }
        wait_until { received.any? }

        expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })
        expect(subscription).to be_closed_gracefully
        expect(received).to eq(['notifications/tools/list_changed'])
      end

      it 'keeps scanning an event that arrives split around multibyte data' do
        subscription = MCPClient::Subscription.new(server: server, requested: {})
        subscription.assign_id(9)
        routed = []
        allow(server).to receive(:route_notification) { |method, _params| routed << method }
        head = JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/resources/updated',
                             'params' => { 'uri' => 'file:///é-é-é-é-é' })
        buffer = +''
        state = { scanned: 0 }

        server.send(:consume_listen_events, buffer << "data: #{head}", subscription, state)
        server.send(:consume_listen_events, buffer << "\n\n", subscription, state)

        expect(routed).to eq(['notifications/resources/updated'])
      end
    end

    describe 'cancellation' do
      let(:server) do
        MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      end

      after { server.cleanup }

      # Closing the response stream is the cancellation signal; killing the
      # thread that reads it interrupts the reader wherever it happens to be,
      # which loses whatever it was delivering at that moment.
      it 'closes the stream without interrupting what the reader was delivering' do
        stub_listen do |body|
          sse_response(ack_message(body['id'], { 'toolsListChanged' => true }),
                       { 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                         'params' => { '_meta' => { sub_meta => body['id'] } } })
        end
        entered = Thread::Queue.new
        release = Thread::Queue.new
        delivered = Thread::Queue.new
        server.on_notification do |method, _params|
          next unless method == 'notifications/tools/list_changed'

          entered << :in
          release.pop
          delivered << method
        end

        subscription = server.listen(notifications: { tools_list_changed: true })
        entered.pop(timeout: 3)
        closer = Thread.new { subscription.close }
        sleep 0.05
        release << :go

        expect(delivered.pop(timeout: 3)).to eq('notifications/tools/list_changed')
        expect(closer.join(3)).to be_truthy
        expect(subscription).to be_closed_by_client
      end
    end

    describe 'shutdown' do
      let(:server) do
        MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      end

      it 'clears the per-URI registry under the subscription lock' do
        stub_listen { |body| sse_response(ack_message(body['id'], { 'resourceSubscriptions' => ['file:///a'] })) }
        server.subscribe_resource('file:///a')
        owned = []
        allow(server.resource_subscriptions).to receive(:clear).and_wrap_original do |original|
          owned << server.subscriptions_mutex.owned?
          original.call
        end

        server.cleanup

        expect(owned).to eq([true])
        expect(server.resource_subscriptions).to be_empty
      end
    end
  end

  describe 'on stdio' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }
    let(:written_mutex) { Mutex.new }

    let(:stdin) do
      double('stdin', flush: nil, closed?: true, close: nil).tap do |pipe|
        allow(pipe).to receive(:puts) { |raw| record(JSON.parse(raw)) }
      end
    end

    before do
      # A re-established process hands the transport a fresh stdin, the way
      # connect does on a live session.
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@stdin, stdin)
        true
      end
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      allow(server).to receive(:send_request) { |request| record(request) }
      allow(server).to receive(:wait_response) do |id, **_options|
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => discover_result }
      end
    end

    after { @reader&.kill }

    def record(message)
      written_mutex.synchronize { written << message }
    end

    def writes
      written_mutex.synchronize { written.dup }
    end

    # Stands in for the stdout reader thread: answers every subscriptions/listen
    # the client sends, so a caller can wait for the answer the way it does on
    # a live session.
    def start_reader_thread(&answer)
      @reader = Thread.new do
        answered = []
        loop do
          writes.each do |message|
            next unless message['method'] == 'subscriptions/listen' && !answered.include?(message['id'])

            answered << message['id']
            server.handle_line("#{JSON.generate(answer.call(message))}\n")
          end
          sleep 0.005
        end
      end
    end

    def acknowledge_listens(granted: nil)
      start_reader_thread do |listen|
        ack_message(listen['id'], granted || listen['params']['notifications'])
      end
    end

    def reject_listens(message)
      start_reader_thread do |listen|
        { 'jsonrpc' => '2.0', 'id' => listen['id'], 'error' => { 'code' => -32_602, 'message' => message } }
      end
    end

    it 'returns true once the server acknowledged the URI' do
      acknowledge_listens

      expect(server.subscribe_resource('file:///a')).to be(true)
      expect(server.resource_subscriptions['file:///a']).to be_active
    end

    it 'raises instead of reporting success when the listen request is rejected' do
      reject_listens('unknown resource')

      expect { server.subscribe_resource('file:///a') }
        .to raise_error(MCPClient::Errors::MCPError, /unknown resource/)
      expect(server.resource_subscriptions).to be_empty
    end

    it 'raises and closes the stream when the acknowledgment does not cover the URI' do
      acknowledge_listens(granted: { 'resourceSubscriptions' => [] })

      expect { server.subscribe_resource('file:///a') }
        .to raise_error(MCPClient::Errors::ResourceReadError, %r{file:///a})
      expect(server.resource_subscriptions).to be_empty
      listen = writes.find { |message| message['method'] == 'subscriptions/listen' }
      cancelled = writes.select { |message| message['method'] == 'notifications/cancelled' }
      expect(cancelled.map { |message| message['params']['requestId'] }).to eq([listen['id']])
    end

    it 'opens a single stream when two threads subscribe to one URI at once' do
      acknowledge_listens
      entered = Thread::Queue.new
      release = Thread::Queue.new
      allow(server).to receive(:open_subscription).and_wrap_original do |original, subscription|
        entered << :in
        release.pop
        original.call(subscription)
      end

      subscribers = Array.new(2) { Thread.new { server.subscribe_resource('file:///a') } }
      entered.pop(timeout: 3)
      sleep 0.05

      expect(entered.size).to eq(0)
      2.times { release << :go }
      expect(subscribers.map { |thread| thread.join(3)&.value }).to eq([true, true])
      expect(writes.count { |message| message['method'] == 'subscriptions/listen' }).to eq(1)
      expect(server.resource_subscriptions.size).to eq(1)
    end

    it 'cancels every listen it sent when a close races with the re-open' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      server.cleanup
      closing = Thread::Queue.new
      allow(server).to receive(:register_subscription).and_wrap_original do |original, registered|
        original.call(registered)
        next unless registered.equal?(subscription)

        Thread.new do
          subscription.close
          closing << :closed
        end
        sleep 0.05
      end

      server.ping
      closing.pop(timeout: 3)

      listens = writes.select { |message| message['method'] == 'subscriptions/listen' }
      expect(cancelled_after_send(listens.last)).to be(true)
      # And nothing cancelled it *before* it was written: "the cancelled
      # request MUST have been previously issued" (basic/patterns/cancellation).
      expect(cancelled_before_send(listens.last)).to be(false)
      expect(subscription).to be_closed
    end

    # Whether a notifications/cancelled for this listen request was written
    # after it — a cancellation that precedes the request it names leaves the
    # server-side subscription running for good.
    def cancelled_after_send(listen)
      cancellations_of(listen, writes.drop(index_of(listen) + 1))
    end

    # @return [Boolean] whether one was written before the request it names
    def cancelled_before_send(listen)
      cancellations_of(listen, writes.take(index_of(listen)))
    end

    def index_of(listen)
      writes.index { |message| message.equal?(listen) }
    end

    def cancellations_of(listen, messages)
      messages.any? do |message|
        message['method'] == 'notifications/cancelled' && message['params']['requestId'] == listen['id']
      end
    end
  end

  describe 'a stdio listener that issues a request of its own' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    after do
      server.cleanup
      @endpoint&.kill
      @pipes&.each { |pipe| pipe.close unless pipe.closed? }
    end

    # A modern stdio server on real pipes, so the client runs its own reader
    # thread: the client writes requests into stdin_r and reads messages the
    # fake server writes to stdout_w.
    def start_stdio_server(stdin_r, stdout_w)
      @endpoint = Thread.new do
        stdin_r.each_line do |raw|
          message = JSON.parse(raw)
          answer = answer_for(message)
          stdout_w.puts(JSON.generate(answer)) if answer
        end
      rescue IOError, JSON::ParserError
        nil
      end
    end

    def answer_for(message)
      case message['method']
      when 'server/discover'
        { 'jsonrpc' => '2.0', 'id' => message['id'], 'result' => discover_result }
      when 'subscriptions/listen'
        ack_message(message['id'], message['params']['notifications'])
      when 'resources/read'
        { 'jsonrpc' => '2.0', 'id' => message['id'],
          'result' => { 'contents' => [{ 'uri' => 'file:///a', 'text' => 'fresh' }] } }
      end
    end

    it 'is answered, because listeners do not run on the reader thread' do
      stdin_r, stdin_w = IO.pipe
      stdout_r, stdout_w = IO.pipe
      @pipes = [stdin_r, stdin_w, stdout_r, stdout_w]
      [stdin_w, stdout_w].each { |pipe| pipe.sync = true }
      start_stdio_server(stdin_r, stdout_w)
      allow(server).to receive(:start_stderr_reader)
      allow(server).to receive(:connect) do
        server.instance_variable_set(:@stdin, stdin_w)
        server.instance_variable_set(:@stdout, stdout_r)
        server.instance_variable_set(:@stderr, StringIO.new(''))
        true
      end

      updates = Thread::Queue.new
      subscription = server.listen(notifications: { resource_subscriptions: ['file:///a'] }) do |_method, _params|
        updates << server.read_resource('file:///a')
      end
      wait_until { subscription.active? }
      stdout_w.puts(JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/resources/updated',
                                  'params' => { 'uri' => 'file:///a',
                                                '_meta' => { sub_meta => subscription.id } }))

      contents = updates.pop(timeout: 3)
      expect(contents&.first&.text).to eq('fresh')
    end
  end
end
