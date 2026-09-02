# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, seventh review round: plain-name
# fragments are scoped to their schema resource, a draft-07 `$id` is an
# anchor only when it is a pure fragment, keywords beside a draft-07 `$ref`
# contribute no anchors, `$defs` / `definitions` belong to the dialects that
# define them, and the unsupported-keyword scan is bounded and memoized.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 7' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'resource-scoped anchors' do
    it 'does not resolve an anchor declared inside an embedded resource from the outside' do
      schema = {
        'type' => 'object',
        'properties' => { 'child' => { '$ref' => '#node' } },
        '$defs' => { 'embedded' => { '$id' => 'https://example.com/embedded', '$anchor' => 'node',
                                     'type' => 'string' } }
      }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref "#node"/))
      expect(validator.validate({ 'child' => 'ok' }, schema)).not_to be_empty
    end

    it 'does not resolve the root anchor from inside an embedded resource' do
      schema = {
        '$anchor' => 'node',
        'type' => 'object',
        'properties' => {
          'child' => { '$id' => 'https://example.com/child', 'type' => 'object',
                       'properties' => { 'inner' => { '$ref' => '#node' } } }
        }
      }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref "#node"/))
    end

    it 'resolves an anchor within its own resource, embedded or root' do
      schema = {
        '$anchor' => 'top',
        'type' => 'object',
        'properties' => {
          'again' => { '$ref' => '#top' },
          'child' => { '$id' => 'https://example.com/child', 'type' => 'object',
                       'properties' => { 'inner' => { '$ref' => '#leaf' } },
                       '$defs' => { 'leaf' => { '$anchor' => 'leaf', 'type' => 'integer' } } }
        }
      }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'again' => {}, 'child' => { 'inner' => 1 } }, schema)).to be_empty
      expect(validator.validate({ 'child' => { 'inner' => 'x' } },
                                schema)).to contain_exactly(a_string_matching(/inner/))
    end
  end

  describe 'draft-07 identifiers' do
    it 'treats only a pure-fragment $id as a plain-name anchor' do
      relative = { '$schema' => draft7, '$ref' => '#item.json',
                   'definitions' => { 'n' => { '$id' => 'item.json', 'type' => 'string' } } }
      expect(validator.check_schema(relative)).to contain_exactly(a_string_matching(/unresolvable local \$ref/))

      bare = { '$schema' => draft7, '$ref' => '#item',
               'definitions' => { 'n' => { '$id' => 'item', 'type' => 'string' } } }
      expect(validator.check_schema(bare)).to contain_exactly(a_string_matching(/unresolvable local \$ref/))

      fragment = { '$schema' => draft7, '$ref' => '#item',
                   'definitions' => { 'n' => { '$id' => '#item', 'type' => 'string' } } }
      expect(validator.check_schema(fragment)).to be_empty
      expect(validator.validate(1, fragment)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'ignores anchors declared under the siblings of a draft-07 $ref' do
      schema = {
        '$schema' => draft7,
        'properties' => {
          'a' => { '$ref' => '#trap' },
          'b' => { '$ref' => '#/definitions/x', 'allOf' => [{ '$id' => '#trap', 'type' => 'string' }] }
        },
        'definitions' => { 'x' => { 'type' => 'integer' } }
      }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref "#trap"/))
    end
  end

  describe 'dialect-scoped definition containers' do
    it 'does not walk definitions under 2020-12 nor $defs under draft-07' do
      modern = { 'type' => 'integer', 'definitions' => { 'hidden' => { '$ref' => 'https://example.com/x' } } }
      expect(validator.check_schema(modern)).to be_empty
      expect(validator.validate(1, modern)).to be_empty

      legacy = { '$schema' => draft7, 'type' => 'integer', '$defs' => { 'hidden' => { '$ref' => 'https://example.com/x' } } }
      expect(validator.check_schema(legacy)).to be_empty
      expect(validator.validate(1, legacy)).to be_empty
    end

    it 'still resolves JSON pointers into either container and checks what they reach' do
      modern = { 'type' => 'object', 'properties' => { 'n' => { '$ref' => '#/definitions/x' } },
                 'definitions' => { 'x' => { 'type' => 'integer' } } }
      expect(validator.check_schema(modern)).to be_empty
      expect(validator.validate({ 'n' => 'x' }, modern)).to contain_exactly(a_string_matching(/expected type integer/))

      reached = { 'type' => 'object', 'properties' => { 'n' => { '$ref' => '#/definitions/x' } },
                  'definitions' => { 'x' => { 'allOf' => [{ '$ref' => 'https://example.com/x' }] } } }
      expect(validator.check_schema(reached)).to contain_exactly(a_string_matching(/external \$ref/))
    end

    it 'keeps recursive schemas through a definitions pointer usable' do
      kids = { 'type' => 'array', 'items' => { '$ref' => '#/$defs/node' } }
      tree = { 'type' => 'object', 'properties' => { 'kids' => kids },
               '$defs' => { 'node' => { 'type' => 'object', 'properties' => { 'kids' => kids.dup } } } }
      expect(validator.check_schema(tree)).to be_empty
      expect(validator.validate({ 'kids' => [{ 'kids' => [{}] }] }, tree)).to be_empty
    end
  end

  describe 'bounded unsupported-keyword scan' do
    it 'stops walking at MAX_SUBSCHEMAS' do
      # More subschemas than the walk admits, but within the structural
      # bound (every object entry counts), so the document is still read.
      huge = { 'type' => 'object', 'properties' => {} }
      (validator::MAX_SUBSCHEMAS + 500).times { |i| huge['properties']["p#{i}"] = { 'format' => 'x' } }
      allow(validator).to receive(:each_subschema).and_call_original

      expect(validator.unsupported_keywords(huge)).to eq(['format'])
      expect(validator).to have_received(:each_subschema).at_most(validator::MAX_SUBSCHEMAS + 1).times
    end

    it 'reports nothing for a document too wide to read, which check_schema rejects' do
      huge = { 'type' => 'object', 'properties' => {} }
      (validator::MAX_STRUCTURAL_OBJECTS + 10).times { |i| huge['properties']["p#{i}"] = { 'format' => 'x' } }

      expect(validator.unsupported_keywords(huge)).to eq([])
      expect(validator.check_schema(huge)).to contain_exactly(a_string_matching(/structural elements/))
    end
  end

  describe 'through MCPClient::Client' do
    let(:logger) { Logger.new(File::NULL) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def client_with(tools)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return(tools)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)
    end

    it 'computes the unsupported keywords of an output schema once per schema' do
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                 output_schema: { 'type' => 'object', 'format' => 'custom' }, server: mock_server)
      client = client_with([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })
      allow(MCPClient::SchemaValidator).to receive(:unsupported_keywords).and_call_original

      3.times { client.call_tool('t', {}) }

      expect(MCPClient::SchemaValidator).to have_received(:unsupported_keywords).once
    end
  end
end
