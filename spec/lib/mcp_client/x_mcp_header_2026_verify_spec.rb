# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# Verification pass over MCP 2026-07-28 Streamable HTTP "Custom Headers from
# Tool Parameters" (SEP-2243). Two contracts the earlier examples left
# unpinned:
#
# * a tools/call result is validated against the tool definition the request
#   attempt it answers went out under -- not against whatever the transport's
#   list happens to hold once the call returns, which a racing
#   `notifications/tools/list_changed` may already have replaced;
# * on a modern session the `Mcp-Param-*` namespace is derived from the call's
#   arguments alone, so a configured header of that name never stands in for
#   an argument the extraction omitted (absent or null).
RSpec.shared_context 'with x-mcp-header wire helpers' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/mcp' }
  let(:url) { "#{base_url}#{endpoint}" }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  # A POST response delivered as an SSE stream, so a server message can be
  # interleaved ahead of the JSON-RPC response the request is waiting for.
  def sse_response(messages)
    { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
      body: messages.map { |m| "event: message\ndata: #{JSON.generate(m)}\n\n" }.join }
  end

  def modern_discover
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
  end

  def header_mismatch(id, message = 'Header mismatch')
    { status: 400, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => -32_020, 'message' => message }) }
  end

  # The wire value of an Mcp-Param-* header, decoded back through the spec's
  # Base64 sentinel so it can be compared with the serialized argument.
  def decode_param_header(value)
    match = value.to_s.match(/\A=\?base64\?(.*)\?=\z/m)
    return value.to_s unless match

    match[1].unpack1('m0').force_encoding('UTF-8')
  end

  def param_headers(headers)
    headers.to_h.select { |k, _| k.to_s.downcase.start_with?('mcp-param-') }
  end

  def calls_in(requests)
    requests.select { |r| r[:body]['method'] == 'tools/call' }
  end
end

# Finding 2: computed parameter headers are applied after the configured ones,
# and nothing removes a configured header in the mirrored namespace when the
# extraction omits it. The spec requires omission for an absent or null
# argument, so a configured `Mcp-Param-*` must never survive into a modern
# request.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — configured Mcp-Param headers' do
  include_context 'with x-mcp-header wire helpers'

  let(:configured_headers) do
    { 'mcp-param-region' => 'configured', 'MCP-PARAM-TENANT' => 'configured-tenant', 'X-Tenant' => 'acme' }
  end
  let(:server) do
    MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0,
                                        headers: configured_headers)
  end

  after { server.cleanup }

  def search_tool
    { 'name' => 'search',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' },
                                           'tenant' => { 'type' => 'string', 'x-mcp-header' => 'Tenant' },
                                           'query' => { 'type' => 'string' } },
                         'required' => ['query'] } }
  end

  # A conformant intermediary rejects a call whose mirrored header does not
  # agree with the arguments: the header is there but the argument is not.
  def stub_strict_server
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers.to_h, body: body }
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], { 'tools' => [search_tool] })
      when 'tools/call'
        args = body['params']['arguments'] || {}
        stray = param_headers(request.headers).keys.select do |name|
          args[name.to_s.downcase.delete_prefix('mcp-param-')].nil?
        end
        stray.empty? ? json_response(body['id'], { 'content' => [] }) : header_mismatch(body['id'], stray.join(','))
      end
    end
    requests
  end

  it 'omits a configured mirrored header when the annotated argument is absent' do
    requests = stub_strict_server
    server.list_tools

    expect(server.call_tool('search', { 'query' => 'x' })).to eq({ 'content' => [] })

    calls = calls_in(requests)
    expect(calls.size).to eq(1)
    expect(param_headers(calls.first[:headers])).to be_empty
  end

  it 'omits a configured mirrored header when the annotated argument is null' do
    requests = stub_strict_server
    server.list_tools

    expect(server.call_tool('search', { 'query' => 'x', 'region' => nil, 'tenant' => nil })).to eq({ 'content' => [] })

    calls = calls_in(requests)
    expect(calls.size).to eq(1)
    expect(param_headers(calls.first[:headers])).to be_empty
  end

  it 'keeps configured headers outside the mirrored namespace' do
    requests = stub_strict_server
    server.list_tools
    server.call_tool('search', { 'query' => 'x' })

    expect(calls_in(requests).first[:headers]['X-Tenant']).to eq('acme')
  end

  it 'mirrors the argument in place of the configured value, without appending to it' do
    requests = stub_strict_server
    server.list_tools
    server.call_tool('search', { 'query' => 'x', 'region' => 'eu-west1' })

    call = calls_in(requests).first
    expect(param_headers(call[:headers])).to eq({ 'Mcp-Param-Region' => 'eu-west1' })
  end

  it 'clears the mirrored namespace on modern requests that carry no arguments at all' do
    requests = stub_strict_server
    server.list_tools

    lists = requests.select { |r| r[:body]['method'] == 'tools/list' }
    expect(param_headers(lists.first[:headers])).to be_empty
  end

  it 'leaves a configured header alone on a legacy session, where the namespace has no meaning' do
    requests = []
    stub_request(:get, url).to_return(status: 405, body: '')
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers.to_h, body: body }
      case body['method']
      when 'initialize'
        json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                                    'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
      when 'notifications/initialized' then { status: 202, body: '' }
      when 'tools/list' then json_response(body['id'], { 'tools' => [search_tool] })
      else json_response(body['id'], { 'content' => [] })
      end
    end
    legacy = MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0,
                                                 protocol: :legacy, headers: configured_headers)

    legacy.call_tool('search', { 'query' => 'x' })

    expect(param_headers(calls_in(requests).first[:headers])['Mcp-Param-Region']).to eq('configured')
    legacy.cleanup
  end
