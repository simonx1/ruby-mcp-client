# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 JSON Schema handling, thirty-third round.
#
# A dynamic reference resolves to the outermost dynamic scope that declares
# its anchor (JSON Schema 2020-12 Core Section 8.2.3.2; 2019-09 Section
# 8.2.4.2.2 for `$recursiveRef`). The dynamic scope always starts at the
# schema being applied, so where that root resource declares the anchor —
# the recursive-tree shape the specification illustrates the keyword with —
# the reference re-binds to the root wherever it is met; and where exactly
# one resource declares it, it is the target the reference named. Only a
# document in which several non-root resources declare the same dynamic
# anchor needs the evaluation path to choose, and stays out of reach. A
# branchless `if` still produces annotations (Section 10.2.2.1), and a
# generated capture-group name never collides with one the pattern wrote.
RSpec.describe 'MCP 2026-07-28 JSON Schema dynamic references, branchless if, captures (round 33)' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft2019) { MCPClient::SchemaValidator::DRAFT_2019_09 }

  def valid?(data, schema)
    errors = validator.validate(data, schema)
    expect(errors).not_to include(a_string_matching(/aborted|not supported/)), errors.inspect
    errors.empty?
  end

  def expect_verdicts(schema, valid:, invalid:)
    valid.each { |data| expect(valid?(data, schema)).to be(true), "expected #{data.inspect} to conform" }
    invalid.each { |data| expect(valid?(data, schema)).to be(false), "expected #{data.inspect} to be rejected" }
  end

  describe 'a $dynamicRef whose anchor the root resource declares' do
    it 'binds to the root: the recursive node shape' do
      schema = { '$dynamicAnchor' => 'node', 'type' => 'object',
                 'properties' => { 'child' => { '$dynamicRef' => '#node' } } }
      expect(validator.unsupported_keywords(schema)).to be_empty
      expect_verdicts(schema, valid: [{ 'child' => {} }, { 'child' => { 'child' => {} } }],
                              invalid: [{ 'child' => 1 }, { 'child' => { 'child' => 'x' } }])
    end

    it 'binds to the anchor a definition of the root resource declares' do
      schema = { '$dynamicRef' => '#node', '$defs' => { 'n' => { '$dynamicAnchor' => 'node', 'type' => 'integer' } } }
      expect(validator.unsupported_keywords(schema)).to be_empty
      expect_verdicts(schema, valid: [1], invalid: ['bad'])
    end

    it 're-binds a reference met inside another resource to the root, so the strict tree stays closed' do
      tree = { '$id' => 'https://example.com/tree', '$dynamicAnchor' => 'node', 'type' => 'object',
               'properties' => { 'data' => true,
                                 'children' => { 'type' => 'array', 'items' => { '$dynamicRef' => '#node' } } } }
      strict = { '$id' => 'https://example.com/strict-tree', '$dynamicAnchor' => 'node',
                 '$ref' => 'tree', 'unevaluatedProperties' => false, '$defs' => { 'tree' => tree } }
      expect(validator.unsupported_keywords(strict)).to be_empty
      expect_verdicts(strict,
                      valid: [{ 'data' => 1, 'children' => [{ 'data' => 2 }] }],
                      invalid: [{ 'data' => 1, 'children' => [{ 'data' => 2, 'extra' => 3 }] },
                                { 'data' => 1, 'extra' => 3 }])
      # The tree alone is open: nothing re-binds the reference to a closed root.
      expect_verdicts(tree, valid: [{ 'data' => 1, 'children' => [{ 'data' => 2, 'extra' => 3 }] }], invalid: [])
    end

    it 'applies a 2019-09 $recursiveRef to a root whose $recursiveAnchor is true' do
      schema = { '$schema' => draft2019, '$recursiveAnchor' => true, 'type' => 'object',
                 'properties' => { 'child' => { '$recursiveRef' => '#' } } }
      expect(validator.unsupported_keywords(schema)).to be_empty
      expect_verdicts(schema, valid: [{ 'child' => {} }], invalid: [{ 'child' => 1 }])
    end
  end

  describe 'a dynamic anchor several non-root resources declare' do
    let(:ambiguous) do
      { '$ref' => 'https://example.com/a',
        '$defs' => { 'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node', 'type' => 'object',
                              'properties' => { 'child' => { '$dynamicRef' => '#node' } } },
                     'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node', 'type' => 'string' } } }
    end

    it 'is the one dynamic reference still reported as not evaluated' do
      expect(validator.unsupported_keywords(ambiguous)).to contain_exactly('$dynamicRef')
      expect(validator.validate({ 'child' => 1 }, { 'not' => ambiguous })).to be_empty
    end
  end

  describe 'a branchless if' do
    it 'still contributes the annotations of a condition that passed' do
      expect_verdicts({ 'if' => { 'properties' => { 'foo' => true } }, 'unevaluatedProperties' => false },
                      valid: [{ 'foo' => 1 }, {}], invalid: [{ 'bar' => 1 }, { 'foo' => 1, 'bar' => 2 }])
      expect_verdicts({ 'if' => { 'prefixItems' => [true] }, 'unevaluatedItems' => false },
                      valid: [[1], []], invalid: [[1, 2]])
    end

    it 'contributes nothing when the condition failed' do
      expect_verdicts({ 'if' => { 'properties' => { 'foo' => { 'type' => 'string' } } },
                        'unevaluatedProperties' => false },
                      valid: [{ 'foo' => 'a' }], invalid: [{ 'foo' => 1 }])
    end

    it 'keeps the verdict when the whole thing sits under not' do
      schema = { 'not' => { 'if' => { 'properties' => { 'foo' => true } }, 'unevaluatedProperties' => false } }
      expect_verdicts(schema, valid: [{ 'bar' => 1 }], invalid: [{ 'foo' => 1 }])
    end
  end

  describe 'a pattern whose own group name looks generated' do
    it 'numbers the unnamed group without colliding with the written name' do
      schema = { 'type' => 'string', 'pattern' => '^(a)(?<__mcp_g1>b)\\1$' }
      expect_verdicts(schema, valid: ['aba'], invalid: %w[abb ab])
    end

    it 'decides patternProperties by the right match' do
      schema = { 'patternProperties' => { '^(a)(?<__mcp_g1>b)\\1$' => { 'type' => 'integer' } } }
      expect_verdicts(schema, valid: [{ 'abb' => 'x' }, { 'aba' => 1 }], invalid: [{ 'aba' => 'x' }])
    end
  end

  describe 'the client' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:complete) { { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'n' => 1 } } }

    def stub_server(output_schema:, answer: complete)
      srv = instance_double(MCPClient::ServerBase, name: 's')
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                 output_schema: output_schema, server: srv)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return([tool])
      allow(srv).to receive(:call_tool).and_return(answer)
      srv
    end

    def client_over(srv, mode = :strict)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    it 'accepts, in :strict mode, a result under a schema whose dynamic anchor the root declares' do
      schema = { '$dynamicAnchor' => 'node', 'type' => 'object',
                 'properties' => { 'child' => { '$dynamicRef' => '#node' } } }
      good = complete.merge('structuredContent' => { 'child' => { 'child' => {} } })
      bad = complete.merge('structuredContent' => { 'child' => 1 })

      expect(client_over(stub_server(output_schema: schema, answer: good)).call_tool('t', {})).to eq(good)
      expect { client_over(stub_server(output_schema: schema, answer: bad)).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
      expect(log_output.string).not_to include('validation is partial')
    end

    # An error result may omit structuredContent; one that carries it is
    # still bound by the output schema (the tools specification exempts
    # nothing about error results), so :strict checks what is there.
    it 'validates the structuredContent an error result carries, in :strict mode' do
      schema = { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer' } } }
      wrong = { 'resultType' => 'complete', 'content' => [], 'isError' => true, 'structuredContent' => { 'n' => 'x' } }
      bare = { 'resultType' => 'complete', 'content' => [{ 'type' => 'text', 'text' => 'boom' }], 'isError' => true }

      expect { client_over(stub_server(output_schema: schema, answer: wrong)).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
      expect(client_over(stub_server(output_schema: schema, answer: bare)).call_tool('t', {})).to eq(bare)
    end

    it 'refuses every structured result under an outputSchema of false, in :strict mode' do
      expect { client_over(stub_server(output_schema: false)).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
      expect(client_over(stub_server(output_schema: false), :warn).call_tool('t', {})).to eq(complete)
      expect(log_output.string).to include('does not match its output schema')
    end
  end

  describe 'the HeaderMismatch retry on Streamable HTTP' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }
    let(:json) { { 'Content-Type' => 'application/json' } }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result), headers: json }
    end

    def listing(header, output_dialect: nil)
      input = { 'type' => 'object', 'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } }
      output = { 'type' => 'object' }
      output = { '$schema' => output_dialect }.merge(output) if output_dialect
      { 'tools' => [{ 'name' => 'wipe', 'inputSchema' => input, 'outputSchema' => output }], 'ttlMs' => 0 }
    end

    # The refreshed definition is checked before the retry goes out, on both
    # of its schemas: a tool run under an output dialect nothing here can
    # read would only be refused after it ran.
    it 'is not sent under a refreshed output dialect this client cannot read' do
      calls = 0
      rejected = false
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => { 'tools' => {} } })
        when 'tools/list'
          json_response(body['id'], listing('Region', output_dialect: rejected ? 'urn:unknown-dialect' : nil))
        when 'tools/call'
          calls += 1
          rejected = true
          { status: 400, headers: json,
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_020, 'message' => 'Mcp-Param-Region missing' }) }
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
        validate_structured_content: :strict
      )

      expect { client.call_tool('wipe', { 'region' => 'eu' }) }
        .to raise_error(MCPClient::Errors::ValidationError, /output schema.*urn:unknown-dialect.*not supported/m)
      expect(calls).to eq(1)
      client.cleanup
    end
  end
end
