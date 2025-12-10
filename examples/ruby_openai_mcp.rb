#!/usr/bin/env ruby
# frozen_string_literal: true

# MCPClient integration example using the alexrudall/ruby-openai gem
# MCP server command:
#  npx @playwright/mcp@latest --port 8931
require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'openai'
require 'json'
require 'logger'
require 'byebug'

# Ensure the OPENAI_API_KEY environment variable is set
api_key = ENV.fetch('OPENAI_API_KEY', nil)
abort 'Please set OPENAI_API_KEY' unless api_key

# Create an MCPClient client using the simplified connect API
logger = Logger.new($stdout)
logger.level = Logger::WARN # DEBUG

# Connect using Streamable HTTP - the /mcp suffix auto-detects the transport
mcp_client = MCPClient.connect('http://localhost:8931/mcp',
                               read_timeout: 30,
                               retries: 3,
                               logger: logger)

# Initialize the Ruby-OpenAI client
client = OpenAI::Client.new(access_token: api_key)

# Get all tools
tools = mcp_client.to_openai_tools

# Or filter to only use specific tools (by exact name)
# tools = mcp_client.to_openai_tools(tool_names: ['mcp__browser-tools__takeScreenshot'])

# Build initial chat messages
messages = [
  { role: 'system', content: 'You are a helpful assistant' },
  { role: 'user', content: 'Open google.com website and search for DAO' }
]

# 1) Send chat with function definitions
response = client.chat(
  parameters: {
    model: 'gpt-5',
    messages: messages,
    tools: tools
  }
)

# byebug

# Extract the function call from the response
tool_call = response.dig('choices', 0, 'message', 'tool_calls', 0)

# 2) Invoke the MCPClient tool
function_details = tool_call['function']
name = function_details['name']
args = JSON.parse(function_details['arguments'])
result = mcp_client.call_tool(name, args)

# 3) Add function call + result to conversation
messages << { role: 'assistant', tool_calls: [tool_call] }
messages << { role: 'tool', tool_call_id: tool_call['id'], name: name, content: result.to_json }

# 4) Get the first response from the model
response = client.chat(
  parameters: {
    model: 'gpt-5',
    messages: messages,
    tools: tools
  }
)

# Extract the function call from the response
tool_call = response.dig('choices', 0, 'message', 'tool_calls', 0)

# 5) Invoke the next MCPClient tool
function_details = tool_call['function']
name = function_details['name']
args = JSON.parse(function_details['arguments'])
result = mcp_client.call_tool(name, args)

# 6) Add function call + result to conversation
messages << { role: 'assistant', tool_calls: [tool_call] }
messages << { role: 'tool', tool_call_id: tool_call['id'], name: name, content: result.to_json }

# 7) Get final response from the model
final = client.chat(
  parameters: {
    model: 'gpt-5',
    messages: messages,
    tools: tools
  }
)

puts final.dig('choices', 0, 'message', 'content')

sleep 5

mcp_client.call_tool('browser_close', {})

# Clean up connections
mcp_client.cleanup
puts "\nConnections cleaned up"
