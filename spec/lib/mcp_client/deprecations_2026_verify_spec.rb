# frozen_string_literal: true

require 'spec_helper'

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
          server.on_sampling_request { |_id, _params| sampling_answer }
          params = { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'allServers' }

          route(server, { 'id' => 9, 'method' => 'sampling/createMessage', 'params' => params })

          expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
          expect(output.string).to match(/Sampling .*deprecated/)
          expect(output.string).to include('Received: includeContext allServers')
          expect(posted.last).to include('jsonrpc' => '2.0', 'id' => 9)
          expect(posted.last['result']).to eq(sampling_answer)
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
        ['MCPClient::Client#roots', 'mcp_client/client.rb', /^\s*attr_reader :servers\b/, :roots],
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
  end
end
