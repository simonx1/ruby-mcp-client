# frozen_string_literal: true

require 'spec_helper'

# Round 9 of the 2026-07-28 deprecation review.
#
# Three threads of it.
#
# The bookkeeping first. A notice is owed once per process, and the slot was
# spent the moment a caller reserved it — before the logger had said anything.
# Two first uses that race with different loggers could therefore lose the
# notice outright: the reserving one blocks inside a broken logger while the
# contender, holding a logger that works, sees the slot taken and returns
# false; the reserving one then raises and releases the slot, and if there is
# no later use nothing is ever logged. A reservation and an emitted notice
# have to be distinguishable so a contender can wait for the outcome and take
# the notice over when the reservation fails.
#
# Then the places round 8's HTTP+SSE sweep did not reach. Round 8 marked the
# Overview bullet, the Quick Connect line, the `/sse` detection row and
# `sse_config` itself; the Advanced Configuration example that calls
# `sse_config`, the auto-detect fallback row, and `MCPClient.connect`'s
# multiple-server example and "Other HTTP URLs" text still offered the
# transport as an ordinary choice. This continues that sweep rather than
# repeating it.
#
# And two documentation claims that do not hold: `protocol:` /
# `discover_timeout:` are not carried to the HTTP+SSE transport by any route,
# and the deprecated-features table — which claims to list what triggers each
# first-use notice — omitted the transport-level Sampling trigger that round 8
# tagged on `on_sampling_request`.
RSpec.describe 'MCP 2026-07-28 deprecations (round 9)' do
  let(:readme) { File.read(File.expand_path('../../../README.md', __dir__)) }
  let(:module_source) { File.read(File.expand_path('../../../lib/mcp_client.rb', __dir__)) }

  # A bullet (or `@param`-style line) plus its continuation lines, stopping at
  # the next bullet or tag. Mirrors the round 7 and round 8 helper.
  def doc_block(source, start_pattern)
    lines = source.lines
    index = lines.index { |line| line.match?(start_pattern) }
    return nil unless index

    block = +lines[index].sub(/^\s*#\s?/, '')
    lines[(index + 1)..].each do |line|
      break unless line.match?(/^\s*#/)
      break if line.match?(/^\s*#\s*[@-]\s?\S/)

      block << " #{line.sub(/^\s*#\s?/, '').strip}"
    end
    block
  end

  # Every YARD `@example` in a source file, as [heading, body] pairs. A body
  # runs until the next tag or the end of the comment block.
  def yard_examples(source)
    examples = []
    open = false
    source.lines.each do |line|
      if (heading = line[/^\s*#\s*@example\s*(.*)$/, 1])
        examples << [heading.strip, +'']
        open = true
      elsif !open
        next
      elsif line.match?(/^\s*#\s*@\w/) || !line.match?(/^\s*#/)
        open = false
      else
        examples.last[1] << line.sub(/^\s*#\s?/, '')
      end
    end
    examples
  end

  # The comment lines directly above the first README line containing a marker.
  def readme_comment_above(marker)
    lines = readme.lines
    index = lines.index { |line| line.include?(marker) }
    return nil unless index

    block = []
    cursor = index - 1
    while cursor >= 0 && lines[cursor].match?(/^\s*#/)
      block.unshift(lines[cursor].sub(/^\s*#\s?/, '').strip)
      cursor -= 1
    end
    block.join(' ')
  end

  # A logger whose #warn blocks until the example releases it, and then either
  # raises or records the message. Deliberately not a ::Logger, so the level
  # probe treats it as one that keeps warnings.
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

  describe 'the once-per-process bookkeeping when two first uses race' do
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

    it 'does not count a reservation as an emitted notice' do
      reserver = Thread.new { MCPClient::Deprecations.warn(:roots, gated_logger) }
      gated_logger.await_entry

      # The slot is reserved, but nothing has been logged yet.
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)

      gated_logger.release(:succeed)
      expect(reserver.value).to be(true)
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
    end

    it 'hands the notice to the contender when the reservation fails' do
      reserver = Thread.new { MCPClient::Deprecations.warn(:roots, gated_logger) }
      gated_logger.await_entry

      contender = Thread.new { MCPClient::Deprecations.warn(:roots, working_logger) }
      # Let the contender reach the in-flight reservation before it resolves.
      sleep 0.05
      gated_logger.release(:raise)

      expect(reserver.value).to be(false)
      expect(contender.value).to be(true)
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
      expect(output.string).to match(/Roots is deprecated/)
    end

    it 'never loses the only viable notice, whatever the interleaving' do
      # Same race without the sleep: whichever way the two land, a working
      # logger was present for a first use, so a notice must have gone out.
      reserver = Thread.new { MCPClient::Deprecations.warn(:roots, gated_logger) }
      gated_logger.await_entry
      contender = Thread.new { MCPClient::Deprecations.warn(:roots, working_logger) }
      gated_logger.release(:raise)

      expect([reserver.value, contender.value]).to eq([false, true])
      expect(output.string).to match(/Roots is deprecated/)
    end

    it 'lets the contender stand down when the reservation succeeds' do
      reserver = Thread.new { MCPClient::Deprecations.warn(:roots, gated_logger) }
      gated_logger.await_entry
      contender = Thread.new { MCPClient::Deprecations.warn(:roots, working_logger) }
      sleep 0.05
      gated_logger.release(:succeed)

      expect(reserver.value).to be(true)
      expect(contender.value).to be(false)
      # Exactly one notice: the contender waited for the outcome rather than
      # logging a duplicate.
      expect(gated_logger.messages.size).to eq(1)
      expect(output.string).not_to match(/Roots is deprecated/)
    end

    it 'never holds up the deprecated operation behind a reservation that hangs' do
      reserver = Thread.new { MCPClient::Deprecations.warn(:roots, gated_logger) }
      gated_logger.await_entry

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # The reservation never resolves; the contender must give up on it.
      expect(MCPClient::Deprecations.warn(:roots, working_logger)).to be(false)
      waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(waited).to be <= (MCPClient::Deprecations::PENDING_WAIT_SECONDS * 4)
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)

      gated_logger.release(:succeed)
      reserver.join
    end
  end

  describe 'a reservation that fails with no contender waiting' do
    around do |example|
      MCPClient::Deprecations.enabled = true
      MCPClient::Deprecations.reset!
      example.run
    ensure
      MCPClient::Deprecations.reset!
      MCPClient::Deprecations.enabled = false
    end

    let(:output) { StringIO.new }

    it 'is still owed to the next use' do
      broken = Class.new do
        def warn(_message) = raise('logger is down')
      end.new

      expect(MCPClient::Deprecations.warn(:logging, broken)).to be(false)
      expect(MCPClient::Deprecations.emitted?(:logging)).to be(false)
      expect(MCPClient::Deprecations.warn(:logging, Logger.new(output))).to be(true)
      expect(output.string).to match(/Logging is deprecated/)
    end
  end

  describe 'the README, in the HTTP+SSE spots round 8 did not reach' do
    it 'marks the Advanced Configuration sse_config example' do
      comment = readme_comment_above('MCPClient.sse_config(')

      expect(comment).not_to be_nil
      expect(comment).to match(/deprecat/i)
      expect(comment).to include('Streamable HTTP')
    end

    it 'marks the auto-detect fallback row, which reaches for SSE too' do
      row = readme[/^\| Other HTTP URLs \|.*$/]

      expect(row).not_to be_nil
      expect(row).to match(/deprecat/i)
      expect(row).to include('#deprecated-features')
    end

    it 'leaves no unmarked SSE row in the transport-detection table' do
      table = readme[/^\| URL Pattern \| Transport \|.*?\n\n/m]
      sse_rows = table.lines.select { |line| line.start_with?('|') && line.match?(/SSE/) }

      expect(sse_rows).not_to be_empty
      sse_rows.each { |row| expect(row).to match(/deprecat/i), row }
    end
  end

  describe 'MCPClient.connect, in the spots round 8 did not reach' do
    it 'marks the "Other HTTP URLs" fallback, whose middle step is HTTP+SSE' do
      block = doc_block(module_source, /^\s*#\s*-\s*Other HTTP URLs\b/)

      expect(block).not_to be_nil
      expect(block).to match(/deprecat/i)
      expect(block).to include('SEP-2596')
    end

    it 'marks every @example that reaches for an /sse URL' do
      sse_examples = yard_examples(module_source).select { |_heading, body| body.include?('/sse') }

      # The dedicated SSE example still exists and is still marked; no other
      # example may casually reach for the deprecated transport.
      expect(sse_examples).not_to be_empty
      sse_examples.each do |heading, body|
        expect("#{heading} #{body}").to match(/deprecat/i), heading
      end
    end
  end

  describe 'the README claim that protocol: and discover_timeout: are available' do
    # The one prose paragraph that offers the two options.
    let(:paragraph) do
      readme.split(/\n\n+/).find { |block| block.include?('discover_timeout:') && !block.start_with?('```') }
    end

    it 'is made in a paragraph the sweep can find' do
      expect(paragraph).not_to be_nil
      expect(paragraph).to include('discover_timeout:')
    end

    it 'only names builders that really take both options' do
      named = %w[stdio_config http_config streamable_http_config sse_config]
              .select { |builder| paragraph.include?("`#{builder}`") }

      expect(named).not_to be_empty
      named.each do |builder|
        keywords = MCPClient.method(builder).parameters.map(&:last)
        expect(keywords).to include(:protocol), builder
        expect(keywords).to include(:discover_timeout), builder
      end
    end

    it 'does not offer them on the HTTP+SSE transport, which rejects them' do
      expect(MCPClient.method(:sse_config).parameters.map(&:last)).not_to include(:protocol, :discover_timeout)
      expect(MCPClient::ServerSSE.instance_method(:initialize).parameters.map(&:last))
        .not_to include(:protocol, :discover_timeout)
      expect(paragraph).not_to include('sse_config')
    end

    it 'says so, because MCPClient.connect silently drops them for an /sse URL' do
      dropped = MCPClient.send(:extract_sse_options, { protocol: :modern, discover_timeout: 5 })

      expect(dropped).not_to include(:protocol)
      expect(dropped).not_to include(:discover_timeout)
      expect(paragraph).to match(/HTTP\+SSE/)
      expect(paragraph).to match(/\bnot\b|never|no era|ignore/i)
    end
  end

  describe 'the deprecated-features table, which lists what triggers each notice' do
    it 'names the transport-level Sampling trigger round 8 tagged' do
      row = readme[/^\| Sampling .*$/]

      expect(row).not_to be_nil
      expect(row).to include('on_sampling_request')
    end

    it 'still names the Client-level triggers alongside it' do
      row = readme[/^\| Sampling .*$/]

      expect(row).to include('sampling_handler:')
      expect(row).to include('MCPClient.connect')
    end
  end
end
