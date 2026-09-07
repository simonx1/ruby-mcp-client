#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: the MCP 2026-07-28 protocol end to end.
#
# The 2026-07-28 revision is stateless. There is no `initialize` handshake and
# no session: the client identifies the server with a `server/discover` probe,
# then carries its own identity in each request's `_meta`. This example walks
# the parts of that revision a host actually touches:
#
#   1. era detection            — modern?, protocol_version, protocol_era
#   2. cacheable results        — ttlMs / cacheScope and cache_info
#   3. structured output        — structuredContent validated against outputSchema
#   4. x-mcp-header parameters  — a tool argument travelling as a request header
#   5. typed errors             — the three JSON-RPC codes the revision adds
#
# Subscriptions and multi round-trip requests have examples of their own:
# subscriptions_listen_example.rb and multi_round_trip_example.rb.
#
# Start the server first:
#
#   python3 examples/mcp_2026_07_28_server.py &   # port 8933
#   ruby examples/mcp_2026_07_28_features.rb
#
# Point it elsewhere with MCP_SERVER_URL.

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

logger = Logger.new($stdout)
logger.level = Logger::WARN

server_url = ENV.fetch('MCP_SERVER_URL', 'http://localhost:8933/mcp')

client = MCPClient.create_client(
  mcp_server_configs: [MCPClient.streamable_http_config(base_url: server_url)],
  logger: logger
)

failures = []

def section(title)
  puts "\n#{title}"
  puts '─' * title.length
end

def check(label, condition, detail = nil)
  suffix = detail ? " — #{detail}" : ''
  puts "  #{condition ? '✅' : '❌'} #{label}#{suffix}"
  condition
end

begin
  # --- 1. Era detection ----------------------------------------------------
  # The client probes with server/discover before anything else. A modern
  # answer means no handshake and no session id on any later request.
  section('1. Protocol era')
  server = client.servers.first
  client.list_tools # forces the probe

  failures << 'era' unless check('modern?', server.modern?, server.modern?.inspect)
  failures << 'version' unless check('protocol_version', server.protocol_version == '2026-07-28',
                                     server.protocol_version)
  failures << 'era name' unless check('protocol_era', server.protocol_era == :modern, server.protocol_era.inspect)

  # --- 2. Cacheable results ------------------------------------------------
  # Lists carry ttlMs and cacheScope. While a list is fresh the client serves
  # it from memory instead of asking again.
  section('2. Cacheable results')
  info = server.cache_info(:tools)
  failures << 'ttl' unless check('tools list has a ttl', info && info[:ttl_ms].to_i.positive?,
                                 info && "ttlMs=#{info[:ttl_ms]}")
  failures << 'scope' unless check('cacheScope recorded', info && info[:cache_scope] == 'public',
                                   info && info[:cache_scope])
  failures << 'fresh' unless check('entry is fresh', info && info[:fresh], info && info[:fresh].inspect)

  read = client.read_resource('file:///reports/summary.txt')
  read_info = server.cache_info(:read, 'file:///reports/summary.txt')
  failures << 'read cached' unless check('resources/read cached per URI', !read_info.nil?,
                                         read_info && "ttlMs=#{read_info[:ttl_ms]}")
  first = read.is_a?(Array) ? read.first : (read['contents'] || read[:contents])&.first
  puts "     read: #{first.respond_to?(:text) ? first.text : first.inspect}"

  # --- 3. Structured output ------------------------------------------------
  # 2026-07-28 widened structuredContent to any JSON value. When the tool
  # declares an outputSchema the client validates the result against it.
  section('3. Structured output')
  echoed = client.call_tool('echo', { 'message' => 'hello 2026' })
  structured = echoed['structuredContent'] || echoed[:structuredContent]
  failures << 'structured' unless check('structuredContent returned', !structured.nil?, structured.inspect)
  failures << 'structured value' unless check('matches the outputSchema',
                                              structured && structured['echoed'] == 'hello 2026' &&
                                              structured['length'] == 10)

  # --- 4. x-mcp-header parameters -----------------------------------------
  # `tenant` is annotated x-mcp-header in the tool definition, so the client
  # sends it as the Mcp-Param-tenant header rather than in the JSON body. The
  # server here refuses the call when the header is missing.
  section('4. Parameters carried as headers')
  report = client.call_tool('tenant_report', { 'tenant' => 'acme', 'section' => 'usage' })
  text = (report['content'] || report[:content])&.first&.fetch('text', nil)
  failures << 'header param' unless check('tool answered from the header', text.to_s.include?('acme'), text)

  # --- 5. Typed errors -----------------------------------------------------
  # The revision adds three JSON-RPC codes, each with its own error class.
  section('5. Typed errors')
  {
    'header_mismatch' => MCPClient::Errors::HeaderMismatchError,
    'missing_capability' => MCPClient::Errors::MissingRequiredClientCapabilityError,
    'unsupported_version' => MCPClient::Errors::UnsupportedProtocolVersionError
  }.each do |trigger, klass|
    client.call_tool('echo', { 'message' => 'x', 'fail_with' => trigger })
    failures << trigger
    check("#{trigger} raises #{klass.name.split('::').last}", false, 'no error raised')
  rescue klass => e
    check("#{trigger} raises #{klass.name.split('::').last}", true, e.message[0, 60])
  rescue StandardError => e
    failures << trigger
    check("#{trigger} raises #{klass.name.split('::').last}", false, "got #{e.class}: #{e.message[0, 60]}")
  end

  puts
  if failures.empty?
    puts '✅ MCP 2026-07-28 features demo completed successfully'
  else
    puts "❌ failed checks: #{failures.uniq.join(', ')}"
    exit 1
  end
rescue StandardError => e
  puts "\n❌ #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
  exit 1
ensure
  client.cleanup
end
