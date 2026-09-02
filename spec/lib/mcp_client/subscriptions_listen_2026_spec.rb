# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 Subscriptions (basic/patterns/subscriptions): a
# subscriptions/listen request opens a long-lived notification stream for
# the notification types the client opted in to. The server acknowledges
# first (notifications/subscriptions/acknowledged), tags every notification
# with io.modelcontextprotocol/subscriptionId (the listen request's id),
# ends a subscription gracefully with a response to the listen request or
# with notifications/cancelled, and the client cancels by closing the
# stream (HTTP) or sending notifications/cancelled (stdio). It replaces
# resources/subscribe and the HTTP GET stream.
SUB_ID_META = 'io.modelcontextprotocol/subscriptionId'

RSpec.describe 'MCP 2026-07-28 subscriptions/listen' do
  def discover_result(capabilities: { 'tools' => { 'listChanged' => true },
                                      'resources' => { 'subscribe' => true, 'listChanged' => true } })
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => capabilities }
  end

  def line(message)
    "#{JSON.generate(message)}\n"
  end

  # Listener callbacks run on the subscription's own dispatcher thread, off
  # the transport's reader.
  def wait_for(timeout = 2)
    deadline = Time.now + timeout
    sleep 0.002 until yield || Time.now > deadline
    raise 'condition not met in time' unless yield
  end

  # Acknowledge each listen as it goes out, the way the reader thread does on
  # a live session: subscribe_resource waits for that answer.
  def acknowledge_on_listen(server)
    allow(server).to receive(:open_subscription).and_wrap_original do |original, subscription|
      original.call(subscription)
      server.handle_line(line('jsonrpc' => '2.0', 'method' => 'notifications/subscriptions/acknowledged',
                              'params' => { '_meta' => { SUB_ID_META => subscription.id },
                                            'notifications' => subscription.requested }))
    end
  end

  describe 'on stdio' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }

    # A modern stdio session whose writes are captured and whose reads are
    # driven by hand through handle_line.
    before do
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      server.instance_variable_set(:@stdin, double('stdin', flush: nil, closed?: true, close: nil).tap do |d|
        allow(d).to receive(:puts) { |l| written << JSON.parse(l) }
      end)
      allow(server).to receive(:send_request) { |req| written << req }
      probe = { 'result' => discover_result }
      allow(server).to receive(:wait_response) { |id, **_o| probe.merge('jsonrpc' => '2.0', 'id' => id) }
    end

    it 'sends subscriptions/listen with the normalized filter and returns a pending subscription' do
      subscription = server.listen(notifications: { tools_list_changed: true,
                                                    resource_subscriptions: ['file:///a'] })

      request = written.find { |m| m['method'] == 'subscriptions/listen' }
      expect(request['params']['notifications']).to eq({ 'toolsListChanged' => true,
                                                         'resourceSubscriptions' => ['file:///a'] })
      expect(request['params']['_meta']['io.modelcontextprotocol/protocolVersion']).to eq('2026-07-28')
      expect(subscription).to be_a(MCPClient::Subscription)
      expect(subscription.id).to eq(request['id'])
      expect(subscription.requested).to eq({ 'toolsListChanged' => true, 'resourceSubscriptions' => ['file:///a'] })
      expect(subscription.state).to eq(:pending)
      expect(subscription.server).to equal(server)
    end

    it 'rejects an unknown filter key' do
      expect { server.listen(notifications: { bogus: true }) }.to raise_error(ArgumentError, /bogus/)
    end

    it 'records the acknowledged subset and becomes active' do
      subscription = server.listen(notifications: { tools_list_changed: true, prompts_list_changed: true })

      server.handle_line(line('jsonrpc' => '2.0', 'method' => 'notifications/subscriptions/acknowledged',
                              'params' => { '_meta' => { SUB_ID_META => subscription.id },
                                            'notifications' => { 'toolsListChanged' => true } }))

      expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })
      expect(subscription.state).to eq(:active)
      expect(subscription).to be_active
      expect(subscription.unsupported).to eq(['promptsListChanged'])
    end

    it 'demultiplexes notifications to the subscription they belong to and to the general listener' do
      general = []
      server.on_notification { |method, params| general << [method, params] }
      received_a = []
      received_b = []
      sub_a = server.listen(notifications: { tools_list_changed: true }) { |m, p| received_a << [m, p] }
      sub_b = server.listen(notifications: { resources_list_changed: true }) { |m, p| received_b << [m, p] }

      server.handle_line(line('jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                              'params' => { '_meta' => { SUB_ID_META => sub_a.id } }))
      server.handle_line(line('jsonrpc' => '2.0', 'method' => 'notifications/resources/list_changed',
                              'params' => { '_meta' => { SUB_ID_META => sub_b.id } }))
      wait_for { received_a.any? && received_b.any? }

      expect(received_a.map(&:first)).to eq(['notifications/tools/list_changed'])
      expect(received_b.map(&:first)).to eq(['notifications/resources/list_changed'])
      expect(general.map(&:first)).to eq(%w[notifications/tools/list_changed notifications/resources/list_changed])
    end

    it 'treats a response to the listen request as a graceful closure' do
      subscription = server.listen(notifications: { tools_list_changed: true })

      closing = { 'resultType' => 'complete', '_meta' => { SUB_ID_META => subscription.id } }
      server.handle_line(line('jsonrpc' => '2.0', 'id' => subscription.id, 'result' => closing))

      expect(subscription.state).to eq(:closed)
      expect(subscription).to be_closed_gracefully
      expect(subscription).not_to be_active
      expect(server.instance_variable_get(:@pending)).to be_empty
    end

    it 'treats an error response to the listen request as a failed subscription' do
      subscription = server.listen(notifications: { tools_list_changed: true })

      server.handle_line(line('jsonrpc' => '2.0', 'id' => subscription.id,
                              'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                                           'data' => { 'requiredCapabilities' => {} } }))

      expect(subscription.state).to eq(:closed)
      expect(subscription).not_to be_closed_gracefully
      expect(subscription.error).to be_a(MCPClient::Errors::MissingRequiredClientCapabilityError)
    end

    it 'treats a server notifications/cancelled for the listen id as a teardown' do
      subscription = server.listen(notifications: { tools_list_changed: true })

      server.handle_line(line('jsonrpc' => '2.0', 'method' => 'notifications/cancelled',
                              'params' => { 'requestId' => subscription.id, 'reason' => 'shutting down' }))

      expect(subscription.state).to eq(:closed)
      expect(subscription).not_to be_closed_gracefully
    end

    it 'cancels with notifications/cancelled on close and ignores later notifications for that id' do
      received = []
      subscription = server.listen(notifications: { tools_list_changed: true }) { |m, _p| received << m }

      subscription.close

      cancelled = written.find { |m| m['method'] == 'notifications/cancelled' }
      expect(cancelled['params']['requestId']).to eq(subscription.id)
      expect(subscription.state).to eq(:closed)
      server.handle_line(line('jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                              'params' => { '_meta' => { SUB_ID_META => subscription.id } }))
      expect(received).to be_empty
      expect(subscription.close).to be_nil
    end

    it 'delivers a notification without a subscriptionId to the general listener only' do
      general = []
      server.on_notification { |method, _params| general << method }
      received = []
      server.listen(notifications: { tools_list_changed: true }) { |m, _p| received << m }

      server.handle_line(line('jsonrpc' => '2.0', 'method' => 'notifications/progress',
                              'params' => { 'progressToken' => 'p', 'progress' => 1 }))

      expect(general).to eq(['notifications/progress'])
      expect(received).to be_empty
    end

    it 'maps subscribe_resource/unsubscribe_resource onto a listen stream per URI' do
      acknowledge_on_listen(server)
      server.subscribe_resource('file:///a')

      request = written.find { |m| m['method'] == 'subscriptions/listen' }
      expect(request['params']['notifications']).to eq({ 'resourceSubscriptions' => ['file:///a'] })
      expect(written.map { |m| m['method'] }).not_to include('resources/subscribe')

      server.unsubscribe_resource('file:///a')

      cancelled = written.find { |m| m['method'] == 'notifications/cancelled' }
      expect(cancelled['params']['requestId']).to eq(request['id'])
      expect(written.map { |m| m['method'] }).not_to include('resources/unsubscribe')
    end

    it 'gates resource subscriptions on the resources.subscribe capability' do
      allow(server).to receive(:wait_response) do |id, **_o|
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => discover_result(capabilities: { 'resources' => {} }) }
      end

      expect { server.subscribe_resource('file:///a') }.to raise_error(MCPClient::Errors::CapabilityError)
    end

    it 're-sends live subscriptions with a new id after the process is re-established' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      first_id = subscription.id

      server.cleanup
      expect(subscription.state).to eq(:reconnecting)
      server.ping

      listens = written.select { |m| m['method'] == 'subscriptions/listen' }
      expect(listens.size).to eq(2)
      expect(listens.last['params']['notifications']).to eq({ 'toolsListChanged' => true })
      expect(subscription.id).to eq(listens.last['id'])
      expect(subscription.id).not_to eq(first_id)
      expect(subscription.state).to eq(:pending)
    end

    it 'does not re-send subscriptions the host closed' do
      subscription = server.listen(notifications: { tools_list_changed: true })
      subscription.close
      server.cleanup
      server.ping

      expect(written.count { |m| m['method'] == 'subscriptions/listen' }).to eq(1)
    end
  end

  describe 'on a legacy server' do
    it 'refuses subscriptions/listen and keeps resources/subscribe' do
      server = MCPClient::ServerStdio.new(command: 'echo test', protocol: :legacy)
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server.instance_variable_set(:@capabilities, { 'resources' => { 'subscribe' => true } })
      server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
      sent = []
      allow(server).to receive(:send_request) { |req| sent << req }
      allow(server).to receive(:wait_response) { |id, **_o| { 'jsonrpc' => '2.0', 'id' => id, 'result' => {} } }

      expect { server.listen(notifications: { tools_list_changed: true }) }
        .to raise_error(MCPClient::Errors::CapabilityError, /2026-07-28/)
      server.subscribe_resource('file:///a')
      expect(sent.last['method']).to eq('resources/subscribe')
    end
  end

  describe 'on Streamable HTTP' do
    let(:url) { 'https://example.com/mcp' }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                          read_timeout: 2)
    end

    after { server.cleanup }

    def sse(*messages)
      messages.map { |m| m.is_a?(String) ? m : "event: message\ndata: #{JSON.generate(m)}\n\n" }.join
    end

    def ack(id, filter)
      { 'jsonrpc' => '2.0', 'method' => 'notifications/subscriptions/acknowledged',
        'params' => { '_meta' => { SUB_ID_META => id }, 'notifications' => filter } }
    end

    def stub_server(listen_bodies)
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << { headers: request.headers, body: body }
        case body['method']
        when 'server/discover'
          { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result),
            headers: { 'Content-Type' => 'application/json' } }
        when 'subscriptions/listen'
          builder = listen_bodies.shift or raise 'no more listen bodies'
          { status: 200, body: builder.call(body['id']), headers: { 'Content-Type' => 'text/event-stream' } }
        else
          { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'tools' => [] }),
            headers: { 'Content-Type' => 'application/json' } }
        end
      end
      requests
    end

    def wait_until(timeout = 2)
      deadline = Time.now + timeout
      sleep 0.01 until yield || Time.now > deadline
      raise 'condition not met in time' unless yield
    end

    it 'POSTs subscriptions/listen, receives the acknowledgment and notifications on the response stream' do
      received = []
      requests = stub_server([
                               lambda do |id|
                                 sse(":\r\n\r\n", ack(id, { 'toolsListChanged' => true }),
                                     ': keep-alive',
                                     { 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                                       'params' => { '_meta' => { SUB_ID_META => id } } },
                                     { 'jsonrpc' => '2.0', 'id' => id,
                                       'result' => { 'resultType' => 'complete', '_meta' => { SUB_ID_META => id } } })
                               end
                             ])

      subscription = server.listen(notifications: { tools_list_changed: true }) { |m, _p| received << m }
      wait_until { subscription.state == :closed }
      wait_until { received.any? }

      listen = requests.find { |r| r[:body]['method'] == 'subscriptions/listen' }
      expect(listen[:headers]['Mcp-Method']).to eq('subscriptions/listen')
      expect(listen[:headers]['Accept']).to include('text/event-stream')
      expect(listen[:body]['params']['notifications']).to eq({ 'toolsListChanged' => true })
      expect(subscription.acknowledged).to eq({ 'toolsListChanged' => true })
      expect(received).to eq(['notifications/tools/list_changed'])
      expect(subscription).to be_closed_gracefully
      expect(requests.count { |r| r[:body]['method'] == 'subscriptions/listen' }).to eq(1)
    end

    it 'reconnects after an abrupt stream end, until the server closes gracefully' do
      requests = stub_server([
                               ->(id) { sse(ack(id, { 'toolsListChanged' => true })) },
                               lambda do |id|
                                 sse(ack(id, { 'toolsListChanged' => true }),
                                     { 'jsonrpc' => '2.0', 'id' => id,
                                       'result' => { 'resultType' => 'complete', '_meta' => { SUB_ID_META => id } } })
                               end
                             ])
      stub_const('MCPClient::HttpTransportBase::LISTEN_RECONNECT_DELAY', 0.01)

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.state == :closed }

      listens = requests.select { |r| r[:body]['method'] == 'subscriptions/listen' }
      expect(listens.size).to eq(2)
      expect(listens[0][:body]['id']).not_to eq(listens[1][:body]['id'])
      expect(subscription.id).to eq(listens[1][:body]['id'])
      expect(subscription).to be_closed_gracefully
    end

    it 'closes the stream to cancel and does not reconnect' do
      requests = stub_server([->(id) { sse(ack(id, { 'toolsListChanged' => true })) }])
      stub_const('MCPClient::HttpTransportBase::LISTEN_RECONNECT_DELAY', 0.5)

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.acknowledged }
      subscription.close
      sleep 0.7

      expect(subscription.state).to eq(:closed)
      expect(requests.count { |r| r[:body]['method'] == 'subscriptions/listen' }).to eq(1)
      expect(requests.map { |r| r[:body]['method'] }).not_to include('notifications/cancelled')
    end

    it 'fails the subscription when the listen request is rejected' do
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'server/discover'
          { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result),
            headers: { 'Content-Type' => 'application/json' } }
        else
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                                             'data' => { 'requiredCapabilities' => {} } }) }
        end
      end

      subscription = server.listen(notifications: { task_ids: ['t1'] })
      wait_until { subscription.state == :closed }

      expect(subscription.error).to be_a(MCPClient::Errors::MissingRequiredClientCapabilityError)
    end

    it 'invalidates the client tool cache from a subscription notification' do
      requests = stub_server([
                               lambda do |id|
                                 sse(ack(id, { 'toolsListChanged' => true }),
                                     { 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed',
                                       'params' => { '_meta' => { SUB_ID_META => id } } },
                                     { 'jsonrpc' => '2.0', 'id' => id,
                                       'result' => { 'resultType' => 'complete', '_meta' => { SUB_ID_META => id } } })
                               end
                             ])
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', base_url: 'x' }])
      client.list_tools

      subscription = client.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.state == :closed }
      client.list_tools

      expect(requests.count { |r| r[:body]['method'] == 'tools/list' }).to eq(2)
    end

    it 'refuses listen on a legacy session' do
      legacy = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                                   protocol: :legacy)
      legacy.instance_variable_set(:@protocol_version, '2025-11-25')
      legacy.instance_variable_set(:@connection_established, true)
      legacy.instance_variable_set(:@initialized, true)

      expect { legacy.listen(notifications: { tools_list_changed: true }) }
        .to raise_error(MCPClient::Errors::CapabilityError, /2026-07-28/)
    end
  end

  describe MCPClient::Subscription do
    it 'normalizes snake_case and camelCase filter keys and validates value types' do
      expect(described_class.normalize_filter({ tools_list_changed: true, 'promptsListChanged' => true,
                                                resource_subscriptions: ['a'], task_ids: ['t'] }))
        .to eq({ 'toolsListChanged' => true, 'promptsListChanged' => true, 'resourceSubscriptions' => ['a'],
                 'taskIds' => ['t'] })
      expect { described_class.normalize_filter({ tools_list_changed: 'yes' }) }.to raise_error(ArgumentError)
      expect { described_class.normalize_filter({ resource_subscriptions: 'a' }) }.to raise_error(ArgumentError)
      expect { described_class.normalize_filter(nil) }.to raise_error(ArgumentError)
    end
  end
