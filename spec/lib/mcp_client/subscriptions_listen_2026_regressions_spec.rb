# frozen_string_literal: true

require 'spec_helper'
require 'rbconfig'
require 'socket'
require 'stringio'
require 'tmpdir'
require 'webmock/rspec'

# MCP 2026-07-28 subscriptions/listen: regression suite.
#
# These examples were written one adversarial review round at a time, each
# pinning a defect that round found. They are gathered here by subject
# rather than by the round that produced them; the round is noted on each
# section only because the review notes refer to it. Every example here
# covers production code no other spec reaches.

# --- verify ----------------------------------------------------------------

# Verification pass over the eleven review rounds: five findings the earlier
# rounds left, three of them driven against a real subprocess rather than a
# scripted one.
#
# * **an exit during initialization.** A replacement process that answered the
#   discovery probe and then exited reached EOF while `@initialized` was still
#   false, so its reader skipped the unexpected-exit handling entirely.
#   Initialization then marked the dead connection initialized and re-sent the
#   open subscriptions to it; the writes failed and were deferred back onto the
#   queue, and with no reader left nothing ever restarted the process. The
#   subscriptions stayed `:reconnecting` for ever with no error to tell the
#   host why.
#
# * **a stale listen write.** `send_request` read the transport's *current*
#   stdin, so a listen write that was still pending when the process exited was
#   written to the process that replaced it — a second stream on the
#   replacement whose id the teardown had already forgotten, which `close`
#   could no longer name.
#
# * **a listen that opens after cleanup.** On Streamable HTTP a `listen` paused
#   between `ensure_session_ready` and the request went on to register and POST
#   after a `cleanup` had closed the (then empty) registries — and a later
#   `cleanup` returns early on a transport that is already disconnected, so
#   nothing ever closed that stream.
#
# * **an intentional reconnect read as a crash loop.** The crash-loop bound
#   only asks how long the process that carried the subscriptions lasted after
#   receiving them, so a host that closed the transport itself and reconnected
#   within the interval had its subscriptions closed for a crash that never
#   happened.
#
# * **the client's caches and the delivery.** Round 10 moved the host callback
#   to the end of the routing order — and this client's own cache invalidation
#   was registered on that callback, so a listener reacting to a list_changed
#   notification could read the very entry the notification says is stale.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — verification' do
  def sub_meta
    'io.modelcontextprotocol/subscriptionId'
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'resources' => { 'subscribe' => true, 'listChanged' => true } } }
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise 'condition not met in time' unless yield
  end

  # A real MCP stdio server, small enough to read: it answers the discovery
  # probe as a 2026-07-28 server, appends every request it is sent to a log so
  # an example can see which process received what, and dies when and how the
  # example asks it to.
  def stdio_server_source
    <<~'RUBY'
      require 'json'
      $stdout.sync = true

      log = ENV.fetch('MCP_SPEC_LOG')
      state = ENV.fetch('MCP_SPEC_STATE')
      die_after_discover_from = ENV.fetch('MCP_SPEC_DIE_AFTER_DISCOVER_FROM', '0').to_i
      die_on_listen_from = ENV.fetch('MCP_SPEC_DIE_ON_LISTEN_FROM', '0').to_i

      generation = (File.exist?(state) ? File.read(state).to_i : 0) + 1
      File.write(state, generation.to_s)
      File.open(log, 'a') { |f| f.puts("spawn #{generation}") }

      discover = {
        'resultType' => 'complete',
        'supportedVersions' => ['2026-07-28'],
        'capabilities' => { 'resources' => { 'subscribe' => true, 'listChanged' => true } }
      }

      $stdin.each_line do |line|
        begin
          message = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        File.open(log, 'a') { |f| f.puts("#{generation} #{message['method']} #{message['id']}") }
        case message['method']
        when 'server/discover'
          $stdout.puts(JSON.generate('jsonrpc' => '2.0', 'id' => message['id'], 'result' => discover))
          $stdout.flush
          exit!(0) if die_after_discover_from.positive? && generation >= die_after_discover_from
        when 'subscriptions/listen'
          exit!(0) if die_on_listen_from.positive? && generation >= die_on_listen_from
        end
      end
    RUBY
  end

  # A transport wired to a real child process, so the restart lifecycle under
  # test is the one the operating system drives: real pipes, a real EOF, a real
  # respawn.
  shared_context 'a real stdio server' do
    let(:workdir) { Dir.mktmpdir('mcp-verify') }
    let(:script) { File.join(workdir, 'server.rb') }
    let(:log_path) { File.join(workdir, 'requests.log') }
    let(:state_path) { File.join(workdir, 'generation') }
    let(:servers) { [] }

    before do
      File.write(script, stdio_server_source)
      File.write(log_path, '')
    end

    after do
      servers.each do |server|
        server.cleanup
      rescue StandardError
        nil
      end
      FileUtils.remove_entry(workdir)
    end

    def build_server(die_on_listen_from: 0, die_after_discover_from: 0)
      server = MCPClient::ServerStdio.new(
        command: [RbConfig.ruby, script],
        read_timeout: 2,
        discover_timeout: 2,
        env: {
          'MCP_SPEC_LOG' => log_path,
          'MCP_SPEC_STATE' => state_path,
          'MCP_SPEC_DIE_ON_LISTEN_FROM' => die_on_listen_from.to_s,
          'MCP_SPEC_DIE_AFTER_DISCOVER_FROM' => die_after_discover_from.to_s
        }
      )
      servers << server
      server
    end

    def log_lines
      File.readlines(log_path, chomp: true)
    rescue Errno::ENOENT
      []
    end

    def spawns
      log_lines.count { |line| line.start_with?('spawn ') }
    end

    def listens_received
      log_lines.select { |line| line.include?('subscriptions/listen') }
    end
  end

  # codex [P1] server_stdio.rb:173: `handle_server_exit if @initialized && ...`
  # — EOF seen before initialization finished was not an exit at all, so the
  # subscriptions the dead process was about to be handed were stranded with
  # nothing left to restart it.
  describe 'a replacement process that exits during initialization' do
    include_context 'a real stdio server'

    it 'is noticed by its own reader, so the subscriptions end instead of waiting for ever' do
      server = build_server(die_on_listen_from: 1, die_after_discover_from: 2)
      probes = 0
      allow(server).to receive(:negotiate_protocol).and_wrap_original do |original|
        original.call
        probes += 1
        next if probes < 2

        # The replacement answered the probe and then exited. Let its reader
        # reach EOF while initialization is still in flight: that is the state
        # the reader used to walk away from.
        server.instance_variable_get(:@wait_thread)&.join(10)
        sleep 0.1
      end

      subscription = server.listen(notifications: { tools_list_changed: true })

      wait_until(10) { subscription.closed? }
      expect(subscription.error).to be_a(MCPClient::Errors::MCPError)
      # A restart was attempted after the exit-during-initialization, and the
      # crash-loop bound stopped it there rather than respawning for ever.
      expect(spawns).to be >= 3
      expect(server.instance_variable_get(:@initialized)).to be(false)
    end
  end

  # codex [P1] json_rpc_transport.rb:65: `send_request` read the transport's
  # current stdin, so a listen write that was outstanding when the process
  # exited landed on the process that replaced it — a stream `close` could no
  # longer name, since the teardown had forgotten its id.
  describe 'a listen write outstanding when the process it was opening on exits' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:old_writes) { [] }
    let(:new_writes) { [] }

    def recording_handle(sink)
      double('stdio', flush: nil, closed?: true, close: nil).tap do |handle|
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

    it 'writes it to the process it was opening on, never to the one that replaced it' do
      subscription = MCPClient::Subscription.new(server: server, requested: { 'toolsListChanged' => true })
      entered = Thread::Queue.new
      release = Thread::Queue.new
      blocked = false
      allow(subscription).to receive(:record_outstanding_listen).and_wrap_original do |original, id|
        original.call(id)
        next if blocked

        blocked = true
        entered << id
        release.pop
      end

      opener = Thread.new { server.open_subscription(subscription) }
      stale_id = entered.pop(timeout: 10)

      # The process exits under the blocked write; the restart hands the
      # subscription to the replacement under a fresh id.
      server.send(:handle_server_exit)
      reopened_id = subscription.id
      expect(reopened_id).not_to eq(stale_id)

      release << :go
      opener.join(10)

      expect(listen_ids(new_writes)).to eq([reopened_id])
      expect(listen_ids(old_writes)).to eq([stale_id])

      subscription.close
      # Every listen the replacement was actually sent is cancelled, because
      # every listen it was sent is one this client recorded against it.
      expect(cancelled_ids(new_writes)).to eq(listen_ids(new_writes))
    end
  end

  # codex [P1] subscription_support.rb:25 with listen_stream.rb:47: a `listen`
  # paused after `ensure_session_ready` registered and POSTed on a connection a
  # `cleanup` had already closed — and `cleanup` returns early on a transport
  # that is already disconnected, so no later one could find that stream.
  describe 'an HTTP listen that resumes after the connection was closed' do
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    before do
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
    end

    it 'refuses to open, instead of leaving a stream nothing can close' do
      listen_post = stub_request(:post, 'https://example.com/mcp')
                    .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: '')
      entered = Thread::Queue.new
      release = Thread::Queue.new
      allow(MCPClient::Subscription).to receive(:new).and_wrap_original do |original, **kwargs, &block|
        entered << :in
        release.pop
        original.call(**kwargs, &block)
      end

      listener = Thread.new do
        Thread.current.report_on_exception = false
        server.listen(notifications: { tools_list_changed: true })
      end
      entered.pop(timeout: 10)
      server.cleanup
      release << :go

      expect { listener.value }.to raise_error(MCPClient::Errors::ConnectionError)
      sleep 0.1
      expect(listen_post).not_to have_been_requested
      expect(server.subscriptions).to be_empty
      expect(server.send(:listen_threads)).to be_empty
      expect(server.instance_variable_get(:@connection_established)).to be(false)
    end
  end

  # codex [P2] the crash-loop bound counted any teardown within the interval,
  # including one the host asked for, so an intentional reconnect closed the
  # subscriptions it was supposed to carry across.
  describe 'a host that closes the transport itself and reconnects' do
    include_context 'a real stdio server'

    it 'has its subscriptions re-sent rather than closed for a crash that never happened' do
      server = build_server
      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { listens_received.size == 1 }

      # The first hand-over: nothing carried them before, so no bound applies.
      server.cleanup
      server.ensure_initialized
      wait_until { listens_received.size == 2 }
      expect(subscription).not_to be_closed

      # The second: the process that carried them was torn down well inside
      # SUBSCRIPTION_RESTART_MIN_INTERVAL — by the host, not by a crash.
      server.cleanup
      server.ensure_initialized
      wait_until { listens_received.size == 3 }

      expect(subscription).not_to be_closed
      expect(subscription.error).to be_nil
    end

    # The bound still has to fire, or "not a crash loop" would just be "no
    # bound": the same two cycles, with the second teardown a real exit.
    it 'still refuses a process that really did exit right after receiving them' do
      server = build_server(die_on_listen_from: 2)
      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { listens_received.size == 1 }

      server.cleanup
      server.ensure_initialized
      # The replacement is handed the subscription and dies on receiving it —
      # a crash loop, and the restart that follows must not feed it again.
      wait_until(10) { subscription.closed? }
      expect(subscription.error).to be_a(MCPClient::Errors::TransportError)
      expect(spawns).to be <= 3
    end
  end

  # codex [P2] the client's own caches were dropped by `process_notification`,
  # registered on `on_notification` — which round 10 moved to run *after* the
  # delivery to a subscription's listeners.
  describe 'the client caches a subscription listener may read' do
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end
    let(:client) do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'x' }])
    end

    it 'are gone before the listener runs, however slow the host callback is' do
      client.tool_cache['server:tool'] = 'a tool'
      seen = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |_method, _params|
        seen << client.tool_cache.dup
      end
      subscription.assign_id(11)
      server.register_subscription(subscription)
      # The host callback is the last routing step and the only one that can
      # block. While this client's invalidation rode on it, a listener that ran
      # while it was blocked read the stale entry.
      allow(server).to receive(:notify_host).and_wrap_original do |original, *args|
        sleep 0.2
        original.call(*args)
      end

      server.route_notification('notifications/tools/list_changed', { '_meta' => { sub_meta => 11 } })

      expect(seen.pop(timeout: 10)).to be_empty
      subscription.finish
    end

    it 'orders the client invalidation with the transport invalidation, ahead of the delivery' do
      order = []
      allow(server).to receive(:invalidate_cache_for_notification) { order << :transport_cache }
      allow(client).to receive(:invalidate_caches_for_notification).and_wrap_original do |original, *args|
        order << :client_cache
        original.call(*args)
      end
      allow(server).to receive(:deliver_subscription_notification) { order << :listeners }
      client.on_notification { |_server, _method, _params| order << :host_listener }

      server.route_notification('notifications/prompts/list_changed', {})

      expect(order).to eq(%i[transport_cache client_cache listeners host_listener])
    end

    # The hook has to reach the paths that fan a notification out without
    # routing a subscription, or moving the invalidation onto it would simply
    # have stopped invalidating there.
    it 'still drops them for a refresh the transport announces itself' do
      allow(server).to receive(:list_tools).and_return([])
      client.tool_cache['server:tool'] = 'a tool'

      server.send(:refresh_tools_cache)

      expect(client.tool_cache).to be_empty
    end

    it 'still drops them on the legacy SSE transport, which routes none' do
      sse = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
      allow(MCPClient::ServerFactory).to receive(:create).and_return(sse)
      sse_client = MCPClient::Client.new(mcp_server_configs: [{ type: 'sse', base_url: 'https://example.com/sse' }])
      sse_client.tool_cache['server:tool'] = 'a tool'

      sse.send(:process_notification?, { 'method' => 'notifications/tools/list_changed', 'params' => {} })

      expect(sse_client.tool_cache).to be_empty
    end
  end
