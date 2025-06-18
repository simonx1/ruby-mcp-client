#!/usr/bin/env ruby
# frozen_string_literal: true

# Example demonstrating MCPClient with multiple MCP servers:
# - Playwright MCP server via Server-Sent Events (SSE)
# - Filesystem MCP server via STDIO
#
# Usage:
#  1. Start Playwright MCP server: npx @playwright/mcp@latest --port 8931
#  2. Run this example: ruby json_input_mcp_servers_example.rb
#
require_relative '../lib/mcp_client'
require 'bundler/setup'
require 'json'
require 'logger'

# Create a logger for debugging (optional)
logger = Logger.new($stdout)
logger.level = Logger::WARN # INFO

# Create an MCP client that connects to multiple servers defined in a JSON file
# Server names from the JSON file are preserved and can be used for disambiguation
sse_client = MCPClient.create_client(server_definition_file: File.join(File.dirname(__FILE__),
                                                                       'sample_server_definition.json'))

puts 'Connected to MCP servers defined in sample_server_definition.json'

# Display connected servers by name
servers = sse_client.servers
puts "\nConnected to #{servers.length} servers:"
servers.each do |server|
  puts "- #{server.name || 'unnamed'} (#{server.class.name.split('::').last})"
end

# Find a specific server by name
playwright_server = sse_client.find_server('playwright')
filesystem_server = sse_client.find_server('filesystem')

puts "\nFound servers by name:"
puts "- Playwright: #{!playwright_server.nil?}"
puts "- Filesystem: #{!filesystem_server.nil?}"

# List all available tools across all servers
tools = sse_client.list_tools
puts "\nFound #{tools.length} total tools across all servers:"
tools.each do |tool|
  server_name = tool.server&.name || 'unnamed'
  puts "- #{tool.name} (from server: #{server_name}): #{tool.description&.split("\n")&.first}"
end

# Find tools by name pattern (supports string or regex)
browser_tools = sse_client.find_tools(/browser/)
puts "\nFound #{browser_tools.length} browser-related tools"

# Find tools from a specific server by filtering the tool list
all_tools = sse_client.list_tools
playwright_tools = all_tools.select { |tool| tool.server&.name == 'playwright' }
filesystem_tools = all_tools.select { |tool| tool.server&.name == 'filesystem' }
puts "Tools from Playwright server: #{playwright_tools.length}"
puts "Tools from Filesystem server: #{filesystem_tools.length}"

# Launch a browser - explicitly specify server by name for disambiguation
puts "\nLaunching browser..."
sse_client.call_tool('browser_install', {}, server: 'playwright')
puts 'Browser installed'

# You can call tools on a specific server directly
playwright_server.call_tool('browser_navigate', { url: 'about:blank' })
puts 'Browser launched and navigated to blank page'

# Create a new page
puts "\nCreating a new page..."
# You can continue using server name for disambiguation
sse_client.call_tool('browser_tab_new', {}, server: 'playwright')
puts 'New tab created'

# Navigate to a website
puts "\nNavigating to a website..."
# When tool names are unique across servers, server name is optional
# but it's good practice to include it for clarity
sse_client.call_tool('browser_navigate', { url: 'https://example.com' }, server: 'playwright')
puts 'Navigated to example.com'

# Get page title
puts "\nGetting page title..."
# Demonstrate using the direct server reference
title_result = playwright_server.call_tool('browser_snapshot', {})
puts "Page title: #{title_result}"

# Take a screenshot
puts "\nTaking a screenshot..."
# You can use either the client or direct server reference
sse_client.call_tool('browser_take_screenshot', {}, server: 'playwright')
puts 'Screenshot captured successfully'

# Close browser
puts "\nClosing browser..."
# Using server parameter for disambiguation
sse_client.call_tool('browser_close', {}, server: 'playwright')
puts 'Browser closed'

# Ping the servers to check connectivity
puts "\nPinging servers:"

# Ping specific servers directly using their references
begin
  ping_result = playwright_server.ping
  puts "Playwright server ping successful: #{ping_result.inspect}"
rescue StandardError => e
  puts "Playwright ping failed: #{e.message}"
end

begin
  ping_result = filesystem_server.ping
  puts "Filesystem server ping successful: #{ping_result.inspect}"
rescue StandardError => e
  puts "Filesystem ping failed: #{e.message}"
end

# Demonstrate error handling for ambiguous tool names (clean implementation)
puts "\nHandling ambiguous tool names:"
puts 'If a tool name exists on multiple servers, you must specify the server:'
puts "sse_client.call_tool('tool_name', params, server: 'server_name')"
puts 'This prevents ambiguity and ensures the correct tool is called'

# Clean up connections
sse_client.cleanup
puts "\nConnections cleaned up"
