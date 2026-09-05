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
    client.on_notification do |_srv, method, _params|
      listed = tool_with_output(object_schema('v3'), header: 'Zone') if method.end_with?('list_changed')
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
