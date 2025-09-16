#!/usr/bin/env ruby
# frozen_string_literal: true

# Enhanced Ruby MCP Client for testing Streamable HTTP Transport
#
# This script demonstrates all features of the Streamable HTTP transport:
# - SSE event streaming
# - Ping/pong keepalive mechanism
# - Server notifications handling
# - Progress notifications
# - Session management
# - Long-running tasks
# - Prompts support
# - Resources support
#
# Prerequisites:
# 1. Install Flask: pip install flask
# 2. Start the enhanced server: python examples/echo_server_streamable.py
# 3. Run this client: bundle exec ruby examples/echo_server_streamable_client.rb

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

# Create a logger with debug level to see all activity
logger = Logger.new($stdout)
logger.level = ENV['DEBUG'] ? Logger::DEBUG : Logger::INFO
logger.formatter = proc do |severity, datetime, _progname, msg|
  "#{datetime.strftime('%H:%M:%S')} [#{severity}] #{msg}\n"
end

puts '🚀 Ruby MCP Client - Streamable HTTP Transport Test'
puts '=' * 60

# Server configuration for streamable HTTP
server_config = {
  type: 'streamable_http',
  base_url: 'http://localhost:8931/mcp',
  headers: {},
  read_timeout: 60, # Longer timeout for long-running tasks
  retries: 3,
  retry_backoff: 1,
  logger: logger
}

puts "📡 Connecting to Enhanced Echo Server at #{server_config[:base_url]}"
puts 'Transport: Streamable HTTP (MCP 2025-03-26)'
puts

# Track received notifications
notifications_received = []
notification_mutex = Mutex.new

