# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, eleventh review round: a branch the
# validator can only partly evaluate is no verdict for not / oneOf / if,
# the structural bound covers deep subtrees, the client never hashes a
# peer schema whole, a draft-07 `$id` beside a `$ref` is ignored, a
# truncated anchor index makes the schema unusable, and malformed JSON
# Pointer escapes are unresolvable.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 11' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'partially evaluated branches' do
    it 'does not reject a value because a not branch it cannot decide seemed to match' do
      # `unevaluatedItems` needs the annotations a whole composition produces,
      # so a branch carrying one is a verdict this validator cannot reach.
      expect(validator.validate([1], { 'not' => { 'unevaluatedItems' => false } })).to be_empty
      # A decided branch still asserts.
      expect(validator.validate('x', { 'not' => { 'type' => 'string' } })).to contain_exactly(a_string_matching(/not/))
      # A branch that fails on an evaluated keyword is decided even when it
      # also carries an unevaluated one.
      undecided_then_failing = { 'not' => { 'allOf' => [{ 'unevaluatedItems' => false }, { 'type' => 'string' }] } }
      expect(validator.validate([1], undecided_then_failing)).to be_empty
      # unevaluatedItems does not apply to a string, so that branch is decided
      # by its type alone and matches: not rejects the string.
      expect(validator.validate('x', undecided_then_failing)).to contain_exactly(a_string_matching(/not/))
    end

    it 'does not count an undecided oneOf branch as a match' do
      schema = { 'oneOf' => [{ 'unevaluatedItems' => false }, { 'type' => 'array' }] }
      expect(validator.validate([1], schema)).to be_empty
      decided = { 'oneOf' => [{ 'type' => 'number' }, { 'type' => 'integer' }] }
      expect(validator.validate(3, decided)).to contain_exactly(a_string_matching(/oneOf/))
    end

    it 'skips a conditional whose if it cannot decide, unless the branches agree' do
      # Neither branch can be selected, but both reject the value, so the
      # instance is rejected whichever way the condition goes.
      condition = { 'unevaluatedItems' => false }
      agreed = { 'if' => condition, 'then' => { 'type' => 'string' }, 'else' => { 'type' => 'string' } }
      expect(validator.validate([1], agreed)).to contain_exactly(a_string_matching(/expected type string/))
      schema = { 'if' => condition, 'then' => { 'type' => 'string' }, 'else' => { 'type' => 'array' } }
      expect(validator.validate([1], schema)).to be_empty
      decided = { 'if' => { 'type' => 'integer' }, 'then' => { 'type' => 'string' } }
      expect(validator.validate(3, decided)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'keeps treating a partial pass as a pass where that is the permissive direction' do
      expect(validator.validate([1], { 'anyOf' => [{ 'unevaluatedItems' => false }] })).to be_empty
      expect(validator.validate([1], { 'allOf' => [{ 'unevaluatedItems' => false }] })).to be_empty
      # An assertion this validator does evaluate decides those compositions
      # rather than passing them: an unevaluated one is not a licence to
      # accept what the schema rejects.
      expect(validator.validate(4, { 'anyOf' => [{ 'multipleOf' => 3 }] }))
        .to contain_exactly(a_string_matching(/anyOf/))
      expect(validator.validate(4, { 'allOf' => [{ 'multipleOf' => 3 }] }))
        .to contain_exactly(a_string_matching(%r{allOf/0}))
    end
  end

  describe 'deep subtrees' do
    def nested(levels, leaf)
      levels.times.reduce(leaf) { |inner, _| { 'type' => 'object', 'properties' => { 'a' => inner } } }
    end

    it 'normalizes and charges a subtree below the nesting bound' do
      schema = nested(40, { type: 'integer' })
      data = 40.times.reduce('x') { |inner, _| { 'a' => inner } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(data, schema)).to contain_exactly(a_string_matching(/expected type integer/))

      wide = {}
      (validator::MAX_STRUCTURAL_OBJECTS + 10).times { |i| wide["p#{i}"] = true }
      expect(validator.check_schema(nested(40, { 'type' => 'object', 'properties' => wide })))
        .to contain_exactly(a_string_matching(/structural elements/))
    end

    it 'reports a document nested beyond the bound instead of keeping the rest raw' do
      deep = nested(validator::MAX_SCHEMA_DEPTH + 10, { 'type' => 'integer' })
      expect(validator.check_schema(deep)).to contain_exactly(a_string_matching(/depth/))
    end
  end

  describe 'draft-07 $id beside $ref' do
    it 'ignores a URI $id next to a $ref like every other sibling' do
      schema = { '$schema' => draft7,
                 'properties' => { 'a' => { '$ref' => '#/definitions/int', '$id' => 'https://example.com/ignored' } },
                 'definitions' => { 'int' => { 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'a' => 'x' }, schema)).to contain_exactly(a_string_matching(/expected type integer/))
    end
  end

  describe 'anchor index bound' do
    it 'makes a document whose anchors cannot be fully indexed unusable' do
      bag = {}
      validator::MAX_SUBSCHEMAS.times { |i| bag["d#{i}"] = { 'type' => 'string' } }
      # The bag sits under the container this dialect does not define, so
      # the preflight walk never reads it while the index still must.
      schema = {
        '$schema' => draft7,
        'properties' => { 'a' => { '$ref' => '#/definitions/holder/definitions/t' } },
        'definitions' => { 'holder' => { 'definitions' => { 't' => { '$id' => 'https://example.com/t',
                                                                     'items' => [{ 'type' => 'integer' }] } } } },
        '$defs' => bag
      }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/index/))
      expect(validator.validate({ 'a' => ['x'] }, schema)).to contain_exactly(a_string_matching(/index/))
    end
  end

  describe 'JSON Pointer escapes' do
    it 'treats a tilde not followed by 0 or 1 as an unresolvable reference' do
      schema = { 'properties' => { 'a' => { '$ref' => '#/$defs/bad~2key' } },
                 '$defs' => { 'bad~2key' => { 'type' => 'string' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable/))
      good = { 'properties' => { 'a' => { '$ref' => '#/$defs/a~0b~1c' } },
               '$defs' => { 'a~b/c' => { 'type' => 'string' } } }
      expect(validator.check_schema(good)).to be_empty
    end
  end

  describe 'through MCPClient::Client' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def client_with(tools)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return(tools)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)
    end

    it 'never hashes a peer schema whole before the bounded check' do
      deep = { 'type' => 'object' }
      100_000.times { deep = { 'properties' => { 'a' => deep } } }
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: deep, output_schema: deep,
                                 server: mock_server)
      client = client_with([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })

      expect { client.send(:input_schema_state, tool) }.not_to raise_error
      expect { client.call_tool('t', {}) }.not_to raise_error
      expect(log_output.string).to include('not usable')
    end

    it 'checks a schema again only when the tool carries a different one' do
      schema = { 'type' => 'object', 'format' => 'custom' }
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: schema, output_schema: schema,
                                 server: mock_server)
      client = client_with([tool])
      allow(validator).to receive(:check_schema).and_call_original

      2.times { client.send(:input_schema_state, tool) }
      expect(validator).to have_received(:check_schema).once

      refreshed = MCPClient::Tool.new(name: 't', description: 'd', schema: schema.dup, server: mock_server)
      client.send(:input_schema_state, refreshed)
      expect(validator).to have_received(:check_schema).twice
    end
  end
end
