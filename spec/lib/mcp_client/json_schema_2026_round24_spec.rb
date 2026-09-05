# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, twenty-fourth round: a fragment whose
# percent escapes are malformed decodes to nothing, so the reference holding
# it is unresolvable rather than a pointer to whatever literal member happens
# to spell the undecoded text (RFC 3986 Section 2.1); the number of items a
# `contains` can match is bounded by the array's length whatever its item
# schema says, so the bounds that length alone settles are decided instead of
# left open; and the `$ref` hop budget counts hops taken at one instance
# value, so a recursive schema still describes arbitrarily deep data.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 24' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'a reference whose fragment has a malformed percent escape' do
    it 'does not resolve "#/$defs/a%ZZ" onto a literal "a%ZZ" member' do
      schema = { '$ref' => '#/$defs/a%ZZ', '$defs' => { 'a%ZZ' => { 'type' => 'string' } } }

      expect(validator.check_schema(schema))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end

    it 'reports "#/$defs/a%ZZ" as unresolvable when no such member exists either' do
      schema = { '$ref' => '#/$defs/a%ZZ', '$defs' => { 'a' => { 'type' => 'string' } } }

      expect(validator.check_schema(schema))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end

    it 'leaves a schema built on such a reference unusable rather than silently applied' do
      schema = { '$ref' => '#/$defs/a%ZZ', '$defs' => { 'a%ZZ' => { 'type' => 'string' } } }

      expect(validator.validate('x', schema))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end

    it 'does not resolve a truncated escape "#/$defs/a%" onto a literal "a%" member' do
      schema = { '$ref' => '#/$defs/a%', '$defs' => { 'a%' => { 'type' => 'integer' } } }

      expect(validator.check_schema(schema))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end

    it 'reports a plain-name fragment with a bad escape as unresolvable' do
      schema = { '$ref' => '#a%ZZ', '$defs' => { 'x' => { '$anchor' => 'aZZ', 'type' => 'string' } } }

      expect(validator.check_schema(schema))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end

    it 'still resolves a well-formed escape naming the same member' do
      schema = { '$ref' => '#/$defs/a%2Db', '$defs' => { 'a-b' => { 'type' => 'string' } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('x', schema)).to be_empty
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end
  end

  describe 'the contains bounds the array length alone settles' do
    it 'rejects an empty array against a contains that must match an item' do
      expect(validator.validate([], { 'contains' => { 'type' => 'string' } }))
        .to contain_exactly(a_string_matching(/expected at least 1 items matching contains/))
    end

    it 'rejects an array shorter than minContains' do
      schema = { 'contains' => { 'type' => 'string' }, 'minContains' => 5 }

      expect(validator.validate([1, 2], schema))
        .to contain_exactly(a_string_matching(/expected at least 5 items matching contains/))
    end

    it 'rejects any array against a contains that matches nothing' do
      expect(validator.validate([1], { 'contains' => false }))
        .to contain_exactly(a_string_matching(/expected at least 1 items matching contains/))
    end

    it 'accepts a contains matching nothing when minContains switches it off' do
      expect(validator.validate([1], { 'contains' => false, 'minContains' => 0 })).to be_empty
    end

    it 'decides such a contains outright, so `not` can reject it' do
      expect(validator.validate([1], { 'not' => { 'contains' => false, 'minContains' => 0 } }))
        .to contain_exactly(a_string_matching(/satisfies the schema in not/))
    end

    it 'ignores minContains under draft-07, which does not define it' do
      schema = { '$schema' => draft7, 'contains' => false, 'minContains' => 0 }

      expect(validator.validate([1], schema))
        .to contain_exactly(a_string_matching(/expected at least 1 items matching contains/))
    end

    it 'does not let an anyOf branch pass on a contains its length already fails' do
      expect(validator.validate([], { 'anyOf' => [{ 'contains' => { 'type' => 'string' } }] }))
        .not_to be_empty
    end

    it 'takes the else branch when the if branch fails on length alone' do
      schema = { 'if' => { 'contains' => { 'type' => 'string' } }, 'then' => true, 'else' => false }

      expect(validator.validate([], schema)).to contain_exactly(a_string_matching(/schema false accepts no value/))
      expect(validator.validate(['x'], schema)).to be_empty
    end

    it 'matches item by item where the length cannot settle contains' do
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' } }))
        .to contain_exactly(a_string_matching(/at least 1 items matching contains/))
      expect(validator.validate([1, 'x'], { 'contains' => { 'type' => 'string' } })).to be_empty
      # `maxContains: 0` alone is unsatisfiable beside the default
      # `minContains: 1` (round 25); with the lower bound switched off, how
      # many items match is still the item schema's business.
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' },
                                          'minContains' => 0, 'maxContains' => 0 })).to be_empty
    end
  end

  describe 'the $ref hop budget against recursive data' do
    it 'validates a self-recursive array schema against deeply nested data' do
      schema = { 'type' => 'array', 'items' => { '$ref' => '#' } }
      data = (1..40).reduce([]) { |nested, _| [nested] }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(data, schema)).to be_empty
    end

    it 'still reports a violation deep inside such data' do
      schema = { 'type' => 'array', 'items' => { '$ref' => '#' } }
      data = (1..40).reduce(['x']) { |nested, _| [nested] }

      expect(validator.validate(data, schema))
        .to contain_exactly(a_string_matching(/expected type array, got string/))
    end

    it 'validates a self-recursive object schema against deeply nested data' do
      schema = { 'type' => 'object', 'properties' => { 'child' => { '$ref' => '#' } } }
      data = (1..40).reduce({}) { |nested, _| { 'child' => nested } }

      expect(validator.validate(data, schema)).to be_empty
    end

    it 'still rejects a $ref cycle that consumes no instance' do
      schema = { '$ref' => '#/$defs/a', '$defs' => { 'a' => { '$ref' => '#/$defs/a' } } }

      expect(validator.validate([], schema)).not_to be_empty
    end
  end
end
