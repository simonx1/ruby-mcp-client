# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 JSON Schema handling: regression suite.
#
# These examples were written one adversarial review round at a time, each
# pinning a defect that round found. They are gathered here by subject
# rather than by the round that produced them; the round is noted on each
# section only because the review notes refer to it. Every example here
# covers production code no other spec reaches.

# --- verify ----------------------------------------------------------------

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
      scanned['$defs']['400'] = { 'format' => 'uuid' }
      expect(on_thread { validator.unsupported_keywords(scanned) }).to contain_exactly('format')
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

      # :strict, so a check that did not run is not the same observation as
      # a check that ran and passed: an unusable schema raises here.
      def client_with(tool, result = { 'structuredContent' => {} })
        allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
        allow(mock_server).to receive(:on_notification)
        allow(mock_server).to receive(:list_tools).and_return([tool])
        allow(mock_server).to receive(:call_tool).and_return(result)
        MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                              validate_structured_content: :strict)
      end

      it 'checks a chained input schema on the calling thread without overflowing it' do
        tool = MCPClient::Tool.new(name: 't', description: 'd', schema: schema, server: mock_server)
        client = client_with(tool)
        expect(on_thread { client.call_tool('t', {}) }).to eq({ 'structuredContent' => {} })

        # The control: the same chain ending in a dialect nothing can read is
        # refused, so the walk really reached the end of it.
        unreadable = chained_refs(400)
        unreadable['$defs']['400'] = { '$id' => 'https://example.com/r', '$schema' => 'urn:unknown' }
        broken = MCPClient::Tool.new(name: 'u', description: 'd', schema: unreadable, server: mock_server)
        allow(mock_server).to receive(:list_tools).and_return([broken])
        expect { on_thread { client_with(broken).call_tool('u', {}) } }
          .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown/)
      end

      it 'checks a chained output schema on the calling thread without overflowing it' do
        tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                   output_schema: schema, server: mock_server)
        # No SystemStackError on the calling thread: the hop budget stops the
        # chain, and an aborted validation is a violation like any other
        # rather than a pass (or a crash out of the tool call).
        expect { on_thread { client_with(tool).call_tool('t', {}) } }
          .to raise_error(MCPClient::Errors::ValidationError, /exceeds #{validator::MAX_REF_DEPTH} hops/)

        # A chain within the hop budget is walked to its end, which really
        # decides the result.
        length = validator::MAX_REF_DEPTH - 2
        typed = chained_refs(length)
        typed['$defs'][length.to_s] = { 'type' => 'array' }
        checked = MCPClient::Tool.new(name: 'v', description: 'd', schema: { 'type' => 'object' },
                                      output_schema: typed, server: mock_server)
        allow(mock_server).to receive(:list_tools).and_return([checked])
        expect { on_thread { client_with(checked).call_tool('v', {}) } }
          .to raise_error(MCPClient::Errors::ValidationError, %r{does not satisfy allOf/0})
        expect(on_thread { client_with(checked, { 'structuredContent' => [] }).call_tool('v', {}) })
          .to eq({ 'structuredContent' => [] })
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
      schema = { 'type' => 'array', 'definitions' => { 'x' => { 'format' => 'uuid' } } }
      expect(validator.unsupported_keywords(schema)).to contain_exactly('format')
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
        { 'required' => 'a' } => /required must be an array of distinct property names/,
        { 'required' => [1] } => /required must be an array of distinct property names/,
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
    # draft-07 `format` asserts (Validation Section 7.2) and this validator
    # does not evaluate formats, so a string branch carrying one is
    # genuinely undecidable — unlike the standard assertions, which are
    # evaluated and decide their condition outright, unlike an
    # `unevaluatedItems` whose annotations its own node produces, and unlike
    # a dynamic reference, which binds against the dynamic scope.
    let(:draft7) { MCPClient::SchemaValidator::DRAFT_07 }
    let(:undecidable) { { 'format' => 'email' } }

    def under_draft7(schema)
      { '$schema' => draft7 }.merge(schema)
    end

    it 'reports a failure both branches agree on' do
      schema = under_draft7({ 'if' => undecidable, 'then' => false, 'else' => false })
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/if/))
      expect(validator.validate('yy', schema)).to contain_exactly(a_string_matching(/if/))
    end

    it 'reports it when both branches assert the same rejected type' do
      schema = under_draft7({ 'if' => undecidable, 'then' => { 'type' => 'integer' },
                              'else' => { 'type' => 'integer' } })
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/expected type integer/))
      expect(validator.validate(1, schema)).to be_empty
    end

    it 'stays silent when the branches genuinely disagree' do
      schema = under_draft7({ 'if' => undecidable, 'then' => { 'type' => 'integer' },
                              'else' => { 'type' => 'string' } })
      expect(validator.validate('x', schema)).to be_empty
    end

    it 'stays silent when only one branch is written' do
      expect(validator.validate('x', under_draft7({ 'if' => undecidable, 'then' => false }))).to be_empty
      expect(validator.validate('x', under_draft7({ 'if' => undecidable, 'else' => false }))).to be_empty
    end

    it 'does not treat an unconditional failure as a match for not' do
      schema = under_draft7({ 'not' => { 'if' => undecidable, 'then' => false, 'else' => false } })
      expect(validator.validate('x', schema)).to be_empty
    end

    it 'applies the branch a condition the validator does evaluate selects' do
      schema = { 'if' => { 'multipleOf' => 2 }, 'then' => { 'type' => 'string' }, 'else' => { 'type' => 'integer' } }
      expect(validator.validate(4, schema)).to contain_exactly(a_string_matching(/expected type string/))
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

# --- round5 ----------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, fifth review round: the keyword
# grammar follows the dialect (draft-07 dependencies, keywords unknown to a
# dialect are ignored), a draft-07 $ref hides its siblings at preflight
# too, plain-name fragments resolve to anchors, an empty outputSchema is a
# schema, exclusive bounds are numbers under draft-07 too, and an external
# $recursiveRef makes a 2019-09 schema unusable.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 5' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:draft2019) { 'https://json-schema.org/draft/2019-09/schema' }

  describe 'dialect-specific keyword grammar' do
    let(:dependencies) do
      { 'type' => 'object',
        'properties' => { 'credit_card' => { 'type' => 'string' }, 'billing_address' => { 'type' => 'string' } },
        'dependencies' => { 'credit_card' => ['billing_address'] } }
    end

    it 'applies the draft-07 property form of dependencies' do
      schema = dependencies.merge('$schema' => draft7)
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'credit_card' => '4111', 'billing_address' => 'x' }, schema)).to be_empty
      expect(validator.validate({ 'credit_card' => '4111' }, schema))
        .to contain_exactly(a_string_matching(/requires property 'billing_address'/))
      expect(validator.unsupported_keywords(schema)).to eq([])
    end

    it 'ignores dependencies entirely under 2020-12, where the keyword does not exist' do
      expect(validator.check_schema(dependencies)).to be_empty
      expect(validator.validate({ 'credit_card' => '4111' }, dependencies)).to be_empty
      expect(validator.unsupported_keywords(dependencies)).to be_empty
    end

    it 'still rejects a draft-07 dependencies entry that is neither a schema nor property names' do
      schema = { '$schema' => draft7, 'dependencies' => { 'a' => 5 } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/dependencies/))
    end

    it 'walks the schema-valued dependencies entries under draft-07' do
      schema = { '$schema' => draft7, 'dependencies' => { 'a' => { '$ref' => 'https://example.com/x' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/external \$ref/))
    end

    it 'neither shape-checks nor reports keywords unknown to the dialect' do
      expect(validator.check_schema({ 'additionalItems' => 'nope' })).to be_empty
      expect(validator.check_schema({ '$recursiveRef' => 'https://example.com/x' })).to be_empty
      expect(validator.unsupported_keywords({ '$recursiveRef' => 'https://example.com/x' })).to be_empty
      expect(validator.check_schema({ '$schema' => draft7, 'prefixItems' => 'nope' })).to be_empty
      expect(validator.check_schema({ '$schema' => draft7, '$dynamicRef' => 'https://example.com/x' })).to be_empty
      expect(validator.unsupported_keywords({ '$schema' => draft7, 'unevaluatedProperties' => false })).to be_empty
    end
  end

  it 'does not preflight the siblings a draft-07 $ref replaces' do
    schema = { '$schema' => draft7, '$ref' => '#/definitions/a',
               'allOf' => [{ '$ref' => 'https://example.com/x' }],
               'definitions' => { 'a' => { 'type' => 'integer' } } }
    expect(validator.check_schema(schema)).to be_empty
    expect(validator.validate(1, schema)).to be_empty
    expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/integer/))
  end

  it 'still preflights the definitions next to a draft-07 $ref' do
    schema = { '$schema' => draft7, '$ref' => '#/definitions/a',
               'definitions' => { 'a' => { 'properties' => { 'p' => { '$ref' => 'https://example.com/x' } } } } }
    expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/external \$ref/))
  end

  describe 'plain-name fragments' do
    it 'resolves $ref "#name" to the subschema carrying $anchor under 2020-12' do
      schema = { '$ref' => '#node', '$defs' => { 'n' => { '$anchor' => 'node', 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(1, schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/integer/))
    end

    it 'resolves $ref "#name" to the subschema whose $id is "#name" under draft-07' do
      schema = { '$schema' => draft7, '$ref' => '#node',
                 'definitions' => { 'n' => { '$id' => '#node', 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/integer/))
    end

    it 'keeps an unknown anchor an error' do
      expect(validator.check_schema({ '$ref' => '#missing' })).to contain_exactly(a_string_matching(/unresolvable/))
      # $anchor does not exist in draft-07, so it names nothing there.
      schema = { '$schema' => draft7, '$ref' => '#node', 'definitions' => { 'n' => { '$anchor' => 'node' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable/))
    end
  end

  describe 'draft-07 exclusive bounds' do
    it 'applies numeric exclusiveMinimum / exclusiveMaximum (draft-07 validation Sections 6.2.3 and 6.2.5)' do
      min = { '$schema' => draft7, 'type' => 'number', 'exclusiveMinimum' => 5 }
      max = { '$schema' => draft7, 'type' => 'number', 'exclusiveMaximum' => 10 }
      expect(validator.validate(5, min)).to contain_exactly(a_string_matching(/greater than/))
      expect(validator.validate(6, min)).to be_empty
      expect(validator.validate(10, max)).to contain_exactly(a_string_matching(/less than/))
      expect(validator.validate(9, max)).to be_empty
    end

    it 'rejects the draft-04 boolean form' do
      expect(validator.check_schema({ '$schema' => draft7, 'exclusiveMinimum' => true }))
        .to contain_exactly(a_string_matching(/exclusiveMinimum.*number/))
      expect(validator.check_schema({ 'exclusiveMaximum' => true }))
        .to contain_exactly(a_string_matching(/exclusiveMaximum.*number/))
    end
  end

  it 'treats an external $recursiveRef like an external $dynamicRef under 2019-09' do
    external = { '$schema' => draft2019, '$recursiveRef' => 'https://example.com/x' }
    expect(validator.check_schema(external)).to contain_exactly(a_string_matching(/external \$recursiveRef/))
    expect(validator.validate(1, external)).not_to be_empty

    # A root whose $recursiveAnchor is true is the outermost dynamic scope
    # there is: the reference is bound to it and evaluated — here onto the
    # same instance again, which is the cycle it is reported as.
    local = { '$schema' => draft2019, '$recursiveAnchor' => true, '$recursiveRef' => '#' }
    expect(validator.check_schema(local)).to be_empty
    expect(validator.unsupported_keywords(local)).to eq([])
    expect(validator.validate(1, local)).to contain_exactly(a_string_matching(/cycle/))
    # Without a `$recursiveAnchor: true` at its target it is a plain `#`.
    plain = { '$schema' => draft2019, '$recursiveRef' => '#' }
    expect(validator.check_schema(plain)).to be_empty
    expect(validator.unsupported_keywords(plain)).to eq([])
  end

  describe 'an empty outputSchema' do
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    it 'is a schema (it accepts every value) for Tool.new and Tool.from_json' do
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' }, output_schema: {})
      expect(tool).to be_structured_output
      parsed = MCPClient::Tool.from_json({ 'name' => 't', 'inputSchema' => { 'type' => 'object' },
                                           'outputSchema' => {} })
      expect(parsed).to be_structured_output
      expect(MCPClient::Tool.from_json({ 'name' => 't', 'inputSchema' => {} })).not_to be_structured_output
    end

    it 'makes the client require structuredContent' do
      log_output = StringIO.new
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' }, output_schema: {},
                                 server: mock_server)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }],
                                     logger: Logger.new(log_output))

      client.call_tool('t', {})

      expect(log_output.string).to include('no structuredContent')
    end
  end
end

# --- round8 ----------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, eighth review round: pointer
# fragments are relative to the schema resource the `$ref` sits in, the
# unsupported-keyword scan follows local references, an `if` without a
# branch is inert, and a schema wider than the bounds is rejected before it
# is copied whole.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 8' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'resource-relative pointer fragments' do
    let(:schema) do
      {
        'type' => 'object',
        '$defs' => { 'n' => { 'type' => 'string' } },
        'properties' => {
          'child' => {
            '$id' => 'https://example.com/child',
            'type' => 'object',
            '$defs' => { 'n' => { 'type' => 'integer' } },
            'properties' => { 'inner' => { '$ref' => '#/$defs/n' }, 'self' => { '$ref' => '#' } }
          }
        }
      }
    end

    it 'resolves a pointer inside an embedded resource against that resource' do
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'child' => { 'inner' => 1 } }, schema)).to be_empty
      expect(validator.validate({ 'child' => { 'inner' => 'x' } }, schema))
        .to contain_exactly(a_string_matching(%r{#/child/inner: expected type integer}))
    end

    it 'resolves "#" inside an embedded resource to that resource' do
      expect(validator.validate({ 'child' => { 'self' => { 'inner' => 2 } } }, schema)).to be_empty
      expect(validator.validate({ 'child' => { 'self' => 'x' } }, schema))
        .to contain_exactly(a_string_matching(%r{#/child/self: expected type object}))
    end

    it 'reports a pointer that only exists in the enclosing document' do
      schema['properties']['child']['properties']['outer'] = { '$ref' => '#/properties/child' }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end
  end

  describe 'unsupported keywords behind local references' do
    it 'scans a target inside a definition bag the dialect does not walk' do
      # draft-07 predates `$defs`, so nothing walks it there: only following
      # the reference reaches what it holds.
      schema = { '$schema' => draft7, 'type' => 'object',
                 'properties' => { 'email' => { '$ref' => '#/$defs/email' } },
                 '$defs' => { 'email' => { 'type' => 'string', 'format' => 'email' } } }
      expect(validator.unsupported_keywords(schema)).to eq(['format'])
    end

    it 'scans a target reached through an anchor and stops at a cycle' do
      schema = { 'properties' => { 'a' => { '$ref' => '#node' } },
                 '$defs' => { 'n' => { '$anchor' => 'node', 'format' => 'uri', 'items' => { '$ref' => '#node' } } } }
      expect(validator.unsupported_keywords(schema)).to eq(['format'])
    end

    it 'ignores keywords beside a draft-07 $ref' do
      schema = { '$schema' => draft7, '$ref' => '#/definitions/x', 'format' => 'email',
                 'definitions' => { 'x' => { 'type' => 'string' } } }
      expect(validator.unsupported_keywords(schema)).to be_empty
    end
  end

  describe 'an if without branches' do
    # The condition is evaluated all the same (its annotations are what an
    # `unevaluated*` beside it reads, 2020-12 Section 10.2.2.1), it just
    # asserts nothing; one that applies the schema to the same instance
    # again is the cycle it is reported as.
    it 'is evaluated but asserts nothing' do
      expect(validator.check_schema({ 'if' => { '$ref' => '#' } })).to be_empty
      expect(validator.validate(1, { 'if' => { '$ref' => '#' } })).to contain_exactly(a_string_matching(/cycle/))
      expect(validator.validate(1, { 'if' => { 'type' => 'string' } })).to be_empty
      expect(validator.validate(1, { 'if' => { 'type' => 'integer' } })).to be_empty
    end

    it 'still selects a branch when one exists' do
      expect(validator.validate(1, { 'if' => { 'type' => 'string' }, 'else' => false })).not_to be_empty
      expect(validator.validate('s', { 'if' => { 'type' => 'string' }, 'then' => { 'minLength' => 3 } }))
        .not_to be_empty
    end
  end

  describe 'a schema wider than the bounds' do
    let(:recorder) do
      Class.new(Hash) do
        def self.visits = @visits ||= [0]

        def to_h(&)
          self.class.visits[0] += 1
          super
        end
      end
    end

    let(:huge) do
      props = {}
      (validator::MAX_SUBSCHEMAS * 8).times { |i| props["p#{i}"] = recorder[{ 'type' => 'string' }] }
      { 'type' => 'object', 'properties' => props }
    end

    it 'is rejected before it is copied whole' do
      expect(validator.check_schema(huge)).to contain_exactly(a_string_matching(/more than/))
      expect(recorder.visits[0]).to be < validator::MAX_SUBSCHEMAS * 8
      expect(validator.validate({}, huge)).to contain_exactly(a_string_matching(/more than/))
      expect(validator.unsupported_keywords(huge)).to eq([])
    end
  end
end

# --- round10 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, tenth review round: a `$ref` chain
# that crosses into an embedded resource is followed by where each hop
# lands, not by the text of its fragment, and an anchor declared twice in
# one schema resource makes the schema unusable.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 10' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'reference chains across resources' do
    let(:schema) do
      {
        'properties' => { 'a' => { '$ref' => '#/$defs/x' } },
        '$defs' => {
          'x' => {
            '$id' => 'https://example.com/inner',
            '$ref' => '#/$defs/x',
            '$defs' => { 'x' => { 'type' => 'string' } }
          }
        }
      }
    end

    it 'follows the same fragment text into an embedded resource without calling it a cycle' do
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 'ok' }, schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'still reports a chain that returns to a schema it visited' do
      cyclic = { 'properties' => { 'a' => { '$ref' => '#/$defs/x' } },
                 '$defs' => { 'x' => { '$ref' => '#/$defs/y' }, 'y' => { '$ref' => '#/$defs/x' } } }
      expect(validator.check_schema(cyclic)).to contain_exactly(a_string_matching(/cycles/))
    end
  end

  describe 'names of a resource reached through a foreign bag' do
    let(:schema) do
      {
        'properties' => { 'a' => { '$ref' => '#/x-defs/x' } },
        # A vendor bag no dialect defines, so nothing walks it: the resource
        # is reached only by following the pointer.
        'x-defs' => {
          'x' => { '$id' => 'https://example.com/x', '$anchor' => 'trap', 'type' => 'object',
                   'properties' => { 'v' => { '$ref' => '#trap' } } }
        }
      }
    end

    it 'resolves the resource\'s own anchor even when the resource sits in a bag the dialect does not walk' do
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => { 'v' => {} } }, schema)).to be_empty
      expect(validator.validate({ 'a' => { 'v' => 1 } },
                                schema)).to contain_exactly(a_string_matching(/expected type object/))
    end

    it 'still hides that name from the enclosing resource' do
      schema['properties']['b'] = { '$ref' => '#trap' }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref "#trap"/))
    end
  end

  describe 'wide leaf maps' do
    it 'rejects a wide map of leaf values before copying it' do
      huge = {}
      (validator::MAX_STRUCTURAL_OBJECTS + 10).times { |i| huge["k#{i}"] = i }
      schema = { 'type' => 'integer', 'x-huge' => huge }
      allow(huge).to receive(:to_h).and_raise('the map must not be copied whole')
      allow(huge).to receive(:each).and_raise('the map must not be copied whole')
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/structural elements/))
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/structural elements/))
    end

    it 'runs the normalization under the validation deadline' do
      schema = { 'type' => 'integer', 'x-slow' => { 'k' => 1 } }
      past = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
      expect(validator.validate(1, schema, deadline: past)).to contain_exactly(a_string_matching(/aborted|time/))
    end
  end

  describe 'duplicate anchors' do
    it 'rejects an $anchor declared twice in one resource' do
      schema = {
        'properties' => { 'a' => { '$ref' => '#node' } },
        '$defs' => { 'x' => { '$anchor' => 'node', 'type' => 'string' },
                     'y' => { '$anchor' => 'node', 'type' => 'integer' } }
      }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/anchor "node".*more than once/))
      expect(validator.validate({ 'a' => 'ok' }, schema)).to contain_exactly(a_string_matching(/anchor "node"/))
    end

    it 'rejects a $dynamicAnchor colliding with an $anchor' do
      schema = { '$defs' => { 'x' => { '$anchor' => 'node' }, 'y' => { '$dynamicAnchor' => 'node' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/anchor "node".*more than once/))
    end

    it 'rejects a draft-07 fragment $id declared twice' do
      schema = { '$schema' => draft7,
                 'definitions' => { 'x' => { '$id' => '#node' }, 'y' => { '$id' => '#node' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/anchor "node".*more than once/))
    end

    it 'allows the same name in different resources' do
      schema = {
        'properties' => { 'a' => { '$ref' => '#node' } },
        '$defs' => { 'x' => { '$anchor' => 'node', 'type' => 'string' },
                     'y' => { '$id' => 'https://example.com/other', '$anchor' => 'node', 'type' => 'integer' } }
      }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end
  end
end

# --- round11 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, eleventh review round: a branch the
# validator can only partly evaluate is no verdict for not / oneOf / if,
# the structural bound covers deep subtrees, the client never hashes a
# peer schema whole, a draft-07 `$id` beside a `$ref` is ignored, a
# truncated anchor index makes the schema unusable, and malformed JSON
# Pointer escapes are unresolvable.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 11' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'partially evaluated branches' do
    it 'does not reject a value because a not branch it cannot decide seemed to match' do
      # `unevaluatedItems` needs the annotations a whole composition produces,
      # so a branch carrying one is a verdict this validator cannot reach.
      expect(validator.validate([1], { 'not' => { 'unevaluatedItems' => false } })).to be_empty
      # A decided branch still asserts.
      expect(validator.validate('x', { 'not' => { 'type' => 'string' } })).to contain_exactly(a_string_matching(/not/))
      # A branch that fails on an evaluated keyword is decided even when it
      # also carries an unevaluated one.
      undecided_then_failing = { 'not' => { 'allOf' => [{ 'unevaluatedItems' => false }, { 'type' => 'string' }] } }
      expect(validator.validate([1], undecided_then_failing)).to be_empty
      # unevaluatedItems does not apply to a string, so that branch is decided
      # by its type alone and matches: not rejects the string.
      expect(validator.validate('x', undecided_then_failing)).to contain_exactly(a_string_matching(/not/))
    end

    it 'does not count an undecided oneOf branch as a match' do
      schema = { 'oneOf' => [{ 'unevaluatedItems' => false }, { 'type' => 'array' }] }
      expect(validator.validate([1], schema)).to be_empty
      decided = { 'oneOf' => [{ 'type' => 'number' }, { 'type' => 'integer' }] }
      expect(validator.validate(3, decided)).to contain_exactly(a_string_matching(/oneOf/))
    end

    it 'skips a conditional whose if it cannot decide, unless the branches agree' do
      # Neither branch can be selected, but both reject the value, so the
      # instance is rejected whichever way the condition goes.
      # draft-07 `format` asserts and formats are not evaluated: a string
      # branch carrying one is genuinely undecidable.
      draft7 = MCPClient::SchemaValidator::DRAFT_07
      condition = { 'format' => 'email' }
      agreed = { '$schema' => draft7, 'if' => condition, 'then' => { 'type' => 'integer' },
                 'else' => { 'type' => 'integer' } }
      expect(validator.validate('x', agreed)).to contain_exactly(a_string_matching(/expected type integer/))
      schema = { '$schema' => draft7, 'if' => condition, 'then' => { 'type' => 'integer' },
                 'else' => { 'type' => 'string' } }
      expect(validator.validate('x', schema)).to be_empty
      decided = { 'if' => { 'type' => 'integer' }, 'then' => { 'type' => 'string' } }
      expect(validator.validate(3, decided)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'keeps treating a partial pass as a pass where that is the permissive direction' do
      draft7 = MCPClient::SchemaValidator::DRAFT_07
      expect(validator.validate('x', { '$schema' => draft7, 'anyOf' => [{ 'format' => 'email' }] })).to be_empty
      expect(validator.validate('x', { '$schema' => draft7, 'allOf' => [{ 'format' => 'email' }] })).to be_empty
      # An assertion this validator does evaluate decides those compositions
      # rather than passing them: an unevaluated one is not a licence to
      # accept what the schema rejects.
      expect(validator.validate(4, { 'anyOf' => [{ 'multipleOf' => 3 }] }))
        .to contain_exactly(a_string_matching(/anyOf/))
      expect(validator.validate(4, { 'allOf' => [{ 'multipleOf' => 3 }] }))
        .to contain_exactly(a_string_matching(%r{allOf/0}))
    end
  end

  describe 'deep subtrees' do
    def nested(levels, leaf)
      levels.times.reduce(leaf) { |inner, _| { 'type' => 'object', 'properties' => { 'a' => inner } } }
    end

    it 'normalizes and charges a subtree below the nesting bound' do
      schema = nested(40, { type: 'integer' })
      data = 40.times.reduce('x') { |inner, _| { 'a' => inner } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(data, schema)).to contain_exactly(a_string_matching(/expected type integer/))

      wide = {}
      (validator::MAX_STRUCTURAL_OBJECTS + 10).times { |i| wide["p#{i}"] = true }
      expect(validator.check_schema(nested(40, { 'type' => 'object', 'properties' => wide })))
        .to contain_exactly(a_string_matching(/structural elements/))
    end

    it 'reports a document nested beyond the bound instead of keeping the rest raw' do
      deep = nested(validator::MAX_SCHEMA_DEPTH + 10, { 'type' => 'integer' })
      expect(validator.check_schema(deep)).to contain_exactly(a_string_matching(/depth/))
    end
  end

  describe 'draft-07 $id beside $ref' do
    it 'ignores a URI $id next to a $ref like every other sibling' do
      schema = { '$schema' => draft7,
                 'properties' => { 'a' => { '$ref' => '#/definitions/int', '$id' => 'https://example.com/ignored' } },
                 'definitions' => { 'int' => { 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'a' => 'x' }, schema)).to contain_exactly(a_string_matching(/expected type integer/))
    end
  end

  describe 'anchor index bound' do
    it 'makes a document whose anchors cannot be fully indexed unusable' do
      bag = {}
      validator::MAX_SUBSCHEMAS.times { |i| bag["d#{i}"] = { 'type' => 'string' } }
      # The bag sits under the container this dialect does not define, so
      # the preflight walk never reads it while the index still must.
      schema = {
        '$schema' => draft7,
        'properties' => { 'a' => { '$ref' => '#/definitions/holder/definitions/t' } },
        'definitions' => { 'holder' => { 'definitions' => { 't' => { '$id' => 'https://example.com/t',
                                                                     'items' => [{ 'type' => 'integer' }] } } } },
        '$defs' => bag
      }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/index/))
      expect(validator.validate({ 'a' => ['x'] }, schema)).to contain_exactly(a_string_matching(/index/))
    end
  end

  describe 'JSON Pointer escapes' do
    it 'treats a tilde not followed by 0 or 1 as an unresolvable reference' do
      schema = { 'properties' => { 'a' => { '$ref' => '#/$defs/bad~2key' } },
                 '$defs' => { 'bad~2key' => { 'type' => 'string' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/unresolvable/))
      good = { 'properties' => { 'a' => { '$ref' => '#/$defs/a~0b~1c' } },
               '$defs' => { 'a~b/c' => { 'type' => 'string' } } }
      expect(validator.check_schema(good)).to be_empty
    end
  end

  describe 'through MCPClient::Client' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def client_with(tools)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return(tools)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)
    end

    it 'never hashes a peer schema whole before the bounded check' do
      deep = { 'type' => 'object' }
      100_000.times { deep = { 'properties' => { 'a' => deep } } }
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: deep, output_schema: deep,
                                 server: mock_server)
      client = client_with([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })

      expect { client.send(:input_schema_state, tool) }.not_to raise_error
      expect { client.call_tool('t', {}) }.not_to raise_error
      expect(log_output.string).to include('not usable')
    end

    it 'checks a schema again only when the tool carries a different one' do
      schema = { 'type' => 'object', 'format' => 'custom' }
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: schema, output_schema: schema,
                                 server: mock_server)
      client = client_with([tool])
      allow(validator).to receive(:check_schema).and_call_original

      2.times { client.send(:input_schema_state, tool) }
      expect(validator).to have_received(:check_schema).once

      refreshed = MCPClient::Tool.new(name: 't', description: 'd', schema: schema.dup, server: mock_server)
      client.send(:input_schema_state, refreshed)
      expect(validator).to have_received(:check_schema).twice
    end
  end
