# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

# MCP 2026-07-28 x-mcp-header: regression suite.
#
# These examples were written one adversarial review round at a time, each
# pinning a defect that round found. They are gathered here by subject
# rather than by the round that produced them; the round is noted on each
# section only because the review notes refer to it. Every example here
# covers production code no other spec reaches.

# --- round4 ----------------------------------------------------------------

# Review round 4 (codex, grok): the tools/list a modern tools/call reads
# first, to derive its Mcp-Param-* headers, is an exchange of its own with a
# recovery of its own -- its failures must not spend the call's; a value
# that starts with the Base64 marker and ends with its closer is
# sentinel-shaped even when the two overlap; and the argument-extraction
# and value-encoding edges the earlier tables left unpinned.
RSpec.shared_context 'with x-mcp-header round-4 helpers' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/mcp' }
  let(:url) { "#{base_url}#{endpoint}" }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def sse_response(messages)
    { status: 200, headers: { 'Content-Type' => 'text/event-stream' },
      body: messages.map { |m| "event: message\ndata: #{JSON.generate(m)}\n\n" }.join }
  end

  # A POST answered on an SSE stream that closes without ever carrying the
  # response: on a modern session that request is lost.
  def closed_stream
    sse_response([{ 'jsonrpc' => '2.0', 'method' => 'notifications/progress', 'params' => { 'progress' => 1 } }])
  end

  def modern_discover
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'resources' => {} } }
  end

  def header_mismatch(id, message = 'Header mismatch')
    { status: 400, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => -32_020, 'message' => message }) }
  end

  # A tools/list result with a freshness hint: on the cacheable-results
  # branch a modern list without one is read again by the next call.
  def fresh_tools(tools, **extra)
    { 'tools' => tools, 'ttlMs' => 60_000 }.merge(extra)
  end

  def annotated_tool(header = 'Region')
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => header } } } }
  end

  def param_headers(headers)
    headers.to_h.select { |k, _| k.to_s.downcase.start_with?('mcp-param-') }
  end

  def calls_in(requests)
    requests.select { |r| r[:body]['method'] == 'tools/call' }
  end

  # Serve the annotated tool, answering the nth tools/list with the nth entry
  # of +lists+ and the nth tools/call with the nth entry of +calls+ (a lambda
  # taking the request body, or :mismatch); anything past the end succeeds.
  def stub_sequence(lists: [], calls: [])
    requests = []
    counts = Hash.new(0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      requests << { headers: request.headers.to_h, body: body }
      method = body['method']
      counts[method] += 1
      answer = { 'tools/list' => lists, 'tools/call' => calls }.fetch(method, [])[counts[method] - 1]
      if method == 'server/discover' then json_response(body['id'], modern_discover)
      elsif answer == :mismatch then header_mismatch(body['id'], 'Mcp-Param-Zone missing')
      elsif answer then answer.call(body)
      elsif method == 'tools/list' then json_response(body['id'], fresh_tools([annotated_tool]))
      else json_response(body['id'], { 'content' => [] })
      end
    end
    requests
  end

  let(:closed) { ->(_body) { closed_stream } }
end

RSpec.describe 'MCP 2026-07-28 x-mcp-header — the prerequisite tools/list has a recovery of its own' do
  include_context 'with x-mcp-header round-4 helpers'

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    context klass.name.split('::').last do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }

      after { server.cleanup }

      # The list re-issues itself once and is lost again: that is the list's
      # failure, and it surfaces. Spending the call's re-issue on it would
      # fetch a third list, send the call, and leave the call itself with no
      # re-issue when its own stream broke.
      it 'surfaces a prerequisite list lost twice instead of spending the call\'s re-issue on it' do
        requests = stub_sequence(lists: [closed, closed])

        expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }
          .to raise_error(MCPClient::Errors::ResponseStreamClosedError)

        expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover tools/list tools/list])
      end

      # A HeaderMismatch on tools/list is the list's own answer: there is no
      # tools/call to refresh for, and the refresh-and-retry-once must still
      # be available to the call that has not gone out yet.
      it 'surfaces a HeaderMismatch on the prerequisite list without spending the call\'s refresh' do
        requests = stub_sequence(lists: [:mismatch])

        expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }
          .to raise_error(MCPClient::Errors::HeaderMismatchError)

        expect(requests.map { |r| r[:body]['method'] }).to eq(%w[server/discover tools/list])
      end

      it 'keeps the call\'s own re-issue after the prerequisite list already used its own' do
        requests = stub_sequence(lists: [closed], calls: [closed])

        expect(server.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

        expect(requests.map { |r| r[:body]['method'] })
          .to eq(%w[server/discover tools/list tools/list tools/call tools/call])
        expect(calls_in(requests).map { |c| c[:body]['id'] }.uniq.size).to eq(2)
        expect(calls_in(requests).map { |c| param_headers(c[:headers]) })
          .to all(eq({ 'Mcp-Param-Region' => 'eu' }))
      end
    end
  end
end

RSpec.describe 'MCP 2026-07-28 x-mcp-header — value encoding edges' do
  include_context 'with x-mcp-header round-4 helpers'

  describe MCPClient::HeaderParams do
    # "=?base64?=" starts with the marker and ends with its closer; the two
    # overlap, and the spec's rule is on the start and the end, not on
    # something being between them.
    it 'encodes a value whose sentinel markers overlap' do
      expect(described_class.encode_header_value('=?base64?=')).to eq('=?base64?PT9iYXNlNjQ/PQ==?=')
    end

    it 'passes a value carrying only one of the two markers as-is' do
      expect(described_class.encode_header_value('=?base64?')).to eq('=?base64?')
      expect(described_class.encode_header_value('x?=')).to eq('x?=')
    end

    it 'encodes trailing-only whitespace, NUL and DEL, and keeps an interior tab' do
      expect(described_class.encode_header_value('a ')).to eq('=?base64?YSA=?=')
      expect(described_class.encode_header_value("a\0b")).to eq('=?base64?YQBi?=')
      expect(described_class.encode_header_value("a\x7Fb")).to eq('=?base64?YX9i?=')
      expect(described_class.encode_header_value("a\tb")).to eq("a\tb")
    end

    # Base64 in a header field is one line: the RFC 2045 wrapping every 60
    # bytes of input would put a raw LF into the field value.
    it 'emits one unwrapped line for a long value' do
      value = 'é' * 60
      encoded = described_class.encode_header_value(value)
      expect(encoded).to eq("=?base64?#{[value].pack('m0')}?=")
      expect(encoded).not_to match(/[\r\n]/)
      expect(encoded.length).to be > 100
    end
  end

  describe 'on the wire' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0) }

    after { server.cleanup }

    it 'escapes an overlapping sentinel in a mirrored argument and in Mcp-Name alike' do
      requests = stub_sequence
      server.call_tool('execute_sql', { 'region' => '=?base64?=' })
      server.read_resource('=?base64?=')

      expect(param_headers(calls_in(requests).first[:headers]))
        .to eq({ 'Mcp-Param-Region' => '=?base64?PT9iYXNlNjQ/PQ==?=' })
      read = requests.find { |r| r[:body]['method'] == 'resources/read' }
      expect(read[:headers]['Mcp-Name']).to eq('=?base64?PT9iYXNlNjQ/PQ==?=')
    end

    it 'sends a negative integer in decimal' do
      tool = { 'name' => 'n', 'inputSchema' => { 'type' => 'object',
                                                 'properties' => { 'n' => { 'type' => 'integer',
                                                                            'x-mcp-header' => 'N' } } } }
      requests = stub_sequence(lists: [->(body) { json_response(body['id'], fresh_tools([tool])) }])
      server.call_tool('n', { 'n' => -7 })

      expect(param_headers(calls_in(requests).first[:headers])).to eq({ 'Mcp-Param-N' => '-7' })
    end
  end
