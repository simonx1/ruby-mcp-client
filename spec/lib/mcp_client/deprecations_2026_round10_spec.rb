# frozen_string_literal: true

require 'spec_helper'

# Round 10 of the 2026-07-28 deprecation review.
#
# Round 9 gave a notice two states — `:pending` while a caller is inside
# `logger.warn`, `:emitted` once one succeeded — so that a contender could
# wait for a reservation's outcome and take the notice over when the
# reservation failed. The wait was bounded by a timeout, on the strength of a
# promise this path cannot keep: that a notice never holds up the deprecated
# operation.
#
# It cannot keep it, and the bound did not buy it. The bound constrains the
# CONTENDERS, never the reservation's owner: a first use whose logger blocks
# forever — a synchronous remote logger, stalled I/O — never returns from
# `warn` at all, so the client construction, SSE connection or incoming
# request that triggered it never completes either. And what the contenders
# bought with their wait was nothing: a reservation that hangs is never
# released, so every later first use of that feature waited the timeout out
# again and still came away without the notice. Sampling, Logging and the
# HTTP+SSE transport all have trigger points that are hit repeatedly, so
# "every later first use" is not a corner case.
#
# The two ways to keep the stronger promise are both worse than dropping it.
# A detached emission thread stops blocking anything but loses the ordering
# between the notice and the operation it describes, and needs a thread per
# stalled notice. `Timeout.timeout` around a host's logger raises inside
# arbitrary third-party code — during its own IO, ensure blocks or internal
# locking — which is how you corrupt a logger, not how you protect a caller.
#
# So the promise is narrowed to the one the rest of the library already makes:
# every other `logger.warn` in this codebase blocks its caller exactly the
# same way, and a logger that blocks forever blocks the library everywhere,
# not only here. A notice costs its caller what one `logger.warn` costs it,
# no more. What survives is what was real: the notice fires once per process,
# a logger that raises or drops warnings neither breaks the deprecated
# operation nor spends the notice, and the bookkeeping is rebuilt after a
# fork. The reservation states, the condition variable and the timeout — the
# machinery that existed only to serve the stronger promise — go, and with
# them the wait that yielded nothing.
#
# Also: the `ServerHTTP` elicitation note, the last place that still offered
# the HTTP+SSE transport as an ordinary alternative.
RSpec.describe 'MCP 2026-07-28 deprecations (round 10)' do
  # A logger whose #warn blocks until the example releases it, and then either
  # raises or records the message. Deliberately not a ::Logger, so the level
  # probe treats it as one that keeps warnings. Mirrors the round 9 helper.
  gated_logger_class = Class.new do
    def initialize
      @entered = Queue.new
      @release = Queue.new
      @messages = []
    end

    attr_reader :messages

    # Block until #release, then behave as instructed.
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

  describe 'a third first use, while the first one is stuck in its logger' do
    around do |example|
      MCPClient::Deprecations.enabled = true
      MCPClient::Deprecations.reset!
      example.run
    ensure
      MCPClient::Deprecations.reset!
      MCPClient::Deprecations.enabled = false
    end

    let(:output) { StringIO.new }
    let(:working_logger) { Logger.new(output) }
    let(:gated_logger) { gated_logger_class.new }

    # Wait until every thread is parked (blocked or finished), so the example
    # exercises the queued path rather than a lucky ordering. Milliseconds:
    # nothing here waits a timeout out.
    def settle(*threads)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until threads.all? { |thread| thread.status == 'sleep' || !thread.status }
        raise 'threads never settled' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.001
      end
    end

    # These two examples state an outcome the timed-out reservation could only
    # reach when the release beat the timeout — which is why they release
    # immediately: an example that let the timeout expire would have to spend
    # it, and spending it is the cost being removed. With the timeout gone the
    # outcome holds however long the stuck logger stays stuck.
    it 'is still owed the notice when the stuck logger finally fails' do
      # Logging's notice fires from every notifications/message and every
      # log_level=, so a second and a third first use are routine.
      owner = Thread.new { MCPClient::Deprecations.warn(:logging, gated_logger) }
      gated_logger.await_entry

      second = Thread.new { MCPClient::Deprecations.warn(:logging, working_logger) }
      third = Thread.new { MCPClient::Deprecations.warn(:logging, working_logger) }
      settle(second, third)
      gated_logger.release(:raise)

      expect(owner.value).to be(false)
      # Neither later use came away empty-handed: one of them logged the
      # notice the failed one owed, the other stood down because it was
      # already out. Under the timed-out reservation both got nothing.
      expect([second.value, third.value].count(true)).to eq(1)
      expect(MCPClient::Deprecations.emitted?(:logging)).to be(true)
      expect(output.string.scan('Logging is deprecated').size).to eq(1)
    end

    it 'stands down exactly once when the stuck logger finally succeeds' do
      owner = Thread.new { MCPClient::Deprecations.warn(:logging, gated_logger) }
      gated_logger.await_entry

      second = Thread.new { MCPClient::Deprecations.warn(:logging, working_logger) }
      third = Thread.new { MCPClient::Deprecations.warn(:logging, working_logger) }
      settle(second, third)
      gated_logger.release(:succeed)

      expect(owner.value).to be(true)
      expect([second.value, third.value]).to eq([false, false])
      expect(gated_logger.messages.size).to eq(1)
      expect(output.string).not_to match(/Logging is deprecated/)
    end

    it 'never reaches past the feature it is logging' do
      owner = Thread.new { MCPClient::Deprecations.warn(:logging, gated_logger) }
      gated_logger.await_entry

      # A notice blocks its own caller like any logger.warn, but a notice in
      # flight is not a lock over the module: another feature's first use
      # goes out while this one is still stuck, and so does the bookkeeping.
      expect(MCPClient::Deprecations.warn(:sampling, working_logger)).to be(true)
      expect(MCPClient::Deprecations.emitted?(:sampling)).to be(true)
      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)

      gated_logger.release(:succeed)
      expect(owner.value).to be(true)
    end
  end

  describe 'the promise the module makes about what a notice costs' do
    let(:source) { File.read(File.expand_path('../../../lib/mcp_client/deprecations.rb', __dir__)) }
    let(:readme) { File.read(File.expand_path('../../../README.md', __dir__)) }

    it 'no longer claims a notice never holds up the deprecated operation' do
      expect(source).not_to match(/holds? up the deprecated operation/)
      expect(MCPClient::Deprecations.constants).not_to include(:PENDING_WAIT_SECONDS)
    end

    it 'does not buy the claim back with a timeout around host logger code' do
      expect(source).not_to include('Timeout')
      expect(source).not_to include('Thread.new')
    end

    it 'says what a notice does cost, in the terms the rest of the library sets' do
      expect(source).to match(/costs its caller what (a|one) `?logger\.warn`? costs it/i)
    end

    it 'still promises what it can keep' do
      expect(source).to match(/once per process/i)
      expect(source).to match(/never breaks the deprecated (operation|feature)|keeps working whatever the log does/i)
    end

    it 'says it in the README too, where the notices are documented' do
      paragraph = readme.split(/\n\n+/).find { |block| block.include?('Notices go to the logger') }

      expect(paragraph).not_to be_nil
      expect(paragraph).to include('`logger.warn`')
      expect(paragraph).to match(/blocks/)
    end
  end

  describe 'the ServerHTTP elicitation note, which offers other transports' do
    let(:note) do
      source = File.read(File.expand_path('../../../lib/mcp_client/server_http.rb', __dir__))
      lines = source.lines
      start = lines.index { |line| line.match?(/@note Elicitation Support/) }
      raise 'elicitation note not found' unless start

      stop = lines[start..].index { |line| !line.match?(/^\s*#/) }
      lines[start, stop].join
    end

    # A bullet in the note, with the continuation lines that belong to it.
    def entry_for(note, transport)
      lines = note.lines
      index = lines.index { |line| line.match?(/^\s*#\s*-\s*#{transport}\b/) }
      return nil unless index

      entry = +lines[index]
      lines[(index + 1)..].each do |line|
        break if line.match?(/^\s*#\s*-\s/)

        entry << line
      end
      entry
    end

    it 'marks the HTTP+SSE alternative as deprecated, as everywhere else does' do
      sse_entry = entry_for(note, 'ServerSSE')

      expect(sse_entry).not_to be_nil
      expect(sse_entry).to match(/deprecat/i)
      expect(sse_entry).to include('SEP-2596')
      expect(sse_entry).to include('ServerStreamableHTTP')
    end

    it 'offers Streamable HTTP before the transport on its way out' do
      expect(note.index('ServerStreamableHTTP')).to be < note.index('ServerSSE')
    end
  end
end
