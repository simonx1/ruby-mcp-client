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

  describe 'names of a resource reached through a foreign bag' do
    let(:schema) do
      {
        'properties' => { 'a' => { '$ref' => '#/definitions/x' } },
        'definitions' => {
          'x' => { '$id' => 'https://example.com/x', '$anchor' => 'trap', 'type' => 'object',
                   'properties' => { 'v' => { '$ref' => '#trap' } } }
        }
      }
    end

    it 'resolves the resource\'s own anchor even when the resource sits in a bag the dialect does not walk' do
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => { 'v' => {} } }, schema)).to be_empty
      expect(validator.validate({ 'a' => { 'v' => 1 } },
                                schema)).to contain_exactly(a_string_matching(/expected type object/))
    end

    it 'still hides that name from the enclosing resource' do
      schema['properties']['b'] = { '$ref' => '#trap' }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref "#trap"/))
    end
  end

  describe 'wide leaf maps' do
    it 'rejects a wide map of leaf values before copying it' do
      huge = {}
      (validator::MAX_STRUCTURAL_OBJECTS + 10).times { |i| huge["k#{i}"] = i }
      schema = { 'type' => 'integer', 'x-huge' => huge }
      allow(huge).to receive(:to_h).and_raise('the map must not be copied whole')
      allow(huge).to receive(:each).and_raise('the map must not be copied whole')
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/structural elements/))
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/structural elements/))
    end

    it 'runs the normalization under the validation deadline' do
      schema = { 'type' => 'integer', 'x-slow' => { 'k' => 1 } }
      past = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
      expect(validator.validate(1, schema, deadline: past)).to contain_exactly(a_string_matching(/aborted|time/))
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
