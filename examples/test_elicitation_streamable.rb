#!/usr/bin/env ruby
# frozen_string_literal: true

# Example demonstrating MCP Elicitation over Streamable HTTP Transport (MCP 2025-06-18)
# Server-initiated user interactions during tool execution over HTTP
#
# This example shows how to:
# 1. Connect to an MCP server via Streamable HTTP transport
# 2. Register an elicitation handler for server requests
# 3. Handle server-initiated elicitation requests over HTTP
# 4. Respond with accept/decline/cancel actions
#
# Transport Flow:
# - Server → Client: Requests sent via SSE-formatted HTTP responses
# - Client → Server: Responses sent via HTTP POST
#
# Usage:
#   # Option 1: Use with Python FastMCP server (recommended)
#   # Install: pip install mcp fastmcp
#   # Run a FastMCP server on http://localhost:8000
#
#   # Option 2: Use with the streamable HTTP example server
#   python examples/elicitation_streamable_server.py
#
#   # Then run this client:
#   ruby test_elicitation_streamable.rb

require 'bundler/setup'
require 'mcp_client'
require 'json'
require 'io/console'

# Enable INFO logging to see the elicitation flow
logger = Logger.new($stdout)
logger.level = Logger::INFO

puts '=' * 80
puts 'MCP Elicitation Example - Streamable HTTP Transport'
puts '=' * 80
puts
puts 'Transport: Streamable HTTP (HTTP POST + SSE-formatted responses)'
puts 'Features: Full bidirectional elicitation support'
puts '  - Server sends requests via SSE-formatted responses'
puts '  - Client sends responses via HTTP POST'
puts

# Define an elicitation handler that prompts the user for input
# rubocop:disable Metrics/BlockLength
elicitation_handler = lambda do |message, requested_schema|
  puts "\n#{'━' * 80}"
  puts '📡 SERVER REQUEST (via Streamable HTTP):'
  puts '━' * 80
  puts message
  puts

  # Show the schema if available
  if requested_schema && requested_schema['properties']
    puts 'Expected input format:'
    requested_schema['properties'].each do |field, schema|
      required = requested_schema['required']&.include?(field) ? ' (required)' : ''
      type_info = schema['type']
      type_info += " (#{schema['enum'].join('|')})" if schema['enum']
      puts "  - #{field}: #{type_info}#{required}"
      puts "    #{schema['description']}" if schema['description']
      puts "    Default: #{schema['default']}" if schema['default']
    end
    puts
  end

  # Prompt user for response
  puts 'Your response:'
  puts '  [a] Accept and provide input'
  puts '  [d] Decline to provide input'
  puts '  [c] Cancel operation'
  print 'Choice (a/d/c): '
  choice = $stdin.gets.chomp.downcase

  case choice
  when 'a', 'accept', ''
    # Accept: collect input from user based on schema
    content = {}
    if requested_schema && requested_schema['properties']
      requested_schema['properties'].each do |field, field_schema|
        # Show default if available
        default_str = field_schema['default'] ? " [#{field_schema['default']}]" : ''
        print "  Enter #{field}#{default_str}: "
        value = $stdin.gets.chomp

        # Use default if empty
        value = field_schema['default'].to_s if value.empty? && field_schema['default']

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

    puts '✓ Sending accept response to server via HTTP POST...'
    { 'action' => 'accept', 'content' => content }

  when 'd', 'decline'
    puts '✗ Sending decline response to server via HTTP POST...'
    { 'action' => 'decline' }

  when 'c', 'cancel'
    puts '⊗ Sending cancel response to server via HTTP POST...'
    { 'action' => 'cancel' }

  else
    puts "⚠ Invalid choice '#{choice}', declining by default"
    { 'action' => 'decline' }
  end
end
# rubocop:enable Metrics/BlockLength

# Server configuration
# Update these if your server runs on a different host/port
server_url = ENV.fetch('MCP_SERVER_URL', 'http://localhost:8000')
server_endpoint = ENV.fetch('MCP_SERVER_ENDPOINT', '/mcp')

puts 'Connecting to MCP server:'
puts "  URL: #{server_url}"
puts "  Endpoint: #{server_endpoint}"
puts '  Transport: Streamable HTTP'
puts

