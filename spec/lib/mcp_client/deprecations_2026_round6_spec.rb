# frozen_string_literal: true

require 'spec_helper'

# Round 6 of the 2026-07-28 deprecation review: the registry carries the
# deprecated-features registry's own earliest-removal wording (a revision, not
# a calendar date), every YARD mark and the runtime notice name that clock,
# the notices fire from the transport entry points a host can reach without a
# Client, and the once-per-process bookkeeping survives a fork.
RSpec.describe 'MCP 2026-07-28 deprecations (round 6)' do
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
      report = reader.read
      reader.close
      Process.wait(pid)

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
