# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, twelfth review round: a `$id`
# resource the anchor index could not reach is truncation, a reference from
# an unindexed schema never falls back to the document root, and a branch
# is undecided only while an unevaluated assertion that applies to the
# instance remains (annotations such as `format` decide nothing).
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 12' do
  let(:validator) { MCPClient::SchemaValidator }

  describe 'resources beyond the index depth' do
    let(:schema) do
      inner = { '$id' => 'https://example.com/deep', 'type' => 'object',
                'properties' => { 'v' => { '$ref' => '#' } } }
      (validator::MAX_SCHEMA_DEPTH + 1).times { inner = { 'not' => inner } }
      { 'properties' => { 'a' => { '$ref' => "#/definitions/x#{'/not' * (validator::MAX_SCHEMA_DEPTH + 1)}" } },
        'definitions' => { 'x' => inner } }
    end

    it 'makes the schema unusable instead of resolving # against the document root' do
      # Since round 14 the target is bounded by its own (too deep) position.
      expect(validator.check_schema(schema)).to include(a_string_matching(/anchors|unresolvable|depth/))
      expect(validator.validate({ 'a' => { 'v' => 'nope' } }, schema)).not_to be_empty
    end

    it 'never resolves a reference from a schema the index does not know' do
      index = validator.anchor_index({ 'type' => 'object' }, validator::DEFAULT_DIALECT)
      stranger = { '$ref' => '#' }
      resolved = validator.resolve_reference({ 'type' => 'object' }, '#', validator::DEFAULT_DIALECT,
                                             { anchors: index }, from: stranger)
      expect(resolved).to equal(validator::UNRESOLVED)
    end
  end

  describe 'undecided branches' do
    it 'treats format as an annotation that decides nothing' do
      expect(validator.validate(1, { 'not' => { 'format' => 'email' } })).to contain_exactly(a_string_matching(/not/))
      expect(validator.validate(1, { 'not' => { 'type' => 'integer', 'format' => 'int32' } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate('x', { 'if' => { 'format' => 'email' }, 'then' => false }))
        .to contain_exactly(a_string_matching(/false/))
    end

    it 'counts a branch decided by its evaluated keywords in oneOf' do
      schema = { 'oneOf' => [{ 'type' => 'integer' }, { 'type' => 'integer', 'format' => 'int32' }] }
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/oneOf/))
    end

    it 'ignores an unevaluated assertion that does not apply to the instance' do
      expect(validator.validate('x', { 'not' => { 'unevaluatedProperties' => false } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate(3, { 'not' => { 'unevaluatedItems' => false } }))
        .to contain_exactly(a_string_matching(/not/))
    end

    it 'stays undecided for an unevaluated assertion that applies to the instance' do
      expect(validator.validate({ 'a' => 1 }, { 'not' => { 'unevaluatedProperties' => false } })).to be_empty
      expect(validator.validate([1], { 'not' => { 'unevaluatedItems' => false } })).to be_empty
      expect(validator.validate([1], { 'oneOf' => [{ 'type' => 'array' }, { 'unevaluatedItems' => false }] }))
        .to be_empty
    end

    it 'decides a branch whose only assertion the validator now evaluates' do
      expect(validator.validate([1, 1], { 'not' => { 'uniqueItems' => true } })).to be_empty
      expect(validator.validate([1, 2], { 'not' => { 'uniqueItems' => true } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate({ 'a' => 1 }, { 'not' => { 'additionalProperties' => false } })).to be_empty
      expect(validator.validate({}, { 'not' => { 'additionalProperties' => false } }))
        .to contain_exactly(a_string_matching(/not/))
    end
  end
end