end

# --- round15 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, fifteenth review round: lexical
# depths follow each resource's dialect, the keyword scan and boolean
# reference targets are bounded by their own position, an unusable input
# schema asserts nothing, and a tautological additionalItems is decided.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 15' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:modern) { 'https://json-schema.org/draft/2020-12/schema' }

  def nested_properties(depth, leaf)
    (1..depth).reduce(leaf) { |inner, _| { 'properties' => { 'a' => inner } } }
  end

  def nested_not(depth, leaf)
    (1..depth).reduce(leaf) { |inner, _| { 'not' => inner } }
  end

  it 'bounds a boolean reference target by its own lexical depth' do
    deep_bool = nested_not(validator::MAX_SCHEMA_DEPTH + 1, true)
    pointer = "#/definitions/n#{'/not' * (validator::MAX_SCHEMA_DEPTH + 1)}"
    schema = { 'properties' => { 'a' => { '$ref' => pointer } }, 'definitions' => { 'n' => deep_bool } }
    expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/depth/))

    shallow = { 'properties' => { 'a' => { '$ref' => '#/definitions/n/not' } },
                'definitions' => { 'n' => { 'not' => true } } }
    expect(validator.check_schema(shallow)).to be_empty
  end

  it 'follows each resource dialect when computing lexical depths, whatever the key order' do
    target = { '$id' => 'https://example.com/r', '$schema' => modern,
               'prefixItems' => [{ 'type' => 'integer' }] }
    chain = nested_properties(validator::MAX_SCHEMA_DEPTH, { '$ref' => '#/definitions/r/prefixItems/0' })
    ref_first = { '$schema' => draft7 }.merge(chain).merge('definitions' => { 'r' => target })
    resource_first = { '$schema' => draft7, 'definitions' => { 'r' => target } }.merge(chain)

    expect(validator.check_schema(ref_first)).to be_empty
    expect(validator.check_schema(resource_first)).to be_empty
  end

  it 'scans a referenced target for unsupported keywords at its own lexical depth' do
    chain = nested_properties(validator::MAX_SCHEMA_DEPTH - 1, { '$ref' => '#/$defs/t' })
    # `format` only annotates in 2020-12, and is reported as such.
    schema = chain.merge('$defs' => { 't' => { 'items' => { 'format' => 'uuid' } } })
    expect(validator.check_schema(schema)).to be_empty
    expect(validator.unsupported_keywords(schema)).to include('format')
  end

  it 'treats a tautological additionalItems beside a tuple as decided' do
    # Two items against a one-schema tuple, so `additionalItems` really does
    # apply to the second: a tautological one still decides the branch.
    schema = { '$schema' => draft7, 'not' => { 'items' => [true], 'additionalItems' => true } }
    expect(validator.validate([1, 2], schema)).to contain_exactly(a_string_matching(/not/))
    empty_schema = { '$schema' => draft7, 'not' => { 'items' => [true], 'additionalItems' => {} } }
    expect(validator.validate([1, 2], empty_schema)).to contain_exactly(a_string_matching(/not/))
    real = { '$schema' => draft7, 'not' => { 'items' => [true], 'additionalItems' => false } }
    expect(validator.validate([1, 2], real)).to be_empty
  end

  describe 'through MCPClient::Client' do
    let(:logger) { Logger.new(StringIO.new) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    it 'sends the call when the input schema is unusable, whatever it claims to require' do
      # An unusable schema asserts nothing, so the server judges the
      # arguments; an unsupported *dialect* is an error instead (MCP
      # 2026-07-28 "Implementation Requirements"), covered in the
      # verification round.
      schema = { 'type' => 'object', 'required' => ['x'],
                 'properties' => { 'x' => { '$ref' => 'https://example.com/x' } } }
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: schema, server: mock_server)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [] })
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)

      expect { client.call_tool('t', {}) }.not_to raise_error
      expect { client.call_tool('t', {}) }.not_to raise_error
      expect(mock_server).to have_received(:call_tool).twice
    end
  end
end

# --- round21 ---------------------------------------------------------------

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
  # The back-reference is to a group `?` quantifies, which repeats at most
  # once, so it is a pattern this validator translates — and one Ruby's
  # optimizer cannot flatten, so matching it burns the whole budget.
  let(:evil_pattern) { '^(x?)(a*)*\1$' }
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

# --- round22 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, twenty-second round: a subtree a
# pointer reaches through a data keyword is adopted once and every pointer
# into it lands on the indexed objects (their own resource, dialect and
# subschema charge), the identifiers such a subtree declares are never the
# document's, a reference whose percent-encoding is not readable resolves to
# nothing instead of raising, a property named like a data keyword is a
# schema position, and a branch that already failed a supported assertion is
# not measured for the keywords it does not evaluate.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 22' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }

  describe 'a pointer into an adopted subtree' do
    it 'keeps the dialect of the resource the pointer entered' do
      schema = { 'allOf' => [{ '$ref' => '#/default/$defs/i' }],
                 'default' => { '$id' => 'https://example.com/emb', '$schema' => draft7,
                                '$defs' => { 'i' => { 'items' => [{ 'type' => 'integer' }] } } } }

      expect(validator.check_schema(schema)).to be_empty
      # draft-07 reads the items array positionally; 2020-12 would reject it.
      expect(validator.validate(['x'], schema))
        .to contain_exactly(a_string_matching(%r{#/0: expected type integer}))
    end

    it 'does not declare the anchors of the adopted subtree twice' do
      schema = { 'properties' => { 'a' => { '$ref' => '#/default' } },
                 'default' => { '$defs' => { 'i' => { '$anchor' => 'int', 'type' => 'integer' } },
                                'properties' => { 'b' => { '$ref' => '#/default/$defs/i' } } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => { 'b' => 'x' } }, schema))
        .to contain_exactly(a_string_matching(%r{#/a/b: expected type integer}))
    end

    it 'charges the adopted subtree against the subschema bound once' do
      big = { 'allOf' => Array.new(1200) { { 'type' => 'integer' } } }
      schema = { 'allOf' => [{ '$ref' => '#/default' }, { '$ref' => '#/default/$defs/i' }],
                 'default' => { '$defs' => { 'i' => big } } }

      expect(validator.check_schema(schema)).to be_empty
    end
  end

  describe 'identifiers written inside a data keyword' do
    it 'are not the document\'s anchors' do
      schema = { '$defs' => { 'x' => { '$anchor' => 'foo', 'type' => 'string' } },
                 'properties' => { 'a' => { '$ref' => '#/default' } },
                 'default' => { '$anchor' => 'foo', 'type' => 'integer' },
                 'allOf' => [{ '$ref' => '#foo' }] }

      expect(validator.check_schema(schema)).to be_empty
      # "#foo" is the one the document declares, whatever the data keyword holds.
      expect(validator.validate('x', schema)).to be_empty
      expect(validator.validate(1, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'resolves a plain name the same way whatever the member order' do
      props_first = { 'properties' => { 'a' => { '$ref' => '#/default' } },
                      'default' => { '$anchor' => 'foo', 'type' => 'integer' },
                      'allOf' => [{ '$ref' => '#foo' }] }
      allof_first = { 'allOf' => [{ '$ref' => '#foo' }],
                      'properties' => { 'a' => { '$ref' => '#/default' } },
                      'default' => { '$anchor' => 'foo', 'type' => 'integer' } }

      expect(validator.check_schema(props_first))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref "#foo"/))
      expect(validator.check_schema(allof_first)).to eq(validator.check_schema(props_first))
    end

    it 'validates the same way whatever the instance' do
      schema = { 'properties' => { 'a' => { '$ref' => '#/default' } },
                 'default' => { '$anchor' => 'foo', 'type' => 'integer' },
                 'allOf' => [{ '$ref' => '#foo' }] }

      expect(validator.validate('x', schema)).to eq(validator.validate({ 'a' => 1 }, schema))
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end
  end

  describe 'a reference whose percent-encoding is not readable' do
    it 'resolves to nothing rather than raising' do
      expect { validator.check_schema({ '$ref' => '#%FF' }) }.not_to raise_error
      expect(validator.check_schema({ '$ref' => '#%FF' }))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
      expect(validator.check_schema({ '$ref' => '#/%FF' }))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
      expect(validator.validate(1, { '$ref' => '#/%FF' }))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end

    it 'still reads a readable escape' do
      schema = { '$ref' => '#/$defs/a%2Db', '$defs' => { 'a-b' => { 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/expected type integer/))
    end
  end

  describe 'a property named like a data keyword' do
    it 'is a schema position, not data' do
      schema = { properties: { enum: { type: 'string' } } }

      expect(validator.validate({ 'enum' => 123 }, schema))
        .to contain_exactly(a_string_matching(%r{#/enum: expected type string}))
      expect(validator.validate({ 'enum' => 'ok' }, schema)).to be_empty
    end

    it 'still keeps a real data keyword as it was given' do
      schema = { type: 'object', properties: { a: { const: { b: 1 } } } }

      expect(validator.validate({ 'a' => { b: 1 } }, schema)).to be_empty
      expect(validator.validate({ 'a' => { 'c' => 1 } }, schema)).not_to be_empty
    end
  end

  describe 'a node whose own type already rejected the value' do
    # Backtracking Ruby's regexp cache cannot flatten: matching it would burn
    # the whole validation budget. The back-reference is to a group `?`
    # quantifies, which repeats at most once, so it stays a pattern this
    # validator translates.
    let(:evil_pattern) { '^(x?)(a*)*\1$' }
    let(:evil_name) { "#{'a' * 17}!" }

    it 'spends nothing more on the keywords for the type it does not have' do
      schema = { 'not' => { 'type' => 'string', 'patternProperties' => { evil_pattern => false } } }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      errors = validator.validate({ evil_name => 1 }, schema)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
      expect(errors).to be_empty
    end

    it 'still applies them when the type accepts the value' do
      schema = { 'not' => { 'type' => 'object', 'patternProperties' => { '^a' => { 'type' => 'string' } } } }
      expect(validator.validate({ 'ab' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'ab' => 'x' }, schema)).to contain_exactly(a_string_matching(/not/))
    end
  end

  describe 'the once-per-definition schema checks' do
    let(:logger) { Logger.new(StringIO.new) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }

    def tool(name)
      MCPClient::Tool.from_json({ 'name' => name, 'description' => 'd',
                                  'inputSchema' => { 'type' => 'object' },
                                  'outputSchema' => { 'type' => 'object', 'minProperties' => 1 } },
                                server: mock_server)
    end

    def client_with(tools)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return(tools)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger)
    end

    it 'forgets the tools a refreshed list no longer carries' do
      client = client_with([tool('old')])
      client.send(:input_schema_state, tool('old'))
      client.send(:warn_partial_schema_coverage, tool('old'))
      client.send(:output_schema_state, tool('old'))
      expect(client.instance_variable_get(:@input_schema_warnings)).not_to be_empty
      expect(client.instance_variable_get(:@output_schema_dialects)).not_to be_empty

      allow(mock_server).to receive(:list_tools).and_return([tool('new')])
      client.list_tools(cache: false)

      expect(client.instance_variable_get(:@input_schema_warnings)).to be_empty
      expect(client.instance_variable_get(:@output_schema_coverage)).to be_empty
      # The output-dialect memo is keyed by a tool definition too, so it is
      # forgotten with the rest: a server that keeps renaming its tools must
      # not grow it without bound.
      expect(client.instance_variable_get(:@output_schema_dialects)).to be_empty
    end

    # An emptied memo hash is only the mechanism; what matters is that the
    # next call decides on the definition the server is now serving.
    it 'decides the next call on the refreshed definition, warning about it again' do
      log = StringIO.new
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      partial = MCPClient::Tool.from_json({ 'name' => 't', 'description' => 'd',
                                            'inputSchema' => { 'type' => 'object' },
                                            'outputSchema' => { 'type' => 'object', 'format' => 'x' } },
                                          server: mock_server)
      allow(mock_server).to receive(:list_tools).and_return([partial])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => { 'a' => 1 } })
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }],
                                     logger: Logger.new(log))

      2.times { client.call_tool('t', {}) }
      expect(log.string.scan('validation is partial').size).to eq(1)

      # A refreshed definition the notification announces: the coverage
      # warning is made again, and it names what the new schema uses.
      refreshed = MCPClient::Tool.from_json(
        { 'name' => 't', 'description' => 'd', 'inputSchema' => { 'type' => 'object' },
          'outputSchema' => { 'type' => 'object', 'properties' => { 'a' => { 'contentSchema' => true } } } },
        server: mock_server
      )
      allow(mock_server).to receive(:list_tools).and_return([refreshed])
      client.send(:invalidate_caches_for_notification, mock_server, 'notifications/tools/list_changed')

      client.call_tool('t', {})
      expect(log.string.scan('validation is partial').size).to eq(2)
      expect(log.string).to include('contentSchema')

      # And a refreshed dialect is refused, rather than read from the memo
      # the first definition filled in.
      unusable = MCPClient::Tool.from_json(
        { 'name' => 't', 'description' => 'd',
          'inputSchema' => { '$schema' => 'urn:unknown', 'type' => 'object' } }, server: mock_server
      )
      allow(mock_server).to receive(:list_tools).and_return([unusable])
      client.send(:invalidate_caches_for_notification, mock_server, 'notifications/tools/list_changed')

      expect { client.call_tool('t', {}) }.to raise_error(MCPClient::Errors::ValidationError, /urn:unknown/)
    end

    it 'forgets them when the whole cache is cleared' do
      client = client_with([tool('old')])
      client.send(:input_schema_state, tool('old'))
      client.send(:warn_partial_schema_coverage, tool('old'))

      client.clear_cache

      expect(client.instance_variable_get(:@input_schema_warnings)).to be_empty
      expect(client.instance_variable_get(:@output_schema_coverage)).to be_empty
    end
  end
end

# --- round23 ---------------------------------------------------------------

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

    it 'leaves a contains whose items it cannot decide undecided' do
      # An item the validator cannot decide is neither a match nor a
      # non-match, so the count never settles and `not` must not fail here.
      undecidable = { 'contains' => { 'format' => 'email' } }
      expect(validator.validate(['x'], { '$schema' => MCPClient::SchemaValidator::DRAFT_07,
                                         'not' => undecidable })).to be_empty
      # A contains schema it can evaluate decides the branch outright.
      expect(validator.validate([1], { 'not' => { 'contains' => { 'type' => 'integer' } } }))
        .to contain_exactly(a_string_matching(/value satisfies the schema in not/))
      expect(validator.validate([1], { 'if' => { 'contains' => { 'type' => 'string' } }, 'else' => false }))
        .to contain_exactly(a_string_matching(/schema false accepts no value/))
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

    it 'fails the branch outright while a required name is absent' do
      # `dependentRequired` is evaluated, so a missing name is a definite
      # failure rather than an unreachable verdict — which `if`/`else` shows
      # and a bare `not` (empty either way) cannot.
      absent = { 'dependentRequired' => { 'a' => %w[b] } }
      expect(validator.validate({ 'a' => 1 }, { 'not' => absent })).to be_empty
      expect(validator.validate({ 'a' => 1 }, { 'if' => absent, 'else' => false }))
        .to contain_exactly(a_string_matching(/schema false accepts no value/))
      expect(validator.validate({ 'a' => 1, 'b' => 2 },
                                { 'if' => { 'dependentRequired' => { 'a' => %w[b c] } }, 'else' => false }))
        .to contain_exactly(a_string_matching(/schema false accepts no value/))
    end

    it 'reads the symbol key form of the instance as present' do
      expect(validator.validate({ a: 1, b: 2 }, { 'not' => { 'dependentRequired' => { 'a' => %w[b] } } }))
        .to contain_exactly(a_string_matching(/value satisfies the schema in not/))
    end
  end
end

# --- round24 ---------------------------------------------------------------

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

# --- round25 ---------------------------------------------------------------

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
                 'y' => { 'type' => 'array', 'items' => { 'format' => 'uuid' } } }

      expect(validator.unsupported_keywords(schema)).to contain_exactly('format')
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

    it 'matches the items themselves where the bounds leave the count open' do
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' } }))
        .to contain_exactly(a_string_matching(/at least 1 items matching contains/))
      expect(validator.validate([1, 'x'], { 'contains' => { 'type' => 'string' } })).to be_empty
      # `minContains: 0` switches the lower bound off, and a `maxContains` no
      # count can exceed asserts nothing either.
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' },
                                          'minContains' => 0, 'maxContains' => 0 })).to be_empty
    end

    it 'leaves a draft-07 maxContains alone, the dialect not defining it' do
      schema = { '$schema' => 'http://json-schema.org/draft-07/schema#',
                 'contains' => { 'type' => 'string' }, 'maxContains' => 0 }

      # The unknown upper bound makes nothing unsatisfiable: draft-07
      # `contains` asks only for one matching item, and never for at most none.
      expect(validator.validate([1, 2], schema))
        .to contain_exactly(a_string_matching(/at least 1 items matching contains/))
      expect(validator.validate([1, 'x', 'y'], schema)).to be_empty
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

