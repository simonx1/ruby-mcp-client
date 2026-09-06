# frozen_string_literal: true

require 'spec_helper'

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
      clock = [now, now, now + 10] # the first pattern is compiled before the clock jumps past the deadline
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock.length > 1 ? clock.shift : clock.first }
      problems = validator.check_schema(many_patterns(400), deadline: now + 1)
      expect(problems).to contain_exactly(a_string_matching(/time budget exhausted/))
      expect(compiled).to be < 10
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
