# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, thirteenth review round: a definite
# verdict is never weakened by uncertainty inside a branch that was decided
# anyway — a failing branch leaves no uncertainty behind, anyOf passes once
# any branch definitely passes, and oneOf fails once two branches do.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 13' do
  let(:validator) { MCPClient::SchemaValidator }

  it 'discards the uncertainty of a branch that definitely fails' do
    # The branch holds a keyword this validator cannot decide (`$dynamicRef`
    # needs a dynamic scope) beside one it can: the definite failure decides
    # the branch, and the uncertainty is not carried out of it.
    schema = { 'not' => { 'not' => { 'minimum' => 10, '$dynamicRef' => '#x' } } }
    expect(validator.validate(3, schema)).to contain_exactly(a_string_matching(/not/))
    # Without the definite failure the same branch is genuinely undecided,
    # and the uncertainty does reach the outer negation.
    expect(validator.validate(12, schema)).to be_empty
  end

  it 'lets anyOf pass on a later definite branch, whatever the order' do
    expect(validator.validate(3, { 'not' => { 'anyOf' => [{ 'multipleOf' => 2 }, true] } }))
      .to contain_exactly(a_string_matching(/not/))
    expect(validator.validate(3, { 'not' => { 'anyOf' => [true, { 'multipleOf' => 2 }] } }))
      .to contain_exactly(a_string_matching(/not/))
    expect(validator.validate(3, { 'not' => { 'anyOf' => [{ 'multipleOf' => 2 }, { 'type' => 'string' }] } }))
      .to be_empty
  end

  it 'rejects oneOf once two branches definitely pass' do
    expect(validator.validate(3, { 'oneOf' => [true, true, { 'multipleOf' => 2 }] }))
      .to contain_exactly(a_string_matching(/oneOf/))
    expect(validator.validate(3, { 'oneOf' => [true, { 'type' => 'string' }, { 'multipleOf' => 2 }] })).to be_empty
    expect(validator.validate(3, { 'not' => { 'oneOf' => [true, true, { 'multipleOf' => 2 }] } })).to be_empty
  end

  it 'keeps a genuinely undecided branch undecided' do
    # `multipleOf` is evaluated and decides its branch outright, so what is
    # left undecided here is a keyword no verdict can be reached for.
    undecidable = { '$dynamicRef' => '#x' }
    expect(validator.validate(3, { 'not' => undecidable })).to be_empty
    expect(validator.validate(3, { 'not' => { 'anyOf' => [undecidable, { 'type' => 'string' }] } })).to be_empty
    expect(validator.validate(3, { 'oneOf' => [true, undecidable] })).to be_empty
    # And a branch the validator can decide is decided: `not` reports it.
    expect(validator.validate(3, { 'not' => { 'multipleOf' => 3 } })).to contain_exactly(a_string_matching(/not/))
  end
end