end

RSpec.describe 'MCP 2026-07-28 x-mcp-header — argument extraction edges' do
  describe MCPClient::HeaderParams do
    def schema(properties)
      { 'type' => 'object', 'properties' => properties }
    end

    let(:nested) do
      schema('db' => { 'type' => 'object',
                       'properties' => { 'tenant' => { 'type' => 'string', 'x-mcp-header' => 'Tenant' } } })
    end

    it 'omits the header when an intermediate object is absent, null or a scalar' do
      [{}, { 'db' => nil }, { 'db' => 'acme' }, { 'db' => ['acme'] }, { 'db' => 7 }].each do |args|
        expect(described_class.headers_for(nested, args)).to eq({}), args.inspect
      end
    end

    it 'reads a property name containing a dot or a slash literally' do
      input = schema('a.b' => { 'type' => 'string', 'x-mcp-header' => 'Dot' },
                     'c/d' => { 'type' => 'string', 'x-mcp-header' => 'Slash' })
      expect(described_class.headers_for(input, { 'a.b' => 'x', 'c/d' => 'y' }))
        .to eq({ 'Mcp-Param-Dot' => 'x', 'Mcp-Param-Slash' => 'y' })
      expect(described_class.headers_for(input, { 'a' => { 'b' => 'x' }, 'c' => { 'd' => 'y' } })).to eq({})
    end

    it 'extracts through a single-element type array' do
      input = schema('n' => { 'type' => ['integer'], 'x-mcp-header' => 'N' })
      expect(described_class.headers_for(input, { 'n' => 3 })).to eq({ 'Mcp-Param-N' => '3' })
    end

    # The JSON body serializes both keys, and which one the server reads is
    # its business: no header can agree with an argument that is two values.
    it 'rejects an argument given under both a String and a Symbol key with different values' do
      input = schema('region' => { 'type' => 'string', 'x-mcp-header' => 'Region' })
      expect { described_class.headers_for(input, { 'region' => 'eu', region: 'us' }) }
        .to raise_error(MCPClient::Errors::ValidationError, /both/)
      expect { described_class.headers_for(nested, { 'db' => { 'tenant' => 'a' }, db: { tenant: 'b' } }) }
        .to raise_error(MCPClient::Errors::ValidationError, /both/)
      expect(described_class.headers_for(input, { 'region' => 'eu', region: 'eu' }))
        .to eq({ 'Mcp-Param-Region' => 'eu' })
    end
  end