end

# Finding 1: the definition a result is validated against must be the one the
# request attempt it answers went out under. A tool-list generation counter
# cannot express that: a `notifications/tools/list_changed` that merely races
# the call bumps it just like the HeaderMismatch refresh does.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — the definition a call went out under' do
  include_context 'with x-mcp-header wire helpers'

  let(:list_changed) { { 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed', 'params' => {} } }

  def tool_with_output(output_schema, header: nil, name: 'execute_sql')
    region = { 'type' => 'string' }
    region['x-mcp-header'] = header if header
    { 'name' => name,
      'inputSchema' => { 'type' => 'object', 'properties' => { 'region' => region } },
      'outputSchema' => output_schema }
  end

  def object_schema(property, required: true)
    schema = { 'type' => 'object', 'properties' => { property => { 'type' => 'boolean' } } }
    required ? schema.merge('required' => [property]) : schema
  end

  def strict_client(**options)
    MCPClient::Client.new(
      mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0,
                                                            **options)],
      validate_structured_content: :strict
    )
  end

  # A legacy (2025-11-25) session whose tools/call POST answers on an SSE
  # stream carrying a list-change notification ahead of the result.
  def stub_legacy_racing_server(listed)
    stub_request(:get, url).to_return(status: 405, body: '')
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      case body['method']
      when 'initialize'
        json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                                    'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
      when 'notifications/initialized' then { status: 202, body: '' }
      when 'tools/list' then json_response(body['id'], { 'tools' => [listed.call] })
      when 'tools/call'
        sse_response([list_changed,
                      { 'jsonrpc' => '2.0', 'id' => body['id'],
                        'result' => { 'content' => [], 'structuredContent' => { 'old' => true } } }])
      end
    end
  end

  it 'keeps the answering definition when a list-change notification races the call' do
    listed = tool_with_output(object_schema('old'))
    stub_legacy_racing_server(-> { listed })
    client = strict_client(protocol: :legacy)
    client.on_notification do |_srv, method, _params|
      listed = tool_with_output(object_schema('new')) if method == 'notifications/tools/list_changed'
    end

    result = client.call_tool('execute_sql', { 'region' => 'eu' })

    expect(result['structuredContent']).to eq({ 'old' => true })
    client.cleanup
  end

  it 'still rejects a result the answering definition forbids when the replacement is looser' do
    listed = tool_with_output(object_schema('missing'))
    stub_legacy_racing_server(-> { listed })
    client = strict_client(protocol: :legacy)
    client.on_notification do |_srv, method, _params|
      listed = tool_with_output(object_schema('missing', required: false)) if method.end_with?('list_changed')
    end

    expect { client.call_tool('execute_sql', { 'region' => 'eu' }) }
      .to raise_error(MCPClient::Errors::ValidationError, /missing/)
    client.cleanup
  end

  # The HeaderMismatch retry is the one re-send that genuinely changes the
  # definition a call is answered under, and a notification arriving on the
  # retry's own response stream must not move it on again.
  it 'validates against the refreshed definition of a HeaderMismatch retry, not a later replacement' do
    listed = tool_with_output(object_schema('v1'), header: 'Region')
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], { 'tools' => [listed] })
      when 'tools/call'
        if request.headers['Mcp-Param-Zone']
          sse_response([list_changed,
                        { 'jsonrpc' => '2.0', 'id' => body['id'],
                          'result' => { 'content' => [], 'structuredContent' => { 'v2' => true } } }])
        else
          listed = tool_with_output(object_schema('v2'), header: 'Zone')
          header_mismatch(body['id'], 'Mcp-Param-Zone missing')
        end
      end
    end
    client = strict_client
    # Only the notification the *server* sent on the retry's own response
    # stream may move the list on. The refresh a HeaderMismatch triggers
    # announces a list_changed of its own, and reacting to that one would
    # replace the definition before the retry even goes out — which is the
    # host changing the answer, not the race this example is about.
    retry_sent = false
    client.on_notification do |_srv, method, _params|
      next unless method.end_with?('list_changed')

      listed = tool_with_output(object_schema('v3'), header: 'Zone') if retry_sent
      retry_sent = true
    end

    result = client.call_tool('execute_sql', { 'region' => 'eu' })

    expect(result['structuredContent']).to eq({ 'v2' => true })
    client.cleanup
  end

  # A listener that calls the very same tool while the outer response is
  # still being parsed goes out under the replacement definition -- and that
  # is what it must be validated against, without displacing what the outer
  # call recorded for itself.
  it 'keeps its own definition when a nested call records one for the same tool' do
    listed = tool_with_output(object_schema('old'), header: 'Region')
    nested = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], { 'tools' => [listed] })
      when 'tools/call'
        if body['params']['arguments']['region'] == 'nested'
          json_response(body['id'], { 'content' => [], 'structuredContent' => { 'new' => true } })
        else
          sse_response([list_changed,
                        { 'jsonrpc' => '2.0', 'id' => body['id'],
                          'result' => { 'content' => [], 'structuredContent' => { 'old' => true } } }])
        end
      end
    end
    client = strict_client
    client.on_notification do |_srv, method, _params|
      next unless method.end_with?('list_changed') && nested.empty?

      listed = tool_with_output(object_schema('new'), header: 'Region')
      nested << client.call_tool('execute_sql', { 'region' => 'nested' })
    end

    expect(client.call_tool('execute_sql', { 'region' => 'eu' })['structuredContent']).to eq({ 'old' => true })
    expect(nested.map { |r| r['structuredContent'] }).to eq([{ 'new' => true }])
    client.cleanup
  end

  # The same, for host code that reaches past this client and calls the
  # transport directly: it too is behind the boundary the transport crosses
  # to reach it, so what it records is its own.
  it 'keeps its own definition when a listener calls the transport directly mid-response' do
    listed = tool_with_output(object_schema('old'), header: 'Region')
    nested = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], { 'tools' => [listed] })
      when 'tools/call'
        if body['params']['arguments']['region'] == 'nested'
          json_response(body['id'], { 'content' => [], 'structuredContent' => { 'new' => true } })
        else
          sse_response([list_changed,
                        { 'jsonrpc' => '2.0', 'id' => body['id'],
                          'result' => { 'content' => [], 'structuredContent' => { 'old' => true } } }])
        end
      end
    end
    client = strict_client
    client.on_notification do |srv, method, _params|
      next unless method.end_with?('list_changed') && nested.empty?

      listed = tool_with_output(object_schema('new'), header: 'Region')
      nested << srv.call_tool('execute_sql', { 'region' => 'nested' })
    end

    expect(client.call_tool('execute_sql', { 'region' => 'eu' })['structuredContent']).to eq({ 'old' => true })
    expect(nested.map { |r| r['structuredContent'] }).to eq([{ 'new' => true }])
    client.cleanup
  end