# --- round28 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, twenty-eighth round.
#
# MCP 2026-07-28 basic "Implementation Requirements" makes 2020-12 support
# mandatory, and a validator that leaves a standard assertion unevaluated
# does not merely report less: it accepts instances the schema rejects.
# `{"allOf": [{"multipleOf": 3}]}` admitted 4, `{"not": {"multipleOf": 2}}`
# admitted 4, `uniqueItems` admitted `[1, 1]` and `contains` was decided by
# the array's length alone. The assertions and applicators whose verdict does
# not depend on annotations collected across a composition are now evaluated,
# and only the annotation-driven ones (`unevaluatedItems`,
# `unevaluatedProperties`), the dynamic references and `format` are left to
# the partial-coverage report.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 28' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:draft2019) { 'https://json-schema.org/draft/2019-09/schema' }

  describe 'multipleOf' do
    it 'asserts on its own and inside every composition' do
      expect(validator.validate(4, { 'multipleOf' => 3 })).to contain_exactly(a_string_matching(/multiple of 3/))
      expect(validator.validate(6, { 'multipleOf' => 3 })).to be_empty
      expect(validator.validate(4, { 'allOf' => [{ 'multipleOf' => 3 }] }))
        .to contain_exactly(a_string_matching(%r{allOf/0}))
      expect(validator.validate(4, { 'anyOf' => [{ 'multipleOf' => 3 }] }))
        .to contain_exactly(a_string_matching(/anyOf/))
      expect(validator.validate(4, { 'not' => { 'multipleOf' => 2 } }))
        .to contain_exactly(a_string_matching(/not/))
      # The condition is decided now, so `then` is applied rather than skipped.
      conditional = { 'if' => { 'multipleOf' => 2 }, 'then' => { 'type' => 'string' },
                      'else' => { 'type' => 'integer' } }
      expect(validator.validate(4, conditional)).to contain_exactly(a_string_matching(/expected type string/))
      expect(validator.validate(3, conditional)).to be_empty
    end

    it 'divides exactly rather than in binary floating point' do
      expect(validator.validate(0.0075, { 'multipleOf' => 0.0001 })).to be_empty
      expect(validator.validate(1.5, { 'multipleOf' => 0.5 })).to be_empty
      expect(validator.validate(1.6, { 'multipleOf' => 0.5 })).to contain_exactly(a_string_matching(/multiple of/))
      # Applies to numbers only.
      expect(validator.validate('4', { 'multipleOf' => 3 })).to be_empty
    end

    it 'refuses a schema whose multipleOf is not a positive number' do
      expect(validator.check_schema({ 'multipleOf' => 0 })).to contain_exactly(a_string_matching(/multipleOf/))
      expect(validator.check_schema({ 'multipleOf' => -2 })).to contain_exactly(a_string_matching(/multipleOf/))
      expect(validator.check_schema({ 'multipleOf' => 'two' })).to contain_exactly(a_string_matching(/multipleOf/))
      expect(validator.check_schema({ 'multipleOf' => 0.5 })).to be_empty
    end
  end

  describe 'uniqueItems' do
    it 'rejects equal items, comparing JSON values rather than Ruby objects' do
      expect(validator.validate([1, 1], { 'uniqueItems' => true })).to contain_exactly(a_string_matching(/unique/))
      # JSON Schema equality: 1 and 1.0 are the same number.
      expect(validator.validate([1, 1.0], { 'uniqueItems' => true })).to contain_exactly(a_string_matching(/unique/))
      expect(validator.validate([{ 'a' => 1, 'b' => 2 }, { 'b' => 2, 'a' => 1 }], { 'uniqueItems' => true }))
        .to contain_exactly(a_string_matching(/unique/))
      expect(validator.validate([1, true], { 'uniqueItems' => true })).to be_empty
      expect(validator.validate([1, 2], { 'uniqueItems' => true })).to be_empty
      expect(validator.validate([1, 1], { 'uniqueItems' => false })).to be_empty
    end

    it 'decides a not branch that only uniqueItems can settle' do
      expect(validator.validate([1, 1], { 'not' => { 'uniqueItems' => true } })).to be_empty
      expect(validator.validate([1, 2], { 'not' => { 'uniqueItems' => true } }))
        .to contain_exactly(a_string_matching(/not/))
    end
  end

  describe 'contains' do
    it 'matches item by item instead of reading the array length alone' do
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' } }))
        .to contain_exactly(a_string_matching(/at least 1 items matching contains/))
      expect(validator.validate([1, 'x'], { 'contains' => { 'type' => 'string' } })).to be_empty
      expect(validator.validate([1, 'x', 'y'], { 'contains' => { 'type' => 'string' }, 'maxContains' => 1 }))
        .to contain_exactly(a_string_matching(/at most 1 items matching contains/))
      expect(validator.validate(%w[x y], { 'contains' => { 'type' => 'string' }, 'minContains' => 3 }))
        .to contain_exactly(a_string_matching(/at least 3 items matching contains/))
      # minContains 0 switches the lower bound off entirely.
      expect(validator.validate([1, 2], { 'contains' => { 'type' => 'string' }, 'minContains' => 0 })).to be_empty
    end

    it 'decides a composition that turns on contains' do
      expect(validator.validate([1, 2], { 'not' => { 'contains' => { 'type' => 'integer' } } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate([1, 2], { 'not' => { 'contains' => { 'type' => 'string' } } })).to be_empty
    end

    it 'refuses a schema whose contains bounds are not non-negative integers' do
      expect(validator.check_schema({ 'contains' => true, 'minContains' => -1 }))
        .to contain_exactly(a_string_matching(/minContains/))
      expect(validator.check_schema({ 'contains' => true, 'maxContains' => 1.5 }))
        .to contain_exactly(a_string_matching(/maxContains/))
      # draft-07 does not define the bounds, so nothing there is malformed.
      expect(validator.check_schema({ '$schema' => draft7, 'contains' => true, 'minContains' => -1 })).to be_empty
    end
  end

  describe 'object assertions' do
    it 'applies property counts and dependent requirements' do
      expect(validator.validate({}, { 'minProperties' => 1 })).to contain_exactly(a_string_matching(/minProperties/))
      expect(validator.validate({ 'a' => 1, 'b' => 2 }, { 'maxProperties' => 1 }))
        .to contain_exactly(a_string_matching(/maxProperties/))
      dependent = { 'dependentRequired' => { 'card' => ['billing'] } }
      expect(validator.validate({ 'card' => 1 }, dependent)).to contain_exactly(a_string_matching(/billing/))
      expect(validator.validate({ 'card' => 1, 'billing' => 2 }, dependent)).to be_empty
      expect(validator.validate({ 'billing' => 2 }, dependent)).to be_empty
      # draft-07 spells the same assertion `dependencies`.
      legacy = { '$schema' => draft7, 'dependencies' => { 'card' => ['billing'] } }
      expect(validator.validate({ 'card' => 1 }, legacy)).to contain_exactly(a_string_matching(/billing/))
    end

    it 'applies patternProperties, additionalProperties and propertyNames' do
      schema = { 'properties' => { 'a' => { 'type' => 'integer' } },
                 'patternProperties' => { '^x' => { 'type' => 'string' } },
                 'additionalProperties' => false }
      expect(validator.validate({ 'a' => 1, 'xy' => 'ok' }, schema)).to be_empty
      expect(validator.validate({ 'xy' => 3 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
      expect(validator.validate({ 'zz' => 1 }, schema)).to contain_exactly(a_string_matching(/not allowed/))

      typed = { 'additionalProperties' => { 'type' => 'integer' } }
      expect(validator.validate({ 'z' => 'x' }, typed)).to contain_exactly(a_string_matching(/expected type integer/))
      names = { 'propertyNames' => { 'maxLength' => 2 } }
      expect(validator.validate({ 'ab' => 1 }, names)).to be_empty
      expect(validator.validate({ 'abc' => 1 }, names)).to contain_exactly(a_string_matching(/propertyNames/))
    end

    it 'applies the schema form of a dependency to the same instance' do
      schema = { 'dependentSchemas' => { 'card' => { 'required' => ['billing'] } } }
      expect(validator.validate({ 'card' => 1 }, schema)).to contain_exactly(a_string_matching(/billing/))
      expect(validator.validate({ 'card' => 1, 'billing' => 2 }, schema)).to be_empty
      expect(validator.validate({ 'other' => 1 }, schema)).to be_empty
      legacy = { '$schema' => draft7, 'dependencies' => { 'card' => { 'required' => ['billing'] } } }
      expect(validator.validate({ 'card' => 1 }, legacy)).to contain_exactly(a_string_matching(/billing/))
    end

    it 'refuses malformed property-count and dependency values' do
      expect(validator.check_schema({ 'minProperties' => -1 }))
        .to contain_exactly(a_string_matching(/minProperties/))
      expect(validator.check_schema({ 'maxProperties' => 'lots' }))
        .to contain_exactly(a_string_matching(/maxProperties/))
      expect(validator.check_schema({ 'uniqueItems' => 'yes' })).to contain_exactly(a_string_matching(/uniqueItems/))
      expect(validator.check_schema({ 'dependentRequired' => { 'a' => 'b' } }))
        .to contain_exactly(a_string_matching(/dependentRequired/))
    end
  end

  describe 'draft-07 additionalItems' do
    it 'applies the tuple tail schema' do
      schema = { '$schema' => draft7, 'items' => [{ 'type' => 'integer' }], 'additionalItems' => false }
      expect(validator.validate([1], schema)).to be_empty
      expect(validator.validate([1, 2], schema)).to contain_exactly(a_string_matching(/not allowed/))
      typed = { '$schema' => draft2019, 'items' => [{ 'type' => 'integer' }],
                'additionalItems' => { 'type' => 'string' } }
      expect(validator.validate([1, 'x'], typed)).to be_empty
      expect(validator.validate([1, 2], typed)).to contain_exactly(a_string_matching(/expected type string/))
    end
  end

  describe 'identifier collisions' do
    it 'refuses a document whose resources declare the same URI' do
      schema = { '$ref' => 'urn:s',
                 '$defs' => { 'a' => { '$id' => 'urn:s', 'type' => 'string' },
                              'b' => { '$id' => 'urn:s', 'type' => 'integer' } } }
      # Which declaration a reference lands on would otherwise depend on the
      # order the walk met them in.
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/urn:s.*more than once/))
      expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/urn:s.*more than once/))
      distinct = { '$ref' => 'urn:s',
                   '$defs' => { 'a' => { '$id' => 'urn:s', 'type' => 'string' },
                                'b' => { '$id' => 'urn:t', 'type' => 'integer' } } }
      expect(validator.check_schema(distinct)).to be_empty
    end

    it 'refuses an $id carrying a non-empty fragment, and a malformed anchor' do
      expect(validator.check_schema({ '$id' => 'urn:root#bad', 'type' => 'integer' }))
        .to contain_exactly(a_string_matching(/\$id.*fragment/))
      expect(validator.check_schema({ '$id' => 'urn:root#', 'type' => 'integer' })).to be_empty
      expect(validator.check_schema({ '$anchor' => 'not a name' }))
        .to contain_exactly(a_string_matching(/\$anchor must be a plain name/))
      # draft-07 spells a plain-name identifier as a bare fragment.
      expect(validator.check_schema({ '$schema' => draft7, '$id' => '#name', 'type' => 'integer' })).to be_empty
      expect(validator.check_schema({ '$id' => 5 })).to contain_exactly(a_string_matching(/\$id/))
    end

    it 'refuses duplicate names in required and dependentRequired' do
      expect(validator.check_schema({ 'required' => %w[a a] })).to contain_exactly(a_string_matching(/required/))
      expect(validator.check_schema({ 'dependentRequired' => { 'a' => %w[b b] } }))
        .to contain_exactly(a_string_matching(/dependentRequired/))
    end
  end

  describe 'references written as absolute URIs into the bundled document' do
    def bool_bag(spelling)
      bools = {}
      props = {}
      1100.times do |i|
        bools["b#{i}"] = true
        props["p#{i}"] = { '$ref' => format(spelling, i) }
      end
      { '$id' => 'urn:root', 'x-bools' => bools, 'properties' => props }
    end

    it 'charges a boolean target reached through an absolute reference' do
      # The same targets, spelled two ways: the accounting must not depend on
      # which spelling the peer chose.
      expect(validator.check_schema(bool_bag('#/x-bools/b%d')))
        .to contain_exactly(a_string_matching(/more than #{validator::MAX_SUBSCHEMAS} subschemas/))
      expect(validator.check_schema(bool_bag('urn:root#/x-bools/b%d')))
        .to contain_exactly(a_string_matching(/more than #{validator::MAX_SUBSCHEMAS} subschemas/))
    end

    it 'tells two bundled resources apart by the query of their URIs' do
      schema = { '$id' => 'urn:x',
                 'properties' => { 'a' => { '$ref' => 'https://example.com/s?v=1' },
                                   'b' => { '$ref' => 'https://example.com/s?v=2' } },
                 '$defs' => { 'one' => { '$id' => 'https://example.com/s?v=1', 'type' => 'string' },
                              'two' => { '$id' => 'https://example.com/s?v=2', 'type' => 'integer' } } }

      # Dropping the query would merge the two resources into one URI, so
      # neither reference could name the resource its author wrote.
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 'x', 'b' => 1 }, schema)).to be_empty
      expect(validator.validate({ 'a' => 1, 'b' => 'x' }, schema))
        .to contain_exactly(a_string_matching(%r{#/a: expected type string}),
                            a_string_matching(%r{#/b: expected type integer}))
    end

    it 'resolves a query-only reference against the base in force' do
      # RFC 3986 Section 5.2.2: an empty path keeps the base's, and the
      # reference's own query replaces it — which is the only thing telling
      # this resource from the document root.
      schema = { '$id' => 'https://example.com/root', 'type' => 'object',
                 'properties' => { 'a' => { '$ref' => '?v=2' } },
                 '$defs' => { 'two' => { '$id' => '?v=2', 'type' => 'integer' } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 'x' }, schema))
        .to contain_exactly(a_string_matching(/expected type integer/))
      expect(validator.validate({ 'a' => 1 }, schema)).to be_empty
    end

    it 'removes the dot segments of a relative reference' do
      schema = { '$id' => 'https://example.com/a/b/root',
                 'properties' => { 'a' => { '$ref' => '../c/s' } },
                 '$defs' => { 's' => { '$id' => 'https://example.com/a/c/s', 'type' => 'string' } } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'still resolves an absolute reference to a schema in the bundle' do
      schema = { '$id' => 'urn:root', 'properties' => { 'a' => { '$ref' => 'urn:root#/$defs/s' } },
                 '$defs' => { 's' => { 'type' => 'string' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate({ 'a' => 1 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end
  end

  describe 'an output schema whose dialect this client does not implement' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:mock_server) { instance_double(MCPClient::ServerBase, name: 'server1') }
    let(:output_schema) { { '$schema' => 'urn:unknown', 'type' => 'object' } }
    let(:tool) do
      MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                          output_schema: output_schema, server: mock_server)
    end

    def client_with(mode)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(mock_server)
      allow(mock_server).to receive(:on_notification)
      allow(mock_server).to receive(:list_tools).and_return([tool])
      allow(mock_server).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    # MCP 2026-07-28 basic "Implementation Requirements": a client MUST
    # return an error saying the dialect is not supported. That is not a
    # structured-content mismatch the host may choose to only log — the
    # client cannot read the schema at all — so it is raised in both modes,
    # exactly as an unsupported input dialect is.
    it 'raises in the default mode as well as in :strict' do
      expect { client_with(:warn).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown.*not supported/m)
      expect { client_with(:strict).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown.*not supported/m)
    end

    it 'still only logs an output schema that is unusable for another reason' do
      allow(tool).to receive(:output_schema).and_return({ '$ref' => 'https://example.com/x' })
      result = client_with(:warn).call_tool('t', {})

      expect(result).to eq({ 'content' => [], 'structuredContent' => {} })
      expect(log_output.string).to include('external $ref')
    end
  end

  describe 'schema checks across tools and entry points' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }

    def stub_server(name, tools)
      srv = instance_double(MCPClient::ServerBase, name: name)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return(tools)
      allow(srv).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => {} })
      allow(srv).to receive(:call_tool_streaming) do |*|
        Enumerator.new { |y| y << { 'content' => [], 'structuredContent' => {} } }
      end
      srv
    end

    def client_over(servers, **opts)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(*servers)
      MCPClient::Client.new(mcp_server_configs: Array.new(servers.length) { { type: 'stdio', command: 'test' } },
                            logger: logger, **opts)
    end

    it 'checks two servers exposing the same tool name independently' do
      good = stub_server('good', [])
      bad = stub_server('bad', [])
      allow(good).to receive(:list_tools).and_return(
        [MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' }, server: good)]
      )
      allow(bad).to receive(:list_tools).and_return(
        [MCPClient::Tool.new(name: 't', description: 'd',
                             schema: { '$schema' => 'urn:unknown', 'type' => 'object' }, server: bad)]
      )
      client = client_over([good, bad])

      expect(client.call_tool('t', {}, server: 'good')).to eq({ 'content' => [], 'structuredContent' => {} })
      expect { client.call_tool('t', {}, server: 'bad') }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown/)
      # And the first server's memo is untouched by the second's verdict.
      expect(client.call_tool('t', {}, server: 'good')).to eq({ 'content' => [], 'structuredContent' => {} })
    end

    it 'refuses an unsupported input dialect at the streaming entry point too' do
      srv = stub_server('s', [])
      allow(srv).to receive(:list_tools).and_return(
        [MCPClient::Tool.new(name: 't', description: 'd',
                             schema: { '$schema' => 'urn:unknown', 'type' => 'object' }, server: srv)]
      )
      client = client_over([srv])

      expect { client.call_tool_streaming('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown/)
      expect(srv).not_to have_received(:call_tool_streaming)
    end

    # A boolean or null outputSchema is a declared schema, so a result must
    # be validated against it — and the copies the client cache hands out
    # must carry that as the parsed definition did.
    [[false, /schema false accepts no value/], [nil, /must be an object or a boolean/]].each do |schema, message|
      it "validates a result against a parsed #{schema.inspect} outputSchema" do
        srv = stub_server('s', [])
        parsed = MCPClient::Tool.from_json({ 'name' => 't', 'inputSchema' => { 'type' => 'object' },
                                             'outputSchema' => schema }, server: srv)
        allow(srv).to receive(:list_tools).and_return([parsed])
        client = client_over([srv], validate_structured_content: :strict)

        expect(client.list_tools.first.structured_output?).to be true
        expect { client.call_tool('t', {}) }.to raise_error(MCPClient::Errors::ValidationError, message)
      end
    end
  end

  describe 'through the wire' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    def modern_client(mode: :strict)
      MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
        validate_structured_content: mode
      )
    end

    # The transport's HeaderMismatch recovery re-derives the call's
    # Mcp-Param-* headers from a refreshed tools/list, so the attempt that is
    # answered may have gone out under a definition this client never
    # resolved -- and the dialect check must cover that one too.
    it 'refuses a call answered under a refreshed input schema of an unsupported dialect' do
      listed = { 'name' => 'execute_sql',
                 'inputSchema' => { 'type' => 'object',
                                    'properties' => { 'region' => { 'type' => 'string',
                                                                    'x-mcp-header' => 'Region' } } } }
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'],
                        { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                          'capabilities' => { 'tools' => {} } })
        when 'tools/list' then json_response(body['id'], { 'tools' => [listed] })
        when 'tools/call'
          next json_response(body['id'], { 'content' => [] }) if request.headers['Mcp-Param-Zone']

          listed = { 'name' => 'execute_sql',
                     'inputSchema' => { '$schema' => 'urn:unknown-dialect', 'type' => 'object',
                                        'properties' => { 'region' => { 'type' => 'string',
                                                                        'x-mcp-header' => 'Zone' } } } }
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_020, 'message' => 'Mcp-Param-Zone missing' }) }
        end
      end
      client = modern_client

      expect { client.call_tool('execute_sql', { 'region' => 'eu' }) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown-dialect.*not supported/m)
      client.cleanup
    end

    # MCP 2025-11-25 server/tools: structured content is an object there, and
    # an outputSchema describes one. The widening to "any JSON value" is a
    # 2026-07-28 rule and does not reach back to a session negotiated legacy.
    it 'still treats a null structuredContent as missing on a legacy session' do
      tool = { 'name' => 'execute_sql', 'inputSchema' => { 'type' => 'object' },
               'outputSchema' => { 'type' => 'null' } }
      stub_request(:get, url).to_return(status: 405, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                                      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
        when 'notifications/initialized' then { status: 202, body: '' }
        when 'tools/list' then json_response(body['id'], { 'tools' => [tool] })
        when 'tools/call' then json_response(body['id'], { 'content' => [], 'structuredContent' => nil })
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0,
                                                              protocol: :legacy)],
        validate_structured_content: :strict
      )

      expect { client.call_tool('execute_sql', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /carries no structuredContent/)
      client.cleanup
    end
  end

  describe 'a leaf deep under a chain of same-instance applications' do
    it 'reports it, and reports a negation of it, through the trampoline' do
      # Twenty mixins applied to each value, so every instance level is
      # reached through twenty same-instance applications.
      defs = { 'leaf' => { 'type' => 'object', 'properties' => { 'next' => { '$ref' => '#/$defs/n0' } },
                           'additionalProperties' => { 'type' => 'integer' } } }
      20.times do |i|
        defs["n#{i}"] = { '$ref' => i + 1 < 20 ? "#/$defs/n#{i + 1}" : '#/$defs/leaf' }
      end
      schema = { '$ref' => '#/$defs/n0', '$defs' => defs }
      deep = (1..30).reduce({ 'v' => 1 }) { |inner, _| { 'next' => inner } }
      bad = (1..30).reduce({ 'v' => 'x' }) { |inner, _| { 'next' => inner } }

      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate(deep, schema)).to be_empty
      expect(validator.validate(bad, schema)).to contain_exactly(a_string_matching(/expected type integer/))
      # The same descent inside a negation: the leaf decides it.
      negated = { 'not' => { '$ref' => '#/$defs/n0' }, '$defs' => defs }
      expect(validator.validate(bad, negated)).to be_empty
      expect(validator.validate(deep, negated)).to contain_exactly(a_string_matching(/not/))
    end
  end

  describe 'ECMAScript pattern semantics' do
    # JSON Schema 2020-12 Core Section 4.3: a `pattern` is an ECMA-262
    # regular expression, where `^` and `$` match only at the ends of the
    # subject. Ruby's match at every line boundary, so a value carrying a
    # newline satisfied a pattern ECMAScript rejects — and, through `not`,
    # was rejected although ECMAScript accepts it.
    it 'anchors a pattern to the whole string, not to each line' do
      expect(validator.validate("a\nb", { 'pattern' => '^a$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate('a', { 'pattern' => '^a$' })).to be_empty
      expect(validator.validate("a\nb", { 'not' => { 'pattern' => '^a$' } })).to be_empty
      # An anchor inside a character class or escaped is a literal.
      expect(validator.validate('a^b$c', { 'pattern' => '[$^]' })).to be_empty
      expect(validator.validate('a$b', { 'pattern' => '\\$' })).to be_empty
      expect(validator.validate('ab', { 'pattern' => '[^x]b' })).to be_empty
    end

    it 'anchors a property-name pattern the same way' do
      schema = { 'patternProperties' => { '^a$' => { 'type' => 'integer' } }, 'additionalProperties' => false }
      expect(validator.validate({ 'a' => 1 }, schema)).to be_empty
      expect(validator.validate({ "a\nb" => 1 }, schema)).to contain_exactly(a_string_matching(/not allowed/))
    end

    it 'matches non-ASCII text as written' do
      expect(validator.validate('héllo', { 'pattern' => '^héllo$' })).to be_empty
      expect(validator.validate("héllo\nx", { 'pattern' => '^héllo$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
    end
  end

  describe 'the dynamic references' do
    it 'evaluates them, so one decides a non-monotonic composition like any other' do
      # The binding is the outermost resource of the dynamic scope declaring
      # the anchor; a resource the instance never entered is not in it.
      schema = { '$ref' => 'https://example.com/a',
                 '$defs' => { 'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node',
                                       'type' => 'object', 'properties' => { 'v' => { '$dynamicRef' => '#node' } } },
                              'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node',
                                       'type' => 'string' } } }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.unsupported_keywords(schema)).to be_empty
      expect(validator.validate({ 'v' => 1 }, schema)).not_to be_empty
      expect(validator.validate({ 'v' => 1 }, { 'not' => schema })).to be_empty
    end

    it 'refuses a dynamic reference that is not a string' do
      expect(validator.check_schema({ '$dynamicRef' => 5 }))
        .to contain_exactly(a_string_matching(/\$dynamicRef must be a string/))
      expect(validator.check_schema({ '$schema' => draft2019, '$recursiveRef' => [] }))
        .to contain_exactly(a_string_matching(/\$recursiveRef must be a string/))
      # A dialect that does not define the keyword has nothing to refuse.
      expect(validator.check_schema({ '$schema' => draft7, '$dynamicRef' => 5 })).to be_empty
    end
  end

  describe 'the partial-coverage report' do
    it 'keeps only the keywords whose verdict this validator still cannot reach' do
      supported = { 'multipleOf' => 2, 'uniqueItems' => true, 'contains' => true, 'minContains' => 1,
                    'maxContains' => 2, 'minProperties' => 1, 'maxProperties' => 2,
                    'additionalProperties' => false, 'patternProperties' => {}, 'propertyNames' => true,
                    'dependentRequired' => {}, 'dependentSchemas' => {},
                    'allOf' => [true], 'unevaluatedProperties' => false, 'unevaluatedItems' => false }
      expect(validator.unsupported_keywords(supported)).to be_empty
      # A dynamic reference is evaluated and reports nothing; `format` and
      # `contentSchema`, which this validator only ever annotates with, are
      # what is left.
      partial = { 'format' => 'email', 'contentSchema' => { 'type' => 'object' },
                  '$ref' => 'https://example.com/a',
                  '$defs' => { 'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node',
                                        'properties' => { 'v' => { '$dynamicRef' => '#node' } } },
                               'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node' } } }
      expect(validator.unsupported_keywords(partial)).to contain_exactly('contentSchema', 'format')
    end
  end
end

# --- round29 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, twenty-ninth round.
#
# Round 28 evaluated the standard assertions; this round fixes the verdicts
# some of them reached. `uniqueItems` canonicalized an object into an array
# of member pairs, so `[{}, []]` — two distinct JSON values — read as equal
# and :strict rejected a conforming result. A `pattern` was compiled as a
# Ruby expression with only its anchors rewritten, so `\A` meant
# start-of-string where ECMA-262 means a literal `A`, `.` matched a carriage
# return ECMA-262 excludes, `\s` missed the Unicode spaces it includes and an
# empty character class was not an expression at all (so the pattern was
# skipped, and every string passed it). The wide instance loops spent
# unbounded work before the deadline was consulted. The annotation-driven
# keywords are now evaluated wherever a node's own applicators produce every
# annotation they read.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 29' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:draft2019) { 'https://json-schema.org/draft/2019-09/schema' }

  describe 'uniqueItems compares JSON values, not their Ruby encodings' do
    it 'never reads an object as equal to an array' do
      # JSON Schema 2020-12 Validation Section 6.4.3 equality is JSON's: an
      # object is never equal to an array, whatever members either holds.
      expect(validator.validate([{}, []], { 'uniqueItems' => true })).to be_empty
      expect(validator.validate([{ 'a' => 1 }, [['a', 1]]], { 'uniqueItems' => true })).to be_empty
      expect(validator.validate([{ 'a' => 1 }, { 'a' => 1 }], { 'uniqueItems' => true }))
        .to contain_exactly(a_string_matching(/unique/))
      expect(validator.validate([[1, 2], [1, 2]], { 'uniqueItems' => true }))
        .to contain_exactly(a_string_matching(/unique/))
      expect(validator.validate([[1, 2], [2, 1]], { 'uniqueItems' => true })).to be_empty
    end

    it 'tells a string apart from the number and the boolean written like it' do
      expect(validator.validate(['1', 1], { 'uniqueItems' => true })).to be_empty
      expect(validator.validate([true, 1], { 'uniqueItems' => true })).to be_empty
      expect(validator.validate([nil, false], { 'uniqueItems' => true })).to be_empty
      expect(validator.validate([{ 'a' => nil }, {}], { 'uniqueItems' => true })).to be_empty
    end

    it 'reads the same verdict through a negation' do
      # The mistake flipped here: `not` ACCEPTED a conforming array.
      expect(validator.validate([{}, []], { 'not' => { 'uniqueItems' => true } }))
        .to contain_exactly(a_string_matching(/not/))
      expect(validator.validate([{}, {}], { 'not' => { 'uniqueItems' => true } })).to be_empty
    end
  end

  describe 'the validation budget inside the wide instance loops' do
    # A schema keyword's cost is bounded by the schema; a loop over the
    # instance is bounded by what the peer sent. Walking every property of a
    # 100k-member object (or canonicalizing a deep one for uniqueItems)
    # without consulting the deadline let a peer hold the calling thread well
    # past the budget the client advertises, and — under `not` — report the
    # work as a pass.
    def with_clock(step)
      now = 0.0
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now += step }
      yield
    end

    it 'aborts a wide additionalProperties sweep instead of running it out' do
      data = (1..500).to_h { |i| ["p#{i}", i] }
      errors = with_clock(0.05) { validator.validate(data, { 'not' => { 'additionalProperties' => false } }) }
      expect(errors).to contain_exactly(a_string_matching(/aborted/))
    end

    it 'aborts a wide tuple tail instead of naming every item past it' do
      # Inside `not` the tail's errors are a verdict, so MAX_ERRORS never
      # stops the sweep: only the deadline can.
      data = Array.new(500, 'x')
      tail = { 'items' => [{ 'type' => 'string' }], 'additionalItems' => false }
      schema = { '$schema' => draft2019, 'not' => tail }
      errors = with_clock(0.05) { validator.validate(data, schema) }
      expect(errors).to contain_exactly(a_string_matching(/aborted/))
    end

    it 'aborts canonicalizing a deep instance for uniqueItems' do
      # Three items, so the per-item checkpoint is never reached: the cost is
      # in canonicalizing what each of them holds.
      data = Array.new(3) { |i| { 'k' => Array.new(50) { |j| { 'n' => (i * 50) + j } } } }
      errors = with_clock(0.05) { validator.validate(data, { 'uniqueItems' => true }) }
      expect(errors).to contain_exactly(a_string_matching(/aborted/))
    end
  end

  describe 'ECMA-262 pattern semantics beyond the anchors' do
    # JSON Schema 2020-12 Core Section 4.3: a `pattern` is an ECMA-262
    # regular expression. Round 28 rewrote `^` and `$`; everything else was
    # still read as Ruby, and the two dialects disagree about more than the
    # anchors — in both directions, so a pattern accepted the wrong strings
    # and (through `not` or `additionalProperties: false`) rejected the right
    # ones.
    it 'reads a Ruby-only escape as the literal character ECMA-262 makes it' do
      # `\A` anchors in Ruby; in ECMA-262 it is an identity escape for "A".
      expect(validator.validate('xy', { 'pattern' => '\\Ax' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate('Ax', { 'pattern' => '\\Ax' })).to be_empty
      # The same for the other Ruby anchors and escapes ECMA-262 does not define.
      expect(validator.validate('xz', { 'pattern' => 'x\\z' })).to be_empty
      expect(validator.validate('x', { 'pattern' => 'x\\z' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate('hG', { 'pattern' => '\\h\\G' })).to be_empty
      # The escapes ECMA-262 does define keep their meaning.
      expect(validator.validate('a1 ', { 'pattern' => '^\\w\\d\\s$' })).to be_empty
      expect(validator.validate('a\\A', { 'pattern' => 'a\\\\A' })).to be_empty
    end

    it 'excludes the line terminators ECMA-262 excludes from a dot' do
      expect(validator.validate("\r", { 'pattern' => '^.$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate("\u2028", { 'pattern' => '^.$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate('x', { 'pattern' => '^.$' })).to be_empty
      # An escaped dot, and a dot inside a character class, are literals.
      expect(validator.validate('.', { 'pattern' => '^\\.$' })).to be_empty
      expect(validator.validate('x', { 'pattern' => '^\\.$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate('.', { 'pattern' => '^[.]$' })).to be_empty
    end

    it 'counts the Unicode spaces ECMA-262 counts as whitespace' do
      expect(validator.validate("\u00a0", { 'pattern' => '^\\s$' })).to be_empty
      expect(validator.validate("\u3000", { 'pattern' => '^[\\s]$' })).to be_empty
      expect(validator.validate("\u00a0", { 'pattern' => '^\\S$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate('x', { 'pattern' => '^[a-z\\S]$' })).to be_empty
      expect(validator.validate(' ', { 'pattern' => '^\\s$' })).to be_empty
    end

    it 'matches nothing with an empty character class rather than skipping the keyword' do
      # Ruby cannot compile `[]` at all, so the pattern was dropped and every
      # string satisfied it; in ECMA-262 an empty class matches no character.
      expect(validator.validate('x', { 'pattern' => '[]' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate('', { 'pattern' => '[]*' })).to be_empty
      # `[^]` is its complement: any character at all, line terminators included.
      expect(validator.validate("\n", { 'pattern' => '^[^]$' })).to be_empty
    end

    it 'leaves a character class the peer wrote alone' do
      expect(validator.validate('b', { 'pattern' => '^[a-c]$' })).to be_empty
      expect(validator.validate('d', { 'pattern' => '^[a-c]$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate(']', { 'pattern' => '^[\\]]$' })).to be_empty
      expect(validator.validate('-', { 'pattern' => '^[-a]$' })).to be_empty
      expect(validator.validate('^', { 'pattern' => '^[x^]$' })).to be_empty
      expect(validator.validate('aa', { 'pattern' => '^(a)\\1$' })).to be_empty
    end

    it 'reads a property-name pattern in the same dialect' do
      schema = { 'patternProperties' => { '\\Ax' => { 'type' => 'string' } }, 'additionalProperties' => false }
      # "xy" is not a member in ECMA-262: `\Ax` needs a literal "Ax".
      expect(validator.validate({ 'xy' => 'ok' }, schema)).to contain_exactly(a_string_matching(/not allowed/))
      expect(validator.validate({ 'Axe' => 'ok' }, schema)).to be_empty
      expect(validator.validate({ 'Axe' => 3 }, schema)).to contain_exactly(a_string_matching(/expected type string/))
    end

    it 'reads the same dialect through a negation' do
      expect(validator.validate('xy', { 'not' => { 'pattern' => '\\Ax' } })).to be_empty
      expect(validator.validate('Ax', { 'not' => { 'pattern' => '\\Ax' } }))
        .to contain_exactly(a_string_matching(/not/))
    end
  end

  describe 'the shape of the standard keywords that only annotate' do
    # JSON Schema 2020-12 Validation Section 9 gives each metadata keyword a
    # type. A schema that writes one of them wrong is malformed, exactly as a
    # malformed assertion is: the preflight said such a document was usable,
    # so :strict checked results against a schema no validator could read.
    it 'refuses a metadata keyword whose value is not what its type says' do
      expect(validator.check_schema({ 'readOnly' => 'no' })).to contain_exactly(a_string_matching(/readOnly/))
      expect(validator.check_schema({ 'writeOnly' => 1 })).to contain_exactly(a_string_matching(/writeOnly/))
      expect(validator.check_schema({ 'title' => 5 })).to contain_exactly(a_string_matching(/title/))
      expect(validator.check_schema({ 'description' => [] })).to contain_exactly(a_string_matching(/description/))
      expect(validator.check_schema({ '$comment' => 5 })).to contain_exactly(a_string_matching(/\$comment/))
      expect(validator.check_schema({ 'format' => 3 })).to contain_exactly(a_string_matching(/format/))
      expect(validator.check_schema({ 'contentMediaType' => 3 }))
        .to contain_exactly(a_string_matching(/contentMediaType/))
      expect(validator.check_schema({ 'contentEncoding' => {} }))
        .to contain_exactly(a_string_matching(/contentEncoding/))
      expect(validator.check_schema({ 'examples' => { 'a' => 1 } })).to contain_exactly(a_string_matching(/examples/))
      expect(validator.check_schema({ 'deprecated' => 'yes' })).to contain_exactly(a_string_matching(/deprecated/))
    end

    it 'accepts the same keywords written as their type' do
      well_formed = { 'title' => 't', 'description' => 'd', '$comment' => 'c', 'format' => 'email',
                      'contentMediaType' => 'application/json', 'contentEncoding' => 'base64',
                      'readOnly' => true, 'writeOnly' => false, 'deprecated' => true, 'examples' => [1],
                      'default' => { 'anything' => true } }
      expect(validator.check_schema(well_formed)).to be_empty
    end

    it 'leaves a keyword the dialect does not define alone' do
      # `deprecated` arrived in 2019-09: under draft-07 it is an unknown
      # keyword, and an unknown keyword is never malformed.
      expect(validator.check_schema({ '$schema' => draft7, 'deprecated' => 'yes' })).to be_empty
      expect(validator.check_schema({ '$schema' => draft2019, 'deprecated' => 'yes' }))
        .to contain_exactly(a_string_matching(/deprecated/))
    end

    it 'refuses a malformed metadata keyword nested in a subschema' do
      expect(validator.check_schema({ 'properties' => { 'a' => { 'title' => 5 } } }))
        .to contain_exactly(a_string_matching(/title/))
      # And an unusable schema is a violation, never a permissive pass.
      expect(validator.validate({ 'a' => 1 }, { 'properties' => { 'a' => { 'title' => 5 } } }))
        .to contain_exactly(a_string_matching(/title/))
    end
  end

  describe 'unevaluatedProperties and unevaluatedItems where the annotations are local' do
    # These two are decided by the annotations a whole composition produces,
    # which is why they were left out. But where a node carries no in-place
    # applicator, every annotation they read is produced by that node's own
    # applicators — and there they are simply `additionalProperties` /
    # `additionalItems` over what the node did not name. Leaving even those
    # unevaluated made :strict accept instances a 2020-12 validator rejects.
    it 'rejects an item past the tuple the node itself evaluates' do
      schema = { 'prefixItems' => [{ 'type' => 'number' }], 'unevaluatedItems' => false }
      expect(validator.validate([1, 'x'], schema)).to contain_exactly(a_string_matching(/unevaluatedItems/))
      expect(validator.validate([1], schema)).to be_empty
      expect(validator.validate([], schema)).to be_empty
      typed = { 'prefixItems' => [{ 'type' => 'number' }], 'unevaluatedItems' => { 'type' => 'string' } }
      expect(validator.validate([1, 'x'], typed)).to be_empty
      expect(validator.validate([1, 2], typed)).to contain_exactly(a_string_matching(/expected type string/))
      # An `items` schema evaluates every item, so nothing is left over.
      expect(validator.validate([1, 'x'], { 'items' => true, 'unevaluatedItems' => false })).to be_empty
    end

    it 'rejects a property the node itself leaves unevaluated' do
      expect(validator.validate({ 'extra' => 1 }, { 'unevaluatedProperties' => false }))
        .to contain_exactly(a_string_matching(/unevaluatedProperties/))
      expect(validator.validate({}, { 'unevaluatedProperties' => false })).to be_empty
      covered = { 'properties' => { 'a' => true }, 'patternProperties' => { '^x' => true },
                  'unevaluatedProperties' => false }
      expect(validator.validate({ 'a' => 1, 'xy' => 2 }, covered)).to be_empty
      expect(validator.validate({ 'a' => 1, 'zz' => 2 }, covered))
        .to contain_exactly(a_string_matching(/unevaluatedProperties/))
      typed = { 'properties' => { 'a' => true }, 'unevaluatedProperties' => { 'type' => 'string' } }
      expect(validator.validate({ 'a' => 1, 'b' => 2 }, typed))
        .to contain_exactly(a_string_matching(/expected type string/))
      # additionalProperties already evaluates every member the node did not name.
      expect(validator.validate({ 'b' => 2 }, { 'additionalProperties' => true,
                                                'unevaluatedProperties' => false })).to be_empty
    end

    it 'settles a negation the keyword alone decides' do
      expect(validator.validate({ 'extra' => 1 }, { 'not' => { 'unevaluatedProperties' => false } })).to be_empty
      expect(validator.validate({}, { 'not' => { 'unevaluatedProperties' => false } }))
        .to contain_exactly(a_string_matching(/not/))
    end

    it 'stops reporting partial coverage for a node it now evaluates' do
      expect(validator.unsupported_keywords({ 'unevaluatedProperties' => false })).to be_empty
      expect(validator.unsupported_keywords({ 'prefixItems' => [true], 'unevaluatedItems' => false })).to be_empty
    end

    it 'evaluates the keyword where a composition produces the annotations' do
      # An in-place applicator's annotations are collected (round 31), so the
      # keyword is evaluated there too — and decides a `not` like any other.
      composed = { 'allOf' => [{ 'properties' => { 'a' => true } }], 'unevaluatedProperties' => false }
      expect(validator.unsupported_keywords(composed)).to be_empty
      expect(validator.validate({ 'a' => 1 }, composed)).to be_empty
      expect(validator.validate({ 'a' => 1, 'b' => 2 }, composed)).to contain_exactly(a_string_matching(/'b'/))
      expect(validator.validate({ 'a' => 1 }, { 'not' => composed })).not_to be_empty

      referenced = { '$ref' => '#/$defs/p', 'unevaluatedProperties' => false,
                     '$defs' => { 'p' => { 'properties' => { 'a' => true } } } }
      expect(validator.unsupported_keywords(referenced)).to be_empty
      expect(validator.validate({ 'a' => 1 }, referenced)).to be_empty
      expect(validator.validate({ 'a' => 1, 'b' => 2 }, referenced)).not_to be_empty
    end

    it 'evaluates unevaluatedItems beside contains, whose matches annotate' do
      schema = { 'contains' => { 'type' => 'string' }, 'unevaluatedItems' => false }
      expect(validator.unsupported_keywords(schema)).to be_empty
      expect(validator.validate(['x'], schema)).to be_empty
      expect(validator.validate(['x', 1], schema)).to contain_exactly(a_string_matching(/item 1/))
    end

    it 'leaves the keyword alone in a dialect that does not define it' do
      legacy = { '$schema' => draft7, 'unevaluatedProperties' => false }
      expect(validator.unsupported_keywords(legacy)).to be_empty
      expect(validator.validate({ 'a' => 1 }, legacy)).to be_empty
      modern = { '$schema' => draft2019, 'unevaluatedProperties' => false }
      expect(validator.validate({ 'a' => 1 }, modern))
        .to contain_exactly(a_string_matching(/unevaluatedProperties/))
    end

    it 'binds the dynamic reference by the path the evaluation took' do
      # A `$dynamicRef` binds to the outermost resource of the dynamic scope
      # declaring its anchor — the resources the evaluation entered. A
      # resource it never entered declares nothing for it, so the reference
      # is evaluated and decides its composition like any other.
      schema = { '$ref' => 'https://example.com/a',
                 '$defs' => { 'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node',
                                       'type' => 'object', 'properties' => { 'v' => { '$dynamicRef' => '#node' } } },
                              'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node',
                                       'type' => 'string' } } }
      expect(validator.unsupported_keywords(schema)).to be_empty
      expect(validator.validate({ 'v' => 1 }, schema)).not_to be_empty
      expect(validator.validate({ 'v' => {} }, schema)).to be_empty
      expect(validator.validate({ 'v' => 1 }, { 'not' => schema })).to be_empty
    end
  end

  describe 'the client entry points a result reaches' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:chunk) { { 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} } }

    def stub_server(output_schema, chunk, input_schema: { 'type' => 'object' })
      srv = instance_double(MCPClient::ServerBase, name: 's')
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: input_schema,
                                 output_schema: output_schema, server: srv)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return([tool])
      allow(srv).to receive(:call_tool).and_return(chunk)
      allow(srv).to receive(:call_tool_streaming) { |*| Enumerator.new { |y| y << chunk } }
      srv
    end

    def client_over(srv, mode)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    # The tools spec's "Clients SHOULD validate structured results against
    # this schema" is about a result, not about the method that fetched it:
    # a stream handed the chunk back unchecked, so the very payload
    # #call_tool refuses came through #call_tool_streaming silently — the
    # unsupported output dialect this PR must refuse included.
    it 'validates an ordinary streamed result against the output schema' do
      srv = stub_server({ 'type' => 'object', 'required' => ['n'] }, chunk)
      client = client_over(srv, :strict)

      expect { client.call_tool_streaming('t', {}).to_a }
        .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
    end

    it 'refuses an unsupported output dialect on the streaming path, in both modes' do
      %i[warn strict].each do |mode|
        srv = stub_server({ '$schema' => 'urn:unknown', 'type' => 'object' }, chunk)
        expect { client_over(srv, mode).call_tool_streaming('t', {}).to_a }
          .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown.*not supported/m)
      end
    end

    it 'reports missing structured content on the streaming path' do
      srv = stub_server({ 'type' => 'object' }, { 'resultType' => 'complete', 'content' => [] })
      client = client_over(srv, :strict)

      expect { client.call_tool_streaming('t', {}).to_a }
        .to raise_error(MCPClient::Errors::ValidationError, /carries no structuredContent/)
    end

    it 'hands a conforming streamed result through unchanged' do
      srv = stub_server({ 'type' => 'object', 'required' => ['n'] },
                        { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'n' => 1 } })
      client = client_over(srv, :strict)

      expect(client.call_tool_streaming('t', {}).to_a)
        .to eq([{ 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'n' => 1 } }])
    end

    it 'leaves a chunk that is not a complete result to the host' do
      # A transport may stream progress; only a complete CallToolResult is a
      # result to check against the output schema.
      partial = { 'resultType' => 'io.modelcontextprotocol/partial', 'content' => [] }
      srv = stub_server({ 'type' => 'object', 'required' => ['n'] }, partial)
      client = client_over(srv, :strict)

      expect(client.call_tool_streaming('t', {}).to_a).to eq([partial])
    end

    # The two task-result methods this PR moved onto #validate_called_result!
    # differ from the structured-content check by exactly one thing: they
    # also refuse the input dialect of the definition the answered request
    # went out under (which a HeaderMismatch refresh may have replaced).
    describe 'the results a task delivers' do
      let(:unreadable) do
        MCPClient::Tool.new(name: 't', description: 'd',
                            schema: { '$schema' => 'urn:unknown', 'type' => 'object' },
                            output_schema: { 'type' => 'object' }, server: nil)
      end
      let(:readable) do
        MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                            output_schema: { 'type' => 'object', 'required' => ['n'] }, server: nil)
      end
      let(:client) { client_over(stub_server({ 'type' => 'object' }, chunk), :strict) }

      it 'refuses a synchronous task answer under an unreadable input dialect' do
        expect { client.send(:validated_sync_result, chunk, unreadable) }
          .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown.*not supported/m)
      end

      it 'refuses a delivered task result under an unreadable input dialect' do
        handle = MCPClient::Task.completed_locally(chunk, server: nil).with_called_tool(unreadable)
        expect { client.send(:validated_task_result, handle, chunk) }
          .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown.*not supported/m)
      end

      it 'still checks the structured content of a readable definition' do
        expect { client.send(:validated_sync_result, chunk, readable) }
          .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
        good = { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'n' => 1 } }
        expect(client.send(:validated_sync_result, good, readable)).to eq(good)
      end
    end
  end

  describe 'the era a structuredContent value belongs to, on the wire' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }
    # An open schema: valid in either era, and it accepts any JSON value, so
    # what the client makes of the value is what the example measures.
    let(:tool) { { 'name' => 't', 'inputSchema' => { 'type' => 'object' }, 'outputSchema' => {} } }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    def legacy_session(structured)
      stub_request(:get, url).to_return(status: 405, body: '')
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'initialize'
          json_response(body['id'], { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
                                      'serverInfo' => { 'name' => 'legacy', 'version' => '1' } })
        when 'notifications/initialized' then { status: 202, body: '' }
        when 'tools/list' then json_response(body['id'], { 'tools' => [tool] })
        when 'tools/call' then json_response(body['id'], { 'content' => [], 'structuredContent' => structured })
        end
      end
      MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0,
                                                              protocol: :legacy)],
        validate_structured_content: :strict
      )
    end

    def modern_session(structured)
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'],
                        { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                          'capabilities' => { 'tools' => {} } })
        when 'tools/list' then json_response(body['id'], { 'tools' => [tool] })
        when 'tools/call'
          json_response(body['id'],
                        { 'resultType' => 'complete', 'content' => [], 'structuredContent' => structured })
        end
      end
      MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
        validate_structured_content: :strict
      )
    end

    # MCP 2025-11-25 server/tools types structuredContent as an object. The
    # widening to "any JSON value" is a 2026-07-28 rule, and a session
    # negotiated to the older revision does not get it: an array or a scalar
    # there is no more structured content than a null is.
    [[[1, 2], 'an array'], ['x', 'a string'], [true, 'a boolean'], [42, 'a number']].each do |value, described|
      it "treats #{described} structuredContent as missing on a legacy session" do
        client = legacy_session(value)

        expect { client.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /carries no structuredContent/)
        client.cleanup
      end
    end

    it 'keeps an object structuredContent on a legacy session' do
      client = legacy_session({ 'a' => 1 })

      expect(client.call_tool('t', {}))
        .to eq({ 'content' => [], 'structuredContent' => { 'a' => 1 } })
      client.cleanup
    end

    it 'accepts any JSON value on a 2026-07-28 session' do
      [[1, 2], 'x', true, 42, nil].each do |value|
        client = modern_session(value)

        expect(client.call_tool('t', {}))
          .to eq({ 'resultType' => 'complete', 'content' => [], 'structuredContent' => value })
        client.cleanup
      end
    end
  end

  describe 'the HeaderMismatch retry' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
        headers: { 'Content-Type' => 'application/json' } }
    end

    # MCP 2026-07-28 "Custom Headers from Tool Parameters": a HeaderMismatch
    # means the server rejected the request BEFORE executing it, and the
    # client re-fetches tools/list and retries once. That retry is the send
    # that runs the tool — so if the refreshed inputSchema declares a dialect
    # this client cannot read, refusing only the answer is too late: the tool
    # has already run. The dialect is checked before the retry goes out.
    it 'is not sent under a refreshed input schema of an unsupported dialect' do
      listed = { 'name' => 'execute_sql',
                 'inputSchema' => { 'type' => 'object',
                                    'properties' => { 'region' => { 'type' => 'string',
                                                                    'x-mcp-header' => 'Region' } } } }
      calls = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'],
                        { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                          'capabilities' => { 'tools' => {} } })
        when 'tools/list' then json_response(body['id'], { 'tools' => [listed] })
        when 'tools/call'
          calls << request.headers.slice('Mcp-Param-Region', 'Mcp-Param-Zone')
          next json_response(body['id'], { 'resultType' => 'complete', 'content' => [] }) if
            request.headers['Mcp-Param-Zone']

          listed = { 'name' => 'execute_sql',
                     'inputSchema' => { '$schema' => 'urn:unknown-dialect', 'type' => 'object',
                                        'properties' => { 'region' => { 'type' => 'string',
                                                                        'x-mcp-header' => 'Zone' } } } }
          { status: 400, headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_020, 'message' => 'Mcp-Param-Zone missing' }) }
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
        validate_structured_content: :strict
      )

      expect { client.call_tool('execute_sql', { 'region' => 'eu' }) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown-dialect.*not supported/m)
      # The rejected attempt did not run the tool; the retry would have.
      expect(calls.length).to eq(1)
      client.cleanup
    end
  end

  describe 'the reference resolver, at the shapes a document can write' do
    # RFC 3986 Section 5.2.2 has a branch per reference form, and a schema
    # document may bundle the resources it names (JSON Schema 2020-12 Core
    # Section 9.3.1), so each of those branches decides which bundled
    # resource a `$ref` lands on.
    {
      'a network-path reference' => ['https://example.com/root', '//other.example/s', 'https://other.example/s'],
      'an absolute-path reference' => ['https://example.com/a/root', '/s', 'https://example.com/s'],
      'a same-directory reference' => ['https://example.com/a/root', './s', 'https://example.com/a/s'],
      'a parent-directory reference' => ['https://example.com/a/root', '../s', 'https://example.com/s']
    }.each do |described, (base, ref, id)|
      it "resolves #{described} against the base in force" do
        schema = { '$id' => base, '$ref' => ref, '$defs' => { 's' => { '$id' => id, 'type' => 'integer' } } }

        expect(validator.check_schema(schema)).to be_empty
        expect(validator.validate(1, schema)).to be_empty
        expect(validator.validate('x', schema)).to contain_exactly(a_string_matching(/expected type integer/))
      end
    end

    it 'refuses a pointer that names nothing' do
      # A JSON pointer either resolves to a schema or it resolves to nothing;
      # an index past the end, a negative or a "-" index, and a step through a
      # scalar all name nothing, and none of them is a permissive pass.
      ['#/prefixItems/5', '#/prefixItems/-1', '#/prefixItems/-'].each do |ref|
        expect(validator.check_schema({ 'prefixItems' => [true], '$ref' => ref }))
          .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
      end
      expect(validator.check_schema({ 'title' => 'x', '$ref' => '#/title/a' }))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
      expect(validator.validate(1, { 'prefixItems' => [true], '$ref' => '#/prefixItems/5' }))
        .to contain_exactly(a_string_matching(/unresolvable local \$ref/))
    end

    it 'refuses a reference that is not a string, and a local chain that leaves the document' do
      expect(validator.check_schema({ '$ref' => 5 }))
        .to contain_exactly(a_string_matching(/\$ref must be a string, got integer/))
      chain = { '$ref' => '#/$defs/a',
                '$defs' => { 'a' => { '$ref' => '#/$defs/b' }, 'b' => { '$ref' => 'https://example.com/x' } } }
      expect(validator.check_schema(chain))
        .to contain_exactly(a_string_matching(%r{external \$ref "https://example.com/x"}))
      expect(validator.validate(1, chain)).to contain_exactly(a_string_matching(/external \$ref/))
    end
  end

  describe 'the dialect an output schema declares, through the client' do
    let(:logger) { Logger.new(StringIO.new) }
    let(:srv) { instance_double(MCPClient::ServerBase, name: 's') }

    def client_for(output_schema, structured, mode: :strict)
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                 output_schema: output_schema, server: srv)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return([tool])
      allow(srv).to receive(:call_tool).and_return({ 'content' => [], 'structuredContent' => structured })
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    # The declared dialect travels with the schema: a client that dropped it
    # would read a draft-07 tuple as a 2020-12 `items`, which is not a schema
    # there — so the document would be unusable rather than applied.
    it 'reads an output schema with the grammar its own dialect defines' do
      tuple = { '$schema' => draft7, 'items' => [{ 'type' => 'string' }], 'additionalItems' => false }

      expect { client_for(tuple, %w[a b]).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /additionalItems is false/)
      expect(client_for(tuple, ['a']).call_tool('t', {}))
        .to eq({ 'content' => [], 'structuredContent' => ['a'] })
    end

    it 'refuses an unsupported dialect an embedded output resource declares, in both modes' do
      embedded = { 'type' => 'object',
                   'properties' => { 'a' => { '$id' => 'https://example.com/r', '$schema' => 'urn:unknown' } } }

      %i[warn strict].each do |mode|
        expect { client_for(embedded, {}, mode: mode).call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown.*not supported/m)
      end
    end

    it 'decides on the refreshed output dialect, in both directions' do
      good = { 'type' => 'object' }
      bad = { '$schema' => 'urn:unknown', 'type' => 'object' }
      client = client_for(good, {})
      expect(client.call_tool('t', {})).to eq({ 'content' => [], 'structuredContent' => {} })

      refreshed = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                      output_schema: bad, server: srv)
      allow(srv).to receive(:list_tools).and_return([refreshed])
      client.send(:invalidate_caches_for_notification, srv, 'notifications/tools/list_changed')
      expect { client.call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown/)

      # ... and back: a definition that is readable again is not refused from
      # the memo the unusable one filled in.
      restored = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                     output_schema: good, server: srv)
      allow(srv).to receive(:list_tools).and_return([restored])
      client.send(:invalidate_caches_for_notification, srv, 'notifications/tools/list_changed')
      expect(client.call_tool('t', {})).to eq({ 'content' => [], 'structuredContent' => {} })
    end
  end