end

RSpec.describe 'MCP 2026-07-28 x-mcp-header — HeaderMismatch recovery edges' do
  include_context 'with x-mcp-header round-4 helpers'

  def invalid_tool
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'number', 'x-mcp-header' => 'Region' } } } }
  end

  [MCPClient::ServerHTTP, MCPClient::ServerStreamableHTTP].each do |klass|
    context klass.name.split('::').last do
      let(:log_output) { StringIO.new }
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0, logger: Logger.new(log_output)) }

      after { server.cleanup }

      # A host's raise_error middleware turns the 400 into a Faraday exception
      # before the transport sees the response; the rejection must still be
      # the typed one the recovery acts on.
      it 'recovers from a HeaderMismatch surfaced by configured raise_error middleware' do
        raising = klass.new(base_url: base_url, endpoint: endpoint, retries: 0,
                            faraday_config: ->(conn) { conn.response :raise_error })
        header = 'Region'
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << { headers: request.headers.to_h, body: body }
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          when 'tools/list' then json_response(body['id'], fresh_tools([annotated_tool(header)]))
          when 'tools/call'
            if request.headers['Mcp-Param-Zone']
              json_response(body['id'], { 'content' => [] })
            else
              header = 'Zone'
              header_mismatch(body['id'], 'Mcp-Param-Zone missing')
            end
          end
        end

        expect(raising.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

        expect(requests.map { |r| r[:body]['method'] })
          .to eq(%w[server/discover tools/list tools/call tools/list tools/call])
        expect(calls_in(requests).map { |c| param_headers(c[:headers]) })
          .to eq([{ 'Mcp-Param-Region' => 'eu' }, { 'Mcp-Param-Zone' => 'eu' }])
        raising.cleanup
      end

      # The refreshed definition is itself invalid: it is excluded from the
      # list (with the warning), so the retry carries no mirrored header --
      # and the server, not the client, decides whether the call succeeds.
      it 'retries without mirrored headers when the refreshed definition is invalid' do
        refreshed = false
        requests = stub_sequence(
          lists: [nil, ->(body) { json_response(body['id'], fresh_tools([invalid_tool])) }],
          calls: [lambda { |body|
            refreshed = true
            header_mismatch(body['id'], 'Mcp-Param-Region is not expected')
          }]
        )

        expect(server.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

        calls = calls_in(requests)
        expect(calls.size).to eq(2)
        expect(param_headers(calls[0][:headers])).to eq({ 'Mcp-Param-Region' => 'eu' })
        expect(param_headers(calls[1][:headers])).to be_empty
        expect(refreshed).to be(true)
        expect(log_output.string).to include('Rejecting tool "execute_sql"')
        expect(server.list_tools).to be_empty
      end

      it 'keeps the HeaderMismatch when the refresh fails on a later page' do
        refreshing = false
        pages = 0
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << { headers: request.headers.to_h, body: body }
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          when 'tools/list'
            if !refreshing
              json_response(body['id'], fresh_tools([annotated_tool]))
            elsif body['params']['cursor']
              pages += 1
              { status: 503, body: '' }
            else
              json_response(body['id'], fresh_tools([annotated_tool('Zone')], 'nextCursor' => 'page2'))
            end
          when 'tools/call'
            refreshing = true
            header_mismatch(body['id'], 'Mcp-Param-Zone missing')
          end
        end

        error = nil
        begin
          server.call_tool('execute_sql', { 'region' => 'eu' })
        rescue MCPClient::Errors::HeaderMismatchError => e
          error = e
        end

        expect(error).not_to be_nil
        expect(error.message).to include('Mcp-Param-Zone missing')
        expect(error.message).not_to include('503')
        expect(pages).to eq(1)
        expect(calls_in(requests).size).to eq(1)
      end

      it 'returns the result when the refreshed list lacks the tool and the server answers the retry' do
        requests = stub_sequence(lists: [nil, ->(body) { json_response(body['id'], fresh_tools([])) }],
                                 calls: [:mismatch])

        expect(server.call_tool('execute_sql', { 'region' => 'eu' })).to eq({ 'content' => [] })

        calls = calls_in(requests)
        expect(calls.size).to eq(2)
        expect(param_headers(calls[0][:headers])).to eq({ 'Mcp-Param-Region' => 'eu' })
        expect(param_headers(calls[1][:headers])).to be_empty
      end

      it 'drops a tool with an invalid annotation from tools/list, with a warning naming it' do
        listed = [invalid_tool, annotated_tool('Zone').merge('name' => 'ok')]
        stub_sequence(lists: [->(body) { json_response(body['id'], { 'tools' => listed }) }])

        expect(server.list_tools.map(&:name)).to eq(['ok'])
        expect(log_output.string).to include('Rejecting tool "execute_sql"').and include('primitive')
      end

      it 'drops a tool with an invalid annotation that only appears on a later page of tools/list' do
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << body['method']
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          when 'tools/list'
            if body['params']['cursor']
              json_response(body['id'], fresh_tools([invalid_tool, annotated_tool('Zone').merge('name' => 'ok')]))
            else
              json_response(body['id'], fresh_tools([{ 'name' => 'first', 'inputSchema' => { 'type' => 'object' } }],
                                                    'nextCursor' => 'page2'))
            end
          end
        end

        expect(server.list_tools.map(&:name)).to eq(%w[first ok])
        expect(requests.count('tools/list')).to eq(2)
        expect(log_output.string).to include('Rejecting tool "execute_sql"')
      end
    end
  end
end

RSpec.describe 'MCP 2026-07-28 x-mcp-header — the definition a modern call went out under' do
  include_context 'with x-mcp-header round-4 helpers'

  let(:list_changed) { { 'jsonrpc' => '2.0', 'method' => 'notifications/tools/list_changed', 'params' => {} } }

  def tool_with_output(output_schema)
    { 'name' => 'execute_sql',
      'inputSchema' => { 'type' => 'object',
                         'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' } } },
      'outputSchema' => output_schema }
  end

  def object_schema(property, required: true)
    schema = { 'type' => 'object', 'properties' => { property => { 'type' => 'boolean' } } }
    required ? schema.merge('required' => [property]) : schema
  end

  # A modern session whose tools/call answers on an SSE stream carrying a
  # list-change notification ahead of the result.
  def stub_modern_racing_server(listed)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      case body['method']
      when 'server/discover' then json_response(body['id'], modern_discover)
      when 'tools/list' then json_response(body['id'], fresh_tools([listed.call]))
      when 'tools/call'
        sse_response([list_changed,
                      { 'jsonrpc' => '2.0', 'id' => body['id'],
                        'result' => { 'content' => [], 'structuredContent' => { 'old' => true } } }])
      end
    end
  end

  def strict_client
    MCPClient::Client.new(
      mcp_server_configs: [MCPClient.streamable_http_config(base_url: base_url, endpoint: endpoint, retries: 0)],
      validate_structured_content: :strict
    )
  end

  it 'keeps the answering definition when a list-change notification races an ordinary modern call' do
    listed = tool_with_output(object_schema('old'))
    stub_modern_racing_server(-> { listed })
    client = strict_client
    client.on_notification do |_srv, method, _params|
      listed = tool_with_output(object_schema('new')) if method == 'notifications/tools/list_changed'
    end

    expect(client.call_tool('execute_sql', { 'region' => 'eu' })['structuredContent']).to eq({ 'old' => true })
    client.cleanup
  end

  it 'still rejects a result the answering definition forbids when the modern replacement is looser' do
    listed = tool_with_output(object_schema('missing'))
    stub_modern_racing_server(-> { listed })
    client = strict_client
    client.on_notification do |_srv, method, _params|
      listed = tool_with_output(object_schema('missing', required: false)) if method.end_with?('list_changed')
    end

    expect { client.call_tool('execute_sql', { 'region' => 'eu' }) }
      .to raise_error(MCPClient::Errors::ValidationError, /missing/)
    client.cleanup
  end