end

# Coverage the earlier examples never established: that the mirrored headers
# agree with the arguments actually serialized into the body, on both POSTs of
# a HeaderMismatch recovery, and that the request `_meta` survives the re-send.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — wire-body agreement' do
  include_context 'with x-mcp-header wire helpers'

  let(:server) do
    MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0)
  end

  after { server.cleanup }

  def report_tool(header)
    { 'name' => 'report',
      'inputSchema' => {
        'type' => 'object',
        'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header },
                          'limit' => { 'type' => 'integer', 'x-mcp-header' => 'Limit' },
                          'db' => { 'type' => 'object',
                                    'properties' => { 'tenant' => { 'type' => 'string',
                                                                    'x-mcp-header' => 'Tenant' } } } }
      } }
  end

  # Every mirrored header names the exact property path it came from, so the
  # agreement can be checked against the body rather than against a literal.
  def expect_headers_to_agree_with_body(entry, header:)
    args = entry[:body]['params']['arguments']
    mirrored = param_headers(entry[:headers]).transform_values { |v| decode_param_header(v) }
    expect(mirrored).to eq({ "Mcp-Param-#{header}" => args['region'],
                             'Mcp-Param-Limit' => args['limit'].to_s,
                             'Mcp-Param-Tenant' => args.dig('db', 'tenant') })
  end

  it 'agrees with the serialized arguments on both POSTs and preserves the request _meta' do
    header = 'Region'
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers.to_h, body: body }
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], { 'tools' => [report_tool(header)] })
      when 'tools/call'
        if request.headers['Mcp-Param-Zone']
          json_response(body['id'], { 'content' => [] })
        else
          header = 'Zone'
          header_mismatch(body['id'], 'Mcp-Param-Zone missing')
        end
      end
    end
    expected = { 'region' => 'eu west 1', 'limit' => 25, 'db' => { 'tenant' => 'acmé' } }

    server.call_tool('report', expected.merge('_meta' => { 'io.example/trace' => 'abc' }))

    calls = calls_in(requests)
    expect(calls.size).to eq(2)
    expect(calls.map { |c| c[:body]['params']['arguments'] }).to eq([expected, expected])
    expect(calls.map { |c| c[:body]['params'].dig('_meta', 'io.example/trace') }).to eq(%w[abc abc])
    expect_headers_to_agree_with_body(calls[0], header: 'Region')
    expect_headers_to_agree_with_body(calls[1], header: 'Zone')
  end

  it 'carries the standard modern headers, the mirrored headers and the body together for a listed tool' do
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers.to_h, body: body }
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], { 'tools' => [report_tool('Region')] })
      else json_response(body['id'], { 'content' => [] })
      end
    end

    server.call_tool('report', { 'region' => 'eu', 'limit' => 1, 'db' => { 'tenant' => 'acme' } })

    call = calls_in(requests).first
    expect(call[:headers]['Mcp-Method']).to eq('tools/call')
    expect(call[:headers]['Mcp-Name']).to eq(call[:body]['params']['name'])
    expect(call[:headers]['Mcp-Protocol-Version']).to eq('2026-07-28')
    expect(call[:body]['params']['_meta']['io.modelcontextprotocol/protocolVersion']).to eq('2026-07-28')
    expect_headers_to_agree_with_body(call, header: 'Region')
  end
