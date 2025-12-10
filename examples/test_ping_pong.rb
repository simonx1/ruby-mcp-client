#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple test to verify ping/pong keepalive mechanism
#
# This script connects to the enhanced echo server and monitors ping/pong activity
# Run with DEBUG=1 to see detailed ping/pong messages

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

# Create logger
logger = Logger.new($stdout)
logger.level = ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO
logger.formatter = proc do |severity, datetime, _progname, msg|
  # Highlight ping/pong messages
  if msg.include?('ping') || msg.include?('pong')
    "\e[32m#{datetime.strftime('%H:%M:%S.%L')} [#{severity}] #{msg}\e[0m\n"
  else
    "#{datetime.strftime('%H:%M:%S.%L')} [#{severity}] #{msg}\n"
  end
end

puts '🏓 Ping/Pong Keepalive Test'
puts '=' * 40
puts 'This test verifies the ping/pong keepalive mechanism'
puts 'Run with DEBUG=1 to see detailed messages'
puts

begin
  puts 'Connecting to server...'
  # Create MCP client using the simplified connect API
  # The /mcp suffix auto-detects Streamable HTTP transport
  client = MCPClient.connect('http://localhost:8931/mcp',
                             logger: logger)

  puts "✅ Connected! Session established.\n\n"

  # Verify connection is working
  tools = client.list_tools
  puts "Server has #{tools.length} tools available\n\n"

  puts 'Monitoring ping/pong activity for 35 seconds...'
  puts 'The server should send a ping every 10 seconds'
  puts "The client should automatically respond with pong\n\n"

  start_time = Time.now

  # Monitor for 35 seconds (should see at least 3 pings)
  35.times do |i|
    elapsed = (Time.now - start_time).round
    remaining = 35 - i

    # Show progress
    print "\r⏱️  Elapsed: #{elapsed}s | Remaining: #{remaining}s | Expected pings: ~#{elapsed / 10}"

    # Make a simple call every 12 seconds to show session is still active
    if [12, 24].include?(i)
      puts "\n\n📤 Making a tool call to verify session is active..."
      result = client.call_tool('echo', { message: "Keep-alive test at #{elapsed}s" })
      puts "📥 Response: #{result['content']&.first&.dig('text')}\n\n"
    end

    sleep 1
  end

  puts "\n\n#{'=' * 40}"
  puts '✅ Test completed!'
  puts "\nExpected behavior:"
  puts '  - Server sends ping every 10 seconds'
  puts '  - Client responds with pong automatically'
  puts '  - Session remains active throughout'
  puts "\nCheck the debug logs above to verify ping/pong messages"
  puts '(Run with DEBUG=1 to see detailed logs)'
rescue StandardError => e
  puts "\n❌ Error: #{e.message}"
  puts "\nMake sure the enhanced echo server is running:"
  puts '  python examples/echo_server_streamable.py'
ensure
  puts "\nCleaning up..."
  client&.cleanup
  puts 'Done!'
end
