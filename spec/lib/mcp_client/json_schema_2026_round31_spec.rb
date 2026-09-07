# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, thirty-first round.
#
# `unevaluatedProperties` and `unevaluatedItems` are decided by the
# annotations a whole composition produces (JSON Schema 2020-12 Core
# Sections 11.2 and 11.3): what `properties`, `patternProperties`,
# `additionalProperties`, `prefixItems`, `items`, `contains` and the two
# keywords themselves evaluated, collected through every in-place applicator
# that passed (`$ref`, `allOf`, `anyOf`, `oneOf`, `if`/`then`/`else`,
# `dependentSchemas`) and never from a cousin. Round 30 refused such a schema
# in :strict and let it through in :warn; both are the wrong verdict on the
# canonical closed composition SEP-2106 made legal on a tool schema. The
# annotations are collected now, and the two keywords are evaluated wherever
# they appear. A `$dynamicRef` or `$recursiveRef` that names no dynamic
# anchor is the plain reference the specification says it is; only a
# reference the dynamic scope could re-bind stays out of reach.
RSpec.describe 'MCP 2026-07-28 JSON Schema unevaluated keywords (round 31)' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft2019) { MCPClient::SchemaValidator::DRAFT_2019_09 }
  let(:draft7) { MCPClient::SchemaValidator::DRAFT_07 }

  def valid?(data, schema)
    errors = validator.validate(data, schema)
    expect(errors).not_to include(a_string_matching(/aborted|not supported/)), errors.inspect
    errors.empty?
  end

  # Every case is a pair: a conforming instance the keyword must let through
  # and a non-conforming one it must reject, so a keyword that decided
  # nothing — or refused everything — fails the example.
  def expect_verdicts(schema, valid:, invalid:)
    valid.each { |data| expect(valid?(data, schema)).to be(true), "expected #{data.inspect} to conform" }
    invalid.each { |data| expect(valid?(data, schema)).to be(false), "expected #{data.inspect} to be rejected" }
  end

  describe 'unevaluatedProperties' do
    it 'is applied beside adjacent properties, patternProperties and additionalProperties' do
      expect_verdicts({ 'properties' => { 'foo' => true }, 'unevaluatedProperties' => false },
                      valid: [{ 'foo' => 1 }, {}], invalid: [{ 'foo' => 1, 'bar' => 2 }])
      expect_verdicts({ 'patternProperties' => { '^f' => true }, 'unevaluatedProperties' => false },
                      valid: [{ 'foo' => 1 }], invalid: [{ 'bar' => 2 }])
      expect_verdicts({ 'properties' => { 'foo' => true }, 'additionalProperties' => true,
                        'unevaluatedProperties' => false },
                      valid: [{ 'foo' => 1, 'bar' => 2 }], invalid: [])
    end

    it 'reads the annotations a $ref target produces' do
      schema = { '$ref' => '#/$defs/bar', 'properties' => { 'foo' => { 'type' => 'string' } },
                 'unevaluatedProperties' => false,
                 '$defs' => { 'bar' => { 'properties' => { 'bar' => { 'type' => 'string' } } } } }
      expect_verdicts(schema, valid: [{ 'foo' => 'a', 'bar' => 'b' }],
                              invalid: [{ 'foo' => 'a', 'bar' => 'b', 'baz' => 'c' }])
    end

    it 'closes the canonical SEP-2106 composition' do
      closed = { '$ref' => '#/$defs/base', 'unevaluatedProperties' => false,
                 '$defs' => { 'base' => { 'type' => 'object', 'properties' => { 'id' => { 'type' => 'string' } },
                                          'required' => ['id'] } } }
      expect_verdicts(closed, valid: [{ 'id' => '1' }], invalid: [{ 'id' => '1', 'secret' => 'leak' }, {}])
    end

    it 'reads the annotations nested allOf members produce, at any depth' do
      schema = { 'properties' => { 'foo' => true },
                 'allOf' => [{ 'properties' => { 'bar' => true } },
                             { 'allOf' => [{ 'patternProperties' => { '^q' => true } }] }],
                 'unevaluatedProperties' => false }
      expect_verdicts(schema, valid: [{ 'foo' => 1, 'bar' => 2, 'quux' => 3 }],
                              invalid: [{ 'foo' => 1, 'bar' => 2, 'baz' => 3 }])
    end

    it 'reads the annotations of every anyOf branch that passed, and none of a branch that failed' do
      schema = { 'properties' => { 'foo' => true },
                 'anyOf' => [{ 'properties' => { 'bar' => { 'const' => 'bar' } }, 'required' => ['bar'] },
                             { 'properties' => { 'baz' => { 'const' => 'baz' } }, 'required' => ['baz'] },
                             { 'properties' => { 'quux' => { 'const' => 'quux' } }, 'required' => ['quux'] }],
                 'unevaluatedProperties' => false }
      expect_verdicts(schema,
                      valid: [{ 'foo' => 1, 'bar' => 'bar' }, { 'foo' => 1, 'bar' => 'bar', 'baz' => 'baz' },
                              { 'foo' => 1, 'bar' => 'bar', 'baz' => 'baz', 'quux' => 'quux' }],
                      invalid: [{ 'foo' => 1, 'bar' => 'bar', 'baz' => 'not-baz' },
                                { 'foo' => 1, 'bar' => 'bar', 'quux' => 'not-quux' }])
    end

    it 'reads the annotations of the one oneOf branch that passed' do
      schema = { 'properties' => { 'foo' => true },
                 'oneOf' => [{ 'properties' => { 'bar' => { 'const' => 'bar' } }, 'required' => ['bar'] },
                             { 'properties' => { 'baz' => { 'const' => 'baz' } }, 'required' => ['baz'] }],
                 'unevaluatedProperties' => false }
      expect_verdicts(schema, valid: [{ 'foo' => 1, 'bar' => 'bar' }, { 'foo' => 1, 'baz' => 'baz' }],
                              invalid: [{ 'foo' => 1, 'bar' => 'bar', 'quux' => 2 }])
    end

    it 'reads nothing from not' do
      schema = { 'properties' => { 'foo' => true },
                 'not' => { 'not' => { 'properties' => { 'bar' => { 'const' => 'bar' } }, 'required' => ['bar'] } },
                 'unevaluatedProperties' => false }
      expect_verdicts(schema, valid: [], invalid: [{ 'foo' => 1, 'bar' => 'bar' }])
    end

    it 'reads the annotations of if (only when it passed) and of the branch that applied' do
      schema = { 'if' => { 'properties' => { 'foo' => { 'const' => 'then' } }, 'required' => ['foo'] },
                 'then' => { 'properties' => { 'bar' => true }, 'required' => ['bar'] },
                 'else' => { 'properties' => { 'baz' => true }, 'required' => ['baz'] },
                 'unevaluatedProperties' => false }
      expect_verdicts(schema,
                      valid: [{ 'foo' => 'then', 'bar' => 1 }, { 'baz' => 1 }],
                      invalid: [{ 'foo' => 'then', 'bar' => 1, 'baz' => 2 }, { 'foo' => 'else', 'baz' => 1 }])
    end

    it 'reads the annotations of a triggered dependentSchemas member' do
      schema = { 'properties' => { 'foo' => true },
                 'dependentSchemas' => { 'foo' => { 'properties' => { 'bar' => true } } },
                 'unevaluatedProperties' => false }
      expect_verdicts(schema, valid: [{ 'foo' => 1, 'bar' => 2 }], invalid: [{ 'bar' => 2 }])
    end

    it 'never sees a cousin, whichever side of the allOf it is on' do
      expect_verdicts({ 'allOf' => [{ 'properties' => { 'foo' => true } }, { 'unevaluatedProperties' => false }] },
                      valid: [{}], invalid: [{ 'foo' => 1 }])
      expect_verdicts({ 'allOf' => [{ 'unevaluatedProperties' => false }, { 'properties' => { 'foo' => true } }] },
                      valid: [{}], invalid: [{ 'foo' => 1 }])
    end

    it 'is itself an annotation a nested one produces' do
      schema = { 'properties' => { 'foo' => true }, 'allOf' => [{ 'unevaluatedProperties' => true }],
                 'unevaluatedProperties' => { 'type' => 'string', 'maxLength' => 2 } }
      expect_verdicts(schema, valid: [{ 'foo' => 1, 'bar' => 'a long value' }], invalid: [])
    end

    it 'applies its schema to what was left unevaluated' do
      schema = { 'properties' => { 'foo' => true },
                 'unevaluatedProperties' => { 'type' => 'string', 'minLength' => 3 } }
      expect_verdicts(schema, valid: [{ 'foo' => 1, 'bar' => 'bar' }], invalid: [{ 'foo' => 1, 'bar' => 'ba' }])
    end

    it 'does not read a property evaluated on another instance level' do
      schema = { 'properties' => { 'child' => { 'properties' => { 'bar' => true } } },
                 'unevaluatedProperties' => false }
      expect_verdicts(schema, valid: [{ 'child' => { 'bar' => 1 } }], invalid: [{ 'child' => {}, 'bar' => 1 }])
    end

    it 'is unknown under draft-07, where nothing defines it' do
      expect_verdicts({ '$schema' => draft7, 'unevaluatedProperties' => false }, valid: [{ 'foo' => 1 }], invalid: [])
    end
  end

  describe 'unevaluatedItems' do
    it 'is applied beside prefixItems and items' do
      expect_verdicts({ 'prefixItems' => [{ 'type' => 'string' }], 'unevaluatedItems' => false },
                      valid: [['foo'], []], invalid: [['foo', 42]])
      expect_verdicts({ 'items' => { 'type' => 'string' }, 'unevaluatedItems' => false },
                      valid: [%w[foo bar]], invalid: [])
    end

    it 'reads the items contains matched' do
      expect_verdicts({ 'contains' => { 'type' => 'string' }, 'unevaluatedItems' => false },
                      valid: [['foo']], invalid: [['foo', 42], [42]])
      expect_verdicts({ 'prefixItems' => [{ 'type' => 'number' }], 'contains' => { 'type' => 'string' },
                        'unevaluatedItems' => false },
                      valid: [[1, 'x'], [1, 'x', 'y']], invalid: [[1, 'x', true]])
    end

    it 'reads the tuple a nested allOf member evaluated' do
      schema = { 'prefixItems' => [{ 'type' => 'string' }],
                 'allOf' => [{ 'prefixItems' => [true, { 'type' => 'number' }] }],
                 'unevaluatedItems' => false }
      expect_verdicts(schema, valid: [['foo', 42]], invalid: [['foo', 42, true]])
    end

    it 'reads the annotations of the anyOf branches that passed' do
      schema = { 'prefixItems' => [{ 'const' => 'foo' }],
                 'anyOf' => [{ 'prefixItems' => [true, { 'const' => 'bar' }] },
                             { 'prefixItems' => [true, true, { 'const' => 'baz' }] }],
                 'unevaluatedItems' => false }
      expect_verdicts(schema, valid: [%w[foo bar], %w[foo bar baz]], invalid: [%w[foo bar baz quux]])
    end

    it 'reads nothing from not' do
      schema = { 'not' => { 'not' => { 'prefixItems' => [true] } }, 'unevaluatedItems' => false }
      expect_verdicts(schema, valid: [[]], invalid: [['foo']])
    end

    it 'reads the annotations of if and of the branch that applied' do
      schema = { 'if' => { 'prefixItems' => [{ 'const' => 'then' }] },
                 'then' => { 'prefixItems' => [true, { 'type' => 'number' }] },
                 'else' => { 'prefixItems' => [true, { 'type' => 'string' }] },
                 'unevaluatedItems' => false }
      expect_verdicts(schema, valid: [['then', 1], %w[else x]], invalid: [['then', 1, 2], %w[else x y]])
    end

    it 'reads the annotations a $ref target produces' do
      schema = { '$ref' => '#/$defs/head', 'unevaluatedItems' => false,
                 '$defs' => { 'head' => { 'prefixItems' => [{ 'type' => 'string' }] } } }
      expect_verdicts(schema, valid: [['foo']], invalid: [%w[foo bar]])
    end

    it 'never sees a cousin' do
      expect_verdicts({ 'allOf' => [{ 'prefixItems' => [true] }, { 'unevaluatedItems' => false }] },
                      valid: [[]], invalid: [['foo']])
    end

    it 'is itself an annotation a nested one produces, and applies its schema to what is left' do
      expect_verdicts({ 'prefixItems' => [true], 'allOf' => [{ 'unevaluatedItems' => true }],
                        'unevaluatedItems' => { 'type' => 'string' } },
                      valid: [[1, 2]], invalid: [])
      expect_verdicts({ 'prefixItems' => [true], 'unevaluatedItems' => { 'type' => 'string' } },
                      valid: [[1, 'a']], invalid: [[1, 2]])
    end

    it 'reads a 2019-09 tuple and its additionalItems' do
      expect_verdicts({ '$schema' => draft2019, 'items' => [{ 'type' => 'string' }], 'unevaluatedItems' => false },
                      valid: [['foo']], invalid: [%w[foo bar]])
      expect_verdicts({ '$schema' => draft2019, 'items' => [{ 'type' => 'string' }], 'additionalItems' => true,
                        'unevaluatedItems' => false },
                      valid: [%w[foo bar]], invalid: [])
    end
  end

  describe 'the dynamic references' do
    it 'applies a $dynamicRef that names no dynamic anchor as the plain reference it is' do
      pointer = { '$dynamicRef' => '#/$defs/n', '$defs' => { 'n' => { 'type' => 'integer' } } }
      expect_verdicts(pointer, valid: [1], invalid: ['bad'])
      expect(validator.unsupported_keywords(pointer)).to be_empty

      plain_anchor = { '$dynamicRef' => '#n', '$defs' => { 'n' => { '$anchor' => 'n', 'type' => 'integer' } } }
      expect_verdicts(plain_anchor, valid: [1], invalid: ['bad'])
      expect(validator.unsupported_keywords(plain_anchor)).to be_empty
    end

    it 'applies a $dynamicRef beside a $ref, after it' do
      schema = { '$ref' => '#/$defs/a', '$dynamicRef' => '#/$defs/b',
                 '$defs' => { 'a' => { 'minimum' => 1 }, 'b' => { 'maximum' => 5 } } }
      expect_verdicts(schema, valid: [3], invalid: [0, 6])
    end

    it 'binds a $dynamicRef to the dynamic anchor its root resource declares' do
      dynamic = { '$dynamicRef' => '#node', '$defs' => { 'n' => { '$dynamicAnchor' => 'node', 'type' => 'integer' } } }
      expect(validator.unsupported_keywords(dynamic)).to be_empty
      expect_verdicts(dynamic, valid: [1], invalid: ['bad'])
    end

    it 'binds a $dynamicRef by the resources the instance entered, not by the ones it did not' do
      dynamic = { '$ref' => 'https://example.com/a',
                  '$defs' => { 'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node',
                                        'type' => 'object',
                                        'properties' => { 'child' => { '$dynamicRef' => '#node' } } },
                               'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node',
                                        'type' => 'string' } } }
      expect(validator.unsupported_keywords(dynamic)).to be_empty
      expect_verdicts(dynamic, valid: [{ 'child' => {} }], invalid: [{ 'child' => 1 }])
      expect(validator.validate({ 'child' => 1 }, { 'not' => dynamic })).to be_empty
    end

    it 'applies a 2019-09 $recursiveRef whose target has no true $recursiveAnchor as a $ref' do
      schema = { '$schema' => draft2019, 'type' => 'object',
                 'properties' => { 'child' => { '$recursiveRef' => '#' } } }
      expect_verdicts(schema, valid: [{ 'child' => {} }], invalid: [{ 'child' => 1 }])
      expect(validator.unsupported_keywords(schema)).to be_empty

      dynamic = { '$schema' => draft2019, '$recursiveAnchor' => true, 'type' => 'object',
                  'properties' => { 'child' => { '$recursiveRef' => '#' } } }
      # The root's own $recursiveAnchor is the outermost one there is.
      expect(validator.unsupported_keywords(dynamic)).to be_empty
      expect_verdicts(dynamic, valid: [{ 'child' => {} }], invalid: [{ 'child' => 1 }])
    end
  end

  describe 'the client' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:closed) do
      { '$ref' => '#/$defs/base', 'unevaluatedProperties' => false,
        '$defs' => { 'base' => { 'type' => 'object', 'properties' => { 'id' => { 'type' => 'string' } },
                                 'required' => ['id'] } } }
    end
    let(:conforming) { { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'id' => '1' } } }
    let(:leak) do
      { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'id' => '1', 'secret' => 'leak' } }
    end

    def stub_server(output_schema, chunk)
      srv = instance_double(MCPClient::ServerBase, name: 's')
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                 output_schema: output_schema, server: srv)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return([tool])
      allow(srv).to receive(:call_tool).and_return(chunk)
      allow(srv).to receive(:call_tool_streaming) { |*| Enumerator.new { |y| y << chunk } }
      srv
    end

    def client_over(srv, mode)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    it 'accepts a conforming result against the closed composition in :strict mode, silently' do
      client = client_over(stub_server(closed, conforming), :strict)

      expect(client.call_tool('t', {})).to eq(conforming)
      expect(log_output.string).not_to include('validation is partial')
    end

    it 'rejects the leaked property in :strict mode, naming it' do
      client = client_over(stub_server(closed, leak), :strict)

      expect { client.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /'secret' is not allowed \(unevaluatedProperties/)
    end

    it 'warns about the leaked property in :warn mode and returns the result' do
      client = client_over(stub_server(closed, leak), :warn)

      expect(client.call_tool('t', {})).to eq(leak)
      expect(log_output.string).to match(/'secret' is not allowed \(unevaluatedProperties/)
      expect(log_output.string).not_to include('validation is partial')
    end

    it 'rejects an item contains did not evaluate in :strict mode, on the streaming path too' do
      items = { 'contains' => { 'type' => 'string' }, 'unevaluatedItems' => false }
      result = { 'resultType' => 'complete', 'content' => [], 'structuredContent' => ['x', 1] }
      client = client_over(stub_server(items, result), :strict)

      expect { client.call_tool_streaming('t', {}).to_a }
        .to raise_error(MCPClient::Errors::ValidationError, /item 1 is not allowed \(unevaluatedItems/)
    end

    # The reference is evaluated now, so :strict gates on the verdict rather
    # than refusing the schema: a conforming result passes, and one the
    # binding rejects is refused for what is wrong with it.
    it 'checks, in :strict mode, a result against the schema its dynamic reference binds to' do
      dynamic = { '$ref' => 'https://example.com/a', 'type' => 'object',
                  '$defs' => { 'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node',
                                        'type' => 'object', 'properties' => { 'id' => { '$dynamicRef' => '#node' } } },
                               'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node',
                                        'type' => 'string' } } }

      # `id` binds to the resource the evaluation entered, whose `type` is
      # object: a nested object passes and the string `conforming` carries is
      # refused for the type it is.
      nested = { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'id' => {} } }
      expect(client_over(stub_server(dynamic, nested), :strict).call_tool('t', {})).to eq(nested)

      expect { client_over(stub_server(dynamic, conforming), :strict).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /expected type object/)
    end
  end
end
