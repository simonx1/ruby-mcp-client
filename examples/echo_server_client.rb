#!/usr/bin/env ruby
# frozen_string_literal: true

# Enhanced example script demonstrating Ruby MCP client with FastMCP echo server
#
# This script shows how to:
# 1. Connect to a FastMCP server via SSE
# 2. List and use available tools
# 3. List and use available prompts
# 4. List and read available resources
# 5. Handle responses and errors
#
# Prerequisites:
# 1. Install FastMCP: pip install fastmcp
# 2. Start the echo server: python examples/echo_server.py
# 3. Run this client: bundle exec ruby examples/echo_server_client.rb

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'
require 'json'

# Helper method to display content from resources
def display_content(content)
  if content.text?
    preview = content.text.length > 200 ? "#{content.text[0...200]}..." : content.text
    puts "   Content (#{content.mime_type || 'text'}): #{preview.gsub("\n", "\n            ")}"
  elsif content.binary?
    puts "   Binary data: #{content.blob.length} characters (base64)"
  end

  # Show annotations if present
  puts "   Annotations: #{content.annotations}" if content.annotations
end

# Create a logger for debugging (optional)
logger = Logger.new($stdout)
logger.level = Logger::INFO

puts '🚀 Enhanced Ruby MCP Client - Tools, Prompts & Resources'
puts '=' * 60

# Server configuration
server_config = {
  type: 'sse',
  base_url: 'http://127.0.0.1:8000/sse',
  headers: {},
  read_timeout: 30,
  ping: 10,
  retries: 3,
  retry_backoff: 1,
  logger: logger
}

puts "📡 Connecting to FastMCP Echo Server at #{server_config[:base_url]}"

