#!/usr/bin/env ruby
# frozen_string_literal: true

# MCPClient integration example using the `gemini-ai` Ruby gem
#
# Prerequisites
#  - A running MCP server (for instance: `npx @modelcontextprotocol/server-filesystem .`)
#  - A Vertex AI service-account JSON file (downloaded from Google Cloud) named
#    `google-credentials.json` in the project root, or set its location in
#      export VERTEX_CREDENTIALS_FILE=/path/to/file.json
#  - (Optional) choose region with `VERTEX_REGION` (default: us-east4).
#
# This example shows a full round-trip interaction:
# 1. The assistant is provided with the MCP tool definitions (as Gemini "function_declarations").
# 2. The model decides to call one of the tools and returns a `functionCall`.
# 3. We execute the requested tool via `MCPClient`.
# 4. The tool result is sent back to Gemini in a follow-up request so the model can
#    formulate a final answer for the user.

require 'bundler/setup'
require_relative '../lib/mcp_client'

# The gem itself
require 'gemini-ai'
require 'logger'
require 'json'

# -----------------------------------------------------------------------------
# 1. ENV checks & Client initialisation
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# 1.a  Vertex credentials discovery
# -----------------------------------------------------------------------------

vertex_creds_file = ENV['VERTEX_CREDENTIALS_FILE'] || File.join(Dir.pwd, 'google-credentials.json')

unless File.exist?(vertex_creds_file)
  abort <<~MSG
    Vertex service-account credentials file not found.

    Place your downloaded service-account JSON at:
      #{vertex_creds_file}
    or set the path explicitly with:
      export VERTEX_CREDENTIALS_FILE=/path/to/google-credentials.json
  MSG
end

# Create an MCPClient instance using the simplified connect API.
# For a quick demo we rely on the filesystem server via stdio (no network services needed).
logger = Logger.new($stdout)
logger.level = Logger::WARN

# Connect using stdio - passing an array of command arguments auto-detects stdio transport
mcp_client = MCPClient.connect(
  %W[npx -y @modelcontextprotocol/server-filesystem #{Dir.pwd}],
  logger: logger
)

# -----------------------------------------------------------------------------
# 1.b  Initialise Gemini client using Vertex AI (tools supported)
# -----------------------------------------------------------------------------

vertex_region = ENV['VERTEX_REGION'] || 'us-east4'

client = Gemini.new(
  credentials: {
    service: 'vertex-ai-api',
    file_path: vertex_creds_file,
    region: vertex_region
  },
  options: {
    model: 'gemini-2.0-flash-001',
    server_sent_events: false # non-streaming for simplicity
  }
)

puts "Gemini Vertex client initialised (region=#{vertex_region})."

# -----------------------------------------------------------------------------
# 2. Prepare tool definitions for Gemini
# -----------------------------------------------------------------------------

# Fetch tool list from the MCP server (cached by default)
mcp_client.list_tools

# Convert to Gemini tool schema (function_declarations)
google_tools = mcp_client.to_google_tools

# -----------------------------------------------------------------------------
# 3. First request – let the model choose and call a tool
# -----------------------------------------------------------------------------

system_instruction = {
  role: 'user',
  parts: {
    text: 'You can call filesystem tools.'
  }
}

# Build the request payload
input = {
  tools: {
    function_declarations: google_tools
  },
  contents: [
    { role: 'user',
      parts: { text: 'List all files in the directory path "./". Use the appropriate filesystem tool to do so.' } }
  ],
  system_instruction: system_instruction
}

# -----------------------------------------------------------------------------
# 3.a Make first request (with basic error diagnostics)
# -----------------------------------------------------------------------------

puts 'Sending first request with tool definitions…'

begin
  first_response = client.generate_content(input)
rescue Gemini::Errors::RequestError => e
  puts "Gemini API returned #{e.class}: #{e.message}"
  puts "Payload sent:\n#{JSON.pretty_generate(e.payload)}" if e.respond_to?(:payload)
  exit 1
rescue Faraday::ClientError => e
  puts "Faraday raised #{e.class}: #{e.message}"
  if (resp = e.response)
    status = resp[:status]
    body = resp[:body]
    puts "Status: #{status}"
    puts "Response body:\n#{body}"
  end
  exit 1
end

puts 'First response received.'

# -----------------------------------------------------------------------------
# 4. Extract the tool call from the response
# -----------------------------------------------------------------------------

candidate = first_response.dig('candidates', 0)
unless candidate
  puts 'No candidates in response:'
  puts JSON.pretty_generate(first_response)
  exit 1
end

function_call_part = candidate.dig('content', 'parts')&.find { |p| p.key?('functionCall') }

unless function_call_part
  puts 'No functionCall found in response:'
  puts JSON.pretty_generate(first_response)
  exit 1
end

function_call = function_call_part['functionCall']
tool_name = function_call['name']
tool_args = function_call['args'] || {}

puts "Model requested tool: #{tool_name} with args: #{tool_args.inspect}"

# -----------------------------------------------------------------------------
# 5. Invoke the MCP tool locally
# -----------------------------------------------------------------------------

tool_result = mcp_client.call_tool(tool_name, tool_args)

puts 'Tool executed successfully.'

# -----------------------------------------------------------------------------
# 6. Second request – return the tool result so the model can answer
# -----------------------------------------------------------------------------

# Gemini expects the original tool call (assistant role) followed by a
# `function` role message containing the result.

function_response_part = {
  functionResponse: {
    name: tool_name,
    response: {
      name: tool_name,
      content: tool_result.to_json
    }
  }
}

second_input = {
  tools: {
    function_declarations: google_tools
  },
  contents: [
    { role: 'user', parts: { text: 'List all files in current directory' } },
    candidate['content'], # the assistant message containing the functionCall
    { role: 'function', parts: [function_response_part] }
  ],
  system_instruction: system_instruction
}

puts 'Sending second request with tool result…'
final_response = client.generate_content(second_input)

# -----------------------------------------------------------------------------
# 7. Display the final answer
# -----------------------------------------------------------------------------

final_parts = final_response.dig('candidates', 0, 'content', 'parts') || []

# Concatenate all text parts for display
final_text = final_parts.map { |p| p['text'] }.join('\n')

puts '\nFinal response:'
puts final_text

# Cleanup
mcp_client.cleanup
