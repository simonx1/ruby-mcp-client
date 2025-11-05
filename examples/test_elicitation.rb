#!/usr/bin/env ruby
# frozen_string_literal: true

# Example demonstrating MCP Elicitation (MCP 2025-06-18)
# Server-initiated user interactions during tool execution
#
# This example shows how to:
# 1. Register an elicitation handler to respond to server requests
# 2. Handle different elicitation messages and schemas
# 3. Respond with accept/decline/cancel actions
#
# Usage:
#   ruby test_elicitation.rb

require 'bundler/setup'
require 'mcp_client'
require 'json'
require 'io/console'

# Enable debug logging to see elicitation requests in action
logger = Logger.new($stdout)
logger.level = Logger::INFO

puts '=' * 80
puts 'MCP Elicitation Example (MCP 2025-06-18)'
puts '=' * 80
puts

# Define an elicitation handler that prompts the user for input
# rubocop:disable Metrics/BlockLength
elicitation_handler = lambda do |message, requested_schema|
  puts "\n#{'─' * 80}"
  puts '📋 SERVER REQUESTS INPUT:'
  puts '─' * 80
  puts message
  puts

  # Show the schema if available
  if requested_schema && requested_schema['properties']
    puts 'Expected input format:'
    requested_schema['properties'].each do |field, schema|
      required = requested_schema['required']&.include?(field) ? ' (required)' : ''
      puts "  - #{field}: #{schema['type']}#{required}"
      puts "    #{schema['description']}" if schema['description']
    end
    puts
  end

  # Prompt user for response
  puts 'Your response:'
  puts '  [a] Accept and provide input'
  puts '  [d] Decline to provide input'
  puts '  [c] Cancel operation'
  print 'Choice: '
  choice = $stdin.gets.chomp.downcase

  case choice
  when 'a', 'accept'
    # Accept: collect input from user based on schema
    content = {}
    if requested_schema && requested_schema['properties']
      requested_schema['properties'].each do |field, field_schema|
        print "Enter #{field}: "
        value = $stdin.gets.chomp

        # Type conversion based on schema
        content[field] = case field_schema['type']
                         when 'boolean'
                           %w[true yes y 1].include?(value.downcase)
                         when 'number', 'integer'
                           value.to_i
                         else
                           value
                         end
      end
    end

    puts '✓ Sending response to server...'
    { 'action' => 'accept', 'content' => content }

  when 'd', 'decline'
    puts '✗ Declining request...'
    { 'action' => 'decline' }

  when 'c', 'cancel'
    puts '⊗ Cancelling operation...'
    { 'action' => 'cancel' }

  else
    puts '⚠ Invalid choice, declining by default'
    { 'action' => 'decline' }
  end
end
# rubocop:enable Metrics/BlockLength

# Initialize MCP client with elicitation handler
client = MCPClient::Client.new(
  mcp_server_configs: [
    {
      server_type: 'stdio',
      command: ['python', File.join(__dir__, 'elicitation_server.py')],
      name: 'elicitation-demo'
    }
  ],
  logger: logger,
  elicitation_handler: elicitation_handler # Register the handler
)

begin
  # Connect to the server
  puts 'Connecting to MCP server with elicitation support...'
  client.connect_to_all_servers
  puts '✓ Connected!'
  puts

  # List available tools
  puts 'Available tools:'
  tools = client.list_all_tools
  tools.each do |tool|
    puts "  • #{tool.name}: #{tool.description}"
  end
  puts

  # Example 1: Create a document with elicitation
  puts '=' * 80
  puts 'Example 1: Creating a document (uses elicitation for title and content)'
  puts '=' * 80
  puts

  result1 = client.call_tool('elicitation-demo', 'create_document', { format: 'markdown' })
  puts "\nResult:"
  puts result1['content'].first['text']
  puts

  # Example 2: Sensitive operation with confirmation
  puts '=' * 80
  puts 'Example 2: Sensitive operation (requires confirmation via elicitation)'
  puts '=' * 80
  puts

  result2 = client.call_tool('elicitation-demo', 'sensitive_operation',
                             { operation: 'delete all temporary files' })
  puts "\nResult:"
  puts result2['content'].first['text']
  puts
rescue StandardError => e
  puts "Error: #{e.message}"
  puts e.backtrace.first(5).join("\n")
ensure
  # Clean up
  puts "\nDisconnecting..."
  client.cleanup
  puts 'Done!'
end
