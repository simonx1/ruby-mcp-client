#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: task-augmented tools/call (MCP 2025-11-25 Tasks utility).
#
# A "task-capable" server advertises the tasks.requests.tools.call capability,
# and a long-running tool declares execution.taskSupport of "optional" or
# "required". Calling such a tool as a task returns immediately with a task
# handle; the actual result is fetched later once the task is terminal.
#
# Tasks are an experimental 2025-11-25 feature that most servers (including
# Zapier, the default target here) do not implement yet. Against such servers
# this example demonstrates the client's capability-aware behavior instead:
# tool.supports_task?, the TaskError from call_tool_as_task, and the
# CapabilityError raised by list_tasks (MCP lifecycle: "Only use capabilities
# that were successfully negotiated").
#
# Run against Zapier (default):
#   MCP_BEARER_TOKEN='your_zapier_token' ./examples/tasks_example.rb
# Or against any task-capable server:
#   MCP_SERVER_URL='https://example.com/mcp' \
#   MCP_BEARER_TOKEN='your_token' ./examples/tasks_example.rb long_job

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

logger = Logger.new($stdout)
logger.level = Logger::WARN

server_url = ENV.fetch('MCP_SERVER_URL', 'https://mcp.zapier.com/api/v1/connect')
bearer_token = ENV.fetch('MCP_BEARER_TOKEN', nil)
tool_name = ARGV[0]

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

# Run the real task workflow against a task-capable server.
def run_task_flow(client, tool_name)
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

  # List outstanding tasks (tasks.list capability)
  page = client.list_tasks
  puts "Server currently knows about #{page[:tasks].size} task(s)."
end

# Demonstrate the client's graceful behavior against a server that has not
# negotiated the tasks capability (the common case today, e.g. Zapier).
def demonstrate_capability_gating(client, tool)
  puts "\nDemonstrating capability-aware task handling:"
  puts "  tool.supports_task? for '#{tool.name}': #{tool.supports_task?}"

  begin
    client.call_tool_as_task(tool.name, {})
  rescue MCPClient::Errors::TaskError, MCPClient::Errors::ValidationError => e
    puts "  call_tool_as_task -> #{e.class.name.split('::').last}: #{e.message}"
  end

  begin
    client.list_tasks
  rescue MCPClient::Errors::CapabilityError => e
    puts "  list_tasks -> CapabilityError: #{e.message}"
  end
end

begin
  tools = client.list_tools
  server = client.servers.first
  puts "Connected to #{server_url} (#{tools.size} tools)"

  tasks_capable = server.capability?('tasks', 'requests', 'tools', 'call')
  puts "Server declares tasks.requests.tools.call: #{tasks_capable}"

  task_tool = tool_name ? client.find_tool(tool_name) : tools.find(&:supports_task?)
  raise "Tool '#{tool_name}' not found on the server" if tool_name && task_tool.nil?

  if tasks_capable && task_tool&.supports_task?
    run_task_flow(client, task_tool.name)
  elsif tools.any?
    puts 'Server does not support task-augmented tool calls; regular tools/call still works.'
    # Prefer a tool without required arguments: call_tool_as_task validates
    # arguments before the capability check, and the point here is to show
    # the TaskError, not a ValidationError.
    demo_tool = task_tool || tools.find do |t|
      required = (t.schema && (t.schema['required'] || t.schema[:required])) || []
      required.empty?
    end || tools.first
    demonstrate_capability_gating(client, demo_tool)
  else
    puts 'Server exposes no tools to demonstrate with.'
  end

  puts "\nTasks example completed"
rescue MCPClient::Errors::TaskError => e
  warn "Task error: #{e.message}"
  exit 1
rescue MCPClient::Errors::MCPError => e
  warn "MCP error: #{e.message}"
  exit 1
ensure
  client.cleanup
end