end

# --- verify2 ---------------------------------------------------------------

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

    # A stream that ends the moment it opens is a drop, not a silent server:
    # the request it carried is over and the transport is waiting to send the
    # next one. Round 14 (grok): the deadline bounds the listen that is in
    # flight, so it does not fire during that wait — expiring there closed the
    # handle `by_client`, which is also unreconnectable, and a server
    # answering 503 for longer than the backoff unsubscribed the host without
    # ever having refused anything.
    #
    # The deadline doing its job on a request that really is outstanding — and
    # closing the response stream, the cancellation signal on this transport —
    # needs a peer holding one open to be visible, and is pinned in verify3.
    it 'does not end the handle while it is waiting to re-open the stream' do
      stub_request(:post, 'https://example.com/mcp')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: ": keep-alive\n\n")
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 5)

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: 0.1)

      expect(subscription.wait_until_settled(0.5)).to be_nil
      expect(subscription).not_to be_closed
      expect(subscription).to be_reconnectable
      expect(subscription.error).to be_nil
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

# --- verify3 ---------------------------------------------------------------

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

    # codex round 5 [P2]: without a concurrent close the cancellation was never
    # sent at all — the write raised, the subscription ended with the error,
    # and the server was left serving `listen(n)` with nobody able to name it.
    # "Abandoning" a request on stdio is a cancellation naming its id
    # (basic/transports/stdio "Cancellation"), whoever abandons it.
    it 'cancels the request a failed write may have put on the pipe before reporting the failure' do
      expect { server.listen(notifications: { tools_list_changed: true }, ack_timeout: false) }
        .to raise_error(MCPClient::Errors::TransportError, /Broken pipe/)

      listen = written.find { |message| message['method'] == 'subscriptions/listen' }
      expect(written.map { |message| message['method'] }).to eq(%w[subscriptions/listen notifications/cancelled])
      expect(written.last['params']['requestId']).to eq(listen['id'])
      expect(server.subscriptions).to be_empty
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

  # codex round 5 [P2]: the buffer was trimmed only at an event terminator, so
  # a server keeping the stream alive with complete comment lines alone —
  # `:\r\n`, which the transport specification permits and tells clients to
  # ignore — grew it without bound until the cap ended the subscription.
  describe 'a listen stream kept alive with comment lines' do
    include_context 'a scripted HTTP session'

    # The parser, fed what arrives: comment lines are dropped on arrival, a
    # comment still missing its line end is kept until it arrives, and a CR
    # at the very end is not taken for the whole of a CRLF.
    it 'discards complete comment lines on arrival and keeps an unfinished one' do
      subscription = MCPClient::Subscription.new(server: server, requested: { 'toolsListChanged' => true })
      subscription.assign_id(1)
      state = { finished: nil, scanned: 0, framing: :sse }
      buffer = +''

      buffer << (":\r\n" * 2000)
      server.send(:consume_listen_events, buffer, subscription, state)
      expect(buffer).to eq('')

      buffer << ': keep-al'
      server.send(:consume_listen_events, buffer, subscription, state)
      expect(buffer).to eq(': keep-al')

      buffer << "ive\r"
      server.send(:consume_listen_events, buffer, subscription, state)
      expect(buffer).to eq(": keep-alive\r")

      buffer << "\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"," \
                "\"params\":{}}\r\n:\r\n\r\n"
      server.send(:consume_listen_events, buffer, subscription, state)
      expect(buffer).to eq('')
      expect(subscription).not_to be_closed
    end

    it 'discards complete comment lines as they arrive and keeps delivering' do
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_MAX_BUFFER_BYTES', 512)
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 30)
      received = []
      stub_listen do |body|
        id = body['id']
        closing = { 'jsonrpc' => '2.0', 'id' => id,
                    'result' => { 'resultType' => 'complete', '_meta' => { sub_meta => id } } }
        change = { 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                   'params' => { '_meta' => { sub_meta => id } } }
        { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
          body: "#{":\r\n" * 2000}#{sse_response(ack_message(id, { 'toolsListChanged' => true }))[:body]}" \
                "#{": keep-alive\n" * 500}\r#{sse_response(change, closing)[:body]}" }
      end

      subscription = server.listen(notifications: { tools_list_changed: true }) { |method, _p| received << method }
      wait_until { subscription.closed? }

      expect(subscription.error).to be_nil
      expect(subscription).to be_closed_gracefully
      expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })
      wait_until { received.any? }
      expect(received).to eq(['notifications/tools/list_changed'])
    end
  end

  # The skip-and-continue branches of the stream parser: an event that is not
  # JSON, or not a JSON object, is skipped and the stream goes on.
  describe 'a listen stream carrying an unreadable event' do
    include_context 'a scripted HTTP session'

    it 'skips it and keeps delivering what follows' do
      received = []
      stub_listen do |body|
        id = body['id']
        closing = { 'jsonrpc' => '2.0', 'id' => id,
                    'result' => { 'resultType' => 'complete', '_meta' => { sub_meta => id } } }
        change = { 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                   'params' => { '_meta' => { sub_meta => id } } }
        { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
          body: "event: message\ndata: {not json\n\n" \
                "#{sse_response(ack_message(id, { 'toolsListChanged' => true }))[:body]}" \
                "event: message\ndata: [1, 2]\n\n#{sse_response(change, closing)[:body]}" }
      end

      subscription = server.listen(notifications: { tools_list_changed: true }) { |method, _p| received << method }
      wait_until { subscription.closed? }

      expect(subscription).to be_closed_gracefully
      expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })
      wait_until { received.any? }
      expect(received).to eq(['notifications/tools/list_changed'])
    end
  end