end

# --- round30 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, thirtieth round.
#
# The ECMA-262 translation round 29 introduced walked the pattern by index
# — quadratic on a multibyte pattern — without ever consulting the budget,
# so a peer-sized `pattern` held the calling thread past the one-second
# budget the client advertises (and reported a pass). The translation also
# still read Ruby-only syntax as Ruby (inline flags, possessive quantifiers),
# failed a back-reference to a group that did not participate (ECMA-262
# matches the empty string there), and dropped a pattern Ruby could not
# compile at all (a surrogate-pair escape) as if it were absent. Malformed
# core keywords (`$id` that is no URI reference, `$vocabulary`,
# `$recursiveAnchor`) were read as usable schemas. :strict accepted a result
# against a schema whose keywords this validator does not evaluate. The
# HeaderMismatch retry checked one definition's dialect and went out under
# the next list's. And the required-argument check read the root only, not
# what the root's `$ref` or `allOf` apply.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 30' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { 'http://json-schema.org/draft-07/schema#' }
  let(:draft2019) { 'https://json-schema.org/draft/2019-09/schema' }

  def with_clock(step)
    now = 0.0
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now += step }
    yield
  end

  describe 'the validation budget over pattern translation' do
    it 'aborts translating a huge pattern once the budget is out' do
      # Every clock read advances the stubbed clock: a translation that
      # consults the deadline as it goes runs out; one that never looks
      # finishes and, under `not`, reports the unmatched pattern as a pass.
      pattern = 'é' * 8_000
      errors = with_clock(0.05) { validator.validate('x', { 'not' => { 'pattern' => pattern } }) }
      expect(errors).to contain_exactly(a_string_matching(/aborted/))
    end

    it 'refuses a pattern longer than the bound at preflight, in both keywords' do
      long = 'a' * (validator::MAX_PATTERN_LENGTH + 1)
      expect(validator.check_schema({ 'pattern' => long }))
        .to contain_exactly(a_string_matching(/pattern is longer than #{validator::MAX_PATTERN_LENGTH}/))
      expect(validator.check_schema({ 'patternProperties' => { long => true } }))
        .to contain_exactly(a_string_matching(/patternProperties pattern is longer than/))
      expect(validator.validate('x', { 'not' => { 'pattern' => long } }))
        .to contain_exactly(a_string_matching(/pattern is longer than/))
      expect(validator.check_schema({ 'pattern' => 'a' * validator::MAX_PATTERN_LENGTH })).to be_empty
    end

    it 'bounds the length in the translator itself, whoever calls it' do
      expect { validator.ecma_source('a' * (validator::MAX_PATTERN_LENGTH + 1)) }
        .to raise_error(RegexpError, /longer than/)
    end

    it 'answers a pattern of the maximum length well inside the budget' do
      pattern = 'é' * validator::MAX_PATTERN_LENGTH
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      errors = validator.validate('x', { 'not' => { 'pattern' => pattern } })
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
      expect(errors).to be_empty
    end

    it 'answers the reported quadratic case without running the budget out' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      errors = validator.validate('x', { 'not' => { 'pattern' => 'é' * 100_000 } })
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.0
      expect(errors).to contain_exactly(a_string_matching(/pattern is longer than/))
    end
  end

  describe 'ECMA-262 pattern semantics, continued' do
    it 'matches the empty string for a back-reference to a group that did not participate' do
      expect(validator.validate('', { 'pattern' => '^(a)?\\1$' })).to be_empty
      expect(validator.validate('aa', { 'pattern' => '^(a)?\\1$' })).to be_empty
      expect(validator.validate('a', { 'pattern' => '^(a)?\\1$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      # A group that did participate is still held to what it captured.
      expect(validator.validate('a', { 'pattern' => '^(a)\\1$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
      expect(validator.validate('b', { 'pattern' => '^(?<n>a)?b\\k<n>$' })).to be_empty
    end

    it 'reads a back-reference with no such group as the legacy octal escape' do
      expect(validator.check_schema({ 'pattern' => '\\1' })).to be_empty
      expect(validator.validate("\u0001", { 'pattern' => '^\\1$' })).to be_empty
      expect(validator.validate('1', { 'pattern' => '^\\1$' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
    end

    it 'reads a surrogate pair as the character it encodes' do
      pair = { 'pattern' => '^\\uD83D\\uDE00$' }
      expect(validator.check_schema(pair)).to be_empty
      expect(validator.validate("\u{1F600}", pair)).to be_empty
      expect(validator.validate('x', pair)).to contain_exactly(a_string_matching(/does not match pattern/))
      # A lone surrogate is no character any string carries: it matches nothing.
      expect(validator.validate("\u{1F600}", { 'pattern' => '\\uD83D' }))
        .to contain_exactly(a_string_matching(/does not match pattern/))
    end

    it 'refuses the Ruby-only syntax ECMA-262 does not define' do
      ['(?i)ok', 'a++', 'a*+', 'a{2}+', 'a?+', '(?>a)', '(?#c)', "(?'n'a)"].each do |pattern|
        expect(validator.check_schema({ 'pattern' => pattern }))
          .to contain_exactly(a_string_matching(/pattern .* is not an ECMA-262 regular expression/)), pattern
        expect(validator.validate('OK', { 'pattern' => pattern }))
          .to contain_exactly(a_string_matching(/is not an ECMA-262 regular expression/)), pattern
      end
      expect(validator.validate('OK', { 'not' => { 'pattern' => '(?i)ok' } }))
        .to contain_exactly(a_string_matching(/is not an ECMA-262 regular expression/))
      expect(validator.check_schema({ 'patternProperties' => { '(?i)ok' => true } }))
        .to contain_exactly(a_string_matching(/patternProperties pattern .* is not an ECMA-262/))
    end

    it 'keeps the groups and quantifiers both dialects define' do
      ['(?:a)+?', '(?=a)a', '(?!b)a', '(?<=x)a', '(?<!x)a', '(?<n>a)\\k<n>', 'a{1,2}?', '\\+', 'a|b'].each do |pattern|
        expect(validator.check_schema({ 'pattern' => pattern })).to be_empty, pattern
      end
      expect(validator.validate('xaa', { 'pattern' => '(?<=x)a' })).to be_empty
      expect(validator.validate('ok', { 'pattern' => '(?i)ok' }))
        .to contain_exactly(a_string_matching(/is not an ECMA-262/))
    end

    it 'never reads an unreadable pattern as absent' do
      # A pattern that is no expression is a malformed keyword; a schema
      # carrying one is unusable, not a schema without the keyword.
      expect(validator.check_schema({ 'pattern' => '(' }))
        .to contain_exactly(a_string_matching(/pattern .* is not an ECMA-262 regular expression/))
      expect(validator.validate('anything', { 'pattern' => '[' }))
        .to contain_exactly(a_string_matching(/is not an ECMA-262/))
      # The matcher itself reports one too, should a pattern reach it
      # without the preflight.
      expect(validator.validate_pattern('OK', '(?i)ok', '#'))
        .to contain_exactly(a_string_matching(/is not an ECMA-262 regular expression/))
    end
  end

  describe 'malformed core keywords at preflight' do
    it 'refuses an $id that is not a URI reference' do
      expect(validator.check_schema({ '$id' => 'https://example.com/a b', 'type' => 'integer' }))
        .to contain_exactly(a_string_matching(/\$id .* must be a URI reference/))
      expect(validator.validate(1, { '$id' => 'https://example.com/a b', 'type' => 'integer' }))
        .to contain_exactly(a_string_matching(/\$id .* must be a URI reference/))
      expect(validator.check_schema({ '$id' => 'https://example.com/root', 'type' => 'integer' })).to be_empty
      expect(validator.check_schema({ '$id' => 'relative/path', 'type' => 'integer' })).to be_empty
    end

    it 'refuses a $vocabulary that is not an object of booleans keyed by URI' do
      expect(validator.check_schema({ '$vocabulary' => [] }))
        .to contain_exactly(a_string_matching(/\$vocabulary must be an object of booleans/))
      expect(validator.check_schema({ '$vocabulary' => { 'https://example.com/v' => 'yes' } }))
        .to contain_exactly(a_string_matching(/\$vocabulary must be an object of booleans/))
      expect(validator.check_schema({ '$vocabulary' => { 'not a uri' => true } }))
        .to contain_exactly(a_string_matching(/\$vocabulary must be an object of booleans/))
      expect(validator.check_schema({ '$vocabulary' => { 'https://example.com/v' => true } })).to be_empty
      expect(validator.check_schema({ '$schema' => draft2019, '$vocabulary' => { 'https://e.com/v' => false } }))
        .to be_empty
      # draft-07 does not define the keyword: unknown there, never malformed.
      expect(validator.check_schema({ '$schema' => draft7, '$vocabulary' => [] })).to be_empty
    end

    it 'refuses a $recursiveAnchor that is not a boolean' do
      expect(validator.check_schema({ '$schema' => draft2019, '$recursiveAnchor' => 'yes' }))
        .to contain_exactly(a_string_matching(/\$recursiveAnchor must be a boolean/))
      expect(validator.validate(1, { '$schema' => draft2019, '$recursiveAnchor' => 'yes' }))
        .to contain_exactly(a_string_matching(/\$recursiveAnchor must be a boolean/))
      expect(validator.check_schema({ '$schema' => draft2019, '$recursiveAnchor' => true })).to be_empty
      # 2020-12 replaced it with $dynamicAnchor: unknown there.
      expect(validator.check_schema({ '$recursiveAnchor' => 'yes' })).to be_empty
    end
  end

  describe 'the validation budget inside loops that visit no node' do
    # Round 29's examples for these loops still passed with the loop's own
    # deadline check removed: the members they rejected each visited a node,
    # and the visit consults the clock too. These sweeps decide every member
    # without a visit, so only the loop's checkpoint can stop them.
    it 'aborts a wide sweep past an unconstrained tuple tail' do
      data = Array.new(500, 'x')
      schema = { '$schema' => draft2019, 'not' => { 'items' => [{ 'type' => 'string' }] } }
      errors = with_clock(0.05) { validator.validate(data, schema) }
      expect(errors).to contain_exactly(a_string_matching(/aborted/))
    end

    it 'aborts a wide sweep under an empty patternProperties map' do
      data = (1..500).to_h { |i| ["p#{i}", i] }
      errors = with_clock(0.05) { validator.validate(data, { 'not' => { 'patternProperties' => {} } }) }
      expect(errors).to contain_exactly(a_string_matching(/aborted/))
    end
  end

  describe 'JSON equality over deep values' do
    def nested(leaf)
      deep = leaf
      2000.times { deep = [deep] }
      deep
    end

    it 'compares separately allocated deep const and enum values' do
      expect(validator.validate(nested(1), { 'const' => nested(1) })).to be_empty
      expect(validator.validate(nested(2), { 'const' => nested(1) }))
        .to contain_exactly(a_string_matching(/does not equal const/))
      expect(validator.validate(nested(1), { 'enum' => [nested(0), nested(1)] })).to be_empty
      expect(validator.validate(nested(3), { 'enum' => [nested(0), nested(1)] }))
        .to contain_exactly(a_string_matching(/is not in enum/))
    end
  end

  describe 'concurrent validations' do
    it 'keeps each validation to its own schema and dialect' do
      schemas = [
        { 'prefixItems' => [{ 'type' => 'integer' }], 'items' => false },
        { '$schema' => draft7, 'items' => [{ 'type' => 'integer' }], 'additionalItems' => false },
        { 'pattern' => '^\\d+$' }
      ]
      barrier = Queue.new
      threads = Array.new(6) do |i|
        Thread.new do
          barrier.pop
          Array.new(20) do
            i % 3 == 2 ? validator.validate('12', schemas[2]) : validator.validate([1, 2], schemas[i % 3])
          end
        end
      end
      6.times { barrier << true }
      threads.each_with_index do |thread, i|
        thread.value.each do |answer|
          if i % 3 == 2
            expect(answer).to be_empty
          else
            expect(answer).to contain_exactly(a_string_matching(%r{item 1 is not allowed|#/1}))
          end
        end
      end
    end

    it 'aborts one validation without touching another' do
      expired = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
      schema = { 'items' => { 'type' => 'integer' } }
      aborted = Thread.new { validator.validate([1, 'x'], schema, deadline: expired) }
      fine = Thread.new { validator.validate([1, 'x'], schema) }
      expect(aborted.value).to contain_exactly(a_string_matching(/aborted/))
      expect(fine.value).to contain_exactly(a_string_matching(%r{#/1}))
    end
  end

  describe 'the client entry points a result reaches' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:leak) do
      { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'id' => '1', 'secret' => 'leak' } }
    end
    # The canonical 2020-12 closed composition (SEP-2106 made it legal on a
    # tool schema): a full validator rejects `secret`.
    let(:closed) do
      { '$ref' => '#/$defs/base', 'unevaluatedProperties' => false,
        '$defs' => { 'base' => { 'type' => 'object', 'properties' => { 'id' => { 'type' => 'string' } },
                                 'required' => ['id'] } } }
    end

    def stub_server(output_schema, chunk, input_schema: { 'type' => 'object' })
      srv = instance_double(MCPClient::ServerBase, name: 's')
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: input_schema,
                                 output_schema: output_schema, server: srv)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return([tool])
      allow(srv).to receive(:call_tool).and_return(chunk)
      allow(srv).to receive(:call_tool_streaming) { |*| Enumerator.new { |y| y << chunk } }
      srv
    end

    def client_over(srv, mode)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    describe 'a schema this validator cannot fully evaluate' do
      # :strict is a gate: a result the validator cannot show to conform is
      # refused, not returned beside a warning. Since round 31 that is only
      # a dynamic reference the dynamic scope could re-bind; the closed
      # composition is evaluated, and its verdict is what :strict enforces.
      it 'rejects the leaked property in :strict mode, on the closed composition' do
        client = client_over(stub_server(closed, leak), :strict)

        expect { client.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /'secret' is not allowed \(unevaluatedProperties/)
        expect(log_output.string).not_to include('validation is partial')
      end

      it 'rejects it on every call' do
        client = client_over(stub_server(closed, leak), :strict)

        2.times do
          expect { client.call_tool('t', {}) }
            .to raise_error(MCPClient::Errors::ValidationError, /unevaluatedProperties/)
        end
        expect(log_output.string).not_to include('validation is partial')
      end

      it 'checks a result against the schema each dynamic reference binds to' do
        # The dynamic scope decides the binding, and `b` is never entered: the
        # result is checked against `a`, which the leak violates.
        two = { 'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node', 'type' => 'object',
                         'properties' => { 'id' => { '$dynamicRef' => '#node' } } },
                'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node', 'type' => 'string' } }
        recursive = { 'a' => { '$id' => 'https://example.com/ra', '$recursiveAnchor' => true, 'type' => 'object',
                               'properties' => { 'id' => { '$recursiveRef' => '#' } } },
                      'b' => { '$id' => 'https://example.com/rb', '$recursiveAnchor' => true, 'type' => 'string' } }
        # `id` binds to `a` (an object), so the string the result carries is
        # refused for what is wrong with it rather than for a keyword nothing
        # evaluated.
        [{ '$ref' => 'https://example.com/a', 'type' => 'object', '$defs' => two },
         { '$schema' => draft2019, '$ref' => 'https://example.com/ra', 'type' => 'object', '$defs' => recursive }]
          .each do |schema|
          expect { client_over(stub_server(schema, leak), :strict).call_tool('t', {}) }
            .to raise_error(MCPClient::Errors::ValidationError, /expected type object/), schema.inspect
        end
        # The same shape accepts what the binding admits.
        nested = { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'id' => {} } }
        expect(client_over(stub_server({ '$ref' => 'https://example.com/a', 'type' => 'object', '$defs' => two },
                                       nested), :strict).call_tool('t', {})).to eq(nested)
        # A pointer-form `$dynamicRef` and a `$recursiveRef` to a root without
        # `$recursiveAnchor` are the plain references they resolve to.
        [{ '$dynamicRef' => '#/$defs/n', '$defs' => { 'n' => { 'type' => 'object' } } },
         { '$schema' => draft2019, 'type' => 'object',
           'properties' => { 'child' => { '$recursiveRef' => '#' } } }].each do |schema|
          expect(client_over(stub_server(schema, leak), :strict).call_tool('t', {})).to eq(leak), schema.inspect
        end
        composed = { 'allOf' => [{ 'properties' => { 'id' => true } }], 'unevaluatedProperties' => false }
        expect { client_over(stub_server(composed, leak), :strict).call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /'secret' is not allowed/)
        items = { 'contains' => { 'type' => 'string' }, 'unevaluatedItems' => false }
        result = { 'resultType' => 'complete', 'content' => [], 'structuredContent' => ['x', 1] }
        expect { client_over(stub_server(items, result), :strict).call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /unevaluatedItems/)
      end

      it 'lets a keyword that only annotates through in :strict mode' do
        schema = { 'type' => 'object', 'properties' => { 'id' => { 'type' => 'string', 'format' => 'uuid' } } }
        client = client_over(stub_server(schema, leak), :strict)

        expect(client.call_tool('t', {})).to eq(leak)
        expect(log_output.string).to include('validation is partial')
      end

      it 'warns about the leaked property on every call, and returns the result, in :warn mode' do
        client = client_over(stub_server(closed, leak), :warn)

        expect(client.call_tool('t', {})).to eq(leak)
        expect(client.call_tool('t', {})).to eq(leak)
        expect(log_output.string.scan('\'secret\' is not allowed').size).to eq(2)
        expect(log_output.string).not_to include('validation is partial')
      end

      it 'refuses on the streaming path too' do
        client = client_over(stub_server(closed, leak), :strict)

        expect { client.call_tool_streaming('t', {}).to_a }
          .to raise_error(MCPClient::Errors::ValidationError, /unevaluatedProperties/)
      end

      it 'refuses a task-delivered result the same way' do
        client = client_over(stub_server(closed, leak), :strict)
        tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                   output_schema: closed, server: nil)
        handle = MCPClient::Task.completed_locally(leak, server: nil).with_called_tool(tool)

        expect { client.send(:validated_task_result, handle, leak) }
          .to raise_error(MCPClient::Errors::ValidationError, /unevaluatedProperties/)
      end
    end

    describe 'the required arguments an input schema names through its applicators' do
      # Tools spec: "clients SHOULD follow $ref resolution when validating
      # tool inputs". SEP-2106 made `$ref` and `allOf` legal on an
      # inputSchema; a `required` behind them is as required as one at the
      # root, and the call is refused locally rather than sent.
      let(:chunk) { { 'resultType' => 'complete', 'content' => [] } }

      it 'refuses a call missing an argument required behind a root $ref' do
        schema = { '$ref' => '#/$defs/t',
                   '$defs' => { 't' => { 'type' => 'object', 'required' => ['x'],
                                         'properties' => { 'x' => { 'type' => 'string' } } } } }
        srv = stub_server(nil, chunk, input_schema: schema)
        client = client_over(srv, :warn)

        expect { client.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /Missing required parameters: x/)
        expect(srv).not_to have_received(:call_tool)
        expect(client.call_tool('t', { 'x' => 'a' })).to eq(chunk)
      end

      it 'follows allOf, and a default the applied schema declares' do
        schema = { 'type' => 'object',
                   'allOf' => [{ 'required' => %w[x y], 'properties' => { 'y' => { 'default' => 1 } } }] }
        client = client_over(stub_server(nil, chunk, input_schema: schema), :warn)

        expect { client.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /Missing required parameters: x$/)
        expect(client.call_tool('t', { 'x' => 1 })).to eq(chunk)
      end

      it 'leaves a branch it cannot decide to the server' do
        schema = { 'type' => 'object', 'oneOf' => [{ 'required' => ['x'] }, { 'required' => ['y'] }] }
        srv = stub_server(nil, chunk, input_schema: schema)
        client = client_over(srv, :warn)

        expect(client.call_tool('t', {})).to eq(chunk)
        expect(srv).to have_received(:call_tool)
      end
    end
  end

  describe 'the HeaderMismatch retry and the definition it was checked against' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }
    let(:json) { { 'Content-Type' => 'application/json' } }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result), headers: json }
    end

    def listing(header, dialect: nil)
      schema = { 'type' => 'object',
                 'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } }
      schema = { '$schema' => dialect }.merge(schema) if dialect
      # A zero TTL: every access to the list is a fresh fetch.
      { 'tools' => [{ 'name' => 'execute_sql', 'inputSchema' => schema }], 'ttlMs' => 0 }
    end

    # The dialect check before the retry and the header derivation of the
    # retry each looked the definition up, and on a list the server bounds
    # with `ttlMs: 0` each lookup is a fetch: the check passed one
    # definition and the retry went out under the next, whose dialect
    # nothing here could read — the "refuse before sending" the check is
    # for, defeated between two lines. The definition the check read is the
    # one the retry goes out under.
    it 'sends the retry under the definition the dialect check read' do
      calls = []
      lists_after_rejection = 0
      lists_at_retry = nil
      rejected = false
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => { 'tools' => {} } })
        when 'tools/list'
          next json_response(body['id'], listing('Region')) unless rejected

          # The refresh reads a readable definition; any list read after it
          # declares a dialect nothing here can read. The refresh hands its
          # own list to the dialect check and to the retry, so one list is
          # all this sequence may cost — a second would mean the check went
          # back to the transport's cache, and it would bring the dialect
          # that fails the call.
          lists_after_rejection += 1
          readable = lists_after_rejection <= 1
          json_response(body['id'], listing('Zone', dialect: readable ? nil : 'urn:unknown-dialect'))
        when 'tools/call'
          calls << request.headers.slice('Mcp-Param-Region', 'Mcp-Param-Zone')
          if request.headers['Mcp-Param-Zone']
            lists_at_retry = lists_after_rejection
            next json_response(body['id'], { 'resultType' => 'complete', 'content' => [] })
          end
          rejected = true
          { status: 400, headers: json,
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_020, 'message' => 'Mcp-Param-Zone missing' }) }
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
        validate_structured_content: :strict
      )

      expect(client.call_tool('execute_sql', { 'region' => 'eu' }))
        .to eq({ 'resultType' => 'complete', 'content' => [] })
      expect(calls).to eq([{ 'Mcp-Param-Region' => 'eu' }, { 'Mcp-Param-Zone' => 'eu' }])
      expect(lists_at_retry).to eq(1)
      client.cleanup
    end
  end
end

# --- round32 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, thirty-second round: the dialect an
# embedded resource declares governs what an input schema requires through
# it, ECMA-262 word boundaries and group numbering are what ECMA-262 says,
# the preflight runs under the validation-wide deadline, and the core
# declarations it accepts are the well-formed ones.
RSpec.describe 'MCP 2026-07-28 JSON Schema handling — round 32' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft7) { MCPClient::SchemaValidator::DRAFT_07 }
  let(:draft2019) { MCPClient::SchemaValidator::DRAFT_2019_09 }

  describe 'input requirements through an embedded resource' do
    it 'reads a draft-07 resource embedded in a 2020-12 document under its own dialect' do
      # draft-07: a `$ref` replaces its siblings, so the `required` beside
      # it is never applied — and never required of the arguments.
      schema = { 'type' => 'object', '$ref' => 'https://example.com/legacy',
                 '$defs' => { 'legacy' => { '$id' => 'https://example.com/legacy', '$schema' => draft7,
                                            'allOf' => [{ '$ref' => '#/definitions/base', 'required' => ['ignored'] }],
                                            'definitions' => { 'base' => { 'type' => 'object' } } } } }
      expect(validator.check_schema(schema)).to be_empty
      required, = validator.input_requirements(schema)
      expect(required).to eq([])
    end

    it 'reads a 2020-12 resource embedded in a draft-07 document under its own dialect' do
      # 2020-12: the `required` beside the `$ref` applies alongside it. (The
      # resource root itself carries no `$ref`: under the containing
      # draft-07 one would replace the whole object, `$id` included.)
      schema = { '$schema' => draft7, 'type' => 'object',
                 'definitions' => { 'modern' => { '$id' => 'https://example.com/modern',
                                                  '$schema' => MCPClient::SchemaValidator::DEFAULT_DIALECT,
                                                  'allOf' => [{ '$ref' => '#/$defs/base', 'required' => ['counted'] }],
                                                  '$defs' => { 'base' => { 'required' => ['also'] } } } },
                 'allOf' => [{ '$ref' => 'https://example.com/modern' }] }
      expect(validator.check_schema(schema)).to be_empty
      required, = validator.input_requirements(schema)
      expect(required).to contain_exactly('counted', 'also')
    end

    it 'follows a chain of references and allOf members, and lets the nearer property win' do
      schema = { '$ref' => '#/$defs/a', 'properties' => { 'x' => { 'default' => 1 } },
                 '$defs' => { 'a' => { '$ref' => '#/$defs/b', 'required' => ['x'],
                                       'properties' => { 'x' => { 'type' => 'string' } } },
                              'b' => { 'allOf' => [{ 'required' => ['y'] },
                                                   { 'allOf' => [{ 'required' => ['z'] }] }] } } }
      required, properties = validator.input_requirements(schema)
      expect(required).to contain_exactly('x', 'y', 'z')
      expect(properties['x']).to eq({ 'default' => 1 })
    end
  end

  describe 'ECMA-262 word boundaries' do
    it 'sees a word boundary only at an ASCII word character' do
      # ECMA-262 `\w` is [A-Za-z0-9_]: "é" has no word boundary at all.
      expect(validator.validate('é', { 'pattern' => '\\b' })).to contain_exactly(a_string_matching(/pattern/))
      expect(validator.validate('é', { 'pattern' => '\\B' })).to be_empty
      expect(validator.validate('e', { 'pattern' => '\\b' })).to be_empty
      expect(validator.validate('e', { 'pattern' => '^\\Be' })).to contain_exactly(a_string_matching(/pattern/))
      expect(validator.validate('a b', { 'pattern' => '^a\\b b$' })).to be_empty
      expect(validator.validate('aé', { 'pattern' => 'a\\bé' })).to be_empty
      expect(validator.validate('aé', { 'pattern' => 'a\\Bé' })).to contain_exactly(a_string_matching(/pattern/))
      # Through `not` the verdict flips, never the other way round.
      expect(validator.validate('é', { 'not' => { 'pattern' => '\\b' } })).to be_empty
    end

    it 'reads \\b inside a class as a backspace, as both dialects do' do
      expect(validator.validate("\b", { 'pattern' => '^[\\b]$' })).to be_empty
      expect(validator.validate('b', { 'pattern' => '^[\\b]$' })).to contain_exactly(a_string_matching(/pattern/))
    end
  end

  describe 'ECMA-262 group numbering' do
    it 'numbers named and unnamed groups alike, so a numbered reference beside a named group works' do
      schema = { 'pattern' => '^(?<a>x)(y)\\2$' }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('xyy', schema)).to be_empty
      expect(validator.validate('xyz', schema)).to contain_exactly(a_string_matching(/pattern/))
      expect(validator.validate('xyx', schema)).to contain_exactly(a_string_matching(/pattern/))
    end

    it 'refers to a named group by its number too' do
      schema = { 'pattern' => '^(?<a>x)\\1(?<b>y)\\k<b>$' }
      expect(validator.check_schema(schema)).to be_empty
      expect(validator.validate('xxyy', schema)).to be_empty
      expect(validator.validate('xxyz', schema)).to contain_exactly(a_string_matching(/pattern/))
    end

    it 'lets an unnamed group capture beside a named one' do
      schema = { 'pattern' => '^(a)(?<n>b)\\1$' }
      expect(validator.validate('aba', schema)).to be_empty
      expect(validator.validate('abb', schema)).to contain_exactly(a_string_matching(/pattern/))
    end

    it 'keeps a numbered reference to a group that did not participate an empty match' do
      schema = { 'pattern' => '^(?<n>x)?(y)?\\1\\2$' }
      expect(validator.validate('', schema)).to be_empty
      expect(validator.validate('xyxy', schema)).to be_empty
    end
  end

  describe 'lookarounds' do
    it 'decides by what a negative lookahead and lookbehind refuse' do
      expect(validator.validate('bar', { 'pattern' => '^(?!foo)bar$' })).to be_empty
      expect(validator.validate('foobar', { 'pattern' => '^(?!foo)' })).to contain_exactly(a_string_matching(/pattern/))
      expect(validator.validate('xa', { 'pattern' => '(?<!x)a' })).to contain_exactly(a_string_matching(/pattern/))
      expect(validator.validate('ya', { 'pattern' => '(?<!x)a' })).to be_empty
      expect(validator.validate('xa', { 'pattern' => '(?<=x)a' })).to be_empty
      expect(validator.validate('ya', { 'pattern' => '(?<=x)a' })).to contain_exactly(a_string_matching(/pattern/))
    end
  end

  describe 'the preflight under the deadline' do
    def many_patterns(count)
      { 'allOf' => Array.new(count) { |i| { 'pattern' => "^#{'a' * 200}#{i}$" } } }
    end

    it 'stops checking a schema once the deadline has passed, and says so' do
      past = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
      expect(validator.check_schema(many_patterns(50), deadline: past))
        .to contain_exactly(a_string_matching(/time budget exhausted/))
      expect(validator.validate('a', many_patterns(50), deadline: past))
        .to contain_exactly(a_string_matching(/time budget exhausted/))
    end

    it 'does not compile the patterns past the deadline' do
      compiled = 0
      allow(validator).to receive(:ecma_regexp).and_wrap_original do |m, *args|
        compiled += 1
        m.call(*args)
      end
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # The clock stands still until a pattern has been compiled, then jumps
      # past the deadline: compilation demonstrably started, and stopped.
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { compiled.zero? ? now : now + 10 }
      problems = validator.check_schema(many_patterns(400), deadline: now + 1)
      expect(problems).to contain_exactly(a_string_matching(/time budget exhausted/))
      expect(compiled).to be_between(1, 9)
    end

    it 'gives check_schema its own budget when the caller names none' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      problems = validator.check_schema({ 'allOf' => Array.new(1500) { { 'pattern' => "(#{'a' * 9_000})" } } })
      expect(problems).not_to be_empty
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    end
  end

  describe 'the client' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:complete) { { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'n' => 1 } } }

    def stub_server(input_schema: { 'type' => 'object' }, output_schema: { 'type' => 'object' }, answer: complete)
      srv = instance_double(MCPClient::ServerBase, name: 's')
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: input_schema, output_schema: output_schema,
                                 server: srv)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return([tool])
      allow(srv).to receive(:call_tool).and_return(answer)
      allow(srv).to receive(:call_tool_streaming) { |*| Enumerator.new { |y| Array(answer).each { |c| y << c } } }
      srv
    end

    def client_over(srv, mode = :strict)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    describe 'a streamed chunk without resultType' do
      it 'hands a progress object that is no CallToolResult to the host unchanged, in :strict mode' do
        progress = { 'progress' => 3, 'total' => 10 }
        srv = stub_server(output_schema: { 'type' => 'object', 'required' => ['n'] }, answer: [progress, complete])
        client = client_over(srv)

        expect(client.call_tool_streaming('t', {}).to_a).to eq([progress, complete])
        expect(log_output.string).not_to include('structuredContent')
      end

      it 'still validates a legacy result, which has no resultType either' do
        legacy = { 'content' => [], 'structuredContent' => { 'n' => 'not a number' } }
        srv = stub_server(output_schema: { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer' } } },
                          answer: [legacy])
        client = client_over(srv)

        expect { client.call_tool_streaming('t', {}).to_a }
          .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
      end
    end

    describe 'an output schema whose dialect this client cannot read' do
      let(:unreadable) { { '$schema' => 'urn:unknown', 'type' => 'object' } }

      it 'refuses the call before it is sent' do
        srv = stub_server(output_schema: unreadable)
        client = client_over(srv, :warn)

        expect { client.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /output schema.*urn:unknown.*not supported/m)
        expect(srv).not_to have_received(:call_tool)
      end

      it 'refuses the streaming call before it is sent' do
        srv = stub_server(output_schema: unreadable)
        client = client_over(srv, :warn)

        expect { client.call_tool_streaming('t', {}).to_a }
          .to raise_error(MCPClient::Errors::ValidationError, /output schema.*urn:unknown/m)
        expect(srv).not_to have_received(:call_tool_streaming)
      end

      it 'refuses an error result under it too: the dialect error is not limited to successful results' do
        srv = stub_server(output_schema: unreadable)
        client = client_over(srv, :warn)
        tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                   output_schema: unreadable, server: srv)

        expect { client.send(:validate_structured_content!, tool, { 'isError' => true, 'content' => [] }) }
          .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown/)
      end
    end

    describe 'the required arguments under a draft-07 input schema' do
      it 'does not require what a `required` beside a root $ref names, since draft-07 ignores the sibling' do
        input = { '$schema' => draft7, '$ref' => '#/definitions/b', 'required' => ['hidden'],
                  'definitions' => { 'b' => { 'type' => 'object', 'required' => ['x'] } } }
        client = client_over(stub_server(input_schema: input), :warn)

        expect { client.call_tool('t', { 'x' => 1 }) }.not_to raise_error
        expect { client.call_tool('t', {}) }
          .to raise_error(MCPClient::Errors::ValidationError, /Missing required parameters: x$/)
      end
    end

    describe 'two calls overlapping on one client' do
      it 'validates each against its own definition' do
        srv = instance_double(MCPClient::ServerBase, name: 's')
        ok = { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'n' => 1 } }
        tools = %w[a b].map do |name|
          MCPClient::Tool.new(name: name, description: 'd', schema: { 'type' => 'object' },
                              output_schema: { 'type' => 'object', 'required' => [name == 'a' ? 'n' : 'm'] },
                              server: srv)
        end
        allow(srv).to receive(:on_notification)
        allow(srv).to receive(:list_tools).and_return(tools)
        barrier = Queue.new
        allow(srv).to receive(:call_tool) do |name, _|
          barrier << name
          sleep 0.01 until barrier.size >= 2 || Thread.current[:released]
          ok
        end
        client = client_over(srv)

        results = %w[a b].map do |name|
          Thread.new do
            client.call_tool(name, {})
            :ok
          rescue MCPClient::Errors::ValidationError => e
            e.message
          end
        end.map(&:value)

        expect(results[0]).to eq(:ok)
        expect(results[1]).to match(/missing required property 'm'/)
      end
    end
  end

  describe 'malformed core declarations' do
    it 'refuses a $schema on a subschema that is no resource root' do
      schema = { 'properties' => { 'x' => { '$schema' => 'urn:unsupported', 'type' => 'integer' } } }
      expect(validator.check_schema(schema)).to contain_exactly(a_string_matching(/\$schema.*resource root/))
      expect(validator.validate({ 'x' => 1 }, schema)).to contain_exactly(a_string_matching(/\$schema.*resource root/))
      supported = { 'properties' => { 'x' => { '$schema' => draft7, 'type' => 'integer' } } }
      expect(validator.check_schema(supported)).to contain_exactly(a_string_matching(/\$schema.*resource root/))
    end

    it 'still reads a $schema at an embedded resource root' do
      schema = { 'properties' => { 'x' => { '$id' => 'https://example.com/x', '$schema' => draft7,
                                            'items' => [{ 'type' => 'integer' }] } } }
      expect(validator.check_schema(schema)).to be_empty
    end

    it 'requires every $vocabulary identifier to be an absolute URI' do
      expect(validator.check_schema({ '$vocabulary' => { 'relative' => true } }))
        .to contain_exactly(a_string_matching(/\$vocabulary/))
      expect(validator.check_schema({ '$vocabulary' => { '' => true } }))
        .to contain_exactly(a_string_matching(/\$vocabulary/))
      core = 'https://json-schema.org/draft/2020-12/vocab/core'
      expect(validator.check_schema({ '$vocabulary' => { core => true } })).to be_empty
    end
  end
