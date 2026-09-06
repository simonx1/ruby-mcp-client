# frozen_string_literal: true

require 'spec_helper'
require 'delegate'
require 'webmock/rspec'

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
