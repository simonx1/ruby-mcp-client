# frozen_string_literal: true

require 'spec_helper'
require 'delegate'
require 'webmock/rspec'

# MCP 2026-07-28 deprecations: regression suite.
#
# These examples were written one adversarial review round at a time, each
# pinning a defect that round found. They are gathered here by subject
# rather than by the round that produced them; the round is noted on each
# section only because the review notes refer to it. Every example here
# covers production code no other spec reaches.

# --- verify ----------------------------------------------------------------

# Verification pass over the 2026-07-28 deprecation notices.
#
# Round 11 stopped a thread that is already INSIDE a notice from queueing for
# an emission gate. That is not the only way into the inversion, because the
# thread holding the logger's device lock need not be inside a notice at all:
# an ordinary `logger.info` holds it for as long as the write takes, and the
# device — a formatter, a log subscriber, an audit hook the host installed —
# may itself reach a deprecated feature. That thread then queues for a gate
# held by a second thread which is waiting for the very device lock the first
# one holds, and neither moves again. Round 11's `emitting?` guard cannot see
# it: the first thread is doing ordinary logging, not writing a notice.
#
# There is no version of "wait for the gate" that survives this, because the
# waiter cannot know whether it holds a lock the emitter needs. So no lock of
# this module is held across host logging code and none is ever waited for:
# the once-per-process accounting is an atomic claim, taken and released
# under a mutex this module never holds while calling out. A caller that
# finds a notice in flight stands down rather than queueing behind it, and
# the notice stays owed to a later use exactly as a dropped one does.
#
# That also closes a second hole. A contender that waited took the notice
# over on a level check it made BEFORE the wait: if its logger stopped
# keeping warnings in the meantime, the warning was filtered and the
# process's one notice was marked emitted having been written nowhere — and
# lowering the level again did not bring it back. Nothing takes a notice
# over any more, and the level check now sits next to the write instead of at
# the top of `warn`.
#
# The rest of this pass is coverage. The Roots and Sampling notice hooks on
# both SSE transports and the Sampling hook on the multi round-trip path
# could each be deleted with the whole focused suite still green, and the
# marking checks counted `@deprecated` tags (which cannot show that an API
# has one) and accepted any registry window (which cannot show that an API
# names its own). These examples also run with notices ENABLED through paths
# the rest of the suite only exercises with them off (spec_helper disables
# them for the suite), so a notice that broke the request it describes would
# fail here.
RSpec.describe 'MCP 2026-07-28 deprecations (verification)' do
  let(:output) { StringIO.new }
  let(:logger) { Logger.new(output) }

  around do |example|
    MCPClient::Deprecations.enabled = true
    MCPClient::Deprecations.reset!
    example.run
  ensure
    MCPClient::Deprecations.reset!
    MCPClient::Deprecations.enabled = false
  end

  let(:threads) { [] }

  after { threads.each { |thread| thread.kill if thread.alive? } }

  def start(&block)
    thread = Thread.new(&block)
    threads << thread
    thread
  end

  # Nothing here may wedge the suite: a regression has to fail the example,
  # not hang it. Seconds, not milliseconds, so a loaded CI box never reports
  # a deadlock that is only slowness.
  def finished?(thread)
    !thread.join(10).nil?
  end

  # Wait until every thread is parked (blocked or finished), so an example
  # exercises the contended path rather than a lucky ordering.
  def settle(*waiting)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until waiting.all? { |thread| thread.status == 'sleep' || !thread.status }
      raise 'threads never settled' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.001
    end
  end

  # A logger whose #warn blocks until the example releases it and then either
  # raises or records the message. Deliberately not a ::Logger, so the level
  # probe treats it as one that keeps warnings. Mirrors rounds 9 to 11.
  let(:gated_logger_class) do
    Class.new do
      attr_reader :messages

      def initialize
        @entered = Queue.new
        @release = Queue.new
        @messages = []
      end

      def warn(message)
        @entered << :entered
        raise 'logger is down' if @release.pop == :raise

        @messages << message
        nil
      end

      # Wait until a caller is inside #warn.
      def await_entry = @entered.pop

      def release(outcome = :succeed) = @release << outcome
    end
  end

  describe 'a notice raised from inside an ordinary log line' do
    # A device for a real ::Logger, which serializes every write behind its
    # device lock. The first write parks inside that lock until the example
    # releases it, and then runs the host's callback while it is still held.
    # Nothing here is inside a notice: the thread is writing an info line.
    let(:callback_device_class) do
      Class.new do
        attr_reader :messages, :nested

        def initialize(&on_first_write)
          @messages = []
          @entered = Queue.new
          @go = Queue.new
          @on_first_write = on_first_write
          @first = true
        end

        def write(message)
          @messages << message
          return unless @first

          @first = false
          @entered << :entered
          @go.pop
          @nested = @on_first_write&.call
        end

        def close = nil

        # Wait until the first writer is inside #write, holding the lock.
        def await_entry = @entered.pop

        def release = (@go << :go)
      end
    end

    let(:device) { callback_device_class.new { MCPClient::Deprecations.warn(:roots, host_logger) } }
    let(:host_logger) { Logger.new(device) }

    it 'does not deadlock against the logger another notice is writing to' do
      ordinary = start { host_logger.info('an ordinary line') }
      device.await_entry
      # This thread now owns the Roots attempt and is queued for the device
      # lock the ordinary line is holding. The ordinary line's callback is
      # about to ask for Roots in turn: the inversion, with neither thread
      # inside a notice when it took the lock it holds.
      notice = start { MCPClient::Deprecations.warn(:roots, host_logger) }
      settle(notice)
      device.release

      expect(finished?(ordinary)).to be(true), 'an ordinary log line deadlocked against a deprecation notice'
      expect(finished?(notice)).to be(true), 'the notice never came back out of the logger'
      expect(notice.value).to be(true)
      # The callback's attempt stood down instead of queueing: the notice it
      # wanted is the one the other thread is writing.
      expect(device.nested).to be(false)
      expect(device.messages.grep(/Roots .*deprecated/).size).to eq(1)
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
    end

    it 'still writes the notice when no other thread is holding it' do
      # The standing down above is the contended case, not a blanket refusal
      # to warn from inside a write: with nothing in flight the callback's
      # first use is served where it happens, through the same logger.
      ordinary = start { host_logger.info('an ordinary line') }
      device.await_entry
      device.release

      expect(finished?(ordinary)).to be(true)
      expect(device.nested).to be(true)
      expect(device.messages.grep(/Roots .*deprecated/).size).to eq(1)
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
    end
  end

  describe 'a notice that was never written' do
    it 'is not spent by a contender whose logger stopped keeping warnings' do
      gated = gated_logger_class.new
      quiet = Logger.new(output)
      emitter = start { MCPClient::Deprecations.warn(:roots, gated) }
      gated.await_entry
      contender = start { MCPClient::Deprecations.warn(:roots, quiet) }
      settle(contender)
      # The level a contender checked before it met the notice in flight is
      # not the level its logger has when it would write.
      quiet.level = Logger::ERROR
      gated.release(:raise)

      expect(finished?(emitter)).to be(true)
      expect(finished?(contender)).to be(true)
      expect([emitter.value, contender.value]).to eq([false, false])
      expect(output.string).not_to match(/Roots .*deprecated/)
      # Nothing was written, so nothing was spent.
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
      quiet.level = Logger::DEBUG
      expect(MCPClient::Deprecations.warn(:roots, quiet)).to be(true)
      expect(output.string).to match(/Roots .*deprecated/)
    end

    it 'is not spent by a level that went up after the probe' do
      # A logger whose level is raised between the module's probe and the
      # write, as another thread raising it would do. ::Logger#warn returns
      # true either way, so "the logger took it" cannot be read off the
      # return value: the check has to sit next to the write.
      raised_after_probe = Class.new(Logger) do
        def level
          current = super
          self.level = Logger::ERROR
          current
        end
      end.new(output)

      expect(MCPClient::Deprecations.warn(:sampling, raised_after_probe)).to be(false)
      expect(output.string).not_to match(/Sampling .*deprecated/)
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(false)
      expect(MCPClient::Deprecations.warn(:sampling, Logger.new(output))).to be(true)
      expect(output.string).to match(/Sampling .*deprecated/)
    end
  end

  describe 'a server-initiated request routed by an HTTP transport' do
    let(:posted) { [] }
    let(:sampling_answer) do
      { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'ok' }, 'model' => 'm' }
    end

    # Route one request through the transport's own dispatch, capturing the
    # response it posts back to the server.
    def route(server, message)
      allow(server).to receive(:ensure_initialized) if server.respond_to?(:ensure_initialized, true)
      allow(server).to receive(:post_jsonrpc_response) { |response| posted << response }
      server.send(:handle_server_request, message)
    end

    {
      'the HTTP+SSE transport' => lambda { |logger|
        MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger)
      },
      'the Streamable HTTP transport' => lambda { |logger|
        MCPClient::ServerStreamableHTTP.new(base_url: 'http://localhost:1/mcp', logger: logger)
      }
    }.each do |label, build|
      context "on #{label}" do
        let(:server) { build.call(logger) }

        it 'warns for a roots/list answer that carries a root, and still answers it' do
          server.on_roots_list_request { |_id, _params| { 'roots' => [{ 'uri' => 'file:///workspace' }] } }

          route(server, { 'id' => 7, 'method' => 'roots/list', 'params' => {} })

          expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
          expect(output.string).to match(/Roots .*deprecated/)
          expect(posted.last).to include('jsonrpc' => '2.0', 'id' => 7)
          expect(posted.last['result']).to eq({ 'roots' => [{ 'uri' => 'file:///workspace' }] })
        end

        it 'stays silent for an answer that carries no root, and still answers it' do
          server.on_roots_list_request { |_id, _params| { 'roots' => [] } }

          route(server, { 'id' => 8, 'method' => 'roots/list', 'params' => {} })

          expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
          expect(posted.last['result']).to eq({ 'roots' => [] })
        end

        it 'warns for a sampling request and its includeContext, and still answers it' do
          # The notice runs before the handler and is handed the very params
          # the handler is about to get, so "still serves it" has to be read
          # off THOSE params: SEP-2596 deprecates the two values, it does not
          # change what the transport passes on.
          served = nil
          server.on_sampling_request do |_id, request_params|
            served = request_params
            sampling_answer
          end
          params = { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'allServers' }

          route(server, { 'id' => 9, 'method' => 'sampling/createMessage', 'params' => params })

          expect(served).to include('includeContext' => 'allServers')
          expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
          expect(output.string).to match(/Sampling .*deprecated/)
          expect(output.string).to include('Received: includeContext allServers')
          expect(posted.last).to include('jsonrpc' => '2.0', 'id' => 9)
          expect(posted.last['result']).to eq(sampling_answer)
        end

        # The notice is once per process; the feature is not. A second
        # request after the notice is spent is served exactly as the first.
        it 'keeps serving sampling after the notice has been spent' do
          server.on_sampling_request { |_id, _params| sampling_answer }

          2.times do |i|
            route(server, { 'id' => 20 + i, 'method' => 'sampling/createMessage',
                            'params' => { 'messages' => [], 'maxTokens' => 5 } })
          end

          expect(posted.map { |response| response['id'] }).to eq([20, 21])
          expect(posted.map { |response| response['result'] }).to eq([sampling_answer, sampling_answer])
          expect(output.string.scan(/Sampling .*deprecated/).size).to eq(1)
        end

        # Serving the request is the use, so a handler that then fails does
        # not get the notice back — and the peer gets the transport's own
        # constant error, not something the notice changed.
        it 'answers the error of a sampling handler that raises, notice spent' do
          server.on_sampling_request { |_id, _params| raise 'handler exploded' }

          route(server, { 'id' => 10, 'method' => 'sampling/createMessage',
                          'params' => { 'messages' => [], 'maxTokens' => 5 } })

          expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
          expect(posted.last['error']).to eq({ 'code' => -32_603, 'message' => 'Internal error' })
          expect(posted.last).not_to have_key('result')
          # The handler's text is host-internal: logged here, never posted.
          expect(output.string).to include('handler exploded')
          expect(JSON.generate(posted.last)).not_to include('handler exploded')
        end

        # A capability this host never registered for is not a deprecated
        # feature it uses: the rejection goes out and the notice stays owed.
        it 'stays silent when it has no sampling handler to serve with' do
          route(server, { 'id' => 11, 'method' => 'sampling/createMessage',
                          'params' => { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'thisServer' } })

          expect(MCPClient::Deprecations.emitted?(:sampling)).to be(false)
          expect(MCPClient::Deprecations.emitted?(:include_context)).to be(false)
          # sampling.mdx § Error Handling reserves -1 for "User rejected
          # sampling request"; a capability the client never declared is an
          # unsupported method, -32601, as Client#handle_sampling_request answers.
          expect(posted.last['error']).to include('code' => -32_601, 'message' => 'Sampling not supported')
        end

        # SEP-1577: "The client MUST return an error if this field is provided
        # but ClientCapabilities.sampling.tools is not declared" — on the 2025
        # server-initiated path as on the round-trip one, and with the notices
        # a served-or-refused sampling request owes going out first.
        it 'refuses a tool-enabled request the host never declared sampling.tools for, notices first' do
          served = []
          server.on_sampling_request do |_id, params|
            served << params
            sampling_answer
          end

          route(server, { 'id' => 12, 'method' => 'sampling/createMessage',
                          'params' => { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'thisServer',
                                        'tools' => [{ 'name' => 'lookup', 'inputSchema' => {} }] } })

          expect(served).to be_empty
          expect(posted.last['error']).to include('code' => -32_602)
          expect(posted.last['error']['message']).to match(/sampling\.tools/)
          expect(posted.last).not_to have_key('result')
          expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
          expect(output.string).to include('Received: includeContext thisServer')
        end

        it 'serves the same request once the host declared sampling.tools' do
          served = []
          server.on_sampling_request do |_id, params|
            served << params
            sampling_answer
          end
          server.declare_sampling_tools

          route(server, { 'id' => 13, 'method' => 'sampling/createMessage',
                          'params' => { 'messages' => [], 'maxTokens' => 5, 'toolChoice' => { 'mode' => 'auto' } } })

          expect(served.last).to include('toolChoice' => { 'mode' => 'auto' })
          expect(posted.last['result']).to eq(sampling_answer)
        end

        # Roots counts as used only once an answer carries a root, and an
        # answer that never came carries none.
        it 'stays silent when the roots handler raises' do
          server.on_roots_list_request { |_id, _params| raise 'no roots today' }

          route(server, { 'id' => 12, 'method' => 'roots/list', 'params' => {} })

          expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
          expect(posted.last['error']).to eq({ 'code' => -32_603, 'message' => 'Internal error' })
        end
      end
    end
  end

  describe 'the Sampling notice on the multi round-trip path' do
    # A stdio server driven by scripted responses (no subprocess), as the
    # MRTR spec drives one.
    def script_stdio(server, responses)
      sent = []
      allow(server).to receive(:connect).and_return(true)
      allow(server).to receive(:start_reader)
      allow(server).to receive(:start_stderr_reader)
      server.instance_variable_set(:@stdin, double('stdin', puts: nil, flush: nil, closed?: true, close: nil))
      allow(server).to receive(:send_request) { |req| sent << req }
      allow(server).to receive(:wait_response) do |id, **_opts|
        responder = responses.shift
        raise 'no scripted response left' unless responder

        response = responder.respond_to?(:call) ? responder.call(sent.last) : responder
        response.merge('jsonrpc' => '2.0', 'id' => id)
      end
      sent
    end

    def discover_result
      { 'resultType' => 'complete', 'supportedVersions' => ['2026-07-28'],
        'capabilities' => { 'tools' => {}, 'resources' => {}, 'prompts' => {} } }
    end

    def sampling_input_required(value)
      params = { 'messages' => [{ 'role' => 'user', 'content' => { 'type' => 'text', 'text' => 'Capital?' } }],
                 'maxTokens' => 100 }
      params['includeContext'] = value if value
      { 'resultType' => 'input_required', 'requestState' => 'opaque-state',
        'inputRequests' => { 'c' => { 'method' => 'sampling/createMessage', 'params' => params } } }
    end

    let(:answer) do
      { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'Paris' }, 'model' => 'm' }
    end
    let(:server) { MCPClient::ServerStdio.new(command: 'true', read_timeout: 1, logger: logger) }

    # Drive one tools/call that the server answers with an input_required
    # sampling request, and return what the retry carried.
    def exchange(include_context)
      server.on_sampling_request { |_key, _params| answer }
      sent = script_stdio(server, [{ 'result' => discover_result },
                                   { 'result' => sampling_input_required(include_context) },
                                   { 'result' => { 'content' => [{ 'type' => 'text', 'text' => 'done' }] } }])
      [server.call_tool('answer', {}), sent.select { |request| request['method'] == 'tools/call' }]
    end

    it 'warns for Sampling, and still completes the round trip' do
      result, calls = exchange(nil)

      expect(result['content'].first['text']).to eq('done')
      expect(calls.size).to eq(2)
      expect(calls.last['params']['inputResponses']).to eq({ 'c' => answer })
      expect(calls.last['params']['requestState']).to eq('opaque-state')
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
      expect(output.string).to match(/Sampling .*deprecated/)
      expect(output.string).to include('LLM provider')
    end

    %w[thisServer allServers].each do |value|
      it "warns for includeContext #{value} it carries, and still completes the round trip" do
        result, calls = exchange(value)

        expect(result['content'].first['text']).to eq('done')
        expect(calls.last['params']['inputResponses']).to eq({ 'c' => answer })
        expect(MCPClient::Deprecations.emitted?(:include_context)).to be(true)
        expect(output.string).to include("Received: includeContext #{value}")
      end
    end

    it 'stays silent about includeContext for the value that is not deprecated' do
      result, = exchange('none')

      expect(result['content'].first['text']).to eq('done')
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
      expect(MCPClient::Deprecations.emitted?(:include_context)).to be(false)
      expect(output.string).not_to include('includeContext')
    end
  end

  describe 'the APIs this gem marks deprecated' do
    let(:registry) { MCPClient::Deprecations::REGISTRY }

    # Every API this gem offers that exposes a feature the 2026-07-28
    # registry deprecates, and the feature it exposes. Counting `@deprecated`
    # tags cannot show that a given API carries one, and a tag that names ANY
    # registry window cannot show that it names its own: both need the
    # inventory written down. Each entry is [label, file under lib/, the
    # definition the tag sits above, the registry feature].
    def inventory
      transports = { 'server_sse.rb' => 'ServerSSE', 'server_stdio.rb' => 'ServerStdio',
                     'server_http.rb' => 'ServerHTTP', 'server_streamable_http.rb' => 'ServerStreamableHTTP' }
      transports.flat_map do |file, klass|
        [["#{klass}#log_level=", "mcp_client/#{file}", /^\s*def log_level=/, :logging],
         ["#{klass}#on_roots_list_request", "mcp_client/#{file}", /^\s*def on_roots_list_request\b/, :roots],
         ["#{klass}#on_sampling_request", "mcp_client/#{file}", /^\s*def on_sampling_request\b/, :sampling]]
      end + [
        ['MCPClient.sse_config', 'mcp_client.rb', /^\s*def self\.sse_config\b/, :http_sse_transport],
        ['MCPClient::ServerSSE', 'mcp_client/server_sse.rb', /^\s*class ServerSSE\b/, :http_sse_transport],
        ['MCPClient::Client#roots', 'mcp_client/client.rb', /^\s*attr_reader :roots\b/, :roots],
        ['MCPClient::Client#roots=', 'mcp_client/client.rb', /^\s*def roots=/, :roots],
        ['MCPClient::Client#log_level=', 'mcp_client/client.rb', /^\s*def log_level=/, :logging],
        ['MCPClient::Root', 'mcp_client/root.rb', /^\s*class Root\b/, :roots],
        ['MCPClient::JsonRpcCommon#declare_sampling_tools', 'mcp_client/json_rpc_common.rb',
         /^\s*def declare_sampling_tools\b/, :sampling],
        ['MCPClient::Auth::OAuthProvider#register_client', 'mcp_client/auth/oauth_provider.rb',
         /^\s*def register_client\b/, :dynamic_client_registration]
      ]
    end

    def source_for(file)
      File.read(File.expand_path("../../../lib/#{file}", __dir__))
    end

    # The `@deprecated` tag of the doc block above a definition: its line
    # number and its text, or nil when the definition carries no tag.
    def deprecated_tag(source, definition)
      lines = source.lines
      index = lines.index { |line| line.match?(definition) }
      return nil unless index

      start = index
      start -= 1 while start.positive? && lines[start - 1].match?(/^\s*#/)
      tag_at = (start...index).find { |i| lines[i].match?(/^\s*#\s*@deprecated\b/) }
      return nil unless tag_at

      text = +lines[tag_at].sub(/^\s*#\s?/, '').strip
      lines[(tag_at + 1)...index].each do |line|
        break if line.match?(/^\s*#\s*@\w/)

        text << " #{line.sub(/^\s*#\s?/, '').strip}"
      end
      [tag_at + 1, text]
    end

    def tags
      inventory.map do |label, file, definition, feature|
        [label, feature, deprecated_tag(source_for(file), definition)]
      end
    end

    it 'marks each one of them at its own definition' do
      tags.each do |label, _feature, tag|
        expect(tag).not_to(be_nil, "#{label} exposes a deprecated feature with no @deprecated tag")
      end
    end

    it 'cites the SEP that deprecated the feature the API exposes' do
      tags.each do |label, feature, tag|
        sep = registry[feature][:reference][/SEP-\d+|PR #\d+/]
        expect(tag&.last).to include(sep), "#{label} (#{feature}) should cite #{sep}"
      end
    end

    it "names that feature's own earliest removal, not merely some registry window" do
      windows = registry.each_value.map { |entry| entry[:earliest_removal] }.uniq
      tags.each do |label, feature, tag|
        window = registry[feature][:earliest_removal]
        expect(tag&.last).to include(window), "#{label} (#{feature}) should name: #{window}"
        (windows - [window]).each do |other|
          expect(tag&.last).not_to include(other), "#{label} (#{feature}) names another feature's window: #{other}"
        end
      end
    end

    it 'accounts for every @deprecated tag the library carries' do
      claimed = inventory.filter_map do |_label, file, definition, _feature|
        found = deprecated_tag(source_for(file), definition)
        [file, found.first] if found
      end
      marked = Dir[File.expand_path('../../../lib/**/*.rb', __dir__)].flat_map do |path|
        file = path.sub(%r{\A.*/lib/}, '')
        File.readlines(path).each_with_index.filter_map do |line, index|
          [file, index + 1] if line.match?(/^\s*#\s*@deprecated\b/)
        end
      end

      # A mark the inventory does not know about is an API nothing checks the
      # SEP or the window of.
      expect((marked - claimed).sort).to eq([])
    end

    # The examples above read the SOURCE, which is where a tag is written but
    # not where a host reads it. What a host reads is the generated API
    # documentation, and a comment that sits in the right place in the file
    # can still fail to reach it: `@!attribute` directives are one such case
    # — YARD drops the docstring of the LAST directive in a block preceding a
    # combined `attr_reader`, so `Client#roots` documented that way came out
    # with no tags at all while every source-text check above passed. So ask
    # YARD for the objects it publishes and read the tags off those.
    describe 'as YARD publishes them' do
      # Parsing the library is the expensive part; one registry serves every
      # example here. YARD's registry is process-global, so it is restored
      # afterwards for anything else that may rely on it.
      before(:context) do
        require 'yard'
        @saved_registry = YARD::Registry.all.dup
        YARD::Registry.clear
        YARD.parse([File.expand_path('../../../lib/**/*.rb', __dir__)], [], YARD::Logger::ERROR)
      end

      after(:context) do
        YARD::Registry.clear
        @saved_registry.each { |object| YARD::Registry.register(object) }
      end

      # The path YARD knows the API by. The transports are listed unqualified.
      def yard_path(label)
        label.start_with?('MCPClient') ? label : "MCPClient::#{label}"
      end

      def documented
        inventory.map do |label, _file, _definition, feature|
          path = yard_path(label)
          [path, feature, YARD::Registry.at(path)]
        end
      end

      it 'publishes an object for every API in the inventory' do
        documented.each do |path, _feature, object|
          expect(object).not_to(be_nil, "YARD publishes no object at #{path}")
        end
      end

      it 'carries a deprecated tag on each of them' do
        documented.each do |path, _feature, object|
          tags = object ? object.tags(:deprecated) : []
          expect(tags.size).to(eq(1), "#{path} is published with #{tags.size} deprecated tags, expected 1")
        end
      end

      it "cites the SEP and that feature's own earliest removal" do
        windows = registry.each_value.map { |entry| entry[:earliest_removal] }.uniq
        documented.each do |path, feature, object|
          # YARD hard-wraps a tag's text, so the line breaks it chose are not
          # part of what the tag says.
          tag = object&.tags(:deprecated)&.first
          text = tag ? tag.text.to_s.gsub(/\s+/, ' ') : ''
          entry = registry[feature]
          expect(text).to include(entry[:reference][/SEP-\d+|PR #\d+/]), path
          expect(text).to include(entry[:earliest_removal]), path
          (windows - [entry[:earliest_removal]]).each do |other|
            expect(text).not_to include(other), "#{path} names another feature's window: #{other}"
          end
        end
      end
    end
  end
end

# --- round6 ----------------------------------------------------------------

# Round 6 of the 2026-07-28 deprecation review: the registry carries the
# deprecated-features registry's own earliest-removal wording (a revision, not
# a calendar date), every YARD mark and the runtime notice name that clock,
# the notices fire from the transport entry points a host can reach without a
# Client, and the once-per-process bookkeeping survives a fork.
RSpec.describe 'MCP 2026-07-28 deprecations (round 6)' do
  # The child's report, or a prompt failure: a bookkeeping regression that
  # leaves the child blocked must fail this example, not wedge the suite on
  # an unbounded pipe read.
  def bounded_fork_report(reader, pid)
    report = reader.wait_readable(10) ? reader.read : nil
    reader.close
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until Process.waitpid(pid, Process::WNOHANG)
      raise 'forked worker did not exit' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    report or raise 'forked worker reported nothing within 10s'
  ensure
    Process.kill('KILL', pid) rescue nil # rubocop:disable Style/RescueModifier
  end

  let(:output) { StringIO.new }
  let(:logger) { Logger.new(output) }

  around do |example|
    MCPClient::Deprecations.enabled = true
    MCPClient::Deprecations.reset!
    example.run
  ensure
    MCPClient::Deprecations.reset!
    MCPClient::Deprecations.enabled = false
  end

  let(:registry) { MCPClient::Deprecations::REGISTRY }
  # https://modelcontextprotocol.io/specification/2026-07-28/deprecated,
  # "Earliest removal" column, verbatim.
  let(:revision_window) { 'the first revision released on or after 2027-07-28' }

  describe 'the earliest removal the registry records' do
    it 'is the registry\'s own wording, not a paraphrase of the policy floor' do
      %i[roots sampling logging dynamic_client_registration].each do |key|
        expect(registry[key][:earliest_removal]).to eq(revision_window), key.to_s
      end
      expect(registry[:include_context][:earliest_removal]).to eq('follows Sampling (SEP-2577)')
      expect(registry[:http_sse_transport][:earliest_removal]).to eq('three months after SEP-2596 reaches Final')
    end

    it 'never states a bare removal date a host could plan around' do
      registry.each do |key, entry|
        expect(entry[:earliest_removal]).not_to match(/\A\s*(no earlier than\s+)?2\d{3}-\d\d-\d\d\s*\z/), key.to_s
      end
    end
  end

  # The lifecycle policy's mark-and-warn obligation is to point the host at
  # the replacement, so the migration text is a requirement and not a
  # decoration. Written down here rather than read back off the production
  # table: an example that compares REGISTRY[...][:migration] with the notice
  # it produced agrees with an empty string just as happily.
  describe 'the replacement the registry names for each feature' do
    # What the published registry's "Migration" column tells a host to do,
    # one distinguishing phrase per row.
    let(:replacements) do
      {
        roots: ['tool parameters', 'resource URIs', 'server configuration'],
        sampling: ['LLM provider'],
        logging: %w[stderr OpenTelemetry],
        http_sse_transport: ['Streamable HTTP'],
        include_context: ['omit includeContext', '"none"'],
        dynamic_client_registration: ['Client ID Metadata Document', 'pre-registered credentials']
      }
    end

    it 'says what to use instead, in the registry and in the notice it writes' do
      expect(replacements.keys).to match_array(registry.keys)
      replacements.each do |key, phrases|
        MCPClient::Deprecations.reset!
        output.truncate(output.rewind)
        expect(MCPClient::Deprecations.warn(key, logger)).to be(true)

        phrases.each do |phrase|
          expect(registry[key][:migration]).to include(phrase), key.to_s
          expect(output.string).to include(phrase), key.to_s
        end
      end
    end

    it 'never leaves a feature without one' do
      registry.each do |key, entry|
        expect(entry[:migration]).to be_a(String)
        expect(entry[:migration].split.size).to be >= 4, key.to_s
      end
    end
  end

  describe 'the runtime notice' do
    it 'names the earliest removal alongside the SEP and the migration' do
      MCPClient::Deprecations.warn(:roots, logger)

      expect(output.string).to include('SEP-2577')
      expect(output.string).to include(revision_window)
      expect(output.string).to include(registry[:roots][:migration])
    end

    it 'names the transport clock for the HTTP+SSE transport' do
      MCPClient::Deprecations.warn(:http_sse_transport, logger)

      expect(output.string).to include('three months after SEP-2596 reaches Final')
    end
  end

  describe 'the YARD marks on the deprecated APIs' do
    # Feature lifecycle policy, tier-1 SDK obligation: mark the API with the
    # language's native mechanism, referencing the deprecation SEP *and* the
    # earliest removal where the mechanism permits.
    def deprecated_tags(source)
      tags = []
      current = nil
      source.each_line do |line|
        if (match = line.match(/^\s*#\s*@deprecated\b(.*)$/))
          tags << (current = +match[1].strip)
        elsif current.nil?
          next
        elsif line.match?(/^\s*#\s*@\w/) || !line.match?(/^\s*#/)
          current = nil
        elsif (match = line.match(/^\s*#\s?(.*)$/))
          current << " #{match[1].strip}"
        end
      end
      tags
    end

    let(:tags) do
      Dir[File.expand_path('../../../lib/**/*.rb', __dir__)].flat_map do |path|
        deprecated_tags(File.read(path)).map { |tag| [path, tag] }
      end
    end

    it 'covers every API this gem marks deprecated' do
      # Round 8 added the sse_config builder and the Roots and Sampling
      # callback registrations on all four transports.
      expect(tags.size).to be >= 17
    end

    it 'cites the deprecation SEP and the earliest removal on each one' do
      windows = registry.each_value.map { |entry| entry[:earliest_removal] }.uniq
      tags.each do |path, tag|
        label = "#{File.basename(path)}: #{tag}"
        expect(tag).to match(/SEP-\d+|PR #\d+/), label
        expect(windows.any? { |window| tag.include?(window) }).to be(true), label
      end
    end
  end

  describe 'a transport driven directly, without a Client' do
    let(:server) { MCPClient::ServerStdio.new(command: 'true', logger: logger) }

    before { allow(server).to receive(:send_message) }

    it 'warns when it serves a roots/list request that carries a root' do
      # Round 7 narrowed the trigger: an empty answer is not use of Roots.
      server.on_roots_list_request { |_id, _params| { 'roots' => [{ 'uri' => 'file:///workspace' }] } }
      server.send(:handle_server_request, { 'id' => 1, 'method' => 'roots/list', 'params' => {} })

      expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
      expect(output.string).to match(/Roots .*deprecated/)
    end

    it 'warns when it serves a sampling request, and for its includeContext' do
      server.on_sampling_request do |_id, _params|
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'ok' }, 'model' => 'm' }
      end
      server.send(:handle_server_request,
                  { 'id' => 2, 'method' => 'sampling/createMessage',
                    'params' => { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'thisServer' } })

      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
      expect(MCPClient::Deprecations.emitted?(:include_context)).to be(true)
      expect(output.string).to include('thisServer')
    end

    it 'stays silent about roots when it has no handler to serve them with' do
      server.send(:handle_server_request, { 'id' => 3, 'method' => 'roots/list', 'params' => {} })

      expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
    end

    it 'warns when a notifications/message reaches its own callback' do
      delivered = []
      server.on_notification { |method, params| delivered << [method, params] }
      server.route_notification('notifications/message', { 'level' => 'info', 'data' => 'hello' })

      expect(MCPClient::Deprecations.emitted?(:logging)).to be(true)
      expect(output.string).to match(/Logging is deprecated/)
      expect(delivered).to eq([['notifications/message', { 'level' => 'info', 'data' => 'hello' }]])
    end

    it 'stays silent for notifications that are not log messages' do
      server.route_notification('notifications/tools/list_changed', {})

      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)
    end
  end

  describe 'an SSE connection that was already established' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger) }

    it 'retries the notice the first connect could not emit' do
      MCPClient::Deprecations.enabled = false
      allow(server).to receive(:start_sse_thread)
      allow(server).to receive(:wait_for_connection)
      allow(server).to receive(:start_activity_monitor)
      expect(server.connect).to be(true)
      server.instance_variable_set(:@connection_established, true)
      expect(MCPClient::Deprecations.emitted?(:http_sse_transport)).to be(false)

      MCPClient::Deprecations.enabled = true
      expect(server.connect).to be(true)

      expect(MCPClient::Deprecations.emitted?(:http_sse_transport)).to be(true)
      expect(output.string).to match(/HTTP\+SSE transport is deprecated/)
    end
  end

  describe 'the once-per-process bookkeeping across a fork' do
    it 'lets a forked worker emit the notice its parent already spent' do
      skip 'fork unavailable on this platform' unless Process.respond_to?(:fork)

      expect(MCPClient::Deprecations.warn(:roots, logger)).to be(true)

      reader, writer = IO.pipe
      pid = fork do
        reader.close
        child_output = StringIO.new
        emitted = MCPClient::Deprecations.warn(:roots, Logger.new(child_output))
        writer.write("#{emitted}\t#{child_output.string.include?('Roots')}")
        writer.close
        exit!(0)
      end
      writer.close
      report = bounded_fork_report(reader, pid)

      expect(report).to eq("true\ttrue")
      # The parent's own bookkeeping is untouched by the child.
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
    end
  end

  describe 'the README' do
    let(:readme) { File.read(File.expand_path('../../../README.md', __dir__)) }

    it 'flags log_level= as deprecated in the subsection that shows it off' do
      # The 2026-07-28 subsection that presents log_level= is where a reader
      # copies it from, so the Logging deprecation has to be stated there and
      # not only in the table further down the page.
      section = readme[/### Discovery and per-request metadata\n.*?(?=\n### )/m]

      expect(section).to include('log_level=')
      expect(section).to include('SEP-2577')
      expect(section).to match(/deprecat/i)
      expect(section).to include('#deprecated-features')
    end
  end
end

# --- round12 ---------------------------------------------------------------

# Round 12 of the 2026-07-28 deprecation review, on three things the earlier
# rounds asserted about but never pinned:
#
#   * a logger the HOST WRAPPED. The notice is owed until a reader could have
#     seen it, and a wrapper that filters is exactly as unreadable as the
#     ::Logger it wraps — but only the bare ::Logger was ever asked.
#   * the HTTP+SSE transport's own notification path. The Logging notice was
#     hung on the routing every other transport shares; the legacy transport
#     carries no subscription stream and does not go through it.
#   * WHEN the elicitation contract reads a server's era. The era is
#     negotiated after the callback is registered, so reading it at
#     registration time reads "not modern" for every server there is.
RSpec.describe 'MCP 2026-07-28 deprecations (round 12)' do
  # The child's report, or a prompt failure: a bookkeeping regression that
  # leaves the child blocked must fail this example, not wedge the suite on
  # an unbounded pipe read.
  def bounded_fork_report(reader, pid)
    report = reader.wait_readable(10) ? reader.read : nil
    reader.close
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until Process.waitpid(pid, Process::WNOHANG)
      raise 'forked worker did not exit' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    report or raise 'forked worker reported nothing within 10s'
  ensure
    Process.kill('KILL', pid) rescue nil # rubocop:disable Style/RescueModifier
  end

  let(:output) { StringIO.new }
  let(:logger) { Logger.new(output) }

  around do |example|
    MCPClient::Deprecations.enabled = true
    MCPClient::Deprecations.reset!
    example.run
  ensure
    MCPClient::Deprecations.reset!
    MCPClient::Deprecations.enabled = false
  end

  # A host's logger is rarely a bare ::Logger: Rails hands out a tagged
  # logger, a broadcast logger or some other Delegator, and an application
  # that routes deprecation output of its own wraps one itself. Every such
  # wrapper answers `warn` without writing when the logger under it drops the
  # record, exactly as ::Logger does above its level — so the notice must be
  # left owed, not spent on a line nobody can read.
  describe 'a logger the host wrapped' do
    # The wrappers a host actually holds: a Delegator around a ::Logger, and
    # a hand-written forwarder that is not a Delegator at all but answers the
    # standard level predicate.
    def delegating_wrapper(level)
      SimpleDelegator.new(Logger.new(output, level: level))
    end

    def forwarding_wrapper(level)
      Class.new do
        def initialize(logger)
          @logger = logger
        end

        def warn?
          @logger.warn?
        end

        def warn(message)
          @logger.warn(message)
        end
      end.new(Logger.new(output, level: level))
    end

    %i[delegating_wrapper forwarding_wrapper].each do |kind|
      context "that is a #{kind.to_s.sub('_wrapper', '')} one" do
        it 'does not spend the notice while it drops warnings' do
          wrapper = send(kind, Logger::ERROR)

          expect(MCPClient::Deprecations.warn(:roots, wrapper)).to be(false)
          expect(output.string).to eq('')
          expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
        end

        it 'writes the notice once the wrapped logger keeps warnings again' do
          wrapper = send(kind, Logger::ERROR)
          expect(MCPClient::Deprecations.warn(:roots, wrapper)).to be(false)

          working = send(kind, Logger::WARN)

          expect(MCPClient::Deprecations.warn(:roots, working)).to be(true)
          expect(output.string).to match(/Roots .*deprecated/)
          expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
        end

        it 'still writes the notice when it keeps warnings' do
          expect(MCPClient::Deprecations.warn(:sampling, send(kind, Logger::DEBUG))).to be(true)
          expect(output.string).to match(/Sampling .*deprecated/)
        end
      end
    end

    # The whole point of the claim: a first use behind a filtered wrapper must
    # not silence the host's own working logger later on.
    it 'leaves a client that used the feature behind it able to warn again' do
      wrapper = delegating_wrapper(Logger::ERROR)
      MCPClient::Client.new(mcp_server_configs: [], roots: [{ uri: 'file:///tmp' }], logger: wrapper)

      expect(output.string).to eq('')
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)

      MCPClient::Client.new(mcp_server_configs: [], roots: [{ uri: 'file:///tmp' }], logger: logger)

      expect(output.string).to match(/Roots .*deprecated/)
    end

    # `Logger.new(nil)` writes nowhere whatever its level says, and wrapping
    # it hides the missing device as surely as wrapping hides the level.
    it 'does not spend the notice on a wrapped no-output logger' do
      wrapper = SimpleDelegator.new(Logger.new(nil))

      expect(MCPClient::Deprecations.warn(:logging, wrapper)).to be(false)
      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)
      expect(MCPClient::Deprecations.warn(:logging, logger)).to be(true)
    end

    # The README lists the ways a notice can go unwritten, so a host can tell
    # whether the one it never saw was dropped or never owed.
    it 'is documented where the other unwritten notices are' do
      readme = File.read(File.expand_path('../../../README.md', __dir__))
      paragraph = readme.split(/\n\n+/).find { |block| block.include?('Notices go to the logger') }

      expect(paragraph).not_to be_nil
      expect(paragraph).to match(/wrapp?ed|wrapper/i)
      expect(paragraph).to include('warn?')
    end

    # Asking is host code like any other: a wrapper whose predicate raises
    # must not take the host's `roots=` down with it, and must not spend the
    # notice on an answer nobody got.
    it 'never fails the deprecated operation for a wrapper that cannot answer' do
      hostile = Class.new(SimpleDelegator) do
        def warn?
          raise 'no'
        end
      end.new(Logger.new(output))

      expect { MCPClient::Deprecations.warn(:roots, hostile) }.not_to raise_error
      expect(MCPClient::Deprecations.warn(:roots, hostile)).to be(false)
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
    end
  end

  # Two bookkeeping edges the earlier rounds describe in prose and never
  # drive: a claim held by a thread that does not survive a fork, and the
  # reentrancy guard's reach across the fibers of one thread.
  describe 'a notice claimed by a thread the caller then leaves behind' do
    # A logger whose #warn parks until released, so a claim can be held open
    # across the fork. Deliberately not a ::Logger, so the level probe takes
    # it for one that keeps warnings.
    let(:gated_logger_class) do
      Class.new do
        def initialize
          @entered = Queue.new
          @release = Queue.new
        end

        def warn(_message)
          @entered << :entered
          @release.pop
          nil
        end

        def await_entry = @entered.pop
        def release = @release << :go
      end
    end

    # A prefork server claims the notice in a thread that the fork does not
    # copy: nobody in the child will ever settle that claim, so a child that
    # inherited it would owe the notice for the life of the worker.
    it 'is not owed forever by a worker forked while it was in flight' do
      skip 'fork unavailable on this platform' unless Process.respond_to?(:fork)

      gated = gated_logger_class.new
      holder = Thread.new { MCPClient::Deprecations.warn(:roots, gated) }
      gated.await_entry

      reader, writer = IO.pipe
      pid = fork do
        reader.close
        child_output = StringIO.new
        emitted = MCPClient::Deprecations.warn(:roots, Logger.new(child_output))
        writer.write("#{emitted}\t#{child_output.string.include?('Roots')}")
        writer.close
        exit!(0)
      end
      writer.close
      report = bounded_fork_report(reader, pid)
      gated.release
      holder.join

      expect(report).to eq("true\ttrue")
    end

    it 'stands down for a fiber of the thread that is already inside it' do
      nested = []
      reentrant = Class.new do
        attr_accessor :nested

        def warn(_message)
          # A formatter, a log subscriber or an audit hook that reaches a
          # deprecated feature from inside a Fiber. The guard is a THREAD
          # variable, not a fiber-local one, because what it guards is a
          # claim this thread holds and every fiber of it holds with it.
          Fiber.new { @nested << MCPClient::Deprecations.warn(:logging, self) }.resume
          nil
        end
      end.new
      reentrant.nested = nested

      expect(MCPClient::Deprecations.warn(:roots, reentrant)).to be(true)
      expect(nested).to eq([false])
      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)
    end
  end

  # The Logging notice belongs to the transport, so a host that never builds
  # an MCPClient::Client still sees it. The HTTP+SSE transport parses its own
  # notifications rather than going through the shared routing, so it needs
  # asking separately — and it is the one transport whose users are most
  # likely to be on the old shape of everything.
  describe 'a notifications/message that reaches an HTTP+SSE transport directly' do
    let(:server) { MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger) }

    def deliver(method, params)
      server.send(:handle_message_event,
                  { data: JSON.generate('jsonrpc' => '2.0', 'method' => method, 'params' => params) })
    end

    it 'warns that Logging is deprecated, and still delivers the notification' do
      delivered = []
      server.on_notification { |method, params| delivered << [method, params] }

      deliver('notifications/message', { 'level' => 'info', 'data' => 'hello' })

      expect(MCPClient::Deprecations.emitted?(:logging)).to be(true)
      expect(output.string).to match(/Logging is deprecated/)
      expect(delivered).to eq([['notifications/message', { 'level' => 'info', 'data' => 'hello' }]])
    end

    it 'stays silent for notifications that are not log messages' do
      server.on_notification { |_method, _params| nil }

      deliver('notifications/tools/list_changed', {})

      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)
    end

    it 'warns even for a host that registered no notification callback' do
      deliver('notifications/message', { 'level' => 'error', 'data' => 'boom' })

      expect(MCPClient::Deprecations.emitted?(:logging)).to be(true)
    end
  end

  # The transports call the elicitation callback with (request_id, params)
  # only, so the era of the asking server has to come from the registration.
  # It cannot be READ there: a server is registered on before it has ever
  # spoken, so its era at that moment is "none" — the 2025-11-25 contract —
  # for a server that is about to negotiate 2026-07-28.
  describe 'the era of a URL-mode elicitation routed by a real transport' do
    let(:url_params) do
      { 'mode' => 'url', 'message' => 'Visit to authorize', 'url' => 'https://example.com/auth',
        'elicitationId' => 'elic-1' }
    end

    # A client on one real stdio transport, built while the server has
    # negotiated nothing, as a client always is. No subprocess is spawned and
    # nothing is written: only the server-request dispatch runs.
    def elicited(server)
      seen = []
      allow(server).to receive(:send_elicitation_response)
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'true' }],
        elicitation_handler: lambda { |_message, metadata|
          seen << metadata
          { 'action' => 'accept' }
        }
      )
      seen
    end

    def ask(server, id)
      server.send(:handle_server_request, { 'id' => id, 'method' => 'elicitation/create', 'params' => url_params })
    end

    it 'is the era the server negotiated after the callback was registered' do
      server = MCPClient::ServerStdio.new(command: 'true')
      seen = elicited(server)
      expect(server).not_to be_modern

      server.instance_variable_set(:@protocol_version, '2026-07-28')
      ask(server, 1)

      expect(seen.last).to eq({ 'mode' => 'url', 'url' => 'https://example.com/auth' })
    end

    it 'follows the same server back to a legacy era on a later session' do
      server = MCPClient::ServerStdio.new(command: 'true')
      seen = elicited(server)

      server.instance_variable_set(:@protocol_version, '2026-07-28')
      ask(server, 1)
      # The host reconnected and the peer answered on the older revision.
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      ask(server, 2)

      expect(seen[0]).not_to have_key('elicitationId')
      expect(seen[1]).to eq(
        { 'mode' => 'url', 'url' => 'https://example.com/auth', 'elicitationId' => 'elic-1' }
      )
    end

    # 2025-11-25 REQUIRES elicitationId on a URL-mode request, so a transport
    # that dropped it on the way to the callback would break that revision.
    it 'carries elicitationId through a legacy transport to the host' do
      server = MCPClient::ServerStdio.new(command: 'true')
      seen = elicited(server)
      server.instance_variable_set(:@protocol_version, '2025-11-25')

      ask(server, 1)

      expect(seen.last).to eq(
        { 'mode' => 'url', 'url' => 'https://example.com/auth', 'elicitationId' => 'elic-1' }
      )
    end

    # A host writes its handler from whichever passage it happened to read.
    # The README says the contract twice — once where elicitation is
    # introduced and once in the 2026-07-28 section — and a reader of the
    # older passage that still showed the 2025-11-25 hash as universal would
    # go looking for `metadata['elicitationId']` on a modern server, find
    # nothing, and correlate against a completion signal the revision removed
    # as well.
    describe 'as the README states it' do
      let(:readme) { File.read(File.expand_path('../../../README.md', __dir__)) }
      # Every passage that shows a host the hash it will be handed.
      let(:passages) { readme.split(/\n\s*\n/).grep(/'mode' => 'url'/) }

      it 'is stated wherever the README shows the hash' do
        expect(passages.size).to be >= 2
        passages.each do |passage|
          expect(passage).to include('2026-07-28'), passage
          expect(passage).to include('2025-11-25'), passage
        end
      end

      it 'never offers elicitationId without the revision it belongs to' do
        passages.each do |passage|
          next unless passage.include?('elicitationId')

          expect(passage).to match(/\*\*2025-11-25\*\*/), passage
          expect(passage).to match(/removed/i), passage
        end
      end
    end

    it 'answers the server whichever era it is on' do
      server = MCPClient::ServerStdio.new(command: 'true')
      answers = []
      allow(server).to receive(:send_elicitation_response) { |id, result| answers << [id, result] }
      allow(MCPClient::ServerFactory).to receive(:create).and_return(server)
      MCPClient::Client.new(
        mcp_server_configs: [{ type: 'stdio', command: 'true' }],
        elicitation_handler: ->(_message, _metadata) { { 'action' => 'accept' } }
      )

      server.instance_variable_set(:@protocol_version, '2026-07-28')
      ask(server, 1)
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      ask(server, 2)

      expect(answers).to eq([[1, { 'action' => 'accept' }], [2, { 'action' => 'accept' }]])
    end
  end
end

# --- round15 ---------------------------------------------------------------

# MCP 2026-07-28 deprecations, fifteenth review round: the diagnostics a
# deprecated operation writes never change the answer the peer gets — a
# logger that fails on the way to a sampling refusal still leaves -32602 on
# the wire — and the transport-direct sampling paths are pinned end to end
# (no handler → -32601, declared tools → served), while the one write failure
# a standard Logger hides from its caller is named as the boundary of the
# notice's retry guarantee.
RSpec.describe 'MCP 2026-07-28 deprecations (round 15)' do
  let(:output) { StringIO.new }
  let(:logger) { Logger.new(output) }

  around do |example|
    MCPClient::Deprecations.enabled = true
    MCPClient::Deprecations.reset!
    example.run
  ensure
    MCPClient::Deprecations.reset!
    MCPClient::Deprecations.enabled = false
  end

  # A host logger whose WARN level is broken (its device raises on that
  # path) while every other level still writes.
  def warn_raising_logger
    Class.new(Logger) do
      def warn(*)
        raise IOError, 'warn device gone'
      end
    end.new(output)
  end

  let(:answer) { { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'x' }, 'model' => 'm' } }
  let(:tool_request) do
    { 'messages' => [], 'maxTokens' => 5, 'tools' => [{ 'name' => 'lookup', 'inputSchema' => {} }],
      'toolChoice' => { 'mode' => 'auto' } }
  end

  describe 'a sampling request served by a stdio transport driven directly' do
    let(:sent) { [] }

    def stdio(log)
      server = MCPClient::ServerStdio.new(command: 'true', logger: log)
      allow(server).to receive(:send_message) { |message| sent << message }
      server.instance_variable_set(:@protocol_version, '2025-11-25')
      server
    end

    def serve(server, id, params)
      server.send(:handle_server_request, { 'id' => id, 'method' => 'sampling/createMessage', 'params' => params })
    end

    # A capability this host never registered for is an unsupported method,
    # not a rejected request: -32601, the envelope complete, and no notice
    # for a feature the host does not use.
    it 'answers a host with no sampling handler with -32601 and spends no notice' do
      serve(stdio(logger), 2, { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'thisServer' })

      expect(sent).to eq([{ 'jsonrpc' => '2.0', 'id' => 2,
                            'error' => { 'code' => -32_601, 'message' => 'Sampling not supported' } }])
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(false)
      expect(MCPClient::Deprecations.emitted?(:include_context)).to be(false)
      expect(output.string).not_to match(/deprecated/)
    end

    # SEP-1577's refusal is the transport's answer to the peer; the line it
    # logs about it is a courtesy to the host. A logger that fails on that
    # line must not turn Invalid params into Internal error.
    it 'still refuses undeclared tool use with -32602 when the logger fails on the warning' do
      server = stdio(warn_raising_logger)
      served = []
      server.on_sampling_request do |_id, params|
        served << params
        answer
      end

      serve(server, 3, tool_request)

      expect(served).to be_empty
      expect(sent.size).to eq(1)
      expect(sent.first['error']).to include('code' => -32_602)
      expect(sent.first['error']['message']).to match(/sampling\.tools/)
    end

    it 'serves a tool-enabled request, parameters intact, once the host declared sampling.tools' do
      server = stdio(logger)
      server.declare_sampling_tools
      served = []
      server.on_sampling_request do |_id, params|
        served << params
        answer
      end

      serve(server, 4, tool_request)

      expect(served).to eq([tool_request])
      expect(sent).to eq([{ 'jsonrpc' => '2.0', 'id' => 4, 'result' => answer }])
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
    end
  end

  describe 'a sampling request routed by an HTTP transport whose logger fails on the warning' do
    let(:posted) { [] }

    {
      'the HTTP+SSE transport' => lambda { |logger|
        MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: logger)
      },
      'the Streamable HTTP transport' => lambda { |logger|
        MCPClient::ServerStreamableHTTP.new(base_url: 'http://localhost:1/mcp', logger: logger)
      }
    }.each do |label, build|
      it "still refuses undeclared tool use with -32602 on #{label}" do
        server = build.call(warn_raising_logger)
        allow(server).to receive(:ensure_initialized) if server.respond_to?(:ensure_initialized, true)
        allow(server).to receive(:post_jsonrpc_response) { |response| posted << response }
        served = []
        server.on_sampling_request do |_id, params|
          served << params
          answer
        end

        server.send(:handle_server_request,
                    { 'id' => 5, 'method' => 'sampling/createMessage', 'params' => tool_request })

        expect(served).to be_empty
        expect(posted.size).to eq(1)
        expect(posted.first['error']).to include('code' => -32_602)
        expect(posted.first['error']['message']).to match(/sampling\.tools/)
      end
    end
  end

  # ::Logger's device catches its own write failure and reports it on
  # $stderr only ("log writing failed."), so `logger.warn` returns as if it
  # had written. A device that is closed is recognised and the notice kept
  # owed; a device that is open and fails to write is beyond reach — the
  # boundary of the retry guarantee, pinned here so it is not mistaken for a
  # promise.
  describe 'a standard logger whose open device fails to write' do
    let(:failing_device) do
      Class.new(StringIO) do
        def write(*)
          raise IOError, 'disk gone'
        end
      end.new
    end
    let(:failing_logger) { Logger.new(failing_device) }

    it 'spends the notice, reporting the failure only where ::Logger does' do
      stderr = StringIO.new
      original = $stderr
      $stderr = stderr
      begin
        expect(MCPClient::Deprecations.warn(:roots, failing_logger)).to be(true)
      ensure
        $stderr = original
      end

      expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
      expect(stderr.string).to include('log writing failed')
      expect(MCPClient::Deprecations.warn(:roots, logger)).to be(false)
      expect(output.string).to be_empty
    end
  end
end
