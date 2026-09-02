# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twenty-eighth review round: the freshness probe only
# runs middleware whose request hook is provably inert — a hook that can reach
# state its class keeps, or state a block closed over, is never run, so the
# one-time credentials it vends are spent on real requests alone — and a stdio
# template list is served from the transport cache only when the server itself
# bounded it.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 28' do
  let(:url) { 'https://example.com/mcp' }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def streamable(**opts)
    MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0, **opts)
  end

  # Answers tools/list with a private list named after the bearer the
  # request carried, and records those bearers.
  def stub_tools_by_bearer
    bearers = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      if body['method'] == 'tools/list'
        bearer = request.headers['Authorization'].to_s.sub(/\ABearer /, '')
        bearers << bearer
        json_response(body['id'],
                      { 'tools' => [tool("#{bearer}-tool")], 'ttlMs' => 60_000, 'cacheScope' => 'private' })
      else
        json_response(body['id'], discover_result)
      end
    end
    bearers
  end

  def unknown_context
    MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT
  end

  describe 'a probe against middleware whose class vends the one-time bearer' do
    # Takes no arguments at all: everything it rotates lives on the class,
    # which a freshly built copy shares with the instance Faraday calls.
    def class_nonce_middleware
      Class.new(Faraday::Middleware) do
        @used = 0

        class << self
          attr_reader :used

          def next_nonce
            @used += 1
            "nonce#{@used}"
          end
        end

        def on_request(env)
          return unless env.body.to_s.include?('"tools/list"')

          env.request_headers['Authorization'] = "Bearer #{self.class.next_nonce}"
        end
      end
    end

    it 'reports the unknown context instead of spending a class-held nonce' do
      stub_tools_by_bearer
      middleware = class_nonce_middleware
      server = streamable(faraday_config: ->(f) { f.use middleware })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(middleware.used).to eq(1)
    end

    it 'never skips the one-time credential of the next real request' do
      bearers = stub_tools_by_bearer
      middleware = class_nonce_middleware
      server = streamable(faraday_config: ->(f) { f.use middleware })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(middleware.used).to eq(2)
    end
  end

  describe 'a probe against a request hook that closed over the counter' do
    # `define_method` keeps the binding it was defined in: the counter is
    # reachable from every instance, and no comparison of two instances or
    # of their constructor arguments can see it.
    def closure_nonce_middleware(counter)
      Class.new(Faraday::Middleware) do
        define_method(:on_request) do |env|
          next unless env.body.to_s.include?('"tools/list"')

          counter[:used] += 1
          env.request_headers['Authorization'] = "Bearer nonce#{counter[:used]}"
        end
      end
    end

    it 'reports the unknown context instead of spending a closed-over nonce' do
      stub_tools_by_bearer
      counter = { used: 0 }
      server = streamable(faraday_config: ->(f) { f.use closure_nonce_middleware(counter) })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(counter[:used]).to eq(1)
    end

    it 'never skips the one-time credential of the next real request' do
      bearers = stub_tools_by_bearer
      counter = { used: 0 }
      server = streamable(faraday_config: ->(f) { f.use closure_nonce_middleware(counter) })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(counter[:used]).to eq(2)
    end
  end

  describe 'a probe against middleware that keeps nothing of its own' do
    it "still serves the private entry of Faraday's own middleware with a static bearer" do
      bearers = stub_tools_by_bearer
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', 'alice' })

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(bearers).to eq(['alice'])
      expect(server.send(:current_authorization_context, :tools)).not_to eq(unknown_context)
    end
  end

  describe 'a stdio template list a server put no freshness hint on' do
    def stdio_templates(result)
      server = MCPClient::ServerStdio.new(command: 'echo test')
      allow(server).to receive(:ensure_initialized)
      calls = 0
      allow(server).to receive(:rpc_request) do |method, _params = {}, **_opts|
        raise "unexpected #{method}" unless method == 'resources/templates/list'

        calls += 1
        result
      end
      [server, -> { calls }]
    end

    def template(name)
      { 'uriTemplate' => "file:///{#{name}}", 'name' => name }
    end

    it 'asks a legacy server again for an empty template list' do
      server, calls = stdio_templates({ 'resourceTemplates' => [] })

      expect(server.list_resource_templates['resourceTemplates']).to eq([])
      expect(server.list_resource_templates['resourceTemplates']).to eq([])
      expect(calls.call).to eq(2)
    end

    it 'asks a legacy server again for a non-empty template list' do
      server, calls = stdio_templates({ 'resourceTemplates' => [template('one')] })

      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['one'])
      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['one'])
      expect(calls.call).to eq(2)
    end

    it 'still serves a template list a 2026 server bounded with a positive ttlMs' do
      server, calls = stdio_templates({ 'resourceTemplates' => [template('one')], 'ttlMs' => 60_000,
                                        'cacheScope' => 'public' })

      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['one'])
      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['one'])
      expect(calls.call).to eq(1)
    end
  end
  describe 'a client cache hit that reads what the next request would carry' do
    def client_over(server, request_meta)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'streamable_http', base_url: 'https://example.com', endpoint: '/mcp' }],
        request_meta: request_meta
      )
    end

    it 'evaluates the host metadata once for the whole decision' do
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << body.dig('params', '_meta', 'traceparent')
        json_response(body['id'],
                      if body['method'] == 'tools/list'
                        { 'tools' => [tool('t')], 'ttlMs' => 60_000 }
                      else
                        discover_result
                      end)
      end
      spent = 0
      client = client_over(streamable, lambda {
        spent += 1
        { 'tenant' => 'a', 'traceparent' => "t#{spent}" }
      })

      client.list_tools
      before = spent

      client.list_tools

      # The hit sends nothing and reads the host's callable once for the
      # whole decision: the freshness check reuses what reading the
      # parameters of the next request already evaluated.
      expect(sent).to eq(%w[t1 t2])
      expect(spent - before).to eq(1)
    ensure
      client&.cleanup
    end

    it 'leaves no per-transport slot on the thread once the slice is tagged' do
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        json_response(body['id'],
                      body['method'] == 'tools/list' ? { 'tools' => [tool('t')], 'ttlMs' => 60_000 } : discover_result)
      end
      server = streamable
      client = client_over(server, nil)

      client.list_tools

      expect(Thread.current[:"mcp_client_served_entries_#{server.object_id}"]).to be_nil
    ensure
      client&.cleanup
    end

    it 'forgets the slot of a transport that is cleaned up' do
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        json_response(body['id'],
                      body['method'] == 'tools/list' ? { 'tools' => [tool('t')], 'ttlMs' => 60_000 } : discover_result)
      end
      server = streamable
      server.list_tools

      expect(Thread.current[:"mcp_client_served_entries_#{server.object_id}"]).not_to be_nil

      server.cleanup

      expect(Thread.current[:"mcp_client_served_entries_#{server.object_id}"]).to be_nil
    end
  end

  describe 'an SSE chunk carrying a notification before a response' do
    it 'dates the response from the arrival of the chunk, not from the callback' do
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/mcp')
      clock = 0.0
      allow(server).to receive(:monotonic_now) { clock }
      # A host callback that takes a while: the response bytes were already
      # in hand when it started, so its duration is not the response's age.
      server.on_notification { |_method, _params| clock += 100.0 }
      server.instance_variable_get(:@pending_request_ids) << 1
      chunk = +''
      chunk << "event: message\ndata: " \
               "#{JSON.generate('jsonrpc' => '2.0', 'method' => 'notifications/message', 'params' => {})}\n\n"
      chunk << "event: message\ndata: #{JSON.generate('jsonrpc' => '2.0', 'id' => 1, 'result' => { 'ok' => true })}\n\n"

      server.send(:process_sse_chunk, chunk)

      expect(server.instance_variable_get(:@sse_result_arrivals)[1]).to eq(0.0)
    ensure
      server&.cleanup
    end
  end
end
