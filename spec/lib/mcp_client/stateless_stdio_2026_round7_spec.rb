# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Seventh review round (codex) on the MCP 2026-07-28 stateless stdio work.
# What the reviewer found this time:
#   1. a replacement subprocess inherited the era the PREVIOUS process had
#      established: connect forgot what that process had said about itself
#      but not what had been negotiated with it, and the replacement's reader
#      starts before the probe marks the era unknown — so a replacement that
#      speaks 2025-11-25 and pings at startup had its ping dropped, and both
#      the probe and the handshake then ran out their timeouts;
#   2. a server/discover answer that fails to validate could still overwrite
#      the server's identity: the identity recorder skipped only results that
#      CARRIED a supportedVersions list, so an answer missing that very field
#      was recorded before the validation rejected it;
#   3. a request abandoned unsent across a restart left its id in the
#      dropped-request bookkeeping for ever: nobody waits on an id that was
#      never written, so the entry that a waiter would have consumed
#      accumulated instead.
R7_FIXTURE = File.expand_path('../../support/protocol_era_stdio_server.rb', __dir__)

RSpec.describe 'MCP 2026-07-28 stateless protocol (stdio) — round 7' do
  def discover_result(versions: ['2026-07-28'], capabilities: { 'tools' => {} }, extra: {})
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => capabilities,
      'ttlMs' => 60_000 }.merge(extra)
  end

  def fixture_command(mode, transcript)
    [RbConfig.ruby, R7_FIXTURE, mode, transcript]
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
    sleep 0.01 until yield || Time.now > deadline
    raise "timed out waiting for #{what}" unless yield
  end

  # ---------------------------------------------------------------------------
  # 1. The era belongs to the process that established it.
  describe 'the era of a replacement process' do
    let(:transcript) { File.join(@dir, 'transcript') }

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir and example.run }
    end

    it 'is unknown the moment a replacement is spawned, before anything is negotiated' do
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      expect(server.protocol_era).to eq(:modern)
      allow(server).to receive(:spawn_server_process)
        .and_return([double('stdin', closed?: false), double('stdout'), double('stderr'),
                     double('wait_thread', alive?: true)])
      allow(server).to receive(:pin_pipe_encodings)

      server.connect

      # The reader of the replacement starts right after this, and a
      # 2025-11-25 server may ping before the probe has settled anything:
      # what the previous process negotiated must not answer for this one.
      expect(server.protocol_era).to be_nil
      expect(server.modern_peer?).to be(false)
    end

    it 'answers the startup ping of a 2025-11-25 process that replaced a modern one' do
      server = MCPClient::ServerStdio.new(command: fixture_command('modern-then-ping', transcript),
                                          read_timeout: 3, discover_timeout: 3)
      expect(server.list_tools.map(&:name)).to eq(['echo'])
      expect(server.protocol_era).to eq(:modern)
      wait_for('the transport to retire') { server.transport_retired? }

      # The window this pins is between the replacement's reader starting and
      # its probe proposing a version. Negotiation is held until the ping is
      # really on the wire and the reader has had it, so the ping is decided
      # under whatever era the replacement inherited — not raced against the
      # probe that would have cleared it.
      allow(server).to receive(:negotiate_protocol).and_wrap_original do |original, *args|
        wait_for('the replacement to ping') { transcript_lines("#{transcript}.events").include?('ping-sent') }
        sleep 0.2
        original.call(*args)
      end

      # The replacement pings before it reads anything and answers nothing
      # until the pong arrives: a client that judged it by the dead process's
      # era would drop the ping and time out here.
      expect(server.list_tools.map(&:name)).to eq(['echo'])

      expect(transcript_pids(transcript).size).to eq(2)
      expect(server.protocol_era).to eq(:legacy)
      expect(transcript_lines(transcript)).to include('response:srv-ping')
    ensure
      server&.cleanup
    end

    it 'answers a startup ping that arrives before the client has written anything' do
      server = MCPClient::ServerStdio.new(command: fixture_command('legacy-ping-immediate', transcript),
                                          read_timeout: 3, discover_timeout: 3)

      expect(server.list_tools.map(&:name)).to eq(['echo'])

      expect(server.protocol_era).to eq(:legacy)
      expect(transcript_lines(transcript)).to include('response:srv-ping')
    ensure
      server&.cleanup
    end
  end

  # ---------------------------------------------------------------------------
  # 2. An invalid refresh changes nothing, identity included.
  describe 'a server/discover answer that does not validate' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def established(server)
      server.send(:apply_discover_result,
                  discover_result(extra: { '_meta' => { MCPClient::JsonRpcCommon::META_SERVER_INFO =>
                                                          { 'name' => 'first', 'version' => '1' } },
                                           'instructions' => 'keep me' }))
    end

    it 'leaves the identity of the last valid result in place' do
      established(server)
      before = server.server_info

      expect do
        server.send(:process_jsonrpc_response,
                    { 'jsonrpc' => '2.0', 'id' => 2,
                      'result' => { 'resultType' => 'complete',
                                    '_meta' => { MCPClient::JsonRpcCommon::META_SERVER_INFO =>
                                                   { 'name' => 'different-server', 'version' => '2' } } } },
                    method: 'server/discover')
      end.not_to raise_error

      expect(server.server_info).to eq(before)
      expect(server.server_info['name']).to eq('first')
    end

    it 'changes nothing at all when the refresh is rejected on the wire' do
      established(server)
      before = { info: server.server_info, caps: server.capabilities, instructions: server.instructions,
                 versions: server.supported_versions, version: server.protocol_version }
      refresh = { 'resultType' => 'complete',
                  '_meta' => { MCPClient::JsonRpcCommon::META_SERVER_INFO =>
                                 { 'name' => 'different-server', 'version' => '2' } } }

      expect { server.send(:apply_discover_result, refresh) }
        .to raise_error(MCPClient::Errors::ConnectionError, /supportedVersions/)

      expect(server.server_info).to eq(before[:info])
      expect(server.capabilities).to eq(before[:caps])
      expect(server.instructions).to eq(before[:instructions])
      expect(server.supported_versions).to eq(before[:versions])
      expect(server.protocol_version).to eq(before[:version])
    end

    it 'still records the identity an ordinary result carries' do
      established(server)

      server.send(:process_jsonrpc_response,
                  { 'jsonrpc' => '2.0', 'id' => 3,
                    'result' => { 'resultType' => 'complete', 'tools' => [],
                                  '_meta' => { MCPClient::JsonRpcCommon::META_SERVER_INFO =>
                                                 { 'name' => 'renamed', 'version' => '3' } } } },
                  method: 'tools/list')

      expect(server.server_info).to eq({ 'name' => 'renamed', 'version' => '3' })
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Bookkeeping of a request that was never written.
  describe 'a request abandoned unsent by a restart' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'keeps no bookkeeping of the id it was registered under' do
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      allow(server).to receive(:ensure_initialized).and_return(true)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')

      abandoned = nil
      sent = []
      allow(server).to receive(:send_request) do |req, generation = nil, **_opts|
        if generation && abandoned.nil?
          abandoned = req['id']
          # The restart the caller is about to notice: it drops every
          # outstanding id, this one included.
          server.send(:dropped_requests) << req['id']
          :replaced
        else
          sent << req
          :sent
        end
      end
      allow(server).to receive(:wait_response) do |id, **_opts|
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => { 'resultType' => 'complete', 'tools' => [] } }
      end

      server.list_tools

      expect(abandoned).not_to be_nil
      expect(sent.map { |r| r['id'] }).not_to include(abandoned)
      expect(server.send(:dropped_requests)).not_to include(abandoned)
      expect(server.send(:dropped_requests)).to be_empty
      # The rebuilt request's own registration is consumed by its waiter,
      # which is stubbed here; only the abandoned id is this example's.
      expect(server.instance_variable_get(:@awaiting)).not_to have_key(abandoned)
    end
  end
  # ---------------------------------------------------------------------------
  # Coverage the reviewers asked for beyond the three defects.
  describe 'the fallback handshake of a client with host callbacks' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    # The capability builder is unit-tested elsewhere; what was missing is that
    # negotiation RESTORES those declarations after the modern probe, and that
    # the server request they authorize is actually served.
    it 'declares the registered callbacks and then serves the request they authorize' do
      server.on_roots_list_request { |_id, _params| { 'roots' => [{ 'uri' => 'file:///w', 'name' => 'w' }] } }
      server.on_sampling_request { |_p| { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'hi' } } }
      server.on_elicitation_request { |_m, _d| { action: 'accept' } }
      written = []
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      stdin = double('stdin', flush: nil, closed?: false, close: nil)
      allow(stdin).to receive(:puts) { |line| written << line }
      server.instance_variable_set(:@stdin, stdin)
      allow(server).to receive(:wait_response) do |id, **_opts|
        case JSON.parse(written.last)['method']
        when 'server/discover'
          { 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => -32_601, 'message' => 'Method not found' } }
        when 'initialize'
          { 'jsonrpc' => '2.0', 'id' => id,
            'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                          'serverInfo' => { 'name' => 'legacy', 'version' => '1' } } }
        else
          { 'jsonrpc' => '2.0', 'id' => id, 'result' => { 'resultType' => 'complete', 'tools' => [] } }
        end
      end

      server.list_tools

      initialize_request = written.map { |line| JSON.parse(line) }.find { |m| m['method'] == 'initialize' }
      expect(initialize_request['params']['capabilities'])
        .to eq({ 'elicitation' => { 'form' => {}, 'url' => {} }, 'roots' => { 'listChanged' => true },
                 'sampling' => {} })

      # And the declaration is honoured: the server asks, the host answers.
      written.clear
      server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-1', 'method' => 'roots/list'))
      response = written.map { |line| JSON.parse(line) }.find { |m| m['id'] == 'srv-1' }
      expect(response['result']).to eq({ 'roots' => [{ 'uri' => 'file:///w', 'name' => 'w' }] })
    end
  end

  describe 'a DiscoverResult that omits what it may omit' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'is applied with no capabilities and no identity of its own' do
      server.send(:apply_discover_result,
                  { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'] })

      expect(server.capabilities).to eq({})
      expect(server.server_info).to be_nil
      expect(server.protocol_version).to eq('2026-07-28')
    end

    it 'keeps the identity of an earlier result when a later one carries none' do
      server.send(:apply_discover_result,
                  discover_result(extra: { '_meta' => { MCPClient::JsonRpcCommon::META_SERVER_INFO =>
                                                          { 'name' => 'named', 'version' => '1' } } }))

      server.send(:apply_discover_result, discover_result)

      expect(server.server_info).to eq({ 'name' => 'named', 'version' => '1' })
    end
  end

  describe 'a host request_meta provider that does not return a Hash' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'is ignored rather than written to the wire' do
      server.request_meta = -> { 'not a hash' }
      server.instance_variable_set(:@protocol_version, '2026-07-28')

      params = server.send(:with_request_meta, { 'name' => 'echo' })

      expect(params['_meta']).to be_a(Hash)
      expect(params['_meta'].values).not_to include('not a hash')
    end
  end

  describe 'a notification written while the transport is replaced' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    # The request path takes the transport lock for its check-and-write;
    # rpc_notify writes on its own and must not reach a dead pipe unnoticed.
    it 'fails on the pipe it was given rather than reaching the replacement' do
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      broken = StringIO.new
      broken.close_write
      server.instance_variable_set(:@stdin, broken)

      expect { server.rpc_notify('notifications/roots/list_changed') }
        .to raise_error(MCPClient::Errors::TransportError)
    end
  end

  describe 'a discovery whose ttlMs has elapsed' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    # Characterisation: capability? reads the last DiscoverResult without
    # re-fetching. The request paths that DEPEND on a capability refresh it
    # first (require_capability!), which is what the caching rule binds.
    it 'still reports the capabilities of the last result, while a gated call refreshes first' do
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      server.send(:apply_discover_result,
                  { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                    'capabilities' => { 'completions' => {} }, 'ttlMs' => 0 })
      server.instance_variable_set(:@initialized, true)

      expect(server.discovery_fresh?).to be(false)
      expect(server.capability?('completions')).to be(true)

      refreshed = []
      allow(server).to receive(:rpc_request).and_wrap_original do |_original, method, *_rest|
        refreshed << method
        { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
          'capabilities' => { 'completions' => {} }, 'ttlMs' => 60_000 }
      end
      server.send(:require_capability!, 'completions', method: 'completion/complete')

      expect(refreshed).to eq(['server/discover'])
    end
  end

  describe 'a live modern process that never answers' do
    let(:transcript) { File.join(@dir, 'transcript') }

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir and example.run }
    end

    # The probe hang is pinned elsewhere; this is a request that times out on
    # a session that HAS negotiated, and the cancellation it owes the server.
    it 'times out the request and cancels it on the wire' do
      server = MCPClient::ServerStdio.new(command: fixture_command('modern-mute-list', transcript),
                                          read_timeout: 1, discover_timeout: 3)

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /[Tt]imeout/)

      wait_for('the cancellation to be recorded') do
        transcript_lines(transcript).include?('notifications/cancelled')
      end
      expect(transcript_lines(transcript)).to include('server/discover', 'tools/list', 'notifications/cancelled')
    ensure
      server&.cleanup
    end
  end
end