# Initialize MCP client with Streamable HTTP transport and elicitation handler
client = MCPClient::Client.new(
  mcp_server_configs: [
    {
      server_type: 'streamable_http',
      base_url: server_url,
      endpoint: server_endpoint,
      name: 'elicitation-demo',
      headers: {
        # Add any required authentication headers here
        # 'Authorization' => 'Bearer YOUR_TOKEN'
      },
      read_timeout: 60, # Longer timeout for user interaction
      retries: 3,
      retry_backoff: 1
    }
  ],
  logger: logger,
  elicitation_handler: elicitation_handler # Register the handler
)

begin
  # Connect to the server
  puts 'Connecting to server...'
  client.connect_to_all_servers
  puts '✓ Connected!'
  puts

  # List available tools
  puts 'Available tools:'
  tools = client.list_all_tools
  tools.each do |tool|
    puts "  • #{tool.name}"
    puts "    #{tool.description}"
  end
  puts
  puts "Total: #{tools.length} tools"
  puts

  # Example 1: Create a document with elicitation
  puts '=' * 80
  puts 'Example 1: Creating a document (multi-step elicitation)'
  puts '=' * 80
  puts
  puts 'This tool will ask for:'
  puts '  1. Document title and author'
  puts '  2. Document content'
  puts

  begin
    result1 = client.call_tool('elicitation-demo', 'create_document', { format: 'markdown' })
    puts "\n📄 Result:"
    puts result1['content'].first['text']
  rescue StandardError => e
    puts "\n❌ Error: #{e.message}"
  end
  puts

  # Example 2: Delete files with confirmation
  puts '=' * 80
  puts 'Example 2: Delete files (requires confirmation)'
  puts '=' * 80
  puts
  puts 'This tool will ask for:'
  puts '  - Confirmation to delete files'
  puts '  - Optional reason if declining'
  puts

  begin
    result2 = client.call_tool('elicitation-demo', 'delete_files', { file_pattern: '*.tmp' })
    puts "\n🗑️  Result:"
    puts result2['content'].first['text']
  rescue StandardError => e
    puts "\n❌ Error: #{e.message}"
  end
  puts

  # Example 3: Deploy application (multi-step with production check)
  puts '=' * 80
  puts 'Example 3: Deploy application (multi-step confirmation)'
  puts '=' * 80
  puts
  puts 'This tool will ask for:'
  puts '  1. Initial deployment confirmation'
  puts '  2. Additional confirmation if deploying to production'
  puts

  print 'Enter environment (development/staging/production) [development]: '
  environment = $stdin.gets.chomp
  environment = 'development' if environment.empty?

  print 'Enter version [v1.0.0]: '
  version = $stdin.gets.chomp
  version = 'v1.0.0' if version.empty?

  begin
    result3 = client.call_tool(
      'elicitation-demo',
      'deploy_application',
      { environment: environment, version: version }
    )
    puts "\n🚀 Result:"
    puts result3['content'].first['text']
  rescue StandardError => e
    puts "\n❌ Error: #{e.message}"
  end
  puts
rescue MCPClient::Errors::ConnectionError => e
  puts "\n❌ Connection Error: #{e.message}"
  puts
  puts 'Make sure the MCP server is running:'
  puts '  python examples/elicitation_streamable_server.py'
  puts
  puts 'Or update the server URL:'
  puts "  export MCP_SERVER_URL='http://your-server:8000'"
  puts "  export MCP_SERVER_ENDPOINT='/mcp'"
rescue StandardError => e
  puts "\n❌ Error: #{e.message}"
  puts e.backtrace.first(5).join("\n") if logger.level <= Logger::DEBUG
ensure
  # Clean up
  puts "\nDisconnecting..."
  client.cleanup
  puts 'Done!'
  puts
  puts '═' * 80
  puts 'Transport Summary:'
  puts '  ✓ Server-to-client requests: Via SSE-formatted HTTP responses'
  puts '  ✓ Client-to-server responses: Via HTTP POST'
  puts '  ✓ Session management: Automatic via Mcp-Session-Id header'
  puts '  ✓ Full bidirectional communication: Supported'
  puts '═' * 80
end