end

# Review (codex): listen streams must not be gzip-encoded (the stream is
# parsed incrementally); a closed per-URI subscription is replaced by a
# fresh one on the next subscribe_resource; listen rejections go through
# the usual HTTP error/auth pipeline; a normal shutdown is not an
# unexpected exit.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — review follow-ups' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'resources' => { 'subscribe' => true } } }
  end

  # Acknowledge each listen as it goes out: subscribe_resource waits for it.
  def acknowledge_on_listen(server)
    allow(server).to receive(:open_subscription).and_wrap_original do |original, subscription|
      original.call(subscription)
      ack = { 'jsonrpc' => '2.0', 'method' => 'notifications/subscriptions/acknowledged',
              'params' => { '_meta' => { SUB_ID_META => subscription.id },
                            'notifications' => subscription.requested } }
      server.handle_line("#{JSON.generate(ack)}\n")
    end
  end

  describe 'on Streamable HTTP' do
    let(:url) { 'https://example.com/mcp' }

    def wait_until(timeout = 2)
      deadline = Time.now + timeout
      sleep 0.01 until yield || Time.now > deadline
      raise 'condition not met in time' unless yield
    end

    it 'asks for an identity-encoded listen stream' do
      server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << { headers: request.headers, body: body }
        if body['method'] == 'server/discover'
          { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result),
            headers: { 'Content-Type' => 'application/json' } }
        else
          { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
            body: "event: message\ndata: #{JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                                         'result' => { 'resultType' => 'complete' })}\n\n" }
        end
      end

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.closed? }

      listen = requests.find { |r| r[:body]['method'] == 'subscriptions/listen' }
      expect(listen[:headers]['Accept-Encoding']).to eq('identity')
      server.cleanup
    end

    it 'routes a rejected listen through the HTTP error pipeline even with raise_error middleware' do
      server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0,
                                                   faraday_config: ->(c) { c.response :raise_error })
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'server/discover'
          { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result),
            headers: { 'Content-Type' => 'application/json' } }
        else
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_021, 'message' => 'Missing required client capability',
                                             'data' => { 'requiredCapabilities' => {} } }) }
        end
      end

      subscription = server.listen(notifications: { task_ids: ['t'] })
      wait_until { subscription.closed? }

      expect(subscription.error).to be_a(MCPClient::Errors::MissingRequiredClientCapabilityError)
      server.cleanup
    end

    it 'surfaces an insufficient_scope challenge on a listen rejection' do
      server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        if body['method'] == 'server/discover'
          { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result),
            headers: { 'Content-Type' => 'application/json' } }
        else
          { status: 403, body: '',
            headers: { 'WWW-Authenticate' => 'Bearer error="insufficient_scope", scope="subs:read"' } }
        end
      end

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.closed? }

      expect(subscription.error).to be_a(MCPClient::Errors::InsufficientScopeError)
      expect(subscription.error.scope).to eq('subs:read')
      server.cleanup
    end
  end

  describe 'on stdio' do
    let(:server) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:written) { [] }

    before do
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      server.instance_variable_set(:@stdin, double('stdin', flush: nil, closed?: true, close: nil).tap do |d|
        allow(d).to receive(:puts) { |l| written << JSON.parse(l) }
      end)
      allow(server).to receive(:send_request) { |req| written << req }
      allow(server).to receive(:wait_response) do |id, **_o|
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => discover_result }
      end
    end

    it 'opens a fresh per-URI subscription after the server closed the previous one' do
      acknowledge_on_listen(server)
      server.subscribe_resource('file:///a')
      first = written.find { |m| m['method'] == 'subscriptions/listen' }
      server.handle_line("#{JSON.generate('jsonrpc' => '2.0', 'id' => first['id'],
                                          'result' => { 'resultType' => 'complete' })}\n")

      server.subscribe_resource('file:///a')

      listens = written.select { |m| m['method'] == 'subscriptions/listen' }
      expect(listens.size).to eq(2)
      expect(listens.last['id']).not_to eq(first['id'])
    end

    it 'does not treat the EOF of a normal shutdown as an unexpected exit' do
      output = StringIO.new
      server.instance_variable_set(:@logger, Logger.new(output))
      server.ping
      stdout = StringIO.new('')
      server.instance_variable_set(:@stdout, stdout)
      server.instance_variable_set(:@stderr, StringIO.new(''))
      allow(server).to receive(:start_reader).and_call_original
      reader = server.start_reader
      server.cleanup
      reader.join(1)

      expect(output.string).not_to include('ended unexpectedly')
    end
  end
