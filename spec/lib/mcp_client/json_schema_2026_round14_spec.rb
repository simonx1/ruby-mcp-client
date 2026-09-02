# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, fourteenth review round: a decided
# composition stops evaluating branches, only an assertion that can still
# change the result is uncertainty, referenced targets are bounded by their
# own position, and boolean subschemas obey the depth bound.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 14' do
  let(:validator) { MCPClient::SchemaValidator }

  it 'stops a composition once its outcome is definite' do
    expect(validator.validate(1, { 'anyOf' => [true, { '$ref' => '#' }] })).to be_empty
    expect(validator.validate(1, { 'not' => { 'oneOf' => [true, true, { '$ref' => '#' }] } })).to be_empty
    expect(validator.validate(1, { 'not' => { 'allOf' => [false, { '$ref' => '#' }] } })).to be_empty
    huge = Array.new(validator::MAX_NODE_VISITS + 10, 1)
    expect(validator.validate(huge, { 'anyOf' => [true, { 'items' => true }] })).to be_empty
  end

  it 'counts only an assertion that can still change the result as uncertainty' do
    expect(validator.validate([], { 'not' => { 'minContains' => 1 } })).to contain_exactly(a_string_matching(/not/))
    expect(validator.validate([1], { 'if' => { 'maxContains' => 0 }, 'then' => false })).not_to be_empty
    expect(validator.validate([], { 'oneOf' => [{ 'minContains' => 1 }, { 'type' => 'array' }] }))
      .to contain_exactly(a_string_matching(/oneOf/))
    draft7 = { '$schema' => 'http://json-schema.org/draft-07/schema#',
               'not' => { 'additionalItems' => false, 'items' => { 'type' => 'number' } } }
    expect(validator.validate([1, 2], draft7)).to contain_exactly(a_string_matching(/not/))
    expect(validator.validate({}, { 'not' => { 'additionalProperties' => true } }))
      .to contain_exactly(a_string_matching(/not/))
    expect(validator.validate([1, 1],
                              { 'not' => { 'uniqueItems' => false } })).to contain_exactly(a_string_matching(/not/))
    expect(validator.validate({}, { 'oneOf' => [{ 'type' => 'object' }, { 'additionalProperties' => true }] }))
      .to contain_exactly(a_string_matching(/oneOf/))
    # Still genuinely undecided.
    expect(validator.validate([1],
                              { 'not' => { 'contains' => { 'type' => 'integer' }, 'minContains' => 2 } })).to be_empty
    expect(validator.validate({ 'a' => 1 }, { 'not' => { 'additionalProperties' => false } })).to be_empty
    expect(validator.validate([1, 1], { 'not' => { 'uniqueItems' => true } })).to be_empty
  end

  it 'bounds a referenced target by its own position, whatever the key order' do
    leaf = { '$ref' => '#/$defs/x' }
    nested = leaf
    (validator::MAX_SCHEMA_DEPTH - 1).times { nested = { 'type' => 'object', 'properties' => { 'a' => nested } } }
    defs_last = { 'type' => 'object', 'properties' => { 'a' => nested }, '$defs' => { 'x' => { 'type' => 'string' } } }
    defs_first = { '$defs' => { 'x' => { 'type' => 'string' } }, 'type' => 'object', 'properties' => { 'a' => nested } }
    expect(validator.check_schema(defs_first)).to eq(validator.check_schema(defs_last))
    expect(validator.check_schema(defs_last)).to be_empty
  end

  it 'charges a boolean target once, not per reference' do
    props = {}
    1500.times { |i| props["p#{i}"] = { '$ref' => '#/$defs/t' } }
    schema = { 'type' => 'object', 'properties' => props, '$defs' => { 't' => true } }
    expect(validator.check_schema(schema)).to be_empty
  end

  it 'applies the depth bound to boolean subschemas' do
    ending_true = true
    ending_object = {}
    (validator::MAX_SCHEMA_DEPTH + 1).times do
      ending_true = { 'not' => ending_true }
      ending_object = { 'not' => ending_object }
    end
    expect(validator.check_schema(ending_object)).to contain_exactly(a_string_matching(/depth/))
    expect(validator.check_schema(ending_true)).to contain_exactly(a_string_matching(/depth/))
  end
end
