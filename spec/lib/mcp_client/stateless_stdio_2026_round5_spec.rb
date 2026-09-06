# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'

# Fifth review round (codex + grok) on the MCP 2026-07-28 stateless stdio
# work. What the reviewers found this time:
#   1. a request that passed the transport-generation check could still be
#      written AFTER another thread had restarted the exited subprocess: the
#      write went to the replacement process unregistered, which executed
#      the request and had its answer discarded as unsolicited;
#   2. a modern-shaped answer to an EXPIRED probe (the discover timed out
#      and the session fell back to the handshake) identified the peer as
#      modern, after which the 2025-11-25 ping a dual-era server sends during
#      initialize was dropped and the handshake hung;
#   3. a caller's `_meta` supplied under both the String and the Symbol key
#      was serialized twice on a legacy request, so the reserved protocol
#      fields stripped from one copy reached the wire through the other;
#   4. a DiscoverResult's ttlMs was ignored, so a zero-TTL discovery — which
#      the spec says to consider immediately stale — kept gating requests on
#      capabilities the server had since enabled.
# Plus the coverage both asked for: a late modern answer against a real
# process, atomic discovery refresh, real completion values, a roots change
# against a probe that is really held open, serialized bytes at the `_meta`
# boundary, a malformed -32021 on the probe, an in-flight call at EOF, valid
# trace context, the extension settings shape and the error accessors.
R5_META = MCPClient::JsonRpcCommon
R5_FIXTURE = File.expand_path('../../support/protocol_era_stdio_server.rb', __dir__)