begin
  # Create MCP client
  client = MCPClient.create_client(
    mcp_server_configs: [server_config]
  )

  puts '✅ Connected successfully!'

  # List available tools
  puts "\n📋 Fetching available tools..."
  tools = client.list_tools

  puts "Found #{tools.length} tools:"
  tools.each_with_index do |tool, index|
    puts "  #{index + 1}. #{tool.name}: #{tool.description}"
    puts "     Parameters: #{tool.schema['properties'].keys.join(', ')}" if tool.schema && tool.schema['properties']
  end

  # Demonstrate each tool
  puts "\n🛠️  Demonstrating tool usage:"
  puts '-' * 30

  # 1. Echo tool
  puts "\n1. Testing echo tool:"
  message = 'Hello from Ruby MCP Client!'
  puts "   Input: #{message}"
  result = client.call_tool('echo', { message: message })
  output = result['content']&.first&.dig('text') || result['structuredContent']&.dig('result')
  puts "   Output: #{output}"

  # 2. Reverse tool
  puts "\n2. Testing reverse tool:"
  text = 'FastMCP with Ruby'
  puts "   Input: #{text}"
  result = client.call_tool('reverse', { text: text })
  output = result['content']&.first&.dig('text') || result['structuredContent']&.dig('result')
  puts "   Output: #{output}"

  # 3. Uppercase tool
  puts "\n3. Testing uppercase tool:"
  text = 'mcp protocol rocks!'
  puts "   Input: #{text}"
  result = client.call_tool('uppercase', { text: text })
  output = result['content']&.first&.dig('text') || result['structuredContent']&.dig('result')
  puts "   Output: #{output}"

  # 4. Count words tool
  puts "\n4. Testing count_words tool:"
  text = 'The Model Context Protocol enables seamless AI integration'
  puts "   Input: #{text}"
  result = client.call_tool('count_words', { text: text })
  output = result['structuredContent'] || result['content']&.first&.dig('text')
  puts "   Output: #{output}"

  # === PROMPTS SECTION ===
  puts "\n🎨 Working with Prompts"
  puts '=' * 25

  # List available prompts
  puts "\n📋 Fetching available prompts..."
  begin
    prompts = client.list_prompts

    if prompts.empty?
      puts '   ℹ️  No prompts available from this server'
    else
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

      # Demonstrate each prompt
      puts "\n🔨 Demonstrating prompt usage:"
      puts '-' * 32

      # 1. Greeting prompt
      puts "\n1. Testing greeting prompt:"
      name = 'FastMCP User'
      puts "   Name: #{name}"
      result = client.get_prompt('greeting', { name: name })
      message = result['messages']&.first&.dig('content', 'text') ||
                result['content']&.first&.dig('text') ||
                result.to_s
      puts '   Generated greeting:'
      puts message.split("\n").map { |line| "   #{line}" }.join("\n")

      # 2. Code review prompt
      puts "\n2. Testing code_review prompt:"
      sample_code = <<~CODE
        def fibonacci(n)
          return n if n <= 1
          fibonacci(n - 1) + fibonacci(n - 2)
        end
      CODE
      puts "   Code to review: #{sample_code.strip}"
      result = client.get_prompt('code_review', { code: sample_code, language: 'ruby' })
      review = result['messages']&.first&.dig('content', 'text') ||
               result['content']&.first&.dig('text') ||
               result.to_s
      puts '   Generated review (first 200 chars):'
      preview = review.length > 200 ? "#{review[0...200]}..." : review
      puts preview.split("\n").map { |line| "   #{line}" }.join("\n")

      # 3. Documentation prompt
      puts "\n3. Testing documentation prompt:"
      topic = 'FastMCP Protocol'
      audience = 'developers'
      puts "   Topic: #{topic}, Audience: #{audience}"
      result = client.get_prompt('documentation', { topic: topic, audience: audience })
      doc = result['messages']&.first&.dig('content', 'text') ||
            result['content']&.first&.dig('text') ||
            result.to_s
      puts '   Generated documentation (first 300 chars):'
      preview = doc.length > 300 ? "#{doc[0...300]}..." : doc
      puts preview.split("\n").map { |line| "   #{line}" }.join("\n")
    end
  rescue MCPClient::Errors::PromptGetError => e
    puts "❌ Prompt Error: #{e.message}"
    puts "      This might mean the server doesn't support prompts"
  end

  # === RESOURCES SECTION ===
  puts "\n📚 Working with Resources"
  puts '=' * 26

  # List available resources
  puts "\n📋 Fetching available resources..."
  begin
    result = client.servers.first.list_resources
    resources = result['resources']

    if resources.nil? || resources.empty?
      puts '   ℹ️  No resources available from this server'
    else
      puts "Found #{resources.length} resources:"
      resources.each_with_index do |resource, index|
        puts "  #{index + 1}. #{resource.name} (#{resource.uri})"
        puts "     MIME Type: #{resource.mime_type}" if resource.mime_type
        puts "     Description: #{resource.description}" if resource.description
      end

      # Demonstrate resource reading
      puts "\n📖 Demonstrating resource reading:"
      puts '-' * 35

      # Read each resource
      resources.each_with_index do |resource, index|
        puts "\n#{index + 1}. Reading #{resource.name}:"
        puts "   URI: #{resource.uri}"

        begin
          contents = client.servers.first.read_resource(resource.uri)
          contents.each { |content| display_content(content) }
        rescue MCPClient::Errors::ResourceReadError => e
          puts "   ❌ Error reading resource: #{e.message}"
        end
      end
    end
  rescue MCPClient::Errors::ResourceReadError => e
    puts "❌ Resource Error: #{e.message}"
    puts "      This might mean the server doesn't support resources"
  end

  # 5. Test streaming (if available)
  puts "\n🔄 Testing streaming capability:"
  puts '-' * 32
  client.call_tool_streaming('echo', { message: 'Streaming test' }) do |chunk|
    puts "   Streamed chunk: #{chunk}"
  end

  puts "\n✨ All features tested successfully!"
rescue MCPClient::Errors::ConnectionError => e
  puts "❌ Connection Error: #{e.message}"
  puts "\n💡 Make sure the echo server is running:"
  puts '   python examples/echo_server.py'
rescue MCPClient::Errors::ToolCallError => e
  puts "❌ Tool Call Error: #{e.message}"
rescue MCPClient::Errors::PromptGetError => e
  puts "❌ Prompt Error: #{e.message}"
rescue MCPClient::Errors::ResourceReadError => e
  puts "❌ Resource Error: #{e.message}"
rescue StandardError => e
  puts "❌ Unexpected Error: #{e.class}: #{e.message}"
  puts e.backtrace.join("\n") if ENV['DEBUG']
ensure
  puts "\n🧹 Cleaning up..."
  client&.cleanup
  puts '👋 Done!'
end
