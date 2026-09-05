# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Verification round (codex) on the MCP 2026-07-28 stateless stdio work.
#
# Four defects and the coverage gaps behind them:
#   1. the version a server/discover probe *proposes* was treated as the
#      server's confirmed era, so a legacy server's startup `ping` was dropped
#      and the whole negotiation deadlocked;
#   2. a discovery failure left the subprocess, its pipes and its reader
#      threads running, and the next request overwrote the handles;
#   3. per-call `_meta` could reinstate `io.modelcontextprotocol/clientInfo`
#      after the host opted out of sending it;
#   4. extension identifiers rejected the empty name the published `_meta` key
#      grammar allows ("Name: Unless empty, MUST begin and end with an
#      alphanumeric character").
#
# The interleavings in (1) and (2) — a server that writes before it is spoken
# to, one that never answers, one that outlives a dropped pipe — only exist
# against a real process, so those are driven through
# spec/support/protocol_era_stdio_server.rb rather than a stubbed transport.
ERA_META = MCPClient::JsonRpcCommon
ERA_FIXTURE_SERVER = File.expand_path('../../support/protocol_era_stdio_server.rb', __dir__)

RSpec.describe 'MCP 2026-07-28 stateless protocol (stdio) — verification round' do
  def discover_result(versions: ['2026-07-28'], capabilities: { 'tools' => {} })
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => capabilities }
  end

  def legacy_init_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
      'serverInfo' => { 'name' => 'legacy-server', 'version' => '1.0' } }
  end

  def tool_list_result
    { 'tools' => [{ 'name' => 'echo', 'description' => 'echo', 'inputSchema' => { 'type' => 'object' } }] }
  end

  def unsupported_version_error(supported, requested)
    { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                   'data' => { 'supported' => supported, 'requested' => requested } } }
  end

  # Drive a ServerStdio without a real subprocess. Returns [sent, written]:
  # the JSON-RPC requests handed to send_request, and the raw lines written to
  # the subprocess stdin (notifications, and responses to server requests).
  def script_stdio(server, responses)
    sent = []
    written = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    stdin = double('stdin', flush: nil, closed?: true, close: nil)
    allow(stdin).to receive(:puts) { |line| written << line }
    server.instance_variable_set(:@stdin, stdin)
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(id) : responder
      raise response if response.is_a?(Exception)

      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    [sent, written]
  end

  # @param mode [String] a protocol_era_stdio_server.rb mode
  # @param transcript [String] path the fixture appends its event log to
  # @return [Array<String>] the command to launch it
  def fixture_command(mode, transcript)
    [RbConfig.ruby, ERA_FIXTURE_SERVER, mode, transcript]
  end

  # The methods the fixture server recorded, waited for because a notification
  # is only recorded once the server reads it.
  # @param path [String] transcript path
  # @param expected [Integer] number of entries to wait for
  # @return [Array<String>]
  def transcript_methods(path, expected, timeout: 5)
    deadline = Time.now + timeout
    loop do
      methods = transcript_lines(path).grep_v(/\Apid /)
      return methods if methods.size >= expected || Time.now > deadline

      sleep 0.02
    end
  end

  # @param path [String] transcript path
  # @return [Array<String>]
  def transcript_lines(path)
    return [] unless File.exist?(path)

    File.readlines(path).map(&:strip).reject(&:empty?)
  rescue Errno::ENOENT
    []
  end

  # @param path [String] transcript path
  # @return [Array<Integer>] pids of every fixture process spawned
  def transcript_pids(path)
    transcript_lines(path).grep(/\Apid /).map { |line| Integer(line.split.last) }
  end

  # Poll a condition until it holds, failing the example if it never does.
  # @param what [String] what is being waited for, for the failure message
  # @param timeout [Numeric] seconds to wait
  # @return [void]
  def wait_for(what, timeout: 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
    raise "timed out after #{timeout}s waiting for #{what}" unless yield
  end

  # @param pid [Integer]
  # @return [Boolean] whether the process still exists (a reaped child does not)
  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  describe 'a probe in flight is not a settled era' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'answers a server-initiated ping that arrives while the probe is unanswered' do
      sent, written = script_stdio(server, [{ 'error' => { 'code' => -32_601, 'message' => 'Method not found' } },
                                            { 'result' => legacy_init_result },
                                            { 'result' => tool_list_result }])
      era_during_probe = :never_probed
      version_during_probe = nil
      allow(server).to receive(:send_request) do |req|
        sent << req
        next unless req['method'] == 'server/discover'

        era_during_probe = server.protocol_era
        version_during_probe = server.protocol_version
        # The reader thread delivers a legacy server's startup ping while the
        # probe is still in flight.
        server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-ping', 'method' => 'ping'))
      end

      server.list_tools

      expect(era_during_probe).to be_nil
      expect(version_during_probe).to eq(MCPClient::LATEST_PROTOCOL_VERSION)
      expect(written.map { |line| JSON.parse(line) })
        .to include({ 'jsonrpc' => '2.0', 'id' => 'srv-ping', 'result' => {} })
      expect(sent.map { |req| req['method'] }).to eq(%w[server/discover initialize tools/list])
    end

    it 'still declares the proposed version on the probe itself' do
      sent, = script_stdio(server, [{ 'result' => discover_result }])

      server.ping

      expect(sent.first['params']['_meta'][ERA_META::META_PROTOCOL_VERSION])
        .to eq(MCPClient::LATEST_PROTOCOL_VERSION)
    end

    it 'drops a server-initiated ping once a well-formed rejection has settled the era as modern' do
      stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
      stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
      sent, written = script_stdio(server, [unsupported_version_error(['2026-07-28'], '2027-01-01'),
                                            { 'result' => discover_result },
                                            { 'result' => tool_list_result }])
      eras = []
      allow(server).to receive(:send_request) do |req|
        sent << req
        next unless req['method'] == 'server/discover'

        eras << server.protocol_era
        server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => "srv-#{eras.size}", 'method' => 'ping'))
      end

      server.list_tools

      expect(eras).to eq([nil, :modern])
      # Only the first ping was answered: after the rejection the server is
      # known modern and MUST NOT be written a JSON-RPC response.
      expect(written.map { |line| JSON.parse(line)['id'] }).to eq(['srv-1'])
    end

    it 'reports the era again once the probe settles' do
      script_stdio(server, [{ 'result' => discover_result }])

      server.ping

      expect(server.protocol_era).to eq(:modern)
      expect(server.modern?).to be(true)
    end
  end

  describe 'a failed negotiation releases the transport' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    # Each of these leaves the subprocess running and @initialized false, so
    # the next request would spawn a second process over the first one's
    # handles.
    {
      'the DiscoverResult offers no mutual version' => [{ 'result' => { 'resultType' => 'complete',
                                                                        'supportedVersions' => ['2099-01-01'] } }],
      'the initialize handshake is rejected' => [{ 'error' => { 'code' => -32_601, 'message' => 'nope' } },
                                                 { 'error' => { 'code' => -32_602, 'message' => 'bad params' } }]
    }.each do |reason, responses|
      it "cleans up when #{reason}" do
        script_stdio(server, responses)
        allow(server).to receive(:cleanup).and_call_original

        expect { server.list_tools }.to raise_error(StandardError)

        expect(server).to have_received(:cleanup).at_least(:once)
        expect(server.instance_variable_get(:@stdin)).to be_nil
      end
    end

    it 'cleans up when a legacy answer is refused under protocol: :modern' do
      modern_only = MCPClient::ServerStdio.new(command: 'echo test', protocol: :modern, read_timeout: 1)
      script_stdio(modern_only, [{ 'error' => { 'code' => -32_601, 'message' => 'Method not found' } }])
      allow(modern_only).to receive(:cleanup).and_call_original

      expect { modern_only.list_tools }.to raise_error(MCPClient::Errors::ToolCallError)

      expect(modern_only).to have_received(:cleanup).at_least(:once)
      expect(modern_only.instance_variable_get(:@stdin)).to be_nil
    end

    it 'does not clean up a session that negotiated successfully' do
      script_stdio(server, [{ 'result' => discover_result }, { 'result' => tool_list_result }])
      allow(server).to receive(:cleanup).and_call_original

      server.list_tools

      expect(server).not_to have_received(:cleanup)
    end
  end

  describe 'per-call _meta cannot reinstate transport-owned fields' do
    let(:transport) do
      Class.new do
        include MCPClient::JsonRpcCommon

        attr_accessor :protocol_version

        def initialize
          @logger = Logger.new(StringIO.new)
        end
      end.new
    end

    let(:caller_identity) { { 'name' => 'private-host', 'version' => '1' } }

    it 'drops a caller-supplied clientInfo when the host opted out of sending it' do
      transport.protocol_version = '2026-07-28'
      transport.send_client_info = false
      params = { '_meta' => { ERA_META::META_CLIENT_INFO => caller_identity } }

      meta = transport.build_jsonrpc_request('tools/call', params, 1)['params']['_meta']

      expect(meta).not_to have_key(ERA_META::META_CLIENT_INFO)
    end

    it 'keeps the transport identity when a caller supplies a different one' do
      transport.protocol_version = '2026-07-28'
      params = { '_meta' => { ERA_META::META_CLIENT_INFO => caller_identity } }

      meta = transport.build_jsonrpc_request('tools/call', params, 1)['params']['_meta']

      expect(meta[ERA_META::META_CLIENT_INFO]).to eq({ 'name' => 'ruby-mcp-client', 'version' => MCPClient::VERSION })
    end

    it 'drops reserved keys from a symbol-keyed per-call _meta too' do
      transport.protocol_version = '2026-07-28'
      transport.send_client_info = false
      params = { _meta: { ERA_META::META_CLIENT_INFO => caller_identity, 'progressToken' => 'p1' } }

      meta = transport.build_jsonrpc_request('tools/call', params, 1)['params']['_meta']

      expect(meta).not_to have_key(ERA_META::META_CLIENT_INFO)
      expect(meta['progressToken']).to eq('p1')
    end

    it 'drops reserved keys from per-call _meta on a legacy server as well' do
      transport.protocol_version = '2025-11-25'
      transport.request_meta = { 'traceparent' => '00-1-2-01' }
      params = { '_meta' => { ERA_META::META_CLIENT_INFO => caller_identity } }

      meta = transport.build_jsonrpc_request('tools/call', params, 1)['params']['_meta']

      expect(meta).to eq({ 'traceparent' => '00-1-2-01' })
    end

    it 'keeps the opt-out on the wire through the stdio transport' do
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      sent, = script_stdio(server, [{ 'result' => discover_result }, { 'result' => { 'content' => [] } }])
      server.send_client_info = false

      server.call_tool('echo', { '_meta' => { ERA_META::META_CLIENT_INFO => caller_identity } })

      expect(sent.last['params']['_meta']).not_to have_key(ERA_META::META_CLIENT_INFO)
      expect(sent.last['params']['_meta'][ERA_META::META_PROTOCOL_VERSION]).to eq('2026-07-28')
    end
  end

  describe 'extension identifier grammar' do
    let(:transport) do
      Class.new do
        include MCPClient::JsonRpcCommon

        attr_accessor :protocol_version

        def initialize
          @logger = Logger.new(StringIO.new)
        end
      end.new
    end

    # basic/versioning "Extension Negotiation": identifiers follow the `_meta`
    # key naming rules with a mandatory prefix, and basic/index says of the
    # name "Unless empty, MUST begin and end with an alphanumeric character".
    it 'accepts a prefix-only identifier, whose name is empty' do
      transport.protocol_version = '2026-07-28'
      transport.declare_extension('com.example/', { 'level' => 1 })

      caps = transport.build_jsonrpc_request('tools/list', {}, 1)['params']['_meta'][ERA_META::META_CLIENT_CAPABILITIES]

      expect(caps['extensions']).to eq({ 'com.example/' => { 'level' => 1 } })
    end

    it 'still requires the mandatory prefix and a well-formed name' do
      ['tasks', 'com.example', '/tasks', 'com.example/-tasks', '.com/tasks', 'com.example/tasks-'].each do |bad|
        expect { transport.declare_extension(bad) }.to raise_error(ArgumentError, /prefix/), bad.inspect
      end
    end
  end

  describe 'against a real subprocess', :slow do
    around do |example|
      Dir.mktmpdir('mcp-era') do |dir|
        @transcript = File.join(dir, 'transcript.log')
        example.run
      end
    end

    attr_reader :transcript

    after do
      transcript_pids(transcript).each do |pid|
        Process.kill('KILL', pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    it 'completes negotiation with a legacy server that pings before it answers' do
      server = MCPClient::ServerStdio.new(command: fixture_command('legacy-ping-first', transcript),
                                          read_timeout: 5, discover_timeout: 2)

      tools = server.list_tools

      expect(tools.map(&:name)).to eq(['echo'])
      expect(server.protocol_era).to eq(:legacy)
      expect(transcript_methods(transcript, 4))
        .to eq(['server/discover', 'response:srv-ping', 'initialize', 'notifications/initialized', 'tools/list'])
    ensure
      server&.cleanup
    end

    it 'never sends initialize or notifications/initialized to a modern server' do
      server = MCPClient::ServerStdio.new(command: fixture_command('modern', transcript),
                                          read_timeout: 5, discover_timeout: 2)

      tools = server.list_tools
      server.call_tool('echo', {})

      expect(tools.map(&:name)).to eq(['echo'])
      expect(server.protocol_era).to eq(:modern)
      expect(transcript_methods(transcript, 3)).to eq(%w[server/discover tools/list tools/call])
    ensure
      server&.cleanup
    end

    it 'runs the complete initialize handshake once the probe is rejected' do
      server = MCPClient::ServerStdio.new(command: fixture_command('legacy', transcript),
                                          read_timeout: 5, discover_timeout: 2)

      tools = server.list_tools

      expect(tools.map(&:name)).to eq(['echo'])
      expect(server.protocol_version).to eq('2025-11-25')
      expect(server.server_info).to eq({ 'name' => 'era-fixture', 'version' => '1.0' })
      expect(transcript_methods(transcript, 4))
        .to eq(%w[server/discover initialize notifications/initialized tools/list])
    ensure
      server&.cleanup
    end

    it 'really waits out discover_timeout, cancels the probe and falls back' do
      server = MCPClient::ServerStdio.new(command: fixture_command('silent-probe', transcript),
                                          read_timeout: 5, discover_timeout: 0.5)

      started = Time.now
      tools = server.list_tools
      elapsed = Time.now - started

      expect(elapsed).to be >= 0.5
      expect(tools.map(&:name)).to eq(['echo'])
      expect(server.protocol_era).to eq(:legacy)
      expect(transcript_methods(transcript, 5))
        .to eq(%w[server/discover notifications/cancelled initialize notifications/initialized tools/list])
    ensure
      server&.cleanup
    end

    it 'probes once when several threads race to make the first request' do
      server = MCPClient::ServerStdio.new(command: fixture_command('modern', transcript),
                                          read_timeout: 5, discover_timeout: 2)

      threads = Array.new(4) { Thread.new { server.list_tools } }
      results = threads.map(&:value)

      expect(results.map { |tools| tools.map(&:name) }).to all(eq(['echo']))
      methods = transcript_methods(transcript, 5)
      expect(methods.count('server/discover')).to eq(1)
      expect(methods.count('tools/list')).to eq(4)
    ensure
      server&.cleanup
    end

    # MCP 2026-07-28 stdio "Unexpected Termination": a client SHOULD restart a
    # server that terminated unexpectedly. A completed handshake describes a
    # process that no longer exists, so it must not keep the transport writing
    # to that process's pipes for the rest of the session.
    it 'restarts a modern subprocess that exited unexpectedly, on the next request' do
      server = MCPClient::ServerStdio.new(command: fixture_command('modern-one-shot', transcript),
                                          read_timeout: 2, discover_timeout: 2)

      expect(server.list_tools.map(&:name)).to eq(['echo'])
      first_pid = transcript_pids(transcript).first
      # Captured while they are still the live ones: the exit releases them.
      dead_pipes = %i[@stdin @stdout @stderr].map { |ivar| server.instance_variable_get(ivar) }
      dead_reader = server.instance_variable_get(:@reader_thread)
      wait_for('the subprocess to exit') { !process_alive?(first_pid) }
      # The reader thread notices the closed stdout and hands the exit on;
      # waiting for it to finish keeps the restart deterministic.
      wait_for('the old reader thread to finish') { !dead_reader.alive? }

      expect(server.list_tools.map(&:name)).to eq(['echo'])

      # The dead process's handles were released rather than overwritten.
      expect(dead_pipes.map(&:closed?)).to eq([true, true, true])
      expect(server.instance_variable_get(:@stdin)).not_to be(dead_pipes.first)
      pids = transcript_pids(transcript)
      expect(pids.size).to eq(2)
      expect(pids.uniq.size).to eq(2)
      expect(server.protocol_era).to eq(:modern)
      expect(transcript_methods(transcript, 4)).to eq(%w[server/discover tools/list server/discover tools/list])
    ensure
      server&.cleanup
    end

    it 'leaves no subprocess behind when discovery fails, twice in a row' do
      stub_const('MCPClient::ServerStdio::SHUTDOWN_GRACE_PERIOD', 0.25)
      server = MCPClient::ServerStdio.new(command: fixture_command('future-only', transcript),
                                          read_timeout: 5, discover_timeout: 2)

      2.times do
        expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /2099-01-01/)
      end

      pids = transcript_pids(transcript)
      expect(pids.size).to eq(2)
      expect(pids.select { |pid| process_alive?(pid) }).to be_empty
    ensure
      server&.cleanup
    end
  end

  describe 'client-level request metadata reaches every transport' do
    it 'stamps _meta on the outgoing requests of every configured server' do
      first = MCPClient::ServerStdio.new(command: 'echo one', read_timeout: 1)
      second = MCPClient::ServerStdio.new(command: 'echo two', read_timeout: 1)
      sent_first, = script_stdio(first, [{ 'result' => discover_result }, { 'result' => tool_list_result }])
      sent_second, = script_stdio(second, [{ 'error' => { 'code' => -32_601, 'message' => 'nope' } },
                                           { 'result' => legacy_init_result }, { 'result' => tool_list_result }])
      allow(MCPClient::ServerFactory).to receive(:create).and_return(first, second)
      calls = 0
      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'one' }, { type: 'stdio', command: 'two' }],
        request_meta: lambda {
          calls += 1
          { 'traceparent' => "00-trace-#{calls}-01", ERA_META::META_CLIENT_INFO => { 'name' => 'spoofed' } }
        }
      )

      client.list_tools

      # Modern and legacy alike: the host's metadata travels, its attempt to
      # set a transport-owned key does not.
      (sent_first + sent_second).each do |req|
        expect(req['params']['_meta']['traceparent']).to match(/\A00-trace-\d+-01\z/)
        expect(req['params']['_meta'][ERA_META::META_CLIENT_INFO]).not_to eq({ 'name' => 'spoofed' })
      end
      expect(sent_first.map { |req| req['method'] }).to eq(%w[server/discover tools/list])
      expect(sent_second.map { |req| req['method'] }).to eq(%w[server/discover initialize tools/list])
      # One evaluation per outgoing request, not one per client.
      expect(calls).to be >= sent_first.size + sent_second.size
    end
  end

  describe 'stdio option forwarding' do
    it 'carries protocol and discover_timeout from MCPClient.connect to the transport' do
      transcript = File.join(Dir.tmpdir, "mcp-forward-#{Process.pid}.log")
      client = MCPClient.connect(fixture_command('modern', transcript), transport: :stdio,
                                                                        protocol: :modern, discover_timeout: 4)

      server = client.servers.first
      expect(server.protocol_mode).to eq(:modern)
      expect(server.discover_timeout).to eq(4)
    ensure
      client&.cleanup
      File.delete(transcript) if transcript && File.exist?(transcript)
    end

    it 'defaults both when the caller says nothing' do
      expect(MCPClient.send(:extract_stdio_options, {})).not_to have_key(:protocol)

      server = MCPClient::ServerFactory.create(MCPClient.stdio_config(command: 'echo test', protocol: :auto))
      expect(server.protocol_mode).to eq(:auto)
      expect(server.discover_timeout).to eq(MCPClient::ServerStdio::READ_TIMEOUT)
    end

    it 'forwards both through extract_stdio_options' do
      options = MCPClient.send(:extract_stdio_options, { protocol: :legacy, discover_timeout: 7 })
      expect(options).to include(protocol: :legacy, discover_timeout: 7)
    end
  end

  # Second verification round (codex). Four more defects in the modern stdio
  # path — each one invisible to the first round's examples:
  #   5. modern-only mode answered a server-initiated request while its probe
  #      was still in flight. The era is unknown then, but the configuration
  #      is not: this client will never fall back to legacy, so running a host
  #      roots/sampling callback and writing a JSON-RPC response is
  #      prohibited traffic;
  #   6. a subprocess that exited after a successful handshake left the
  #      handshake standing, so every later request wrote to the dead pipes of
  #      a process that no longer existed, forever;
  #   7. a host request_meta provider that raised leaked one @awaiting entry
  #      per attempt: the id is registered before the request is built;
  #   8. the inline version-retry guard compared the server's advertised
  #      version against the one read before the request was built, not
  #      against the one the request actually declared.
  describe 'modern-only mode is never a legacy peer' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', protocol: :modern, read_timeout: 1) }

    # The era is unknown while the probe is unanswered — but protocol: :modern
    # has already ruled out the legacy fallback that the accommodation exists
    # for, and MCP 2026-07-28 stdio says the client MUST NOT write JSON-RPC
    # responses to a modern server.
    it 'ignores a server-initiated roots/list that arrives while the probe is in flight' do
      sent, written = script_stdio(server, [{ 'result' => discover_result }, { 'result' => tool_list_result }])
      roots_calls = []
      server.on_roots_list_request do |id, _params|
        roots_calls << id
        { 'roots' => [{ 'uri' => 'file:///private-project' }] }
      end
      allow(server).to receive(:send_request) do |req|
        sent << req
        next unless req['method'] == 'server/discover'

        server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-roots', 'method' => 'roots/list',
                                         'params' => {}))
      end

      expect(server.list_tools.map(&:name)).to eq(['echo'])

      expect(roots_calls).to be_empty
      expect(written).to be_empty
      expect(sent.map { |req| req['method'] }).to eq(%w[server/discover tools/list])
    end

    it 'does not answer an unsupported server-initiated method with an error either' do
      _sent, written = script_stdio(server, [{ 'result' => discover_result }, { 'result' => tool_list_result }])

      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-1', 'method' => 'sampling/createMessage'))
      server.list_tools

      expect(written).to be_empty
    end
  end

  describe 'a request that is never built leaves no outstanding entry' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'drops the awaiting marker when the host metadata provider raises, and recovers afterwards' do
      responses = [{ 'result' => discover_result }, { 'result' => tool_list_result }]
      sent, = script_stdio(server, responses)
      server.list_tools

      # script_stdio stubs wait_response, which is what clears a marker on a
      # real transport, so only the growth the failures cause is meaningful.
      outstanding = -> { server.instance_variable_get(:@awaiting).size }
      settled = outstanding.call

      server.request_meta = -> { raise 'trace provider unavailable' }
      3.times do
        expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /trace provider/)
      end

      # Nothing was sent and nothing will ever answer: an id registered for a
      # request that was never built must not stay outstanding.
      expect(outstanding.call).to eq(settled)
      expect(sent.map { |req| req['method'] }).to eq(%w[server/discover tools/list])

      server.request_meta = nil
      responses << { 'result' => tool_list_result }
      expect(server.list_tools.map(&:name)).to eq(['echo'])
    end
  end

  describe 'the inline version retry compares against the version actually sent' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    # A concurrent request can move the transport on between the guard reading
    # protocol_version and build_jsonrpc_request stamping _meta with it. The
    # metadata provider stands in for that interleaving: it is evaluated
    # inside the build, so what it does to the shared version is what the
    # request goes out declaring.
    it 'retries when another request changed the version between the guard and the build' do
      stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
      stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
      sent, = script_stdio(server, [{ 'result' => discover_result(versions: %w[2027-01-01 2026-07-28]) },
                                    unsupported_version_error(['2027-01-01'], '2026-07-28'),
                                    { 'result' => tool_list_result }])
      builds = 0
      server.request_meta = lambda {
        builds += 1
        # Build 2 is the first tools/list: another request settled the
        # transport on 2026-07-28 a moment before this one stamped its _meta.
        server.instance_variable_set(:@protocol_version, '2026-07-28') if builds == 2
        {}
      }

      expect(server.list_tools.map(&:name)).to eq(['echo'])

      expect(sent.map { |req| req['method'] }).to eq(%w[server/discover tools/list tools/list])
      expect(sent[1]['params']['_meta'][ERA_META::META_PROTOCOL_VERSION]).to eq('2026-07-28')
      expect(sent[2]['params']['_meta'][ERA_META::META_PROTOCOL_VERSION]).to eq('2027-01-01')
    end
  end
end
