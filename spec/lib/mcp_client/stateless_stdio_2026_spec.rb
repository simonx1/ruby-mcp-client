# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 stateless protocol on stdio (basic/index "Statelessness",
# basic/versioning, basic/transports/stdio "Backward Compatibility",
# server/discover):
# - no initialize handshake; every request carries protocolVersion,
#   clientInfo and clientCapabilities in _meta
# - server/discover probes the server's era; a DiscoverResult or a recognized
#   modern error means modern, anything else (or a timeout) means legacy and
#   the client falls back to the initialize handshake
# - UnsupportedProtocolVersionError makes the client retry with a mutually
#   supported version rather than fall back
# - ping, logging/setLevel and notifications/roots/list_changed are gone in
#   modern mode: ping maps to server/discover, the log level travels in
#   _meta, and roots changes are not announced
META_VERSION = 'io.modelcontextprotocol/protocolVersion'
META_CLIENT_INFO = 'io.modelcontextprotocol/clientInfo'
META_CLIENT_CAPS = 'io.modelcontextprotocol/clientCapabilities'
META_LOG_LEVEL = 'io.modelcontextprotocol/logLevel'
META_SERVER_INFO = 'io.modelcontextprotocol/serverInfo'

RSpec.describe 'MCP 2026-07-28 stateless protocol (stdio)' do
  def discover_result(versions: ['2026-07-28'], capabilities: { 'tools' => {} }, extra: {})
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => capabilities,
      '_meta' => { META_SERVER_INFO => { 'name' => 'modern-server', 'version' => '9.9' } },
      'instructions' => 'be nice', 'ttlMs' => 60_000, 'cacheScope' => 'public' }.merge(extra)
  end

  def legacy_init_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
      'serverInfo' => { 'name' => 'legacy-server', 'version' => '1.0' } }
  end

  # Drive a ServerStdio without a real subprocess: the process spawn and the
  # reader threads are stubbed, requests are captured, and responses are
  # served from a queue keyed by request order (or by a block).
  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    stdin = double('stdin', puts: nil, flush: nil, closed?: true, close: nil)
    server.instance_variable_set(:@stdin, stdin)
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(id) : responder
      raise response if response.is_a?(Exception)

      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  describe 'per-request _meta (JsonRpcCommon)' do
    let(:transport) do
      Class.new do
        include MCPClient::JsonRpcCommon

        attr_accessor :protocol_version

        def initialize
          @logger = Logger.new(StringIO.new)
        end
      end.new
    end

    it 'leaves params untouched for a legacy server' do
      transport.protocol_version = '2025-11-25'
      params = { name: 'echo', arguments: { a: 1 } }
      request = transport.build_jsonrpc_request('tools/call', params, 1)
      expect(request['params']).to eq(params)
    end

    it 'adds protocolVersion, clientInfo and clientCapabilities for a modern server' do
      transport.protocol_version = '2026-07-28'
      request = transport.build_jsonrpc_request('tools/list', {}, 1)
      meta = request['params']['_meta']
      expect(meta[META_VERSION]).to eq('2026-07-28')
      expect(meta[META_CLIENT_INFO]).to eq({ 'name' => 'ruby-mcp-client', 'version' => MCPClient::VERSION })
      expect(meta[META_CLIENT_CAPS]).to eq({})
    end

    it 'injects _meta even when params are nil' do
      transport.protocol_version = '2026-07-28'
      request = transport.build_jsonrpc_request('server/discover', nil, 1)
      expect(request['params']['_meta'][META_VERSION]).to eq('2026-07-28')
    end

    it 'preserves host-supplied _meta keys such as progressToken and trace context' do
      transport.protocol_version = '2026-07-28'
      params = { name: 'echo', '_meta' => { 'progressToken' => 'p1', 'traceparent' => '00-abc-def-01' } }
      meta = transport.build_jsonrpc_request('tools/call', params, 1)['params']['_meta']
      expect(meta['progressToken']).to eq('p1')
      expect(meta['traceparent']).to eq('00-abc-def-01')
      expect(meta[META_VERSION]).to eq('2026-07-28')
    end

    it 'accepts a symbol-keyed _meta and normalizes to the string key' do
      transport.protocol_version = '2026-07-28'
      params = { name: 'echo', _meta: { progressToken: 'p1' } }
      request_params = transport.build_jsonrpc_request('tools/call', params, 1)['params']
      expect(request_params.key?(:_meta)).to be(false)
      expect(request_params['_meta']['progressToken']).to eq('p1')
      expect(request_params['_meta'][META_VERSION]).to eq('2026-07-28')
    end

    it 'does not let host _meta override the required protocol fields' do
      transport.protocol_version = '2026-07-28'
      params = { '_meta' => { META_VERSION => '1900-01-01', META_CLIENT_CAPS => { 'roots' => {} } } }
      meta = transport.build_jsonrpc_request('tools/list', params, 1)['params']['_meta']
      expect(meta[META_VERSION]).to eq('2026-07-28')
      expect(meta[META_CLIENT_CAPS]).to eq({})
    end

    it 'omits clientInfo when the host configured it off' do
      transport.protocol_version = '2026-07-28'
      transport.send_client_info = false
      meta = transport.build_jsonrpc_request('tools/list', {}, 1)['params']['_meta']
      expect(meta).not_to have_key(META_CLIENT_INFO)
      expect(meta[META_VERSION]).to eq('2026-07-28')
    end

    it 'includes the per-request log level once set' do
      transport.protocol_version = '2026-07-28'
      transport.instance_variable_set(:@log_level, 'warning')
      meta = transport.build_jsonrpc_request('tools/list', {}, 1)['params']['_meta']
      expect(meta[META_LOG_LEVEL]).to eq('warning')
    end

    it 'lets a host-supplied per-request logLevel win over the default' do
      transport.protocol_version = '2026-07-28'
      transport.instance_variable_set(:@log_level, 'warning')
      params = { '_meta' => { META_LOG_LEVEL => 'debug' } }
      meta = transport.build_jsonrpc_request('tools/list', params, 1)['params']['_meta']
      expect(meta[META_LOG_LEVEL]).to eq('debug')
    end

    it 'merges host request_meta (Hash) into every request in both eras' do
      transport.request_meta = { 'traceparent' => '00-1-2-01', 'baggage' => 'k=v' }
      transport.protocol_version = '2025-11-25'
      legacy_meta = transport.build_jsonrpc_request('tools/list', {}, 1)['params']['_meta']
      expect(legacy_meta).to eq({ 'traceparent' => '00-1-2-01', 'baggage' => 'k=v' })
      expect(legacy_meta).not_to have_key(META_VERSION)

      transport.protocol_version = '2026-07-28'
      modern_meta = transport.build_jsonrpc_request('tools/list', {}, 1)['params']['_meta']
      expect(modern_meta['traceparent']).to eq('00-1-2-01')
      expect(modern_meta[META_VERSION]).to eq('2026-07-28')
    end

    it 'calls a request_meta proc per request and cannot override required fields' do
      calls = 0
      transport.request_meta = lambda do
        calls += 1
        { 'tracestate' => "n=#{calls}", META_VERSION => 'evil' }
      end
      transport.protocol_version = '2026-07-28'
      first = transport.build_jsonrpc_request('tools/list', {}, 1)['params']['_meta']
      second = transport.build_jsonrpc_request('tools/list', {}, 2)['params']['_meta']
      expect(first['tracestate']).to eq('n=1')
      expect(second['tracestate']).to eq('n=2')
      expect(first[META_VERSION]).to eq('2026-07-28')
    end

    it 'declares roots with listChanged only to legacy servers (removed in 2026-07-28)' do
      transport.instance_variable_set(:@roots_list_request_callback, proc {})
      transport.protocol_version = '2025-11-25'
      expect(transport.client_capabilities['roots']).to eq({ 'listChanged' => true })
      transport.protocol_version = '2026-07-28'
      expect(transport.client_capabilities).not_to have_key('roots')
    end

    it 'declares negotiated extensions under clientCapabilities.extensions' do
      transport.protocol_version = '2026-07-28'
      transport.declare_extension('io.modelcontextprotocol/tasks')
      transport.declare_extension('com.example/ui', { 'mimeTypes' => ['text/html'] })
      caps = transport.build_jsonrpc_request('tools/list', {}, 1)['params']['_meta'][META_CLIENT_CAPS]
      expect(caps['extensions']).to eq({ 'io.modelcontextprotocol/tasks' => {},
                                         'com.example/ui' => { 'mimeTypes' => ['text/html'] } })
    end

    it 'rejects extension identifiers without the mandatory prefix' do
      expect { transport.declare_extension('tasks') }.to raise_error(ArgumentError, /prefix/)
    end

    it 'reports the era from the protocol version' do
      transport.protocol_version = nil
      expect(transport.modern?).to be(false)
      transport.protocol_version = '2025-11-25'
      expect(transport.modern?).to be(false)
      transport.protocol_version = '2026-07-28'
      expect(transport.modern?).to be(true)
    end

    it 'selects the newest mutually supported modern version' do
      stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
      expect(transport.select_protocol_version(%w[2026-07-28 2025-11-25])).to eq('2026-07-28')
      expect(transport.select_protocol_version(%w[2026-07-28 2027-01-01])).to eq('2027-01-01')
      expect(transport.select_protocol_version(%w[2025-11-25])).to be_nil
      expect(transport.select_protocol_version(nil)).to be_nil
    end
  end

  describe 'server/discover probe on stdio' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'goes modern when the server returns a DiscoverResult' do
      sent = script_stdio(server, [{ 'result' => discover_result }, { 'result' => { 'tools' => [] } }])

      server.list_tools

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover tools/list])
      expect(server.protocol_era).to eq(:modern)
      expect(server.protocol_version).to eq('2026-07-28')
      expect(server.capabilities).to eq({ 'tools' => {} })
      expect(server.server_info).to eq({ 'name' => 'modern-server', 'version' => '9.9' })
      expect(server.instructions).to eq('be nice')
      expect(server.supported_versions).to eq(['2026-07-28'])
    end

    it 'declares the version, identity and capabilities on the probe itself' do
      sent = script_stdio(server, [{ 'result' => discover_result }])

      server.ping

      probe = sent.first
      expect(probe['method']).to eq('server/discover')
      expect(probe['params']['_meta'][META_VERSION]).to eq(MCPClient::LATEST_PROTOCOL_VERSION)
      expect(probe['params']['_meta'][META_CLIENT_INFO]['name']).to eq('ruby-mcp-client')
      expect(probe['params']['_meta']).to have_key(META_CLIENT_CAPS)
    end

    it 'carries the required _meta on every subsequent request and never sends initialize' do
      sent = script_stdio(server, [{ 'result' => discover_result }, { 'result' => { 'tools' => [] } },
                                   { 'result' => { 'content' => [] } }])

      server.list_tools
      server.call_tool('echo', { 'x' => 1 })

      expect(sent.map { |r| r['method'] }).not_to include('initialize', 'notifications/initialized')
      sent.each do |req|
        expect(req['params']['_meta'][META_VERSION]).to eq('2026-07-28')
        expect(req['params']['_meta'][META_CLIENT_CAPS]).to be_a(Hash)
      end
      expect(sent.last['params']['name']).to eq('echo')
      expect(sent.last['params']['arguments']).to eq({ 'x' => 1 })
    end

    it 'picks the newest version this client speaks from supportedVersions' do
      stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
      stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
      sent = script_stdio(server, [{ 'result' => discover_result(versions: %w[2026-07-28 2025-11-25]) },
                                   { 'result' => { 'tools' => [] } }])

      server.list_tools

      expect(sent.first['params']['_meta'][META_VERSION]).to eq('2027-01-01')
      expect(server.protocol_version).to eq('2026-07-28')
      expect(sent.last['params']['_meta'][META_VERSION]).to eq('2026-07-28')
    end

    it 'fails without falling back when no supported version is mutually supported' do
      sent = script_stdio(server, [{ 'result' => discover_result(versions: ['2099-01-01']) }])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /2099-01-01/)
      expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
    end

    it 'treats UnsupportedProtocolVersionError as a modern server and retries with an advertised version' do
      stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
      stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
      sent = script_stdio(server, [
                            { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                           'data' => { 'supported' => ['2026-07-28'], 'requested' => '2027-01-01' } } },
                            { 'result' => discover_result },
                            { 'result' => { 'tools' => [] } }
                          ])

      server.list_tools

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover server/discover tools/list])
      expect(sent[0]['params']['_meta'][META_VERSION]).to eq('2027-01-01')
      expect(sent[1]['params']['_meta'][META_VERSION]).to eq('2026-07-28')
      expect(sent[0]['id']).not_to eq(sent[1]['id'])
      expect(server.protocol_era).to eq(:modern)
    end

    it 'does not fall back to initialize when the advertised versions are all unknown' do
      sent = script_stdio(server, [
                            { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                           'data' => { 'supported' => ['2099-01-01'], 'requested' => '2026-07-28' } } }
                          ])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /2099-01-01/)
      expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
    end

    it 'falls back to the initialize handshake on any other error' do
      sent = script_stdio(server, [{ 'error' => { 'code' => -32_601, 'message' => 'Method not found' } },
                                   { 'result' => legacy_init_result },
                                   { 'result' => { 'tools' => [] } }])

      server.list_tools

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover initialize tools/list])
      expect(server.protocol_era).to eq(:legacy)
      expect(server.protocol_version).to eq('2025-11-25')
      expect(sent.last['params']).not_to have_key('_meta')
      expect(server.server_info).to eq({ 'name' => 'legacy-server', 'version' => '1.0' })
    end

    # The stdio backward-compatibility rules key the fallback to the server
    # answering the probe with an error, not to one code: a legacy server
    # rejects a pre-initialize request with whatever its framework produces.
    {
      -32_601 => 'method not found',
      -32_600 => 'invalid request',
      -32_602 => 'invalid params',
      -32_603 => 'internal error',
      -32_000 => 'an implementation-defined server error'
    }.each do |code, label|
      it "falls back to the initialize handshake when the probe is refused with #{code} (#{label})" do
        sent = script_stdio(server, [{ 'error' => { 'code' => code, 'message' => label } },
                                     { 'result' => legacy_init_result },
                                     { 'result' => { 'tools' => [] } }])

        server.list_tools

        expect(sent.map { |r| r['method'] }).to eq(%w[server/discover initialize tools/list])
        expect(server.protocol_era).to eq(:legacy)
        expect(server.protocol_version).to eq('2025-11-25')
      end
    end

    # -32022 identifies a modern server only when its data carries the
    # versions the client is told to retry with; without them there is
    # nothing to act on, so it is just another error answer from a legacy
    # server.
    it 'treats a -32022 without a supported list as a legacy answer, not a modern rejection' do
      sent = script_stdio(server, [{ 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                                  'data' => { 'requested' => '2026-07-28' } } },
                                   { 'result' => legacy_init_result },
                                   { 'result' => { 'tools' => [] } }])

      server.list_tools

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover initialize tools/list])
      expect(server.protocol_era).to eq(:legacy)
    end

    it 'falls back to initialize when the probe times out' do
      sent = script_stdio(server, [MCPClient::Errors::RequestTimeoutError.new('timeout'),
                                   { 'result' => legacy_init_result },
                                   { 'result' => { 'tools' => [] } }])

      server.list_tools

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover initialize tools/list])
      expect(server.protocol_era).to eq(:legacy)
    end

    it 'waits at most discover_timeout for the probe' do
      server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 30, discover_timeout: 2)
      timeouts = []
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil))
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response) do |id, timeout: nil|
        timeouts << timeout
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => discover_result }
      end

      server.ping

      expect(timeouts.first).to eq(2)
    end

    it 'skips the probe entirely when protocol: :legacy is configured' do
      server = MCPClient::ServerStdio.new(command: 'echo test', protocol: :legacy)
      sent = script_stdio(server, [{ 'result' => legacy_init_result }, { 'result' => { 'tools' => [] } }])

      server.list_tools

      expect(sent.map { |r| r['method'] }).to eq(%w[initialize tools/list])
      expect(server.protocol_era).to eq(:legacy)
    end

    it 'surfaces an actionable error instead of falling back when protocol: :modern is configured' do
      server = MCPClient::ServerStdio.new(command: 'echo test', protocol: :modern)
      sent = script_stdio(server, [{ 'error' => { 'code' => -32_601, 'message' => 'Method not found' } }])

      expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /legacy|initialize/i)
      expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
    end

    it 'rejects an unknown protocol mode' do
      expect { MCPClient::ServerStdio.new(command: 'echo', protocol: :bogus) }.to raise_error(ArgumentError, /protocol/)
    end

    it 'treats a probe answer without supportedVersions as a legacy answer' do
      sent = script_stdio(server, [{ 'result' => { 'resultType' => 'complete', 'capabilities' => {} } },
                                   { 'result' => legacy_init_result }, { 'result' => {} }])

      server.ping

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover initialize ping])
    end

    it 'reports the era as unknown before the first request' do
      expect(server.protocol_era).to be_nil
      expect(server.protocol_version).to be_nil
    end
  end

  describe 'modern-mode behaviour on stdio' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'maps ping to server/discover (ping was removed from the protocol)' do
      sent = script_stdio(server, [{ 'result' => discover_result }, { 'result' => discover_result }])

      server.ping
      result = server.ping

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover server/discover])
      expect(result['supportedVersions']).to eq(['2026-07-28'])
    end

    it 'sets the log level per request via _meta instead of logging/setLevel' do
      sent = script_stdio(server, [{ 'result' => discover_result(capabilities: { 'logging' => {} }) },
                                   { 'result' => { 'tools' => [] } }])

      server.log_level = 'debug'
      server.list_tools

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover tools/list])
      expect(sent.last['params']['_meta'][META_LOG_LEVEL]).to eq('debug')
    end

    it 'rejects an unknown log level locally' do
      script_stdio(server, [{ 'result' => discover_result }])
      expect { server.log_level = 'loud' }.to raise_error(ArgumentError, /log level/i)
    end

    it 'still sends logging/setLevel to a legacy server' do
      sent = script_stdio(server, [{ 'error' => { 'code' => -32_601, 'message' => 'nope' } },
                                   { 'result' => legacy_init_result.merge('capabilities' => { 'logging' => {} }) },
                                   { 'result' => {} }])

      server.log_level = 'debug'

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover initialize logging/setLevel])
    end

    it 'retries a request once with an advertised version after an inline UnsupportedProtocolVersionError' do
      stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
      stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
      sent = script_stdio(server, [
                            { 'result' => discover_result(versions: %w[2027-01-01]) },
                            { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                           'data' => { 'supported' => ['2026-07-28'], 'requested' => '2027-01-01' } } },
                            { 'result' => { 'tools' => [] } }
                          ])

      server.list_tools

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover tools/list tools/list])
      expect(sent[1]['params']['_meta'][META_VERSION]).to eq('2027-01-01')
      expect(sent[2]['params']['_meta'][META_VERSION]).to eq('2026-07-28')
      expect(sent[1]['id']).not_to eq(sent[2]['id'])
      expect(server.protocol_version).to eq('2026-07-28')
    end

    # "Retry the request" once, not renegotiate: a server that keeps
    # rejecting must end the exchange, not drive an unbounded round of
    # version proposals.
    it 'retries an inline version rejection exactly once and surfaces a second rejection' do
      stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
      stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
      sent = script_stdio(server, [
                            { 'result' => discover_result(versions: %w[2027-01-01]) },
                            { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                           'data' => { 'supported' => ['2026-07-28'], 'requested' => '2027-01-01' } } },
                            { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                           'data' => { 'supported' => ['2027-01-01'], 'requested' => '2026-07-28' } } },
                            # Only a client that renegotiated instead of
                            # retrying once would ever reach this.
                            { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'ok' }] } }
                          ])
      server.request_meta = { 'traceparent' => '00-abc-def-01' }

      expect { server.call_tool('echo', { 'a' => 1 }) }
        .to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError)

      expect(sent.map { |r| r['method'] }).to eq(%w[server/discover tools/call tools/call])
      # The retry re-sends the same call: same arguments, same host metadata,
      # a fresh id and the version the server named.
      expect(sent[2]['params']['arguments']).to eq({ 'a' => 1 })
      expect(sent[2]['params']['_meta']['traceparent']).to eq('00-abc-def-01')
      expect(sent[1]['params']['_meta'][META_VERSION]).to eq('2027-01-01')
      expect(sent[2]['params']['_meta'][META_VERSION]).to eq('2026-07-28')
      expect(sent[1]['id']).not_to eq(sent[2]['id'])
    end

    it 'raises the UnsupportedProtocolVersionError when no advertised version is usable' do
      script_stdio(server, [
                     { 'result' => discover_result },
                     { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                    'data' => { 'supported' => ['2099-01-01'], 'requested' => '2026-07-28' } } }
                   ])

      expect { server.rpc_request('tools/list') }.to raise_error(MCPClient::Errors::UnsupportedProtocolVersionError)
    end

    it 'refreshes serverInfo from a result _meta' do
      renamed = { META_SERVER_INFO => { 'name' => 'renamed', 'version' => '2' } }
      script_stdio(server, [{ 'result' => discover_result },
                            { 'result' => { 'tools' => [], '_meta' => renamed } }])

      server.list_tools

      expect(server.server_info).to eq({ 'name' => 'renamed', 'version' => '2' })
    end

    it 'still sends notifications/cancelled when a request times out (stdio cancellation)' do
      stdin_lines = []
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   MCPClient::Errors::RequestTimeoutError.new('Timeout waiting')])
      server.instance_variable_set(:@stdin, double('stdin', flush: nil).tap do |d|
        allow(d).to receive(:puts) { |line| stdin_lines << line }
      end)

      expect { server.rpc_request('tools/list') }.to raise_error(MCPClient::Errors::RequestTimeoutError)

      cancelled = stdin_lines.map { |l| JSON.parse(l) }.find { |m| m['method'] == 'notifications/cancelled' }
      expect(cancelled['params']['requestId']).to eq(sent.last['id'])
    end
  end

  describe 'client-level behaviour with a modern server' do
    it 'does not send notifications/roots/list_changed to modern servers' do
      modern = MCPClient::ServerStdio.new(command: 'echo modern')
      legacy = MCPClient::ServerStdio.new(command: 'echo legacy')
      modern.instance_variable_set(:@protocol_version, '2026-07-28')
      legacy.instance_variable_set(:@protocol_version, '2025-11-25')
      allow(MCPClient::ServerFactory).to receive(:create).and_return(modern, legacy)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' },
                                                          { type: 'stdio', command: 'b' }])
      expect(modern).not_to receive(:rpc_notify)
      expect(legacy).to receive(:rpc_notify).with('notifications/roots/list_changed', {})

      client.roots = [{ 'uri' => 'file:///tmp', 'name' => 'tmp' }]
    end

    it 'passes request_meta from the client to every server' do
      meta = { 'traceparent' => '00-abc-def-01' }
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'a' }], request_meta: meta)
      expect(client.servers.first.request_meta).to eq(meta)
    end

    it 'builds stdio configs with the protocol mode and discover timeout' do
      config = MCPClient.stdio_config(command: 'x', protocol: :modern, discover_timeout: 3)
      expect(config[:protocol]).to eq(:modern)
      expect(config[:discover_timeout]).to eq(3)

      server = MCPClient::ServerFactory.create(config)
      expect(server.protocol_mode).to eq(:modern)
      expect(server.discover_timeout).to eq(3)
    end

    it 'defaults the stdio protocol mode to :auto' do
      server = MCPClient::ServerFactory.create(MCPClient.stdio_config(command: 'x'))
      expect(server.protocol_mode).to eq(:auto)
    end
  end
