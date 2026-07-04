#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: task-augmented tools/call (MCP 2025-11-25 Tasks utility).
#
# A "task-capable" server advertises the tasks.requests.tools.call capability,
# and a long-running tool declares execution.taskSupport of "optional" or
# "required". Calling such a tool as a task returns immediately with a task
# handle; the actual result is fetched later once the task is terminal.
#
# Run against a task-capable server, e.g.:
#   MCP_SERVER_URL='https://example.com/mcp' \
#   MCP_BEARER_TOKEN='your_token' ./examples/tasks_example.rb long_job

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

logger = Logger.new($stdout)
logger.level = Logger::INFO

server_url = ENV.fetch('MCP_SERVER_URL', 'https://example.com/mcp')
bearer_token = ENV.fetch('MCP_BEARER_TOKEN', nil)
tool_name = ARGV[0] || 'long_job'

headers = {}
headers['Authorization'] = "Bearer #{bearer_token}" if bearer_token

client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.streamable_http_config(base_url: server_url, headers: headers)
  ],
  logger: logger
)

# Surface server-pushed task status updates
client.on_notification do |_server, method, params|
  puts "  [notification] Task #{params['taskId']} -> #{params['status']}" if method == 'notifications/tasks/status'
end

begin
  tool = client.find_tool(tool_name)
  raise "Tool '#{tool_name}' not found on the server" unless tool

  unless tool.supports_task?
    raise "Tool '#{tool_name}' does not support task execution " \
          "(execution.taskSupport = #{tool.task_support.inspect})"
  end

  puts "Creating a task for tool '#{tool_name}'..."
  task = client.call_tool_as_task(tool_name, { 'input' => 'demo' }, ttl: 60_000)
  puts "  created task #{task.task_id} (status: #{task.status})"

  # Poll until the task finishes or asks for input, honoring the server's
  # suggested poll interval (milliseconds).
  until task.terminal? || task.input_required?
    sleep((task.poll_interval || 1000) / 1000.0)
    task = client.get_task(task.task_id)
    puts "  status: #{task.status}"
  end

  if task.terminal? && task.status == 'completed'
    result = client.get_task_result(task.task_id)
    puts "Result: #{result.inspect}"
  else
    puts "Task ended in status: #{task.status}"
  end

  # List and (optionally) cancel outstanding tasks
  page = client.list_tasks
  puts "Server currently knows about #{page[:tasks].size} task(s)."
rescue MCPClient::Errors::TaskError => e
  warn "Task error: #{e.message}"
rescue MCPClient::Errors::MCPError => e
  warn "MCP error: #{e.message}"
ensure
  client.cleanup
end