end

RSpec.describe 'MCP 2026-07-28 x-mcp-header — annotations beside a $ref' do
  # The reachability chain MUST NOT pass through $ref: an annotation that
  # sits in a $ref target is not a property of the tool, however the property
  # pointing at it is written. Reaching THIS annotation traverses `properties`
  # alone -- the reference only says what the property's type is, which
  # JSON Schema 2020-12 evaluates beside its siblings -- so the tool stays in
  # the list. See round 6 for the type resolution itself.
  it 'keeps a tool whose annotated property declares its type behind a local $ref' do
    input = { 'type' => 'object',
              '$defs' => { 'r' => { 'type' => 'string' } },
              'properties' => { 'region' => { '$ref' => '#/$defs/r', 'x-mcp-header' => 'Region' } } }
    expect(MCPClient::HeaderParams.validate_schema(input)).to eq([])
    expect(MCPClient::HeaderParams.annotations(input)).to eq([[['region'], 'Region']])
  end

  it 'excludes a tool whose annotation itself sits behind a $ref' do
    input = { 'type' => 'object',
              '$defs' => { 'r' => { 'type' => 'string', 'x-mcp-header' => 'Region' } },
              'properties' => { 'region' => { '$ref' => '#/$defs/r' } } }
    expect(MCPClient::HeaderParams.validate_schema(input)).to include(match(/statically reachable/))
    expect(MCPClient::HeaderParams.annotations(input)).to eq([])
  end