end

# The IEEE754 safe-integer boundary, at both ends and on both sides.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — safe integer boundary' do
  let(:schema) do
    { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer', 'x-mcp-header' => 'N' } } }
  end

  it 'accepts the largest and smallest exactly representable integers' do
    max = (2**53) - 1
    expect(MCPClient::HeaderParams.headers_for(schema, { 'n' => max })).to eq({ 'Mcp-Param-N' => max.to_s })
    expect(MCPClient::HeaderParams.headers_for(schema, { 'n' => -max })).to eq({ 'Mcp-Param-N' => (-max).to_s })
  end

  it 'rejects the first integer beyond the range at either end' do
    [2**53, -(2**53)].each do |value|
      expect { MCPClient::HeaderParams.headers_for(schema, { 'n' => value }) }
        .to raise_error(MCPClient::Errors::ValidationError, /safe/)
    end
  end
end

# Review round 3 (codex): a modern tools/call may need either of the two
# 2026-07-28 recoveries -- refresh-and-retry after a HeaderMismatch, re-issue
# after a broken response stream -- and either one's re-send can run into the
# other. They must compose, in both orders, and stay bounded.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — recovery composition' do
  include_context 'with x-mcp-header wire helpers'

  let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

  after { server.cleanup }

  def annotated_tool(header)
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } } }
  end

  # A POST answered on an SSE stream that closes without ever carrying the
  # response: on a modern session that request is lost and MUST be re-issued.
  def closed_stream
    sse_response([{ 'jsonrpc' => '2.0', 'method' => 'notifications/progress', 'params' => { 'progress' => 1 } }])
  end

  # Serve the annotated tool, answering the nth tools/call with the nth entry
  # of +answers+ (a lambda taking the request body). The header the tool is
  # annotated with flips to 'Zone' as soon as a HeaderMismatch is returned.
  #
  # The list is bounded with a ttlMs so that the only tools/list this example
  # counts is the one a recovery asks for: a 2026-07-28 server that sends no
  # ttlMs means "assume 0", and every attempt would then re-read the list it
  # derives its Mcp-Param-* headers from.
  def stub_call_sequence(answers)
    header = 'Region'
    requests = []
    calls = 0
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers.to_h, body: body }
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list'
        json_response(body['id'], { 'tools' => [annotated_tool(header)], 'ttlMs' => 60_000 })
      when 'tools/call'
        calls += 1
        answer = answers[calls - 1] || ->(b) { json_response(b['id'], { 'content' => [] }) }
        header = 'Zone' if answer == :mismatch
        answer == :mismatch ? header_mismatch(body['id'], 'Mcp-Param-Zone missing') : answer.call(body)
      end
    end
    requests
  end

  let(:closed) { ->(_body) { closed_stream } }
  let(:ok) { ->(body) { json_response(body['id'], { 'content' => [] }) } }

  it 're-issues the HeaderMismatch retry when its own response stream closes' do
    requests = stub_call_sequence([:mismatch, closed, ok])

    expect(server.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

    posted = calls_in(requests)
    expect(posted.size).to eq(3)
    expect(posted.map { |c| c[:headers]['Mcp-Param-Region'] }).to eq(['eu', nil, nil])
    expect(posted.map { |c| c[:headers]['Mcp-Param-Zone'] }).to eq([nil, 'eu', 'eu'])
    expect(posted.map { |c| c[:body]['id'] }.uniq.size).to eq(3)
    expect(requests.count { |r| r[:body]['method'] == 'tools/list' }).to eq(2)
  end

  it 'refreshes tools/list when the re-issue after a broken stream is rejected for its headers' do
    requests = stub_call_sequence([closed, :mismatch, ok])

    expect(server.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

    posted = calls_in(requests)
    expect(posted.size).to eq(3)
    expect(posted.map { |c| c[:headers]['Mcp-Param-Region'] }).to eq(%w[eu eu] + [nil])
    expect(posted.map { |c| c[:headers]['Mcp-Param-Zone'] }).to eq([nil, nil, 'eu'])
    expect(posted.map { |c| c[:body]['id'] }.uniq.size).to eq(3)
    expect(requests.count { |r| r[:body]['method'] == 'tools/list' }).to eq(2)
  end

  it 'stays bounded: each recovery fires once, then the failure surfaces' do
    requests = stub_call_sequence([:mismatch, closed, closed])

    expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }
      .to raise_error(MCPClient::Errors::ResponseStreamClosedError, /closed before delivering the response/)

    expect(calls_in(requests).size).to eq(3)
  end

  it 'stays bounded in the other order too' do
    requests = stub_call_sequence([closed, :mismatch, :mismatch])

    expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }
      .to raise_error(MCPClient::Errors::HeaderMismatchError)

    expect(calls_in(requests).size).to eq(3)
  end
