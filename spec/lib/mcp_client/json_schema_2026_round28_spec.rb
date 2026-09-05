# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 JSON Schema handling, twenty-eighth round.
#
# MCP 2026-07-28 basic "Implementation Requirements" makes 2020-12 support
# mandatory, and a validator that leaves a standard assertion unevaluated
# does not merely report less: it accepts instances the schema rejects.
# `{"allOf": [{"multipleOf": 3}]}` admitted 4, `{"not": {"multipleOf": 2}}`
# admitted 4, `uniqueItems` admitted `[1, 1]` and `contains` was decided by
# the array's length alone. The assertions and applicators whose verdict does
# not depend on annotations collected across a composition are now evaluated,
# and only the annotation-driven ones (`unevaluatedItems`,
# `unevaluatedProperties`), the dynamic references and `format` are left to
# the partial-coverage report.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 28' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:draft2019) { 'https://json-schema.org/draft/2019-09/schema' }

  describe 'multipleOf' do
    it 'asserts on its own and inside every composition' do
      expect(validator.validate(4, { 'multipleOf' => 3 })).to contain_exactly(a_string_matching(/multiple of 3/))
      expect(validator.validate(6, { 'multipleOf' => 3 })).to be_empty
      expect(validator.validate(4, { 'allOf' => [{ 'multipleOf' => 3 }] }))
        .to contain_exactly(a_string_matching(%r{allOf/0}))
      expect(validator.validate(4, { 'anyOf' => [{ 'multipleOf' => 3 }] }))
        .to contain_exactly(a_string_matching(/anyOf/))
      expect(validator.validate(4, { 'not' => { 'multipleOf' => 2 } }))
        .to contain_exactly(a_string_matching(/not/))
      # The condition is decided now, so `then` is applied rather than skipped.
      conditional = { 'if' => { 'multipleOf' => 2 }, 'then' => { 'type' => 'string' },
                      'else' => { 'type' => 'integer' } }
      expect(validator.validate(4, conditional)).to contain_exactly(a_string_matching(/expected type string/))
      expect(validator.validate(3, conditional)).to be_empty
    end

    it 'divides exactly rather than in binary floating point' do
      expect(validator.validate(0.0075, { 'multipleOf' => 0.0001 })).to be_empty
      expect(validator.validate(1.5, { 'multipleOf' => 0.5 })).to be_empty
      expect(validator.validate(1.6, { 'multipleOf' => 0.5 })).to contain_exactly(a_string_matching(/multiple of/))
      # Applies to numbers only.
      expect(validator.validate('4', { 'multipleOf' => 3 })).to be_empty
    end

    it 'refuses a schema whose multipleOf is not a positive number' do
      expect(validator.check_schema({ 'multipleOf' => 0 })).to contain_exactly(a_string_matching(/multipleOf/))
      expect(validator.check_schema({ 'multipleOf' => -2 })).to contain_exactly(a_string_matching(/multipleOf/))
      expect(validator.check_schema({ 'multipleOf' => 'two' })).to contain_exactly(a_string_matching(/multipleOf/))
      expect(validator.check_schema({ 'multipleOf' => 0.5 })).to be_empty
    end
  end

  describe 'uniqueItems' do
    it 'rejects equal items, comparing JSON values rather than Ruby objects' do
      expect(validator.validate([1, 1], { 'uniqueItems' => true })).to contain_exactly(a_string_matching(/unique/))
      # JSON Schema equality: 1 and 1.0 are the same number.
      expect(validator.validate([1, 1.0], { 'uniqueItems' => true })).to contain_exactly(a_string_matching(/unique/))
      expect(validator.validate([{ 'a' => 1, 'b' => 2 }, { 'b' => 2, 'a' => 1 }], { 'uniqueItems' => true }))
        .to contain_exactly(a_string_matching(/unique/))
      expect(validator.validate([1, true], { 'uniqueItems' => true })).to be_empty
      expect(validator.validate([1, 2], { 'uniqueItems' => true })).to be_empty
      expect(validator.validate([1, 1], { 'uniqueItems' => false })).to be_empty
    end

    it 'decides a not branch that only uniqueItems can settle' do
      expect(validator.validate([1, 1], { 'not' => { 'uniqueItems' => true } })).to be_empty
      expect(validator.validate([1, 2], { 'not' => { 'uniqueItems' => true } }))
        .to contain_exactly(a_string_matching(/not/))
    end
  end

  describe 'contains' do
    it 'matches item by item instead of reading the array length alone' do
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' } }))
        .to contain_exactly(a_string_matching(/at least 1 items matching contains/))
      expect(validator.validate([1, 'x'], { 'contains' => { 'type' => 'string' } })).to be_empty
      expect(validator.validate([1, 'x', 'y'], { 'contains' => { 'type' => 'string' }, 'maxContains' => 1 }))
        .to contain_exactly(a_string_matching(/at most 1 items matching contains/))
      expect(validator.validate(%w[x y], { 'contains' => { 'type' => 'string' }, 'minContains' => 3 }))
        .to contain_exactly(a_string_matching(/at least 3 items matching contains/))
      # minContains 0 switches the lower bound off entirely.
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' }, 'minContains' => 0 })).to be_empty
    end

    it 'decides a composition that turns on contains' do
      expect(validator.validate([1, 2], { 'not' => { 'contains' => { 'type' => 'integer' } } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate([1, 2], { 'not' => { 'contains' => { 'type' => 'string' } } })).to be_empty
    end

    it 'refuses a schema whose contains bounds are not non-negative integers' do
      expect(validator.check_schema({ 'contains' => true, 'minContains' => -1 }))
        .to contain_exactly(a_string_matching(/minContains/))
      expect(validator.check_schema({ 'contains' => true, 'maxContains' => 1.5 }))
        .to contain_exactly(a_string_matching(/maxContains/))
      # draft-07 does not define the bounds, so nothing there is malformed.
      expect(validator.check_schema({ '$schema' => draft7, 'contains' => true, 'minContains' => -1 })).to be_empty
    end
  end

  describe 'object assertions' do
    it 'applies property counts and dependent requirements' do
      expect(validator.validate({}, { 'minProperties' => 1 })).to contain_exactly(a_string_matching(/minProperties/))
      expect(validator.validate({ 'a' => 1, 'b' => 2 }, { 'maxProperties' => 1 }))
        .to contain_exactly(a_string_matching(/maxProperties/))
      dependent = { 'dependentRequired' => { 'card' => ['billing'] } }
      expect(validator.validate({ 'card' => 1 }, dependent)).to contain_exactly(a_string_matching(/billing/))
      expect(validator.validate({ 'card' => 1, 'billing' => 2 }, dependent)).to be_empty
      expect(validator.validate({ 'billing' => 2 }, dependent)).to be_empty
      # draft-07 spells the same assertion `dependencies`.
      legacy = { '$schema' => draft7, 'dependencies' => { 'card' => ['billing'] } }
      expect(validator.validate({ 'card' => 1 }, legacy)).to contain_exactly(a_string_matching(/billing/))
    end

    it 'applies patternProperties, additionalProperties and propertyNames' do
      schema = { 'properties' => { 'a' => { 'type' => 'integer' } },
                 'patternProperties' => { '\Ax' => { 'type' => 'string' } },
                 'additionalProperties' => false }
      expect(validator.validate({ 'a' => 1, 'xy' => 'ok' }, schema)).to be_empty
      expect(validator.validate({ 'xy' => 3 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
      expect(validator.validate({ 'zz' => 1 }, schema)).to contain_exactly(a_string_matching(/not allowed/))

      typed = { 'additionalProperties' => { 'type' => 'integer' } }
      expect(validator.validate({ 'z' => 'x' }, typed)).to contain_exactly(a_string_matching(/expected type integer/))
      names = { 'propertyNames' => { 'maxLength' => 2 } }
      expect(validator.validate({ 'ab' => 1 }, names)).to be_empty
      expect(validator.validate({ 'abc' => 1 }, names)).to contain_exactly(a_string_matching(/propertyNames/))
    end

    it 'applies the schema form of a dependency to the same instance' do
      schema = { 'dependentSchemas' => { 'card' => { 'required' => ['billing'] } } }
      expect(validator.validate({ 'card' => 1 }, schema)).to contain_exactly(a_string_matching(/billing/))
      expect(validator.validate({ 'card' => 1, 'billing' => 2 }, schema)).to be_empty
      expect(validator.validate({ 'other' => 1 }, schema)).to be_empty
      legacy = { '$schema' => draft7, 'dependencies' => { 'card' => { 'required' => ['billing'] } } }
      expect(validator.validate({ 'card' => 1 }, legacy)).to contain_exactly(a_string_matching(/billing/))
    end

    it 'refuses malformed property-count and dependency values' do
      expect(validator.check_schema({ 'minProperties' => -1 }))
        .to contain_exactly(a_string_matching(/minProperties/))
      expect(validator.check_schema({ 'maxProperties' => 'lots' }))
        .to contain_exactly(a_string_matching(/maxProperties/))
      expect(validator.check_schema({ 'uniqueItems' => 'yes' })).to contain_exactly(a_string_matching(/uniqueItems/))
      expect(validator.check_schema({ 'dependentRequired' => { 'a' => 'b' } }))
        .to contain_exactly(a_string_matching(/dependentRequired/))
    end
  end

  describe 'draft-07 additionalItems' do
    it 'applies the tuple tail schema' do
      schema = { '$schema' => draft7, 'items' => [{ 'type' => 'integer' }], 'additionalItems' => false }
      expect(validator.validate([1], schema)).to be_empty
      expect(validator.validate([1, 2], schema)).to contain_exactly(a_string_matching(/not allowed/))
      typed = { '$schema' => draft2019, 'items' => [{ 'type' => 'integer' }],
                'additionalItems' => { 'type' => 'string' } }
      expect(validator.validate([1, 'x'], typed)).to be_empty
      expect(validator.validate([1, 2], typed)).to contain_exactly(a_string_matching(/expected type string/))
    end
  end

  describe 'identifier collisions' do
    it 'refuses a document whose resources declare the same URI' do
      schema = { '$ref' => 'urn:s',
                 '$defs' => { 'a' => { '$id' => 'urn:s', 'type' => 'string' },
                              'b' => { '$id' => 'urn:s', 'type' => 'integer' } } }
      # Which declaration a reference lands on would otherwise depend on the
      # order the walk met them in.
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/urn:s.*more than once/))
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/urn:s.*more than once/))
      distinct = { '$ref' => 'urn:s',
                   '$defs' => { 'a' => { '$id' => 'urn:s', 'type' => 'string' },
                                'b' => { '$id' => 'urn:t', 'type' => 'integer' } } }
      expect(validator.check_schema(distinct)).to be_empty
    end

    it 'refuses an $id carrying a non-empty fragment, and a malformed anchor' do
      expect(validator.check_schema({ '$id' => 'urn:root#bad', 'type' => 'integer' }))
        .to contain_exactly(a_string_matching(/\$id.*fragment/))
      expect(validator.check_schema({ '$id' => 'urn:root#', 'type' => 'integer' })).to be_empty
      expect(validator.check_schema({ '$anchor' => 'not a name' }))
        .to contain_exactly(a_string_matching(/\$anchor must be a plain name/))
      # draft-07 spells a plain-name identifier as a bare fragment.
      expect(validator.check_schema({ '$schema' => draft7, '$id' => '#name', 'type' => 'integer' })).to be_empty
      expect(validator.check_schema({ '$id' => 5 })).to contain_exactly(a_string_matching(/\$id/))
    end

    it 'refuses duplicate names in required and dependentRequired' do
      expect(validator.check_schema({ 'required' => %w[a a] })).to contain_exactly(a_string_matching(/required/))
      expect(validator.check_schema({ 'dependentRequired' => { 'a' => %w[b b] } }))
        .to contain_exactly(a_string_matching(/dependentRequired/))
    end
  end

  describe 'references written as absolute URIs into the bundled document' do
    def bool_bag(spelling)
      bools = {}
      props = {}
      1100.times do |i|
        bools["b#{i}"] = true
        props["p#{i}"] = { '$ref' => format(spelling, i) }
      end
      { '$id' => 'urn:root', 'x-bools' => bools, 'properties' => props }
    end

    it 'charges a boolean target reached through an absolute reference' do
      # The same targets, spelled two ways: the accounting must not depend on
      # which spelling the peer chose.
      expect(validator.check_schema(bool_bag('#/x-bools/b%d')))
        .to contain_exactly(a_string_matching(/more than #{validator::MAX_SUBSCHEMAS} subschemas/))
      expect(validator.check_schema(bool_bag('urn:root#/x-bools/b%d')))
        .to contain_exactly(a_string_matching(/more than #{validator::MAX_SUBSCHEMAS} subschemas/))
    end

    it 'tells two bundled resources apart by the query of their URIs' do
      schema = { '$id' => 'urn:x',
                 'properties' => { 'a' => { '$ref' => 'https://example.com/s?v=1' },
                                   'b' => { '$ref' => 'https://example.com/s?v=2' } },
                 '$defs' => { 'one' => { '$id' => 'https://example.com/s?v=1', 'type' => 'string' },
                              'two' => { '$id' => 'https://example.com/s?v=2', 'type' => 'integer' } } }

      # Dropping the query would merge the two resources into one URI, so
      # neither reference could name the resource its author wrote.
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 'x', 'b' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'a' => 1, 'b' => 'x' }, schema))
        .to contain_exactly(a_string_matching(%r{#/a: expected type string}),
                            a_string_matching(%r{#/b: expected type integer}))
    end

    it 'resolves a query-only reference against the base in force' do
      # RFC 3986 Section 5.2.2: an empty path keeps the base's, and the
      # reference's own query replaces it — which is the only thing telling
      # this resource from the document root.
      schema = { '$id' => 'https://example.com/root', 'type' => 'object',
                 'properties' => { 'a' => { '$ref' => '?v=2' } },
                 '$defs' => { 'two' => { '$id' => '?v=2', 'type' => 'integer' } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 'x' }, schema))
        .to contain_exactly(a_string_matching(/expected type integer/))
      expect(validator.validate({ 'a' => 1 }, schema)).to be_empty
    end

    it 'removes the dot segments of a relative reference' do
      schema = { '$id' => 'https://example.com/a/b/root',
                 'properties' => { 'a' => { '$ref' => '../c/s' } },
                 '$defs' => { 's' => { '$id' => 'https://example.com/a/c/s', 'type' => 'string' } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'still resolves an absolute reference to a schema in the bundle' do
      schema = { '$id' => 'urn:root', 'properties' => { 'a' => { '$ref' => 'urn:root#/$defs/s' } },
                 '$defs' => { 's' => { 'type' => 'string' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end
  end

  describe 'an output schema whose dialect this client does not implement' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }
    let(:output_schema) { { '$schema' => 'urn:unknown', 'type' => 'object' } }
    let(:tool) do
      MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                          output_schema: output_schema, server: mock_server)
    end

    def client_with(mode)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    # MCP 2026-07-28 basic "Implementation Requirements": a client MUST
    # return an error saying the dialect is not supported. That is not a
    # structured-content mismatch the host may choose to only log — the
    # client cannot read the schema at all — so it is raised in both modes,
    # exactly as an unsupported input dialect is.
    it 'raises in the default mode as well as in :strict' do
      expect { client_with(:warn).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown.*not supported/m)
      expect { client_with(:strict).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown.*not supported/m)
    end

    it 'still only logs an output schema that is unusable for another reason' do
      allow(tool).to receive(:output_schema).and_return({ '$ref' => 'https://example.com/x' })
      result = client_with(:warn).call_tool('t', {})

      expect(result).to eq({ 'content' => [], 'structuredContent' => {} })
      expect(log_output.string).to include('external $ref')
    end
  end

  describe 'schema checks across tools and entry points' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }

    def stub_server(name, tools)
      srv = instance_double(MCPClient::ServerBase, name: name)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return(tools)
      allow(srv).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })
      allow(srv).to receive(:call_tool_streaming) do |*|
        Enumerator.new { |y| y << { 'content' => [], 'structuredContent' => {} } }
      end
      srv
    end

    def client_over(servers, **opts)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(*servers)
      MCPClient::Client.new(mcp_server_configs: Array.new(servers.length) { { type: 'stdio', command: 'test' } },
                            logger: logger, **opts)
    end

    it 'checks two servers exposing the same tool name independently' do
      good = stub_server('good', [])
      bad = stub_server('bad', [])
      allow(good).to receive(:list_tools).and_return(
        [MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' }, server: good)]
      )
      allow(bad).to receive(:list_tools).and_return(
        [MCPClient::Tool.new(name: 't', description: 'd',
                             schema: { '$schema' => 'urn:unknown', 'type' => 'object' }, server: bad)]
      )
      client = client_over([good, bad])

      expect(client.call_tool('t', {}, server: 'good')).to eq({ 'content' => [], 'structuredContent' => {} })
      expect { client.call_tool('t', {}, server: 'bad') }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown/)
      # And the first server's memo is untouched by the second's verdict.
      expect(client.call_tool('t', {}, server: 'good')).to eq({ 'content' => [], 'structuredContent' => {} })
    end

    it 'refuses an unsupported input dialect at the streaming entry point too' do
      srv = stub_server('s', [])
      allow(srv).to receive(:list_tools).and_return(
        [MCPClient::Tool.new(name: 't', description: 'd',
                             schema: { '$schema' => 'urn:unknown', 'type' => 'object' }, server: srv)]
      )
      client = client_over([srv])

      expect { client.call_tool_streaming('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown/)
      expect(srv).not_to have_received(:call_tool_streaming)
    end

    # A boolean or null outputSchema is a declared schema, so a result must
    # be validated against it — and the copies the client cache hands out
    # must carry that as the parsed definition did.
    [[false, /schema false accepts no value/], [nil, /must be an object or a boolean/]].each do |schema, message|
      it "validates a result against a parsed #{schema.inspect} outputSchema" do
        srv = stub_server('s', [])
        parsed = MCPClient::Tool.from_json({ 'name' => 't', 'inputSchema' => { 'type' => 'object' },
                                             'outputSchema' => schema }, server: srv)
        allow(srv).to receive(:list_tools).and_return([parsed])
        client = client_over([srv], validate_structured_content: :strict)

        expect(client.list_tools.first.structured_output?).to be true
        expect { client.call_tool('t', {}) }.to raise_error(MCPClient::Errors::ValidationError, message)
      end
    end
  end

  describe 'through the wire' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    def modern_client(mode: :strict)
      MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
        validate_structured_content: mode
      )
    end

    # The transport's HeaderMismatch recovery re-derives the call's
    # Mcp-Param-* headers from a refreshed tools/list, so the attempt that is
    # answered may have gone out under a definition this client never
    # resolved -- and the dialect check must cover that one too.
    it 'refuses a call answered under a refreshed input schema of an unsupported dialect' do
      listed = { 'name' => 'execute_sql',
                 'inputSchema' => { 'type' => 'object',
                                    'properties' => { 'region' => { 'type' => 'string',
                                                                    'x-mcp-header' => 'Region' } } } }
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'],
                        { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                          'capabilities' => { 'tools' => {} } })
        when 'tools/list' then json_response(body['id'], { 'tools' => [listed] })
        when 'tools/call'
          next json_response(body['id'], { 'content' => [] }) if request.headers['Mcp-Param-Zone']

          listed = { 'name' => 'execute_sql',
                     'inputSchema' => { '$schema' => 'urn:unknown-dialect', 'type' => 'object',
                                        'properties' => { 'region' => { 'type' => 'string',
                                                                        'x-mcp-header' => 'Zone' } } } }
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_020, 'message' => 'Mcp-Param-Zone missing' }) }
        end
      end
      client = modern_client

      expect { client.call_tool('execute_sql', { 'region' => 'eu' }) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown-dialect.*not supported/m)
      client.cleanup
    end

    # MCP 2025-11-25 server/tools: structured content is an object there, and
    # an outputSchema describes one. The widening to "any JSON value" is a
    # 2026-07-28 rule and does not reach back to a session negotiated legacy.
    it 'still treats a null structuredContent as missing on a legacy session' do
      tool = { 'name' => 'execute_sql', 'inputSchema' => { 'type' => 'object' },
               'outputSchema' => { 'type' => 'null' } }
      stub_request(:get, url).to_return(status: 405, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                                      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
        when 'notifications/initialized' then { status: 202, body: '' }
        when 'tools/list' then json_response(body['id'], { 'tools' => [tool] })
        when 'tools/call' then json_response(body['id'], { 'content' => [], 'structuredContent' => nil })
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0,
                                                              protocol: :legacy)],
        validate_structured_content: :strict
      )

      expect { client.call_tool('execute_sql', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /carries no structuredContent/)
      client.cleanup
    end
  end

  describe 'a leaf deep under a chain of same-instance applications' do
    it 'reports it, and reports a negation of it, through the trampoline' do
      # Twenty mixins applied to each value, so every instance level is
      # reached through twenty same-instance applications.
      defs = { 'leaf' => { 'type' => 'object', 'properties' => { 'next' => { '$ref' => '#/$defs/n0' } },
                           'additionalProperties' => { 'type' => 'integer' } } }
      20.times do |i|
        defs["n#{i}"] = { '$ref' => i + 1 < 20 ? "#/$defs/n#{i + 1}" : '#/$defs/leaf' }
      end
      schema = { '$ref' => '#/$defs/n0', '$defs' => defs }
      deep = (1..30).reduce({ 'v' => 1 }) { |inner, _| { 'next' => inner } }
      bad = (1..30).reduce({ 'v' => 'x' }) { |inner, _| { 'next' => inner } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(deep, schema)).to be_empty
      expect(validator.validate(bad, schema)).to contain_exactly(a_string_matching(/expected type integer/))
      # The same descent inside a negation: the leaf decides it.
      negated = { 'not' => { '$ref' => '#/$defs/n0' }, '$defs' => defs }
      expect(validator.validate(bad, negated)).to be_empty
      expect(validator.validate(deep, negated)).to contain_exactly(a_string_matching(/not/))
    end
  end

  describe 'ECMAScript pattern semantics' do
    # JSON Schema 2020-12 Core Section 4.3: a `pattern` is an ECMA-262
    # regular expression, where `^` and `$` match only at the ends of the
    # subject. Ruby's match at every line boundary, so a value carrying a
    # newline satisfied a pattern ECMAScript rejects — and, through `not`,
    # was rejected although ECMAScript accepts it.
    it 'anchors a pattern to the whole string, not to each line' do
      expect(validator.validate("a\nb", { 'pattern' => '^a$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate('a', { 'pattern' => '^a$' })).to be_empty
      expect(validator.validate("a\nb", { 'not' => { 'pattern' => '^a$' } })).to be_empty
      # An anchor inside a character class or escaped is a literal.
      expect(validator.validate('a^b$c', { 'pattern' => '[$^]' })).to be_empty
      expect(validator.validate('a$b', { 'pattern' => '\\$' })).to be_empty
      expect(validator.validate('ab', { 'pattern' => '[^x]b' })).to be_empty
    end

    it 'anchors a property-name pattern the same way' do
      schema = { 'patternProperties' => { '^a$' => { 'type' => 'integer' } }, 'additionalProperties' => false }
      expect(validator.validate({ 'a' => 1 }, schema)).to be_empty
      expect(validator.validate({ "a\nb" => 1 }, schema)).to contain_exactly(a_string_matching(/not allowed/))
    end

    it 'matches non-ASCII text as written' do
      expect(validator.validate('héllo', { 'pattern' => '^héllo$' })).to be_empty
      expect(validator.validate("héllo\nx", { 'pattern' => '^héllo$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
    end
  end

  describe 'the dynamic references this validator does not evaluate' do
    it 'reports them and never lets one decide a non-monotonic composition' do
      schema = { '$dynamicRef' => '#node', '$defs' => { 'n' => { '$dynamicAnchor' => 'node', 'type' => 'string' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.unsupported_keywords(schema)).to contain_exactly('$dynamicRef')
      # Not applied, so it decides nothing — and a `not` around it cannot
      # read the pass as a match.
      expect(validator.validate(1, schema)).to be_empty
      expect(validator.validate(1, { 'not' => schema })).to be_empty
    end

    it 'refuses a dynamic reference that is not a string' do
      expect(validator.check_schema({ '$dynamicRef' => 5 }))
        .to contain_exactly(a_string_matching(/\$dynamicRef must be a string/))
      expect(validator.check_schema({ '$schema' => draft2019, '$recursiveRef' => [] }))
        .to contain_exactly(a_string_matching(/\$recursiveRef must be a string/))
      # A dialect that does not define the keyword has nothing to refuse.
      expect(validator.check_schema({ '$schema' => draft7, '$dynamicRef' => 5 })).to be_empty
    end
  end

  describe 'the partial-coverage report' do
    it 'keeps only the keywords whose verdict this validator still cannot reach' do
      supported = { 'multipleOf' => 2, 'uniqueItems' => true, 'contains' => true, 'minContains' => 1,
                    'maxContains' => 2, 'minProperties' => 1, 'maxProperties' => 2,
                    'additionalProperties' => false, 'patternProperties' => {}, 'propertyNames' => true,
                    'dependentRequired' => {}, 'dependentSchemas' => {} }
      expect(validator.unsupported_keywords(supported)).to be_empty
      partial = { 'unevaluatedProperties' => false, 'format' => 'email', '$dynamicRef' => '#a',
                  '$dynamicAnchor' => 'a' }
      expect(validator.unsupported_keywords(partial))
        .to contain_exactly('$dynamicRef', 'unevaluatedProperties', 'format')
    end
  end
end
