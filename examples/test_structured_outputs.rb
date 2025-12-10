#!/usr/bin/env ruby
# frozen_string_literal: true

# Example script demonstrating MCP structured tool outputs (MCP 2025-06-18)
#
# This script shows how to:
# 1. Detect tools with outputSchema declarations
# 2. Call tools that return structured content
# 3. Access and parse structured data from responses
# 4. Use the structured_output? helper method
#
# Prerequisites:
# 1. Install mcp: pip install mcp
# 2. Run this client: bundle exec ruby examples/test_structured_outputs.rb

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'
require 'json'

# Helper method to display output schema properties
def display_schema_properties(output_schema)
  return unless output_schema['properties']

  puts '      Properties:'
  required_fields = output_schema['required'] || []
  output_schema['properties'].each do |prop_name, prop_schema|
    required_suffix = required_fields.include?(prop_name) ? ' (required)' : ''
    puts "        - #{prop_name}: #{prop_schema['type']}#{required_suffix}"
    puts "          #{prop_schema['description']}" if prop_schema['description']
  end
end

# Create a logger for debugging
logger = Logger.new($stdout)
logger.level = Logger::INFO

puts '🚀 Ruby MCP Client - Structured Tool Outputs Demo (MCP 2025-06-18)'
puts '=' * 70

puts '📡 Connecting to MCP Server with Structured Output Support'

begin
  # Create MCP client using the simplified connect API
  # Passing an array of command arguments auto-detects stdio transport
  client = MCPClient.connect(
    ['python', 'examples/structured_output_server.py'],
    logger: logger
  )

  puts '✅ Connected successfully!'

  # List available tools
  puts "\n📋 Fetching available tools with output schemas..."
  tools = client.list_tools

  puts "Found #{tools.length} tools:\n\n"

  # Display each tool with its output schema
  tools.each_with_index do |tool, index|
    puts "#{index + 1}. #{tool.name}"
    puts "   Description: #{tool.description}"

    # Use helper method to check if tool supports structured output
    if tool.structured_output?
      puts '   ✅ Supports structured output (MCP 2025-06-18)'

      # Display the output schema
      if tool.output_schema
        puts '   Output Schema:'
        puts "      Type: #{tool.output_schema['type']}"
        display_schema_properties(tool.output_schema)
      end
    else
      puts '   ℹ️  No structured output schema'
    end

    puts
  end

  # === DEMONSTRATE STRUCTURED OUTPUT USAGE ===
  puts "\n🛠️  Demonstrating structured output tool usage:"
  puts '-' * 70

  # 1. Test get_weather (structured output)
  puts "\n1. Testing get_weather (structured output):"
  weather_tool = tools.find { |t| t.name == 'get_weather' }
  if weather_tool
    puts "   ✓ Tool supports structured output: #{weather_tool.structured_output?}"

    result = client.call_tool('get_weather', { location: 'San Francisco', units: 'celsius' })

    # Access the text content (backward compatible)
    text_content = result['content']&.first&.dig('text')
    if text_content
      puts '   Text content (backward compatible):'
      parsed = JSON.parse(text_content)
      puts "      Location: #{parsed['location']}"
      puts "      Temperature: #{parsed['temperature']}°C"
      puts "      Conditions: #{parsed['conditions']}"
      puts "      Humidity: #{parsed['humidity']}%"
    end

    # Access structured content (MCP 2025-06-18)
    structured_content = result['structuredContent']
    if structured_content
      puts "\n   📊 Structured content (type-safe):"
      puts "      Location: #{structured_content['location']}"
      puts "      Temperature: #{structured_content['temperature']}°C"
      puts "      Conditions: #{structured_content['conditions']}"
      puts "      Humidity: #{structured_content['humidity']}%"
      puts "      Wind Speed: #{structured_content['wind_speed']} km/h"
      puts "      Timestamp: #{structured_content['timestamp']}"
    else
      puts "\n   ℹ️  Note: Server returned text content only"
      puts '       Parsing from text content instead'
    end
  end

  # 2. Test analyze_text (structured output)
  puts "\n2. Testing analyze_text (structured output with optional fields):"
  analyze_tool = tools.find { |t| t.name == 'analyze_text' }
  if analyze_tool
    puts "   ✓ Tool supports structured output: #{analyze_tool.structured_output?}"

    sample_text = <<~TEXT
      The Model Context Protocol (MCP) is a revolutionary standard.
      It enables seamless integration between AI applications and external tools.
      MCP 2025-06-18 introduces structured outputs for type safety.
    TEXT

    result = client.call_tool('analyze_text', { text: sample_text, include_words: true })

    # Parse the response (checking both structured and text content)
    data = result['structuredContent'] || JSON.parse(result['content']&.first&.dig('text') || '{}')

    puts '   📊 Text Analysis Results:'
    puts "      Characters: #{data['character_count']}"
    puts "      Words: #{data['word_count']}"
    puts "      Lines: #{data['line_count']}"
    puts "      Sentences: #{data['sentence_count']}"
    puts "      Avg Word Length: #{data['average_word_length']&.round(2)}"

    if data['top_words'] && !data['top_words'].empty?
      puts '      Top Words:'
      data['top_words'].each do |word_data|
        puts "        - #{word_data['word']}: #{word_data['count']}"
      end
    end
  end

  # 3. Test calculate_stats (structured output)
  puts "\n3. Testing calculate_stats (structured output):"
  stats_tool = tools.find { |t| t.name == 'calculate_stats' }
  if stats_tool
    puts "   ✓ Tool supports structured output: #{stats_tool.structured_output?}"

    numbers = [10, 25, 15, 30, 20, 35, 18, 22, 28, 12]
    puts "   Input numbers: #{numbers.inspect}"

    result = client.call_tool('calculate_stats', { numbers: numbers })

    # Parse the response
    data = result['structuredContent'] || JSON.parse(result['content']&.first&.dig('text') || '{}')

    puts '   📊 Statistical Results:'
    puts "      Count: #{data['count']}"
    puts "      Sum: #{data['sum']}"
    puts "      Mean: #{data['mean']&.round(2)}"
    puts "      Median: #{data['median']}"
    puts "      Min: #{data['min']}"
    puts "      Max: #{data['max']}"
    puts "      Range: #{data['range']}"
  end

  # === SUMMARY ===
  puts "\n📊 Structured Output Support Summary:"
  puts '-' * 70

  structured_tools = tools.select(&:structured_output?)

  puts "Total tools: #{tools.length}"
  puts "Tools with structured output: #{structured_tools.length}"
  puts "\nTools supporting structured outputs:"
  structured_tools.each do |tool|
    required_list = tool.output_schema&.dig('required') || []
    properties = tool.output_schema&.dig('properties') || {}
    puts "  - #{tool.name}: #{properties.keys.length} fields (#{required_list.length} required)"
  end

  puts "\n✨ Structured outputs demo completed successfully!"
  puts "\n💡 Key Benefits of Structured Outputs (MCP 2025-06-18):"
  puts '   • Type-safe responses with JSON Schema validation'
  puts '   • Predictable data structures for easier parsing'
  puts '   • Better IDE support and code completion'
  puts '   • Backward compatible with text content'
  puts '   • Improved error detection and debugging'
rescue MCPClient::Errors::ConnectionError => e
  puts "❌ Connection Error: #{e.message}"
  puts "\n💡 Make sure the structured output server is running:"
  puts '   python examples/structured_output_server.py'
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