end

# Review round 3 (codex): the plain HTTP transport also answers a POST on an
# SSE stream and dispatches the server messages that stream carries, so host
# code it reaches can nest a tools/call inside an outer one -- exactly as on
# Streamable HTTP, and with the same requirement that the nested call not
# displace the definition the outer call recorded for itself.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — nested calls on both HTTP transports' do
  include_context 'with x-mcp-header wire helpers'

  let(:progress) do
    { 'jsonrpc' => '2.0', 'method' => 'notifications/progress',
      'params' => { 'progressToken' => 'p', 'progress' => 1 } }
  end
  let(:other_tool) { { 'name' => 'other', 'inputSchema' => { 'type' => 'object' } } }

  def annotated(header, required)
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } },
      'outputSchema' => { 'type' => 'object', 'properties' => { required => { 'type' => 'boolean' } },
                          'required' => [required] } }
  end

  # A modern server that rejects the first tools/call for its headers, moving
  # both the annotation and the outputSchema on, and answers the retry on an
  # SSE stream carrying a progress notification ahead of the result.
  def stub_refreshing_server
    listed = [annotated('Region', 'v1'), other_tool]
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], { 'tools' => listed })
      when 'tools/call'
        if body['params']['name'] == 'other'
          json_response(body['id'], { 'content' => [] })
        elsif request.headers['Mcp-Param-Zone']
          sse_response([progress,
                        { 'jsonrpc' => '2.0', 'id' => body['id'],
                          'result' => { 'content' => [], 'structuredContent' => { 'v2' => true } } }])
        else
          listed = [annotated('Zone', 'v2'), other_tool]
          header_mismatch(body['id'], 'Mcp-Param-Zone missing')
        end
      end
    end
  end

  def strict_client_for(factory)
    MCPClient::Client.new(
      mcp_server_configs: [MCPClient.public_send(factory, base_url: base_url, endpoint: endpoint, retries: 0)],
      validate_structured_content: :strict, logger: Logger.new(File::NULL)
    )
  end

  { 'plain HTTP' => :http_config, 'Streamable HTTP' => :streamable_http_config }.each do |label, factory|
    it "keeps the answering definition on #{label} when a listener nests a call to another tool" do
      stub_refreshing_server
      client = strict_client_for(factory)
      nested = []
      client.on_notification do |srv, method, _params|
        nested << srv.call_tool('other', {}) if method == 'notifications/progress'
      end

      result = client.call_tool('execute_sql', { 'region' => 'eu' })

      expect(result['structuredContent']).to eq({ 'v2' => true })
      expect(nested).to eq([{ 'content' => [] }])
      client.cleanup
    end
  end
end

