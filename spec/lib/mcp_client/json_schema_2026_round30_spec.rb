# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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

          # The refresh and the dialect check read a readable definition; any
          # list read after those declares a dialect nothing here can read.
          lists_after_rejection += 1
          readable = lists_after_rejection <= 2
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
      expect(lists_at_retry).to eq(2)
      client.cleanup
    end
  end
end
