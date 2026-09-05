# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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

    it 'still defers the keyword where a composition produces the annotations' do
      # An in-place applicator contributes annotations this validator does not
      # collect, so the keyword stays unevaluated — reported, never guessed.
      composed = { 'allOf' => [{ 'properties' => { 'a' => true } }], 'unevaluatedProperties' => false }
      expect(validator.unsupported_keywords(composed)).to contain_exactly('unevaluatedProperties')
      expect(validator.validate({ 'a' => 1 }, composed)).to be_empty
      # ... and never decides a non-monotonic composition on that guess.
      expect(validator.validate({ 'a' => 1 }, { 'not' => composed })).to be_empty

      referenced = { '$ref' => '#/$defs/p', 'unevaluatedProperties' => false,
                     '$defs' => { 'p' => { 'properties' => { 'a' => true } } } }
      expect(validator.unsupported_keywords(referenced)).to contain_exactly('unevaluatedProperties')
      expect(validator.validate({ 'a' => 1 }, referenced)).to be_empty
    end

    it 'still defers unevaluatedItems beside contains, whose matches annotate' do
      schema = { 'contains' => { 'type' => 'string' }, 'unevaluatedItems' => false }
      expect(validator.unsupported_keywords(schema)).to contain_exactly('unevaluatedItems')
      expect(validator.validate(['x', 1], schema)).to be_empty
    end

    it 'leaves the keyword alone in a dialect that does not define it' do
      legacy = { '$schema' => draft7, 'unevaluatedProperties' => false }
      expect(validator.unsupported_keywords(legacy)).to be_empty
      expect(validator.validate({ 'a' => 1 }, legacy)).to be_empty
      modern = { '$schema' => draft2019, 'unevaluatedProperties' => false }
      expect(validator.validate({ 'a' => 1 }, modern))
        .to contain_exactly(a_string_matching(/unevaluatedProperties/))
    end

    it 'keeps the dynamic references deferred, and says so' do
      # A `$dynamicRef` needs the dynamic scope a validation was entered
      # through, which this validator does not track. It stays unevaluated,
      # is reported, and never decides a non-monotonic composition.
      schema = { '$dynamicRef' => '#node', '$defs' => { 'n' => { '$dynamicAnchor' => 'node', 'type' => 'string' } } }
      expect(validator.unsupported_keywords(schema)).to contain_exactly('$dynamicRef')
      expect(validator.validate(1, schema)).to be_empty
      expect(validator.validate(1, { 'not' => schema })).to be_empty
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
