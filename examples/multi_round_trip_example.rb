#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: multi round-trip requests (MCP 2026-07-28).
#
# A modern server has no channel for calling the client back, so when it needs
# something mid-request it says so in the *result*: `resultType:
# "input_required"`, a set of `inputRequests`, and an opaque `requestState`.
#
# The client answers each request with the handlers it already has — the
# elicitation handler here — and re-sends the original request with
# `inputResponses` and that state echoed back verbatim. From the host's side
# it is still one `call_tool`: the round trips happen underneath.
#
# What this shows:
#
#   - an elicitation handler answering a question the server asked mid-call
#   - the tool returning its real result on the second round trip
#   - the guard rails: a request the client cannot honour raises
#     InputRequiredError with the requests and state attached
#
# Start the server first:
#
#   python3 examples/mcp_2026_07_28_server.py &   # port 8933
#   ruby examples/multi_round_trip_example.rb

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

logger = Logger.new($stdout)
logger.level = Logger::WARN

server_url = ENV.fetch('MCP_SERVER_URL', 'http://localhost:8933/mcp')

asked = []

# A two-argument handler is called with the server's message and the schema
# it wants filled in (a one-argument handler gets only the message). Return a
# hash to answer, or nil/false to decline.
elicitation_handler = lambda do |message, schema|
  asked << message
  puts "  server asks: #{message}"
  puts "  requested schema: #{(schema['properties'] || {}).keys.inspect}"
  puts '  answering with { "name" => "Ada Lovelace" }'
  { 'name' => 'Ada Lovelace' }
end

# Handlers are constructor arguments, so this one goes through Client.new
# rather than the create_client shorthand.
client = MCPClient::Client.new(
  mcp_server_configs: [MCPClient.streamable_http_config(base_url: server_url)],
  elicitation_handler: elicitation_handler,
  logger: logger
)

begin
  puts 'Calling create_ticket — the server will need more before it can answer.'
  result = client.call_tool('create_ticket', { 'summary' => 'Printer is on fire' })

  text = (result['content'] || result[:content])&.first&.fetch('text', nil)
  puts "  result: #{text}"

  ok = asked.size == 1 && text.to_s.include?('Ada Lovelace') && text.to_s.include?('Printer is on fire')

  # A client with no elicitation handler declares no elicitation capability,
  # and a well-behaved server checks that before it asks: it refuses the call
  # with -32021 rather than starting a round trip nobody can finish. A server
  # that asked anyway would give this client an InputRequiredError instead,
  # carrying the requests it could not honour and the opaque request state.
  puts "\nA client that declares no elicitation capability is refused up front:"
  bare = MCPClient::Client.new(
    mcp_server_configs: [MCPClient.streamable_http_config(base_url: server_url)],
    logger: logger
  )
  begin
    bare.call_tool('create_ticket', { 'summary' => 'Second ticket' })
    puts '  ❌ expected the server to refuse'
    ok = false
  rescue MCPClient::Errors::MissingRequiredClientCapabilityError => e
    puts "  ✅ MissingRequiredClientCapabilityError: #{e.message[0, 70]}"
  rescue MCPClient::Errors::InputRequiredError => e
    # Also correct, for a server that asks without checking first.
    puts "  ✅ InputRequiredError: #{e.message[0, 60]}"
    puts "     input_requests: #{e.input_requests.keys.inspect}, request_state present: #{!e.request_state.nil?}"
  ensure
    bare.cleanup
  end

  puts
  if ok
    puts '✅ multi round-trip demo completed successfully'
  else
    puts '❌ multi round-trip demo did not complete as expected'
    exit 1
  end
rescue StandardError => e
  puts "\n❌ #{e.class}: #{e.message}"
  puts e.backtrace.first(5)
  exit 1
ensure
  client.cleanup
end
