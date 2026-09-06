# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'

# Sixth review round (codex + grok) on the MCP 2026-07-28 stateless stdio
# work. What the reviewers found this time:
#   1. a request that had passed the initialization check could be written
#      to a replacement subprocess whose negotiation had not completed: the
#      restart clears the retirement flag before it negotiates, and the
#      generation check alone judged the half-restarted transport current;
#   2. an ordinary answer on an ESTABLISHED 2025-11-25 session that happened
#      to carry a 2026-07-28 marker identified the peer as modern, after
#      which the server's own ping, roots, sampling and elicitation requests
#      were dropped for the rest of the session;
#   3. a caller waiting on a request of the exited process saw neither its
#      answer nor the retirement when another caller restarted first: the
#      restart cleared the flag, and the waiter ran out its whole timeout;
#   4. a DiscoverResult's ttlMs was honoured only as a non-negative Integer,
#      absent and negative hints were treated as fresh forever, and a stale
#      discovery was refreshed only when it was about to refuse a capability
#      — never before reusing one it still listed;
#   5. the public client kept gating the log level on a negotiated logging
#      capability, which the modern per-request field does not need;
#   6. an extension that adds a result type could be advertised without this
#      client being able to accept that result type;
#   7. an explicit connect followed by any request spawned a second child.
R6_FIXTURE = File.expand_path('../../support/protocol_era_stdio_server.rb', __dir__)
R6_META = MCPClient::JsonRpcCommon