end

# The list_changed invalidation this PR added covers prompts and resources
# too, and like the tool cache before round 2, a fetch that was already in
# flight when the notification landed must not put its stale list back.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — stale prompt and resource fetches racing list_changed' do
  include_context 'with x-mcp-header round-4 helpers'

  def full_discover
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'prompts' => {}, 'resources' => {} } }
  end

  # Serve numbered prompt and resource lists, holding the first +held+
  # response open until released.
  def stub_held_lists(held, in_flight, release)
    counts = Hash.new(0)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      method = body['method']
      counts[method] += 1
      n = counts[method]
      if method == held && n == 1
        in_flight << true
        release.pop(timeout: 5)
      end
      case method
      when 'server/discover' then json_response(body['id'], full_discover)
      when 'prompts/list' then json_response(body['id'], { 'prompts' => [{ 'name' => "p#{n}" }] })
      when 'resources/list'
        json_response(body['id'], { 'resources' => [{ 'uri' => "file:///r#{n}", 'name' => "r#{n}" }] })
      end
    end
  end

  { MCPClient::ServerHTTP => :dispatch_sse_message,
    MCPClient::ServerStreamableHTTP => :dispatch_server_message }.each do |klass, dispatcher|
    context klass.name.split('::').last do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0) }

      after { server.cleanup }

      def notify(server, dispatcher, method)
        server.send(dispatcher, { 'jsonrpc' => '2.0', 'method' => method, 'params' => {} })
      end

      it 'does not let a stale in-flight prompts/list overwrite an invalidated prompt cache' do
        in_flight = Queue.new
        release = Queue.new
        stub_held_lists('prompts/list', in_flight, release)
        server.connect

        stale = Thread.new { server.list_prompts }
        expect(in_flight.pop(timeout: 5)).not_to be_nil
        notify(server, dispatcher, 'notifications/prompts/list_changed')
        release << true

        # The caller that was already waiting is answered with the list its
        # own fetch obtained -- returned, but never put back into the cache
        # the notification emptied.
        expect(stale.join(5)).not_to be_nil
        expect(stale.value.map(&:name)).to eq(['p1'])
        expect(server.list_prompts.map(&:name)).to eq(['p2'])
      end

      it 'does not let a stale in-flight resources/list overwrite an invalidated resource cache' do
        in_flight = Queue.new
        release = Queue.new
        stub_held_lists('resources/list', in_flight, release)
        server.connect

        stale = Thread.new { server.list_resources }
        expect(in_flight.pop(timeout: 5)).not_to be_nil
        notify(server, dispatcher, 'notifications/resources/list_changed')
        release << true

        expect(stale.join(5)).not_to be_nil
        expect(stale.value['resources'].map(&:name)).to eq(['r1'])
        expect(server.list_resources['resources'].map(&:name)).to eq(['r2'])
      end
    end
  end
end

# --- round6 ----------------------------------------------------------------

