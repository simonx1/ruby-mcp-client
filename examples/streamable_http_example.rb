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

  # Example tool call (adjust based on your server's tools)
  if tools.any?
    first_tool = tools.first
    puts "\n🔧 Calling tool: #{first_tool.name}"

    # NOTE: Adjust parameters based on your tool's input schema
    result = client.call_tool(first_tool.name, {})

    puts 'Tool result:'
    puts result.inspect
  else
    puts "\n⚠️  No tools available to call"
  end

  # Test server connectivity
  puts "\n🏓 Testing server connectivity..."
  ping_result = client.ping
  puts "Ping result: #{ping_result.inspect}"

  puts "\n✅ Example completed successfully!"
rescue MCPClient::Errors::ConnectionError => e
  puts "\n❌ Connection Error: #{e.message}"
  puts 'Make sure your server URL and credentials are correct'
rescue MCPClient::Errors::TransportError => e
  puts "\n❌ Transport Error: #{e.message}"
  puts 'The server may not be returning valid SSE format'
rescue MCPClient::Errors::ServerError => e
  puts "\n❌ Server Error: #{e.message}"
rescue StandardError => e
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
