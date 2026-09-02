# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, twenty-fifth round: the keyword scan
# survives a local `$ref` that points at a non-schema-object member, so an
# accepted schema never turns a successful call into an exception; `contains`
# bounds that no count can satisfy fail on the bounds alone, before any appeal
# to an item schema the validator cannot decide, so a non-monotonic
# composition does not fail open on them; and the walk over an instance is
# depth-bounded, so data nested deeper than the interpreter's stack allows
# aborts with one validation error instead of a SystemStackError.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 25' do
  let(:validator) { MCPClient::SchemaValidator }

  describe 'the keyword scan over a $ref to a non-object member' do
    it 'scans a reference to a number beside a definition bag without raising' do
      schema = { 'definitions' => {}, 'x' => 1.5, '$ref' => '#/x' }

      expect { validator.unsupported_keywords(schema) }.not_to raise_error
      expect(validator.unsupported_keywords(schema)).to be_empty
    end

    it 'scans a reference to a boolean vendor member without raising' do
      schema = { '$ref' => '#/x', 'x' => true }

      expect { validator.unsupported_keywords(schema) }.not_to raise_error
      expect(validator.unsupported_keywords(schema)).to be_empty
    end

    it 'leaves such a schema usable end to end' do
      schema = { '$ref' => '#/x', 'x' => true }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(1, schema)).to be_empty
    end

    it 'still reports the keywords a reference to a schema object reaches' do
      schema = { 'definitions' => {}, 'x' => 1.5, '$ref' => '#/y',
                 'y' => { 'type' => 'array', 'uniqueItems' => true } }

      expect(validator.unsupported_keywords(schema)).to contain_exactly('uniqueItems')
    end
  end

  describe 'contains bounds no count can satisfy' do
    it 'fails a contains whose minContains default exceeds its maxContains' do
      schema = { 'contains' => { 'type' => 'string' }, 'maxContains' => 0 }

      expect(validator.validate([1, 2], schema))
        .to contain_exactly(a_string_matching(/matching items/))
    end

    it 'fails such a contains whatever the item schema is' do
      schema = { 'contains' => { 'not' => false }, 'minContains' => 3, 'maxContains' => 2 }

      expect(validator.validate([1, 2, 3, 4], schema))
        .to contain_exactly(a_string_matching(/matching items/))
    end

    it 'does not let an anyOf branch pass on bounds that cannot overlap' do
      schema = { 'anyOf' => [{ 'contains' => { 'type' => 'string' }, 'maxContains' => 0 }] }

      expect(validator.validate([1, 2], schema))
        .to contain_exactly(a_string_matching(/does not satisfy any schema in anyOf/))
    end

    it 'takes the else branch when the if branch is unsatisfiable on its bounds' do
      schema = { 'if' => { 'contains' => { 'type' => 'string' }, 'maxContains' => 0 },
                 'then' => true, 'else' => false }

      expect(validator.validate([1, 2], schema))
        .to contain_exactly(a_string_matching(/schema false accepts no value/))
    end

    it 'counts such a oneOf branch as no match rather than as undecided' do
      schema = { 'oneOf' => [{ 'contains' => { 'type' => 'string' }, 'maxContains' => 0 },
                             { 'type' => 'string' }] }

      expect(validator.validate([1, 2], schema))
        .to contain_exactly(a_string_matching(/satisfies 0 schemas in oneOf/))
    end

    it 'keeps a tautological non-literal contains bounded by the array length' do
      expect(validator.validate([1, 2], { 'contains' => { 'not' => false } })).to be_empty
      expect(validator.validate([1, 2], { 'contains' => { '$ref' => '#/$defs/any' },
                                          '$defs' => { 'any' => true } })).to be_empty
    end

    it 'still leaves bounds the array length cannot settle unevaluated' do
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' } })).to be_empty
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' },
                                          'minContains' => 0, 'maxContains' => 0 })).to be_empty
    end

    it 'leaves a draft-07 maxContains alone, the dialect not defining it' do
      schema = { '$schema' => 'http://json-schema.org/draft-07/schema#',
                 'contains' => { 'type' => 'string' }, 'maxContains' => 0 }

      expect(validator.validate([1, 2], schema)).to be_empty
    end
  end

  describe 'an instance nested deeper than the walk can follow' do
    let(:recursive) { { 'type' => 'array', 'items' => { '$ref' => '#' } } }

    def nest(depth, seed = [])
      (1..depth).reduce(seed) { |nested, _| [nested] }
    end

    it 'aborts with a single validation error instead of a SystemStackError' do
      expect(validator.validate(nest(5000), recursive))
        .to contain_exactly(a_string_matching(/validation aborted/))
    end

    it 'aborts on a thread with a smaller stack too' do
      result = Thread.new { validator.validate(nest(5000), recursive) }.value

      expect(result).to contain_exactly(a_string_matching(/validation aborted/))
    end

    it 'still accepts data nested as deeply as the wire allows' do
      data = nest(99)

      expect(JSON.parse(JSON.generate(data))).to eq(data)
      expect(validator.validate(data, recursive)).to be_empty
    end

    it 'still validates and reports at ordinary depths' do
      expect(validator.validate(nest(40), recursive)).to be_empty
      expect(validator.validate(nest(40, ['x']), recursive))
        .to contain_exactly(a_string_matching(/expected type array, got string/))
    end
  end
end
