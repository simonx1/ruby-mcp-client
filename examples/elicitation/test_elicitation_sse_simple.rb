#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple MCP Elicitation Example - SSE Transport
#
# This example demonstrates SSE (Server-Sent Events) transport for MCP elicitation.
# SSE transport uses:
#   - Server-to-client: SSE stream for pushing requests
#   - Client-to-server: HTTP POST for sending responses
#
# Usage:
#   # Start the server:
#   python examples/elicitation/elicitation_streamable_server.py
#
#   # Run this client:
#   ruby examples/elicitation/test_elicitation_sse_simple.rb

require 'bundler/setup'
require 'mcp_client'

puts '=' * 60
puts 'Simple MCP Elicitation Example - SSE Transport'
puts '=' * 60
puts

# Simple elicitation handler
elicitation_handler = lambda do |message, _schema|
  puts "\n📡 Server request: #{message}"

  # Auto-accept with sample data
  case message
  when /document details/
    puts "✓ Providing: title='Quick Doc', author='Demo User'"
    { 'action' => 'accept', 'content' => { 'title' => 'Quick Doc', 'author' => 'Demo User' } }
  when /content/
    puts '✓ Providing content'
    { 'action' => 'accept', 'content' => { 'content' => 'This is demo content from SSE transport.' } }
  else
    puts '✓ Accepting request'
    { 'action' => 'accept' }
  end
end

# Create client with SSE transport
# SSE transport uses separate endpoints:
#   - GET /sse - Opens SSE stream for server-to-client events
#   - POST /sse - Sends JSON-RPC requests from client to server
client = MCPClient::Client.new(
  mcp_server_configs: [
    MCPClient.sse_config(
      base_url: 'http://localhost:8000/sse',
      name: 'sse-demo',
      read_timeout: 60,
      ping: 10 # Send ping every 10 seconds of inactivity
    )
  ],
  elicitation_handler: elicitation_handler
)

begin
  puts 'Calling create_document tool...'
  result = client.call_tool('create_document', { format: 'markdown' }, server: 'sse-demo')

  puts "\n✅ Success!"
  puts '─' * 60
  puts result['content'].first['text']
  puts '─' * 60
rescue MCPClient::Errors::ConnectionError => e
  puts "\n❌ Connection Error: #{e.message}"
  puts "\nMake sure the server is running:"
  puts '  python examples/elicitation/elicitation_streamable_server.py'
rescue StandardError => e
  puts "\n❌ Error: #{e.message}"
ensure
  client.cleanup
end

puts "\n✓ Done!"
