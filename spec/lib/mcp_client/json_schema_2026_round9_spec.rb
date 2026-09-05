# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, ninth review round: plain-name
# anchors come only from schema positions the dialect walks, an embedded
# resource's `$schema` is its dialect, wide documents are rejected before
# they are copied, and numeric messages clip what they quote.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 9' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'anchors only from schema positions' do
    it 'does not take an $anchor from a bag under a keyword no dialect defines' do
      schema = {
        'type' => 'object',
        'properties' => { 'a' => { '$ref' => '#trap' } },
        'x-defs' => { 'x' => { '$anchor' => 'trap', 'type' => 'string' } }
      }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref "#trap"/))
      expect(validator.validate({ 'a' => 'ok' }, schema)).to contain_exactly(a_string_matching(/unresolvable/))
    end

    it 'still resolves a pointer into that bag' do
      schema = { 'properties' => { 'a' => { '$ref' => '#/x-defs/x' } },
                 'x-defs' => { 'x' => { 'type' => 'string' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'takes no draft-07 identifier from $defs beside a $ref' do
      schema = {
        '$schema' => draft7,
        'properties' => {
          'a' => { '$ref' => '#trap' },
          'b' => { '$ref' => '#/definitions/x', '$defs' => { 't' => { '$id' => '#trap', 'type' => 'string' } } }
        },
        'definitions' => { 'x' => { 'type' => 'integer' } }
      }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref "#trap"/))
    end

    it 'takes no draft-07 identifier from a root $defs bag' do
      schema = { '$schema' => draft7, 'properties' => { 'a' => { '$ref' => '#trap' } },
                 '$defs' => { 't' => { '$id' => '#trap', 'type' => 'string' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref "#trap"/))
    end

    it 'takes identifiers from the definition bag the dialect does define' do
      schema = { '$schema' => draft7, 'properties' => { 'a' => { '$ref' => '#ok' } },
                 'definitions' => { 't' => { '$id' => '#ok', 'type' => 'string' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end
  end

  describe 'embedded resource dialects' do
    let(:schema) do
      {
        'properties' => {
          'child' => {
            '$id' => 'https://example.com/child',
            '$schema' => draft7,
            '$ref' => '#/definitions/x',
            'type' => 'string',
            'definitions' => { 'x' => { 'type' => 'integer', '$id' => '#int' } },
            'properties' => { 'anchored' => { '$ref' => '#int' } }
          }
        }
      }
    end

    it 'applies the embedded $schema to the embedded resource' do
      expect(validator.check_schema(schema)).to be_empty
      # draft-07 in the child: the $ref replaces its siblings, so 1 is valid.
      expect(validator.validate({ 'child' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'child' => 'x' },
                                schema)).to contain_exactly(a_string_matching(/expected type integer/))
    end

    it 'indexes the embedded resource anchors in the embedded dialect' do
      inner = { 'properties' => { 'child' => { '$id' => 'https://example.com/c', '$schema' => draft7,
                                               'definitions' => { 'x' => { '$id' => '#int', 'type' => 'integer' } },
                                               'properties' => { 'v' => { '$ref' => '#int' } } } } }
      expect(validator.check_schema(inner)).to be_empty
      expect(validator.validate({ 'child' => { 'v' => 'x' } }, inner))
        .to contain_exactly(a_string_matching(%r{#/child/v: expected type integer}))
    end

    it 'rejects an embedded $schema that is malformed or unsupported' do
      bad = { 'properties' => { 'c' => { '$id' => 'https://example.com/c', '$schema' => 7 } } }
      expect(validator.check_schema(bad)).to contain_exactly(a_string_matching(/\$schema/))
      old = { 'properties' => { 'c' => { '$id' => 'https://example.com/c',
                                         '$schema' => 'http://json-schema.org/draft-04/schema#' } } }
      expect(validator.check_schema(old)).to contain_exactly(a_string_matching(/draft-04.*not supported/))
      expect(validator.validate({}, old)).to contain_exactly(a_string_matching(/not supported/))
    end

    it 'ignores a $schema that is not at a resource root' do
      schema = { 'properties' => { 'c' => { '$schema' => 'http://json-schema.org/draft-04/schema#',
                                            'type' => 'string' } } }
      expect(validator.check_schema(schema)).to be_empty
    end
  end

  describe 'bounds and messages' do
    it 'rejects a wide array of boolean schemas before copying it' do
      wide = Array.new(validator::MAX_STRUCTURAL_OBJECTS + 10, true)
      expect(validator.check_schema({ 'anyOf' => wide })).to contain_exactly(a_string_matching(/structural elements/))
      expect(validator.validate(1, { 'anyOf' => wide })).to contain_exactly(a_string_matching(/structural elements/))
    end

    it 'clips the values quoted by numeric bound errors' do
      huge = 10**500
      errors = validator.validate(huge, { 'maximum' => 1, 'exclusiveMaximum' => 1 })
      expect(errors.size).to eq(2)
      expect(errors.map(&:length).max).to be < 250
      expect(validator.validate(5, { 'minimum' => huge }).first.length).to be < 250
    end
  end
end
