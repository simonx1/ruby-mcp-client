# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, twenty-first round: the pattern
# matching behind the property-coverage checks runs under the validation
# deadline and the regexp timeout, every adopted pointer target is charged
# against the structural bound and indexed with its descendants, dependency
# triggers are looked up in both key forms, and an explicit null
# outputSchema is a declaration, not an absent field.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 21' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  # Backtracking Ruby's regexp cache cannot flatten (the backreference
  # disables the memoization): a server-controlled expression like this one
  # must not be able to hold the calling thread past the deadline.
  let(:evil_pattern) { '^(a*)*\1$' }
  let(:evil_name) { "#{'a' * 17}!" }

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  describe 'pattern matching behind the property-coverage checks' do
    it 'matches patternProperties patterns under the validation deadline' do
      schema = { 'not' => { 'patternProperties' => { evil_pattern => { 'type' => 'string' } } } }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05
      errors, elapsed = timed { validator.validate({ evil_name => 1 }, schema, deadline: deadline) }

      expect(elapsed).to be < 2
      expect(errors).to contain_exactly(a_string_matching(/aborted/))
    end

    it 'matches additionalProperties coverage patterns under the validation deadline' do
      schema = { 'not' => { 'additionalProperties' => false, 'patternProperties' => { evil_pattern => true } } }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05
      errors, elapsed = timed { validator.validate({ evil_name => 1 }, schema, deadline: deadline) }

      expect(elapsed).to be < 2
      expect(errors).to contain_exactly(a_string_matching(/aborted/))
    end

    it 'still reads a cheap pattern within the budget' do
      inert = { 'not' => { 'patternProperties' => { '^z' => { 'type' => 'string' } } } }
      expect(validator.validate({ 'a' => 1 }, inert)).not_to be_empty
      live = { 'not' => { 'patternProperties' => { '^a' => { 'type' => 'string' } } } }
      expect(validator.validate({ 'a' => 1 }, live)).to be_empty
    end
  end

  describe 'adopted pointer targets' do
    it 'charges a string-keyed target against the structural bound' do
      huge = {}
      (validator::MAX_STRUCTURAL_OBJECTS + 50).times { |i| huge["k#{i}"] = i }

      expect(validator.check_schema({ '$ref' => '#/default', 'default' => huge }))
        .to contain_exactly(a_string_matching(/structural elements/))
    end

    it 'resolves a $ref written inside an adopted target' do
      schema = { 'type' => 'object',
                 'properties' => { 'a' => { '$ref' => '#/default' } },
                 'default' => { '$defs' => { 'i' => { 'type' => 'integer' } },
                                'properties' => { 'b' => { '$ref' => '#/default/$defs/i' } } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => { 'b' => 1 } }, schema)).to be_empty
      expect(validator.validate({ 'a' => { 'b' => 'x' } }, schema))
        .to contain_exactly(a_string_matching(%r{#/a/b: expected type integer}))
    end

    it 'keeps the adopted resource dialect for the schemas nested inside it' do
      schema = { 'properties' => { 'a' => { '$ref' => '#/default' } },
                 'default' => { '$id' => 'https://example.com/embedded', '$schema' => draft7,
                                'properties' => { 'b' => { 'items' => [{ 'type' => 'integer' }] } } } }

      expect(validator.check_schema(schema)).to be_empty
      # draft-07 reads an items array positionally; under the root's 2020-12
      # the same array would apply nothing at all.
      expect(validator.validate({ 'a' => { 'b' => ['x'] } }, schema))
        .to contain_exactly(a_string_matching(%r{#/a/b/0: expected type integer}))
    end
  end

  describe 'dependency triggers' do
    let(:schema) { { 'not' => { 'dependentRequired' => { 'a' => ['b'] } } } }

    it 'is looked up in both key forms' do
      expect(validator.validate({ 'a' => 1 }, schema)).to be_empty
      expect(validator.validate({ a: 1 }, schema)).to be_empty
      draft = { '$schema' => draft7, 'not' => { 'dependencies' => { 'a' => { 'type' => 'string' } } } }
      expect(validator.validate({ a: 1 }, draft)).to be_empty
    end

    it 'decides the branch when the trigger is present in neither form' do
      expect(validator.validate({ 'c' => 1 }, schema)).not_to be_empty
      expect(validator.validate({ c: 1 }, schema)).not_to be_empty
    end
  end

  describe 'an explicit null outputSchema' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def tool_json(**extra)
      MCPClient::Tool.from_json({ 'name' => 'tool', 'description' => 'd', 'inputSchema' => { 'type' => 'object' } }
                                 .merge(extra), server: mock_server)
    end

    def client_with(tools, **opts)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return(tools)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger, **opts)
    end

    it 'is a declared schema, not an absent field' do
      expect(tool_json('outputSchema' => nil).structured_output?).to be(true)
      expect(MCPClient::Tool.from_json({ 'name' => 't', 'description' => 'd',
                                         inputSchema: {}, outputSchema: nil }).structured_output?).to be(true)
      expect(tool_json.structured_output?).to be(false)
      expect(tool_json('outputSchema' => nil).output_schema).to be_nil
    end

    it 'survives a copy of the tool definition' do
      expect(tool_json('outputSchema' => nil).dup.structured_output?).to be(true)
      expect(tool_json.dup.structured_output?).to be(false)
    end

    it 'still requires structuredContent in a successful result' do
      client = client_with([tool_json('outputSchema' => nil)], validate_structured_content: :strict)
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })

      expect { client.call_tool('tool', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /no structuredContent/)
    end

    it 'reports the null schema as unusable rather than as a permissive pass' do
      client = client_with([tool_json('outputSchema' => nil)], validate_structured_content: :strict)
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => { 'a' => 1 } })

      expect { client.call_tool('tool', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /must be an object or a boolean/)
    end
  end
end