end

# --- round33 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, thirty-third round.
#
# A dynamic reference resolves to the outermost dynamic scope that declares
# its anchor (JSON Schema 2020-12 Core Section 8.2.3.2; 2019-09 Section
# 8.2.4.2.2 for `$recursiveRef`). The dynamic scope always starts at the
# schema being applied, so where that root resource declares the anchor —
# the recursive-tree shape the specification illustrates the keyword with —
# the reference re-binds to the root wherever it is met; and where exactly
# one resource declares it, it is the target the reference named. Only a
# document in which several non-root resources declare the same dynamic
# anchor needs the evaluation path to choose, and stays out of reach. A
# branchless `if` still produces annotations (Section 10.2.2.1), and a
# generated capture-group name never collides with one the pattern wrote.
RSpec.describe 'MCP 2026-07-28 JSON Schema dynamic references, branchless if, captures (round 33)' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft2019) { MCPClient::SchemaValidator::DRAFT_2019_09 }

  def valid?(data, schema)
    errors = validator.validate(data, schema)
    expect(errors).not_to include(a_string_matching(/aborted|not supported/)), errors.inspect
    errors.empty?
  end

  def expect_verdicts(schema, valid:, invalid:)
    valid.each { |data| expect(valid?(data, schema)).to be(true), "expected #{data.inspect} to conform" }
    invalid.each { |data| expect(valid?(data, schema)).to be(false), "expected #{data.inspect} to be rejected" }
  end

  describe 'a $dynamicRef whose anchor the root resource declares' do
    it 'binds to the root: the recursive node shape' do
      schema = { '$dynamicAnchor' => 'node', 'type' => 'object',
                 'properties' => { 'child' => { '$dynamicRef' => '#node' } } }
      expect(validator.unsupported_keywords(schema)).to be_empty
      expect_verdicts(schema, valid: [{ 'child' => {} }, { 'child' => { 'child' => {} } }],
                              invalid: [{ 'child' => 1 }, { 'child' => { 'child' => 'x' } }])
    end

    it 'binds to the anchor a definition of the root resource declares' do
      schema = { '$dynamicRef' => '#node', '$defs' => { 'n' => { '$dynamicAnchor' => 'node', 'type' => 'integer' } } }
      expect(validator.unsupported_keywords(schema)).to be_empty
      expect_verdicts(schema, valid: [1], invalid: ['bad'])
    end

    it 're-binds a reference met inside another resource to the root, so the strict tree stays closed' do
      tree = { '$id' => 'https://example.com/tree', '$dynamicAnchor' => 'node', 'type' => 'object',
               'properties' => { 'data' => true,
                                 'children' => { 'type' => 'array', 'items' => { '$dynamicRef' => '#node' } } } }
      strict = { '$id' => 'https://example.com/strict-tree', '$dynamicAnchor' => 'node',
                 '$ref' => 'tree', 'unevaluatedProperties' => false, '$defs' => { 'tree' => tree } }
      expect(validator.unsupported_keywords(strict)).to be_empty
      expect_verdicts(strict,
                      valid: [{ 'data' => 1, 'children' => [{ 'data' => 2 }] }],
                      invalid: [{ 'data' => 1, 'children' => [{ 'data' => 2, 'extra' => 3 }] },
                                { 'data' => 1, 'extra' => 3 }])
      # The tree alone is open: nothing re-binds the reference to a closed root.
      expect_verdicts(tree, valid: [{ 'data' => 1, 'children' => [{ 'data' => 2, 'extra' => 3 }] }], invalid: [])
    end

    it 'applies a 2019-09 $recursiveRef to a root whose $recursiveAnchor is true' do
      schema = { '$schema' => draft2019, '$recursiveAnchor' => true, 'type' => 'object',
                 'properties' => { 'child' => { '$recursiveRef' => '#' } } }
      expect(validator.unsupported_keywords(schema)).to be_empty
      expect_verdicts(schema, valid: [{ 'child' => {} }], invalid: [{ 'child' => 1 }])
    end
  end

  describe 'a dynamic anchor several non-root resources declare' do
    let(:elsewhere) do
      { '$ref' => 'https://example.com/a',
        '$defs' => { 'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node', 'type' => 'object',
                              'properties' => { 'child' => { '$dynamicRef' => '#node' } } },
                     'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node', 'type' => 'string' } } }
    end

    # The dynamic scope holds the resources the evaluation entered, and `b`
    # is not one of them: it declares nothing for this reference, so the
    # binding is decided and the verdict is whole (see round 34).
    it 'is evaluated against the resources the instance entered' do
      expect(validator.unsupported_keywords(elsewhere)).to be_empty
      expect(validator.validate({ 'child' => 1 }, elsewhere)).not_to be_empty
      expect(validator.validate({ 'child' => 1 }, { 'not' => elsewhere })).to be_empty
    end
  end

  describe 'a branchless if' do
    it 'still contributes the annotations of a condition that passed' do
      expect_verdicts({ 'if' => { 'properties' => { 'foo' => true } }, 'unevaluatedProperties' => false },
                      valid: [{ 'foo' => 1 }, {}], invalid: [{ 'bar' => 1 }, { 'foo' => 1, 'bar' => 2 }])
      expect_verdicts({ 'if' => { 'prefixItems' => [true] }, 'unevaluatedItems' => false },
                      valid: [[1], []], invalid: [[1, 2]])
    end

    it 'contributes nothing when the condition failed' do
      expect_verdicts({ 'if' => { 'properties' => { 'foo' => { 'type' => 'string' } } },
                        'unevaluatedProperties' => false },
                      valid: [{ 'foo' => 'a' }], invalid: [{ 'foo' => 1 }])
    end

    it 'keeps the verdict when the whole thing sits under not' do
      schema = { 'not' => { 'if' => { 'properties' => { 'foo' => true } }, 'unevaluatedProperties' => false } }
      expect_verdicts(schema, valid: [{ 'bar' => 1 }], invalid: [{ 'foo' => 1 }])
    end
  end

  describe 'a pattern whose own group name looks generated' do
    it 'numbers the unnamed group without colliding with the written name' do
      schema = { 'type' => 'string', 'pattern' => '^(a)(?<__mcp_g1>b)\\1$' }
      expect_verdicts(schema, valid: ['aba'], invalid: %w[abb ab])
    end

    it 'decides patternProperties by the right match' do
      schema = { 'patternProperties' => { '^(a)(?<__mcp_g1>b)\\1$' => { 'type' => 'integer' } } }
      expect_verdicts(schema, valid: [{ 'abb' => 'x' }, { 'aba' => 1 }], invalid: [{ 'aba' => 'x' }])
    end
  end

  describe 'the client' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:complete) { { 'resultType' => 'complete', 'content' => [], 'structuredContent' => { 'n' => 1 } } }

    def stub_server(output_schema:, answer: complete)
      srv = instance_double(MCPClient::ServerBase, name: 's')
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                 output_schema: output_schema, server: srv)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return([tool])
      allow(srv).to receive(:call_tool).and_return(answer)
      srv
    end

    def client_over(srv, mode = :strict)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    it 'accepts, in :strict mode, a result under a schema whose dynamic anchor the root declares' do
      schema = { '$dynamicAnchor' => 'node', 'type' => 'object',
                 'properties' => { 'child' => { '$dynamicRef' => '#node' } } }
      good = complete.merge('structuredContent' => { 'child' => { 'child' => {} } })
      bad = complete.merge('structuredContent' => { 'child' => 1 })

      expect(client_over(stub_server(output_schema: schema, answer: good)).call_tool('t', {})).to eq(good)
      expect { client_over(stub_server(output_schema: schema, answer: bad)).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
      expect(log_output.string).not_to include('validation is partial')
    end

    # An error result may omit structuredContent; one that carries it is
    # still bound by the output schema (the tools specification exempts
    # nothing about error results), so :strict checks what is there.
    it 'validates the structuredContent an error result carries, in :strict mode' do
      schema = { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer' } } }
      wrong = { 'resultType' => 'complete', 'content' => [], 'isError' => true, 'structuredContent' => { 'n' => 'x' } }
      bare = { 'resultType' => 'complete', 'content' => [{ 'type' => 'text', 'text' => 'boom' }], 'isError' => true }

      expect { client_over(stub_server(output_schema: schema, answer: wrong)).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
      expect(client_over(stub_server(output_schema: schema, answer: bare)).call_tool('t', {})).to eq(bare)
    end

    it 'refuses every structured result under an outputSchema of false, in :strict mode' do
      expect { client_over(stub_server(output_schema: false)).call_tool('t', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
      expect(client_over(stub_server(output_schema: false), :warn).call_tool('t', {})).to eq(complete)
      expect(log_output.string).to include('does not match its output schema')
    end
  end

  describe 'the HeaderMismatch retry on Streamable HTTP' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }
    let(:json) { { 'Content-Type' => 'application/json' } }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result), headers: json }
    end

    def listing(header, output_dialect: nil, ttl: 0)
      input = { 'type' => 'object', 'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } }
      output = { 'type' => 'object' }
      output = { '$schema' => output_dialect }.merge(output) if output_dialect
      { 'tools' => [{ 'name' => 'wipe', 'inputSchema' => input, 'outputSchema' => output }], 'ttlMs' => ttl }
    end

    # The refreshed definition is checked before the retry goes out, on both
    # of its schemas: a tool run under an output dialect nothing here can
    # read would only be refused after it ran.
    it 'is not sent under a refreshed output dialect this client cannot read' do
      calls = 0
      rejected = false
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => { 'tools' => {} } })
        when 'tools/list'
          json_response(body['id'], listing('Region', output_dialect: rejected ? 'urn:unknown-dialect' : nil))
        when 'tools/call'
          calls += 1
          rejected = true
          { status: 400, headers: json,
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_020, 'message' => 'Mcp-Param-Region missing' }) }
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
        validate_structured_content: :strict
      )

      expect { client.call_tool('wipe', { 'region' => 'eu' }) }
        .to raise_error(MCPClient::Errors::ValidationError, /output schema.*urn:unknown-dialect.*not supported/m)
      expect(calls).to eq(1)
      client.cleanup
    end

    # The definition pinned for a retry is that retry's alone: once the
    # retry was refused, the next call reads a fresh list and derives its
    # headers from what it read, not from what the refused retry held.
    it 'leaves no pinned definition behind once the retry was refused' do
      headers = []
      lists = 0
      rejected = false
      readable_again = false
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => { 'tools' => {} } })
        when 'tools/list'
          lists += 1
          next json_response(body['id'], listing('Region')) unless rejected

          # Every list read while the first call recovers is unreadable; the
          # lists the second call reads name a new header.
          json_response(body['id'], listing('Zone', output_dialect: readable_again ? nil : 'urn:unknown-dialect'))
        when 'tools/call'
          headers << request.headers.slice('Mcp-Param-Region', 'Mcp-Param-Zone')
          if rejected
            next json_response(body['id'], { 'resultType' => 'complete', 'content' => [],
                                             'structuredContent' => {} })
          end

          rejected = true
          { status: 400, headers: json,
            body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                'error' => { 'code' => -32_020, 'message' => 'Mcp-Param-Zone missing' }) }
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
        validate_structured_content: :strict
      )

      expect { client.call_tool('wipe', { 'region' => 'eu' }) }.to raise_error(MCPClient::Errors::ValidationError)
      readable_again = true
      expect(client.call_tool('wipe', { 'region' => 'us' }))
        .to eq({ 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} })
      expect(headers).to eq([{ 'Mcp-Param-Region' => 'eu' }, { 'Mcp-Param-Zone' => 'us' }])
      expect(lists).to be >= 3
      client.cleanup
    end

    # Two calls of one tool recovering at once: both first attempts really are
    # rejected and both really are re-sent, each under the header its own
    # refresh read. NOTE: `take_pinned_retry_definition` answers nil on this
    # path, so what keeps the two apart here is the per-call definition
    # lookup, not the retry pin — the pin itself is still unpinned by any
    # example, which is worth closing.
    it 'sends each overlapping retry under the definition its own refresh read' do
      retries = Queue.new
      rejections = Queue.new
      refreshed = Queue.new
      refreshes = 0
      calls = []
      lock = Mutex.new
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => { 'tools' => {} } })
        when 'tools/list'
          # Every list before both calls have been rejected still annotates
          # `region` with Region, so both first attempts really do go out
          # under it and really are rejected; each refresh that follows
          # brings a header of its own, which is what the two retries must
          # not share.
          n = lock.synchronize { refreshes += 1 }
          next json_response(body['id'], listing('Region')) if rejections.size < 2

          # Neither refreshed list is handed back until both have been
          # produced, so the list the transport caches is the later one for
          # both callers: only the definition each retry pinned for itself
          # can still tell the two apart.
          refreshed << n
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
          sleep 0.01 while refreshed.size < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          # Cacheable, so the retry that reads the transport's list rather
          # than the definition it pinned for itself finds the other's.
          json_response(body['id'], listing("H#{n}", ttl: 60_000))
        when 'tools/call'
          mirrored = request.headers.select { |k, _| k.start_with?('Mcp-Param-') }
          lock.synchronize { calls << body['id'] }
          if mirrored.key?('Mcp-Param-Region')
            rejections << body['id']
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
            sleep 0.01 while rejections.size < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            { status: 400, headers: json,
              body: JSON.generate('jsonrpc' => '2.0', 'id' => body['id'],
                                  'error' => { 'code' => -32_020, 'message' => 'header missing' }) }
          else
            retries << mirrored
            json_response(body['id'], { 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} })
          end
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)]
      )
      client.list_tools

      threads = %w[a b].map { |region| Thread.new { client.call_tool('wipe', { 'region' => region }) } }
      expect(threads.map(&:value))
        .to all(eq({ 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} }))
      sent = Array.new(2) { retries.pop }
      expect(sent.map(&:keys).flatten.uniq.size).to eq(2)
      expect(sent.map(&:values).flatten).to contain_exactly('a', 'b')
      # Both calls were rejected once and re-sent once, each under a request
      # id of its own: four requests, no id reused.
      expect(rejections.size).to eq(2)
      expect(calls.size).to eq(4)
      expect(calls.uniq.size).to eq(4)
      client.cleanup
    end
  end

  describe 'validations overlapping with opposite verdicts' do
    it 'keeps each to its own schema, including a resource-local $ref that resolves differently' do
      accepting = { '$ref' => '#/$defs/x', '$defs' => { 'x' => { 'type' => 'integer' } } }
      rejecting = { '$ref' => '#/$defs/x', '$defs' => { 'x' => { 'type' => 'string' } } }
      open_tuple = { 'prefixItems' => [{ 'type' => 'integer' }], 'items' => true }
      closed_tuple = { 'prefixItems' => [{ 'type' => 'integer' }], 'items' => false }
      barrier = Queue.new
      threads = Array.new(8) do |i|
        Thread.new do
          barrier.pop
          Array.new(25) do
            case i % 4
            when 0 then [:empty, validator.validate(1, accepting)]
            when 1 then [:error, validator.validate(1, rejecting)]
            when 2 then [:empty, validator.validate([1, 2], open_tuple)]
            else [:error, validator.validate([1, 2], closed_tuple)]
            end
          end
        end
      end
      8.times { barrier << true }
      threads.each do |thread|
        thread.value.each do |expectation, answer|
          expectation == :empty ? expect(answer).to(be_empty) : expect(answer).not_to(be_empty)
        end
      end
    end
  end

  describe 'a session negotiated to 2025-11-25' do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:schema) { { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer' } } } }

    def legacy_server(*chunks)
      srv = instance_double(MCPClient::ServerStdio, name: 's', modern?: false)
      tool = MCPClient::Tool.new(name: 't', description: 'd', schema: { 'type' => 'object' },
                                 output_schema: schema, server: srv)
      allow(srv).to receive(:on_notification)
      allow(srv).to receive(:list_tools).and_return([tool])
      allow(srv).to receive(:call_tool_streaming) { |*| Enumerator.new { |y| chunks.each { |c| y << c } } }
      srv
    end

    def client_over(srv, mode)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(srv)
      MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'test' }], logger: logger,
                            validate_structured_content: mode)
    end

    it 'validates an object structuredContent a streamed legacy result carries' do
      legacy = { 'content' => [], 'structuredContent' => { 'n' => 'x' } }
      expect { client_over(legacy_server(legacy), :strict).call_tool_streaming('t', {}).to_a }
        .to raise_error(MCPClient::Errors::ValidationError, /does not match its output schema/)
    end

    it 'treats a non-object structuredContent as absent on the streaming path, as 2025-11-25 types it' do
      legacy = { 'content' => [], 'structuredContent' => [1] }
      client = client_over(legacy_server(legacy), :warn)
      expect(client.call_tool_streaming('t', {}).to_a).to eq([legacy])
      expect(log_output.string).to include('carries no structuredContent')
    end
  end

  describe 'the public task API' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1, name: 'a') }
    let(:tasks_ext) { MCPClient::JsonRpcCommon::TASKS_EXTENSION }
    let(:strict_schema) do
      { 'type' => 'object', 'required' => ['n'], 'properties' => { 'n' => { 'type' => 'integer' } } }
    end

    def tool_with(output_schema)
      MCPClient::Tool.new(name: 'sync', description: 'd', schema: { 'type' => 'object' },
                          output_schema: output_schema, server: stdio)
    end

    def create_result
      now = Time.now.utc.iso8601(3)
      { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'createdAt' => now,
        'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1 }
    end

    def completed(result)
      now = Time.now.utc.iso8601(3)
      { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => 'completed', 'createdAt' => now,
        'lastUpdatedAt' => now, 'ttlMs' => nil, 'pollIntervalMs' => 1, 'result' => result }
    end

    def client_for(tool, delivered:)
      allow(stdio).to receive_messages(modern?: true, ping: true,
                                       capabilities: { 'tools' => {}, 'extensions' => { tasks_ext => {} } })
      allow(stdio).to receive(:ensure_session_ready)
      stdio.singleton_class.include(MCPClient::CalledToolDefinition)
      allow(stdio).to receive(:list_tools).and_return([tool])
      allow(stdio).to receive(:call_tool) do
        stdio.send(:note_called_tool_definition, 'sync', tool)
        create_result
      end
      allow(stdio).to receive(:rpc_request) do |method, *_args, **_opts|
        raise "unexpected #{method}" unless method == 'tasks/get'

        completed(delivered)
      end
      allow(MCPClient::ServerFactory).to receive(:create).and_return(stdio)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x', name: 'a' }],
                                     extensions: [tasks_ext], validate_structured_content: :strict)
      allow(client).to receive(:sleep)
      client
    end

    it 'refuses to create a task under an output dialect it cannot read, before anything is sent' do
      unreadable = tool_with({ '$schema' => 'urn:unknown', 'type' => 'object' })
      client = client_for(unreadable, delivered: {})

      expect { client.call_tool_as_task('sync', {}) }
        .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown.*not supported/m)
      expect(stdio).not_to have_received(:call_tool)
    end

    it 'refuses a delivered result a closed composition rejects' do
      closed = { '$ref' => '#/$defs/b', 'unevaluatedProperties' => false,
                 '$defs' => { 'b' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer' } } } } }
      leak = { 'content' => [], 'structuredContent' => { 'n' => 1, 'secret' => 'x' } }
      client = client_for(tool_with(closed), delivered: leak)
      handle = client.call_tool_as_task('sync', {})

      expect { client.get_task_result(handle) }
        .to raise_error(MCPClient::Errors::ValidationError, /'secret' is not allowed/)
    end

    it 'validates the delivered result against the definition the task was created under' do
      client = client_for(tool_with(strict_schema), delivered: { 'content' => [], 'structuredContent' => { 'n' => 1 } })
      handle = client.call_tool_as_task('sync', {})
      # The definition changes while the task runs: what the server refreshed
      # to would reject the result the creating call was promised.
      refreshed = tool_with({ 'type' => 'object', 'required' => ['m'] })
      allow(stdio).to receive(:list_tools).and_return([refreshed])
      client.send(:clear_tool_cache)

      expect(client.get_task_result(handle)).to eq({ 'content' => [], 'structuredContent' => { 'n' => 1 } })
    end
  end
end

# --- round34 ---------------------------------------------------------------

# MCP 2026-07-28 JSON Schema handling, thirty-fourth round.
#
# A dynamic reference binds to the outermost schema resource in the *dynamic
# scope* — the resources evaluation actually entered on the way to it (JSON
# Schema 2020-12 Core Section 8.2.3.2; 2019-09 Section 8.2.4.2.2 for
# `$recursiveRef`). A resource the instance never enters declares nothing
# for it, so a duplicate anchor elsewhere in the document decides nothing.
# `contains` produces the item annotations `unevaluatedItems` reads in
# 2020-12 and not in 2019-09, and a pattern whose ECMA-262 meaning Ruby's
# engine cannot be made to reproduce is refused rather than answered wrongly.
RSpec.describe 'MCP 2026-07-28 JSON Schema dynamic scope, contains annotations, patterns (round 34)' do
  let(:validator) { MCPClient::SchemaValidator }
  let(:draft2019) { MCPClient::SchemaValidator::DRAFT_2019_09 }

  def valid?(data, schema)
    errors = validator.validate(data, schema)
    expect(errors).not_to include(a_string_matching(/aborted|not supported/)), errors.inspect
    errors.empty?
  end

  def expect_verdicts(schema, valid:, invalid:)
    valid.each { |data| expect(valid?(data, schema)).to be(true), "expected #{data.inspect} to conform" }
    invalid.each { |data| expect(valid?(data, schema)).to be(false), "expected #{data.inspect} to be rejected" }
  end

  describe 'the dynamic scope is the resources evaluation entered' do
    # Two resources declare `node`; only `a` is ever entered, so the
    # reference inside it binds to `a` and nothing about `b` reaches the
    # verdict. Deciding this statically ("several non-root declarations, so
    # the path would have to choose") left the reference unevaluated and the
    # instance wrongly accepted.
    let(:unused_duplicate) do
      { '$ref' => 'https://example.com/a',
        '$defs' => {
          'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node', 'type' => 'object',
                   'properties' => { 'child' => { '$dynamicRef' => '#node' } } },
          'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node', 'type' => 'string' }
        } }
    end

    it 'ignores a duplicate anchor in a resource the instance never enters' do
      expect_verdicts(unused_duplicate,
                      valid: [{ 'child' => {} }, { 'child' => { 'child' => {} } }],
                      invalid: [{ 'child' => 1 }, { 'child' => { 'child' => 'x' } }])
    end

    it 'inverts that verdict under not, rather than accepting both sides' do
      expect_verdicts({ 'not' => unused_duplicate },
                      valid: [{ 'child' => 1 }],
                      invalid: [{ 'child' => {} }])
    end

    it 'reports no unsupported keyword for it, so :strict can gate on the verdict' do
      expect(validator.unsupported_keywords(unused_duplicate)).to be_empty
    end

    # The specification's own illustration: the outer resource overrides the
    # anchor the inner one declares, so the reference inside the inner
    # resource re-binds outward to whichever resource the evaluation began at.
    let(:tree) do
      { '$id' => 'https://example.com/tree', '$dynamicAnchor' => 'node',
        'type' => 'object',
        'properties' => { 'data' => true,
                          'children' => { 'type' => 'array', 'items' => { '$dynamicRef' => '#node' } } } }
    end

    def strict_tree(tree)
      { '$id' => 'https://example.com/strict-tree', '$dynamicAnchor' => 'node',
        '$ref' => 'https://example.com/tree', 'unevaluatedProperties' => false,
        '$defs' => { 'tree' => tree } }
    end

    it 'binds a reference met inside an entered resource to the outermost declaration' do
      expect_verdicts(strict_tree(tree),
                      valid: [{ 'data' => 1 }, { 'data' => 1, 'children' => [{ 'data' => 2 }] }],
                      invalid: [{ 'data' => 1, 'extra' => 2 },
                                { 'data' => 1, 'children' => [{ 'data' => 2, 'extra' => 3 }] }])
    end

    it 'binds to the entered resource itself when nothing outer declares the anchor' do
      expect_verdicts({ '$id' => 'https://example.com/plain', '$ref' => 'https://example.com/tree',
                        '$defs' => { 'tree' => tree } },
                      valid: [{ 'data' => 1, 'extra' => 2 },
                              { 'children' => [{ 'data' => 2, 'extra' => 3 }] }],
                      invalid: [{ 'children' => [1] }])
    end

    # 2019-09 spells the same rule with `$recursiveRef`/`$recursiveAnchor`.
    it 'follows the 2019-09 recursive reference outward the same way' do
      inner = { '$id' => 'https://example.com/r-tree', '$recursiveAnchor' => true,
                'type' => 'object',
                'properties' => { 'data' => true,
                                  'children' => { 'type' => 'array',
                                                  'items' => { '$recursiveRef' => '#' } } } }
      strict = { '$schema' => draft2019, '$id' => 'https://example.com/r-strict',
                 '$recursiveAnchor' => true, '$ref' => 'https://example.com/r-tree',
                 'unevaluatedProperties' => false, '$defs' => { 'tree' => inner } }
      expect(validator.unsupported_keywords(strict)).to be_empty
      expect_verdicts(strict,
                      valid: [{ 'data' => 1, 'children' => [{ 'data' => 2 }] }],
                      invalid: [{ 'data' => 1, 'children' => [{ 'data' => 2, 'extra' => 3 }] }])
    end

    it 'refuses a dynamic reference whose anchor no entered resource declares' do
      schema = { '$dynamicRef' => '#nowhere', 'type' => 'object' }
      expect(validator.validate({}, schema)).to include(a_string_matching(/\$dynamicRef/))
    end
  end

  describe 'contains annotations belong to 2020-12' do
    let(:schema) { { 'contains' => { 'type' => 'integer' }, 'unevaluatedItems' => false } }

    it 'lets a matched item satisfy unevaluatedItems under 2020-12' do
      expect_verdicts(schema, valid: [[1]], invalid: [%w[a]])
    end

    # 2019-09 Core Section 9.3.1.3: unevaluatedItems reads the annotations of
    # items/additionalItems only, so a `contains` match leaves the item
    # unevaluated and `false` refuses it. `items` still annotates there, so
    # the same array passes once something evaluates it.
    it 'does not, under 2019-09' do
      expect_verdicts(schema.merge('$schema' => draft2019), valid: [], invalid: [[1], %w[a]])
      expect_verdicts(schema.merge('$schema' => draft2019, 'items' => true), valid: [[1]], invalid: [%w[a]])
    end

    # The dialect belongs to the resource root, so it is declared there and
    # the composed branch is read under it.
    it 'inverts under not, so the dialect decides both directions' do
      expect(valid?([1], { 'not' => schema })).to be(false)
      expect(valid?([1], { '$schema' => draft2019, 'not' => schema })).to be(true)
    end
  end

  describe 'patterns whose ECMA-262 meaning Ruby cannot reproduce' do
    # ECMAScript clears the captures inside a quantified group at the start of
    # every iteration, Ruby keeps the last one that participated: "aba" is
    # valid there and "abab" is not, and Ruby's engine says the opposite of
    # both. A wrong verdict in either direction is worse than no verdict.
    let(:reset_pattern) { { 'pattern' => '^(a|(b))*\2$' } }

    it 'refuses the schema instead of answering either way' do
      %w[aba abab].each do |data|
        errors = validator.validate(data, reset_pattern)
        expect(errors).to include(a_string_matching(/cannot be evaluated faithfully/)), errors.inspect
      end
    end

    it 'never reports it as no ECMA-262 regular expression' do
      expect(validator.validate('aba', reset_pattern))
        .not_to include(a_string_matching(/is not an ECMA-262 regular expression/))
    end

    # ES2018 lookbehind is variable-length; Ruby's is not. The pattern is a
    # perfectly good ECMA-262 expression, so saying it is not one was wrong.
    it 'says the same of a variable-length lookbehind' do
      errors = validator.validate('aab', { 'pattern' => '(?<=a+)b' })
      expect(errors).to include(a_string_matching(/cannot be evaluated faithfully/))
      expect(errors).not_to include(a_string_matching(/is not an ECMA-262 regular expression/))
    end

    it 'still refuses an expression that is no regular expression at all' do
      expect(validator.validate('x', { 'pattern' => '(' }))
        .to include(a_string_matching(/is not an ECMA-262 regular expression/))
    end

    it 'keeps evaluating a back-reference to a group no quantifier repeats' do
      expect_verdicts({ 'pattern' => '^(a)(?<b>x)?\1$' }, valid: %w[aa], invalid: %w[ab])
    end

    it 'reads an astral escape written as a surrogate pair' do
      expect_verdicts({ 'pattern' => '\\uD83D\\uDE00' }, valid: ["\u{1F600}!"], invalid: %w[x])
    end
  end

  # The definition a call goes out under is the one header extraction reads,
  # and that read may bring a newer list than the client preflighted. A tool
  # whose refreshed schema declares a dialect nothing here can read must be
  # refused before it runs, not after — the retry path already was.
  describe 'a definition replaced between the preflight and the initial send' do
    let(:base_url) { 'https://example.com' }
    let(:endpoint) { '/mcp' }
    let(:url) { "#{base_url}#{endpoint}" }
    let(:json) { { 'Content-Type' => 'application/json' } }

    def json_response(id, result)
      { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result), headers: json }
    end

    def listing(dialect_side)
      input = { 'type' => 'object', 'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' } } }
      output = { 'type' => 'object' }
      input = { '$schema' => 'urn:unknown-dialect' }.merge(input) if dialect_side == 'input'
      output = { '$schema' => 'urn:unknown-dialect' }.merge(output) if dialect_side == 'output'
      { 'tools' => [{ 'name' => 'wipe', 'inputSchema' => input, 'outputSchema' => output }], 'ttlMs' => 0 }
    end

    %w[input output].each do |side|
      it "refuses the call before it runs when the refreshed #{side} dialect cannot be read" do
        lists = 0
        calls = 0
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          case body['method']
          when 'server/discover'
            json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                        'capabilities' => { 'tools' => {} } })
          when 'tools/list'
            # The zero-TTL list is read three times before the call goes out:
            # by list_tools, by the client's own preflight, and by the header
            # extraction that decides what the request carries. Only the last
            # one brings the unreadable dialect, so the preflight passes and
            # the transport is the only thing left to catch it.
            lists += 1
            json_response(body['id'], listing(lists >= 3 ? side : nil))
          when 'tools/call'
            calls += 1
            json_response(body['id'], { 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} })
          end
        end
        client = MCPClient::Client.new(
          mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)]
        )
        client.list_tools

        expect { client.call_tool('wipe', { 'region' => 'eu' }) }
          .to raise_error(MCPClient::Errors::ValidationError, /urn:unknown-dialect/)
        expect(calls).to eq(0)
        expect(lists).to be >= 3
        client.cleanup
      end
    end

    it 'still sends the call when the refreshed definition stays readable' do
      lists = 0
      headers = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => { 'tools' => {} } })
        when 'tools/list'
          lists += 1
          json_response(body['id'], listing(nil))
        when 'tools/call'
          headers << request.headers.select { |k, _| k.start_with?('Mcp-Param-') }
          json_response(body['id'], { 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} })
        end
      end
      client = MCPClient::Client.new(
        mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)]
      )
      client.list_tools

      expect(client.call_tool('wipe', { 'region' => 'eu' }))
        .to eq({ 'resultType' => 'complete', 'content' => [], 'structuredContent' => {} })
      expect(headers).to eq([{ 'Mcp-Param-Region' => 'eu' }])
      client.cleanup
    end
  end

  # MCP 2025-11-25 types structuredContent as an object, so anything else was
  # no structured content at all on a session negotiated to that revision. An
  # error result is allowed to carry none — dropping the non-object must
  # leave it an error result, not turn it into a successful one missing its
  # output.
  describe 'an error result carrying a non-object structuredContent on a legacy session' do
    let(:logger) { instance_double(Logger, warn: nil, info: nil, debug: nil, error: nil, :level= => nil) }
    let(:server) { instance_double(MCPClient::ServerStdio, modern?: false, name: 'legacy') }
    let(:tool) do
      MCPClient::Tool.new(name: 'run', description: 'd', schema: { 'type' => 'object' }, server: server,
                          output_schema: { 'type' => 'object' })
    end

    def client_with(mode)
      client = MCPClient::Client.new(mcp_server_configs: [])
      client.instance_variable_set(:@logger, logger)
      client.instance_variable_set(:@validate_structured_content, mode)
      client
    end

    [nil, 'text', 1, true, []].each do |content|
      it "returns it unchanged in :strict when structuredContent is #{content.inspect}" do
        result = { 'isError' => true, 'content' => [], 'structuredContent' => content }

        expect(client_with(:strict).send(:validate_structured_content!, tool, result)).to eq(result)
        expect(logger).not_to have_received(:warn).with(/carries no structuredContent/)
      end
    end

    it 'still refuses a successful result whose structuredContent is not an object' do
      result = { 'content' => [], 'structuredContent' => 'text' }

      expect { client_with(:strict).send(:validate_structured_content!, tool, result) }
        .to raise_error(MCPClient::Errors::ValidationError, /carries no structuredContent/)
    end

    it 'still checks an error result whose structuredContent is an object' do
      result = { 'isError' => true, 'content' => [], 'structuredContent' => { 'a' => 1 } }
      tool = MCPClient::Tool.new(name: 'run', description: 'd', schema: { 'type' => 'object' }, server: server,
                                 output_schema: { 'type' => 'object', 'properties' => { 'a' => { 'type' => 'string' } },
                                                  'required' => ['a'] })

      expect { client_with(:strict).send(:validate_structured_content!, tool, result) }
        .to raise_error(MCPClient::Errors::ValidationError)
    end
  end
end
