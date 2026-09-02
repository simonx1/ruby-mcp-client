# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, sixteenth review round: a pointer
# target's depth counts schema steps, positions under data or unknown
# keywords are bounded too, and an assertion is uncertainty only when it
# can still change this instance.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 16' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:max) { validator::MAX_SCHEMA_DEPTH }

  def nested_properties(depth, leaf)
    (1..depth).reduce(leaf) { |inner, _| { 'properties' => { 'a' => inner } } }
  end

  def nested_not(depth, leaf)
    (1..depth).reduce(leaf) { |inner, _| { 'not' => inner } }
  end

  it 'counts schema steps, not tokens, for a boolean under a map or array keyword' do
    base = nested_properties(max - 1, { 'properties' => { 'b' => true } })
    expect(validator.check_schema(base)).to be_empty

    pointer = "##{'/properties/a' * (max - 1)}/properties/b"
    expect(validator.check_schema(base.merge('allOf' => [{ '$ref' => pointer }]))).to be_empty

    defs = { '$defs' => { 't' => nested_not(max - 1, true) },
             'allOf' => [{ '$ref' => "#/$defs/t#{'/not' * (max - 1)}" }] }
    expect(validator.check_schema(defs)).to be_empty

    tuple = { 'prefixItems' => [nested_not(max - 1, true)],
              'not' => { '$ref' => "#/prefixItems/0#{'/not' * (max - 1)}" } }
    expect(validator.check_schema(tuple)).to be_empty

    composed = { 'allOf' => [nested_not(max - 1, true)], 'not' => { '$ref' => "#/allOf/0#{'/not' * (max - 1)}" } }
    expect(validator.check_schema(composed)).to be_empty

    too_deep = { '$defs' => { 't' => nested_not(max, true) }, 'allOf' => [{ '$ref' => "#/$defs/t#{'/not' * max}" }] }
    expect(validator.check_schema(too_deep)).to contain_exactly(a_string_matching(/depth/))
  end

  it 'bounds a reference into a data or unknown keyword by its position' do
    deep = nested_not(max + 5, true)
    %w[default enum const examples x-custom].each do |keyword|
      holder = %w[enum examples].include?(keyword) ? [deep] : deep
      prefix = %w[enum examples].include?(keyword) ? "#/#{keyword}/0" : "#/#{keyword}"
      schema = { 'properties' => { 'a' => { '$ref' => "#{prefix}#{'/not' * (max + 5)}" } }, keyword => holder }
      expect(validator.check_schema(schema)).to include(a_string_matching(/depth|unresolvable/)), keyword
      expect(validator.validate({ 'a' => 1 }, schema)).not_to be_empty, keyword
    end

    deep_object = nested_not(max + 5, {})
    schema = { 'properties' => { 'a' => { '$ref' => "#/default#{'/not' * (max + 5)}" } }, 'default' => deep_object }
    expect(validator.check_schema(schema)).to include(a_string_matching(/depth|unresolvable/))
  end

  it 'decodes a percent-encoded pointer before placing its target' do
    deep = nested_not(max + 5, true)
    schema = { 'properties' => { 'a' => { '$ref' => "#%2Fdefault#{'%2Fnot' * (max + 5)}" } }, 'default' => deep }
    expect(validator.check_schema(schema)).to include(a_string_matching(/depth|unresolvable/))

    fine = { 'properties' => { 'a' => { '$ref' => '#%2F$defs%2Ft' } }, '$defs' => { 't' => { 'type' => 'integer' } } }
    expect(validator.check_schema(fine)).to be_empty
    expect(validator.validate({ 'a' => 'x' }, fine)).not_to be_empty
  end

  it 'treats additionalItems false as decided when the tuple covers the instance' do
    schema = { '$schema' => draft7, 'not' => { 'items' => [true], 'additionalItems' => false } }
    expect(validator.validate([1], schema)).to contain_exactly(a_string_matching(/not/))
    expect(validator.validate([1, 2], schema)).to be_empty
    expect(validator.validate([], schema)).to contain_exactly(a_string_matching(/not/))
  end

  it 'treats contains as decided when minContains is 0' do
    schema = { 'not' => { 'contains' => true, 'minContains' => 0 } }
    expect(validator.validate([], schema)).to contain_exactly(a_string_matching(/not/))
    expect(validator.validate([1], schema)).to contain_exactly(a_string_matching(/not/))

    one_of = { 'oneOf' => [{ 'type' => 'array' }, { 'contains' => true, 'minContains' => 0 }] }
    expect(validator.validate([1], one_of)).to contain_exactly(a_string_matching(/oneOf/))

    conditional = { 'if' => { 'contains' => true, 'minContains' => 0 }, 'then' => false }
    expect(validator.validate([], conditional)).not_to be_empty

    still_open = { 'not' => { 'contains' => { 'type' => 'string' } } }
    expect(validator.validate([1], still_open)).to be_empty
  end
end
