# frozen_string_literal: true

require 'spec_helper'

# Round 8 of the 2026-07-28 deprecation review.
#
# HTTP+SSE is the one deprecated feature on a short clock — three months
# after SEP-2596 reaches Final, and SEP-2596 is Final — and it is also the
# place a new integration is most likely to start, so every spot that offers
# it as an ordinary choice among the transports has to say so and point at
# Streamable HTTP.
#
# And the transport-level callback registrations for Roots and Sampling carry
# the native @deprecated mark: a host that drives a transport directly and
# copies `server.on_sampling_request { ... }` out of the YARD would otherwise
# meet SEP-2577 for the first time in a runtime notice. Round 7 deliberately
# stopped treating a registered `roots/list` handler as use of Roots, so
# without a mark at the registration site that handler has no mark at all.
RSpec.describe 'MCP 2026-07-28 deprecations (round 8)' do
  let(:registry) { MCPClient::Deprecations::REGISTRY }
  let(:sse_window) { registry[:http_sse_transport][:earliest_removal] }
  let(:revision_window) { MCPClient::Deprecations::REVISION_AFTER_2027_07_28 }
  let(:readme) { File.read(File.expand_path('../../../README.md', __dir__)) }
  let(:module_source) { File.read(File.expand_path('../../../lib/mcp_client.rb', __dir__)) }

  # The comment block immediately above a definition, joined into one string.
  def preceding_doc(source, definition)
    lines = source.lines
    index = lines.index { |line| line.match?(definition) }
    return nil unless index

    block = []
    cursor = index - 1
    while cursor >= 0 && lines[cursor].match?(/^\s*#/)
      block.unshift(lines[cursor].sub(/^\s*#\s?/, '').strip)
      cursor -= 1
    end
    block.join(' ')
  end

  # A bullet (or `@param`-style line) plus its continuation lines, stopping at
  # the next bullet or tag. Mirrors the round 7 helper.
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

  describe 'the README, wherever HTTP+SSE is offered as a choice' do
    it 'marks the Overview transport bullet and names Streamable HTTP' do
      bullet = readme[/^- \*\*SSE\*\*.*$/]

      expect(bullet).not_to be_nil
      expect(bullet).to match(/deprecat/i)
      expect(bullet).to include('Streamable HTTP')
    end

    it 'marks the Quick Connect line that reaches for an /sse URL' do
      line = readme[%r{^client = MCPClient\.connect\('http://localhost:8000/sse'\).*$}]

      expect(line).not_to be_nil
      expect(line).to match(/deprecat/i)
    end

    it 'marks the /sse row of the transport-detection table' do
      row = readme[%r{^\| Ends with `/sse` \|.*$}]

      expect(row).not_to be_nil
      expect(row).to match(/deprecat/i)
    end

    it 'points every one of those marks at the deprecated-features section' do
      overview = readme[/^- \*\*SSE\*\*.*$/]
      table_row = readme[%r{^\| Ends with `/sse` \|.*$}]

      [overview, table_row].each do |text|
        expect(text).to include('#deprecated-features'), text
      end
    end

    it 'keeps the deprecated-features table as the place the window is spelled out' do
      row = readme[/^\| HTTP\+SSE transport .*$/]

      expect(row).to include(sse_window)
    end
  end

  describe 'MCPClient.connect, where the transport is chosen' do
    it 'marks the /sse target bullet with the SEP and the earliest removal' do
      block = doc_block(module_source, %r{^\s*#\s*-\s*URLs ending in /sse\b})

      expect(block).not_to be_nil
      expect(block).to match(/deprecat/i)
      expect(block).to include('SEP-2596')
      expect(block).to include(sse_window)
      expect(block).to include('Streamable HTTP')
    end

    it 'marks the @example that connects to an SSE server' do
      heading = module_source[/^\s*#\s*@example Connect to (an )?SSE server.*$/]

      expect(heading).not_to be_nil
      expect(heading).to match(/deprecat/i)
    end
  end

  describe 'MCPClient.sse_config' do
    it 'carries a native @deprecated tag' do
      doc = preceding_doc(module_source, /^\s*def self\.sse_config\b/)

      expect(doc).to include('@deprecated')
    end

    it 'cites SEP-2596, the earliest removal and the replacement builder' do
      doc = preceding_doc(module_source, /^\s*def self\.sse_config\b/)

      expect(doc).to include('SEP-2596')
      expect(doc).to include(sse_window)
      expect(doc).to include('streamable_http_config')
    end
  end

  describe 'the transport callbacks for the deprecated SEP-2577 features' do
    {
      'ServerSSE' => 'server_sse.rb',
      'ServerStdio' => 'server_stdio.rb',
      'ServerHTTP' => 'server_http.rb',
      'ServerStreamableHTTP' => 'server_streamable_http.rb'
    }.each do |transport, file|
      context "on #{transport}" do
        let(:source) { File.read(File.expand_path("../../../lib/mcp_client/#{file}", __dir__)) }
        let(:sampling_doc) { preceding_doc(source, /^\s*def on_sampling_request\b/) }
        let(:roots_doc) { preceding_doc(source, /^\s*def on_roots_list_request\b/) }

        it 'marks on_sampling_request at the registration site' do
          expect(sampling_doc).to include('@deprecated')
          expect(sampling_doc).to include('SEP-2577')
          expect(sampling_doc).to include(revision_window)
        end

        it 'marks on_roots_list_request at the registration site' do
          expect(roots_doc).to include('@deprecated')
          expect(roots_doc).to include('SEP-2577')
          expect(roots_doc).to include(revision_window)
        end

        it 'warns at the roots registration site that an answer carrying a root is the use' do
          # Round 7 made registration alone silent at runtime, so the mark is
          # the only thing that reaches a host reading the YARD.
          expect(roots_doc).to match(/registering .*not/i)
          expect(roots_doc).to match(/root/i)
        end
      end
    end
  end
end
