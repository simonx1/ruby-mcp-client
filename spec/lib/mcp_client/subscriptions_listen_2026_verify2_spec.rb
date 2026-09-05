# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Second verification pass over subscriptions/listen.
#
# * **a listen that opens after cleanup, one step earlier.** Readying the
#   session connected and *then* cleared the "streams may be opened" flag as
#   two separate steps, so a `cleanup` landing between them had its flag reset
#   by the listen that resumed afterwards — which then POSTed on a transport
#   the host had already disconnected.
#
# * **a stdio cancellation for a request that was never issued.** A `close`
#   racing an open cancelled the id the open had just taken, before the listen
#   carrying that id had been written: the wire carried `cancelled(2)` ahead of
#   `listen(2)`, and cancellation MUST refer to a previously issued request.
#
# * **an unacknowledged listen with no deadline.** A server that answers
#   discovery and then never acknowledges left the handle pending for ever.
#
# * **a non-completion closing result.** `resultType: "input_required"` is a
#   result the client recognizes, and subscriptions/listen was closing
#   *gracefully* on one — but MRTR is not supported for listen and
#   input_required means the request is not complete.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen, verification pass 2' do
  def sub_meta
    'io.modelcontextprotocol/subscriptionId'
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise 'condition not met in time' unless yield
  end

  # codex [P1] listen_stream.rb:47: ensure_connected and clearing the
  # shutdown flag were separate operations, so a cleanup between them was
  # undone by the listen that resumed after it.
  describe 'an HTTP cleanup that lands inside ensure_session_ready' do
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
    end

    it 'refuses the listen instead of POSTing on the closed transport' do
      listen_post = stub_request(:post, 'https://example.com/mcp')
                    .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: '')
      connected = Thread::Queue.new
      release = Thread::Queue.new
      allow(server).to receive(:ensure_connected).and_wrap_original do |original, *args|
        original.call(*args)
        connected << :in
        release.pop
      end

      listener = Thread.new do
        Thread.current.report_on_exception = false
        server.listen(notifications: { tools_list_changed: true })
      end
      connected.pop(timeout: 10)
      server.cleanup
      release << :go

      expect { listener.value }.to raise_error(MCPClient::Errors::ConnectionError)
      sleep 0.1
      expect(listen_post).not_to have_been_requested
      expect(server.subscriptions).to be_empty
      expect(server.send(:listen_threads)).to be_empty
    end
  end

  # codex [P2] json_rpc_transport.rb:84: the subscription's lock is released
  # before the listen is written, so a close landing in that window cancelled
  # an id the server had not been sent yet — "the cancelled request MUST have
  # been previously issued" (basic/patterns/cancellation).
  describe 'a stdio close that races the write of the listen it would cancel' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }

    before do
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      handle = double('stdin', flush: nil, closed?: false, close: nil)
      allow(handle).to receive(:puts) { |line| written << JSON.parse(line) }
      server.instance_variable_set(:@stdin, handle)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
    end

    it 'never writes notifications/cancelled before the listen it names' do
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
        server.listen(notifications: { tools_list_changed: true })
      end
      writing.pop(timeout: 10)
      subscription = server.subscriptions.values.first
      # Runs to completion while the listen is still unwritten: whatever this
      # cancels, it cancels before the request reaches the pipe.
      subscription.close
      release << :go
      opener.join(10)

      methods = written.map { |message| message['method'] }
      expect(methods.first).to eq('subscriptions/listen')
      expect(methods).to include('notifications/cancelled')
      cancelled = written.select { |message| message['method'] == 'notifications/cancelled' }
      expect(cancelled.map { |message| message['params']['requestId'] }).to eq([subscription.id])
    end
  end

  # codex [P2] subscription_support.rb:32: `listen` opened the stream and
  # returned the handle without arranging any deadline, so a server that
  # answered discovery and then never acknowledged left it pending for ever —
  # "implementations SHOULD establish timeouts for all sent requests ... [and]
  # SHOULD issue a cancellation notification for that request"
  # (basic/patterns/cancellation "Timeouts").
  describe 'a listen the server never acknowledges' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }

    before do
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      handle = double('stdin', flush: nil, closed?: false, close: nil)
      allow(handle).to receive(:puts) { |line| written << JSON.parse(line) }
      server.instance_variable_set(:@stdin, handle)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      allow(server).to receive(:send_request) { |request, **_o| written << request }
    end

    def acknowledge(subscription)
      server.handle_line("#{JSON.generate('jsonrpc' => '2.0',
                                          'method' => 'notifications/subscriptions/acknowledged',
                                          'params' => { '_meta' => { sub_meta => subscription.id },
                                                        'notifications' => subscription.requested })}\n")
    end

    it 'ends the handle on the deadline the transport read timeout sets, and cancels the request' do
      allow(server).to receive(:subscription_ack_timeout).and_return(0.1)

      subscription = server.listen(notifications: { tools_list_changed: true })

      expect(subscription.wait_until_settled(5)).to eq(:closed)
      expect(subscription.error).to be_a(MCPClient::Errors::RequestTimeoutError)
      cancelled = written.select { |message| message['method'] == 'notifications/cancelled' }
      expect(cancelled.map { |message| message['params']['requestId'] }).to eq([subscription.id])
    end

    it 'takes the deadline the caller gives it instead' do
      allow(server).to receive(:subscription_ack_timeout).and_return(60)

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.1)

      expect(subscription.wait_until_settled(5)).to eq(:closed)
      expect(subscription.error).to be_a(MCPClient::Errors::RequestTimeoutError)
    end

    it 'leaves an acknowledged subscription running for as long as the server keeps it' do
      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.1)
      acknowledge(subscription)

      sleep 0.3

      expect(subscription).to be_active
      expect(written.map { |message| message['method'] }).not_to include('notifications/cancelled')
    end

    it 'accepts a caller that wants no deadline at all' do
      allow(server).to receive(:subscription_ack_timeout).and_return(0.05)

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: false)

      sleep 0.2
      expect(subscription.state).to eq(:pending)
      subscription.close
    end
  end

  # The same deadline on Streamable HTTP, where an unacknowledged stream that
  # keeps arriving is bounded by nothing else.
  describe 'an HTTP listen the server never acknowledges' do
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
    end

    after { server.cleanup }

    it 'ends the handle on the deadline' do
      stub_request(:post, 'https://example.com/mcp')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: ": keep-alive\n\n")
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 5)

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.1)

      expect(subscription.wait_until_settled(5)).to eq(:closed)
      expect(subscription.error).to be_a(MCPClient::Errors::RequestTimeoutError)
    end
  end

  # codex [P2] subscription_support.rb:261: the closing response was checked
  # against the result types the client recognizes at all, and then finished
  # gracefully whatever it was. `input_required` is recognized — and means the
  # request is *not* complete; subscriptions/listen is not one of the requests
  # a server may answer with one (basic/patterns/mrtr "Supported Requests").
  describe 'a listen answered with a non-completion result' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    before do
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      server.instance_variable_set(:@stdin,
                                   double('stdin', flush: nil, closed?: true, close: nil, puts: nil))
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response) do |id, **_options|
        { 'jsonrpc' => '2.0', 'id' => id,
          'result' => { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                        'capabilities' => { 'tools' => { 'listChanged' => true } } } }
      end
    end

    it 'fails the subscription instead of reporting a graceful close' do
      subscription = server.listen(notifications: { tools_list_changed: true })

      server.handle_line("#{JSON.generate('jsonrpc' => '2.0', 'id' => subscription.id,
                                          'result' => { 'resultType' => 'input_required',
                                                        'requestState' => 'resume-me',
                                                        '_meta' => { sub_meta => subscription.id } })}\n")

      expect(subscription).to be_closed
      expect(subscription).not_to be_closed_gracefully
      expect(subscription.error).to be_a(MCPClient::Errors::InvalidResultError)
      expect(subscription.error.message).to include('input_required')
    end

    it 'still closes gracefully on a complete result' do
      subscription = server.listen(notifications: { tools_list_changed: true })

      server.handle_line("#{JSON.generate('jsonrpc' => '2.0', 'id' => subscription.id,
                                          'result' => { 'resultType' => 'complete' })}\n")

      expect(subscription).to be_closed_gracefully
      expect(subscription.error).to be_nil
    end
  end
end
