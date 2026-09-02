# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, seventeenth review round: pointer
# steps are classified by the dialect in force, every distinct boolean a
# reference reaches is charged once, draft-07 `format` is an unevaluated
# assertion, and a companion keyword the dialect does not define changes
# nothing.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 17' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:max) { validator::MAX_SCHEMA_DEPTH }

  def nested_not(depth, leaf)
    (1..depth).reduce(leaf) { |inner, _| { 'not' => inner } }
  end

  it 'treats a keyword the dialect does not define as opaque data when counting pointer steps' do
    pointer = "#/prefixItems/0#{'/not' * (max - 1)}"
    modern = { 'prefixItems' => [nested_not(max - 1, true)], 'not' => { '$ref' => pointer } }
    expect(validator.check_schema(modern)).to be_empty

    legacy = modern.merge('$schema' => draft7)
    expect(validator.check_schema(legacy)).to contain_exactly(a_string_matching(/nesting depth exceeds/))
  end

  it 'charges every distinct boolean a reference reaches toward the subschema bound' do
    count = (validator::MAX_SUBSCHEMAS / 2) + 100
    bools = (0...count).to_h { |i| ["b#{i}", true] }
    props = (0...count).to_h { |i| ["p#{i}", { '$ref' => "#/x-bools/b#{i}" }] }
    schema = { 'type' => 'object', 'properties' => props, 'x-bools' => bools }

    expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/more than \d+ subschemas/))

    few = { 'type' => 'object', 'x-bools' => { 'b' => true },
            'properties' => { 'p' => { '$ref' => '#/x-bools/b' }, 'q' => { '$ref' => '#/x-bools/b' } } }
    expect(validator.check_schema(few)).to be_empty
  end

  it 'leaves a draft-07 branch carrying format undecided while 2020-12 treats it as an annotation' do
    expect(validator.validate('abc', { 'not' => { 'format' => 'email' } })).not_to be_empty
    expect(validator.validate('abc', { '$schema' => draft7, 'not' => { 'format' => 'email' } })).to be_empty
    expect(validator.validate(1, { '$schema' => draft7, 'not' => { 'format' => 'email' } })).not_to be_empty
  end

  it 'ignores a companion keyword the dialect does not define' do
    modern = { 'not' => { 'contains' => true, 'minContains' => 0 } }
    expect(validator.validate([], modern)).not_to be_empty

    # draft-07 does not define minContains: contains keeps its one-match
    # requirement, so [] fails the inner schema and the not passes.
    legacy = { '$schema' => draft7, 'not' => { 'contains' => true, 'minContains' => 0 } }
    expect(validator.validate([], legacy)).to be_empty
  end
end