end

# --- round3 ----------------------------------------------------------------

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

# --- round4 ----------------------------------------------------------------

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
        expect(subscription.error.code).to eq(-32_602)
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

# --- round5 ----------------------------------------------------------------

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

# --- round7 ----------------------------------------------------------------

# Review round 7 (codex, grok), on the code round 6 left: a listen write that
# failed after a restart had already re-opened the same subscription and tore
# the healthy replacement down; a readiness stamp a nested restart wiped, so
# the crash-loop bound round 6 introduced never fired; subscriptions stranded
# :reconnecting when the restarted process turned out to be legacy; a host
# notification callback whose exception swallowed the delivery to the
# subscription's listeners; a byte ceiling that evicted the only notice of one
# resource to admit a notice of another; a resource re-acknowledgment that
# landed before the URI was mapped and was therefore not checked; a requested
# filter that kept the caller's own mutable array; and an acknowledgment that
# counted as support merely by naming the field.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 7' do
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

  # codex [P1] json_rpc_transport.rb:68-69: the child can exit while the
  # initial listen write is blocked; the EOF handler restarts the process and
  # re-opens the very same Subscription under a new id, and the older write's
  # rescue then unregistered *that* id and finished the subscription — closing
  # the healthy replacement stream.
  describe 'a listen write that fails after a restart re-opened the subscription' do
    include_context 'a scripted stdio session'

    it 'leaves the stream the restart opened alone' do
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

      opened = nil
      failure = nil
      opener = Thread.new do
        opened = server.listen(notifications: { tools_list_changed: true })
      rescue StandardError => e
        failure = e
      end
      entered.pop(timeout: 3)

      # The process exits under the blocked write and the restart re-sends the
      # subscription with a fresh id.
      server.send(:handle_server_exit)
      subscription = server.subscriptions.values.first
      expect(subscription).not_to be_nil
      expect(subscription.id).not_to eq(blocked_id)
      reopened_id = subscription.id

      release << :go
      opener.join(3)

      expect(failure).to be_nil
      expect(opened).to equal(subscription)
      expect(subscription).not_to be_closed
      expect(server.subscription_by_id(reopened_id)).to equal(subscription)
      expect(listens.size).to eq(2)
    end
  end

  # grok [1] json_rpc_transport.rb:37-40, 132-138 with server_stdio.rb:797-803:
  # a second restart beginning while the first is still inside
  # ensure_initialized cleared the shared "restarting" flag on its way out, so
  # the session the second restart established stamped nil and every later
  # exit read the crash loop as a healthy server.
  describe 'a restart that begins while the previous one is still finishing' do
    include_context 'a scripted stdio session'

    it 'still counts the session the nested restart established against the crash-loop bound' do
      stub_const('MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL', 0.05)
      subscription = server.listen(notifications: { tools_list_changed: true })
      nested = nil

      # The process the first restart spawned exits while that restart is
      # still re-sending subscriptions to it: its reader runs
      # handle_server_exit on its own thread, which blocks on the init lock
      # the first restart is holding.
      allow(server).to receive(:reopen_subscriptions).and_wrap_original do |original, *args|
        if nested.nil?
          sleep 0.1 # outlive the crash-loop interval, so this exit is not itself a loop
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
  end

  # codex [P2] json_rpc_transport.rb:77-78: cleanup has already moved the open
  # subscriptions into @reconnecting_subscriptions, so returning from
  # reopen_subscriptions on a legacy session neither re-opened nor closed
  # them: their handles stayed :reconnecting for ever.
  describe 'a restarted stdio process that negotiates a legacy version' do
    include_context 'a scripted stdio session'

    it 'fails the subscriptions the new session cannot carry' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      allow(server).to receive(:negotiate_protocol) do
        server.instance_variable_set(:@protocol_version, '2025-11-25')
      end

      server.send(:handle_server_exit)

      expect(subscription).to be_closed
      expect(subscription.error).to be_a(MCPClient::Errors::CapabilityError)
      expect(subscription.error.message).to include('2025-11-25')
      expect(subscription.state).to eq(:closed)
    end
  end

  # grok [4] subscription_support.rb:101-106: round 6 moved the delivery to the
  # subscription's listeners behind the host callback so the caches would be
  # invalidated first — which let a host callback that raises drop the
  # notification the listeners were waiting for.
  describe 'a host notification callback that raises' do
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
    end

    it 'still invalidates both caches first and still reaches the listeners' do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'x' }])
      server.instance_variable_set(:@tools, ['a tool'])
      client.tool_cache['server:tool'] = 'a tool'
      client.on_notification { |_srv, _method, _params| raise 'host handler exploded' }
      seen = Thread::Queue.new
      subscription = MCPClient::Subscription.new(server: server, requested: {}) do |method, _params|
        seen << [method, server.instance_variable_get(:@tools), client.tool_cache.dup]
      end
      subscription.assign_id(7)
      server.register_subscription(subscription)

      expect do
        server.route_notification('notifications/tools/list_changed', { '_meta' => { sub_meta => 7 } })
      end.not_to raise_error

      method, transport_cache, client_cache = seen.pop(timeout: 3)
      expect(method).to eq('notifications/tools/list_changed')
      expect(transport_cache).to be_nil
      expect(client_cache).to be_empty
      subscription.finish
    end
  end

  # grok [2] notification_dispatcher.rb:155-188: a payload larger than the whole
  # budget is queued alone by design, but charging it against the budget left
  # the queue permanently overflowing — so the next notice of anything else
  # evicted it, which is the "only notice of one thing" loss the policy exists
  # to prevent.
  describe 'a queued notification larger than the whole byte budget' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def updated(uri, payload)
      ['notifications/resources/updated',
       { 'uri' => uri, 'blob' => payload, '_meta' => { sub_meta => 1 } }]
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
      subscription.deliver(*updated('file:///blocker', 'x'))
      entered.pop(timeout: 3)
      [subscription, release]
    end

    it 'is not evicted by the next notice of something else' do
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

    it 'is still the only oversized payload the queue retains' do
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
  end

  # grok [3] subscription_support.rb:238-254, 265-275: round 6's revalidation
  # reads the resource_subscriptions mapping, which open_resource_subscription
  # only writes after confirm_resource_subscription has returned — so a
  # narrowing re-acknowledgment inside that window was invisible and the stream
  # was stored as a live watch.
  describe 'a resource subscription re-acknowledged before its URI is mapped' do
    include_context 'a scripted stdio session'

    let(:uri) { 'file:///watched.txt' }

    before { server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION) }

    def acknowledge(id, filter)
      server.route_notification('notifications/subscriptions/acknowledged',
                                { '_meta' => { sub_meta => id }, 'notifications' => filter })
    end

    it 'does not store a watch the server stopped honouring in that window' do
      allow(server).to receive(:confirm_resource_subscription).and_wrap_original do |original, subscription, wanted|
        acknowledge(subscription.id, { 'resourceSubscriptions' => [wanted] })
        original.call(subscription, wanted)
        # The stream is re-opened and acknowledged again before the caller
        # has had a chance to map the URI to it.
        acknowledge(subscription.id, { 'toolsListChanged' => true })
      end

      expect { server.subscribe_resource_via_listen(uri) }
        .to raise_error(MCPClient::Errors::ResourceReadError, /without '#{Regexp.escape(uri)}'/)
      expect(server.live_resource_subscription(uri)).to be_nil
      expect(server.subscriptions_mutex.synchronize { server.resource_subscriptions }).to be_empty
    end
  end

  # codex [P2] subscription.rb:106: an array-valued filter kept the caller's own
  # array and its mutable strings, and Streamable HTTP serializes the request on
  # a background thread after listen has returned.
  describe 'the filter a listen request carries' do
    include_context 'a scripted stdio session'

    it 'detaches and freezes an array-valued filter from the caller' do
      uris = ['file:///a'.dup]
      subscription = server.listen(notifications: { resource_subscriptions: uris })

      uris << 'file:///b'
      uris.first << '/mutated'

      expect(subscription.requested['resourceSubscriptions']).to eq(['file:///a'])
      expect(subscription.requested['resourceSubscriptions']).to be_frozen
      expect(subscription.requested['resourceSubscriptions'].first).to be_frozen
      expect(subscription.requested).to be_frozen
    end

    it 'serializes the normalized filter detached from the strings the caller passed' do
      uris = ['file:///a'.dup]
      filter = MCPClient::Subscription.normalize_filter('resourceSubscriptions' => uris)

      uris.first.replace('file:///elsewhere')

      expect(JSON.generate(filter)).to eq(JSON.generate({ 'resourceSubscriptions' => ['file:///a'] }))
    end
  end

  # codex [P2] subscription.rb:192: unsupported compared field names only, so a
  # server that echoed resourceSubscriptions with an empty array reported the
  # field as supported although it had accepted none of the URIs.
  describe 'what an acknowledgment has to grant to count as supported' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def subscription_for(filter)
      MCPClient::Subscription.new(server: server, requested: MCPClient::Subscription.normalize_filter(filter))
    end

    it 'reports a resource subscription the server granted no URI of as unsupported' do
      subscription = subscription_for('resourceSubscriptions' => ['file:///a'])

      subscription.acknowledge({ 'resourceSubscriptions' => [] })

      expect(subscription.unsupported).to eq(['resourceSubscriptions'])
      expect(subscription.unacknowledged_resource_uris).to eq(['file:///a'])
    end

    it 'reports a flag the server acknowledged as false as unsupported' do
      subscription = subscription_for('toolsListChanged' => true)

      subscription.acknowledge({ 'toolsListChanged' => false })

      expect(subscription.unsupported).to eq(['toolsListChanged'])
    end

    it 'still reports a partially granted list as supported' do
      subscription = subscription_for('resourceSubscriptions' => ['file:///a', 'file:///b'],
                                      'toolsListChanged' => true)

      subscription.acknowledge({ 'resourceSubscriptions' => ['file:///a'], 'toolsListChanged' => true })

      expect(subscription.unsupported).to be_empty
      expect(subscription.unacknowledged_resource_uris).to eq(['file:///b'])
    end

    it 'still reports a field the server left out as unsupported' do
      subscription = subscription_for('resourcesListChanged' => true, 'toolsListChanged' => true)

      subscription.acknowledge({ 'toolsListChanged' => true })

      expect(subscription.unsupported).to eq(['resourcesListChanged'])
    end
  end
end

# --- round8 ----------------------------------------------------------------

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

# --- round10 ---------------------------------------------------------------

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
      # A real open records the listen it writes, and only a written listen may
      # be cancelled (see {MCPClient::Subscription#take_outstanding_listens}).
      # This fixture assigns the id by hand, so it records the write by hand.
      subscription.record_outstanding_listen(11)
      subscription.mark_listen_written(11)
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

# --- round11 ---------------------------------------------------------------

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
      # This server's own traffic, not the process-global registry: another
      # example's leaked events thread must not decide this one.
      expect(server.instance_variable_get(:@events_thread)).to be_nil
      expect(a_request(:get, url).with(headers: { 'Mcp-Protocol-Version' => '2026-07-28' }))
        .not_to have_been_made
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

# --- round14 ---------------------------------------------------------------

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
