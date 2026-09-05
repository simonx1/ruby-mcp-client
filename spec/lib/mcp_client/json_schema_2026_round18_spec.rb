# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, eighteenth review round: pointer
# depth follows the dialect in force at each node (switching inside an
# embedded resource) and an opaque count is never overridden by a lexical
# depth; an unevaluated assertion that cannot change this instance decides
# nothing; a boolean the walk already admitted is not charged again.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 18' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:modern) { 'https://json-schema.org/draft/2020-12/schema' }
  let(:max) { validator::MAX_SCHEMA_DEPTH }

  def nested_not(depth, leaf)
    (1..depth).reduce(leaf) { |inner, _| { 'not' => inner } }
  end

  describe 'pointer depth by the dialect in force' do
    it 'accepts a boolean legal at the bound inside a 2020-12 resource embedded in a draft-07 document' do
      n = max - 2
      emb = { '$id' => 'https://example.com/emb', '$schema' => modern,
              'prefixItems' => [nested_not(n, true)],
              'allOf' => [{ '$ref' => "#/prefixItems/0#{'/not' * n}" }] }
      schema = { '$schema' => draft7, 'definitions' => { 'emb' => emb } }

      expect(validator.check_schema(schema)).to be_empty
    end

    it 'counts every token under a keyword the embedded dialect does not define' do
      node = true
      40.times { node = { 'prefixItems' => [node] } }
      schema = { '$defs' => { 'emb' => { '$id' => 'https://example.com/e', '$schema' => draft7,
                                         'prefixItems' => [node] } },
                 'allOf' => [{ '$ref' => "#/$defs/emb#{'/prefixItems/0' * 41}" }] }

      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/nesting depth exceeds/))
      expect(validator.validate(123, schema)).to contain_exactly(a_string_matching(/nesting depth exceeds/))
    end

    it 'lets the opaque count win over a lexical depth for an object leaf too' do
      pointer = "#/$defs/t#{'/not' * (max - 1)}"
      schema = { '$schema' => draft7, '$defs' => { 't' => nested_not(max - 1, {}) },
                 'allOf' => [{ '$ref' => pointer }] }

      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/nesting depth exceeds/))
    end
  end

  describe 'assertions that cannot change the instance' do
    it 'decides not / oneOf when the unevaluated keyword is a no-op for the value' do
      expect(validator.validate([1], { 'not' => { 'prefixItems' => [true], 'unevaluatedItems' => false } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate([1, 2], { 'not' => { 'items' => true, 'unevaluatedItems' => false } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate([1], { 'not' => { 'uniqueItems' => true } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate([1], { 'oneOf' => [{ 'type' => 'array' }, { 'uniqueItems' => true }] }))
        .to contain_exactly(a_string_matching(/oneOf/))
      expect(validator.validate({}, { 'not' => { 'additionalProperties' => false } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate([], { 'not' => { 'contains' => true, 'minContains' => 0, 'maxContains' => 0 } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate({ 'a' => 1 }, { 'not' => { 'properties' => { 'a' => true },
                                                           'unevaluatedProperties' => false } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate({ 'a' => 1 }, { 'not' => { 'minProperties' => 1, 'maxProperties' => 1 } }))
        .to contain_exactly(a_string_matching(/not/))
    end

    it 'stays undecided while the keyword can still change the value' do
      expect(validator.validate([1, 2], { 'not' => { 'prefixItems' => [true], 'unevaluatedItems' => false } }))
        .to be_empty
      expect(validator.validate([1, 1], { 'not' => { 'uniqueItems' => true } })).to be_empty
      expect(validator.validate({ 'a' => 1 }, { 'not' => { 'additionalProperties' => false } })).to be_empty
      expect(validator.validate([1], { 'not' => { 'contains' => true, 'minContains' => 0, 'maxContains' => 0 } }))
        .to be_empty
    end
  end

  it 'resolves a reference written in a schema that was reached through a data keyword' do
    schema = { '$ref' => '#/default', 'default' => { '$ref' => '#/$defs/x' },
               '$defs' => { 'x' => { 'type' => 'string' } } }

    expect(validator.check_schema(schema)).to be_empty
    expect(validator.validate('ok', schema)).to be_empty
    expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type string/))
  end

  it 'normalizes a symbol-keyed schema reached through a data keyword' do
    schema = { '$ref': '#/default', default: { type: 'string' } }

    expect(validator.check_schema(schema)).to be_empty
    expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type string/))
    expect(validator.validate('ok', schema)).to be_empty
  end

  it 'does not charge a boolean the walk already admitted when a reference reaches it' do
    count = 700
    bools = (0...count).to_h { |i| ["b#{i}", true] }
    props = (0...count).to_h { |i| ["p#{i}", { '$ref' => "#/$defs/b#{i}" }] }
    schema = { 'type' => 'object', 'properties' => props, '$defs' => bools }

    expect(validator.check_schema(schema)).to be_empty
  end
end
