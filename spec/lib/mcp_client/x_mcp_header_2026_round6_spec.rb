# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'

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
