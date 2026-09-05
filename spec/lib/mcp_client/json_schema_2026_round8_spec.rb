# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, eighth review round: pointer
# fragments are relative to the schema resource the `$ref` sits in, the
# unsupported-keyword scan follows local references, an `if` without a
# branch is inert, and a schema wider than the bounds is rejected before it
# is copied whole.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 8' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'resource-relative pointer fragments' do
    let(:schema) do
      {
        'type' => 'object',
        '$defs' => { 'n' => { 'type' => 'string' } },
        'properties' => {
          'child' => {
            '$id' => 'https://example.com/child',
            'type' => 'object',
            '$defs' => { 'n' => { 'type' => 'integer' } },
            'properties' => { 'inner' => { '$ref' => '#/$defs/n' }, 'self' => { '$ref' => '#' } }
          }
        }
      }
    end

    it 'resolves a pointer inside an embedded resource against that resource' do
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'child' => { 'inner' => 1 } }, schema)).to be_empty
      expect(validator.validate({ 'child' => { 'inner' => 'x' } }, schema))
        .to contain_exactly(a_string_matching(%r{#/child/inner: expected type integer}))
    end

    it 'resolves "#" inside an embedded resource to that resource' do
      expect(validator.validate({ 'child' => { 'self' => { 'inner' => 2 } } }, schema)).to be_empty
      expect(validator.validate({ 'child' => { 'self' => 'x' } }, schema))
        .to contain_exactly(a_string_matching(%r{#/child/self: expected type object}))
    end

    it 'reports a pointer that only exists in the enclosing document' do
      schema['properties']['child']['properties']['outer'] = { '$ref' => '#/properties/child' }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end
  end

  describe 'unsupported keywords behind local references' do
    it 'scans a target inside a definition bag the dialect does not walk' do
      # draft-07 predates `$defs`, so nothing walks it there: only following
      # the reference reaches what it holds.
      schema = { '$schema' => draft7, 'type' => 'object',
                 'properties' => { 'email' => { '$ref' => '#/$defs/email' } },
                 '$defs' => { 'email' => { 'type' => 'string', 'format' => 'email' } } }
      expect(validator.unsupported_keywords(schema)).to eq(['format'])
    end

    it 'scans a target reached through an anchor and stops at a cycle' do
      schema = { 'properties' => { 'a' => { '$ref' => '#node' } },
                 '$defs' => { 'n' => { '$anchor' => 'node', 'format' => 'uri', 'items' => { '$ref' => '#node' } } } }
      expect(validator.unsupported_keywords(schema)).to eq(['format'])
    end

    it 'ignores keywords beside a draft-07 $ref' do
      schema = { '$schema' => draft7, '$ref' => '#/definitions/x', 'format' => 'email',
                 'definitions' => { 'x' => { 'type' => 'string' } } }
      expect(validator.unsupported_keywords(schema)).to be_empty
    end
  end

  describe 'an if without branches' do
    it 'is not evaluated' do
      expect(validator.check_schema({ 'if' => { '$ref' => '#' } })).to be_empty
      expect(validator.validate(1, { 'if' => { '$ref' => '#' } })).to be_empty
      expect(validator.validate(1, { 'if' => { 'type' => 'string' } })).to be_empty
    end

    it 'still selects a branch when one exists' do
      expect(validator.validate(1, { 'if' => { 'type' => 'string' }, 'else' => false })).not_to be_empty
      expect(validator.validate('s', { 'if' => { 'type' => 'string' }, 'then' => { 'minLength' => 3 } }))
        .not_to be_empty
    end
  end

  describe 'a schema wider than the bounds' do
    let(:recorder) do
      Class.new(Hash) do
        def self.visits = @visits ||= [0]

        def to_h(&)
          self.class.visits[0] += 1
          super
        end
      end
    end

    let(:huge) do
      props = {}
      (validator::MAX_SUBSCHEMAS * 8).times { |i| props["p#{i}"] = recorder[{ 'type' => 'string' }] }
      { 'type' => 'object', 'properties' => props }
    end

    it 'is rejected before it is copied whole' do
      expect(validator.check_schema(huge)).to contain_exactly(a_string_matching(/more than/))
      expect(recorder.visits[0]).to be < validator::MAX_SUBSCHEMAS * 8
      expect(validator.validate({}, huge)).to contain_exactly(a_string_matching(/more than/))
      expect(validator.unsupported_keywords(huge)).to eq([])
    end
  end
end
