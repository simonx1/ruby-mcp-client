# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'tmpdir'
require 'rbconfig'

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
