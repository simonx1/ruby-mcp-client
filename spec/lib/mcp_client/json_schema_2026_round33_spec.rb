# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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
    let(:ambiguous) do
      { '$ref' => 'https://example.com/a',
        '$defs' => { 'a' => { '$id' => 'https://example.com/a', '$dynamicAnchor' => 'node', 'type' => 'object',
                              'properties' => { 'child' => { '$dynamicRef' => '#node' } } },
                     'b' => { '$id' => 'https://example.com/b', '$dynamicAnchor' => 'node', 'type' => 'string' } } }
    end

    it 'is the one dynamic reference still reported as not evaluated' do
      expect(validator.unsupported_keywords(ambiguous)).to contain_exactly('$dynamicRef')
      expect(validator.validate({ 'child' => 1 }, { 'not' => ambiguous })).to be_empty
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

    def listing(header, output_dialect: nil)
      input = { 'type' => 'object', 'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } }
      output = { 'type' => 'object' }
      output = { '$schema' => output_dialect }.merge(output) if output_dialect
      { 'tools' => [{ 'name' => 'wipe', 'inputSchema' => input, 'outputSchema' => output }], 'ttlMs' => 0 }
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

    # Two calls of one tool recovering at once each retry under the
    # definition their own refresh read: a pin shared between them would
    # send both retries under one of the two.
    it 'pins each overlapping retry to the definition its own refresh read' do
      retries = Queue.new
      rejections = Queue.new
      refreshes = 0
      lock = Mutex.new
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover'
          json_response(body['id'], { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                      'capabilities' => { 'tools' => {} } })
        when 'tools/list'
          n = lock.synchronize { refreshes += 1 }
          json_response(body['id'], listing(n == 1 ? 'Region' : "H#{n}"))
        when 'tools/call'
          mirrored = request.headers.select { |k, _| k.start_with?('Mcp-Param-') }
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