end

# Review round 2 (codex + grok): modern errors other than -32022 must not
# fall back, roots changes must not reach a modern server even before the
# era is known, every DiscoverResult is applied, the probe waits the full
# read timeout, initialization is serialized, and — until the multi
# round-trip pattern lands — modern requests do not declare capabilities
# this client could only serve over the removed server-request channel.
RSpec.describe 'MCP 2026-07-28 stateless protocol (stdio) — review follow-ups' do
  def discover_result(versions: ['2026-07-28'], capabilities: { 'tools' => {} })
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => capabilities,
      '_meta' => { META_SERVER_INFO => { 'name' => 'modern-server', 'version' => '9.9' } } }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(id) : responder
      raise response if response.is_a?(Exception)

      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  it 'does not fall back to initialize on a MissingRequiredClientCapabilityError probe answer' do
    sent = script_stdio(server, [{ 'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                                                'data' => { 'requiredCapabilities' => { 'elicitation' => {} } } } }])

    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /Missing required client capability/)
    expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
    expect(server.protocol_era).to be_nil
  end

  it 'does not fall back to initialize on a HeaderMismatchError probe answer' do
    sent = script_stdio(server, [{ 'error' => { 'code' => -32_020, 'message' => 'Header mismatch' } }])

    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError, /Header mismatch/)
    expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
  end

  it 'clears the tentative version when the DiscoverResult offers no mutual version' do
    script_stdio(server, [{ 'result' => discover_result(versions: ['2099-01-01']) }])

    expect { server.list_tools }.to raise_error(MCPClient::Errors::ToolCallError)
    expect(server.protocol_era).to be_nil
    expect(server.modern?).to be(false)
  end

  it 'never sends notifications/roots/list_changed to a modern server, even before the era is known' do
    stdin_lines = []
    sent = script_stdio(server, [{ 'result' => discover_result }])
    server.instance_variable_set(:@stdin, double('stdin', flush: nil, closed?: true, close: nil).tap do |d|
      allow(d).to receive(:puts) { |line| stdin_lines << line }
    end)
    server.on_roots_list_request { |_id, _params| { 'roots' => [] } }

    server.rpc_notify('notifications/roots/list_changed', {})

    expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
    expect(stdin_lines.map { |l| JSON.parse(l)['method'] }).not_to include('notifications/roots/list_changed')
  end

  it 'still forwards other notifications to a modern server' do
    stdin_lines = []
    script_stdio(server, [{ 'result' => discover_result }])
    server.instance_variable_set(:@stdin, double('stdin', flush: nil, closed?: true, close: nil).tap do |d|
      allow(d).to receive(:puts) { |line| stdin_lines << line }
    end)

    server.rpc_notify('notifications/cancelled', { 'requestId' => 1 })

    expect(stdin_lines.map { |l| JSON.parse(l)['method'] }).to include('notifications/cancelled')
  end

  it 'applies every DiscoverResult, not only the probe' do
    script_stdio(server, [{ 'result' => discover_result(capabilities: { 'tools' => {} }) },
                          { 'result' => discover_result(capabilities: { 'tools' => {}, 'prompts' => {} }) }])

    server.ping
    server.rpc_request('server/discover')

    expect(server.capabilities).to eq({ 'tools' => {}, 'prompts' => {} })
  end

  it 'waits the full read timeout for the probe by default' do
    server = MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 20)
    expect(server.discover_timeout).to eq(20)
  end

  it 'serializes concurrent first requests so the probe runs once' do
    probes = 0
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request)
    allow(server).to receive(:wait_response) do |id, **_opts|
      probes += 1
      sleep 0.05
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => discover_result }
    end

    threads = Array.new(4) { Thread.new { server.ping } }
    threads.each(&:join)

    expect(probes).to eq(1)
    expect(server.protocol_era).to eq(:modern)
  end

  describe 'modern client capabilities before multi round-trip support' do
    let(:transport) do
      Class.new do
        include MCPClient::JsonRpcCommon

        attr_accessor :protocol_version

        def initialize
          @logger = Logger.new(StringIO.new)
        end
      end.new
    end

    it 'omits roots, elicitation and sampling from modern requests' do
      transport.instance_variable_set(:@roots_list_request_callback, proc {})
      transport.instance_variable_set(:@elicitation_request_callback, proc {})
      transport.instance_variable_set(:@sampling_request_callback, proc {})
      transport.protocol_version = '2025-11-25'
      expect(transport.client_capabilities.keys).to include('roots', 'elicitation', 'sampling')
      transport.protocol_version = '2026-07-28'
      expect(transport.client_capabilities).to eq({})
    end

    it 'surfaces an input_required result as InputRequiredError instead of a tool result' do
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => { 'resultType' => 'input_required', 'requestState' => 'blob',
                                                   'inputRequests' => { 'k' => { 'method' => 'roots/list' } } } }])

      expect { server.call_tool('t', {}) }.to raise_error(MCPClient::Errors::InputRequiredError) do |e|
        expect(e.request_state).to eq('blob')
        expect(e.input_requests).to eq({ 'k' => { 'method' => 'roots/list' } })
      end
      expect(sent.size).to eq(2)
    end
  end
