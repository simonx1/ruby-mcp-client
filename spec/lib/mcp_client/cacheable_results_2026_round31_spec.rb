# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirty-first review round: the evaluation of the
# host's `request_meta` that a cache decision holds is spent by the request it
# was held for — never by the handshake a reconnect issues first — and every
# transport, HTTP+SSE included, drops the authorization slot it leaves on the
# calling thread when its connection goes away.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 31' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def initialize_result
    { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
      'serverInfo' => { 'name' => 'l', 'version' => '1' } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  # Records the method and the host baggage of every message that goes out.
  # @param legacy [Boolean] whether the server refuses server/discover
  # @return [Array<Array(String, String)>] the wire log
  def stub_recording(legacy: false)
    log = []
    stub_request(:get, url).to_return(status: 405, body: '')
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      log << [body['method'], body.dig('params', '_meta', 'baggage')]
      recorded_response(body, legacy: legacy)
    end
    log
  end

  def recorded_response(body, legacy:)
    case body['method']
    when 'server/discover' then legacy ? { status: 400, body: '' } : json_response(body['id'], discover_result)
    when 'initialize' then json_response(body['id'], initialize_result)
    when 'tools/list' then json_response(body['id'], { 'tools' => [tool('t')], 'ttlMs' => 60_000 })
    else { status: 202, body: '' }
    end
  end

  # A host callable that vends a fresh value every time it is read, so the
  # evaluation one request carries can be told from any other.
  def nonce_meta(server)
    issued = 0
    server.request_meta = lambda {
      issued += 1
      { 'baggage' => "nonce=#{issued}" }
    }
  end

  # @param log [Array<Array(String, String)>] the wire log
  # @param method [String] the JSON-RPC method
  # @return [Integer] the nonce the last message of that method carried
  def last_nonce(log, method)
    entry = log.reverse.find { |sent, _| sent == method }
    raise "no #{method} was sent" unless entry

    Integer(entry.last[/\d+/])
  end

  describe 'the request_meta evaluation a list cache decision holds' do
    # The cache decision reads the host's request_meta and holds that
    # evaluation for the request it leads to. That request reconnects on its
    # way out (`ensure_connected` cleans up and connects first), and the
    # handshake must leave the held evaluation alone: the list carries what
    # the decision weighed, and the handshake reads the host afresh.
    it 'is spent by the list, not by the server/discover of the reconnect it triggers' do
      log = stub_recording
      server = streamable
      nonce_meta(server)

      server.list_tools
      # The session is gone: the next call reconnects in the middle of the
      # very request whose cache decision is holding its evaluation.
      server.instance_variable_set(:@initialized, false)
      server.list_tools

      expect(log.map(&:first)).to eq(['server/discover', 'tools/list', 'server/discover', 'tools/list'])
      expect(last_nonce(log, 'tools/list')).to be < last_nonce(log, 'server/discover')
      expect(log.map(&:last).uniq.size).to eq(log.size)
    ensure
      server&.cleanup
    end

    it 'is spent by the list, not by the initialize handshake of the reconnect' do
      log = stub_recording(legacy: true)
      server = streamable(protocol: :legacy)
      nonce_meta(server)

      server.list_tools
      server.instance_variable_set(:@initialized, false)
      server.list_tools

      expect(log.map(&:first).last(3)).to eq(['initialize', 'notifications/initialized', 'tools/list'])
      expect(last_nonce(log, 'tools/list')).to be < last_nonce(log, 'initialize')
      expect(last_nonce(log, 'tools/list')).to be < last_nonce(log, 'notifications/initialized')
      expect(log.map(&:last).uniq.size).to eq(log.size)
    ensure
      server&.cleanup
    end
  end

  describe 'the thread-local slots a transport owns' do
    def build_transport(kind)
      case kind
      when :streamable then streamable
      when :http then MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      when :sse then MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
      when :stdio then MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1)
      end
    end

    # Leave one entry in every slot this transport records into, through the
    # transport's own bookkeeping rather than by writing the keys directly.
    def fill_thread_slots(server)
      server.send(:note_request_authorization, 'Bearer static') if server.respond_to?(:note_request_authorization, true)
      server.send(:note_request_params, { 'a' => 1 })
      server.send(:mark_round_trip_result, true)
      Thread.current[server.send(:recorded_entries_key)] = { tools: Object.new }
      Thread.current[server.send(:served_entries_key)] = { tools: [Object.new, nil] }
      Thread.current[server.send(:response_received_key)] = 1.0
    end

    %i[streamable http sse stdio].each do |kind|
      it "are all dropped by #{kind}'s cleanup" do
        server = build_transport(kind)
        fill_thread_slots(server)
        expect(server.send(:transport_thread_local_keys).map { |key| Thread.current[key] }).to all(be_truthy)

        server.cleanup

        # Every slot named after this transport, whatever its prefix.
        expect(Thread.current.keys.grep(/_#{server.object_id}\z/)).to be_empty
      end
    end

    it 'include the authorization slot on HTTP+SSE, as on the other HTTP transports' do
      server = build_transport(:sse)
      key = server.send(:request_authorization_key)

      expect(key).to eq(:"mcp_client_request_authorization_#{server.object_id}")
      expect(server.send(:transport_thread_local_keys)).to include(key)
    ensure
      server&.cleanup
    end

    it 'let an anonymous SSE request read as recorded and a torn-down one as unrecorded' do
      server = build_transport(:sse)
      server.send(:note_request_authorization, nil)

      expect(server.send(:request_authorization_recorded?)).to be(true)
      expect(server.send(:request_authorization_context)).to be_nil

      server.cleanup

      expect(server.send(:request_authorization_recorded?)).to be(false)
    end

    it 'do not accumulate on a worker thread that builds and discards SSE transports' do
      leftover = Thread.new do
        3.times do
          server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse')
          server.send(:note_request_authorization, 'Bearer static')
          server.cleanup
        end
        Thread.current.keys.grep(/mcp_client/)
      end.value

      expect(leftover).to be_empty
    end
  end
end
