# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, sixth review round: exclusive bounds
# are numbers under every supported dialect (the boolean modifier form is
# draft-04), inclusive and exclusive bounds are independent assertions,
# each validation error counts once, and percent-encoded plain-name
# fragments resolve to their anchor.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 6' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:draft2019) { 'https://json-schema.org/draft/2019-09/schema' }

  describe 'exclusive bounds' do
    it 'evaluates numeric exclusiveMinimum / exclusiveMaximum under draft-07 like the later drafts' do
      min = { '$schema' => draft7, 'type' => 'number', 'exclusiveMinimum' => 5 }
      max = { '$schema' => draft7, 'type' => 'number', 'exclusiveMaximum' => 10 }
      expect(validator.check_schema(min)).to be_empty
      expect(validator.check_schema(max)).to be_empty
      expect(validator.validate(5, min)).to contain_exactly(a_string_matching(/greater than/))
      expect(validator.validate(6, min)).to be_empty
      expect(validator.validate(10, max)).to contain_exactly(a_string_matching(/less than/))
      expect(validator.validate(9, max)).to be_empty
    end

    it 'rejects the draft-04 boolean form under every supported dialect' do
      [draft7, draft2019, nil].each do |dialect|
        schema = { 'minimum' => 5, 'exclusiveMinimum' => true, 'exclusiveMaximum' => false }
        schema['$schema'] = dialect if dialect
        expect(validator.check_schema(schema))
          .to contain_exactly(a_string_matching(/exclusiveMinimum.*number/),
                              a_string_matching(/exclusiveMaximum.*number/)),
              "expected the boolean form to be rejected under #{dialect.inspect}"
      end
    end

    it 'applies minimum and exclusiveMinimum (maximum and exclusiveMaximum) independently' do
      schema = { 'type' => 'number', 'minimum' => 10, 'exclusiveMinimum' => 5,
                 'maximum' => 20, 'exclusiveMaximum' => 30 }
      expect(validator.validate(7, schema)).to contain_exactly(a_string_matching(/less than minimum 10/))
      expect(validator.validate(5, schema))
        .to contain_exactly(a_string_matching(/less than minimum 10/),
                            a_string_matching(/greater than exclusiveMinimum 5/))
      expect(validator.validate(25, schema)).to contain_exactly(a_string_matching(/greater than maximum 20/))
      expect(validator.validate(30, schema))
        .to contain_exactly(a_string_matching(/greater than maximum 20/),
                            a_string_matching(/less than exclusiveMaximum 30/))
      expect(validator.validate(15, schema)).to be_empty
    end
  end

  describe 'error accounting' do
    it 'counts each array element error once' do
      count = (validator::MAX_ERRORS / 2) + 1
      errors = validator.validate(Array.new(count, 'x'), { 'type' => 'array', 'items' => { 'type' => 'integer' } })
      expect(errors.size).to eq(count)
      expect(errors).to all(match(/expected type integer/))
    end

    it 'counts nested object errors once through every ancestor' do
      count = (validator::MAX_ERRORS / 3) + 1
      leaf = { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer' } } }
      schema = { 'type' => 'object',
                 'properties' => { 'items' => { 'type' => 'array', 'items' => { 'allOf' => [leaf] } } } }
      data = { 'items' => Array.new(count) { { 'n' => 'x' } } }
      errors = validator.validate(data, schema)
      expect(errors.size).to eq(count)
      expect(errors).to all(match(/expected type integer/))
    end

    it 'still aborts once the bound is really exceeded' do
      errors = validator.validate(Array.new(validator::MAX_ERRORS + 1, 'x'),
                                  { 'type' => 'array', 'items' => { 'type' => 'integer' } })
      expect(errors).to contain_exactly(a_string_matching(/more than #{validator::MAX_ERRORS}/))
    end
  end

  describe 'anchors' do
    it 'percent-decodes a plain-name fragment before looking up the anchor' do
      schema = { 'type' => 'object',
                 'properties' => { 'a' => { '$ref' => '#foo%2Dbar' } },
                 '$defs' => { 'x' => { '$anchor' => 'foo-bar', 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'a' => 'x' }, schema)).to contain_exactly(a_string_matching(/expected type integer/))
    end

    it 'keeps an unknown anchor unresolvable after decoding' do
      schema = { '$ref' => '#no%2Dsuch', '$defs' => { 'x' => { '$anchor' => 'other' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable/))
    end
  end
end