# Review round 3 (codex): behaviour the earlier examples pinned on one HTTP
# transport only, plus the distinctions four surviving mutations showed were
# unpinned -- legacy gating of the HeaderMismatch recovery, the sentinel
# escaping of an argument on the wire, and modern structured-output rejection.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — shared by both HTTP transports' do
  include_context 'with x-mcp-header wire helpers'

  def annotated_tool(header)
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header },
                                           'shard' => { 'type' => 'integer', 'x-mcp-header' => 'Shard' } } } }
  end

  def legacy_initialize(id)
    json_response(id, { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                        'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    context klass.name.split('::').last do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }

      after { server.cleanup }

      it 'refreshes tools/list and retries once after a HeaderMismatch, re-deriving the headers' do
        header = 'Region'
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << { headers: request.headers.to_h, body: body }
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          # Bounded, so the refresh is the only re-read in the sequence below:
          # an unbounded list on a 2026-07-28 server is stale on arrival, and
          # the retry would read it again to derive its own headers.
          when 'tools/list'
            json_response(body['id'], { 'tools' => [annotated_tool(header)], 'ttlMs' => 60_000 })
          when 'tools/call'
            if request.headers['Mcp-Param-Zone']
              json_response(body['id'], { 'content' => [] })
            else
              header = 'Zone'
              header_mismatch(body['id'], 'Mcp-Param-Zone missing')
            end
          end
        end

        expect(server.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

        expect(requests.map { |r| r[:body]['method'] })
          .to eq(%w[server/discover tools/list tools/call tools/list tools/call])
        calls = calls_in(requests)
        expect(calls.map { |c| param_headers(c[:headers]) })
          .to eq([{ 'Mcp-Param-Region' => 'eu' }, { 'Mcp-Param-Zone' => 'eu' }])
      end

      it 'surfaces the second rejection in full, with its code, message and HTTP status' do
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << body['method']
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          when 'tools/list' then json_response(body['id'], { 'tools' => [annotated_tool('Region')] })
          else header_mismatch(body['id'], requests.count('tools/call') == 1 ? 'first' : 'second')
          end
        end

        error = nil
        begin
          server.call_tool('execute_sql', { 'region' => 'eu' })
        rescue MCPClient::Errors::HeaderMismatchError => e
          error = e
        end

        expect(error).not_to be_nil
        expect(error.message).to include('second').and include('400')
        expect(error.message).not_to include('first')
        expect(error.code).to eq(-32_020)
        expect(requests.count('tools/call')).to eq(2)
      end

      it 'does not refresh after a HeaderMismatch on a method other than tools/call' do
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << body['method']
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          else header_mismatch(body['id'], 'not a call')
          end
        end

        expect { server.list_tools }.to raise_error(MCPClient::Errors::HeaderMismatchError)
        expect(requests.count('tools/list')).to eq(1)
      end

      it 'does not refresh after an ordinary server error on tools/call' do
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << body['method']
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          when 'tools/list' then json_response(body['id'], { 'tools' => [annotated_tool('Region')] })
          else
            { status: 200, headers: { 'Content-Type' => 'application/json' },
              body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                  'error' => { 'code' => -32_602, 'message' => 'Invalid params' }) }
          end
        end

        expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }.to raise_error(MCPClient::Errors::MCPError)
        expect(requests.count('tools/call')).to eq(1)
        expect(requests.count('tools/list')).to eq(1)
      end

      it 'rejects an argument that cannot be mirrored before the call goes out' do
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << body['method']
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          when 'tools/list' then json_response(body['id'], { 'tools' => [annotated_tool('Region')] })
          else json_response(body['id'], { 'content' => [] })
          end
        end
        server.list_tools

        [[{ 'region' => { 'nested' => 1 } }, /primitive/], [[1, 2], /primitive/],
         [{ 'shard' => Float::INFINITY }, /primitive/], [{ 'shard' => Float::NAN }, /primitive/],
         [{ 'shard' => 2**53 }, /safe/]].each do |value, message|
          args = value.is_a?(Hash) ? value : { 'region' => value }
          expect { server.call_tool('execute_sql', args) }
            .to raise_error(MCPClient::Errors::ValidationError, message), value.inspect
        end

        expect(requests).not_to include('tools/call')
      end

      # Mutation: not escaping a sentinel-shaped argument on the parameter
      # path. The wire values, not the encoder in isolation, are what an
      # intermediary reads back.
      it 'encodes every argument on the wire the way the value-encoding rules require' do
        tool = { 'name' => 'encode', 'inputSchema' => {
          'type' => 'object',
          'properties' => { 'text' => { 'type' => 'string', 'x-mcp-header' => 'Text' },
                            'n' => { 'type' => 'integer', 'x-mcp-header' => 'N' },
                            'flag' => { 'type' => 'boolean', 'x-mcp-header' => 'Flag' } }
        } }
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << { headers: request.headers.to_h, body: body }
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          when 'tools/list' then json_response(body['id'], { 'tools' => [tool] })
          else json_response(body['id'], { 'content' => [] })
          end
        end
        server.list_tools

        cases = {
          # A value already shaped like the sentinel is itself encoded, so the
          # peer cannot mistake it for an encoded one.
          { 'text' => '=?base64?literal?=' } => { 'Mcp-Param-Text' => '=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=' },
          { 'text' => '' } => { 'Mcp-Param-Text' => '=?base64??=' },
          { 'text' => "a\r\nb" } => { 'Mcp-Param-Text' => '=?base64?YQ0KYg==?=' },
          { 'text' => 'Hello, 世界' } => { 'Mcp-Param-Text' => '=?base64?SGVsbG8sIOS4lueVjA==?=' },
          { 'text' => 'us-west1' } => { 'Mcp-Param-Text' => 'us-west1' },
          { 'flag' => false } => { 'Mcp-Param-Flag' => 'false' },
          { 'n' => 0 } => { 'Mcp-Param-N' => '0' },
          { 'n' => 42.0 } => { 'Mcp-Param-N' => '42' }
        }
        cases.each do |args, expected|
          requests.clear
          server.call_tool('encode', args)
          expect(param_headers(calls_in(requests).first[:headers])).to eq(expected), args.inspect
        end
      end

      # Mutation: allowing the HeaderMismatch recovery on a legacy session.
      # The Mcp-Param namespace does not exist there, so there is nothing to
      # re-derive and the rejection is simply the server's answer.
      it 'never refreshes or retries after a HeaderMismatch on a legacy session' do
        requests = []
        stub_request(:get, url).to_return(status: 405, body: '')
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << body['method']
          case body['method']
          when 'initialize' then legacy_initialize(body['id'])
          when 'notifications/initialized' then { status: 202, body: '' }
          when 'tools/list' then json_response(body['id'], { 'tools' => [annotated_tool('Region')] })
          else header_mismatch(body['id'], 'Mcp-Param-Zone missing')
          end
        end
        legacy = klass.new(base_url: base_url, endpoint: endpoint, retries: 0, protocol: :legacy)

        expect { legacy.call_tool('execute_sql', { 'region' => 'eu' }) }
          .to raise_error(MCPClient::Errors::HeaderMismatchError, /Mcp-Param-Zone missing/)

        expect(requests.count('tools/call')).to eq(1)
        expect(requests).not_to include('tools/list')
        legacy.cleanup
      end
    end
  end
end

# Mutation: disabling structured-output validation on a modern session. Every
# other modern example expects acceptance, so a client that validated nothing
# would still pass them.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — modern structured-output rejection' do
  include_context 'with x-mcp-header wire helpers'

  def tool(header, required)
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } },
      'outputSchema' => { 'type' => 'object', 'properties' => { required => { 'type' => 'boolean' } },
                          'required' => [required] } }
  end

  it 'rejects a retry result the refreshed definition forbids, naming the refreshed requirement' do
    listed = tool('Region', 'v1')
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], { 'tools' => [listed] })
      when 'tools/call'
        if request.headers['Mcp-Param-Zone']
          json_response(body['id'], { 'content' => [], 'structuredContent' => { 'v1' => true } })
        else
          listed = tool('Zone', 'v2')
          header_mismatch(body['id'], 'Mcp-Param-Zone missing')
        end
      end
    end
    client = MCPClient::Client.new(
      mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
      validate_structured_content: :strict, logger: Logger.new(File::NULL)
    )

    expect { client.call_tool('execute_sql', { 'region' => 'eu' }) }
      .to raise_error(MCPClient::Errors::ValidationError, /missing required property 'v2'/)
    client.cleanup
  end
