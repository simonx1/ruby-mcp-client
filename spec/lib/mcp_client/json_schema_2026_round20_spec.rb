# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, twentieth round: more unevaluated
# assertions that cannot change the instance decide nothing under not /
# oneOf / if, a boolean in a position the walk never visits is charged when
# a reference reaches it, the keyword scan follows a pointer into a data
# keyword at the target's own position, and a symbol-keyed target adopted
# from a data keyword is copied within the structural budget.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 20' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  def nested(keyword, count, leaf)
    count.times.reduce(leaf) { |inner, _| { keyword => inner } }
  end

  describe 'inert unevaluated assertions' do
    it 'treats contains true or {} on an array that satisfies minContains as decided' do
      expect(validator.validate([1], { 'not' => { 'contains' => true } })).not_to be_empty
      expect(validator.validate([1], { 'not' => { 'contains' => {} } })).not_to be_empty
      expect(validator.validate([1], { 'oneOf' => [{ 'type' => 'array' }, { 'contains' => true }] })).not_to be_empty
      expect(validator.validate([1], { 'if' => { 'contains' => true }, 'then' => false })).not_to be_empty
      # An empty array fails contains true (default minContains 1): a real assertion.
      expect(validator.validate([], { 'not' => { 'contains' => true } })).to be_empty
      # A contains schema the validator cannot evaluate stays undecided.
      expect(validator.validate([1], { 'not' => { 'contains' => { 'type' => 'string' } } })).to be_empty
    end

    it 'treats unevaluatedItems as inert once contains evaluated every item' do
      expect(validator.validate([1], { 'not' => { 'contains' => true, 'unevaluatedItems' => false } })).not_to be_empty
      schema = { 'not' => { 'contains' => true, 'minContains' => 0, 'unevaluatedItems' => false } }
      expect(validator.validate([1], schema)).not_to be_empty
    end

    it 'treats patternProperties matching nothing or only tautologies as inert' do
      inert = { 'not' => { 'patternProperties' => { '^z' => { 'type' => 'string' } } } }
      expect(validator.validate({ 'a' => 1 }, inert)).not_to be_empty
      schema = { 'not' => { 'patternProperties' => { '.*' => true }, 'additionalProperties' => false } }
      expect(validator.validate({ 'a' => 1 }, schema)).not_to be_empty
      # A matching pattern with a real schema still leaves the branch undecided.
      live = { 'not' => { 'patternProperties' => { '^a' => { 'type' => 'string' } } } }
      expect(validator.validate({ 'a' => 1 }, live)).to be_empty
    end

    it 'treats dependencies whose present trigger cannot fail as inert' do
      expect(validator.validate({ 'a' => 1 }, { 'not' => { 'dependentRequired' => { 'a' => [] } } })).not_to be_empty
      expect(validator.validate({ 'a' => 1 }, { 'not' => { 'dependentSchemas' => { 'a' => true } } })).not_to be_empty
      draft = { '$schema' => draft7, 'not' => { 'dependencies' => { 'a' => {} } } }
      expect(validator.validate({ 'a' => 1 }, draft)).not_to be_empty
      expect(validator.validate({ 'a' => 1 }, { 'not' => { 'dependentRequired' => { 'a' => ['b'] } } })).to be_empty
    end
  end

  it 'charges booleans beside a draft-07 $ref (a position the walk never visits) toward the subschema bound' do
    count = validator::MAX_SUBSCHEMAS - 200
    props = (0...count).to_h { |i| ["p#{i}", { '$ref' => "#/definitions/hidden/allOf/#{i}" }] }
    schema = { '$schema' => draft7, 'type' => 'object', 'properties' => props,
               'definitions' => { 'hidden' => { '$ref' => '#/definitions/x', 'allOf' => Array.new(count, true) },
                                  'x' => { 'type' => 'integer' } } }

    expect(validator.check_schema(schema))
      .to contain_exactly(a_string_matching(/more than #{validator::MAX_SUBSCHEMAS}/))
  end

  it 'scans a data-keyword $ref target at its own position even from a referrer at the depth bound' do
    leaf = nested('properties', 0, { '$ref' => '#/default' })
    validator::MAX_SCHEMA_DEPTH.times { leaf = { 'properties' => { 'a' => leaf } } }
    schema = leaf.merge('default' => { 'type' => 'array', 'uniqueItems' => true })

    expect(validator.check_schema(schema)).to be_empty
    expect(validator.unsupported_keywords(schema)).to eq(['uniqueItems'])
  end

  it 'copies a symbol-keyed target adopted from a data keyword within the structural budget' do
    huge = {}
    (validator::MAX_STRUCTURAL_OBJECTS + 50).times { |i| huge[:"k#{i}"] = i }

    expect(validator.check_schema({ '$ref': '#/default', default: huge }))
      .to contain_exactly(a_string_matching(/structural elements/))
  end
end