# Review round 6 (codex, grok): a property whose primitive type is written
# through a local $ref is a primitive property, and a refresh that fails
# still has to leave the host's own cache dropped.
RSpec.describe 'MCP 2026-07-28 x-mcp-header — round 6' do
  let(:base_url) { 'https://example.com' }
  let(:endpoint) { '/mcp' }
  let(:url) { "#{base_url}#{endpoint}" }
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }

  def json_response(id, result)
    { status: 200, body: JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result),
      headers: { 'Content-Type' => 'application/json' } }
  end

  def modern_discover
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {} } }
  end

  def header_mismatch(id)
    { status: 400, headers: { 'Content-Type' => 'application/json' },
      body: JSON.generate('jsonrpc' => '2.0', 'id' => id,
                          'error' => { 'code' => -32_020, 'message' => 'Header mismatch' }) }
  end

  # ---------------------------------------------------------------------------
  # A property typed through a local $ref
  #
  # The reachability chain MUST NOT pass through $ref -- an annotation inside
  # $defs is not a property of the tool -- but that is a rule about where the
  # ANNOTATION sits, not about how the property's type is spelled. JSON Schema
  # 2020-12 evaluates $ref beside its siblings (Core 8.2.3.1), so
  # `{"$ref": "#/$defs/r", "x-mcp-header": "Region"}` under `properties` is a
  # directly reachable property whose type the document states.
  describe MCPClient::HeaderParams do
    def local_ref_schema(target = { 'type' => 'string' })
      { 'type' => 'object',
        '$defs' => { 'r' => target },
        'properties' => { 'region' => { '$ref' => '#/$defs/r', 'x-mcp-header' => 'Region' } } }
    end

    it 'accepts a property whose primitive type is stated through a local $ref' do
      expect(MCPClient::HeaderParams.validate_schema(local_ref_schema)).to eq([])
      expect(MCPClient::HeaderParams.annotations(local_ref_schema)).to eq([[['region'], 'Region']])
    end

    it 'follows a chain of local $refs, and the pointer escapes in their names' do
      schema = { 'type' => 'object',
                 '$defs' => { 'a/b' => { '$ref' => '#/$defs/c~d' }, 'c~d' => { 'type' => 'integer' } },
                 'properties' => { 'n' => { '$ref' => '#/$defs/a~1b', 'x-mcp-header' => 'N' } } }

      expect(MCPClient::HeaderParams.validate_schema(schema)).to eq([])
      expect(MCPClient::HeaderParams.annotations(schema)).to eq([[['n'], 'N']])
    end

    it 'still refuses a $ref target that is not a primitive type' do
      errors = MCPClient::HeaderParams.validate_schema(local_ref_schema({ 'type' => 'object' }))

      expect(errors).to include(match(/primitive/))
      expect(MCPClient::HeaderParams.annotations(local_ref_schema({ 'type' => 'object' }))).to eq([])
    end

    it 'refuses a $ref this client cannot resolve: external, unknown or cyclic' do
      external = { 'type' => 'object',
                   'properties' => { 'region' => { '$ref' => 'https://example.com/r', 'x-mcp-header' => 'R' } } }
      unknown = { 'type' => 'object', '$defs' => {},
                  'properties' => { 'region' => { '$ref' => '#/$defs/missing', 'x-mcp-header' => 'R' } } }
      cyclic = { 'type' => 'object',
                 '$defs' => { 'a' => { '$ref' => '#/$defs/b' }, 'b' => { '$ref' => '#/$defs/a' } },
                 'properties' => { 'region' => { '$ref' => '#/$defs/a', 'x-mcp-header' => 'R' } } }

      [external, unknown, cyclic].each do |schema|
        expect(MCPClient::HeaderParams.validate_schema(schema)).to include(match(/primitive/)), schema.inspect
      end
    end

    it 'keeps the annotation itself out of a $ref target' do
      # The annotation sits in $defs, so it is not reachable through
      # properties keys however the property is written.
      schema = { 'type' => 'object',
                 '$defs' => { 'r' => { 'type' => 'string', 'x-mcp-header' => 'Region' } },
                 'properties' => { 'region' => { '$ref' => '#/$defs/r' } } }

      expect(MCPClient::HeaderParams.validate_schema(schema)).to include(match(/statically reachable/))
      expect(MCPClient::HeaderParams.annotations(schema)).to eq([])
    end

    it 'reads a sibling type in preference to the reference' do
      schema = { 'type' => 'object',
                 '$defs' => { 'r' => { 'type' => 'object' } },
                 'properties' => { 'region' => { '$ref' => '#/$defs/r', 'type' => 'string',
                                                 'x-mcp-header' => 'Region' } } }

      expect(MCPClient::HeaderParams.validate_schema(schema)).to eq([])
    end
  end

  # The wire consequence: the tool stays in the list and its argument is
  # mirrored, on both HTTP transports.
  [MCPClient::ServerStreamableHTTP, MCPClient::ServerHTTP].each do |klass|
    context "with #{klass}" do
      let(:server) { klass.new(base_url: base_url, endpoint: endpoint, retries: 0, logger: logger) }

      after { server.cleanup }

      it 'lists a tool typed through a local $ref and mirrors its argument' do
        schema = { 'type' => 'object',
                   '$defs' => { 'r' => { 'type' => 'string' } },
                   'properties' => { 'region' => { '$ref' => '#/$defs/r', 'x-mcp-header' => 'Region' } } }
        requests = []
        stub_request(:post, url).to_return do |request|
          body = JSON.parse(request.body)
          requests << { method: body['method'], headers: request.headers }
          case body['method']
          when 'server/discover' then json_response(body['id'], modern_discover)
          when 'tools/list' then json_response(body['id'], { 'tools' => [{ 'name' => 't', 'inputSchema' => schema }] })
          else json_response(body['id'], { 'content' => [] })
          end
        end

        expect(server.list_tools.map(&:name)).to eq(['t'])
        server.call_tool('t', { 'region' => 'eu' })

        expect(requests.last[:headers]['Mcp-Param-Region']).to eq('eu')
      end
    end
  end

  # ---------------------------------------------------------------------------
  # A refresh that fails still drops the host's cache
  #
  # refresh_tools_cache invalidates the transport's own list first, so once it
  # has run the transport will re-fetch whatever the caller asks for next. The
  # host above it (MCPClient::Client) keeps its own copy, and learns of the
  # change only from the announcement -- which must therefore survive a
  # refresh that could not complete, or the host goes on calling with
  # definitions this transport has already thrown away.
  describe 'the announcement of a failed refresh' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, logger: logger) }

    after { server.cleanup }

    def stub_failing_refresh
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list'
          lists += 1
          if lists == 1
            json_response(body['id'], { 'tools' => [{ 'name' => 'execute_sql', 'inputSchema' => {
                            'type' => 'object',
                            'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' } }
                          } }] })
          else
            { status: 503, body: '' }
          end
        else header_mismatch(body['id'])
        end
      end
    end

    it 'announces the invalidation even when the re-fetch fails' do
      stub_failing_refresh
      announced = []
      server.on_notification { |method, params| announced << [method, params] }

      expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }
        .to raise_error(MCPClient::Errors::HeaderMismatchError)

      expect(announced).to include(['notifications/tools/list_changed', {}])
    end

    it 'keeps the HeaderMismatch when the announcement itself raises' do
      stub_failing_refresh
      server.on_notification { |_method, _params| raise 'host listener exploded' }

      expect { server.call_tool('execute_sql', { 'region' => 'eu' }) }
        .to raise_error(MCPClient::Errors::HeaderMismatchError)
    end
  end

  # ---------------------------------------------------------------------------
  # What a retry carries
  describe 'the retry after a refresh' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, logger: logger) }

    after { server.cleanup }

    # The headers are recomputed from the refreshed definition, but the body
    # is the caller's own params re-sent -- not a reconstruction from the
    # arguments. Fields this branch never reads (the multi round-trip
    # requestState/inputResponses and the tasks extension's task parameters
    # arrive on later branches) have to survive it for the same reason.
    it 'resends the params it was given and recomputes only the headers' do
      bodies = []
      headers = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list'
          annotation = bodies.empty? ? 'Region' : 'Zone'
          json_response(body['id'], { 'tools' => [{ 'name' => 'execute_sql', 'inputSchema' => {
                          'type' => 'object',
                          'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => annotation } }
                        } }] })
        else
          bodies << body
          headers << request.headers.to_h
          bodies.size == 1 ? header_mismatch(body['id']) : json_response(body['id'], { 'content' => [] })
        end
      end

      params = { 'name' => 'execute_sql', 'arguments' => { 'region' => 'eu' },
                 'requestState' => 'continue-later',
                 'inputResponses' => { 'consent' => { 'action' => 'accept' } },
                 'task' => { 'taskId' => 't-1' },
                 '_meta' => { 'io.example/trace' => 'abc' } }
      server.rpc_request('tools/call', params)

      expect(bodies.size).to eq(2)
      # Everything but the id is the request the caller made, both times.
      expect(bodies.last['params']).to eq(bodies.first['params'])
      expect(bodies.last['params']).to include(
        'requestState' => 'continue-later',
        'inputResponses' => { 'consent' => { 'action' => 'accept' } },
        'task' => { 'taskId' => 't-1' }
      )
      # The headers are the only thing the refresh changed.
      expect(headers.first['Mcp-Param-Region']).to eq('eu')
      expect(headers.last['Mcp-Param-Zone']).to eq('eu')
      expect(headers.last).not_to have_key('Mcp-Param-Region')
    end
  end

  # ---------------------------------------------------------------------------
  # Two servers offering the same tool name
  describe 'a refresh on one server while another server\'s call is in flight' do
    let(:other_url) { 'https://other.example.com/mcp' }

    def tool_named(annotation)
      { 'name' => 't', 'inputSchema' => { 'type' => 'object',
                                          'properties' => { 'region' => { 'type' => 'string',
                                                                          'x-mcp-header' => annotation } } } }
    end

    # The definition a call goes out under is the one its own transport
    # recorded: a refresh driven by one server's rejection must not reach
    # into the headers another server's call already computed, nor into the
    # definition its result is validated against.
    it 'leaves the other call its own annotation' do
      arrived = Queue.new
      release = Queue.new
      other_requests = []
      stub_request(:post, other_url).to_return do |request|
        body = JSON.parse(request.body)
        other_requests << { headers: request.headers.to_h, body: body }
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list'
          # Held here, before this call derives its headers: the other
          # server's whole refresh happens in between, so a derivation that
          # read anything but this transport's own list would pick up its
          # annotation instead.
          arrived << true
          release.pop(timeout: 5)
          json_response(body['id'], { 'tools' => [tool_named('Tenant')] })
        else json_response(body['id'], { 'content' => [{ 'type' => 'text', 'text' => 'other' }] })
        end
      end

      main_requests = []
      lists = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        main_requests << { headers: request.headers.to_h, body: body }
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list'
          lists += 1
          json_response(body['id'], { 'tools' => [tool_named(lists == 1 ? 'Region' : 'Zone')] })
        else
          if request.headers['Mcp-Param-Zone']
            json_response(body['id'], { 'content' => [] })
          else
            header_mismatch(body['id'])
          end
        end
      end

      other = MCPClient::ServerStreamableHTTP.new(base_url: 'https://other.example.com', endpoint: '/mcp',
                                                  retries: 0, logger: logger)
      main = MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, logger: logger)
      begin
        held = Thread.new { other.call_tool('t', { 'region' => 'eu' }) }
        expect(arrived.pop(timeout: 5)).not_to be_nil

        # The other server's call is on the wire, its headers already
        # computed, while this one refreshes and retries.
        main.call_tool('t', { 'region' => 'eu' })
        release << true

        expect(held.join(5)).not_to be_nil
        expect(held.value['content'].first['text']).to eq('other')
      ensure
        release << true
        other.cleanup
        main.cleanup
      end

      other_call = other_requests.find { |r| r[:body]['method'] == 'tools/call' }
      expect(other_call[:headers]).to include('Mcp-Param-Tenant' => 'eu')
      expect(other_call[:headers].keys.map(&:downcase)).not_to include('mcp-param-zone', 'mcp-param-region')

      main_calls = main_requests.select { |r| r[:body]['method'] == 'tools/call' }
      expect(main_calls.size).to eq(2)
      expect(main_calls.last[:headers]).to include('Mcp-Param-Zone' => 'eu')
    end
  end

  # ---------------------------------------------------------------------------
  # An integral Float argument
  #
  # A JSON number parsed as 42.0 is mirrored as the integer it is, while the
  # body carries the Float it arrived as. The spec tells servers to compare
  # integers numerically, so the two agree; pinned because the asymmetry is
  # only visible on the wire.
  describe 'an integral Float argument' do
    let(:server) { MCPClient::ServerStreamableHTTP.new(base_url: base_url, endpoint: endpoint, retries: 0, logger: logger) }

    after { server.cleanup }

    it 'mirrors the integer while the body keeps the number as written' do
      sent = nil
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body, symbolize_names: false)
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list'
          json_response(body['id'], { 'tools' => [{ 'name' => 't', 'inputSchema' => {
                          'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer', 'x-mcp-header' => 'N' } }
                        } }] })
        else
          sent = { raw: request.body, headers: request.headers.to_h }
          json_response(body['id'], { 'content' => [] })
        end
      end

      server.call_tool('t', { 'n' => 42.0 })

      expect(sent[:headers]['Mcp-Param-N']).to eq('42')
      expect(sent[:raw]).to include('42.0')
    end
  end

  # The host-level consequence: a client whose refresh failed must not go on
  # serving the definition the transport already dropped.
  describe 'a host above a transport whose refresh failed' do
    it 'serves the recovered definition once the server answers again' do
      lists = 0
      calls = []
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        calls << body['method']
        case body['method']
        when 'server/discover' then json_response(body['id'], modern_discover)
        when 'tools/list'
          lists += 1
          case lists
          when 1
            json_response(body['id'], { 'tools' => [{ 'name' => 'execute_sql', 'inputSchema' => {
                            'type' => 'object', 'required' => ['old'],
                            'properties' => { 'old' => { 'type' => 'string', 'x-mcp-header' => 'Region' } }
                          } }] })
          when 2 then { status: 503, body: '' }
          else
            json_response(body['id'], { 'tools' => [{ 'name' => 'execute_sql', 'inputSchema' => {
                            'type' => 'object', 'required' => ['new'],
                            'properties' => { 'new' => { 'type' => 'string', 'x-mcp-header' => 'Zone' } }
                          } }] })
          end
        else header_mismatch(body['id'])
        end
      end

      client = MCPClient::Client.new(
        mcp_server_configs: [{ type: 'streamable_http', base_url: base_url, endpoint: endpoint, retries: 0 }],
        logger: logger
      )
      begin
        expect(client.list_tools.first.schema['required']).to eq(['old'])

        expect { client.call_tool('execute_sql', { 'old' => 'eu' }) }
          .to raise_error(MCPClient::Errors::HeaderMismatchError)

        # The server has recovered by now; the host must ask again rather than
        # answer from the copy the transport already invalidated.
        expect(client.list_tools.first.schema['required']).to eq(['new'])
      ensure
        client.cleanup
      end
    end
  end
end