end

# Review round 2 (grok): a JSON-framed answer to a listen request is a
# closing response, not a dropped stream; a client-closed subscription is
# never reopened by a racing reconnect; a listen stream only closes its own
# subscription; resource_subscriptions is guarded; unsupported reports the
# resource URIs the server declined; peer text in client logs is sanitized;
# the stream buffer is scanned incrementally.
RSpec.describe 'MCP 2026-07-28 subscriptions/listen — round 2' do
  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'resources' => { 'subscribe' => true } } }
  end

  def wait_until(timeout = 2)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    raise 'condition not met in time' unless yield
  end

  describe 'on Streamable HTTP' do
    let(:url) { 'https://example.com/mcp' }
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

    after { server.cleanup }

    def stub_discover_then(&listen)
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << body
        if body['method'] == 'server/discover'
          { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => discover_result),
            headers: { 'Content-Type' => 'application/json' } }
        else
          listen.call(body)
        end
      end
      requests
    end

    it 'treats a JSON-framed response to the listen request as the closing response' do
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 0.01)
      requests = stub_discover_then do |body|
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => { 'resultType' => 'complete' }) }
      end

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.closed? }
      sleep 0.05

      expect(subscription).to be_closed_gracefully
      expect(requests.count { |r| r['method'] == 'subscriptions/listen' }).to eq(1)
    end

    it 'treats a JSON-framed error to the listen request as a failed subscription' do
      stub_discover_then do |body|
        { status: 200, headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                              'error' => { 'code' => -32_602, 'message' => 'bad filter' }) }
      end

      subscription = server.listen(notifications: { tools_list_changed: true })
      wait_until { subscription.closed? }

      expect(subscription.error).to be_a(MCPClient::Errors::ServerError)
      expect(subscription.error.code).to eq(-32_602)
    end

    it 'closes only its own subscription when a stream carries a response for another id' do
      other = nil
      stub_discover_then do |body|
        if other && body['id'] != other.id
          { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
            body: "event: message\ndata: #{JSON.generate('jsonrpc' => '2.0', 'id' => other.id,
                                                         'result' => { 'resultType' => 'complete' })}\n\n" \
                  "event: message\ndata: #{JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                                         'result' => { 'resultType' => 'complete' })}\n\n" }
        else
          { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
            body: "event: message\ndata: #{JSON.generate('jsonrpc' => '2.0',
                                                         'method' => 'notifications/subscriptions/acknowledged',
                                                         'params' => { '_meta' => { SUB_ID_META => body['id'] },
                                                                       'notifications' => {} })}\n\n" }
        end
      end
      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_RECONNECT_DELAY', 5)
      other = server.listen(notifications: { prompts_list_changed: true })
      wait_until { other.acknowledged }

      victim = server.listen(notifications: { tools_list_changed: true })
      wait_until { victim.closed? }

      expect(victim).to be_closed_gracefully
      expect(other.closed?).to be(false)
    end
  end

  describe MCPClient::Subscription do
    let(:server) { instance_double(MCPClient::ServerStdio) }

    it 'does not reopen a subscription the client closed, even if a reconnect assigns a new id' do
      subscription = described_class.new(server: server, requested: { 'toolsListChanged' => true })
      subscription.assign_id(1)
      allow(server).to receive(:cancel_subscription) { |s| s.finish(by_client: true) }
      subscription.close

      subscription.assign_id(2)

      expect(subscription.state).to eq(:closed)
      expect(subscription).not_to be_reconnectable
    end

    it 'reports the resource URIs the server declined as unsupported' do
      subscription = described_class.new(server: server,
                                         requested: { 'resourceSubscriptions' => ['file:///a', 'file:///b'],
                                                      'promptsListChanged' => true })
      subscription.assign_id(1)
      subscription.acknowledge({ 'resourceSubscriptions' => ['file:///a'] })

      expect(subscription.unsupported).to eq(['promptsListChanged'])
      expect(subscription.unacknowledged_resource_uris).to eq(['file:///b'])
    end
  end

  describe 'client logging' do
    it 'sanitizes the subscription id and reason from server notifications' do
      output = StringIO.new
      stdio = MCPClient::ServerStdio.new(command: 'echo test')
      allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], logger: Logger.new(output))
      client.logger.level = Logger::DEBUG

      stdio.instance_variable_get(:@notification_callback).call(
        'notifications/subscriptions/acknowledged',
        { '_meta' => { SUB_ID_META => "1\nWARN forged" }, 'notifications' => {} }
      )
      stdio.instance_variable_get(:@notification_callback).call(
        'notifications/cancelled', { 'requestId' => 1, 'reason' => "bye\nWARN forged" }
      )

      expect(output.string).not_to include("\nWARN forged")
    end
  end

  describe 'listen stream buffering' do
    it 'scans the buffer incrementally and enforces the cap on unterminated events' do
      server = MCPClient::ServerStreamableHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0)
      subscription = MCPClient::Subscription.new(server: server, requested: {})
      subscription.assign_id(9)
      buffer = +''
      state = { scanned: 0 }
      expect(server).to receive(:match_event_terminator).at_most(3).times.and_call_original
      3.times { server.send(:consume_listen_events, buffer << ('x' * 10), subscription, state) }

      stub_const('MCPClient::HttpTransportBase::ListenStream::LISTEN_MAX_BUFFER_BYTES', 8)
      expect { server.send(:enforce_listen_buffer_cap!, buffer) }.to raise_error(MCPClient::Errors::ConnectionError)
      server.cleanup
    end
  end
end