end

# Review round 3 (codex): the changed list-cache path is also the paginated
# one, and a refresh may take an annotation away as easily as add one.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — paginated and shrinking lists' do
  include_context 'with x-mcp-header wire helpers'

  let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

  after { server.cleanup }

  def plain_tool(name)
    { 'name' => name, 'inputSchema' => { 'type' => 'object' } }
  end

  def annotated_tool(header)
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } } }
  end

  it 'mirrors an annotated tool that only appears on a later page of tools/list' do
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers.to_h, body: body }
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list'
        # Both pages carry the bound (the combined entry takes the shortest),
        # so the call below mirrors from the list already followed rather than
        # walking the pages again.
        if body['params']['cursor']
          json_response(body['id'], { 'tools' => [annotated_tool('Region')], 'ttlMs' => 60_000 })
        else
          json_response(body['id'],
                        { 'tools' => [plain_tool('first')], 'nextCursor' => 'page2', 'ttlMs' => 60_000 })
        end
      else json_response(body['id'], { 'content' => [] })
      end
    end

    expect(server.list_tools.map(&:name)).to eq(%w[first execute_sql])
    server.call_tool('execute_sql', { 'region' => 'eu' })

    expect(requests.count { |r| r[:body]['method'] == 'tools/list' }).to eq(2)
    expect(param_headers(calls_in(requests).first[:headers])).to eq({ 'Mcp-Param-Region' => 'eu' })
  end

  it 'sends no mirrored header when the refreshed definition drops the annotation' do
    annotated = true
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers.to_h, body: body }
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list'
        json_response(body['id'], { 'tools' => [annotated ? annotated_tool('Region') : plain_tool('execute_sql')] })
      when 'tools/call'
        if param_headers(request.headers).empty?
          json_response(body['id'], { 'content' => [] })
        else
          annotated = false
          header_mismatch(body['id'], 'Mcp-Param-Region is not expected')
        end
      end
    end

    expect(server.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

    calls = calls_in(requests)
    expect(calls.size).to eq(2)
    expect(param_headers(calls[0][:headers])).to eq({ 'Mcp-Param-Region' => 'eu' })
    expect(param_headers(calls[1][:headers])).to be_empty
  end

  it 'fails the call when the refreshed definition no longer carries the tool at all' do
    listed = [annotated_tool('Region')]
    requests = []
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << body['method']
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], { 'tools' => listed })
      when 'tools/call'
        listed = []
        header_mismatch(body['id'], 'Mcp-Param-Zone missing')
      end
    end

    # The retry still goes out -- the server, not the client, decides whether an
    # unlisted tool exists -- but it carries no mirrored header to re-derive.
    expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }
      .to raise_error(MCPClient::Errors::HeaderMismatchError)
    expect(requests.count('tools/call')).to eq(2)
  end
