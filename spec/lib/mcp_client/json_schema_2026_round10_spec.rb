# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, tenth review round: a `$ref` chain
# that crosses into an embedded resource is followed by where each hop
# lands, not by the text of its fragment, and an anchor declared twice in
# one schema resource makes the schema unusable.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 10' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'reference chains across resources' do
    let(:schema) do
      {
        'properties' => { 'a' => { '$ref' => '#/$defs/x' } },
        '$defs' => {
          'x' => {
            '$id' => 'https://example.com/inner',
            '$ref' => '#/$defs/x',
            '$defs' => { 'x' => { 'type' => 'string' } }
          }
        }
      }
    end

    it 'follows the same fragment text into an embedded resource without calling it a cycle' do
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 'ok' }, schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'still reports a chain that returns to a schema it visited' do
      cyclic = { 'properties' => { 'a' => { '$ref' => '#/$defs/x' } },
                 '$defs' => { 'x' => { '$ref' => '#/$defs/y' }, 'y' => { '$ref' => '#/$defs/x' } } }
      expect(validator.check_schema(cyclic)).to contain_exactly(a_string_matching(/cycles/))
    end
  end

  describe 'duplicate anchors' do
    it 'rejects an $anchor declared twice in one resource' do
      schema = {
        'properties' => { 'a' => { '$ref' => '#node' } },
        '$defs' => { 'x' => { '$anchor' => 'node', 'type' => 'string' },
                     'y' => { '$anchor' => 'node', 'type' => 'integer' } }
      }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/anchor "node".*more than once/))
      expect(validator.validate({ 'a' => 'ok' }, schema)).to contain_exactly(a_string_matching(/anchor "node"/))
    end

    it 'rejects a $dynamicAnchor colliding with an $anchor' do
      schema = { '$defs' => { 'x' => { '$anchor' => 'node' }, 'y' => { '$dynamicAnchor' => 'node' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/anchor "node".*more than once/))
    end

    it 'rejects a draft-07 fragment $id declared twice' do
      schema = { '$schema' => draft7,
                 'definitions' => { 'x' => { '$id' => '#node' }, 'y' => { '$id' => '#node' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/anchor "node".*more than once/))
    end

    it 'allows the same name in different resources' do
      schema = {
        'properties' => { 'a' => { '$ref' => '#node' } },
        '$defs' => { 'x' => { '$anchor' => 'node', 'type' => 'string' },
                     'y' => { '$id' => 'https://example.com/other', '$anchor' => 'node', 'type' => 'integer' } }
      }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end
  end
end
