# frozen_string_literal: true

require 'spec_helper'

# Round 5 of the 2026-07-28 deprecation review: a logger that misbehaves must
# never reach the deprecated operation (not even through its `level`
# accessor), and the earliest removal of each feature lives in the registry
# so the prose cannot drift away from it.
RSpec.describe 'MCP 2026-07-28 deprecations (round 5)' do
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

  # A Logger subclass whose level accessor is broken: asking whether it drops
  # warnings raises, exactly as a custom logger with a lazily configured level
  # might.
  let(:broken_level_logger) do
    Class.new(Logger) do
      def level = raise(IOError, 'level unavailable')
    end.new(File::NULL)
  end

  describe 'a logger whose level accessor raises' do
    it 'declines the notice without spending it and without raising' do
      expect(MCPClient::Deprecations.warn(:roots, broken_level_logger)).to be(false)
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)

      expect(MCPClient::Deprecations.warn(:roots, logger)).to be(true)
      expect(output.string).to match(/Roots .*deprecated/)
    end

    it 'keeps serving the deprecated features it guards' do
      broken = broken_level_logger
      handler = lambda { |_messages, _prefs, _system, _max|
        { 'role' => 'assistant', 'content' => { 'type' => 'text', 'text' => 'ok' }, 'model' => 'm' }
      }
      c = MCPClient::Client.new(mcp_server_configs: [], logger: broken, sampling_handler: handler,
                                roots: [{ uri: 'file:///tmp', name: 'tmp' }])
      params = { 'messages' => [], 'maxTokens' => 5, 'includeContext' => 'thisServer' }

      expect(c.send(:handle_sampling_request, 1, params)['content']['text']).to eq('ok')
      expect { c.log_level = 'debug' }.not_to raise_error

      server = MCPClient::ServerSSE.new(base_url: 'http://localhost:1/sse', logger: broken)
      allow(server).to receive(:start_sse_thread)
      allow(server).to receive(:wait_for_connection)
      allow(server).to receive(:start_activity_monitor)
      expect(server.connect).to be(true)
    end
  end

  # `level` is host code, and the notice asks for it BEFORE it writes. A host
  # whose accessor reaches back into a deprecated feature therefore re-enters
  # the notice on a path the reentrancy guard has to cover too: a guard that
  # only wraps `logger.warn` leaves the probe recursing until the stack ends,
  # and a SystemStackError is not a StandardError, so it escapes the rescue
  # that exists to keep the deprecated operation working.
  describe 'a logger whose level accessor re-enters a deprecated feature' do
    # A `level` accessor that uses Roots, as a formatter, a log subscriber or
    # an audit hook reading the client's configuration would.
    def reentrant_logger(io)
      Class.new(Logger) do
        attr_accessor :client

        def level
          @client&.roots = []
          super
        end
      end.new(io)
    end

    it 'still sets the roots, and lets the nested notice stand down' do
      broken = reentrant_logger(output)
      client = MCPClient::Client.new(mcp_server_configs: [], logger: broken)
      broken.client = client

      expect { client.roots = [{ uri: 'file:///workspace', name: 'Workspace' }] }.not_to raise_error
      expect(client.roots.map(&:uri)).to eq(['file:///workspace'])
    end

    it 'writes the notice exactly once, from the outermost use' do
      broken = reentrant_logger(output)
      client = MCPClient::Client.new(mcp_server_configs: [], logger: broken)
      broken.client = client

      client.roots = [{ uri: 'file:///workspace', name: 'Workspace' }]

      expect(output.string.scan(/Roots .*deprecated/).size).to eq(1)
    end
  end

  # A standard ::Logger whose device was closed swallows the write failure
  # inside Logger::LogDevice (it rescues and reports through Kernel#warn), so
  # `logger.warn` returns as if it had written. Counting that as the notice
  # spends the process's one notice on a line nobody can read, and silences
  # every later use — including one holding a logger that does write.
  describe 'a standard logger whose device is closed' do
    let(:closed_logger) do
      Logger.new(StringIO.new).tap(&:close)
    end

    it 'declines the notice without spending it' do
      expect(MCPClient::Deprecations.warn(:roots, closed_logger)).to be(false)
      expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
    end

    it 'leaves the notice owed, so a working logger still writes it' do
      MCPClient::Deprecations.warn(:roots, closed_logger)

      expect(MCPClient::Deprecations.warn(:roots, logger)).to be(true)
      expect(output.string).to match(/Roots .*deprecated/)
    end

    it 'keeps serving the deprecated feature' do
      client = MCPClient::Client.new(mcp_server_configs: [], logger: closed_logger)

      expect { client.roots = [{ uri: 'file:///workspace', name: 'Workspace' }] }.not_to raise_error
      expect(client.roots.map(&:uri)).to eq(['file:///workspace'])
    end
  end

  describe 'the earliest removal of each feature' do
    let(:registry) { MCPClient::Deprecations::REGISTRY }

    it 'is recorded for every feature' do
      registry.each do |key, entry|
        expect(entry[:earliest_removal]).to be_a(String), key.to_s
        expect(entry[:earliest_removal]).not_to be_empty, key.to_s
      end
    end

    it 'gives the features 2026-07-28 deprecates one shared clock' do
      # The exact wording is pinned in the round 6 spec, against the
      # registry's own "Earliest removal" column; here only the grouping.
      long_window = registry[:sampling][:earliest_removal]
      %i[roots logging dynamic_client_registration].each do |key|
        expect(registry[key][:earliest_removal]).to eq(long_window), key.to_s
      end

      # SEP-2596 reclassified both the HTTP+SSE transport and the
      # includeContext values, but only the transport has a clock of its own:
      # the transition provision ties includeContext to Sampling.
      expect(registry[:include_context][:earliest_removal]).to match(/follows Sampling/)
      expect(registry[:http_sse_transport][:earliest_removal]).not_to eq(long_window)
      expect(registry[:http_sse_transport][:earliest_removal]).to match(/SEP-2596/)
    end

    # The table row each feature owns, so a clock cannot satisfy the pin from
    # some other feature's row.
    let(:rows) do
      {
        roots: /^\| Roots \(.*$/,
        sampling: /^\| Sampling \(.*$/,
        logging: /^\| Logging \(.*$/,
        http_sse_transport: /^\| HTTP\+SSE transport \(.*$/,
        include_context: /^\| `includeContext`.*$/,
        dynamic_client_registration: /^\| OAuth Dynamic Client Registration.*$/
      }
    end

    it 'is what the README documents, verbatim, on that feature\'s own row' do
      readme = File.read(File.expand_path('../../../README.md', __dir__))
      section = readme[/### Deprecated features.*?\n## /m] || readme
      expect(rows.keys).to match_array(registry.keys)
      registry.each do |key, entry|
        row = section[rows.fetch(key)]
        expect(row).not_to be_nil, "no README table row for #{key}"
        expect(row).to include(entry[:earliest_removal]), "#{key}: #{row}"
      end
    end
  end
end
