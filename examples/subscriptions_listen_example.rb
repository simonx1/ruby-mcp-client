#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: subscriptions/listen (MCP 2026-07-28).
#
# The 2026-07-28 revision removed both `resources/subscribe` and the GET event
# stream. A host that wants notifications opens one instead: a long-lived
# `subscriptions/listen` request that stays open and delivers notifications on
# its own response stream until either side ends it.
#
# What this shows:
#
#   - opening a stream for the notification types you want
#   - what the server agreed to watch (acknowledged) and what it refused
#     (unsupported) — asking for something a server does not offer is not an
#     error, it just does not arrive
#   - notifications arriving on the subscription's own thread
#   - closing the stream, and the graceful end the server sends
#
# Start the server first:
#
#   python3 examples/mcp_2026_07_28_server.py &   # port 8933
#   ruby examples/subscriptions_listen_example.rb

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

logger = Logger.new($stdout)
logger.level = Logger::WARN

server_url = ENV.fetch('MCP_SERVER_URL', 'http://localhost:8933/mcp')

client = MCPClient.create_client(
  mcp_server_configs: [MCPClient.streamable_http_config(base_url: server_url)],
  logger: logger
)

received = Queue.new

begin
  puts 'Opening a subscriptions/listen stream…'

  # `resource_subscriptions` is deliberately included: this server does not
  # offer it, so it comes back under `unsupported` rather than failing the
  # call. A host uses that to decide what it can rely on.
  subscription = client.listen(
    notifications: {
      tools_list_changed: true,
      resource_subscriptions: ['file:///reports/summary.txt']
    }
  ) do |method, params|
    received << [method, params]
  end

  # `listen` returns as soon as the request is on the wire; the
  # acknowledgment arrives on the stream a moment later.
  deadline = Time.now + 5
  sleep 0.02 while subscription.acknowledged.nil? && Time.now < deadline

  puts "  acknowledged: #{subscription.acknowledged.inspect}"
  puts "  unsupported:  #{subscription.unsupported.inspect}"

  puts "\nWaiting for notifications (the server sends three)…"
  deadline = Time.now + 10
  notifications = []
  while notifications.size < 3 && Time.now < deadline
    begin
      method, params = received.pop(timeout: deadline - Time.now)
    rescue StandardError
      break
    end
    break unless method

    notifications << method
    round = params['round'] ? "(round #{params['round']})" : ''
    puts "  ← #{method} #{round}"
  end

  puts "\nClosing the subscription…"
  subscription.close

  # The server ends a subscription by answering the listen request; the client
  # reports that as a graceful close rather than a dropped stream.
  deadline = Time.now + 5
  sleep 0.05 while !subscription.closed? && Time.now < deadline
  puts "  state: #{subscription.state}"

  puts
  if notifications.size >= 3 && subscription.closed?
    puts '✅ subscriptions/listen demo completed successfully'
  else
    puts "❌ expected 3 notifications and a closed subscription, got #{notifications.size} and #{subscription.state}"
    exit 1
  end
rescue StandardError => e
  puts "\n❌ #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
  exit 1
ensure
  client.cleanup
end
