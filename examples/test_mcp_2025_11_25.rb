#!/usr/bin/env ruby
# frozen_string_literal: true

# Test MCP 2025-11-25 Features
#
# This script connects to the Python MCP 2025-11-25 feature demo server via stdio
# and exercises every new feature, printing PASS/FAIL for each test.
#
# Features tested:
# - Audio content in tool results
# - Resource annotations with lastModified
# - Tool annotations (readOnlyHint, destructiveHint, idempotentHint, openWorldHint)
# - Completion with context parameter
# - ResourceLink content type in tool results
# - Task management (create, get, cancel)
#
# Usage:
#   bundle exec ruby examples/test_mcp_2025_11_25.rb

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

# Tracks test results
class TestRunner
  attr_reader :passed, :failed, :errors

  def initialize
    @passed = 0
    @failed = 0
    @errors = []
  end

  def assert(description, condition, detail = nil)
    if condition
      @passed += 1
      puts "  PASS: #{description}"
    else
      @failed += 1
      msg = "  FAIL: #{description}"
      msg += " — #{detail}" if detail
      puts msg
      @errors << msg
    end
  end

  def summary # rubocop:disable Naming/PredicateMethod
    total = @passed + @failed
    puts
    puts '=' * 60
    puts "Results: #{@passed}/#{total} passed, #{@failed} failed"
    @errors.each { |e| puts e } if @failed.positive?
    puts '=' * 60
    @failed.zero?
  end
end

runner = TestRunner.new

# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------

logger = Logger.new($stdout)
logger.level = ENV['DEBUG'] ? Logger::DEBUG : Logger::WARN
logger.formatter = proc do |severity, datetime, _progname, msg|
  "#{datetime.strftime('%H:%M:%S')} [#{severity}] #{msg}\n"
end

# ---------------------------------------------------------------------------
# Connect to the server via stdio
# ---------------------------------------------------------------------------

puts 'MCP 2025-11-25 Feature Tests'
puts '=' * 60

server_script = File.expand_path('mcp_2025_11_25_server.py', __dir__)

unless File.exist?(server_script)
  puts "FAIL: Server script not found: #{server_script}"
  exit 1
end

puts "Spawning server: python3 #{server_script}"
puts

client = MCPClient::Client.new(
  mcp_server_configs: [
    {
      type: 'stdio',
      command: ['python3', server_script],
      name: 'mcp-2025-11-25-demo',
      read_timeout: 30
    }
  ],
  logger: logger
)

