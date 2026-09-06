# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Review round 5 (codex, grok): the boundaries the earlier rounds left
# unpinned — an integral Float beyond the safe-integer range, the structured
# parts of a HeaderMismatch that is re-raised whole, the inner recoveries
# meeting a configured retry budget, a replacement list installed while a
# stale fetch is still in flight, a tab in a header name, and the code
# HeaderMismatch had before the changelog reassigned it.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — round 5' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/mcp' }
  let(:url) { "#{base_url}#{endpoint}" }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def modern_discover
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'resources' => {} } }
  end

  def header_mismatch(id, message = 'Header mismatch')
    { status: 400, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => -32_020, 'message' => message }) }
  end

  def annotated_tool(header = 'Region')
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } } }
  end

  def integer_tool
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'n' => { 'type' => 'integer', 'x-mcp-header' => 'N' } } } }
  end

  # A HeaderMismatch with the optional error data a server may add.
  def header_mismatch_with_data(id, message, data)
    { status: 400, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate('jsonrpc' => '2.0', 'id' => id,
                          'error' => { 'code' => -32_020, 'message' => message, 'data' => data }) }
  end

  describe MCPClient::HeaderParams do
    let(:schema) do
      { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer', 'x-mcp-header' => 'N' } } }
    end

    # A JSON integer parsed as a Float is an integer for the safe-integer
    # rule too: 2**53 is out of range whether it arrives as 9007199254740992
    # or as 9007199254740992.0.
    it 'rejects an integral Float beyond the safe-integer range at either end' do
      [9_007_199_254_740_992.0, -9_007_199_254_740_992.0].each do |value|
        expect { described_class.headers_for(schema, { 'n' => value }) }
          .to raise_error(MCPClient::Errors::ValidationError, /safe/), value.to_s
      end
    end

    it 'accepts the integral Floats at the edge of the range' do
      expect(described_class.headers_for(schema, { 'n' => 9_007_199_254_740_991.0 }))
        .to eq({ 'Mcp-Param-N' => '9007199254740991' })
      expect(described_class.headers_for(schema, { 'n' => -9_007_199_254_740_991.0 }))
        .to eq({ 'Mcp-Param-N' => '-9007199254740991' })
    end
  end

  # RFC 9110 field names are tokens: tab, comma and "@" are delimiters, not
  # tchars, however plausible they look inside a name.
  describe 'header names' do
    it 'rejects a tab, a comma and an at-sign inside the name' do
      ["Region\t1", 'a,b', 'a@b', "\tRegion"].each do |bad|
        schema = { 'type' => 'object', 'properties' => { 'a' => { 'type' => 'string', 'x-mcp-header' => bad } } }
        expect(MCPClient::HeaderParams.validate_schema(schema)).not_to be_empty, bad.inspect
      end
    end
  end

  # SEP-2243 first assigned HeaderMismatch -32001; MCP 2026-07-28 reassigned
  # it to -32020. The old code is an ordinary server error: no refresh, no
  # retry.
  describe 'the pre-reassignment HeaderMismatch code' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    after { server.cleanup }

    it 'does not start the refresh-and-retry recovery on -32001' do
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << body['method']
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list' then json_response(body['id'], { 'tools' => [annotated_tool] })
        else
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_001, 'message' => 'Header mismatch' }) }
        end
      end

      # An ordinary server error, wrapped the way call_tool wraps them —
      # never the typed HeaderMismatchError that starts the recovery.
      expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }
        .to raise_error(MCPClient::Errors::ToolCallError, /HTTP 400/)
      expect(requests.count('tools/call')).to eq(1)
      expect(requests.count('tools/list')).to eq(1)
    end
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    context "on #{klass.name.split('::').last}" do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }

      after { server.cleanup }

      it 'rejects an out-of-range integral Float before the call goes out' do
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << body['method']
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          when 'tools/list' then json_response(body['id'], { 'tools' => [integer_tool] })
          else json_response(body['id'], { 'content' => [] })
          end
        end
        server.list_tools

        expect { server.call_tool('execute_sql', { 'n' => 9_007_199_254_740_992.0 }) }
          .to raise_error(MCPClient::Errors::ValidationError, /safe/)
        expect(requests).not_to include('tools/call')
      end
    end
  end

  describe 'a HeaderMismatch re-raised whole' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    after { server.cleanup }

    def rescued_mismatch
      server.call_tool('execute_sql', { 'region' => 'eu' })
      nil
    rescue MCPClient::Errors::HeaderMismatchError => e
      e
    end

    it 'keeps the second rejection\'s HTTP status and error data, not the first\'s' do
      calls = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list' then json_response(body['id'], { 'tools' => [annotated_tool] })
        else
          calls += 1
          if calls == 1
            header_mismatch_with_data(body['id'], 'first', { 'attempt' => 1 })
          else
            { status: 422, headers: { 'Content-Type' => 'application/json' },
              body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                  'error' => { 'code' => -32_020, 'message' => 'second',
                                               'data' => { 'attempt' => 2, 'header' => 'Mcp-Param-Region' } }) }
          end
        end
      end

      error = rescued_mismatch
      expect(error).not_to be_nil
      expect(error.code).to eq(-32_020)
      expect(error.http_status).to eq(422)
      expect(error.data).to eq({ 'attempt' => 2, 'header' => 'Mcp-Param-Region' })
      expect(calls).to eq(2)
    end

    it 'keeps the rejection\'s HTTP status and error data when the refresh fails' do
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list'
          lists += 1
          lists == 1 ? json_response(body['id'], { 'tools' => [annotated_tool] }) : { status: 503, body: '' }
        else header_mismatch_with_data(body['id'], 'Mcp-Param-Zone missing', { 'missing' => ['Mcp-Param-Zone'] })
        end
      end

      error = rescued_mismatch
      expect(error).not_to be_nil
      expect(error.http_status).to eq(400)
      expect(error.data).to eq({ 'missing' => ['Mcp-Param-Zone'] })
      expect(lists).to eq(2)
    end

    it 'keeps the rejection\'s HTTP status and error data when the refresh fails on a later page' do
      refreshing = false
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list'
          if !refreshing
            json_response(body['id'], { 'tools' => [annotated_tool] })
          elsif body['params']['cursor']
            { status: 503, body: '' }
          else
            json_response(body['id'], { 'tools' => [annotated_tool('Zone')], 'nextCursor' => 'page2' })
          end
        else
          refreshing = true
          header_mismatch_with_data(body['id'], 'Mcp-Param-Zone missing', { 'page' => 'irrelevant' })
        end
      end

      error = rescued_mismatch
      expect(error).not_to be_nil
      expect(error.http_status).to eq(400)
      expect(error.data).to eq({ 'page' => 'irrelevant' })
    end
  end

  # The inner recoveries (refresh-and-retry, re-issue) are bounded per
  # with_retry attempt; a configured retry budget is spent by the exchange
  # that fails, and never on a tools/call, which with_retry does not re-send.
  describe 'the recoveries and a configured retry budget' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 1) }

    after { server.cleanup }

    # Serve the annotated tool; the tools/list at position +failing_list+
    # (1-based) answers 503 once, the tools/call at +failing_call+ answers 503.
    def stub_transient(failing_list: nil, failing_call: nil, mismatch_first_call: false)
      lists = 0
      calls = 0
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << body['method']
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list'
          lists += 1
          if lists == failing_list
            { status: 503, body: '' }
          else
            json_response(body['id'], { 'tools' => [annotated_tool(calls.positive? ? 'Zone' : 'Region')] })
          end
        when 'tools/call'
          calls += 1
          if calls == failing_call then { status: 503, body: '' }
          elsif mismatch_first_call && calls == 1 then header_mismatch(body['id'], 'Mcp-Param-Zone missing')
          else json_response(body['id'], { 'content' => [] })
          end
        end
      end
      requests
    end

    it 'spends the budget on the prerequisite tools/list that fails, and sends the call once' do
      requests = stub_transient(failing_list: 1)

      expect(server.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

      expect(requests.count('tools/list')).to eq(2)
      expect(requests.count('tools/call')).to eq(1)
    end

    it 'spends the budget on a refresh that fails transiently, then retries the call once' do
      requests = stub_transient(failing_list: 2, mismatch_first_call: true)

      expect(server.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

      # initial list, failed refresh, retried refresh; the rejected call and its retry
      expect(requests.count('tools/list')).to eq(3)
      expect(requests.count('tools/call')).to eq(2)
    end

    it 'never re-sends the tools/call itself, whatever the budget' do
      requests = stub_transient(failing_call: 1)

      expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }
        .to raise_error(MCPClient::Errors::ToolCallError, /HTTP 503/)

      expect(requests.count('tools/call')).to eq(1)
    end
  end

  # A stale fetch releasing after a newer one already installed the list
  # must leave that newer list in place — not overwrite it, not evict it.
  describe 'a replacement list installed while a stale fetch is in flight' do
    def full_discover
      { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
        'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
    end

    # Serve numbered lists, holding the first +held+ response until released;
    # +counts+ records how many of each method were fetched.
    def stub_held_lists(held, in_flight, release, counts)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        method = body['method']
        counts[method] += 1
        n = counts[method]
        if method == held && n == 1
          in_flight << true
          release.pop(timeout: 5)
        end
        case method
        when 'server/discover' then json_response(body['id'], full_discover)
        when 'prompts/list' then json_response(body['id'], { 'prompts' => [{ 'name' => "p#{n}" }] })
        when 'resources/list'
          json_response(body['id'], { 'resources' => [{ 'uri' => "file:///r#{n}", 'name' => "r#{n}" }] })
        end
      end
    end

    { MCPClient::ServerHTTP => :dispatch_sse_message,
      MCPClient::ServerStreamableHTTP => :dispatch_server_message }.each do |klass, dispatcher|
      context klass.name.split('::').last do
        let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }

        after { server.cleanup }

        def notify(server, dispatcher, method)
          server.send(dispatcher, { 'jsonrpc' => '2.0', 'method' => method, 'params' => {} })
        end

        it 'keeps the replacement prompt list when the stale fetch finally returns' do
          in_flight = Queue.new
          release = Queue.new
          counts = Hash.new(0)
          stub_held_lists('prompts/list', in_flight, release, counts)
          server.connect

          stale = Thread.new { server.list_prompts }
          expect(in_flight.pop(timeout: 5)).not_to be_nil
          notify(server, dispatcher, 'notifications/prompts/list_changed')
          expect(server.list_prompts.map(&:name)).to eq(['p2'])
          release << true
          stale.join(5)

          expect(server.list_prompts.map(&:name)).to eq(['p2'])
          expect(counts['prompts/list']).to eq(2)
        end

        it 'keeps the replacement resource list when the stale fetch finally returns' do
          in_flight = Queue.new
          release = Queue.new
          counts = Hash.new(0)
          stub_held_lists('resources/list', in_flight, release, counts)
          server.connect

          stale = Thread.new { server.list_resources }
          expect(in_flight.pop(timeout: 5)).not_to be_nil
          notify(server, dispatcher, 'notifications/resources/list_changed')
          expect(server.list_resources['resources'].map(&:name)).to eq(['r2'])
          release << true
          stale.join(5)

          expect(server.list_resources['resources'].map(&:name)).to eq(['r2'])
          expect(counts['resources/list']).to eq(2)
        end
      end
    end
  end
end
