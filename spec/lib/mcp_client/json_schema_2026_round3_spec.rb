# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, third review round: a false output
# schema survives parsing, speculative composition branches do not eat the
# error budget, positional keywords follow the dialect, and a malformed
# $schema declaration is not the default dialect.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 3' do
  let(:validator) { MCPClient::SchemaValidator }

  it 'keeps an outputSchema of false through Tool.from_json' do
    tool = MCPClient::Tool.from_json({ 'name' => 't', 'description' => 'd', 'inputSchema' => { 'type' => 'object' },
                                       'outputSchema' => false })

    expect(tool.output_schema).to be(false)
    expect(tool).to be_structured_output
    expect(validator.validate({}, tool.output_schema)).to contain_exactly(a_string_matching(/false/))
  end

  it 'does not count the errors of rejected anyOf, oneOf, not or if branches' do
    alternatives = Array.new(validator::MAX_ERRORS + 50) { { 'type' => 'string' } } + [{ 'type' => 'integer' }]
    expect(validator.validate(1, { 'anyOf' => alternatives })).to be_empty
    expect(validator.validate(1, { 'oneOf' => alternatives })).to be_empty

    nots = Array.new(validator::MAX_ERRORS + 50) { { 'not' => { 'type' => 'string' } } }
    expect(validator.validate(1, { 'allOf' => nots })).to be_empty

    conditionals = Array.new(validator::MAX_ERRORS + 50) { { 'if' => { 'type' => 'string' }, 'then' => false } }
    expect(validator.validate(1, { 'allOf' => conditionals })).to be_empty
  end

  it 'chooses the positional keyword by dialect' do
    draft7 = { '$schema' => 'http://json-schema.org/draft-07/schema#', 'type' => 'array',
               'prefixItems' => [{ 'type' => 'integer' }] }
    expect(validator.validate(['x'], draft7)).to be_empty

    modern = { 'type' => 'array', 'items' => [{ 'type' => 'integer' }] }
    expect(validator.check_schema(modern)).to contain_exactly(a_string_matching(/items.*prefixItems/))
  end

  it 'rejects a present but malformed $schema declaration' do
    [nil, 7, ''].each do |declared|
      problems = validator.check_schema({ '$schema' => declared, 'type' => 'object' })
      expect(problems).to contain_exactly(a_string_matching(/\$schema/)), "expected #{declared.inspect} to be rejected"
    end
    expect(validator.check_schema({ 'type' => 'object' })).to be_empty
  end
end
