# frozen_string_literal: true

require 'spec_helper'

# Round 7 of the 2026-07-28 deprecation review: the Roots notice fires for a
# host that actually uses Roots — a configured list, a `roots=` call, or an
# answer that carries a root — and not for the empty answer every Client
# gives by default; and the keyword APIs that carry a deprecated feature
# name the earliest removal, not just the SEP.
RSpec.describe 'MCP 2026-07-28 deprecations (round 7)' do
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
  let(:revision_window) { 'the first revision released on or after 2027-07-28' }

  describe 'the Roots notice and the host that never opted in' do
    # A Client registers its roots/list handler unconditionally (roots can be
    # set at any time through `roots=`), so "a handler is registered" says
    # nothing about whether the host adopted the deprecated feature. Only an
    # answer that actually carries a root does.
    def stdio_server(client)
      client.servers.first
    end

    let(:client_config) { MCPClient.stdio_config(command: 'true') }

    context 'with a Client that never configured a root' do
      let(:client) { MCPClient::Client.new(mcp_server_configs: [client_config], logger: logger) }

      it 'stays silent when it answers roots/list with the default empty list' do
        server = stdio_server(client)
        allow(server).to receive(:send_message)

        server.send(:handle_server_request, { 'id' => 1, 'method' => 'roots/list', 'params' => {} })

        expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
        expect(output.string).not_to match(/Roots/)
      end

      it 'still answers the request with an empty roots list' do
        server = stdio_server(client)
        sent = []
        allow(server).to receive(:send_message) { |message| sent << message }

        server.send(:handle_server_request, { 'id' => 1, 'method' => 'roots/list', 'params' => {} })

        expect(sent.last['result']).to eq({ 'roots' => [] })
      end
    end

    context 'with a Client that configured a root' do
      it 'warns when it answers roots/list with that root' do
        client = MCPClient::Client.new(mcp_server_configs: [client_config], logger: logger,
                                       roots: [{ uri: 'file:///workspace', name: 'Workspace' }])
        # The constructor's own notice is not what this example is about.
        MCPClient::Deprecations.reset!
        output.truncate(output.rewind)

        server = stdio_server(client)
        allow(server).to receive(:send_message)
        server.send(:handle_server_request, { 'id' => 1, 'method' => 'roots/list', 'params' => {} })

        expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
        expect(output.string).to match(/Roots .*deprecated/)
      end
    end

    context 'with a Client whose roots were set after construction' do
      it 'warns on the roots= call itself' do
        client = MCPClient::Client.new(mcp_server_configs: [client_config], logger: logger)
        # `roots=` tells every connected server the list changed; the stub
        # keeps this example off the wire, where `true` never answers and the
        # notification would wait out the discovery timeout.
        allow(stdio_server(client)).to receive(:rpc_notify)
        expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)

        client.roots = [{ uri: 'file:///workspace' }]

        expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
      end
    end

    context 'with a transport driven directly' do
      let(:server) { MCPClient::ServerStdio.new(command: 'true', logger: logger) }

      before { allow(server).to receive(:send_message) }

      it 'stays silent for a handler that answers with no roots' do
        server.on_roots_list_request { |_id, _params| { 'roots' => [] } }
        server.send(:handle_server_request, { 'id' => 1, 'method' => 'roots/list', 'params' => {} })

        expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
      end

      it 'warns for a handler that answers with a root' do
        server.on_roots_list_request { |_id, _params| { 'roots' => [{ 'uri' => 'file:///workspace' }] } }
        server.send(:handle_server_request, { 'id' => 1, 'method' => 'roots/list', 'params' => {} })

        expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
      end

      # The handler is host code and its answer is a plain Ruby Hash that
      # nothing converted, so a host that writes `{ roots: [...] }` — the
      # natural Ruby spelling — is using Roots exactly as much as one that
      # writes the string key. Reading only the string key makes the notice
      # depend on how the host happened to type the literal.
      it 'warns for a handler that answers with a symbol-keyed root' do
        server.on_roots_list_request { |_id, _params| { roots: [{ 'uri' => 'file:///workspace' }] } }
        server.send(:handle_server_request, { 'id' => 1, 'method' => 'roots/list', 'params' => {} })

        expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
      end

      it 'stays silent for a symbol-keyed answer that carries no root' do
        server.on_roots_list_request { |_id, _params| { roots: [] } }
        server.send(:handle_server_request, { 'id' => 1, 'method' => 'roots/list', 'params' => {} })

        expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
      end
    end

    context 'with the multi round-trip pattern' do
      let(:server) { MCPClient::ServerStdio.new(command: 'true', logger: logger) }

      def fulfil(server, response)
        server.on_roots_list_request { |_id, _params| response }
        server.send(:fulfil_input_request, 'roots',
                    { 'method' => 'roots/list', 'params' => {} },
                    { 'inputRequests' => {} })
      end

      it 'stays silent when the handler answers with no roots' do
        expect(fulfil(server, { 'roots' => [] })).to eq({ 'roots' => [] })

        expect(MCPClient::Deprecations.emitted?(:roots)).to be(false)
      end

      it 'warns when the handler answers with a root' do
        answer = { 'roots' => [{ 'uri' => 'file:///workspace' }] }
        expect(fulfil(server, answer)).to eq(answer)

        expect(MCPClient::Deprecations.emitted?(:roots)).to be(true)
      end
    end
  end

  describe 'the README' do
    let(:readme) { File.read(File.expand_path('../../../README.md', __dir__)) }

    it 'documents the trigger the Roots notice actually has' do
      row = readme[/^\| Roots \(.*$/]

      expect(row).not_to be_nil
      expect(row).to include('roots:')
      expect(row).to include('Client#roots=')
      expect(row).to match(%r{roots/list})
    end

    it 'says a client that never configured a root is not warned' do
      section = readme[/### Deprecated features\n.*?(?=\n## )/m]

      expect(section).to match(/empty (roots )?list/i)
    end
  end

  describe 'the keyword APIs that carry a deprecated feature' do
    # Feature lifecycle policy, tier-1 SDK obligation: an API that exposes a
    # deprecated feature names the SEP *and* the earliest removal wherever it
    # is documented. A keyword argument has no @deprecated tag of its own, so
    # the round 6 tag sweep never reached these. Round 8 extended the sweep to
    # the transport callbacks a host registers when it drives a transport
    # without a Client.
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

    let(:client_source) { File.read(File.expand_path('../../../lib/mcp_client/client.rb', __dir__)) }
    let(:module_source) { File.read(File.expand_path('../../../lib/mcp_client.rb', __dir__)) }

    # The @deprecated tag of the doc block above a definition.
    def deprecated_tag_above(source, definition)
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
      text
    end

    let(:transport_sources) do
      %w[server_sse server_stdio server_http server_streamable_http].to_h do |name|
        [name, File.read(File.expand_path("../../../lib/mcp_client/#{name}.rb", __dir__))]
      end
    end

    let(:transport_callbacks) do
      transport_sources.flat_map do |name, source|
        [["#{name} on_roots_list_request",
          deprecated_tag_above(source, /^\s*def on_roots_list_request\b/)],
         ["#{name} on_sampling_request",
          deprecated_tag_above(source, /^\s*def on_sampling_request\b/)]]
      end
    end

    let(:documented_apis) do
      [
        ['Client.new roots:', doc_block(client_source, /^\s*#\s*@param roots\b/)],
        ['Client.new sampling_handler:', doc_block(client_source, /^\s*#\s*@param sampling_handler\b/)],
        ['MCPClient.connect sampling_handler', doc_block(module_source, /^\s*#\s*-\s*sampling_handler\b/)]
      ] + transport_callbacks
    end

    it 'documents every one of them' do
      documented_apis.each do |label, block|
        expect(block).not_to(be_nil, label)
      end
    end

    it 'marks each one deprecated, with its SEP and its earliest removal' do
      windows = registry.each_value.map { |entry| entry[:earliest_removal] }.uniq

      documented_apis.each do |label, block|
        expect(block).to match(/deprecat/i), "#{label}: #{block}"
        expect(block).to include('SEP-2577'), "#{label}: #{block}"
        expect(windows.any? { |window| block.include?(window) }).to be(true), "#{label}: #{block}"
      end
    end

    it 'names the same window the registry gives Roots and Sampling' do
      documented_apis.each do |label, block|
        expect(block).to include(revision_window), "#{label}: #{block}"
      end
    end
  end
end
