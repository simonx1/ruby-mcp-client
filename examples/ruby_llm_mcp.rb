#!/usr/bin/env ruby
# frozen_string_literal: true

# MCPClient integration example using the RubyLLM gem (OpenAI provider)
# MCP server command (pin the version rather than tracking @latest):
#  npx @playwright/mcp@0.0.78 --port 8931
#
# The model drives the browser unattended: every tool it selects is executed
# with no approval step, and page content it reads can influence the next
# call it makes. Point it at a disposable browser profile, never one holding
# authenticated sessions.
require 'bundler/setup'
require_relative '../lib/mcp_client'
require_relative 'support/example_sandbox'
require 'ruby_llm'
require 'json'
require 'logger'

# Ensure the OPENAI_API_KEY environment variable is set
api_key = ENV.fetch('OPENAI_API_KEY', nil)
abort 'Please set OPENAI_API_KEY' unless api_key

# Create an MCPClient client using the simplified connect API
logger = Logger.new($stdout)
logger.level = Logger::WARN

ExampleSandbox.announce_auto_execution('every browser tool the Playwright MCP server exposes')

# Connect using Streamable HTTP - the /mcp suffix auto-detects the transport
mcp_client = MCPClient.connect('http://localhost:8931/mcp',
                               read_timeout: 30,
                               retries: 3,
                               logger: logger)

# Configure RubyLLM with OpenAI
RubyLLM.configure { |c| c.openai_api_key = api_key }

# Wrap an MCP tool as a RubyLLM tool
def wrap_mcp_tool(mcp, tool)
  tool_name = tool.name
  Class.new(RubyLLM::Tool) do
    description tool.description
    params tool.schema
    define_method(:name) { tool_name }
    define_method(:execute) { |**args| mcp.call_tool(tool_name, args) }
  end.new
end

# Discover MCP tools and wrap them for RubyLLM
tools = mcp_client.list_tools.map { |t| wrap_mcp_tool(mcp_client, t) }

# Create a chat with all MCP tools attached
chat = RubyLLM.chat(model: 'gpt-4o-mini')
tools.each { |t| chat.with_tool(t) }

# RubyLLM handles the tool call loop automatically
response = chat.ask('Navigate to google.com and tell me the page title')
puts "Assistant: #{response.content}"

# Clean up connections
mcp_client.cleanup
puts "\nConnections cleaned up"
