# frozen_string_literal: true

require 'spec_helper'

# Review round 13 (codex). The teardown of a stdio process is now the
# teardown of *that* process: a reader whose process exited claims its
# handles once, under the transport lock, and tears down what it claimed —
# so a host request that observed the exit and re-established the process in
# the meantime is left alone, however late the old reader's own teardown
# finishes. The published SubscriptionFilter has four members; anything
# beyond them (the tasks extension's `taskIds`) is registered by the
# extension that defines it. And a listen stream's size cap is enforced on
# what arrives, before it is parsed, so a complete oversized event is refused
# whatever the chunk boundaries happened to be.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 13' do
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

  # A stdio transport whose process, handshake and writes are all stubbed, so
  # an example can drive the restart lifecycle by hand. Every `connect`
  # installs a fresh stdin double, so the process a request went to can be
  # told from the process that replaced it.
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
      # Like the real `connect`: the handles and the generation change
      # together, and a fresh process is not the one that was retired.
      allow(server).to receive(:connect) do
        server.instance_variable_get(:@transport_lock).synchronize do
          install_stdin
          server.instance_variable_set(:@transport_generation, server.instance_variable_get(:@transport_generation) + 1)
          server.instance_variable_set(:@transport_retired, false)
        end
        true
      end
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      install_stdin
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      server.instance_variable_set(:@capabilities, discover_result['capabilities'])
      allow(server).to receive(:send_request) { |request, *_rest, **_options| written << request }
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

  # --- 1. an old reader's late teardown and the replacement --------------
  describe 'a stdio teardown that finishes after a host request re-established the process' do
    include_context 'a scripted stdio session'

    # codex [P1] server_stdio.rb: the reader's EOF retired the transport and
    # entered `cleanup`; a host request observed the retirement and ran its
    # own cleanup and re-initialization, which killed the old reader without
    # joining it; the host established the replacement and re-sent the
    # subscription; and the old reader's cleanup `ensure` then cleared the
    # *replacement's* handles, reader and initialized flag, leaving a live
    # subscription registered on a transport that had just forgotten its
    # process.
    it 'leaves the replacement, its handshake and the re-sent subscription alone' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      acknowledge(subscription)
      old_stdin = server.instance_variable_get(:@stdin)
      entered = Thread::Queue.new
      release = Thread::Queue.new
      # The old process is slow to go: its reader's teardown is held at the
      # point where it waits for the process to exit.
      first_teardown = true
      allow(server).to receive(:terminate_server_process).and_wrap_original do |original, *args|
        if first_teardown
          first_teardown = false
          entered << true
          release.pop
        end
        original.call(*args)
      end

      reader = Thread.new { server.send(:handle_server_exit) }
      entered.pop
      # A host request observes the retirement and re-establishes the process
      # itself, re-sending the open subscription to the replacement.
      server.send(:ensure_initialized)
      replacement = server.instance_variable_get(:@stdin)
      expect(replacement).not_to equal(old_stdin)
      expect(listens.size).to eq(2)
      acknowledge(subscription)
      expect(subscription).to be_active

      release << true
      reader.join(3)

      expect(server.instance_variable_get(:@stdin)).to equal(replacement)
      expect(server.instance_variable_get(:@initialized)).to be(true)
      expect(server.send(:transport_retired?)).to be(false)
      expect(subscription).to be_active
      expect(subscription).not_to be_closed
      # The replacement still serves: a notification on the re-sent id is
      # delivered, and a request is registered against a live transport.
      received = Thread::Queue.new
      subscription.on_notification { |method, _params| received << method }
      server.handle_line("#{JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                                          'params' => { '_meta' => { sub_meta => subscription.id } })}\n")
      expect(received.pop(timeout: 3)).to eq('notifications/tools/list_changed')
      expect(server.send(:reconnecting_subscriptions)).to be_empty
    end

    # The mirror image: the host's own teardown is the late one. A `cleanup`
    # the host asked for claims the process it found; a reader whose process
    # exited in the meantime must not tear down what the host re-established
    # afterwards, and the host's cleanup must not touch a replacement either.
    it 'tears down only the process each teardown claimed' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      acknowledge(subscription)
      first = server.instance_variable_get(:@stdin)
      generation = server.instance_variable_get(:@transport_generation)

      server.cleanup
      expect(server.instance_variable_get(:@stdin)).to be_nil
      expect(subscription).to be_reconnecting

      server.send(:ensure_initialized)
      replacement = server.instance_variable_get(:@stdin)
      expect(replacement).not_to equal(first)
      expect(listens.size).to eq(2)

      # The first process's reader reports its EOF only now.
      server.send(:handle_server_exit, nil, generation)

      expect(server.instance_variable_get(:@stdin)).to equal(replacement)
      expect(server.instance_variable_get(:@initialized)).to be(true)
      expect(listens.size).to eq(2)
      expect(subscription).not_to be_closed
    end
  end

  # --- 2. the published filter and extension fields ------------------------
  describe MCPClient::Subscription do
    around do |example|
      saved = described_class.instance_variable_get(:@extension_filter_fields)
      described_class.instance_variable_set(:@extension_filter_fields, nil)
      example.run
    ensure
      described_class.instance_variable_set(:@extension_filter_fields, saved)
    end

    # codex [P2] subscription.rb: `taskIds` was offered as a core filter
    # field, while the published SubscriptionFilter has four members.
    it 'accepts exactly the four published SubscriptionFilter fields' do
      expect(described_class.filter_fields.keys)
        .to contain_exactly('toolsListChanged', 'promptsListChanged', 'resourcesListChanged',
                            'resourceSubscriptions')
      expect { described_class.normalize_filter({ task_ids: ['t'] }) }
        .to raise_error(ArgumentError, /Unknown subscription filter field/)
      expect { described_class.normalize_filter({ 'taskIds' => ['t'] }) }
        .to raise_error(ArgumentError, /Unknown subscription filter field/)
    end

    it 'lets an extension register a filter field of its own, with a snake_case alias' do
      described_class.register_filter_field('taskIds', :string_array, alias_name: 'task_ids')

      expect(described_class.normalize_filter({ task_ids: ['t'], tools_list_changed: true }))
        .to eq({ 'taskIds' => ['t'], 'toolsListChanged' => true })
      expect(described_class.normalize_filter({ 'taskIds' => ['t'] })).to eq({ 'taskIds' => ['t'] })
      expect { described_class.normalize_filter({ task_ids: [nil] }) }
        .to raise_error(ArgumentError, /array of strings/)
      expect { described_class.normalize_filter({ task_ids: 'a' }) }
        .to raise_error(ArgumentError, /array of strings/)
    end

    it 'refuses to redefine a published field and rejects unknown value types' do
      expect { described_class.register_filter_field('toolsListChanged', :string_array) }
        .to raise_error(ArgumentError, /published/)
      expect { described_class.register_filter_field('extra', :integer) }
        .to raise_error(ArgumentError, /boolean or string_array/)
    end
  end

  # --- 3. the size cap on what a listen stream buffers ---------------------
  describe 'a listen stream event at and beyond the buffered size cap' do
    include_context 'a scripted HTTP session'

    let(:cap) { 512 }

    before do
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_MAX_BUFFER_BYTES', cap)
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 30)
    end

    # An SSE event of exactly `bytes` bytes, terminator included, carrying an
    # acknowledgment for `id`.
    def event_of(bytes, id)
      message = ack_message(id, { 'toolsListChanged' => true })
      base = "event: message\ndata: #{JSON.generate(message)}\n\n"
      padding = bytes - base.bytesize
      raise "an acknowledgment is already #{base.bytesize} bytes" if padding.negative?

      message['params']['pad'] = 'x' * padding
      event = "event: message\ndata: #{JSON.generate(message)}\n\n"
      # JSON quoting adds the two quotes and the key once: trim the padding
      # until the event lands exactly on the requested size.
      until event.bytesize <= bytes
        message['params']['pad'] = message['params']['pad'][0...-(event.bytesize - bytes)]
        event = "event: message\ndata: #{JSON.generate(message)}\n\n"
      end
      raise "could not build an event of #{bytes} bytes" unless event.bytesize == bytes

      event
    end

    it 'accepts an event of exactly the cap' do
      stub_listen do |body|
        { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: event_of(cap, body['id']) }
      end

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: false)

      expect(subscription.wait_until_settled(5)).to eq(:active)
      expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })
    end

    # codex [P3] listen_stream.rb: complete events were consumed before the
    # buffer was measured, so an oversized event whose terminator arrived in
    # the same chunk was parsed and removed, and the cap saw an empty buffer.
    it 'refuses a complete event one byte over the cap, terminator and all' do
      stub_listen do |body|
        { status: 200, headers: { 'Content-Type' => 'text/event-stream' }, body: event_of(cap + 1, body['id']) }
      end

      subscription = server.listen(notifications: { tools_list_changed: true }, ack_timeout: false)
      wait_until { subscription.closed? }

      expect(subscription.error).to be_a(MCPClient::Errors::ConnectionError)
      expect(subscription.error.message).to include('maximum buffered size')
      expect(subscription.acknowledged).to be_nil
      expect(listen_requests.size).to eq(1)
    end

    # The parser fed what arrives, in every split: the verdict on an event
    # over the cap does not depend on where the chunk boundaries fell.
    it 'refuses the same event however it is split into chunks' do
      subscription = MCPClient::Subscription.new(server: server, requested: { 'toolsListChanged' => true })
      subscription.send(:assign_id, 7) if subscription.respond_to?(:assign_id, true)
      event = event_of(cap + 1, subscription.id || 7)

      [[1], [cap], [cap - 1, 1], [300, 100, 200], [cap + 1]].each do |cuts|
        buffer = +''
        state = { finished: nil, scanned: 0, framing: :sse }
        offset = 0
        chunks = cuts.map do |size|
          chunk = event.byteslice(offset, size)
          offset += size
          chunk
        end
        chunks << event.byteslice(offset..) if offset < event.bytesize
        expect do
          chunks.each { |chunk| server.send(:ingest_listen_chunk, buffer, chunk, subscription, state) }
        end.to raise_error(MCPClient::Errors::ConnectionError, /maximum buffered size/), "split #{cuts.inspect}"
      end
    end
  end

  # --- 4. what a host's faraday_config cannot undo (grok) -------------------
  describe 'a listen connection under a host faraday_config' do
    include_context 'a scripted HTTP session'

    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                          faraday_config: lambda { |conn|
                                            conn.request :retry, max: 3
                                            conn.adapter :net_http
                                          })
    end

    # grok round 13: `listen_connection` installed `retry max: 0` and the
    # adapter block that arms the cancellation signal, then applied the host's
    # configuration — which could add retries or replace the adapter, undoing
    # both. The host's settings now go first, the stream's own last.
    it 'keeps the stream free of retries and the cancellation hook on the adapter' do
      subscription = MCPClient::Subscription.new(server: server, requested: { 'toolsListChanged' => true })
      conn = server.send(:listen_connection, subscription)

      expect(conn.builder.handlers.map(&:klass)).not_to include(Faraday::Retry::Middleware)
      expect(conn.builder.adapter.klass).to eq(Faraday::Adapter::NetHttp)
      expect(conn.options.timeout).to eq(MCPClient::HttpTransportBase::ListenStream::LISTEN_STREAM_TIMEOUT)
      expect(conn.options.open_timeout).to eq(MCPClient::HttpTransportBase::ListenStream::LISTEN_OPEN_TIMEOUT)
    end

    it 'still arms the cancellation signal when the stream goes out' do
      armed = Thread::Queue.new
      allow(server).to receive(:arm_listen_session).and_wrap_original do |original, *args|
        armed << args.first
        original.call(*args)
      end
      stub_listen do |body|
        { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
          body: "event: message\ndata: #{JSON.generate(ack_message(body['id'], { 'toolsListChanged' => true }))}\n\n" }
      end

      subscription = server.listen(notifications: { tools_list_changed: true })

      expect(subscription.wait_until_settled(5)).to eq(:active)
      expect(armed.pop(timeout: 3)).to equal(subscription)
      expect(listen_requests.size).to eq(1)
    end
  end

  # --- 5. transports without a listen stream (grok) -------------------------
  describe 'listen on a transport that has no listen stream' do
    it 'is refused on the deprecated SSE transport whatever the session negotiated' do
      sse = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 1, retries: 0)
      sse.instance_variable_set(:@connection_established, true)
      sse.instance_variable_set(:@sse_connected, true)
      sse.instance_variable_set(:@initialized, true)
      sse.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      allow(sse).to receive(:ensure_session_ready)

      expect { sse.listen(notifications: { tools_list_changed: true }) }
        .to raise_error(MCPClient::Errors::CapabilityError, %r{does not support subscriptions/listen})
    end
  end

  # --- 6. a closing response after the client cancelled (grok) --------------
  describe 'a listen response that arrives after the client cancelled' do
    include_context 'a scripted stdio session'

    it 'is ignored: the handle stays closed by the client and nothing is re-opened' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      acknowledge(subscription)
      subscription.close
      expect(subscription).to be_closed_by_client
      before = listens.size

      server.handle_line("#{JSON.generate('jsonrpc' => '2.0', 'id' => subscription.id,
                                          'result' => { 'resultType' => 'complete' })}\n")

      expect(subscription).to be_closed_by_client
      expect(subscription).not_to be_closed_gracefully
      expect(listens.size).to eq(before)
      expect(server.send(:reconnecting_subscriptions)).to be_empty
      expect(server.instance_variable_get(:@pending)).not_to have_key(subscription.id)
    end
  end

  # --- 7. a listen rejected with a typed error keeps its data ----------------
  describe 'a listen request the server rejects with a typed error' do
    include_context 'a scripted stdio session'

    it 'ends the subscription with the typed error and the error data intact' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      data = { 'header' => 'Mcp-Param-Region', 'expected' => 'eu' }
      server.handle_line("#{JSON.generate('jsonrpc' => '2.0', 'id' => subscription.id,
                                          'error' => { 'code' => -32_020, 'message' => 'Header mismatch',
                                                       'data' => data })}\n")

      expect(subscription).to be_closed
      expect(subscription).not_to be_closed_gracefully
      expect(subscription.error).to be_a(MCPClient::Errors::ServerError)
      expect(subscription.error.code).to eq(-32_020)
      expect(subscription.error.data).to eq(data)
      expect(subscription.error.message).to include('Header mismatch')
    end
  end
end
