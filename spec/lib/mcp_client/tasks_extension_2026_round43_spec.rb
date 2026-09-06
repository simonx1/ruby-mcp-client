# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# MCP 2026-07-28 tasks extension, review round 43: a replaced stdio process is
# not the end of a session on a stateless 2026-07-28 peer (a task it holds
# outlives the connection, as it does over HTTP), a retransmitted update
# carries only the answers the task still asks for, and a transport that
# reports no session keeps its bookkeeping in one place.
RSpec.describe 'MCP 2026-07-28 tasks extension — round 43' do
  def detailed_task(status:, id: 'task-1', poll_ms: 1, **extra)
    now = Time.now.utc.iso8601
    { 'resultType' => 'complete', 'taskId' => id, 'status' => status, 'createdAt' => now,
      'lastUpdatedAt' => now, 'ttlMs' => 60_000, 'pollIntervalMs' => poll_ms }.merge(extra)
  end

  def call_result(text = 'done')
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => false }
  end

  def elicit_request(name = 'n')
    { 'method' => 'elicitation/create',
      'params' => { 'mode' => 'form', 'message' => "#{name}?",
                    'requestedSchema' => { 'type' => 'object', 'properties' => { name => { 'type' => 'string' } } } } }
  end

  def client_for(server, **opts)
    allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
    client = MCPClient::Client.new(mcp_server_configs: [{ type: 'stdio', command: 'x' }], extensions: [TASKS_EXT],
                                   **opts)
    allow(client).to receive(:sleep)
    client
  end

  def discover_result
    { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
      'capabilities' => { 'tools' => {}, 'extensions' => { TASKS_EXT => {} } } }
  end

  # The stdio transport driven at the wire: every request it writes is
  # recorded, and each method is answered from its own queue (a Proc raises
  # or returns). Its own handlers fulfil the input requests a task raises.
  def scripted(server, script)
    sent = []
    script = { 'server/discover' => [discover_result] }.merge(script)
    allow(server).to receive(:connect).and_return(true)
    allow(server).to receive(:start_reader)
    allow(server).to receive(:start_stderr_reader)
    server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    # The wire shape: what send_request would serialize.
    allow(server).to receive(:send_request) { |req, *_rest, **_opts| sent << JSON.parse(JSON.generate(req)) }
    allow(server).to receive(:wait_response) do |id, **_opts|
      method = sent.last['method']
      queue = script.fetch(method) { raise "no script for #{method}" }
      answer = queue.size == 1 && method == 'server/discover' ? queue.first : queue.shift
      raise "no scripted answer left for #{method}" if answer.nil?

      answer = answer.call(method, sent.last['params']) if answer.respond_to?(:call)
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => answer }
    end
    sent
  end

  def update_keys(sent)
    sent.select { |req| req['method'] == 'tasks/update' }
        .map { |req| (req['params']['inputResponses'] || req['params'][:inputResponses]).keys.map(&:to_s) }
  end

  describe 'a replaced stdio process on a 2026-07-28 peer' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    def connected(server, version:, initialized: true)
      server.instance_variable_set(:@protocol_version, version)
      server.instance_variable_set(:@initialized, initialized)
      server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
    end

    it 'leaves the session epoch alone: a stateless peer holds no session a cleanup could end' do
      connected(stdio, version: '2026-07-28')
      epoch = stdio.session_epoch

      stdio.cleanup

      expect(stdio.session_epoch).to eq(epoch)
    end

    it 'still ends the session a 2025-11-25 handshake opened' do
      connected(stdio, version: '2025-11-25')
      epoch = stdio.session_epoch

      stdio.cleanup

      expect(stdio.session_epoch).to be > epoch
    end

    it 'forgets the task bookkeeping of the session a 2025-11-25 handshake opened' do
      client = client_for(stdio)
      connected(stdio, version: '2025-11-25')
      client.send(:remember_answered_keys, stdio, 'task-1', ['k1'])

      stdio.cleanup

      expect(stdio.session_epoch).to eq(1)
      expect(client.send(:answered_task_keys, stdio, 'task-1')).to be_empty
    end

    it 'ends no session on a process that never completed a handshake' do
      connected(stdio, version: nil, initialized: false)
      epoch = stdio.session_epoch

      stdio.cleanup

      expect(stdio.session_epoch).to eq(epoch)
    end

    describe 'a durable task, driven by a real child process' do
      # A 2026-07-28 stdio server fronting a job store that outlives it: the
      # task it creates is recorded in a file, and the process that replaces
      # it answers tasks/get from that file.
      def stdio_server_source
        <<~RUBY
          require 'json'
          $stdout.sync = true
          store = ENV.fetch('MCP_SPEC_STORE')
          generation = (File.exist?("\#{store}.gen") ? File.read("\#{store}.gen").to_i : 0) + 1
          File.write("\#{store}.gen", generation.to_s)
          tasks_ext = 'io.modelcontextprotocol/tasks'
          now = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
          stamp = { 'createdAt' => now, 'lastUpdatedAt' => now, 'ttlMs' => 60_000, 'pollIntervalMs' => 1 }
          answer = ->(id, result) { $stdout.puts(JSON.generate('jsonrpc' => '2.0', 'id' => id, 'result' => result)) }

          $stdin.each_line do |line|
            begin
              message = JSON.parse(line)
            rescue JSON::ParserError
              next
            end
            id = message['id']
            case message['method']
            when 'server/discover'
              answer.call(id, { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
                                'capabilities' => { 'tools' => {}, 'extensions' => { tasks_ext => {} } } })
            when 'tools/list'
              answer.call(id, { 'resultType' => 'complete', 'ttlMs' => 60_000,
                                'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' } }] })
            when 'tools/call'
              File.write(store, JSON.generate('status' => 'working', 'polls' => 0, 'generation' => generation))
              answer.call(id, { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working' }.merge(stamp))
            when 'tasks/get'
              task = File.exist?(store) ? JSON.parse(File.read(store)) : nil
              if task.nil?
                $stdout.puts(JSON.generate('jsonrpc' => '2.0', 'id' => id,
                                           'error' => { 'code' => -32_602, 'message' => 'no such task' }))
              else
                task['polls'] += 1
                task['status'] = 'completed' if task['polls'] >= 2
                File.write(store, JSON.generate(task))
                result = { 'resultType' => 'complete', 'taskId' => 'task-1', 'status' => task['status'],
                           'servedBy' => generation }.merge(stamp)
                if task['status'] == 'completed'
                  # The generation travels in the payload the client hands
                  # back, so the example can name the process that served the
                  # task without depending on a field Task#to_h drops.
                  result['result'] = { 'content' => [{ 'type' => 'text', 'text' => "done by \#{generation}" }],
                                       'isError' => false }
                end
                answer.call(id, result)
              end
            end
          end
        RUBY
      end

      let(:workdir) { Dir.mktmpdir('mcp-round43') }
      let(:script) { File.join(workdir, 'server.rb') }
      let(:store) { File.join(workdir, 'task') }
      let(:server) do
        MCPClient::ServerStdio.new(command: [RbConfig.ruby, script], read_timeout: 5, discover_timeout: 5,
                                   env: { 'MCP_SPEC_STORE' => store })
      end

      before { File.write(script, stdio_server_source) }

      after do
        server.cleanup
      rescue StandardError
        nil
      ensure
        FileUtils.remove_entry(workdir)
      end

      it 'is still the handle\'s task after the process was replaced' do
        client = client_for(server)
        handle = client.call_tool_as_task('slow', {})
        expect(handle).to be_working

        server.cleanup

        # The next request negotiates a replacement process; the task is
        # asked about there, not refused as belonging to an ended session.
        finished = client.wait_for_task(handle, timeout: 10)
        expect(finished).to be_completed
        # The replacement process served it: its generation is in the payload
        # the client handed back, asserted unconditionally.
        expect(finished.result).to eq(call_result('done by 2'))
        expect(File.read("#{store}.gen").to_i).to eq(2)
      end
    end
  end

  describe 'a retransmitted update' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:lost) { ->(_method, _params) { raise MCPClient::Errors::TransportError, 'acknowledgement lost' } }
    let(:ask_k1) { detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => elicit_request('a') }) }
    let(:ask_k2) { detailed_task(status: 'input_required', 'inputRequests' => { 'k2' => elicit_request('b') }) }
    let(:done) { detailed_task(status: 'completed', 'result' => call_result) }

    def answering_client(asked)
      client_for(stdio, elicitation_handler: lambda { |message, _schema|
        asked << message
        { action: 'accept', content: { 'n' => 'x' } }
      })
    end

    it 'carries nothing once the task no longer asks for the answer the server consumed' do
      asked = []
      client = answering_client(asked)
      calls = scripted(stdio, 'tasks/get' => [ask_k1, detailed_task(status: 'working'), done], 'tasks/update' => [lost])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(asked.size).to eq(1)
      expect(update_keys(calls)).to eq([['k1']])
    end

    it 'carries only the answers to the requests the task still lists' do
      asked = []
      client = answering_client(asked)
      calls = scripted(stdio, 'tasks/get' => [ask_k1, ask_k2, done], 'tasks/update' => [lost, {}])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(asked.size).to eq(2)
      expect(update_keys(calls)).to eq([['k1'], ['k2']])
    end

    it 'still resends an answer the task keeps asking for, without asking the host again' do
      asked = []
      client = answering_client(asked)
      calls = scripted(stdio, 'tasks/get' => [ask_k1, ask_k1, done], 'tasks/update' => [lost, {}])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(asked.size).to eq(1)
      expect(update_keys(calls)).to eq([['k1'], ['k1']])
    end
  end

  describe 'a transport that reports no session' do
    # The stdio transport with its session surface removed: what a
    # third-party transport implementing the documented interface and
    # nothing else looks like to the task registry.
    let(:sessionless) do
      Class.new(MCPClient::ServerStdio) do
        undef_method :session_epoch
        undef_method :pinned_to_session
      end.new(command: 'echo test', read_timeout: 1)
    end

    it 'takes one explicit update after another and is then waited on' do
      client = client_for(sessionless)
      calls = scripted(sessionless, 'tasks/update' => [{}, {}],
                                    'tasks/get' => [detailed_task(status: 'completed', 'result' => call_result)])
      expect(sessionless).not_to respond_to(:session_epoch)

      client.update_task('task-1', { 'k1' => { 'action' => 'accept', 'content' => { 'n' => 'x' } } })
      expect do
        client.update_task('task-1', { 'k2' => { 'action' => 'accept', 'content' => { 'n' => 'y' } } })
      end.not_to raise_error

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed
      expect(update_keys(calls)).to eq([['k1'], ['k2']])
      expect(calls.map { |req| req['method'] }).to eq(%w[server/discover tasks/update tasks/update tasks/get])
    end
  end

  describe 'a completed handle a host persisted' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }

    it 'hands back its serialized result without asking a server that may have purged the task' do
      client = client_for(stdio)
      sent = scripted(stdio, 'tasks/get' => [detailed_task(status: 'completed', 'result' => call_result('kept'))])
      finished = client.wait_for_task('task-1', timeout: 5)

      # What the README shows: the handle's hash, persisted and read back.
      restored = MCPClient::Task.from_json(JSON.parse(JSON.generate(finished.to_h)), server: stdio)

      expect(restored).to be_detailed
      expect(client.get_task_result(restored)).to eq(call_result('kept'))
      expect(sent.count { |req| req['method'] == 'tasks/get' }).to eq(1)
    end

    it 'still treats a persisted CreateTaskResult as the seed it is' do
      created = MCPClient::Task.from_create_result(
        { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working', 'ttlMs' => 1000 }, server: stdio
      )

      expect(MCPClient::Task.from_json(created.to_h, server: stdio)).not_to be_detailed
    end
  end

  describe 'the input a 2026-07-28 task asks for' do
    let(:stdio) { MCPClient::ServerStdio.new(command: 'echo test', read_timeout: 1) }
    let(:done) { detailed_task(status: 'completed', 'result' => call_result) }

    def url_request
      { 'method' => 'elicitation/create',
        'params' => { 'mode' => 'url', 'message' => 'Sign in', 'url' => 'https://consent.example.com/session/1' } }
    end

    it 'runs a URL-mode elicitation through tasks/update, handing the host no 2025 field' do
      seen = []
      client = client_for(stdio, elicitation_handler: lambda { |message, details|
        seen << [message, details]
        { action: 'accept' }
      })
      asks = detailed_task(status: 'input_required', 'inputRequests' => { 'consent' => url_request })
      sent = scripted(stdio, 'tasks/get' => [asks, done], 'tasks/update' => [{}])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(seen).to eq([['Sign in', { 'mode' => 'url', 'url' => 'https://consent.example.com/session/1' }]])
      update = sent.find { |req| req['method'] == 'tasks/update' }
      expect(update['params']['inputResponses']).to eq({ 'consent' => { 'action' => 'accept' } })
    end

    # The session here is 2026-07-28 (it answers server/discover), and the
    # deprecations branch removed elicitationId from the modern URL-mode host
    # contract: a modern server that sends the field anyway cannot smuggle a
    # correlation id to the host through it, and the client names the field in
    # one warning without quoting its value. The 2025-11-25 contract, key
    # present and all, is pinned on that branch.
    it 'keeps a modern server from smuggling an elicitationId to the host' do
      seen = []
      logger = instance_double(Logger, warn: nil, info: nil, debug: nil, error: nil, :level= => nil)
      client = client_for(stdio, elicitation_handler: lambda { |_message, details|
        seen << details
        { action: 'accept' }
      })
      client.instance_variable_set(:@logger, logger)
      request = url_request.merge('params' => url_request['params'].merge('elicitationId' => 'e-1'))
      asks = detailed_task(status: 'input_required', 'inputRequests' => { 'consent' => request })
      scripted(stdio, 'tasks/get' => [asks, done], 'tasks/update' => [{}])

      client.wait_for_task('task-1', timeout: 5)

      expect(seen.first).not_to have_key('elicitationId')
      expect(seen.first).to eq({ 'mode' => 'url', 'url' => 'https://consent.example.com/session/1' })
      expect(logger).to have_received(:warn).with(/elicitationId/).at_least(:once)
    end

    def sampling_request(tools: true)
      params = { 'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'hi' } }],
                 'maxTokens' => 10 }
      if tools
        params.merge!('tools' => [{ 'name' => 'lookup', 'inputSchema' => { 'type' => 'object' } }],
                      'toolChoice' => { 'mode' => 'auto' })
      end
      { 'method' => 'sampling/createMessage', 'params' => params }
    end

    it 'refuses a tool-enabled sampling request when sampling.tools was not declared, before any sampler runs' do
      sampled = []
      client = client_for(stdio, sampling_handler: lambda { |params|
        sampled << params
        raise 'not reached'
      })
      asks = detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => sampling_request })
      sent = scripted(stdio, 'tasks/get' => [asks])

      expect { client.wait_for_task('task-1', timeout: 5) }
        .to raise_error(MCPClient::Errors::InputRequiredError, /sampling\.tools/)
      expect(sampled).to be_empty
      expect(sent.map { |req| req['method'] }).not_to include('tasks/update')
    end

    it 'hands a declared sampler the tools and tool choice whole and sends its answer whole' do
      sampled = []
      answer = { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'call lookup' },
                 'model' => 'm-1', 'stopReason' => 'toolUse' }
      client = client_for(stdio, sampling_supports_tools: true,
                                 sampling_handler: lambda { |_messages, _prefs, _system, _max, params|
                                   sampled << params
                                   answer
                                 })
      asks = detailed_task(status: 'input_required', 'inputRequests' => { 'k1' => sampling_request })
      sent = scripted(stdio, 'tasks/get' => [asks, done], 'tasks/update' => [{}])

      expect(client.wait_for_task('task-1', timeout: 5)).to be_completed

      expect(sampled.first).to include('tools' => sampling_request['params']['tools'],
                                       'toolChoice' => { 'mode' => 'auto' }, 'maxTokens' => 10)
      update = sent.find { |req| req['method'] == 'tasks/update' }
      expect(update['params']['inputResponses']).to eq({ 'k1' => answer })
    end
  end

  describe 'a task created after a real HeaderMismatch recovery over Streamable HTTP' do
    let(:url) { 'http://tasks.example/mcp' }

    def charge_tool(required)
      { 'name' => 'charge',
        'inputSchema' => { 'type' => 'object',
                           'properties' => { 'region' => { 'type' => 'string', 'x-mcp-header' => 'Region' } } },
        'outputSchema' => { 'type' => 'object', 'properties' => { 'a' => { 'type' => 'integer' },
                                                                  'b' => { 'type' => 'integer' } },
                            'required' => required } }
    end

    def json_answer(id, result)
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { jsonrpc: '2.0', id: id, result: result }.to_json }
    end

    # The first call is rejected with HeaderMismatch; the list the client
    # refreshes in response carries a stricter outputSchema, and the retried
    # call is accepted as a task.
    def serving
      sent = []
      lists = 0
      calls = 0
      stub_request(:post, url).to_return do |request|
        body = JSON.parse(request.body)
        sent << [body['method'], request.headers['Mcp-Param-Region']]
        case body['method']
        when 'server/discover' then json_answer(body['id'], discover_result)
        when 'tools/list'
          lists += 1
          json_answer(body['id'], { 'resultType' => 'complete', 'ttlMs' => 60_000,
                                    'tools' => [charge_tool(lists == 1 ? ['a'] : %w[a b])] })
        when 'tools/call'
          calls += 1
          if calls == 1
            { status: 400, headers: { 'Content-Type' => 'application/json' },
              body: { jsonrpc: '2.0', id: body['id'],
                      error: { code: -32_020, message: 'Header mismatch' } }.to_json }
          else
            now = Time.now.utc.iso8601
            json_answer(body['id'], { 'resultType' => 'task', 'taskId' => 'task-1', 'status' => 'working',
                                      'createdAt' => now, 'lastUpdatedAt' => now, 'ttlMs' => 60_000,
                                      'pollIntervalMs' => 1 })
          end
        when 'tasks/get'
          json_answer(body['id'], detailed_task(status: 'completed',
                                                'result' => { 'content' => [], 'structuredContent' => { 'a' => 1 },
                                                              'isError' => false }))
        else raise "unexpected #{body['method']}"
        end
      end
      sent
    end

    it 'validates what the task delivers against the definition the recovery refreshed' do
      sent = serving
      http = MCPClient::ServerStreamableHTTP.new(base_url: url)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(http)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'streamable_http', url: url }],
                                     extensions: [TASKS_EXT], validate_structured_content: :strict)
      allow(client).to receive(:sleep)

      handle = client.call_tool_as_task('charge', { 'region' => 'eu' })

      expect(handle).to be_working
      expect(sent.map(&:first)).to eq(%w[server/discover tools/list tools/call tools/list tools/call
                                         tasks/get].first(5))
      expect(sent.filter_map { |method, region| region if method == 'tools/call' }).to eq(%w[eu eu])
      expect { client.get_task_result(handle) }.to raise_error(MCPClient::Errors::ValidationError, /\bb\b/)
      expect(sent.map(&:first).last).to eq('tasks/get')
    end
  end

  describe 'a legacy task whose result stream carries a related-task elicitation' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'https://example.com/sse', read_timeout: 5, retries: 0) }
    let(:related_key) { MCPClient::ServerBase::RELATED_TASK_META_KEY }

    def legacy_task(status: 'working')
      now = Time.now.utc.iso8601
      { 'taskId' => 'task-1', 'status' => status, 'createdAt' => now, 'lastUpdatedAt' => now, 'ttl' => 60_000,
        'pollInterval' => 1 }
    end

    def event(message)
      "event: message\ndata: #{JSON.generate(message)}\n\n"
    end

    def elicitation_from_server
      { 'jsonrpc' => '2.0', 'id' => 'srv-7', 'method' => 'elicitation/create',
        'params' => { 'message' => 'Name?', 'mode' => 'form',
                      'requestedSchema' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'string' } } },
                      '_meta' => { related_key => { 'taskId' => 'task-1' } } } }
    end

    # The SSE transport at the wire: every POST is recorded, and the answer
    # (or, for tasks/result, first the server's own request and then the
    # answer) arrives on the event stream, as it does over this transport.
    def on_the_stream(answers)
      sent = []
      written = []
      server.instance_variable_set(:@connection_established, true)
      server.instance_variable_set(:@sse_connected, true)
      server.instance_variable_set(:@rpc_endpoint, 'https://example.com/messages')
      allow(server).to receive(:post_json_rpc_request) do |request|
        wire = JSON.parse(JSON.generate(request))
        sent << wire
        next nil if wire['method'].start_with?('notifications/')

        answers.fetch(wire['method']) { raise "no answer for #{wire['method']}" }.call(wire).each do |message|
          server.send(:parse_and_handle_sse_event, event(message.merge('jsonrpc' => '2.0')))
        end
        nil
      end
      allow(server).to receive(:post_jsonrpc_response) { |response| written << JSON.parse(JSON.generate(response)) }
      [sent, written]
    end

    it 'answers the elicitation on the stream before the result is released, related to the task' do
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      client = MCPClient::Client.new(mcp_server_configs: [{ type: 'sse', base_url: 'https://example.com/sse' }],
                                     elicitation_handler: lambda { |_message, _schema|
                                       { action: 'accept', content: { 'n' => 'x' } }
                                     })
      allow(client).to receive(:sleep)
      answer = ->(wire, result) { [{ 'id' => wire['id'], 'result' => result }] }
      sent, written = on_the_stream(
        'initialize' => lambda { |wire|
          tasks = { 'get' => true, 'result' => true, 'requests' => { 'tools' => { 'call' => {} } } }
          answer.call(wire, { 'protocolVersion' => '2025-11-25',
                              'capabilities' => { 'tools' => {}, 'tasks' => tasks },
                              'serverInfo' => { 'name' => 's', 'version' => '1' } })
        },
        'tools/list' => lambda { |wire|
          answer.call(wire, { 'tools' => [{ 'name' => 'slow', 'inputSchema' => { 'type' => 'object' },
                                            'execution' => { 'taskSupport' => 'optional' } }] })
        },
        'tools/call' => ->(wire) { answer.call(wire, { 'task' => legacy_task }) },
        'tasks/result' => ->(wire) { [elicitation_from_server] + answer.call(wire, call_result('legacy')) }
      )

      handle = client.call_tool_as_task('slow', {})
      expect(client.get_task_result(handle)).to eq(call_result('legacy'))

      expect(sent.map { |request| request['method'] }.reject { |method| method.start_with?('notifications/') })
        .to eq(%w[initialize tools/list tools/call tasks/result])
      reply = written.find { |message| message['id'] == 'srv-7' }
      expect(reply['result']).to include('action' => 'accept', 'content' => { 'n' => 'x' })
      expect(reply.dig('result', '_meta', related_key)).to eq({ 'taskId' => 'task-1' })
    end
  end
end
