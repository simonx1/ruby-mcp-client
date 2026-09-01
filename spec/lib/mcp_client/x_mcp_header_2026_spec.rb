# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 Streamable HTTP "Custom Headers from Tool Parameters"
# (SEP-2243): a tool's inputSchema may mark primitive, statically reachable
# properties with `x-mcp-header`; clients on Streamable HTTP MUST mirror the
# argument values into `Mcp-Param-{name}` headers, MUST reject tool
# definitions whose annotations violate the constraints (dropping them from
# tools/list with a warning), and SHOULD refresh tools/list and retry once
# after a HeaderMismatch rejection.
RSpec.describe 'MCP 2026-07-28 x-mcp-header custom headers' do
  describe MCPClient::HeaderParams do
    def schema(properties, extra = {})
      { 'type' => 'object', 'properties' => properties }.merge(extra)
    end

    describe '.validate_schema' do
      it 'accepts the specification example' do
        input = schema('region' => { 'type' => 'string', 'x-mcp-header' => 'Region' },
                       'query' => { 'type' => 'string' })
        expect(described_class.validate_schema(input)).to eq([])
      end

      it 'accepts annotations on nested object properties reached only via properties keys' do
        input = schema('db' => { 'type' => 'object',
                                 'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' } } })
        expect(described_class.validate_schema(input)).to eq([])
      end

      it 'accepts integer and boolean properties' do
        input = schema('n' => { 'type' => 'integer', 'x-mcp-header' => 'N' },
                       'flag' => { 'type' => 'boolean', 'x-mcp-header' => 'Flag' })
        expect(described_class.validate_schema(input)).to eq([])
      end

      it 'rejects an empty or non-string value' do
        expect(described_class.validate_schema(schema('a' => { 'type' => 'string', 'x-mcp-header' => '' })))
          .to include(match(/empty/))
        expect(described_class.validate_schema(schema('a' => { 'type' => 'string', 'x-mcp-header' => 42 })))
          .to include(match(/string/))
      end

      it 'rejects values that are not HTTP field-name tokens' do
        ['Reg ion', 'Region:', "Reg\nion", "Reg\rion", 'Région', 'a/b', '(x)'].each do |bad|
          errors = described_class.validate_schema(schema('a' => { 'type' => 'string', 'x-mcp-header' => bad }))
          expect(errors).not_to be_empty, "expected #{bad.inspect} to be rejected"
        end
      end

      it 'accepts every tchar' do
        token = "!#$%&'*+-.^_`|~09AZaz"
        expect(described_class.validate_schema(schema('a' => { 'type' => 'string', 'x-mcp-header' => token })))
          .to eq([])
      end

      it 'rejects case-insensitive duplicates' do
        input = schema('a' => { 'type' => 'string', 'x-mcp-header' => 'Region' },
                       'b' => { 'type' => 'string', 'x-mcp-header' => 'REGION' })
        expect(described_class.validate_schema(input)).to include(match(/unique/i))
      end

      it 'rejects number, array, object, missing and multi-typed properties' do
        [{ 'type' => 'number' }, { 'type' => 'array', 'items' => { 'type' => 'string' } },
         { 'type' => 'object' }, {}, { 'type' => %w[string null] }].each do |prop|
          errors = described_class.validate_schema(schema('a' => prop.merge('x-mcp-header' => 'A')))
          expect(errors).to include(match(/primitive/)), "expected #{prop.inspect} to be rejected"
        end
      end

      it 'rejects annotations that are not statically reachable' do
        unreachable = [
          schema('list' => { 'type' => 'array', 'items' => { 'type' => 'string', 'x-mcp-header' => 'A' } }),
          schema({}, 'oneOf' => [{ 'properties' => { 'a' => { 'type' => 'string', 'x-mcp-header' => 'A' } } }]),
          schema({}, 'anyOf' => [{ 'properties' => { 'a' => { 'type' => 'string', 'x-mcp-header' => 'A' } } }]),
          schema({}, 'allOf' => [{ 'properties' => { 'a' => { 'type' => 'string', 'x-mcp-header' => 'A' } } }]),
          schema({}, 'not' => { 'properties' => { 'a' => { 'type' => 'string', 'x-mcp-header' => 'A' } } }),
          schema({}, 'if' => { 'properties' => { 'a' => { 'type' => 'string', 'x-mcp-header' => 'A' } } }),
          schema({}, 'then' => { 'properties' => { 'a' => { 'type' => 'string', 'x-mcp-header' => 'A' } } }),
          schema({}, '$defs' => { 'x' => { 'type' => 'string', 'x-mcp-header' => 'A' } }),
          schema({ 'a' => { '$ref' => '#/$defs/x' } },
                 '$defs' => { 'x' => { 'type' => 'string', 'x-mcp-header' => 'A' } }),
          schema({ 'a' => { 'type' => 'string' } }, 'x-mcp-header' => 'Root')
        ]
        unreachable.each do |input|
          errors = described_class.validate_schema(input)
          expect(errors).not_to be_empty, "expected #{input.inspect} to be rejected"
        end
      end

      it 'accepts schemas without any annotation, whatever else they contain' do
        input = schema({ 'a' => { 'type' => 'array', 'items' => { 'type' => 'string' } } },
                       'oneOf' => [{ 'required' => ['a'] }], '$defs' => { 'x' => { 'type' => 'number' } })
        expect(described_class.validate_schema(input)).to eq([])
        expect(described_class.validate_schema(nil)).to eq([])
      end
    end

    describe '.annotations' do
      it 'lists annotated property paths with their header names' do
        input = schema('region' => { 'type' => 'string', 'x-mcp-header' => 'Region' },
                       'db' => { 'type' => 'object',
                                 'properties' => { 'shard' => { 'type' => 'integer', 'x-mcp-header' => 'Shard' } } })
        expect(described_class.annotations(input)).to eq([[['region'], 'Region'], [%w[db shard], 'Shard']])
      end
    end

    describe '.headers_for' do
      let(:input) do
        schema('region' => { 'type' => 'string', 'x-mcp-header' => 'Region' },
               'shard' => { 'type' => 'integer', 'x-mcp-header' => 'Shard' },
               'dry' => { 'type' => 'boolean', 'x-mcp-header' => 'Dry-Run' },
               'db' => { 'type' => 'object',
                         'properties' => { 'tenant' => { 'type' => 'string', 'x-mcp-header' => 'Tenant' } } })
      end

      it 'mirrors present values, converting per type, and omits absent or null ones' do
        headers = described_class.headers_for(input, { 'region' => 'us-west1', 'shard' => 42, 'dry' => false,
                                                       'db' => { 'tenant' => nil } })
        expect(headers).to eq({ 'Mcp-Param-Region' => 'us-west1', 'Mcp-Param-Shard' => '42',
                                'Mcp-Param-Dry-Run' => 'false' })
      end

      it 'reads nested paths and symbol-keyed arguments' do
        headers = described_class.headers_for(input, { db: { tenant: 'acme' }, region: 'eu' })
        expect(headers).to eq({ 'Mcp-Param-Region' => 'eu', 'Mcp-Param-Tenant' => 'acme' })
      end

      it 'Base64-encodes values that are not header-safe' do
        headers = described_class.headers_for(input, { 'region' => 'Hello, 世界' })
        expect(headers).to eq({ 'Mcp-Param-Region' => '=?base64?SGVsbG8sIOS4lueVjA==?=' })
      end

      it 'rejects integers outside the IEEE754 safe range' do
        expect { described_class.headers_for(input, { 'shard' => 2**53 }) }
          .to raise_error(MCPClient::Errors::ValidationError, /safe/)
        min = -(2**53) + 1
        expect(described_class.headers_for(input, { 'shard' => min })).to eq({ 'Mcp-Param-Shard' => min.to_s })
      end

      it 'rejects values that cannot be mirrored (floats, objects, arrays)' do
        expect { described_class.headers_for(input, { 'shard' => 1.5 }) }
          .to raise_error(MCPClient::Errors::ValidationError, /primitive/)
        expect { described_class.headers_for(input, { 'region' => ['a'] }) }
          .to raise_error(MCPClient::Errors::ValidationError, /primitive/)
      end

      it 'returns no headers for a schema without annotations' do
        expect(described_class.headers_for({ 'type' => 'object' }, { 'a' => 1 })).to eq({})
        expect(described_class.headers_for(nil, { 'a' => 1 })).to eq({})
      end
    end
  end

  describe 'on the Streamable HTTP transport' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:server) do
      MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, logger: logger)
    end

    after { server.cleanup }

    def discover_result
      { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} },
        'ttlMs' => 0, 'cacheScope' => 'public' }
    end

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    def sql_tool(header: 'Region')
      { 'name' => 'execute_sql', 'description' => 'Execute SQL',
        'inputSchema' => { 'type' => 'object',
                           'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header },
                                             'query' => { 'type' => 'string' } },
                           'required' => %w[region query] } }
    end

    def nested_tool
      { 'name' => 'nested', 'inputSchema' => {
        'type' => 'object',
        'properties' => { 'db' => { 'type' => 'object',
                                    'properties' => { 'tenant' => { 'type' => 'string', 'x-mcp-header' => 'Tenant' },
                                                      'shard' => { 'type' => 'integer',
                                                                   'x-mcp-header' => 'Shard' } } } }
      } }
    end

    def broken_tool
      { 'name' => 'broken', 'inputSchema' => { 'type' => 'object',
                                               'properties' => { 'a' => { 'type' => 'number',
                                                                          'x-mcp-header' => 'A' } } } }
    end

    def stub_server(tools:, call: nil)
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << { headers: request.headers, body: body }
        case body['method']
        when 'server/discover' then json_response(body['id'], discover_result)
        when 'tools/list' then json_response(body['id'], { 'tools' => tools.respond_to?(:call) ? tools.call : tools })
        when 'tools/call'
          call ? call.call(body, requests) : json_response(body['id'], { 'content' => [] })
        else raise "unexpected #{body['method']}"
        end
      end
      requests
    end

    it 'drops tools with an invalid x-mcp-header annotation from tools/list, with a warning naming the tool' do
      stub_server(tools: [sql_tool, broken_tool])

      names = server.list_tools.map(&:name)

      expect(names).to eq(['execute_sql'])
      expect(log_output.string).to match(/WARN.*broken.*x-mcp-header/)
    end

    it 'mirrors annotated arguments into Mcp-Param-{name} headers on tools/call' do
      requests = stub_server(tools: [sql_tool, nested_tool])

      server.list_tools
      server.call_tool('execute_sql', { 'region' => 'us-west1', 'query' => 'SELECT 1' })
      server.call_tool('nested', { 'db' => { 'tenant' => 'acme', 'shard' => 7 } })

      calls = requests.select { |r| r[:body]['method'] == 'tools/call' }
      expect(calls[0][:headers]['Mcp-Param-Region']).to eq('us-west1')
      expect(calls[0][:headers]['Mcp-Name']).to eq('execute_sql')
      expect(calls[0][:headers].keys.grep(/\AMcp-Param-/)).to eq(['Mcp-Param-Region'])
      expect(calls[1][:headers]['Mcp-Param-Tenant']).to eq('acme')
      expect(calls[1][:headers]['Mcp-Param-Shard']).to eq('7')
    end

    it 'omits the header when the argument is absent or null' do
      requests = stub_server(tools: [nested_tool])

      server.list_tools
      server.call_tool('nested', { 'db' => { 'tenant' => nil } })

      call = requests.find { |r| r[:body]['method'] == 'tools/call' }
      expect(call[:headers].keys.grep(/\AMcp-Param-/)).to be_empty
    end

    it 'Base64-encodes a value that is not header-safe' do
      requests = stub_server(tools: [sql_tool])

      server.list_tools
      server.call_tool('execute_sql', { 'region' => ' padded ', 'query' => 'x' })

      call = requests.find { |r| r[:body]['method'] == 'tools/call' }
      expect(call[:headers]['Mcp-Param-Region']).to eq('=?base64?IHBhZGRlZCA=?=')
    end

    it 'fetches the tool list itself when tools/call is issued before tools/list' do
      requests = stub_server(tools: [sql_tool])

      server.call_tool('execute_sql', { 'region' => 'eu', 'query' => 'x' })

      expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover tools/list tools/call])
      expect(requests.last[:headers]['Mcp-Param-Region']).to eq('eu')
    end

    it 'refreshes tools/list and retries once after a HeaderMismatch rejection' do
      current_header = 'Region'
      requests = stub_server(
        tools: -> { [sql_tool(header: current_header)] },
        call: lambda do |body, all|
          if all.one? { |r| r[:body]['method'] == 'tools/call' }
            current_header = 'Zone'
            { status: 400, headers: { 'Content-Type' => 'application/json' },
              body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                  'error' => { 'code' => -32_020,
                                               'message' => 'Header mismatch: Mcp-Param-Zone missing' }) }
          else
            json_response(body['id'], { 'content' => [] })
          end
        end
      )

      server.list_tools
      result = server.call_tool('execute_sql', { 'region' => 'eu', 'query' => 'x' })

      expect(result).to eq({ 'content' => [] })
      expect(requests.map { |r| r[:body]['method'] })
        .to eq(%w[server/discover tools/list tools/call tools/list tools/call])
      calls = requests.select { |r| r[:body]['method'] == 'tools/call' }
      expect(calls[0][:headers]['Mcp-Param-Region']).to eq('eu')
      expect(calls[1][:headers]['Mcp-Param-Zone']).to eq('eu')
      expect(calls[1][:headers]).not_to have_key('Mcp-Param-Region')
      expect(calls[0][:body]['id']).not_to eq(calls[1][:body]['id'])
      expect(server.list_tools.first.schema['properties']['region']['x-mcp-header']).to eq('Zone')
    end

    it 'gives up after a second HeaderMismatch and raises the typed error' do
      requests = stub_server(
        tools: [sql_tool],
        call: lambda do |body, _all|
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_020, 'message' => 'Header mismatch' }) }
        end
      )

      expect { server.call_tool('execute_sql', { 'region' => 'eu', 'query' => 'x' }) }
        .to raise_error(MCPClient::Errors::HeaderMismatchError)
      expect(requests.count { |r| r[:body]['method'] == 'tools/call' }).to eq(2)
    end

    it 'rejects a call whose annotated argument cannot be mirrored before sending it' do
      requests = stub_server(tools: [nested_tool])

      server.list_tools
      expect { server.call_tool('nested', { 'db' => { 'shard' => 2**60 } }) }
        .to raise_error(MCPClient::Errors::ValidationError, /safe/)
      expect(requests.map { |r| r[:body]['method'] }).not_to include('tools/call')
    end

    it 'leaves legacy sessions alone: no rejection, no Mcp-Param headers' do
      requests = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        requests << { headers: request.headers, body: body }
        case body['method']
        when 'server/discover' then { status: 400, body: 'Bad Request' }
        when 'initialize'
          json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                                      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
        when 'notifications/initialized' then { status: 202, body: '' }
        when 'tools/list' then json_response(body['id'], { 'tools' => [sql_tool, broken_tool] })
        when 'tools/call' then json_response(body['id'], { 'content' => [] })
        end
      end
      stub_request(:get, url).to_return(status: 405, body: '')

      expect(server.list_tools.map(&:name)).to eq(%w[execute_sql broken])
      server.call_tool('execute_sql', { 'region' => 'eu', 'query' => 'x' })
      call = requests.find { |r| r[:body]['method'] == 'tools/call' }
      expect(call[:headers].keys.grep(/\AMcp-Param-/)).to be_empty
    end
  end

  describe 'on the plain HTTP transport' do
    let(:server) { MCPClient::ServerHTTP.new(base_url: 'https://example.com', endpoint: '/mcp', retries: 0) }

    after { server.cleanup }

    it 'mirrors annotated arguments too' do
      requests = []
      stub_request(:post, 'https://example.com/mcp').to_return do |request|
        body = JSON.parse(request.body)
        requests << { headers: request.headers, body: body }
        result = case body['method']
                 when 'server/discover'
                   { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => {} }
                 when 'tools/list'
                   { 'tools' => [{ 'name' => 't', 'inputSchema' => {
                     'type' => 'object', 'properties' => { 'k' => { 'type' => 'boolean', 'x-mcp-header' => 'K' } }
                   } }] }
                 else { 'content' => [] }
                 end
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end

      server.call_tool('t', { 'k' => true })

      expect(requests.last[:headers]['Mcp-Param-K']).to eq('true')
    end
  end

  describe 'on stdio' do
    it 'ignores x-mcp-header annotations entirely (they only concern the HTTP transport)' do
      server = MCPClient::ServerStdio.new(command: 'echo test')
      server.instance_variable_set(:@initialized, true)
      server.instance_variable_set(:@protocol_version, '2026-07-28')
      allow(server).to receive(:send_request)
      allow(server).to receive(:wait_response).and_return(
        { 'jsonrpc' => '2.0', 'id' => 1,
          'result' => { 'tools' => [{ 'name' => 'broken', 'inputSchema' => {
            'type' => 'object', 'properties' => { 'a' => { 'type' => 'number', 'x-mcp-header' => 'A' } }
          } }] } }
      )

      expect(server.list_tools.map(&:name)).to eq(['broken'])
    end
  end