begin
  # =========================================================================
  # 1. Tool Annotations
  # =========================================================================

  puts '--- Tool Annotations ---'
  tools = client.list_tools
  runner.assert('list_tools returns tools', tools.size >= 5, "got #{tools.size}")

  get_audio = tools.find { |t| t.name == 'get_audio' }
  runner.assert('get_audio tool found', !get_audio.nil?)
  if get_audio
    runner.assert('get_audio: readOnlyHint is true', get_audio.read_only_hint? == true)
    runner.assert('get_audio: destructiveHint is false', get_audio.destructive_hint? == false)
    runner.assert('get_audio: idempotentHint is true', get_audio.idempotent_hint? == true)
    runner.assert('get_audio: openWorldHint is false', get_audio.open_world_hint? == false)
  end

  delete_item = tools.find { |t| t.name == 'delete_item' }
  runner.assert('delete_item tool found', !delete_item.nil?)
  if delete_item
    runner.assert('delete_item: readOnlyHint is false', delete_item.read_only_hint? == false)
    runner.assert('delete_item: destructiveHint is true', delete_item.destructive_hint? == true)
    runner.assert('delete_item: idempotentHint is true', delete_item.idempotent_hint? == true)
    runner.assert('delete_item: openWorldHint is false', delete_item.open_world_hint? == false)
  end

  send_email = tools.find { |t| t.name == 'send_email' }
  runner.assert('send_email tool found', !send_email.nil?)
  if send_email
    runner.assert('send_email: readOnlyHint is false', send_email.read_only_hint? == false)
    runner.assert('send_email: destructiveHint is false', send_email.destructive_hint? == false)
    runner.assert('send_email: idempotentHint is false', send_email.idempotent_hint? == false)
    runner.assert('send_email: openWorldHint is true', send_email.open_world_hint? == true)
  end

  # =========================================================================
  # 2. Audio Content
  # =========================================================================

  puts
  puts '--- Audio Content ---'
  audio_result = client.call_tool('get_audio', { frequency: 440 })
  content_items = audio_result['content']
  runner.assert('get_audio returns content array', content_items.is_a?(Array) && content_items.size >= 2)

  audio_item = content_items.find { |c| c['type'] == 'audio' }
  runner.assert('audio content item present', !audio_item.nil?)

  if audio_item
    audio = MCPClient::AudioContent.from_json(audio_item)
    runner.assert('AudioContent.data is non-empty', !audio.data.nil? && !audio.data.empty?)
    runner.assert('AudioContent.mime_type is audio/wav', audio.mime_type == 'audio/wav')

    decoded = audio.content
    runner.assert('decoded audio starts with RIFF header', decoded[0..3] == 'RIFF')
    runner.assert('decoded audio contains WAVE marker', decoded[8..11] == 'WAVE')
  end

  text_item = content_items.find { |c| c['type'] == 'text' }
  runner.assert('text content accompanies audio', !text_item.nil? && text_item['text'].include?('440'))

  # =========================================================================
  # 3. Resource Annotations with lastModified
  # =========================================================================

  puts
  puts '--- Resource Annotations (lastModified) ---'
  result = client.list_resources
  resources = result['resources'] || result[:resources] || []
  runner.assert('list_resources returns resources', resources.size >= 3, "got #{resources.size}")

  readme_res = resources.find { |r| r.uri == 'file:///demo/README.md' }
  runner.assert('README resource found', !readme_res.nil?)
  if readme_res
    runner.assert('README has annotations', !readme_res.annotations.nil?)
    runner.assert(
      'README lastModified is 2025-11-25T10:30:00Z',
      readme_res.last_modified == '2025-11-25T10:30:00Z'
    )
    runner.assert('README has audience annotation', readme_res.annotations['audience'].is_a?(Array))
    runner.assert('README has priority annotation', (readme_res.annotations['priority'] - 1.0).abs < 0.001)
  end

  config_res = resources.find { |r| r.uri == 'file:///demo/config.json' }
  runner.assert('config resource found', !config_res.nil?)
  if config_res
    runner.assert(
      'config lastModified is 2025-11-20T08:00:00Z',
      config_res.last_modified == '2025-11-20T08:00:00Z'
    )
  end

  audio_res = resources.find { |r| r.uri == 'file:///demo/audio_sample.wav' }
  runner.assert('audio_sample resource found', !audio_res.nil?)
  if audio_res
    runner.assert('audio_sample has lastModified', !audio_res.last_modified.nil?)
    runner.assert('audio_sample mime_type is audio/wav', audio_res.mime_type == 'audio/wav')
  end

  # =========================================================================
  # 4. ResourceLink in Tool Results
  # =========================================================================

  puts
  puts '--- ResourceLink Content ---'
  link_result = client.call_tool('get_resource_link', { resource_name: 'readme' })
  link_items = link_result['content']
  runner.assert('get_resource_link returns content', link_items.is_a?(Array) && link_items.size >= 2)

  rl_item = link_items.find { |c| c['type'] == 'resource_link' }
  runner.assert('resource_link content item present', !rl_item.nil?)

  if rl_item
    rl = MCPClient::ResourceLink.from_json(rl_item)
    runner.assert('ResourceLink.uri is file:///demo/README.md', rl.uri == 'file:///demo/README.md')
    runner.assert('ResourceLink.name is README.md', rl.name == 'README.md')
    runner.assert('ResourceLink.description is non-empty', !rl.description.nil? && !rl.description.empty?)
    runner.assert('ResourceLink.mime_type is text/markdown', rl.mime_type == 'text/markdown')
    runner.assert('ResourceLink.type returns resource_link', rl.type == 'resource_link')
  end

  # Also test config link
  config_link_result = client.call_tool('get_resource_link', { resource_name: 'config' })
  config_rl_item = config_link_result['content'].find { |c| c['type'] == 'resource_link' }
  runner.assert(
    'config resource_link has correct URI',
    config_rl_item && config_rl_item['uri'] == 'file:///demo/config.json'
  )

  # =========================================================================
  # 5. Completion with Context Parameter
  # =========================================================================

  puts
  puts '--- Completion with Context ---'

  # First, complete country_code without context
  country_result = client.complete(
    ref: { 'type' => 'ref/prompt', 'name' => 'lookup_city' },
    argument: { 'name' => 'country_code', 'value' => 'U' }
  )
  runner.assert(
    'country_code completion returns US and UK',
    country_result['values'].is_a?(Array) && country_result['values'].sort == %w[UK US]
  )

  # Complete city WITHOUT context — should return all cities starting with "N"
  no_ctx_result = client.complete(
    ref: { 'type' => 'ref/prompt', 'name' => 'lookup_city' },
    argument: { 'name' => 'city', 'value' => 'N' }
  )
  runner.assert(
    'city completion without context returns cities from all countries',
    no_ctx_result['values'].is_a?(Array) && no_ctx_result['values'].size > 2,
    "got #{no_ctx_result['values'].inspect}"
  )

  # Complete city WITH context — only JP cities starting with "N"
  ctx_result = client.complete(
    ref: { 'type' => 'ref/prompt', 'name' => 'lookup_city' },
    argument: { 'name' => 'city', 'value' => 'N' },
    context: { 'arguments' => { 'country_code' => 'JP' } }
  )
  runner.assert(
    'city completion with JP context returns only Japanese cities',
    ctx_result['values'].is_a?(Array) && ctx_result['values'].all? { |c| %w[Nagoya].include?(c) },
    "got #{ctx_result['values'].inspect}"
  )

  # Complete city with US context starting with "N"
  us_ctx_result = client.complete(
    ref: { 'type' => 'ref/prompt', 'name' => 'lookup_city' },
    argument: { 'name' => 'city', 'value' => 'N' },
    context: { 'arguments' => { 'country_code' => 'US' } }
  )
  runner.assert(
    'city completion with US context returns New York',
    us_ctx_result['values'].is_a?(Array) && us_ctx_result['values'].include?('New York'),
    "got #{us_ctx_result['values'].inspect}"
  )

  # =========================================================================
  # 6. Task Management (create, get, cancel)
  # =========================================================================

  puts
  puts '--- Task Management ---'

  # Create a task
  task = client.create_task('background_work', params: { input: 'test' }, progress_token: 'tok-1')
  runner.assert('create_task returns a Task', task.is_a?(MCPClient::Task))
  runner.assert('task has an id', !task.id.nil? && !task.id.empty?)
  runner.assert('task initial state is pending', task.state == 'pending')
  runner.assert('task has message', !task.message.nil?)

  # Wait briefly then get task state (should be running or completed)
  sleep 0.5
  task_state = client.get_task(task.id)
  runner.assert('get_task returns a Task', task_state.is_a?(MCPClient::Task))
  runner.assert(
    'task is running or completed after 0.5s',
    %w[running completed].include?(task_state.state),
    "state: #{task_state.state}"
  )

  # Wait for completion
  sleep 2.5
  final_state = client.get_task(task.id)
  runner.assert('task is completed after waiting', final_state.state == 'completed')
  runner.assert('completed task has result', !final_state.result.nil?) if final_state.state == 'completed'

  # Create another task and cancel it quickly
  cancel_task = client.create_task('cancel_test', params: {})
  runner.assert('cancel test task created', cancel_task.is_a?(MCPClient::Task))

  cancelled = client.cancel_task(cancel_task.id)
  runner.assert('cancel_task returns a Task', cancelled.is_a?(MCPClient::Task))
  runner.assert('cancelled task state is cancelled', cancelled.state == 'cancelled')

  # Verify get on cancelled task
  cancelled_get = client.get_task(cancel_task.id)
  runner.assert('get_task on cancelled task returns cancelled', cancelled_get.state == 'cancelled')

  # Task error handling: get non-existent task
  begin
    client.get_task('nonexistent-task-id')
    runner.assert('get non-existent task raises error', false, 'no exception raised')
  rescue MCPClient::Errors::TaskNotFound
    runner.assert('get non-existent task raises TaskNotFound', true)
  rescue MCPClient::Errors::TaskError
    runner.assert('get non-existent task raises TaskError', true)
  end

  # =========================================================================
  # Summary
  # =========================================================================

  success = runner.summary
  exit(success ? 0 : 1)
rescue MCPClient::Errors::ConnectionError => e
  puts
  puts "Connection error: #{e.message}"
  puts 'Make sure python3 is available and the server script exists.'
  exit 1
rescue StandardError => e
  puts
  puts "Error: #{e.class}: #{e.message}"
  puts e.backtrace.first(5).join("\n") if ENV['DEBUG']
  exit 1
ensure
  client&.cleanup
end
