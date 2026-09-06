# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'stringio'
require 'tmpdir'
require 'webmock/rspec'

# Fourth review round (codex + grok) on the MCP 2026-07-28 stateless stdio
# work. Two interleavings that only show between a thread and the reader:
#   1. a request that registered its id, then paused inside the host's
#      request_meta provider while another thread restarted the exited
#      subprocess: the restart cleared the id, the request went out on the
#      replacement transport unregistered, and its successful answer was
#      thrown away as unsolicited;
#   2. the reader queued a DiscoverResult (or a well-formed modern version
#      rejection) and read the server's next line before the negotiating
#      thread had applied it: the era was still unknown, so a roots/list the
#      modern server MUST NOT have written was answered with a response the
#      client MUST NOT write.
# Plus the coverage both reviewers asked for: concurrent and legacy restarts,
# the inline version retry's era and same-version guards, discovery refresh
# of everything a DiscoverResult carries, the public `complete` method, the
# host metadata on the HTTP transports, a failed legacy handshake against a
# real process, the probe's identity opt-out and empty capabilities, a modern
# `log_level=` without a logging capability, legacy-mode `_meta`, and the
# initialize timeout that MUST NOT be cancelled.
R4_META = MCPClient::JsonRpcCommon
R4_FIXTURE = File.expand_path('../../support/protocol_era_stdio_server.rb', __dir__)

