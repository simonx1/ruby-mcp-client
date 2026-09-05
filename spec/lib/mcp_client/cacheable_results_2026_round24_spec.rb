# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twenty-fourth review round: the freshness probe
# resolves the Authorization a Faraday request would really carry (Faraday's
# header table is case-insensitive, so one spelling of the header survives),
# host middleware that keeps state of its own between requests makes the
# next request's credentials unknowable, and stdio serves a fresh resource
# template list instead of asking again.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 24' do
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

  def oauth_provider(token)
    provider = instance_double(MCPClient::Auth::OAuthProvider)
    allow(provider).to receive(:apply_authorization) do |req|
      req.headers['Authorization'] = "Bearer #{token[:value]}" if token[:value]
    end
    allow(provider).to receive(:respond_to?).and_return(true)
    provider
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

  describe 'the Authorization a request would carry' do
    it 'lets the provider replace a header configured under another spelling' do
      bearers = stub_tools_by_bearer
      token = { value: 'alice' }
      # The configured hash spells the header as a symbol; Faraday's header
      # table is case-insensitive, so the provider's canonical write is the
      # only Authorization the request goes out with.
      server = streamable(headers: { authorization: 'Bearer alice' }, oauth_provider: oauth_provider(token))

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])

      token[:value] = 'bob'

      expect(server.list_tools.map(&:name)).to eq(['bob-tool'])
      expect(bearers).to eq(%w[alice bob])
    end

    it 'resolves the value Faraday would send when the headers hold several spellings' do
      server = streamable(headers: { 'authorization' => 'Bearer lower', 'Authorization' => 'Bearer canonical' })

      expect(server.send(:current_authorization_context, :tools))
        .to eq(Digest::SHA256.hexdigest('Bearer canonical'))
    end

    it 'resolves the same value on HTTP+SSE' do
      server = MCPClient::ServerSSE.new(base_url: 'https://example.com/sse',
                                        headers: { authorization: 'Bearer symbol',
                                                   'Authorization' => 'Bearer canonical' })

      expect(server.send(:current_authorization_context))
        .to eq(Digest::SHA256.hexdigest('Bearer canonical'))
    end
  end

  describe 'host middleware that keeps state between requests' do
    # Rotates its bearer on every tools/list it sends: a freshly built
    # instance keeps predicting the token the live one has already used.
    def rotating_middleware
      Class.new(Faraday::Middleware) do
        def initialize(app)
          super
          @sent = 0
        end

        def on_request(env)
          return unless env.body.to_s.include?('"tools/list"')

          @sent += 1
          env.request_headers['Authorization'] = "Bearer token#{@sent}"
        end
      end
    end

    it 'never serves a private entry when the next request cannot be predicted' do
      bearers = stub_tools_by_bearer
      server = streamable(faraday_config: ->(f) { f.use rotating_middleware })

      expect(server.list_tools.map(&:name)).to eq(['token1-tool'])
      expect(server.list_tools.map(&:name)).to eq(['token2-tool'])
      expect(bearers).to eq(%w[token1 token2])
    end

    it 'reports the unknown context for such a stack' do
      stub_tools_by_bearer
      server = streamable(faraday_config: ->(f) { f.use rotating_middleware })
      server.list_tools

      expect(server.send(:current_authorization_context, :tools))
        .to eq(MCPClient::HttpTransportBase::CacheSupport::UNKNOWN_CONTEXT)
    end

    it "still serves the private entry of Faraday's own middleware with a static bearer" do
      bearers = stub_tools_by_bearer
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', 'alice' })

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(bearers).to eq(['alice'])
    end
  end

  describe 'resource templates on stdio' do
    def templates_result(name)
      { 'resourceTemplates' => [{ 'uriTemplate' => "file:///{#{name}}", 'name' => name }],
        'ttlMs' => 60_000, 'cacheScope' => 'public' }
    end

    def scripted(server, answers)
      %i[ensure_initialized].each { |m| allow(server).to receive(m) }
      calls = 0
      allow(server).to receive(:rpc_request) do |method, _params = {}, **_opts|
        raise "unexpected #{method}" unless method == 'resources/templates/list'

        calls += 1
        answers[calls - 1] || answers.last
      end
      -> { calls }
    end

    it 'serves a fresh template list without asking again' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      calls = scripted(server, [templates_result('one'), templates_result('two')])

      first = server.list_resource_templates
      second = server.list_resource_templates

      expect(first['resourceTemplates'].map(&:name)).to eq(['one'])
      expect(second['resourceTemplates'].map(&:name)).to eq(['one'])
      expect(calls.call).to eq(1)
    end

    it 'still fetches a cursor page' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      calls = scripted(server, [templates_result('one'), templates_result('two')])

      server.list_resource_templates
      expect(server.list_resource_templates(cursor: 'c')['resourceTemplates'].map(&:name)).to eq(['two'])
      expect(calls.call).to eq(2)
    end
  end
end