end

# Review round 3 (codex): a server that answered the probe with a well-formed
# UnsupportedProtocolVersionError is conclusively modern; every
# server/discover answer is validated; version renegotiation compares
# against the version a request was actually sent with; a probe answered
# with something that is not a DiscoverResult is a legacy server.
RSpec.describe 'MCP 2026-07-28 stateless protocol (stdio) — probe and renegotiation edges' do
  def discover_result(versions: ['2026-07-28'], capabilities: { 'tools' => {} })
    { 'resultType' => 'complete', 'supportedVersions' => versions, 'capabilities' => capabilities }
  end

  def script_stdio(server, responses)
    sent = []
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    allow(server).to receive(:send_request) { |req| sent << req }
    allow(server).to receive(:wait_response) do |id, **_opts|
      responder = responses.shift
      raise 'no scripted response left' unless responder

      response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
      raise response if response.is_a?(Exception)

      response.merge('jsonrpc' => '2.0', 'id' => id)
    end
    sent
  end

  let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

  it 'does not fall back to initialize when the retried probe fails after a well-formed -32022' do
    stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
    stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
    sent = script_stdio(server, [
                          { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                                         'data' => { 'supported' => ['2026-07-28'], 'requested' => '2027-01-01' } } },
                          { 'error' => { 'code' => -32_603, 'message' => 'Internal error' } }
                        ])

    expect { server.ping }.to raise_error(MCPClient::Errors::ConnectionError, /Internal error/)
    expect(sent.map { |r| r['method'] }).to eq(%w[server/discover server/discover])
  end

  it 'falls back to initialize when the probe is answered with something that is not a DiscoverResult' do
    sent = script_stdio(server, [{ 'result' => { 'resultType' => 'complete', 'capabilities' => {} } },
                                 { 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {},
                                                 'serverInfo' => { 'name' => 'legacy', 'version' => '1' } } },
                                 { 'result' => { 'tools' => [] } }])

    server.list_tools

    expect(sent.map { |r| r['method'] }).to eq(%w[server/discover initialize tools/list])
    expect(server.protocol_era).to eq(:legacy)
  end

  it 'falls back to initialize when the probe is answered with a non-object result' do
    sent = script_stdio(server, [{ 'result' => nil },
                                 { 'result' => { 'protocolVersion' => '2025-11-25', 'capabilities' => {} } },
                                 { 'result' => {} }])

    server.ping

    expect(sent.map { |r| r['method'] }).to eq(%w[server/discover initialize ping])
    expect(server.protocol_era).to eq(:legacy)
  end

  it 'refuses to fall back on a malformed DiscoverResult when protocol: :modern is configured' do
    server = MCPClient::ServerStdio.new(command: 'echo test', protocol: :modern)
    sent = script_stdio(server, [{ 'result' => { 'resultType' => 'complete', 'capabilities' => {} } }])

    expect { server.ping }.to raise_error(MCPClient::Errors::ConnectionError, /legacy|initialize/i)
    expect(sent.map { |r| r['method'] }).to eq(['server/discover'])
  end

  it 'validates every later server/discover answer' do
    script_stdio(server, [{ 'result' => discover_result },
                          { 'result' => { 'resultType' => 'complete', 'capabilities' => {} } }])

    server.ping
    expect { server.rpc_request('server/discover') }
      .to raise_error(MCPClient::Errors::ConnectionError, /supportedVersions/)
  end

  it 'retries a request rejected for the version it was actually sent with, even after another request switched' do
    stub_const('MCPClient::MODERN_PROTOCOL_VERSIONS', %w[2027-01-01 2026-07-28])
    stub_const('MCPClient::LATEST_PROTOCOL_VERSION', '2027-01-01')
    rejection = { 'error' => { 'code' => -32_022, 'message' => 'Unsupported protocol version',
                               'data' => { 'supported' => ['2026-07-28'], 'requested' => '2027-01-01' } } }
    sent = script_stdio(server, [
                          { 'result' => discover_result(versions: ['2027-01-01']) },
                          # The response to this request arrives after a concurrent request already
                          # moved the transport to 2026-07-28.
                          lambda { |_req|
                            server.instance_variable_set(:@protocol_version, '2026-07-28')
                            rejection
                          },
                          { 'result' => { 'tools' => [] } }
                        ])

    expect(server.list_tools).to eq([])
    lists = sent.select { |r| r['method'] == 'tools/list' }
    expect(lists.size).to eq(2)
    expect(lists[1]['params']['_meta']['io.modelcontextprotocol/protocolVersion']).to eq('2026-07-28')
  end
