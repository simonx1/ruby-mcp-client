# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, twenty-third round: the JSON pointer
# "/" addresses the member named "" and not the whole document, a
# tautological `contains` is an assertion this validator decides rather than
# a keyword that leaves a branch undecided, and a `dependentRequired` (or
# draft-07 `dependencies`) list whose names the instance already carries
# cannot fail.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 23' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'the pointer to the empty-named member' do
    it 'resolves "#/" to the member named "" (RFC 6901 Section 5)' do
      schema = { '$ref' => '#/', '' => { 'type' => 'string', 'minLength' => 2 } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('ab', schema)).to be_empty
      expect(validator.validate('a', schema))
        .to contain_exactly(a_string_matching(/string is shorter than minLength 2/))
    end

    it 'resolves the percent-encoded form "#%2F" the same way' do
      schema = { '$ref' => '#%2F', '' => { 'type' => 'integer' } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(1, schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/expected type integer/))
    end

    it 'reports "#/" without an empty-named member as unresolvable, not as a cycle' do
      expect(validator.check_schema({ '$ref' => '#/' }))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end

    it 'still reads the empty pointer "#" as the whole document' do
      expect(validator.check_schema({ '$ref' => '#' })).to contain_exactly(a_string_matching(/cycles/))
    end

    it 'walks on past an empty token to the members below it' do
      schema = { '$ref' => '#//x', '' => { 'x' => { 'type' => 'boolean' } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(true, schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/expected type boolean/))
    end

    it 'keeps reading a trailing empty token as the empty-named member' do
      schema = { '$ref' => '#/$defs/', '$defs' => { '' => { 'type' => 'null' } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(nil, schema)).to be_empty
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type null/))
    end

    it 'reaches a boolean schema held by the empty-named member' do
      schema = { '$ref' => '#/', '' => false }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/schema false accepts no value/))
    end
  end

  describe 'a tautological contains' do
    it 'fails an array that holds fewer items than minContains requires' do
      expect(validator.validate([], { 'contains' => true }))
        .to contain_exactly(a_string_matching(/at least 1 items matching contains/))
      expect(validator.validate([1], { 'contains' => true })).to be_empty
      expect(validator.validate([1, 2, 3], { 'contains' => {}, 'minContains' => 5 }))
        .to contain_exactly(a_string_matching(/at least 5 items matching contains/))
    end

    it 'fails an array that holds more items than maxContains allows' do
      expect(validator.validate([1, 2, 3], { 'contains' => true, 'maxContains' => 2 }))
        .to contain_exactly(a_string_matching(/at most 2 items matching contains/))
      expect(validator.validate([1, 2], { 'contains' => true, 'maxContains' => 2 })).to be_empty
    end

    it 'asserts nothing once minContains switches it off' do
      expect(validator.validate([], { 'contains' => true, 'minContains' => 0 })).to be_empty
    end

    it 'takes the default minContains under a dialect without the companion' do
      schema = { '$schema' => draft7, 'contains' => true, 'minContains' => 0 }

      # draft-07 knows no minContains, so the default of 1 stands.
      expect(validator.validate([], schema)).to contain_exactly(a_string_matching(/at least 1 items matching contains/))
    end

    it 'decides the branches that never treat an undecided verdict as a match' do
      expect(validator.validate([], { 'if' => { 'contains' => true }, 'then' => true, 'else' => false }))
        .to contain_exactly(a_string_matching(/schema false accepts no value/))
      expect(validator.validate([], { 'oneOf' => [{ 'type' => 'null' }, { 'contains' => true }] }))
        .to contain_exactly(a_string_matching(/satisfies 0 schemas in oneOf/))
      expect(validator.validate([], { 'anyOf' => [{ 'contains' => true }] }))
        .to contain_exactly(a_string_matching(/does not satisfy any schema in anyOf/))
      expect(validator.validate([1], { 'not' => { 'contains' => true } }))
        .to contain_exactly(a_string_matching(/value satisfies the schema in not/))
    end

    it 'leaves a contains schema it does not evaluate undecided' do
      # A real contains schema is still unevaluated: not must not fail here.
      expect(validator.validate([1], { 'not' => { 'contains' => { 'type' => 'string' } } })).to be_empty
    end
  end

  describe 'a dependency whose required names are already present' do
    it 'cannot fail, so not and if decide the branch' do
      instance = { 'a' => 1, 'b' => 2 }

      expect(validator.validate(instance, { 'not' => { 'dependentRequired' => { 'a' => %w[b] } } }))
        .to contain_exactly(a_string_matching(/value satisfies the schema in not/))
      expect(validator.validate(instance, { 'if' => { 'dependentRequired' => { 'a' => %w[b] } }, 'then' => false }))
        .to contain_exactly(a_string_matching(/schema false accepts no value/))
    end

    it 'reads a draft-07 dependencies list the same way' do
      instance = { 'a' => 1, 'b' => 2 }
      schema = { '$schema' => draft7, 'not' => { 'dependencies' => { 'a' => %w[b] } } }

      expect(validator.validate(instance, schema))
        .to contain_exactly(a_string_matching(/value satisfies the schema in not/))
    end

    it 'still leaves the branch undecided while a required name is absent' do
      expect(validator.validate({ 'a' => 1 }, { 'not' => { 'dependentRequired' => { 'a' => %w[b] } } })).to be_empty
      expect(validator.validate({ 'a' => 1, 'b' => 2 },
                                { 'not' => { 'dependentRequired' => { 'a' => %w[b c] } } })).to be_empty
    end

    it 'reads the symbol key form of the instance as present' do
      expect(validator.validate({ a: 1, b: 2 }, { 'not' => { 'dependentRequired' => { 'a' => %w[b] } } }))
        .to contain_exactly(a_string_matching(/value satisfies the schema in not/))
    end
  end
end
