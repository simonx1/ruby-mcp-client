# frozen_string_literal: true

require 'spec_helper'

# MCP 2026-07-28 JSON Schema handling, verification round: the preflight and
# the unsupported-keyword scan run on an explicit work list rather than the
# call stack, an unsupported input dialect is an error the caller sees, a
# reference to a resource the document bundles resolves inside it,
# `definitions` is the deprecated `$defs` of the modern dialects, 2019-09
# anchor names admit a colon, malformed keyword shapes are rejected at
# preflight, and a condition the validator cannot decide still reports a
# failure both of its branches agree on.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — verification round' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:draft2019) { 'https://json-schema.org/draft/2019-09/schema' }

  # A shallow document whose references chain through hundreds of schemas:
  # far below every structural bound, but one Ruby frame per hop would
  # overflow the small stack a transport's reader thread runs on.
  def chained_refs(length)
    defs = {}
    length.times { |i| defs[i.to_s] = { 'allOf' => [{ '$ref' => "#/$defs/#{i + 1}" }] } }
    defs[length.to_s] = {}
    { '$ref' => '#/$defs/0', '$defs' => defs }
  end

  # Run a block on a fresh thread (the stack a transport's reader owns) and
  # re-raise whatever it raised, SystemStackError included.
  def on_thread(&block)
    thread = Thread.new(&block)
    thread.report_on_exception = false
    thread.value
  end

  describe 'a reference chain that does not nest the document' do
    let(:schema) { chained_refs(400) }

    it 'preflights a long chain of shallow references without the call stack' do
      expect(on_thread { validator.check_schema(schema) }).to be_empty
    end

    it 'scans a long chain of shallow references for unsupported keywords' do
      scanned = chained_refs(400)
      scanned['$defs']['400'] = { 'uniqueItems' => true }
      expect(on_thread { validator.unsupported_keywords(scanned) }).to contain_exactly('uniqueItems')
    end

    it 'validates against a long chain on the hop budget, never on the call stack' do
      errors = on_thread { validator.validate({}, schema) }
      expect(errors).to contain_exactly(a_string_matching(/exceeds #{validator::MAX_REF_DEPTH} hops/))
    end

    it 'validates against a chain within the hop budget' do
      short = chained_refs(validator::MAX_REF_DEPTH - 2)
      expect(on_thread { validator.validate({}, short) }).to be_empty
    end

    describe 'through MCPClient::Client' do
      let(:logger) { Logger.new(StringIO.new) }
      let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

      def client_with(tool)
        allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
        allow(mock_server).to receive(:on_notification)
        allow(mock_server).to receive(:list_tools).and_return([tool])
        allow(mock_server).to receive(:call_tool).and_return({ 'structuredContent' => {} })
        MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)
      end

      it 'checks a chained input schema on the calling thread without overflowing it' do
        tool = MCPClient::Tool.new(name: 't', description: 'd', schema: schema, server: mock_server)
        client = client_with(tool)
        expect(on_thread { client.call_tool('t', {}) }).to eq({ 'structuredContent' => {} })
      end

      it 'checks a chained output schema on the calling thread without overflowing it' do
        tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                   output_schema: schema, server: mock_server)
        client = client_with(tool)
        expect(on_thread { client.call_tool('t', {}) }).to eq({ 'structuredContent' => {} })
      end
    end
  end

  describe 'an unsupported input dialect' do
    let(:logger) { Logger.new(StringIO.new) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def client_for(schema)
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: schema, server: mock_server)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)
    end

    it 'is an error the caller sees, and the call never goes out' do
      client = client_for({ '$schema' => 'urn:unknown-dialect', 'type' => 'object' })
      expect { client.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown-dialect.*not supported/)
      expect { client.call_tool('t', {}) }.to raise_error(MCPClient::Errors::ValidationError)
      expect(mock_server).not_to have_received(:call_tool)
    end

    it 'reports an unsupported dialect declared by an embedded resource too' do
      embedded = { 'type' => 'object',
                   'properties' => { 'a' => { '$id' => 'https://example.com/a',
                                              '$schema' => 'http://json-schema.org/draft-04/schema#' } } }
      client = client_for(embedded)
      expect { client.call_tool('t', {}) }.to raise_error(MCPClient::Errors::ValidationError, /draft-04/)
      expect(mock_server).not_to have_received(:call_tool)
    end

    it 'still sends the call when a supported-dialect schema is merely unusable' do
      client = client_for({ 'type' => 'object', 'required' => ['x'],
                            'properties' => { 'x' => { '$ref' => 'https://example.com/x' } } })
      expect { client.call_tool('t', {}) }.not_to raise_error
      expect(mock_server).to have_received(:call_tool)
    end

    it 'names the unsupported dialect through the validator' do
      expect(validator.unsupported_dialect({ '$schema' => 'urn:unknown-dialect' })).to eq('urn:unknown-dialect')
      expect(validator.unsupported_dialect({ 'type' => 'object' })).to be_nil
      expect(validator.unsupported_dialect(true)).to be_nil
    end
  end

  describe 'references to resources the document bundles' do
    it 'resolves an absolute $ref naming an embedded $id' do
      schema = { '$defs' => { 's' => { '$id' => 'urn:example:s', 'type' => 'string' } },
                 '$ref' => 'urn:example:s' }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('ok', schema)).to be_empty
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'resolves a relative $ref against the base its resource declares' do
      schema = { '$id' => 'https://example.com/root.json',
                 'type' => 'object',
                 'properties' => { 'a' => { '$ref' => 'sub.json' } },
                 '$defs' => { 's' => { '$id' => 'sub.json', 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'a' => 'x' }, schema)).to contain_exactly(a_string_matching(/expected type integer/))
    end

    it 'resolves a pointer into a bundled resource' do
      schema = { '$defs' => { 's' => { '$id' => 'urn:example:s',
                                       '$defs' => { 'inner' => { 'type' => 'boolean' } } } },
                 '$ref' => 'urn:example:s#/$defs/inner' }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(true, schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/expected type boolean/))
    end

    it 'resolves an anchor inside a bundled resource' do
      schema = { '$defs' => { 's' => { '$id' => 'urn:example:s',
                                       '$defs' => { 'a' => { '$anchor' => 'leaf', 'type' => 'null' } } } },
                 '$ref' => 'urn:example:s#leaf' }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(nil, schema)).to be_empty
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type null/))
    end

    it 'reads the empty URI reference as the current resource' do
      schema = { 'type' => 'object', 'properties' => { 'a' => { '$ref' => '' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => { 'a' => {} } }, schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type object/))
    end

    it 'still reports a reference the document does not bundle as external' do
      schema = { '$defs' => { 's' => { '$id' => 'urn:example:s', 'type' => 'string' } },
                 '$ref' => 'urn:example:other' }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/external \$ref/))
      relative = { '$id' => 'https://example.com/root.json', '$ref' => 'sibling.json' }
      expect(validator.check_schema(relative)).to contain_exactly(a_string_matching(/external \$ref/))
    end
  end

  describe 'definitions under the modern dialects' do
    it 'takes an anchor from definitions the way it does from $defs' do
      schema = { 'definitions' => { 'x' => { '$anchor' => 'x', 'type' => 'integer' } }, '$ref' => '#x' }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(1, schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/expected type integer/))
    end

    it 'preflights what a modern definitions bag holds' do
      schema = { 'type' => 'integer', 'definitions' => { 'hidden' => { '$ref' => 'https://example.com/x' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/external \$ref/))
    end

    it 'scans a modern definitions bag for unsupported keywords' do
      schema = { 'type' => 'array', 'definitions' => { 'x' => { 'uniqueItems' => true } } }
      expect(validator.unsupported_keywords(schema)).to contain_exactly('uniqueItems')
    end

    it 'leaves $defs unknown to draft-07' do
      legacy = { '$schema' => draft7, 'properties' => { 'a' => { '$ref' => '#trap' } },
                 '$defs' => { 't' => { '$id' => '#trap', 'type' => 'string' } } }
      expect(validator.check_schema(legacy)).to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end
  end

  describe '2019-09 anchor names' do
    it 'accepts a colon in a 2019-09 anchor' do
      schema = { '$schema' => draft2019,
                 '$defs' => { 'a' => { '$anchor' => 'a:b', 'type' => 'string' } }, '$ref' => '#a:b' }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('ok', schema)).to be_empty
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'accepts a colon in a draft-07 plain-name $id' do
      schema = { '$schema' => draft7,
                 'definitions' => { 'a' => { '$id' => '#a:b', 'type' => 'string' } }, '$ref' => '#a:b' }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'keeps the 2020-12 name syntax for 2020-12' do
      colon = { '$defs' => { 'a' => { '$anchor' => 'a:b', 'type' => 'string' } }, '$ref' => '#a:b' }
      expect(validator.check_schema(colon)).to contain_exactly(a_string_matching(/unresolvable local \$ref/))
      underscore = { '$defs' => { 'a' => { '$anchor' => '_b', 'type' => 'string' } }, '$ref' => '#_b' }
      expect(validator.check_schema(underscore)).to be_empty
    end

    it 'rejects a leading underscore under 2019-09, which does not allow one' do
      schema = { '$schema' => draft2019,
                 '$defs' => { 'a' => { '$anchor' => '_b', 'type' => 'string' } }, '$ref' => '#_b' }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end
  end

  describe 'malformed keyword shapes at preflight' do
    it 'rejects an empty composition array' do
      %w[allOf anyOf oneOf].each do |keyword|
        expect(validator.check_schema({ keyword => [] }))
          .to contain_exactly(a_string_matching(/#{Regexp.escape(keyword)} must be a non-empty array/))
      end
      expect(validator.check_schema({ 'prefixItems' => [] }))
        .to contain_exactly(a_string_matching(/prefixItems must be a non-empty array/))
    end

    it 'rejects a definition bag entry that is not a schema' do
      expect(validator.check_schema({ '$defs' => { 'x' => 5 } }))
        .to contain_exactly(a_string_matching(/\$defs must be an object of schemas/))
      expect(validator.check_schema({ '$schema' => draft7, 'definitions' => { 'x' => 5 } }))
        .to contain_exactly(a_string_matching(/definitions must be an object of schemas/))
      expect(validator.check_schema({ '$defs' => [] }))
        .to contain_exactly(a_string_matching(/\$defs must be an object of schemas/))
    end

    it 'rejects malformed assertion keyword values' do
      cases = {
        { 'type' => 42 } => /type must be/,
        { 'type' => [] } => /type must be/,
        { 'type' => ['objekt'] } => /type must be/,
        { 'enum' => 'a' } => /enum must be an array/,
        { 'required' => 'a' } => /required must be an array of property names/,
        { 'required' => [1] } => /required must be an array of property names/,
        { 'pattern' => 5 } => /pattern must be a string/,
        { 'minLength' => 'a' } => /minLength must be a non-negative integer/,
        { 'maxItems' => -1 } => /maxItems must be a non-negative integer/,
        { 'minimum' => 'a' } => /minimum must be a number/
      }
      cases.each do |schema, message|
        expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(message)),
                                                  "expected #{schema.inspect} to be rejected"
      end
    end

    it 'still accepts the well-formed shapes' do
      expect(validator.check_schema({ 'type' => %w[string null], 'enum' => [1], 'required' => ['a'],
                                      'pattern' => 'x', 'minLength' => 0, 'maxItems' => 2,
                                      'minimum' => 1.5, 'allOf' => [true],
                                      '$defs' => { 'x' => false } })).to be_empty
    end

    it 'refuses to validate against a malformed schema instead of passing the data' do
      expect(validator.validate([1], { 'prefixItems' => [] }))
        .to contain_exactly(a_string_matching(/prefixItems must be a non-empty array/))
    end
  end

  describe 'a condition the validator cannot decide' do
    it 'reports a failure both branches agree on' do
      schema = { 'if' => { 'multipleOf' => 2 }, 'then' => false, 'else' => false }
      expect(validator.validate(3, schema)).to contain_exactly(a_string_matching(/if/))
      expect(validator.validate(4, schema)).to contain_exactly(a_string_matching(/if/))
    end

    it 'reports it when both branches assert the same rejected type' do
      schema = { 'if' => { 'multipleOf' => 2 }, 'then' => { 'type' => 'string' },
                 'else' => { 'type' => 'string' } }
      expect(validator.validate(3, schema)).to contain_exactly(a_string_matching(/expected type string/))
      expect(validator.validate('x', schema)).to be_empty
    end

    it 'stays silent when the branches genuinely disagree' do
      schema = { 'if' => { 'multipleOf' => 2 }, 'then' => { 'type' => 'string' },
                 'else' => { 'type' => 'integer' } }
      expect(validator.validate(3, schema)).to be_empty
    end

    it 'stays silent when only one branch is written' do
      expect(validator.validate(3, { 'if' => { 'multipleOf' => 2 }, 'then' => false })).to be_empty
      expect(validator.validate(3, { 'if' => { 'multipleOf' => 2 }, 'else' => false })).to be_empty
    end

    it 'does not treat an unconditional failure as a match for not' do
      schema = { 'not' => { 'if' => { 'multipleOf' => 2 }, 'then' => false, 'else' => false } }
      expect(validator.validate(3, schema)).to be_empty
    end
  end

  describe 'the normalization deadline' do
    it 'stops copying before it reads the rest of the document' do
      tripwire = { 'k' => 1 }
      allow(tripwire).to receive(:to_h).and_raise('the schema must not be copied past the deadline')
      schema = { 'type' => 'integer', 'x-rest' => tripwire }
      past = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
      expect(validator.validate(1, schema, deadline: past)).to contain_exactly(a_string_matching(/aborted|time/))
    end
  end
end
