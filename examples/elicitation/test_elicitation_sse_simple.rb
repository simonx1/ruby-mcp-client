#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple MCP Elicitation Example - SSE Transport
#
# Note: SSE and Streamable HTTP transports are similar in this implementation.
# This example shows a minimal SSE configuration using the streamable HTTP server.
#
# Usage:
#   # Start the server:
#   python examples/elicitation_streamable_server.py
#
#   # Run this client:
#   ruby examples/test_elicitation_sse_simple.rb

require 'bundler/setup'
require 'mcp_client'

puts '=' * 60
puts 'Simple MCP Elicitation Example - SSE Transport'
puts '=' * 60
puts

# Simple elicitation handler
elicitation_handler = lambda do |message, schema|
  puts "\n📡 Server request: #{message}"

  # Auto-accept with sample data
  case message
  when /document details/
    puts "✓ Providing: title='Quick Doc', author='Demo User'"
    { 'action' => 'accept', 'content' => { 'title' => 'Quick Doc', 'author' => 'Demo User' } }
  when /content/
    puts "✓ Providing content"
    { 'action' => 'accept', 'content' => { 'content' => 'This is demo content from SSE transport.' } }
  else
    puts "✓ Accepting request"
    { 'action' => 'accept' }
  end
end

# Create client with SSE transport
# Note: For simplicity, using streamable_http type which works the same way
client = MCPClient::Client.new(
  mcp_server_configs: [
    {
      type: 'streamable_http',
      base_url: 'http://localhost:8000',
      endpoint: '/mcp',
      name: 'sse-demo',
      read_timeout: 60
    }
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
  puts "  python examples/elicitation_streamable_server.py"
rescue StandardError => e
  puts "\n❌ Error: #{e.message}"
ensure
  client.cleanup
end

puts "\n✓ Done!"
