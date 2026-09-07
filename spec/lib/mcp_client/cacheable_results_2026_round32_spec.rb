# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, thirty-second review round: a freshness check that
# aborts on one server lets go of the metadata every server was holding, a
# post-call re-resolve reads the definition the call went out under instead of
# listing again, and a transport's cleanup drops its thread-local slots after
# the session-termination request rather than before it.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 32' do
  def json_response(id, result, headers = {})
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' }.merge(headers) }
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  def tool(name, extra = {})
    { 'name' => name, 'description' => name, 'inputSchema' => { 'type' => 'object' } }.merge(extra)
  end

  def streamable(host: 'example.com', **opts)
    MCPClient::ServerStreamableHTTP.new(base_url: "https://#{host}", endpoint: '/mcp', retries: 0, **opts)
  end

  def client_for(*servers, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(*servers)
    MCPClient::Client.new(mcp_server_configs: servers.map { { type: 'stdio', command: 'echo test' } }, **opts)
  end

  describe 'a freshness check that aborts on a later server' do
    let(:a_url) { 'https://a.example.com/mcp' }
    let(:b_url) { 'https://b.example.com/mcp' }

    # Answers a modern handshake, a bounded tools/list and ping, recording the
    # trace identifier every request carried.
    def stub_host(url, name, scope)
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << body.dig('params', '_meta', 'traceparent')
        result = case body['method']
                 when 'tools/list'
                   { 'tools' => [tool("#{name}-tool")], 'ttlMs' => 60_000, 'cacheScope' => scope }
                 when 'ping' then {}
                 else discover_result
                 end
        json_response(body['id'], result)
      end
      sent
    end

    # An OAuth provider whose token refresh fails while `refusing` says so.
    def refusing_provider(refusing)
      provider_class = Class.new do
        def initialize(&block)
          @block = block
        end

        def apply_authorization(request)
          @block.call(request)
        end
      end
      provider_class.new do |request|
        raise MCPClient::Errors::ConnectionError, 'token refresh failed' if refusing[:now]

        request.headers['Authorization'] = 'Bearer b'
      end
    end

    it 'lets go of the metadata an earlier server was holding' do
      a_sent = stub_host(a_url, 'a', 'public')
      stub_host(b_url, 'b', 'private')
      refusing = { now: false }
      server_a = streamable(host: 'a.example.com')
      server_b = streamable(host: 'b.example.com', oauth_provider: refusing_provider(refusing))

      # The tenant is what the cached list is bound to and never changes;
      # the trace identifier is fresh for every request, which is exactly
      # what a leaked evaluation would send twice.
      evaluated = []
      recording = nil
      server_a.request_meta = lambda do
        value = "00-trace#{evaluated.size + 1}"
        evaluated << value
        recording&.<<(value)
        { 'baggage' => 'tenant=acme', 'traceparent' => value }
      end
      client = client_for(server_a, server_b)
      expect(client.list_tools.map(&:name)).to contain_exactly('a-tool', 'b-tool')

      # The first server's slice is still fresh (its evaluation is held for
      # the fetch the check is deciding on); the second server's probe then
      # fails its token refresh, so no fetch follows for either of them.
      refusing[:now] = true
      recording = []
      expect { client.list_tools }.to raise_error(MCPClient::Errors::ConnectionError)
      aborted = recording
      recording = nil

      expect(aborted).not_to be_empty
      expect(Thread.current[server_a.send(:held_request_meta_key)]).to be_nil

      # The next request on this thread reads the host afresh instead of
      # carrying the tenant/nonce the aborted decision evaluated.
      refusing[:now] = false
      server_a.ping
      expect(a_sent.last).to eq(evaluated.last)
      expect(aborted).not_to include(a_sent.last)
    ensure
      server_a&.cleanup
      server_b&.cleanup
    end
  end

  describe 'the tool definition a post-call re-resolve validates against' do
    let(:url) { 'https://example.com/mcp' }

    def greet(output_required)
      tool('greet',
           'outputSchema' => { 'type' => 'object', 'properties' => { output_required => { 'type' => 'string' } },
                               'required' => [output_required] })
    end

    # tools/list answers from `definitions` in order (the last one repeats),
    # always with `ttlMs: 0`, so every access re-fetches. Returns the counter
    # of tools/list requests actually made.
    def stub_tool_versions(definitions)
      listed = { count: 0 }
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        result = case body['method']
                 when 'tools/list'
                   listed[:count] += 1
                   listing = definitions[[listed[:count] - 1, definitions.size - 1].min]
                   { 'tools' => listing.is_a?(Array) ? listing : [listing], 'ttlMs' => 0 }
                 when 'tools/call'
                   { 'content' => [{ 'type' => 'text', 'text' => 'hi' }],
                     'structuredContent' => { 'greeting' => 'hi' } }
                 else discover_result
                 end
        json_response(body['id'], result)
      end
      listed
    end

    it 'is the one the wire request went out under, not a newer re-fetch' do
      # The header derivation re-fetches mid-call and gets the definition the
      # call is answered under; a third fetch afterwards would validate the
      # result against a definition the call never carried.
      listed = stub_tool_versions([tool('greet'), greet('greeting'), greet('farewell')])
      server = streamable
      client = client_for(server, validate_structured_content: :strict)

      result = client.call_tool('greet', {})

      expect(result['structuredContent']).to eq({ 'greeting' => 'hi' })
      expect(listed[:count]).to eq(2)
    ensure
      server&.cleanup
    end

    it 'keeps the definition the call was made with when the list dropped the tool' do
      listed = stub_tool_versions([tool('greet'), []])
      server = streamable
      client = client_for(server, validate_structured_content: :strict)

      expect(client.call_tool('greet', {})['structuredContent']).to eq({ 'greeting' => 'hi' })
      expect(listed[:count]).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe "a cleanup that terminates the transport's session" do
    let(:base_url) { 'https://example.com' }
    let(:url) { 'https://example.com/mcp' }
    let(:session_id) { 'session_abc123' }

    # A legacy handshake that hands out a session id, so cleanup sends the
    # DELETE that terminates it.
    def stub_session
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          json_response(body['id'],
                        { 'protocolVersion' => '2025-06-18', 'capabilities' => { 'tools' => {} },
                          'serverInfo' => { 'name' => 'test', 'version' => '1.0' } },
                        { 'Mcp-Session-Id' => session_id })
        when 'notifications/initialized' then { status: 202, body: '' }
        else json_response(body['id'], { 'tools' => [] })
        end
      end
      stub_request(:delete, url).to_return(status: 200, body: '')
    end

    shared_examples 'a transport that forgets its thread state after terminating' do
      it 'leaves no authorization fingerprint behind for the worker thread' do
        stub_session
        server.list_tools

        server.cleanup

        expect(a_request(:delete, url)).to have_been_made
        expect(Thread.current[server.send(:request_authorization_key)]).to be_nil
        expect(server.send(:request_authorization_recorded?)).to be(false)
      end
    end

    context 'with the plain HTTP transport' do
      subject(:server) do
        MCPClient::ServerHTTP.new(base_url: base_url, endpoint: '/mcp', retries: 0, protocol: :legacy,
                                  headers: { 'Authorization' => 'Bearer static' })
      end

      it_behaves_like 'a transport that forgets its thread state after terminating'
    end

    context 'with the Streamable HTTP transport' do
      subject(:server) do
        MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: '/mcp', retries: 0, protocol: :legacy,
                                            headers: { 'Authorization' => 'Bearer static' })
      end

      it_behaves_like 'a transport that forgets its thread state after terminating'
    end
  end
end
