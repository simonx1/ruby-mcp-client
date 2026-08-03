#!/usr/bin/env ruby
# frozen_string_literal: true

# Example script demonstrating Streamable HTTP transport usage
# This transport is designed for servers that use HTTP POST requests
# but return Server-Sent Event formatted responses (like Zapier MCP)

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

# Create a logger for demonstration
logger = Logger.new($stdout)
logger.level = Logger::INFO

puts '=== Streamable HTTP Transport Example ==='
puts 'This example connects to a Streamable HTTP MCP server'
puts 'The server expects HTTP POST but responds with SSE format'
puts

# Server URL and Bearer token - set via environment variables
# Example:
#   MCP_SERVER_URL='https://mcp.zapier.com/api/v1/connect' \
#   MCP_BEARER_TOKEN='your_token' ./examples/streamable_http_example.rb
server_url = ENV.fetch('MCP_SERVER_URL', 'https://mcp.zapier.com/api/v1/connect')
bearer_token = ENV.fetch('MCP_BEARER_TOKEN', nil)
abort 'Please set MCP_SERVER_URL (and optionally MCP_BEARER_TOKEN for authenticated servers)' unless server_url

# Build headers with optional Bearer token authentication
headers = {}
headers['Authorization'] = "Bearer #{bearer_token}" if bearer_token

# Tracks whether anything failed, so the process exit status reflects it —
# printing an error while exiting 0 hides failures from CI and scripts.
example_failed = false

begin
  # Create client using the simplified connect API
  client = MCPClient.connect(server_url,
                             headers: headers,
                             read_timeout: 60,
                             retries: 3,
                             retry_backoff: 2,
                             name: 'example-streamable-server',
                             logger: logger)

  puts '✓ Client created successfully'

  # List available tools
  puts "\n📋 Listing available tools..."
  tools = client.list_tools

  puts "Found #{tools.size} tools:"
  tools.each do |tool|
    puts "  - #{tool.name}: #{tool.description&.split("\n")&.first || 'No description'}"
  end

  # Example tool call. The server picks which tools exist (for Zapier, an
  # arbitrary set of connected actions that may send mail, move money, or
  # change records), so this demo never invokes one on its own initiative:
  # name the tool you want with MCP_EXAMPLE_TOOL. A zero-argument tool is only
  # suggested, not called.
  requested_tool = ENV.fetch('MCP_EXAMPLE_TOOL', nil)

  if tools.empty?
    puts "\n⚠️  No tools available to call"
  elsif requested_tool
    tool = tools.find { |t| t.name == requested_tool }
    # An explicit request must not end in a success marker when it did not
    # run: a typo or a stale tool name has to be visible to a human and to
    # exit-code-driven automation.
    raise "MCP_EXAMPLE_TOOL=#{requested_tool} is not advertised by this server" unless tool

    required = (tool.schema && (tool.schema['required'] || tool.schema[:required])) || []
    unless required.empty?
      raise "MCP_EXAMPLE_TOOL=#{requested_tool} requires arguments #{required.inspect}; " \
            'this example only performs zero-argument calls'
    end

    puts "\n🔧 Calling tool requested via MCP_EXAMPLE_TOOL: #{tool.name}"
    result = client.call_tool(tool.name, {})
    puts 'Tool result:'
    puts result.inspect
  else
    suggestion = tools.find do |tool|
      required = (tool.schema && (tool.schema['required'] || tool.schema[:required])) || []
      required.empty?
    end
    puts "\nℹ️  No tool was called: this example does not invoke server-advertised tools on its own."
    puts "   Pick one explicitly, e.g. MCP_EXAMPLE_TOOL='#{(suggestion || tools.first).name}'"
    puts "   or in code: client.call_tool('#{(suggestion || tools.first).name}', { ... })"
  end

  # Test server connectivity
  puts "\n🏓 Testing server connectivity..."
  ping_result = client.ping
  puts "Ping result: #{ping_result.inspect}"

  puts "\n✅ Example completed successfully!"
rescue MCPClient::Errors::ConnectionError => e
  example_failed = true
  puts "\n❌ Connection Error: #{e.message}"
  puts 'Make sure your server URL and credentials are correct'
rescue MCPClient::Errors::TransportError => e
  example_failed = true
  puts "\n❌ Transport Error: #{e.message}"
  puts 'The server may not be returning valid SSE format'
rescue MCPClient::Errors::ServerError => e
  example_failed = true
  puts "\n❌ Server Error: #{e.message}"
rescue StandardError => e
  example_failed = true
  puts "\n❌ Unexpected Error: #{e.class}: #{e.message}"
ensure
  # Clean up connections
  client&.cleanup
  puts "\nConnection cleaned up."
end

puts "\n=== How Streamable HTTP Works ==="
puts '1. Client sends HTTP POST with JSON-RPC request'
puts '2. Server responds with SSE-formatted data:'
puts '   event: message'
puts '   data: {"jsonrpc":"2.0","id":1,"result":{...}}'
puts '3. Client parses SSE format and extracts JSON data'
puts '4. Standard JSON-RPC processing continues normally'
puts "\nThis allows HTTP semantics with streaming response format!"

exit(1) if example_failed
