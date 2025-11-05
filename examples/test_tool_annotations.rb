#!/usr/bin/env ruby
# frozen_string_literal: true

# Example script demonstrating MCP tool annotations support
#
# This script shows how to:
# 1. Connect to an MCP server with stdio transport
# 2. List tools and display their annotations
# 3. Use annotation helper methods (read_only?, destructive?, requires_confirmation?)
# 4. Make informed decisions about tool execution based on annotations
#
# Prerequisites:
# 1. Install mcp: pip install mcp
# 2. Start the annotated echo server in a separate terminal:
#    python examples/echo_server_with_annotations.py
# 3. Run this client: bundle exec ruby examples/test_tool_annotations.rb

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'
require 'json'

# Create a logger for debugging
logger = Logger.new($stdout)
logger.level = Logger::INFO

puts '🚀 Ruby MCP Client - Tool Annotations Demo'
puts '=' * 60

# Server configuration for stdio transport
server_config = {
  type: 'stdio',
  command: 'python',
  args: ['examples/echo_server_with_annotations.py'],
  logger: logger
}

puts '📡 Connecting to MCP Echo Server with Tool Annotations'

begin
  # Create MCP client
  client = MCPClient.create_client(
    mcp_server_configs: [server_config]
  )

  puts '✅ Connected successfully!'

  # List available tools
  puts "\n📋 Fetching available tools with annotations..."
  tools = client.list_tools

  puts "Found #{tools.length} tools:\n\n"

  # Display each tool with its annotations
  tools.each_with_index do |tool, index|
    puts "#{index + 1}. #{tool.name}"
    puts "   Description: #{tool.description}"

    # Display raw annotations if present
    if tool.annotations && !tool.annotations.empty?
      puts "   Annotations: #{tool.annotations.inspect}"

      # Use helper methods to check specific annotations
      annotations_display = []
      annotations_display << '🔒 READ-ONLY' if tool.read_only?
      annotations_display << '⚠️  DESTRUCTIVE' if tool.destructive?
      annotations_display << '🛡️  REQUIRES CONFIRMATION' if tool.requires_confirmation?

      puts "   Flags: #{annotations_display.join(', ')}" unless annotations_display.empty?
    else
      puts '   Annotations: none'
    end

    # Display parameters
    if tool.schema && tool.schema['properties']
      params = tool.schema['properties'].keys.join(', ')
      puts "   Parameters: #{params}"
    end

    puts
  end

  # === DEMONSTRATE TOOL USAGE WITH ANNOTATION AWARENESS ===
  puts "\n🛠️  Demonstrating annotation-aware tool usage:"
  puts '-' * 60

  # 1. Test read_data (read-only)
  puts "\n1. Testing read_data (read-only tool):"
  read_tool = tools.find { |t| t.name == 'read_data' }
  if read_tool
    puts "   ✓ Tool is read-only: #{read_tool.read_only?}"
    puts '   → Safe to execute without confirmation'
    result = client.call_tool('read_data', { key: 'user_1' })
    output = result['content']&.first&.dig('text')
    puts "   Result: #{output}"
  end

  # 2. Test analyze_text (read-only)
  puts "\n2. Testing analyze_text (read-only tool):"
  analyze_tool = tools.find { |t| t.name == 'analyze_text' }
  if analyze_tool
    puts "   ✓ Tool is read-only: #{analyze_tool.read_only?}"
    puts '   → Safe to execute without confirmation'
    text = 'The Model Context Protocol enables seamless integration between LLM applications and external data sources.'
    result = client.call_tool('analyze_text', { text: text })
    output = result['content']&.first&.dig('text')
    puts "   Result: #{output}"
  end

  # 3. Test update_data (modifies data)
  puts "\n3. Testing update_data (modifies data):"
  update_tool = tools.find { |t| t.name == 'update_data' }
  if update_tool
    puts "   ✓ Tool is destructive: #{update_tool.destructive?}"
    puts "   ✓ Requires confirmation: #{update_tool.requires_confirmation?}"
    if update_tool.requires_confirmation?
      puts '   → Should ask user for confirmation before executing'
    else
      puts '   → Can execute without explicit confirmation'
    end
    result = client.call_tool('update_data', { key: 'user_1', value: { name: 'Alice Updated', role: 'super_admin' } })
    output = result['content']&.first&.dig('text')
    puts "   Result: #{output}"
  end

  # 4. Test delete_data (destructive)
  puts "\n4. Testing delete_data (destructive tool):"
  delete_tool = tools.find { |t| t.name == 'delete_data' }
  if delete_tool
    puts "   ⚠️  Tool is destructive: #{delete_tool.destructive?}"
    puts "   🛡️  Requires confirmation: #{delete_tool.requires_confirmation?}"

    if delete_tool.destructive? && delete_tool.requires_confirmation?
      puts '   → DANGER: This tool should require explicit user confirmation'
      puts '   → In a real application, you would prompt the user here'
      puts '   → For demonstration purposes, we will skip execution'
      puts '   ⏭️  Skipping execution of destructive tool'
    else
      result = client.call_tool('delete_data', { key: 'user_2' })
      output = result['content']&.first&.dig('text')
      puts "   Result: #{output}"
    end
  end

  # === SUMMARY ===
  puts "\n📊 Tool Annotations Summary:"
  puts '-' * 60

  read_only_tools = tools.select(&:read_only?)
  destructive_tools = tools.select(&:destructive?)
  confirmation_tools = tools.select(&:requires_confirmation?)

  puts "Total tools: #{tools.length}"
  puts "Read-only tools: #{read_only_tools.length} (#{read_only_tools.map(&:name).join(', ')})"
  puts "Destructive tools: #{destructive_tools.length} (#{destructive_tools.map(&:name).join(', ')})"
  puts "Requires confirmation: #{confirmation_tools.length} (#{confirmation_tools.map(&:name).join(', ')})"

  puts "\n✨ Tool annotations demo completed successfully!"

  # === VERIFY READ-BACK ===
  puts "\n🔍 Verifying data after operations:"
  result = client.call_tool('read_data', { key: 'user_1' })
  output = result['content']&.first&.dig('text')
  puts "   user_1 data: #{output}"
rescue MCPClient::Errors::ConnectionError => e
  puts "❌ Connection Error: #{e.message}"
  puts "\n💡 Make sure the annotated echo server is running:"
  puts '   python examples/echo_server_with_annotations.py'
rescue MCPClient::Errors::ToolCallError => e
  puts "❌ Tool Call Error: #{e.message}"
rescue StandardError => e
  puts "❌ Unexpected Error: #{e.class}: #{e.message}"
  puts e.backtrace.join("\n") if ENV['DEBUG']
ensure
  puts "\n🧹 Cleaning up..."
  client&.cleanup
  puts '👋 Done!'
end