end

# Review (codex): instance data inside a schema (default, examples, enum,
# const) is not a schema, so an "x-mcp-header" key there is not an
# annotation; and a HeaderMismatch refresh must reach the client-level
# tool cache and the in-flight call.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — review follow-ups' do
  describe MCPClient::HeaderParams do
    it 'ignores x-mcp-header keys inside instance data (default, examples, enum, const)' do
      schema = { 'type' => 'object',
                 'properties' => {
                   'cfg' => { 'type' => 'object', 'default' => { 'x-mcp-header' => 'literal' },
                              'examples' => [{ 'x-mcp-header' => 'literal' }],
                              'const' => { 'x-mcp-header' => 'x' }, 'enum' => [{ 'x-mcp-header' => 'y' }] },
                   'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' }
                 } }
      expect(described_class.validate_schema(schema)).to eq([])
      expect(described_class.annotations(schema)).to eq([[['region'], 'Region']])
    end

    it 'still walks every schema-bearing keyword for misplaced annotations' do
      %w[additionalProperties contains propertyNames unevaluatedProperties].each do |keyword|
        schema = { 'type' => 'object',
                   'properties' => { 'a' => { 'type' => 'object',
                                              keyword => { 'type' => 'string', 'x-mcp-header' => 'A' } } } }
        expect(described_class.validate_schema(schema)).not_to be_empty, keyword
      end
      %w[patternProperties dependentSchemas definitions].each do |keyword|
        schema = { 'type' => 'object', keyword => { 'k' => { 'type' => 'string', 'x-mcp-header' => 'A' } } }
        expect(described_class.validate_schema(schema)).not_to be_empty, keyword
      end
      schema = { 'type' => 'object', 'prefixItems' => [{ 'type' => 'string', 'x-mcp-header' => 'A' }] }
      expect(described_class.validate_schema(schema)).not_to be_empty
    end
  end

  describe 'HeaderMismatch refresh through MCPClient::Client' do
    let(:url) { 'https://example.com/mcp' }

    it 'invalidates the client tool cache and validates the in-flight call against the refreshed tool' do
      current = 'Region'
      current_output = { 'type' => 'object', 'properties' => { 'ok' => { 'type' => 'boolean' } },
                         'required' => ['ok'] }
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        result = case body['method']
                 when 'server/discover'
                   { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'], 'capabilities' => { 'tools' => {} } }
                 when 'tools/list'
                   { 'tools' => [{ 'name' => 'execute_sql',
                                   'inputSchema' => { 'type' => 'object',
                                                      'properties' => { 'region' => { 'type' => 'string',
                                                                                      'x-mcp-header' => current } } },
                                   'outputSchema' => current_output }] }
                 when 'tools/call'
                   if request.headers['Mcp-Param-Zone']
                     { 'content' => [], 'structuredContent' => { 'rows' => 1 } }
                   else
                     current = 'Zone'
                     current_output = { 'type' => 'object', 'properties' => { 'rows' => { 'type' => 'integer' } },
                                        'required' => ['rows'] }
                     next { status: 400, headers: { 'Content-Type' => 'application/json' },
                            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                                'error' => { 'code' => -32_020, 'message' => 'Header mismatch' }) }
                   end
                 end
        { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'], 'result' => result),
          headers: { 'Content-Type' => 'application/json' } }
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: 'https://example.com', endpoint: '/mcp',
                                                              retries: 0)],
        validate_structured_content: :strict
      )

      result = client.call_tool('execute_sql', { 'region' => 'eu' })

      expect(result['structuredContent']).to eq({ 'rows' => 1 })
      expect(client.list_tools.first.schema['properties']['region']['x-mcp-header']).to eq('Zone')
      client.cleanup
    end
  end
end
