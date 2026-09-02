# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, thirteenth review round: a definite
# verdict is never weakened by uncertainty inside a branch that was decided
# anyway — a failing branch leaves no uncertainty behind, anyOf passes once
# any branch definitely passes, and oneOf fails once two branches do.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 13' do
  let(:validator) { MCPClient::SchemaValidator }

  it 'discards the uncertainty of a branch that definitely fails' do
    schema = { 'not' => { 'not' => { 'minimum' => 10, 'multipleOf' => 2 } } }
    expect(validator.validate(3, schema)).to contain_exactly(a_string_matching(/not/))
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
    expect(validator.validate(3, { 'not' => { 'multipleOf' => 2 } })).to be_empty
    expect(validator.validate(3, { 'not' => { 'anyOf' => [{ 'multipleOf' => 2 }, { 'type' => 'string' }] } }))
      .to be_empty
    expect(validator.validate(3, { 'oneOf' => [true, { 'multipleOf' => 2 }] })).to be_empty
  end
end