end

# Review round 3 (codex): the notification-driven cache invalidation this PR
# added covers prompts and resources as well as tools, and the plain HTTP
# dispatcher only started calling it here.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — list_changed invalidation on both HTTP transports' do
  include_context 'with x-mcp-header wire helpers'

  def full_discover
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  { MCPClient::ServerHTTP => :dispatch_sse_message,
    MCPClient::ServerStreamableHTTP => :dispatch_server_message }.each do |klass, dispatcher|
    context klass.name.split('::').last do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }

      after { server.cleanup }

      def notify(server, dispatcher, method)
        server.send(dispatcher, { 'jsonrpc' => '2.0', 'method' => method, 'params' => {} })
      end

      it 'drops each cache only on its own list_changed notification' do
        counts = Hash.new(0)
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          counts[body['method']] += 1
          n = counts[body['method']]
          # Each list is bounded, so there is a cache for a notification to
          # drop: a 2026-07-28 server that sends no ttlMs means "assume 0",
          # and every list would then be re-read whatever was invalidated.
          case body['method']
          when 'server/discover' then json_response(body['id'], full_discover)
          when 'tools/list'
            json_response(body['id'], { 'tools' => [{ 'name' => "t#{n}" }], 'ttlMs' => 60_000 })
          when 'prompts/list'
            json_response(body['id'], { 'prompts' => [{ 'name' => "p#{n}" }], 'ttlMs' => 60_000 })
          when 'resources/list'
            json_response(body['id'], { 'resources' => [{ 'uri' => "file:///r#{n}", 'name' => "r#{n}" }],
                                        'ttlMs' => 60_000 })
          end
        end

        expect(server.list_tools.map(&:name)).to eq(['t1'])
        expect(server.list_prompts.map(&:name)).to eq(['p1'])
        expect(server.list_resources['resources'].map(&:name)).to eq(['r1'])

        # A tools change leaves the other two caches alone.
        notify(server, dispatcher, 'notifications/tools/list_changed')
        expect(server.list_tools.map(&:name)).to eq(['t2'])
        expect(server.list_prompts.map(&:name)).to eq(['p1'])
        expect(server.list_resources['resources'].map(&:name)).to eq(['r1'])

        notify(server, dispatcher, 'notifications/prompts/list_changed')
        expect(server.list_prompts.map(&:name)).to eq(['p2'])

        notify(server, dispatcher, 'notifications/resources/list_changed')
        expect(server.list_resources['resources'].map(&:name)).to eq(['r2'])
        expect(server.list_tools.map(&:name)).to eq(['t2'])
      end
    end
  end
end