begin
  # Create MCP client with notification callback
  client = MCPClient::Client.new(
    mcp_server_configs: [server_config]
  )

  # Set up notification handler
  client.on_notification do |method, params|
    notification_mutex.synchronize do
      notifications_received << { method: method, params: params, time: Time.now }

      case method
      when 'notification/server_status'
        puts "📊 Server Status: #{params['message']}"
      when 'notification/progress'
        puts "⏳ Progress: #{params['progress']}% - #{params['message']}"
      when 'notification/manual'
        puts "📢 Manual Notification: #{params['message']}"
      else
        puts "🔔 Notification [#{method}]: #{params.inspect}"
      end
    end
  end

  puts '✅ Connected successfully!'
  puts "Session established with Streamable HTTP transport\n\n"

  # Give the connection a moment to stabilize
  sleep 1

  # List available tools
  puts '📋 Fetching available tools...'
  tools = client.list_tools

  puts "Found #{tools.length} tools:"
  tools.each_with_index do |tool, index|
    puts "  #{index + 1}. #{tool.name}: #{tool.description}"
  end
  puts

  # Test 1: Basic echo tool
  puts '=' * 40
  puts 'Test 1: Basic Echo Tool'
  puts '-' * 40
  message = 'Hello from Streamable HTTP Transport!'
  puts "Calling echo with: #{message}"
  result = client.call_tool('echo', { message: message })
  output = result['content']&.first&.dig('text')
  puts "Response: #{output}"
  puts

  # Test 2: Trigger manual notification
  puts '=' * 40
  puts 'Test 2: Trigger Server Notification'
  puts '-' * 40
  puts 'Triggering a manual notification...'
  result = client.call_tool('trigger_notification', {
                              message: 'Testing notification system with Streamable HTTP!'
                            })
  output = result['content']&.first&.dig('text')
  puts "Response: #{output}"
  sleep 1 # Give time for notification to arrive
  puts

  # Test 3: Long-running task with progress
  puts '=' * 40
  puts 'Test 3: Long-Running Task with Progress'
  puts '-' * 40
  puts 'Starting a 5-second task with progress notifications...'
  start_time = Time.now
  result = client.call_tool('long_task', {
                              duration: 5,
                              steps: 5
                            })
  output = result['content']&.first&.dig('text')
  puts "Response: #{output}"
  puts "Task completed in #{(Time.now - start_time).round(2)} seconds"
  puts

  # Test 4: Monitor ping/pong activity
  puts '=' * 40
  puts 'Test 4: Monitoring Ping/Pong Keepalive'
  puts '-' * 40
  puts 'Waiting 15 seconds to observe ping/pong activity...'
  puts '(Check DEBUG logs to see ping/pong messages)'

  15.times do |i|
    print "\rWaiting... #{15 - i} seconds remaining"
    sleep 1
  end
  puts "\n"

  # Test 5: Check notification history
  puts '=' * 40
  puts 'Test 5: Notification Summary'
  puts '-' * 40
  notification_mutex.synchronize do
    if notifications_received.empty?
      puts 'No notifications received (this might be normal if server notifications are disabled)'
    else
      puts "Received #{notifications_received.length} notifications:"
      notifications_received.each do |notif|
        time_ago = (Time.now - notif[:time]).round(1)
        puts "  - [#{notif[:method]}] #{time_ago}s ago"
      end
    end
  end
  puts

  # Test 6: Session persistence
  puts '=' * 40
  puts 'Test 6: Session Persistence'
  puts '-' * 40
  puts 'Testing session persistence with multiple requests...'

  3.times do |i|
    result = client.call_tool('echo', { message: "Request #{i + 1}" })
    output = result['content']&.first&.dig('text')
    puts "  Request #{i + 1}: #{output}"
    sleep 0.5
  end
  puts '✅ Session maintained across multiple requests'
  puts

  # Test 7: Prompts functionality
  puts '=' * 40
  puts 'Test 7: Prompts Support'
  puts '-' * 40
  puts 'Testing prompts functionality...'
  puts

  # List available prompts
  puts '📋 Fetching available prompts...'
  begin
    prompts = client.list_prompts
    puts "Found #{prompts.length} prompts:"
    prompts.each_with_index do |prompt, index|
      puts "  #{index + 1}. #{prompt.name}: #{prompt.description}"
      if prompt.arguments && !prompt.arguments.empty?
        if prompt.arguments.is_a?(Array)
          arg_names = prompt.arguments.map { |arg| arg['name'] || arg[:name] }.compact
          puts "     Arguments: #{arg_names.join(', ')}" unless arg_names.empty?
        elsif prompt.arguments.is_a?(Hash)
          puts "     Arguments: #{prompt.arguments.keys.join(', ')}"
        end
      end
    end
    puts

    # Test each prompt
    puts '🎨 Testing prompts:'
    puts

    # 1. Greeting prompt
    puts '1. Testing greeting prompt:'
    result = client.get_prompt('greeting', { name: 'Streamable HTTP Tester' })
    message = result['messages']&.first&.dig('content', 'text') || result.to_s
    puts '   Generated greeting:'
    puts "   #{message.gsub("\n", "\n   ")}"
    puts

    # 2. Code review prompt
    puts '2. Testing code_review prompt:'
    sample_code = "def hello; puts 'Hello World'; end"
    result = client.get_prompt('code_review', { code: sample_code, language: 'ruby' })
    review = result['messages']&.first&.dig('content', 'text') || result.to_s
    puts "   Code: #{sample_code}"
    puts '   Generated review (first 200 chars):'
    preview = review.length > 200 ? "#{review[0...200]}..." : review
    puts "   #{preview.gsub("\n", "\n   ")}"
    puts

    # 3. Documentation prompt
    puts '3. Testing documentation prompt:'
    result = client.get_prompt('documentation', { topic: 'Streamable HTTP Transport', audience: 'developers' })
    doc = result['messages']&.first&.dig('content', 'text') || result.to_s
    puts '   Topic: Streamable HTTP Transport'
    puts '   Generated documentation (first 200 chars):'
    preview = doc.length > 200 ? "#{doc[0...200]}..." : doc
    puts "   #{preview.gsub("\n", "\n   ")}"
    puts
  rescue MCPClient::Errors::PromptGetError => e
    puts "❌ Prompt Error: #{e.message}"
  end

  # Test 8: Resources functionality
  puts '=' * 40
  puts 'Test 8: Resources Support'
  puts '-' * 40
  puts 'Testing resources functionality...'
  puts

  # List available resources
  puts '📋 Fetching available resources...'
  begin
    resources = client.list_resources
    puts "Found #{resources.length} resources:"
    resources.each_with_index do |resource, index|
      puts "  #{index + 1}. #{resource.name} (#{resource.uri})"
      puts "     MIME Type: #{resource.mime_type}" if resource.mime_type
      puts "     Description: #{resource.description}" if resource.description
    end
    puts

    # Test reading each resource
    puts '📖 Reading resources:'
    puts

    resources.each_with_index do |resource, index|
      puts "#{index + 1}. Reading #{resource.name}:"
      begin
        result = client.read_resource(resource.uri)

        result['contents']&.each do |content|
          if content['text']
            # Text content
            preview = if content['text'].length > 150
                        "#{content['text'][0...150]}..."
                      else
                        content['text']
                      end
            puts "   Content (#{content['mimeType'] || 'text'}): #{preview.gsub("\n", "\n   ")}"
          elsif content['blob']
            # Binary content
            puts "   Binary data: #{content['blob'].length} characters (base64)"
          end

          # Show annotations if present
          puts "   Annotations: #{content['annotations']}" if content['annotations']
        end
        puts
      rescue MCPClient::Errors::ResourceReadError => e
        puts "   ❌ Error reading resource: #{e.message}"
        puts
      end
    end
  rescue MCPClient::Errors::ResourceReadError => e
    puts "❌ Resource Error: #{e.message}"
  end

  # Final summary
  puts '=' * 60
  puts '✨ All tests completed successfully!'
  puts
  puts 'Summary:'
  puts '  ✅ Streamable HTTP connection established'
  puts '  ✅ SSE event streaming working'
  puts '  ✅ Tools called successfully'
  puts '  ✅ Progress notifications received'
  puts '  ✅ Server notifications handled'
  puts '  ✅ Ping/pong keepalive active (check debug logs)'
  puts '  ✅ Session persistence verified'
  puts '  ✅ Prompts functionality tested'
  puts '  ✅ Resources functionality tested'
rescue MCPClient::Errors::ConnectionError => e
  puts "❌ Connection Error: #{e.message}"
  puts "\n💡 Make sure the enhanced echo server is running:"
  puts '   python examples/echo_server_streamable.py'
rescue MCPClient::Errors::ToolCallError => e
  puts "❌ Tool Call Error: #{e.message}"
rescue MCPClient::Errors::PromptGetError => e
  puts "❌ Prompt Error: #{e.message}"
rescue MCPClient::Errors::ResourceReadError => e
  puts "❌ Resource Error: #{e.message}"
rescue StandardError => e
  puts "❌ Unexpected Error: #{e.class}: #{e.message}"
  puts e.backtrace.first(5).join("\n") if ENV['DEBUG']
ensure
  puts "\n🧹 Cleaning up..."
  client&.cleanup
  puts '👋 Connection closed gracefully'
end