RSpec.describe 'MCP 2026-07-28 stateless protocol (stdio) — round 5' do
  # A DiscoverResult fresh for a minute unless the example says otherwise
  # (a hint-less one is immediately stale by the caching rules).
  def discover_result(versions: ['2026-07-28'], capabilities: { 'tools' => {} }, extra: {})
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => capabilities,
      'ttlMs' => 60_000 }.merge(extra)
  end

  def legacy_init_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
      'serverInfo' => { 'name' => 'legacy-server', 'version' => '1.0' } }
  end

  def tool_list_result
    { 'tools' => [{ 'name' => 'echo', 'description' => 'echo', 'inputSchema' => { 'type' => 'object' } }] }
  end

  def version_rejection(supported, requested)
    { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                   'data' => { 'supported' => supported, 'requested' => requested } } }
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

  def fixture_command(mode, transcript)
    [RbConfig.ruby, R5_FIXTURE, mode, transcript]
  end

  def transcript_lines(path)
    return [] unless File.exist?(path)

    File.readlines(path).map(&:strip).reject(&:empty?)
  rescue Errno::ENOENT
    []
  end

  def wait_for(what, timeout: 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
    raise "timed out after #{timeout}s waiting for #{what}" unless yield
  end

  # A negotiated transport with real pipe objects in place of a subprocess.
  def negotiated_transport
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
    %i[@stdin @stdout @stderr].each { |ivar| server.instance_variable_set(ivar, StringIO.new) }
    server.instance_variable_set(:@initialized, true)
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server
  end

  # ---------------------------------------------------------------------------
  describe 'a request whose write raced a restart' do
    # The request passed the generation check; it is paused at the write,
    # while the subprocess exits and another thread restarts it.
    def paused_at_the_write(server)
      writing = Queue.new
      restarted = Queue.new
      paused = false
      allow(server).to receive(:send_request).and_wrap_original do |original, *args|
        unless paused
          paused = true
          writing << true
          restarted.pop
        end
        original.call(*args)
      end
      [writing, restarted]
    end

    it 'is re-issued on the replacement transport registered, so its answer is delivered' do
      server = negotiated_transport
      old_stdin = server.instance_variable_get(:@stdin)
      replacement = StringIO.new
      writing, restarted = paused_at_the_write(server)

      caller = Thread.new { server.send(:send_request_and_wait, 'tools/call', { 'name' => 'echo' }, 1) }
      writing.pop
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
      expect(old_stdin.string).to be_empty
      expect(replacement.string.lines.grep(%r{tools/call}).size).to eq(1)
    end

    it 'never reaches the replacement process under the id it was registered with on the old one' do
      server = negotiated_transport
      replacement = StringIO.new
      writing, restarted = paused_at_the_write(server)
      caller = Thread.new { server.send(:send_request_and_wait, 'tools/call', { 'name' => 'echo' }, 1) }
      writing.pop
      # The id the abandoned request was registered under, read while it is
      # still the only one outstanding: what must never reach the
      # replacement is THIS id, not merely some other id.
      original = server.instance_variable_get(:@awaiting).keys.first
      server.cleanup
      server.instance_variable_set(:@stdin, replacement)
      server.instance_variable_set(:@initialized, true)
      # The replacement process takes a request of its own first, so the
      # re-issued one cannot reuse the id the old registration had.
      taken = server.send(:next_id)
      restarted << true

      wait_for('the request to reach the replacement transport') { !replacement.string.empty? }
      request = JSON.parse(replacement.string.lines.first)
      expect(original).not_to be_nil
      expect(request['id']).not_to eq(original)
      expect(request['id']).not_to eq(taken)
      # The abandoned registration is gone from both books: nothing was
      # written under it, so no waiter will ever consume it (round 7).
      expect(server.instance_variable_get(:@awaiting)).not_to have_key(original)
      expect(server.send(:dropped_requests)).not_to include(original)
      expect(server.instance_variable_get(:@awaiting).keys).to include(request['id'])
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => request['id'], 'result' => {}))
      expect(caller.value).to eq({})
    end

    it 'still surfaces a write failure on a transport that was not replaced' do
      server = negotiated_transport
      broken = StringIO.new
      broken.close_write
      server.instance_variable_set(:@stdin, broken)

      expect { server.send(:send_request_and_wait, 'tools/call', { 'name' => 'echo' }, 1) }
        .to raise_error(MCPClient::Errors::TransportError, /Failed to send/)
      expect(server.instance_variable_get(:@awaiting)).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  describe 'a modern-shaped answer to an expired probe' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    # The probe timed out (its id is no longer outstanding) and the session
    # completed the 2025-11-25 handshake.
    def legacy_session_after_a_timed_out_probe
      written = wire_stdio(server, [])
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      written
    end

    it 'does not identify the peer: a DiscoverResult for a dropped id is only discarded' do
      written = legacy_session_after_a_timed_out_probe

      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'result' => discover_result))

      expect(server.modern_peer?).to be(false)
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-ping', 'method' => 'ping'))
      expect(requests_in(written)).to eq([{ 'jsonrpc' => '2.0', 'id' => 'srv-ping', 'result' => {} }])
    end

    it 'does not identify the peer from a well-formed version rejection of a dropped id either' do
      written = legacy_session_after_a_timed_out_probe

      server.handle_line(JSON.generate({ 'jsonrpc' => '2.0', 'id' => 1 }
                                         .merge(version_rejection(['2026-07-28'], '2027-01-01'))))
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-ping', 'method' => 'ping'))

      expect(server.modern_peer?).to be(false)
      expect(requests_in(written).map { |msg| msg['id'] }).to eq(['srv-ping'])
    end

    it 'still identifies the peer from the answer to an outstanding probe' do
      written = wire_stdio(server, [])
      server.instance_variable_set(:@protocol_version, MCPClient::LATEST_PROTOCOL_VERSION)
      server.send(:begin_era_probe)
      probe_id = server.send(:next_id)

      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => probe_id, 'result' => discover_result))
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-ping', 'method' => 'ping'))

      expect(server.modern_peer?).to be(true)
      expect(written).to be_empty
    end
  end

  describe 'a modern answer that arrives after the probe timed out, against a real process' do
    let(:transcript) { File.join(Dir.tmpdir, "mcp-era-r5-#{Process.pid}-#{rand(1_000_000)}.log") }

    after { FileUtils.rm_f(transcript) }

    # The fixture answers server/discover only after the client's discover
    # timeout, then pings before answering initialize and waits for the pong
    # — the startup ping a 2025-11-25 server MAY send, which the receiver
    # MUST answer promptly.
    it 'still completes the 2025-11-25 handshake, answering the ping the server sends during it' do
      server = MCPClient::ServerStdio.new(command: fixture_command('late-discover', transcript), read_timeout: 3,
                                          discover_timeout: 0.2)
      begin
        expect(server.list_tools.map(&:name)).to eq(['echo'])
        expect(server.protocol_version).to eq('2025-11-25')
        expect(server.modern_peer?).to be(false)

        events = transcript_lines(transcript).grep_v(/\Apid /)
        expect(events).to include('server/discover', 'notifications/cancelled', 'initialize', 'response:srv-ping',
                                  'tools/list')
        expect(events.index('response:srv-ping')).to be < events.index('tools/list')
      ensure
        server.cleanup
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe 'per-call _meta supplied under both key spellings' do
    let(:transport) do
      Class.new do
        include MCPClient::JsonRpcCommon

        attr_accessor :protocol_version

        def initialize
          @logger = Logger.new(StringIO.new)
        end
      end.new
    end

    def serialized_params(params)
      json = JSON.generate(transport.build_jsonrpc_request('tools/call', params, 1))
      [json, JSON.parse(json)['params']]
    end

    it 'reaches a legacy wire as one _meta member with the reserved fields stripped, whichever came first' do
      transport.protocol_version = '2025-11-25'
      string_first = { '_meta' => { 'progressToken' => 1 },
                       :_meta => { R5_META::META_PROTOCOL_VERSION => '2026-07-28' } }
      symbol_first = { _meta: { R5_META::META_PROTOCOL_VERSION => '2026-07-28' },
                       '_meta' => { 'progressToken' => 1 } }

      [string_first, symbol_first].each do |params|
        json, wire_params = serialized_params(params)
        expect(json.scan('"_meta"').size).to eq(1), json
        expect(wire_params).to eq({ '_meta' => { 'progressToken' => 1 } })
      end
    end

    it 'merges the two spellings, the String one winning, on a modern request' do
      transport.protocol_version = '2026-07-28'
      params = { _meta: { 'progressToken' => 'sym', 'baggage' => 'tier=free' },
                 '_meta' => { 'progressToken' => 'str' } }

      json, wire_params = serialized_params(params)

      expect(json.scan('"_meta"').size).to eq(1)
      expect(wire_params['_meta']).to include('progressToken' => 'str', 'baggage' => 'tier=free',
                                              R5_META::META_PROTOCOL_VERSION => '2026-07-28')
    end

    it 'cannot reinstate the client identity through the other spelling once the host opted out' do
      transport.protocol_version = '2026-07-28'
      transport.send_client_info = false
      params = { '_meta' => { 'progressToken' => 1 },
                 :_meta => { R5_META::META_CLIENT_INFO => { 'name' => 'private-host', 'version' => '1' } } }

      json, wire_params = serialized_params(params)

      expect(json.scan('"_meta"').size).to eq(1)
      expect(wire_params['_meta']).not_to have_key(R5_META::META_CLIENT_INFO)
      expect(wire_params['_meta']['progressToken']).to eq(1)
    end

    it 'keeps a legacy request with no _meta at all untouched' do
      transport.protocol_version = '2025-11-25'

      _json, wire_params = serialized_params({ 'name' => 'echo' })

      expect(wire_params).to eq({ 'name' => 'echo' })
    end
  end

  # ---------------------------------------------------------------------------
  describe 'discovery freshness (DiscoverResult.ttlMs)' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:prompt_ref) { { 'type' => 'ref/prompt', 'name' => 'greet' } }
    let(:argument) { { 'name' => 'name', 'value' => 'a' } }
    let(:completion) { { 'completion' => { 'values' => ['ada'], 'total' => 1, 'hasMore' => false } } }

    it 'considers a zero-TTL discovery immediately stale and re-discovers before refusing a capability' do
      written = wire_stdio(server, [
                             { 'result' => discover_result(capabilities: {},
                                                           extra: {
                                                             'ttlMs' => 0, 'cacheScope' => 'public'
                                                           }) },
                             { 'result' => discover_result(capabilities: { 'completions' => {} },
                                                           extra: { 'ttlMs' => 60_000 }) },
                             { 'result' => completion }
                           ])

      result = server.complete(ref: prompt_ref, argument: argument)

      expect(requests_in(written).map do |r|
        r['method']
      end).to eq(%w[server/discover server/discover completion/complete])
      expect(result['values']).to eq(['ada'])
      expect(server.capabilities).to eq({ 'completions' => {} })
    end

    it 'refuses locally while a positive TTL is still fresh' do
      written = wire_stdio(server, [{ 'result' => discover_result(capabilities: {}, extra: { 'ttlMs' => 60_000 }) }])

      expect { server.complete(ref: prompt_ref, argument: argument) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(requests_in(written).map { |r| r['method'] }).to eq(%w[server/discover])
    end

    it 're-discovers once a positive TTL has elapsed' do
      written = wire_stdio(server, [
                             { 'result' => discover_result(capabilities: {}, extra: { 'ttlMs' => 10 }) },
                             { 'result' => discover_result(capabilities: { 'completions' => {} },
                                                           extra: { 'ttlMs' => 10 }) },
                             { 'result' => completion }
                           ])
      # The clock: at discovery, at the first gate (fresh), at the second
      # gate (expired) and at the second discovery.
      allow(server).to receive(:discovery_clock).and_return(100.0, 100.0, 200.0, 200.0)

      expect { server.complete(ref: prompt_ref, argument: argument) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(server.complete(ref: prompt_ref, argument: argument)['values']).to eq(['ada'])
      expect(requests_in(written).map do |r|
        r['method']
      end).to eq(%w[server/discover server/discover completion/complete])
    end

    # Caching: an absent ttlMs SHOULD be treated as zero, so a hint-less
    # discovery is immediately stale and re-fetched on every access.
    it 're-discovers on every access when the server gave no freshness hint' do
      hintless = { 'result' => discover_result(capabilities: {}).except('ttlMs') }
      written = wire_stdio(server, [hintless, hintless, hintless])

      expect { server.complete(ref: prompt_ref, argument: argument) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect { server.complete(ref: prompt_ref, argument: argument) }.to raise_error(MCPClient::Errors::CapabilityError)
      expect(requests_in(written).map { |r| r['method'] }).to eq(%w[server/discover server/discover server/discover])
    end

    # Caching: a stale result is re-fetched on the next access, hit or miss
    # — the server may have withdrawn a capability the stale result lists.
    it 're-discovers a zero-TTL discovery even for a capability it already declares' do
      written = wire_stdio(server, [{ 'result' => discover_result(capabilities: { 'completions' => {} },
                                                                  extra: { 'ttlMs' => 0 }) },
                                    { 'result' => discover_result(capabilities: { 'completions' => {} }) },
                                    { 'result' => completion }])

      expect(server.complete(ref: prompt_ref, argument: argument)['values']).to eq(['ada'])
      expect(requests_in(written).map do |r|
        r['method']
      end).to eq(%w[server/discover server/discover completion/complete])
    end

    it 'does not re-discover for a capability a fresh discovery declares' do
      written = wire_stdio(server, [{ 'result' => discover_result(capabilities: { 'completions' => {} }) },
                                    { 'result' => completion }])

      expect(server.complete(ref: prompt_ref, argument: argument)['values']).to eq(['ada'])
      expect(requests_in(written).map { |r| r['method'] }).to eq(%w[server/discover completion/complete])
    end

    it 'exposes the cache scope the server declared' do
      wire_stdio(server, [{ 'result' => discover_result(extra: { 'ttlMs' => 5_000, 'cacheScope' => 'private' }) }])

      server.ping

      expect(server.discovery_cache_scope).to eq('private')
      expect(server.discovery_fresh?).to be(true)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'a discovery refresh that fails to validate' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:first_identity) { { 'name' => 'srv', 'version' => '1' } }
    let(:second_identity) { { 'name' => 'srv', 'version' => '2' } }

    def discovered_server(bad_refresh)
      first = discover_result(extra: { 'instructions' => 'first', 'cacheScope' => 'private',
                                       '_meta' => { R5_META::META_SERVER_INFO => first_identity } })
      wire_stdio(server, [{ 'result' => first }, { 'result' => bad_refresh }])
      server.ping
      server
    end

    def expect_everything_kept
      expect(server.server_info).to eq(first_identity)
      expect(server.capabilities).to eq({ 'tools' => {} })
      expect(server.instructions).to eq('first')
      expect(server.supported_versions).to eq(['2026-07-28'])
      # The freshness deadline, the cache scope and the cached result are
      # the first answer's too.
      expect(server.discovery_fresh?).to be(true)
      expect(server.discovery_cache_scope).to eq('private')
      expect(server.instance_variable_get(:@last_discover_result)['instructions']).to eq('first')
    end

    it 'changes nothing, not even the identity the invalid answer carried' do
      discovered_server('resultType' => 'complete', 'supportedVersions' => 'not-a-list',
                        '_meta' => { R5_META::META_SERVER_INFO => second_identity })

      expect { server.rpc_request('server/discover') }.to raise_error(MCPClient::Errors::ConnectionError)

      expect_everything_kept
    end

    it 'rejects malformed capabilities as a whole rather than applying part of the answer' do
      discovered_server('resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                        'capabilities' => 'everything', 'instructions' => 'second',
                        '_meta' => { R5_META::META_SERVER_INFO => second_identity })

      expect { server.rpc_request('server/discover') }
        .to raise_error(MCPClient::Errors::ConnectionError, /capabilities/)

      expect_everything_kept
    end

    it 'rejects a malformed _meta as a whole' do
      discovered_server('resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                        'capabilities' => { 'prompts' => {} }, '_meta' => 'srv v2')

      expect { server.rpc_request('server/discover') }.to raise_error(MCPClient::Errors::ConnectionError, /_meta/)

      expect_everything_kept
    end
  end

  # ---------------------------------------------------------------------------
  describe 'a modern completion' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'hands back the values, total and hasMore the server returned, and sends the context' do
      written = wire_stdio(server, [
                             { 'result' => discover_result(capabilities: { 'completions' => {} }) },
                             { 'result' => { 'completion' => { 'values' => %w[ada alan], 'total' => 2,
                                                               'hasMore' => true } } }
                           ])

      completion = server.complete(ref: { 'type' => 'ref/prompt', 'name' => 'greet' },
                                   argument: { 'name' => 'name', 'value' => 'a' },
                                   context: { 'arguments' => { 'lang' => 'en' } })

      expect(completion).to eq({ 'values' => %w[ada alan], 'total' => 2, 'hasMore' => true })
      request = requests_in(written).last
      expect(request['method']).to eq('completion/complete')
      expect(request['params']['context']).to eq({ 'arguments' => { 'lang' => 'en' } })
      expect(request['params']['_meta'][R5_META::META_PROTOCOL_VERSION]).to eq('2026-07-28')
    end
  end

  # ---------------------------------------------------------------------------
  describe 'Client#roots= while a probe is really held open' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 2) }
    let(:client) do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' }])
    end

    # The probe blocks on its answer until the example supplies one; the
    # roots change is made while it is in flight.
    def roots_changed_during_a_probe(answers_after)
      answer = Queue.new
      written = wire_stdio(server, [->(_id) { answer.pop }] + answers_after)
      probe = Thread.new { server.list_tools }
      wait_for('the probe to be in flight') { server.send(:era_probe_in_flight?) }
      client
      notifier = Thread.new { client.roots = [{ 'uri' => 'file:///tmp', 'name' => 'tmp' }] }
      sleep 0.1
      expect(requests_in(written).map { |r| r['method'] }).to eq(['server/discover'])
      expect(written.map { |line| JSON.parse(line)['method'] }).not_to include('notifications/roots/list_changed')
      [answer, probe, notifier, written]
    end

    it 'writes nothing once the probe settles the era as modern' do
      answer, probe, notifier, written = roots_changed_during_a_probe([{ 'result' => tool_list_result }])

      answer << { 'result' => discover_result }
      probe.join
      notifier.join

      expect(written.map { |line| JSON.parse(line)['method'] }).not_to include('notifications/roots/list_changed')
      expect(server.protocol_era).to eq(:modern)
    end

    it 'writes the notification once the probe settles the era as legacy' do
      answer, probe, notifier, written = roots_changed_during_a_probe([{ 'result' => legacy_init_result },
                                                                       { 'result' => tool_list_result }])

      answer << { 'error' => { 'code' => -32_601, 'message' => 'Method not found' } }
      probe.join
      notifier.join

      methods = written.map { |line| JSON.parse(line)['method'] }
      expect(methods).to include('notifications/roots/list_changed')
      expect(methods.index('notifications/roots/list_changed')).to be > methods.index('notifications/initialized')
      expect(server.protocol_era).to eq(:legacy)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'the probe answered with a malformed -32021' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    # Only the mandated shape identifies a modern server; a legacy endpoint
    # that happens to use the code number is still a legacy endpoint.
    it 'falls back to the 2025-11-25 handshake' do
      written = wire_stdio(server, [
                             { 'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                                            'data' => { 'requiredCapabilities' => { 'elicitation' => [] } } } },
                             { 'result' => legacy_init_result },
                             { 'result' => tool_list_result }
                           ])

      expect(server.list_tools.map(&:name)).to eq(['echo'])
      expect(server.protocol_version).to eq('2025-11-25')
      expect(requests_in(written).map { |r| r['method'] }).to eq(%w[server/discover initialize tools/list])
    end

    it 'is surfaced, never falling back, when the shape is the mandated one' do
      wire_stdio(server, [{ 'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                                         'data' => { 'requiredCapabilities' => { 'elicitation' => {} } } } }])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::MCPError, /modern but incompatible/)
    end
  end

  # ---------------------------------------------------------------------------
  describe 'a call in flight when the subprocess exits' do
    let(:transcript) { File.join(Dir.tmpdir, "mcp-era-r5-#{Process.pid}-#{rand(1_000_000)}.log") }

    after { FileUtils.rm_f(transcript) }

    it 'fails as soon as the exit is noticed, is not replayed, and the next request restarts the server' do
      server = MCPClient::ServerStdio.new(command: fixture_command('modern-exit-on-call', transcript), read_timeout: 5)
      begin
        expect(server.list_tools.map(&:name)).to eq(['echo'])

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect { server.call_tool('echo', {}) }.to raise_error(MCPClient::Errors::MCPError, /exited/)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 4

        expect(server.list_tools.map(&:name)).to eq(['echo'])
        events = transcript_lines(transcript)
        expect(events.grep(/\Apid /).size).to eq(2)
        expect(events.count('tools/call')).to eq(1)
      ensure
        server.cleanup
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe 'W3C trace context supplied by the host' do
    let(:traceparent) { '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' }
    let(:tracestate) { 'congo=t61rcWkgMzE,rojo=00f067aa0ba902b7' }

    def stdio_with(era_responses)
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      written = wire_stdio(server, era_responses)
      server.request_meta = { 'traceparent' => traceparent, 'tracestate' => tracestate }
      [server, written]
    end

    it 'reaches the wire verbatim on every modern request' do
      server, written = stdio_with([{ 'result' => discover_result }, { 'result' => tool_list_result }])

      server.list_tools

      requests = requests_in(written)
      expect(requests.map { |r| r['method'] }).to eq(%w[server/discover tools/list])
      requests.each do |request|
        expect(request['params']['_meta']).to include('traceparent' => traceparent, 'tracestate' => tracestate)
      end
    end

    it 'reaches the wire verbatim on every legacy request, without any reserved field' do
      server, written = stdio_with([{ 'error' => { 'code' => -32_601, 'message' => 'Method not found' } },
                                    { 'result' => legacy_init_result }, { 'result' => tool_list_result }])

      server.list_tools

      requests = requests_in(written).reject { |r| r['method'] == 'server/discover' }
      expect(requests.map { |r| r['method'] }).to eq(%w[initialize tools/list])
      requests.each do |request|
        meta = request['params']['_meta']
        expect(meta).to include('traceparent' => traceparent, 'tracestate' => tracestate)
        expect(meta.keys.grep(%r{\Aio\.modelcontextprotocol/})).to be_empty
      end
    end
  end

  # ---------------------------------------------------------------------------
  describe 'extension settings' do
    let(:transport) do
      Class.new do
        include MCPClient::JsonRpcCommon

        attr_accessor :protocol_version

        def initialize
          @logger = Logger.new(StringIO.new)
          @protocol_version = '2026-07-28'
        end
      end.new
    end

    it 'are advertised as the settings object under the extension id' do
      transport.declare_extension('io.example/tasks', { 'maxConcurrent' => 2 })
      transport.declare_extension('io.example/plain')

      extensions = transport.build_jsonrpc_request('tools/list', {}, 1)
                            .dig('params', '_meta', R5_META::META_CLIENT_CAPABILITIES, 'extensions')

      expect(extensions).to eq({ 'io.example/tasks' => { 'maxConcurrent' => 2 }, 'io.example/plain' => {} })
    end

    it 'must be an object' do
      expect { transport.declare_extension('io.example/tasks', 'yes') }
        .to raise_error(ArgumentError, /settings.*object/)
      expect { transport.declare_extension('io.example/tasks', ['yes']) }
        .to raise_error(ArgumentError, /settings.*object/)
      expect(transport.declared_extensions).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  describe 'InputRequiredError accessors' do
    let(:city) { { 'method' => 'elicitation/create', 'params' => { 'message' => 'which city?' } } }

    it 'read symbol-keyed data' do
      error = MCPClient::Errors::InputRequiredError.new('unfinished',
                                                        data: { inputRequests: { 'city' => city }, requestState: 's1' })

      expect(error.input_requests).to eq({ 'city' => city })
      expect(error.request_state).to eq('s1')
    end

    it 'hand back an empty map for a malformed InputRequests' do
      [%w[not a map], 'city', 42, nil].each do |malformed|
        error = MCPClient::Errors::InputRequiredError.new('unfinished', data: { 'inputRequests' => malformed })
        expect(error.input_requests).to eq({}), malformed.inspect
      end
    end

    it 'hand back nothing for data that is not an object' do
      error = MCPClient::Errors::InputRequiredError.new('unfinished', data: 'opaque')

      expect(error.input_requests).to eq({})
      expect(error.request_state).to be_nil
    end
  end
end
