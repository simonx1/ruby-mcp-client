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
    allow(server).to receive(:send_request) { |req, *_rest, **_opts| sent << req }
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
                  result['result'] = { 'content' => [{ 'type' => 'text', 'text' => 'done' }], 'isError' => false }
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
        expect(finished.result).to eq(call_result)
        expect(File.read("#{store}.gen").to_i).to eq(2)
        expect(client.get_task(handle).to_h['servedBy']).to eq(2) if finished.to_h.key?('servedBy')
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
end
