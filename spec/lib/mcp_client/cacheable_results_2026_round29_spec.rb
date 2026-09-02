# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 caching, twenty-ninth review round: the freshness probe never
# runs host middleware at all — it answers from what the transport itself
# knows (its configured headers and its OAuth provider), and a faraday_config
# block that installs anything but pure framework middleware makes the context
# unknown — `baggage` is application context that a cached result may depend
# on, a cache decision that leads to a request keeps the metadata it held for
# it, and an invalidated template list is really dropped.
RSpec.describe 'MCP 2026-07-28 cacheable results — round 29' do
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

  # The nonce lives in a constant of the middleware class: nothing about the
  # class, its instances or its constructor arguments betrays it.
  def constant_nonce_middleware
    Class.new(Faraday::Middleware) do
      const_set(:STORE, { used: 0 })

      def on_request(env)
        return unless env.body.to_s.include?('"tools/list"')

        store = self.class.const_get(:STORE)
        store[:used] += 1
        env.request_headers['Authorization'] = "Bearer nonce#{store[:used]}"
      end
    end
  end

  # The same rotation, reached through an included module rather than the
  # middleware class itself.
  def included_nonce_middleware
    hook = Module.new do
      const_set(:STORE, { used: 0 })

      def on_request(env)
        return unless env.body.to_s.include?('"tools/list"')

        store = self.class.ancestors.find { |m| m.const_defined?(:STORE, false) }.const_get(:STORE)
        store[:used] += 1
        env.request_headers['Authorization'] = "Bearer nonce#{store[:used]}"
      end
    end
    [Class.new(Faraday::Middleware) { include hook }, hook.const_get(:STORE)]
  end

  # The rotation lives on the thread, which a fresh copy of the middleware
  # shares with the instance Faraday calls.
  def thread_nonce_middleware(key)
    Class.new(Faraday::Middleware) do
      define_method(:thread_key) { key }

      def on_request(env)
        return unless env.body.to_s.include?('"tools/list"')

        Thread.current[thread_key] = Thread.current[thread_key].to_i + 1
        env.request_headers['Authorization'] = "Bearer nonce#{Thread.current[thread_key]}"
      end
    end
  end

  describe 'a probe against host middleware that rotates a credential it does not hold' do
    it 'reports the unknown context instead of spending a nonce kept in a constant' do
      stub_tools_by_bearer
      middleware = constant_nonce_middleware
      store = middleware.const_get(:STORE)
      server = streamable(faraday_config: ->(f) { f.use middleware })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(store[:used]).to eq(1)
    end

    it 'never skips the one-time credential of the next real request' do
      bearers = stub_tools_by_bearer
      middleware = constant_nonce_middleware
      store = middleware.const_get(:STORE)
      server = streamable(faraday_config: ->(f) { f.use middleware })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(store[:used]).to eq(2)
    end

    it 'reports the unknown context for a nonce an included module keeps' do
      bearers = stub_tools_by_bearer
      middleware, store = included_nonce_middleware
      server = streamable(faraday_config: ->(f) { f.use middleware })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(store[:used]).to eq(2)
    end

    it 'reports the unknown context for a nonce kept on the thread' do
      bearers = stub_tools_by_bearer
      key = :"mcp_round29_nonce_#{object_id}"
      server = streamable(faraday_config: ->(f) { f.use thread_nonce_middleware(key) })

      expect(server.list_tools.map(&:name)).to eq(['nonce1-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(bearers).to eq(%w[nonce1 nonce2])
      expect(Thread.current[key]).to eq(2)
    ensure
      Thread.current[key] = nil
    end

    it 'is never run even when it could only read an immutable holder' do
      bearers = stub_tools_by_bearer
      runs = 0
      readonly = Class.new(Faraday::Middleware) do
        define_method(:on_request) do |env|
          runs += 1
          env.request_headers['Authorization'] = 'Bearer alice'
        end
      end
      server = streamable(faraday_config: ->(f) { f.use readonly })

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(bearers).to eq(%w[alice alice])
      # The probe made no run of its own: only the three real requests
      # (the discovery and the two tool lists) did.
      expect(runs).to eq(3)
    end
  end

  describe 'a probe against a stack the transport can answer for by itself' do
    it 'serves the private entry of a statically configured bearer' do
      bearers = stub_tools_by_bearer
      server = streamable(headers: { 'Authorization' => 'Bearer alice' })

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(bearers).to eq(['alice'])
      expect(server.send(:current_authorization_context, :tools)).not_to eq(unknown_context)
    end

    it "serves the private entry of Faraday's own middleware with a static bearer" do
      bearers = stub_tools_by_bearer
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', 'alice' })

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(bearers).to eq(['alice'])
      expect(server.send(:current_authorization_context, :tools)).not_to eq(unknown_context)
    end

    it 'reports the unknown context when that middleware was given a callable' do
      bearers = stub_tools_by_bearer
      spent = 0
      vend = lambda {
        spent += 1
        "nonce#{spent}"
      }
      server = streamable(faraday_config: ->(f) { f.request :authorization, 'Bearer', vend })

      # The discovery carried the first nonce, the tool list the second.
      expect(server.list_tools.map(&:name)).to eq(['nonce2-tool'])
      expect(server.send(:current_authorization_context, :tools)).to eq(unknown_context)
      expect(spent).to eq(2)
      expect(server.list_tools.map(&:name)).to eq(['nonce3-tool'])
      # Every nonce the host vended went out on a real request.
      expect(bearers).to eq(%w[nonce2 nonce3])
      expect(spent).to eq(3)
    end

    it 'leaves a response-only middleware alone and still serves the private entry' do
      bearers = stub_tools_by_bearer
      server = streamable(headers: { 'Authorization' => 'Bearer alice' },
                          faraday_config: ->(f) { f.response :logger, Logger.new(File::NULL) })

      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(server.list_tools.map(&:name)).to eq(['alice-tool'])
      expect(bearers).to eq(['alice'])
    end
  end

  describe 'the application context a request carries in its baggage' do
    it 'does not let one baggage serve a private list cached under another' do
      counts = Hash.new(0)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'tools/list'
          counts[:tools] += 1
          tenant = body.dig('params', '_meta', 'baggage').to_s.sub('tenant=', '')
          json_response(body['id'],
                        { 'tools' => [tool("#{tenant}-tool")], 'ttlMs' => 60_000, 'cacheScope' => 'private' })
        else
          json_response(body['id'], discover_result)
        end
      end
      server = streamable
      server.request_meta = { 'baggage' => 'tenant=a' }
      expect(server.list_tools.map(&:name)).to eq(['a-tool'])
      expect(server.list_tools.map(&:name)).to eq(['a-tool'])
      expect(counts[:tools]).to eq(1)

      server.request_meta = { 'baggage' => 'tenant=b' }
      expect(server.list_tools.map(&:name)).to eq(['b-tool'])
      expect(counts[:tools]).to eq(2)
    ensure
      server&.cleanup
    end
  end

  describe 'a cache decision that finds its entry stale' do
    it 'keeps the metadata it held for the request the decision leads to' do
      sent = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << body.dig('params', '_meta', 'traceparent')
        json_response(body['id'],
                      if body['method'] == 'tools/list'
                        { 'tools' => [tool('t')], 'ttlMs' => 1 }
                      else
                        discover_result
                      end)
      end
      spent = 0
      server = streamable
      # The tenant keeps the entry's parameters matching; the trace id
      # rotates and is carried by whichever request goes out.
      server.request_meta = lambda {
        spent += 1
        { 'tenant' => 'a', 'traceparent' => "t#{spent}" }
      }

      server.list_tools
      allow(server).to(receive(:monotonic_now).and_wrap_original { |method| method.call + 3600 })
      server.list_tools

      # Every evaluation of the host's callable went out on the wire: the
      # freshness check that found the entry stale kept the one it had read
      # for the request it was about to make.
      expect(sent).to eq((1..spent).map { |i| "t#{i}" })
    ensure
      server&.cleanup
    end
  end

  describe 'a template list a resources/list_changed notification invalidates' do
    def stub_templates
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'resources/templates/list'
          json_response(body['id'],
                        { 'resourceTemplates' => [{ 'uriTemplate' => 'file:///{p}', 'name' => 'one' }],
                          'ttlMs' => 60_000 })
        else
          json_response(body['id'], discover_result)
        end
      end
    end

    it 'lets go of the list the transport was holding' do
      stub_templates
      server = streamable
      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['one'])
      expect(server.instance_variable_get(:@templates_result)).not_to be_nil

      server.send(:invalidate_cache_for_notification, 'notifications/resources/list_changed')

      expect(server.instance_variable_get(:@templates_result)).to be_nil
    ensure
      server&.cleanup
    end

    it 'lets go of it when the connection is torn down' do
      stub_templates
      server = streamable
      expect(server.list_resource_templates['resourceTemplates'].map(&:name)).to eq(['one'])

      server.cleanup

      expect(server.instance_variable_get(:@templates_result)).to be_nil
    end
  end
end