end

# Review round 3 (grok): a modern stdio client MUST NOT write JSON-RPC
# responses — server-initiated requests (ping, elicitation, roots,
# sampling) do not exist in 2026-07-28 and are dropped, not answered.
RSpec.describe 'MCP 2026-07-28 stateless protocol (stdio) — server-initiated requests' do
  let(:server) { MCPClient::ServerStdio.new(command: 'echo test') }

  it 'drops server-initiated requests on a modern session instead of responding' do
    written = []
    server.instance_variable_set(:@protocol_version, '2026-07-28')
    server.instance_variable_set(:@stdin, double('stdin', flush: nil).tap do |d|
      allow(d).to receive(:puts) { |line| written << line }
    end)
    calls = 0
    server.on_roots_list_request do |_id, _p|
      calls += 1
      { 'roots' => [] }
    end

    server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-1', 'method' => 'ping'))
    server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-2', 'method' => 'roots/list', 'params' => {}))

    expect(written).to be_empty
    expect(calls).to eq(0)
  end

  it 'still answers server-initiated requests on a legacy session' do
    written = []
    server.instance_variable_set(:@protocol_version, '2025-11-25')
    server.instance_variable_set(:@stdin, double('stdin', flush: nil).tap do |d|
      allow(d).to receive(:puts) { |line| written << line }
    end)

    server.handle_line(JSON.generate('jsonrpc' => '2.0', 'id' => 'srv-1', 'method' => 'ping'))

    expect(written.map { |l| JSON.parse(l) }).to eq([{ 'jsonrpc' => '2.0', 'id' => 'srv-1', 'result' => {} }])
  end
end
