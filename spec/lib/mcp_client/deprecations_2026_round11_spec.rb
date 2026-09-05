# frozen_string_literal: true

require 'spec_helper'

# Round 11 of the 2026-07-28 deprecation review.
#
# Round 10 replaced the reservation machinery with a per-feature gate held
# across `logger.warn`. Holding ANY lock across host code buys a lock-order
# inversion, and this one is reachable with nothing exotic: a real ::Logger
# serializes its writes behind its own device lock, so two threads that warn
# for two different features through the SAME logger take the two locks in
# opposite orders the moment either logger callback — a formatter, a log
# subscriber — touches a deprecated feature itself. Both threads then wait
# forever, and the sampling request, the log level or the SSE `connect` that
# raised the notice never returns. The same-thread case (a callback warning
# for the feature being logged) only escaped because CRuby raises ThreadError
# on a recursive lock and `emit_once` swallowed it in the rescue that means
# "the logger failed" — an accident, not a decision.
#
# The round 11 fix kept round 10's gate and added the one rule that seemed to
# make holding it safe: a thread already inside a notice never waits for a
# gate, its nested attempt standing down at once and leaving that notice owed
# to a later use — which is what the module already does with every notice it
# could not write. That rule was not enough, because the thread holding the
# logger's device lock need not be inside a notice at all (see the
# verification pass), so no caller waits for a notice any more. The examples
# below hold either way; what changed is the plain contender, which now
# stands down where round 10 had it wait.
#
# Also in this round: `Logger.new(nil)` is a supported no-output logger whose
# level sits below WARN, so the level probe accepted it and a notice was
# marked emitted that nobody could read; and a modern host can adopt the
# deprecated Logging utility without ever calling `log_level=`, by putting
# `io.modelcontextprotocol/logLevel` in `request_meta` or in a per-call
# `_meta` — which `with_request_meta` deliberately forwards on the wire.
RSpec.describe 'MCP 2026-07-28 deprecations (round 11)' do
  around do |example|
    MCPClient::Deprecations.enabled = true
    MCPClient::Deprecations.reset!
    example.run
  ensure
    MCPClient::Deprecations.reset!
    MCPClient::Deprecations.enabled = false
  end

  describe 'a notice raised from inside the logger of another notice' do
    # A logger that serializes its writes behind one lock, the way ::Logger's
    # LogDevice does. The first writer parks inside that lock until the
    # example releases it, and then runs the example's callback while it is
    # still held — a formatter or a log subscriber that itself reaches a
    # deprecated feature. Deliberately not a ::Logger, so the level probe
    # treats it as one that keeps warnings.
    let(:serializing_logger_class) do
      Class.new do
        attr_reader :messages, :nested

        def initialize(&on_first_write)
          @write_lock = Mutex.new
          @entered = Queue.new
          @go = Queue.new
          @messages = []
          @on_first_write = on_first_write
          @first = true
        end

        def warn(message)
          @write_lock.synchronize do
            if @first
              @first = false
              @entered << :entered
              @go.pop
              @nested = @on_first_write&.call
            end
            @messages << message
          end
          nil
        end

        # Wait until the first caller is inside #warn, holding the write lock.
        def await_entry = @entered.pop

        def release = (@go << :go)
      end
    end

    let(:threads) { [] }

    after { threads.each { |thread| thread.kill if thread.alive? } }

    def start(&block)
      thread = Thread.new(&block)
      threads << thread
      thread
    end

    # Nothing here is allowed to wedge the suite: a regression must fail the
    # example, not hang it. Seconds, not milliseconds, so a loaded CI box
    # never reports a deadlock that is only slowness.
    def finished?(thread)
      !thread.join(10).nil?
    end

    # Wait until every thread is parked (blocked or finished), so the example
    # exercises the queued path rather than a lucky ordering.
    def settle(*waiting)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until waiting.all? { |thread| thread.status == 'sleep' || !thread.status }
        raise 'threads never settled' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.001
      end
    end

    it 'stands down when the logger warns again for the feature being logged' do
      logger = serializing_logger_class.new { MCPClient::Deprecations.warn(:logging, logger) }
      emitter = start { MCPClient::Deprecations.warn(:logging, logger) }
      logger.await_entry
      logger.release

      expect(finished?(emitter)).to be(true), 'the emitting thread never came back out of its own notice'
      expect(emitter.value).to be(true)
      # The nested attempt neither duplicated the notice nor waited for it.
      expect(logger.nested).to be(false)
      expect(logger.messages.size).to eq(1)
      expect(MCPClient::Deprecations.emitted?(:logging)).to be(true)
    end

    it 'never waits for a second feature while it is inside the first one' do
      # The inversion: the emitting thread holds :logging and wants
      # :sampling, while the thread that holds :sampling wants the logger's
      # write lock this one is inside.
      logger = serializing_logger_class.new { MCPClient::Deprecations.warn(:sampling, logger) }
      emitter = start { MCPClient::Deprecations.warn(:logging, logger) }
      logger.await_entry
      contender = start { MCPClient::Deprecations.warn(:sampling, logger) }
      settle(contender)
      logger.release

      expect(finished?(emitter)).to be(true), 'the notice deadlocked against the logger it was writing to'
      expect(finished?(contender)).to be(true)
      expect(emitter.value).to be(true)
      # The notice the nested attempt stood down from was not lost: the
      # thread that was already holding it wrote it.
      expect(logger.nested).to be(false)
      expect(contender.value).to be(true)
      expect(logger.messages.size).to eq(2)
      expect(MCPClient::Deprecations.emitted?(:logging)).to be(true)
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
    end

    it 'leaves a nested notice owed when no one else is holding it' do
      logger = serializing_logger_class.new { MCPClient::Deprecations.warn(:sampling, logger) }
      emitter = start { MCPClient::Deprecations.warn(:logging, logger) }
      logger.await_entry
      logger.release

      expect(finished?(emitter)).to be(true)
      expect(logger.nested).to be(false)
      # Owed, not spent: the next use of Sampling still gets its notice.
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(false)
      output = StringIO.new
      expect(MCPClient::Deprecations.warn(:sampling, Logger.new(output))).to be(true)
      expect(output.string).to include('Sampling is deprecated')
    end

    it 'has a plain contender stand down instead of waiting for the emission' do
      # Round 10 had this contender wait; the verification pass took the wait
      # out, because a thread that queues for a notice cannot know whether it
      # is holding a lock the emitting thread needs. What it still must not
      # do is write a second copy.
      logger = serializing_logger_class.new
      emitter = start { MCPClient::Deprecations.warn(:logging, logger) }
      logger.await_entry
      output = StringIO.new
      contender = start { MCPClient::Deprecations.warn(:logging, Logger.new(output)) }

      expect(finished?(contender)).to be(true), 'the contender queued behind the emission in flight'
      expect(contender.value).to be(false)
      logger.release

      expect(finished?(emitter)).to be(true)
      expect(emitter.value).to be(true)
      expect(logger.messages.size).to eq(1)
      expect(output.string).not_to include('Logging is deprecated')
    end
  end

  describe 'a logger that writes nowhere' do
    it 'does not spend the notice on Logger.new(nil)' do
      # Logger.new(nil) is a supported no-output logger: its level defaults
      # to DEBUG, so the level probe passes and #warn returns true having
      # written nothing. Marking the notice emitted there would silence every
      # later warning from a logger that does write.
      silent = Logger.new(nil)

      expect(MCPClient::Deprecations.warn(:logging, silent)).to be(false)
      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)

      output = StringIO.new
      expect(MCPClient::Deprecations.warn(:logging, Logger.new(output))).to be(true)
      expect(output.string).to include('Logging is deprecated')
    end

    it 'does not break the deprecated operation the silent logger belongs to' do
      server = MCPClient::ServerStdio.new(command: 'true', logger: Logger.new(nil))
      allow(server).to receive(:ensure_initialized)
      allow(server).to receive(:modern?).and_return(true)

      expect { server.log_level = 'debug' }.not_to raise_error
      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)
    end

    it 'still spends the notice on a logger with a device' do
      # Only a logger built without a device is knowably unreadable. (Which
      # ones those are is a `logger` version question: 1.7 opens no file for
      # `Logger.new(File::NULL)` either, older versions do — hence a device
      # this example can actually read back.)
      expect(MCPClient::Deprecations.warn(:sampling, Logger.new(StringIO.new))).to be(true)
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
    end
  end

  describe 'the log level a modern request carries in its metadata' do
    let(:output) { StringIO.new }
    let(:logger) { Logger.new(output) }

    let(:transport_class) do
      Class.new do
        include MCPClient::JsonRpcCommon

        attr_reader :logger

        def initialize(logger, protocol_version)
          @logger = logger
          @protocol_version = protocol_version
        end
      end
    end

    let(:transport) { transport_class.new(logger, '2026-07-28') }

    it 'warns when the host default metadata carries the log level' do
      transport.request_meta = { 'io.modelcontextprotocol/logLevel' => 'debug' }

      params = transport.with_request_meta({ 'name' => 'tool' })

      expect(params['_meta']['io.modelcontextprotocol/logLevel']).to eq('debug')
      expect(output.string).to include('Logging is deprecated')
      expect(output.string).to include('SEP-2577')
    end

    it 'warns when a per-call _meta carries it, and only once' do
      2.times do
        transport.with_request_meta({ '_meta' => { 'io.modelcontextprotocol/logLevel' => 'warning' } })
      end

      expect(output.string.scan('Logging is deprecated').size).to eq(1)
    end

    # A host that writes the key as a Symbol — the natural Ruby spelling for
    # a hash literal — has adopted the deprecated utility just as much as one
    # that writes the String. On the modern path the question never arises:
    # `with_request_meta` builds the outgoing `_meta` and stringifies both the
    # defaults and the supplied hash on the way. The LEGACY passthrough is
    # where it does arise, because there the host's `_meta` goes out exactly
    # as it was written and is the very hash the notice reads.
    it 'warns when a legacy transport forwards a symbol-keyed log level' do
      legacy = transport_class.new(logger, '2025-06-18')

      params = legacy.with_request_meta({ '_meta' => { 'io.modelcontextprotocol/logLevel': 'debug' } })

      expect(params['_meta']).to eq({ 'io.modelcontextprotocol/logLevel': 'debug' })
      expect(output.string).to include('Logging is deprecated')
    end

    it 'warns when a legacy _meta is itself keyed by symbol' do
      legacy = transport_class.new(logger, '2025-06-18')

      params = legacy.with_request_meta({ _meta: { 'io.modelcontextprotocol/logLevel': 'warning' } })

      expect(params[:_meta]).to eq({ 'io.modelcontextprotocol/logLevel': 'warning' })
      expect(output.string).to include('Logging is deprecated')
    end

    it 'warns when a legacy transport forwards it untouched' do
      legacy = transport_class.new(logger, '2025-06-18')

      params = legacy.with_request_meta({ '_meta' => { 'io.modelcontextprotocol/logLevel' => 'debug' } })

      expect(params['_meta']['io.modelcontextprotocol/logLevel']).to eq('debug')
      expect(output.string).to include('Logging is deprecated')
    end

    it 'warns for a notification that carries it, on the same wire path' do
      transport.request_meta = -> { { 'io.modelcontextprotocol/logLevel' => 'error' } }

      transport.build_jsonrpc_notification('notifications/progress', {})

      expect(output.string).to include('Logging is deprecated')
    end

    it 'stays silent for a modern request that carries no log level' do
      transport.request_meta = { 'com.example/tenant' => 'acme' }

      params = transport.build_jsonrpc_request('tools/list', {}, 1)

      expect(params['params']['_meta']).to include('com.example/tenant' => 'acme')
      expect(output.string).not_to match(/deprecated/)
    end
  end

  describe 'the documentation for the transport on its way out' do
    let(:readme) { File.read(File.expand_path('../../../README.md', __dir__)) }
    let(:entry_point) { File.read(File.expand_path('../../../lib/mcp_client.rb', __dir__)) }

    it 'does not offer SSE as an unmarked elicitation transport' do
      bullet = readme.lines.find { |line| line.start_with?('- **Elicitation**') }

      expect(bullet).not_to be_nil
      expect(bullet).to match(/deprecated/i)
      expect(bullet.index('Streamable HTTP')).to be < bullet.index('HTTP+SSE')
    end

    it 'names the earliest removal where connect documents transport: :sse' do
      lines = entry_point.lines
      index = lines.index { |line| line.match?(/^\s*#\s*-\s*transport \[Symbol\]/) }
      expect(index).not_to be_nil

      entry = +lines[index]
      lines[(index + 1)..].each do |line|
        break if line.match?(/^\s*#\s*-\s/) || !line.match?(/^\s*#/)

        entry << line
      end

      expect(entry).to include('SEP-2596')
      expect(entry).to match(/three months after SEP-2596 reaches Final/)
      expect(entry).to include(':streamable_http')
    end

    it 'documents both new ways a notice can go unwritten' do
      paragraph = readme.split(/\n\n+/).find { |block| block.include?('Notices go to the logger') }

      expect(paragraph).not_to be_nil
      expect(paragraph).to include('`logger.warn`')
      expect(paragraph).to match(/blocks/)
      expect(paragraph).to match(/Logger\.new\(nil\)|writes nowhere|no output/i)
    end

    it 'documents the metadata route into the deprecated Logging utility' do
      logging_row = readme.lines.find { |line| line.start_with?('| Logging (') }

      expect(logging_row).not_to be_nil
      expect(logging_row).to include('io.modelcontextprotocol/logLevel')
    end
  end
end