RSpec.describe 'MCP 2026-07-28 stateless protocol (stdio) — round 6' do
  def discover_result(versions: ['2026-07-28'], capabilities: { 'tools' => {} }, extra: {})
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => capabilities,
      'ttlMs' => 60_000 }.merge(extra)
  end

  def tool_list_result
    { 'tools' => [{ 'name' => 'echo', 'description' => 'echo', 'inputSchema' => { 'type' => 'object' } }] }
  end

  # Drive a ServerStdio without a subprocess: requests are written through
  # the real serialization path into `written` (one JSON line each), and
  # each wait is answered by the next scripted responder. Returns `written`.
  def wire_stdio(server, responses)
    written = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    stdin = double('stdin', flush: nil, closed?: false, close: nil)
    allow(stdin).to receive(:puts) { |line| written << line }
    server.instance_variable_set(:@stdin, stdin)
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(id) : responder
      raise response if response.is_a?(Exception)

      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    written
  end

  def requests_in(written)
    written.map { |line| JSON.parse(line) }.select { |msg| msg.key?('id') }
  end

  def methods_in(written)
    requests_in(written).map { |r| r['method'] }
  end

  def fixture_command(mode, transcript)
    [RbConfig.ruby, R6_FIXTURE, mode, transcript]
  end

  def transcript_lines(path)
    return [] unless File.exist?(path)

    File.readlines(path).map(&:strip).reject(&:empty?)
  rescue Errno::ENOENT
    []
  end

  def transcript_pids(path)
    transcript_lines(path).grep(/\Apid /).map { |line| Integer(line.split.last) }
  end

  def wait_for(what, timeout: 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
    raise "timed out after #{timeout}s waiting for #{what}" unless yield
  end

  # A negotiated modern transport with real pipe objects in place of a
  # subprocess; its reader threads are never started.
  def negotiated_transport
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    %i[@stdin @stdout @stderr].each { |ivar| server.instance_variable_set(ivar, StringIO.new) }
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.send(:settle_era_probe)
    server
  end

  # An established 2025-11-25 session (probe settled, handshake done).
  def legacy_session
    server = negotiated_transport
    server.instance_variable_set(:@protocol_version, '2025-11-25')
    server
  end

  # ---------------------------------------------------------------------------
  describe 'a request racing a restart that has not negotiated yet' do
    # The replacement process is installed (handles swapped, generation
    # bumped) and its negotiation is held open by the restarting thread.
    def restart_held_at_negotiation(server)
      negotiating = Queue.new
      finish = Queue.new
      replacement = StringIO.new
      allow(Open3).to receive(:popen3).and_return([replacement, StringIO.new, StringIO.new, nil])
      allow(server).to receive(:negotiate_protocol) do
        negotiating << true
        finish.pop
      end
      server.instance_variable_set(:@initialized, false)
      restarter = Thread.new { server.send(:ensure_initialized) }
      negotiating.pop
      [replacement, finish, restarter]
    end

    it 'is not written to the replacement process before its negotiation completes' do
      server = negotiated_transport
      replacement, finish, restarter = restart_held_at_negotiation(server)

      caller = Thread.new { server.send(:send_request_and_wait, 'tools/call', { 'name' => 'echo' }, 2) }
      sleep 0.2

      expect(replacement.string).to be_empty
      expect(caller).to be_alive

      finish << true
      restarter.join
      wait_for('the request to reach the negotiated replacement') { !replacement.string.empty? }
      request = JSON.parse(replacement.string.lines.first)
      expect(request['method']).to eq('tools/call')
      expect(server.instance_variable_get(:@awaiting)).to have_key(request['id'])
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => request['id'], 'result' => { 'content' => [] }))
      expect(caller.value).to eq({ 'content' => [] })
    end

    it 'goes out registered on the replacement once the negotiation has completed' do
      server = negotiated_transport
      replacement, finish, restarter = restart_held_at_negotiation(server)
      finish << true
      restarter.join

      caller = Thread.new { server.send(:send_request_and_wait, 'tools/call', { 'name' => 'echo' }, 2) }
      wait_for('the request to reach the replacement') { !replacement.string.empty? }
      request = JSON.parse(replacement.string.lines.first)
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => request['id'], 'result' => {}))

      expect(caller.value).to eq({})
      expect(replacement.string.lines.size).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'a restart racing a write that is in progress' do
    # A stdin whose write blocks until released: the request is INSIDE the
    # write, past the generation check, when the restart is attempted.
    def blocking_stdin(server)
      writing = Queue.new
      release = Queue.new
      lines = []
      stdin = double('stdin', flush: nil, closed?: false, close: nil)
      allow(stdin).to receive(:puts) do |line|
        writing << true
        release.pop
        lines << line
      end
      server.instance_variable_set(:@stdin, stdin)
      [writing, release, lines]
    end

    it 'cannot replace the handles until the write has finished' do
      server = negotiated_transport
      writing, release, lines = blocking_stdin(server)
      before = server.instance_variable_get(:@transport_generation)
      caller = Thread.new { server.send(:send_request_and_wait, 'tools/call', { 'name' => 'echo' }, 2) }
      writing.pop

      restarter = Thread.new { server.cleanup }
      sleep 0.2

      expect(restarter).to be_alive
      expect(server.instance_variable_get(:@transport_generation)).to eq(before)
      expect(lines).to be_empty

      release << true
      restarter.join
      expect(lines.size).to eq(1)
      expect(JSON.parse(lines.first)['method']).to eq('tools/call')
      expect(server.instance_variable_get(:@transport_generation)).to eq(before + 1)
      # The transport the request went out on is gone: its caller is told.
      expect { caller.value }.to raise_error(MCPClient::Errors::TransportError)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'an answer on an established 2025-11-25 session' do
    it 'identifies nothing, so the server is still answered its own requests' do
      server = legacy_session
      id = server.send(:next_id)

      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => id,
                                       'result' => { 'resultType' => 'complete', 'content' => [] }))

      expect(server.modern_peer?).to be(false)
      expect(server.protocol_era).to eq(:legacy)
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-ping', 'method' => 'ping'))
      written = server.instance_variable_get(:@stdin).string.lines.map { |line| JSON.parse(line) }
      expect(written).to eq([{ 'jsonrpc' => '2.0', 'id' => 'srv-ping', 'result' => {} }])
    end

    it 'identifies nothing from a well-formed modern error either' do
      server = legacy_session
      id = server.send(:next_id)

      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => id,
                                       'error' => { 'code' => -32_021, 'message' => 'missing',
                                                    'data' => { 'requiredCapabilities' => { 'roots' => {} } } }))

      expect(server.modern_peer?).to be(false)
    end

    it 'still identifies a modern server from the answer to an outstanding probe' do
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      server.instance_variable_set(:@stdin, StringIO.new)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server.send(:begin_era_probe)
      id = server.send(:next_id)

      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => discover_result))

      expect(server.modern_peer?).to be(true)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'a request of the exited process when another caller restarts first' do
    # The waiter is blocked on its answer when the subprocess exits; the
    # other caller observes the retirement and restarts before the waiter
    # ever runs, so the retirement it would have seen is already cleared.
    def restart_under(server)
      allow(Open3).to receive(:popen3).and_return([StringIO.new, StringIO.new, StringIO.new, nil])
      allow(server).to receive(:negotiate_protocol)
      server.instance_variable_get(:@mutex).synchronize { server.instance_variable_set(:@transport_retired, true) }
      server.send(:ensure_initialized)
    end

    it 'fails promptly rather than waiting out its timeout' do
      server = negotiated_transport
      unanswered = server.send(:next_id)
      waiter = Thread.new { server.send(:wait_response, unanswered, timeout: 5) }
      sleep 0.05
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      restart_under(server)

      expect { waiter.value }.to raise_error(MCPClient::Errors::TransportError, /exited/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(server.transport_retired?).to be(false)
    end

    it 'sends no cancellation for it to the replacement process' do
      server = negotiated_transport
      caller = Thread.new { server.send(:send_request_and_wait, 'tools/call', { 'name' => 'echo' }, 5) }
      wait_for('the request to be written') { !server.instance_variable_get(:@stdin).string.empty? }

      restart_under(server)

      expect { caller.value }.to raise_error(MCPClient::Errors::TransportError)
      expect(server.instance_variable_get(:@stdin).string).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  describe 'discovery freshness by the caching rules' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:prompt_ref) { { 'type' => 'ref/prompt', 'name' => 'greet' } }
    let(:argument) { { 'name' => 'name', 'value' => 'a' } }
    let(:completion) { { 'completion' => { 'values' => ['ada'], 'total' => 1, 'hasMore' => false } } }

    def completions_after(first_discover)
      wire_stdio(server, [{ 'result' => first_discover },
                          { 'result' => discover_result(capabilities: { 'completions' => {} }) },
                          { 'result' => completion }])
    end

    it 'honours a ttlMs sent as a JSON number that is not an integer' do
      written = completions_after(discover_result(capabilities: {}, extra: { 'ttlMs' => 0.0 }))

      expect(server.complete(ref: prompt_ref, argument: argument)['values']).to eq(['ada'])
      expect(methods_in(written)).to eq(%w[server/discover server/discover completion/complete])
    end

    it 'keeps a float ttlMs that has not elapsed fresh' do
      written = wire_stdio(server, [{ 'result' => discover_result(capabilities: {}, extra: { 'ttlMs' => 1e3 }) }])

      expect { server.complete(ref: prompt_ref, argument: argument) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(methods_in(written)).to eq(%w[server/discover])
    end

    it 'treats a negative ttlMs as zero: immediately stale' do
      written = completions_after(discover_result(capabilities: {}, extra: { 'ttlMs' => -1 }))

      expect(server.complete(ref: prompt_ref, argument: argument)['values']).to eq(['ada'])
      expect(methods_in(written)).to eq(%w[server/discover server/discover completion/complete])
    end

    it 'treats an absent ttlMs as zero: immediately stale' do
      first = discover_result(capabilities: {}).except('ttlMs')
      written = completions_after(first)

      expect(server.complete(ref: prompt_ref, argument: argument)['values']).to eq(['ada'])
      expect(methods_in(written)).to eq(%w[server/discover server/discover completion/complete])
    end

    it 'treats a ttlMs that is not a number as zero' do
      written = completions_after(discover_result(capabilities: {}, extra: { 'ttlMs' => 'soon' }))

      expect(server.complete(ref: prompt_ref, argument: argument)['values']).to eq(['ada'])
      expect(methods_in(written)).to eq(%w[server/discover server/discover completion/complete])
    end

    it 'is stale exactly when the TTL has elapsed, not before' do
      written = wire_stdio(server, [
                             { 'result' => discover_result(capabilities: {}, extra: { 'ttlMs' => 1_000 }) },
                             { 'result' => discover_result(capabilities: { 'completions' => {} }) },
                             { 'result' => completion }
                           ])
      # Discovered at 100.0; the first gate at 100.999 is fresh, the second
      # at exactly 101.0 is not.
      allow(server).to receive(:discovery_clock).and_return(100.0, 100.999, 101.0, 101.0)

      expect { server.complete(ref: prompt_ref, argument: argument) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(server.complete(ref: prompt_ref, argument: argument)['values']).to eq(['ada'])
      expect(methods_in(written)).to eq(%w[server/discover server/discover completion/complete])
    end

    it 'refreshes a stale discovery before reusing a capability it still lists' do
      written = wire_stdio(server, [
                             { 'result' => discover_result(capabilities: { 'completions' => {} },
                                                           extra: { 'ttlMs' => 0 }) },
                             { 'result' => discover_result(capabilities: {}) }
                           ])

      expect { server.complete(ref: prompt_ref, argument: argument) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(methods_in(written)).to eq(%w[server/discover server/discover])
      expect(server.capabilities).to eq({})
    end

    it 'does not refresh a fresh discovery on a capability it lists' do
      written = wire_stdio(server, [{ 'result' => discover_result(capabilities: { 'completions' => {} }) },
                                    { 'result' => completion }])

      expect(server.complete(ref: prompt_ref, argument: argument)['values']).to eq(['ada'])
      expect(methods_in(written)).to eq(%w[server/discover completion/complete])
    end

    it 'exposes the freshness deadline through discovery_fresh? across the boundary' do
      wire_stdio(server, [{ 'result' => discover_result(extra: { 'ttlMs' => 500 }) }])
      allow(server).to receive(:discovery_clock).and_return(10.0, 10.4, 10.5)
      server.ping

      expect(server.discovery_fresh?).to be(true)
      expect(server.discovery_fresh?).to be(false)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'the log level set through the public client' do
    def stdio_client
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'echo test', read_timeout: 1 }])
      [client, client.servers.first]
    end

    it 'reaches a modern server that declared no logging capability' do
      client, server = stdio_client
      written = wire_stdio(server,
                           [{ 'result' => discover_result(capabilities: {}) }, { 'result' => tool_list_result }])
      server.ping

      client.log_level = 'debug'
      client.list_tools

      request = requests_in(written).find { |r| r['method'] == 'tools/list' }
      expect(request.dig('params', '_meta', R6_META::META_LOG_LEVEL)).to eq('debug')
    end

    it 'still skips a 2025-11-25 server that negotiated no logging capability' do
      client, server = stdio_client
      written = wire_stdio(server, [])
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server.instance_variable_set(:@capabilities, {})

      client.log_level = 'debug'

      expect(methods_in(written)).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  describe 'an extension that adds a result type' do
    let(:transport) do
      Class.new do
        include MCPClient::JsonRpcCommon

        attr_accessor :protocol_version

        def initialize
          @protocol_version = '2026-07-28'
          @logger = Logger.new(File::NULL)
        end
      end.new
    end

    it 'cannot be advertised by a client that does not implement it' do
      expect { transport.declare_extension('io.modelcontextprotocol/tasks') }
        .to raise_error(ArgumentError, /result type "task".*not implement/)
      expect(transport.declared_extensions).to be_empty
    end

    it 'can be advertised by a client that implements it' do
      transport.define_singleton_method(:implemented_extension_result_types) do
        { 'io.modelcontextprotocol/tasks' => ['task'] }
      end
      transport.declare_extension('io.modelcontextprotocol/tasks')

      expect(transport.accepted_result_types).to eq(%w[complete input_required task])
      result = { 'resultType' => 'task', 'taskId' => 't1' }
      expect(transport.process_jsonrpc_response({ 'id' => 1, 'result' => result })).to eq(result)
    end

    it 'widens the accepted result types once declared by a client that implements it' do
      transport.define_singleton_method(:implemented_extension_result_types) do
        { 'com.example/deferred' => ['deferred'] }
      end
      transport.declare_extension('com.example/deferred')
      result = { 'resultType' => 'deferred', 'ticket' => 't1' }

      expect(transport.process_jsonrpc_response({ 'id' => 1, 'result' => result })).to eq(result)
    end

    it 'rejects an extension result type the session did not declare' do
      transport.define_singleton_method(:implemented_extension_result_types) do
        { 'com.example/deferred' => ['deferred'] }
      end
      result = { 'resultType' => 'deferred', 'ticket' => 't1' }

      expect { transport.process_jsonrpc_response({ 'id' => 1, 'result' => result }) }
        .to raise_error(MCPClient::Errors::InvalidResultError, /deferred/)
    end

    it 'never widens a 2025-11-25 session' do
      transport.define_singleton_method(:implemented_extension_result_types) do
        { 'com.example/deferred' => ['deferred'] }
      end
      transport.declare_extension('com.example/deferred')
      transport.protocol_version = '2025-11-25'

      expect(transport.accepted_result_types).to eq(%w[complete])
    end
  end

  # ---------------------------------------------------------------------------
  describe 'restarts against a real subprocess' do
    let(:transcript) { File.join(Dir.tmpdir, "mcp-era-r6-#{Process.pid}-#{rand(1_000_000)}.log") }

    after { FileUtils.rm_f(transcript) }

    it 'spawns one process when connect is called before the first request' do
      server = MCPClient::ServerStdio.new(command: fixture_command('modern', transcript),
                                          read_timeout: 2, discover_timeout: 2)
      server.connect
      expect(server.list_tools.map(&:name)).to eq(['echo'])
      expect(server.list_tools.map(&:name)).to eq(['echo'])

      expect(transcript_pids(transcript).size).to eq(1)
    ensure
      server&.cleanup
    end

    it 'forgets a modern identification through the production restart path' do
      server = MCPClient::ServerStdio.new(command: fixture_command('modern', transcript),
                                          read_timeout: 2, discover_timeout: 2)
      expect(server.list_tools.map(&:name)).to eq(['echo'])
      expect(server.modern_peer?).to be(true)
      Process.kill('TERM', transcript_pids(transcript).first)
      wait_for('the transport to retire') { server.transport_retired? }

      # The restart runs connect for real: nothing is repaired by hand. The
      # era of the replacement is observed while it is still being
      # established — retaining the dead process's would satisfy the final
      # state just as well, and it is what round 7 found dropping a legacy
      # replacement's startup ping.
      era_at_negotiation = :unset
      allow(server).to receive(:negotiate_protocol).and_wrap_original do |original, *args|
        era_at_negotiation = server.protocol_era
        original.call(*args)
      end

      expect(server.list_tools.map(&:name)).to eq(['echo'])

      expect(era_at_negotiation).to be_nil
      expect(transcript_pids(transcript).size).to eq(2)
      expect(server.protocol_era).to eq(:modern)
    ensure
      server&.cleanup
    end
  end

  # ---------------------------------------------------------------------------
  describe 'unfinished results on the read and list paths' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:unfinished) do
      { 'resultType' => 'input_required', 'requestState' => 'later',
        'inputRequests' => { 'k' => { 'method' => 'elicitation/create', 'params' => { 'message' => 'm' } } } }
    end

    it 'surfaces the whole continuation from resources/read' do
      wire_stdio(server, [{ 'result' => discover_result }, { 'result' => unfinished }])

      expect { server.read_resource('file:///x') }.to raise_error(MCPClient::Errors::InputRequiredError) do |e|
        expect(e.data).to eq(unfinished)
        expect(e.request_state).to eq('later')
      end
    end

    it 'never flattens an unfinished tools/list page into an empty list' do
      wire_stdio(server, [{ 'result' => discover_result }, { 'result' => unfinished }])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::InputRequiredError) do |e|
        expect(e.data).to eq(unfinished)
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe 'the serialized second page' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'carries the modern _meta like the first' do
      written = wire_stdio(server, [{ 'result' => discover_result },
                                    { 'result' => { 'prompts' => [], 'nextCursor' => 'p2' } },
                                    { 'result' => { 'prompts' => [] } }])

      server.list_prompts

      pages = requests_in(written).select { |r| r['method'] == 'prompts/list' }
      expect(pages.size).to eq(2)
      expect(pages.last.dig('params', 'cursor')).to eq('p2')
      expect(pages.last.dig('params', '_meta', R6_META::META_PROTOCOL_VERSION)).to eq('2026-07-28')
    end
  end

  # ---------------------------------------------------------------------------
  describe 'a -32021 on an in-session tools/call' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'reaches the host typed, with the capabilities the server requires' do
      wire_stdio(server, [{ 'result' => discover_result },
                          { 'error' => { 'code' => -32_021, 'message' => 'missing',
                                         'data' => { 'requiredCapabilities' => { 'sampling' => {} } } } }])

      expect { server.call_tool('echo', {}) }
        .to raise_error(MCPClient::Errors::MissingRequiredClientCapabilityError) do |e|
          expect(e.required_capabilities).to eq({ 'sampling' => {} })
        end
    end
  end
end