RSpec.describe 'MCP 2026-07-28 stateless protocol (stdio) — round 4' do
  def discover_result(versions: ['2026-07-28'], capabilities: { 'tools' => {} }, extra: {})
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => capabilities }.merge(extra)
  end

  def legacy_init_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {}, 'logging' => {} },
      'serverInfo' => { 'name' => 'legacy-server', 'version' => '1.0' } }
  end

  def tool_list_result
    { 'tools' => [{ 'name' => 'echo', 'description' => 'echo', 'inputSchema' => { 'type' => 'object' } }] }
  end

  def version_rejection(supported, requested)
    { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                   'data' => { 'supported' => supported, 'requested' => requested } } }
  end

  # Drive a ServerStdio without a subprocess. Returns [sent, written].
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

  def fixture_command(mode, transcript)
    [RbConfig.ruby, R4_FIXTURE, mode, transcript]
  end

  def transcript_lines(path)
    return [] unless File.exist?(path)

    File.readlines(path).map(&:strip).reject(&:empty?)
  rescue Errno::ENOENT
    []
  end

  def transcript_methods(path, expected, timeout: 5)
    deadline = Time.now + timeout
    loop do
      methods = transcript_lines(path).grep_v(/\Apid /)
      return methods if methods.size >= expected || Time.now > deadline

      sleep 0.02
    end
  end

  def transcript_pids(path)
    transcript_lines(path).grep(/\Apid /).map { |line| Integer(line.split.last) }
  end

  def wait_for(what, timeout: 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
    raise "timed out after #{timeout}s waiting for #{what}" unless yield
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  # ---------------------------------------------------------------------------
  describe 'a request built across a restart' do
    # A transport with real pipe objects in place of a subprocess, already
    # negotiated, so cleanup runs its whole sequence and the replacement can
    # be swapped in underneath a paused request.
    def negotiated_transport
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      %i[@stdin @stdout @stderr].each { |ivar| server.instance_variable_set(ivar, StringIO.new) }
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      server
    end

    it 'goes out on the replacement transport registered, so its answer is delivered' do
      server = negotiated_transport
      replacement = StringIO.new
      registered = Queue.new
      restarted = Queue.new
      paused = false
      # The host's metadata provider is evaluated between the id registration
      # and the write; this one pauses there, once, while the subprocess
      # exits and another thread restarts it.
      allow(server).to receive(:build_jsonrpc_request).and_wrap_original do |original, *args|
        unless paused
          paused = true
          registered << args.last
          restarted.pop
        end
        original.call(*args)
      end

      caller = Thread.new { server.send(:send_request_and_wait, 'tools/call', { 'name' => 'echo' }, 1) }
      registered.pop
      server.cleanup
      server.instance_variable_set(:@stdin, replacement)
      server.instance_variable_set(:@initialized, true)
      restarted << true

      wait_for('the request to reach the replacement transport') { !replacement.string.empty? }
      request = JSON.parse(replacement.string.lines.first)
      expect(request['method']).to eq('tools/call')
      expect(server.instance_variable_get(:@awaiting)).to have_key(request['id'])

      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => request['id'], 'result' => { 'content' => [] }))
      expect(caller.value).to eq({ 'content' => [] })
    end

    it 'is written exactly once' do
      server = negotiated_transport
      replacement = StringIO.new
      registered = Queue.new
      restarted = Queue.new
      paused = false
      allow(server).to receive(:build_jsonrpc_request).and_wrap_original do |original, *args|
        unless paused
          paused = true
          registered << args.last
          restarted.pop
        end
        original.call(*args)
      end
      caller = Thread.new { server.send(:send_request_and_wait, 'tools/call', { 'name' => 'echo' }, 1) }
      registered.pop
      old_stdin = server.instance_variable_get(:@stdin)
      server.cleanup
      server.instance_variable_set(:@stdin, replacement)
      server.instance_variable_set(:@initialized, true)
      restarted << true
      wait_for('the request to reach the replacement transport') { !replacement.string.empty? }
      request = JSON.parse(replacement.string.lines.first)
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => request['id'], 'result' => {}))
      caller.join

      expect(old_stdin.string).to be_empty
      expect(replacement.string.lines.grep(%r{tools/call}).size).to eq(1)
    end
  end

  # The fast path of ensure_initialized reads two flags a restart writes one
  # after the other. Read in the wrong order, a thread can see the handshake
  # still standing next to the retirement already cleared, and skip the lock
  # while the restart is half done.
  describe 'a request arriving while a restart is half done' do
    it 'waits for the restart instead of slipping past the lock' do
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@transport_retired, true)
      lock = server.instance_variable_get(:@init_lock)
      gate = Queue.new
      arrived = Queue.new
      first_read = true
      # The retirement flag is read through a method; hold that read until
      # the restarting thread has cleared both flags. Read in the wrong
      # order, the handshake flag has already been read — as still standing
      # — by the time this is reached.
      allow(server).to receive(:transport_retired?).and_wrap_original do |original|
        if first_read
          first_read = false
          arrived << true
          gate.pop
        end
        original.call
      end
      returned = Queue.new
      caller = Thread.new do
        server.ensure_initialized
        returned << true
      end

      arrived.pop
      lock.synchronize do
        # What release_retired_transport does, in its order, with the lock
        # held for the rest of the restart.
        server.instance_variable_set(:@initialized, false)
        server.instance_variable_set(:@transport_retired, false)
        gate << true
        sleep 0.2
        expect(returned).to be_empty
        server.instance_variable_set(:@initialized, true)
      end

      expect(returned.pop(timeout: 2)).to be(true)
      caller.join
    end
  end

  # ---------------------------------------------------------------------------
  describe 'an identifying answer settles the era before the next line is read' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:roots_calls) { [] }

    # The reader thread's view: the probe is unanswered, then two lines
    # arrive back to back — the probe's answer and a request the server
    # writes straight after it. The negotiating thread has not run yet.
    def probe_in_flight
      _sent, written = script_stdio(server, [])
      server.on_roots_list_request do |id, _params|
        roots_calls << id
        { 'roots' => [] }
      end
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      server.send(:begin_era_probe)
      [server.send(:next_id), written]
    end

    it 'ignores a roots/list that follows a DiscoverResult' do
      probe_id, written = probe_in_flight

      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => probe_id, 'result' => discover_result))
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-roots', 'method' => 'roots/list',
                                       'params' => {}))

      expect(roots_calls).to be_empty
      expect(written).to be_empty
      expect(server.modern_peer?).to be(true)
    end

    it 'ignores a roots/list that follows a well-formed modern version rejection' do
      probe_id, written = probe_in_flight

      server.handle_line(JSON.generate({ 'jsonrpc' => '2.0', 'id' => probe_id }
                                         .merge(version_rejection(['2026-07-28'], '2027-01-01'))))
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-roots', 'method' => 'roots/list',
                                       'params' => {}))

      expect(roots_calls).to be_empty
      expect(written).to be_empty
    end

    # The accommodation the era exists for: a legacy answer identifies
    # nothing yet, so the startup ping that follows it is still answered.
    it 'still answers a ping that follows a legacy rejection of the probe' do
      probe_id, written = probe_in_flight

      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => probe_id,
                                       'error' => { 'code' => -32_601, 'message' => 'Method not found' }))
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-ping', 'method' => 'ping'))

      expect(written.map { |line| JSON.parse(line) })
        .to eq([{ 'jsonrpc' => '2.0', 'id' => 'srv-ping', 'result' => {} }])
    end

    it 'forgets the identification when a new subprocess is spawned' do
      probe_id, = probe_in_flight
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => probe_id, 'result' => discover_result))
      expect(server.modern_peer?).to be(true)
      allow(server).to receive(:connect).and_call_original
      allow(Open3).to receive(:popen3).and_return([StringIO.new, StringIO.new, StringIO.new, nil])
      server.instance_variable_set(:@protocol_version, nil)

      server.connect

      expect(server.modern_peer?).to be(false)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'restarts against a real subprocess' do
    let(:transcript) { File.join(Dir.tmpdir, "mcp-era-r4-#{Process.pid}-#{rand(1_000_000)}.log") }

    after { FileUtils.rm_f(transcript) }

    it 'restarts once when several threads find the subprocess gone' do
      server = MCPClient::ServerStdio.new(command: fixture_command('modern', transcript),
                                          read_timeout: 2, discover_timeout: 2)
      expect(server.list_tools.map(&:name)).to eq(['echo'])
      # The server dies under a completed handshake, and four callers find
      # it gone at once.
      Process.kill('TERM', transcript_pids(transcript).first)
      wait_for('the transport to be retired') { server.transport_retired? }

      results = Array.new(4) { Thread.new { server.list_tools } }.map(&:value)

      expect(results.map { |tools| tools.map(&:name) }).to all(eq(['echo']))
      pids = transcript_pids(transcript)
      expect(pids.uniq.size).to eq(2)
      methods = transcript_methods(transcript, 7)
      expect(methods.count('server/discover')).to eq(2)
      expect(methods.count('tools/list')).to eq(5)
    ensure
      server&.cleanup
    end

    it 'runs the initialize handshake again when a legacy subprocess exited' do
      server = MCPClient::ServerStdio.new(command: fixture_command('legacy-one-shot', transcript),
                                          read_timeout: 2, discover_timeout: 2)
      expect(server.list_tools.map(&:name)).to eq(['echo'])
      wait_for('the transport to be retired') { server.transport_retired? }

      expect(server.list_tools.map(&:name)).to eq(['echo'])

      expect(server.protocol_era).to eq(:legacy)
      expect(transcript_pids(transcript).uniq.size).to eq(2)
      expect(transcript_methods(transcript, 8))
        .to eq(%w[server/discover initialize notifications/initialized tools/list
                  server/discover initialize notifications/initialized tools/list])
    ensure
      server&.cleanup
    end

    it 'leaves nothing behind when the legacy handshake itself is rejected' do
      stub_const('MCPClient::ServerStdio::SHUTDOWN_GRACE_PERIOD', 0.25)
      server = MCPClient::ServerStdio.new(command: fixture_command('legacy-broken-init', transcript),
                                          read_timeout: 2, discover_timeout: 2)

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /Initialize failed/)

      expect(server.instance_variable_get(:@stdin)).to be_nil
      pids = transcript_pids(transcript)
      expect(pids.size).to eq(1)
      wait_for('the subprocess to be gone') { !process_alive?(pids.first) }
      expect(transcript_methods(transcript, 2)).to eq(%w[server/discover initialize])
    ensure
      server&.cleanup
    end
  end

  # ---------------------------------------------------------------------------
  describe 'the fixture refuses malformed modern metadata, not only missing keys' do
    def ask_fixture(meta)
      out, = Open3.capture2(RbConfig.ruby, R4_FIXTURE, 'modern',
                            stdin_data: "#{JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list',
                                                         'params' => { '_meta' => meta })}\n")
      JSON.parse(out.lines.first)
    end

    it 'rejects a null protocol version' do
      answer = ask_fixture(R4_META::META_PROTOCOL_VERSION => nil, R4_META::META_CLIENT_CAPABILITIES => {})
      expect(answer.dig('error', 'code')).to eq(-32_602)
      expect(answer.dig('error', 'message')).to match(/protocolVersion/)
    end

    it 'rejects capabilities that are not an object' do
      answer = ask_fixture(R4_META::META_PROTOCOL_VERSION => '2026-07-28', R4_META::META_CLIENT_CAPABILITIES => nil)
      expect(answer.dig('error', 'code')).to eq(-32_602)
      expect(answer.dig('error', 'message')).to match(/clientCapabilities/)
    end

    it 'answers a well-formed request' do
      answer = ask_fixture(R4_META::META_PROTOCOL_VERSION => '2026-07-28', R4_META::META_CLIENT_CAPABILITIES => {})
      expect(answer['result']['tools'].map { |t| t['name'] }).to eq(['echo'])
    end
  end

  # ---------------------------------------------------------------------------
  describe 'the inline version retry' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'surfaces a well-formed rejection on a legacy session without retrying' do
      sent, = script_stdio(server, [{ 'error' => { 'code' => -32_601, 'message' => 'nope' } },
                                    { 'result' => legacy_init_result },
                                    version_rejection(['2026-07-28'], '2025-11-25'),
                                    { 'result' => tool_list_result }])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError)

      expect(sent.map { |req| req['method'] }).to eq(%w[server/discover initialize tools/list])
    end

    it 'surfaces a rejection that advertises only the version the request declared' do
      sent, = script_stdio(server, [{ 'result' => discover_result },
                                    version_rejection(['2026-07-28'], '2026-07-28'),
                                    { 'result' => tool_list_result }])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError)

      expect(sent.map { |req| req['method'] }).to eq(%w[server/discover tools/list])
      expect(server.protocol_version).to eq('2026-07-28')
    end
  end

  # ---------------------------------------------------------------------------
  describe 'a later DiscoverResult refreshes everything the first one set' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'refreshes versions, capabilities, instructions and identity, and keeps them across an invalid refresh' do
      stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
      stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
      script_stdio(server, [
                     { 'result' => discover_result(extra: { 'instructions' => 'first',
                                                            '_meta' => { R4_META::META_SERVER_INFO =>
                                                                         { 'name' => 'srv', 'version' => '1' } } }) },
                     { 'result' => discover_result(versions: %w[2026-07-28 2027-01-01],
                                                   capabilities: { 'tools' => {}, 'prompts' => {} },
                                                   extra: { 'instructions' => 'second',
                                                            '_meta' => { R4_META::META_SERVER_INFO =>
                                                                         { 'name' => 'srv', 'version' => '2' } } }) },
                     { 'result' => { 'resultType' => 'complete', 'supportedVersions' => 'not-a-list' } }
                   ])

      server.ping
      expect(server.protocol_version).to eq('2026-07-28')
      expect(server.instructions).to eq('first')

      server.rpc_request('server/discover')
      expect(server.supported_versions).to eq(%w[2026-07-28 2027-01-01])
      expect(server.protocol_version).to eq('2027-01-01')
      expect(server.capabilities).to eq({ 'tools' => {}, 'prompts' => {} })
      expect(server.instructions).to eq('second')
      expect(server.server_info).to eq({ 'name' => 'srv', 'version' => '2' })

      expect { server.rpc_request('server/discover') }.to raise_error(MCPClient::Errors::ConnectionError)
      expect(server.supported_versions).to eq(%w[2026-07-28 2027-01-01])
      expect(server.protocol_version).to eq('2027-01-01')
      expect(server.capabilities).to eq({ 'tools' => {}, 'prompts' => {} })
      expect(server.instructions).to eq('second')
      expect(server.server_info).to eq({ 'name' => 'srv', 'version' => '2' })
    end
  end

  # ---------------------------------------------------------------------------
  describe 'client-level request metadata on the HTTP transports' do
    let(:base_url) { 'https://example.com' }
    let(:bodies) { [] }

    def answer(request)
      body = JSON.parse(request.body)
      bodies << body
      result = case body['method']
               when 'initialize'
                 { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                   'serverInfo' => { 'name' => 'http', 'version' => '1' } }
               when 'tools/list' then tool_list_result
               else {}
               end
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    before do
      stub_request(:post, "#{base_url}/rpc").to_return { |request| answer(request) }
      stub_request(:post, "#{base_url}/mcp").to_return { |request| answer(request) }
    end

    it 'stamps the host metadata on every request of ServerHTTP and ServerStreamableHTTP' do
      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'http', base_url: base_url, endpoint: '/rpc', retries: 0 },
                             { type: 'streamable_http', base_url: base_url, endpoint: '/mcp', retries: 0 }],
        request_meta: { 'traceparent' => '00-http-trace-01' }
      )

      expect(client.list_tools.map(&:name)).to eq(%w[echo echo])

      requests = bodies.reject { |body| body['method'].start_with?('notifications/') }
      expect(requests.map { |body| body['method'] }.uniq).to contain_exactly('initialize', 'tools/list')
      requests.each do |body|
        expect(body.dig('params', '_meta', 'traceparent')).to eq('00-http-trace-01'), body['method']
      end
    ensure
      client&.cleanup
    end

    it 'stamps the host metadata on the requests ServerSSE posts' do
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'sse', base_url: "#{base_url}/sse", retries: 0 }],
                                     request_meta: { 'traceparent' => '00-sse-trace-01' })
      server = client.servers.first
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server.instance_variable_set(:@rpc_endpoint, "#{base_url}/messages")
      posted = []
      allow(server).to receive(:post_json_rpc_request) do |request|
        posted << request
        body = JSON.generate('jsonrpc' => '2.0', 'id' => request['id'], 'result' => tool_list_result)
        server.send(:parse_and_handle_sse_event, "event: message\ndata: #{body}\n\n")
        nil
      end

      expect(server.list_tools.map(&:name)).to eq(['echo'])

      expect(posted.map { |req| req['method'] }).to eq(['tools/list'])
      expect(posted.first.dig('params', '_meta', 'traceparent')).to eq('00-sse-trace-01')
    end
  end

  # ---------------------------------------------------------------------------
  describe 'the probe' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'omits the client identity once the host opted out' do
      sent, = script_stdio(server, [{ 'result' => discover_result }])
      server.send_client_info = false

      server.ping

      expect(sent.first['method']).to eq('server/discover')
      expect(sent.first['params']['_meta']).not_to have_key(R4_META::META_CLIENT_INFO)
      expect(sent.first['params']['_meta'][R4_META::META_PROTOCOL_VERSION]).to eq(MCPClient::LATEST_PROTOCOL_VERSION)
    end

    it 'declares no capabilities even with roots, elicitation and sampling callbacks registered' do
      sent, = script_stdio(server, [{ 'result' => discover_result }, { 'result' => tool_list_result }])
      server.on_roots_list_request { |_id, _params| { 'roots' => [] } }
      server.on_elicitation_request { |_id, _params| { 'action' => 'accept' } }
      server.on_sampling_request { |_id, _params| {} }

      server.list_tools

      expect(sent.map { |req| req['params']['_meta'][R4_META::META_CLIENT_CAPABILITIES] }).to eq([{}, {}])
    end
  end

  describe 'log_level= on a modern server' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'needs no logging capability: the level travels in _meta' do
      sent, = script_stdio(server, [{ 'result' => discover_result(capabilities: { 'tools' => {} }) },
                                    { 'result' => tool_list_result }])

      server.log_level = 'warning'
      server.list_tools

      expect(sent.map { |req| req['method'] }).to eq(%w[server/discover tools/list])
      expect(sent.last['params']['_meta'][R4_META::META_LOG_LEVEL]).to eq('warning')
    end
  end

  describe 'protocol: :legacy' do
    it 'puts no modern _meta on any request' do
      server = MCPClient::ServerStdio.new(command: 'echo test', protocol: :legacy, read_timeout: 1)
      sent, = script_stdio(server, [{ 'result' => legacy_init_result }, { 'result' => tool_list_result },
                                    { 'result' => { 'content' => [] } }])

      server.list_tools
      server.call_tool('echo', { 'x' => 1 })

      expect(sent.map { |req| req['method'] }).to eq(%w[initialize tools/list tools/call])
      sent.each do |req|
        meta = req.dig('params', '_meta') || {}
        expect(meta.keys.grep(%r{\Aio\.modelcontextprotocol/})).to be_empty, req['method']
      end
    end
  end

  describe 'a timed-out initialize' do
    it 'is not cancelled: MCP 2025-11-25 says the handshake MUST NOT be' do
      server = MCPClient::ServerStdio.new(command: 'echo test', protocol: :legacy, read_timeout: 1)
      sent, written = script_stdio(server, [MCPClient::Errors::RequestTimeoutError.new('Timeout waiting for id=1')])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /Timeout/)

      expect(sent.map { |req| req['method'] }).to eq(['initialize'])
      expect(written.map { |line| JSON.parse(line)['method'] }).not_to include('notifications/cancelled')
    end
  end

  # ---------------------------------------------------------------------------
  describe 'Client#roots= while a probe is in flight' do
    it 'leaves the decision to the transport, which settles the era first' do
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' }])
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      server.send(:begin_era_probe)
      allow(server).to receive(:rpc_notify)

      client.roots = [{ 'uri' => 'file:///tmp', 'name' => 'tmp' }]

      expect(server).to have_received(:rpc_notify).with('notifications/roots/list_changed', {})
    end
  end
end
