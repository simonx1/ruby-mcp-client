#!/usr/bin/env ruby
# frozen_string_literal: true

# Scriptable stdio MCP server for pinning protocol-era negotiation against a
# real subprocess (MCP 2026-07-28 basic/transports/stdio "Backward
# Compatibility"). Stubbed transports cannot show the interleavings that
# matter here: a server that writes before it is spoken to, a server that
# never answers, or a server that is left running after a failed probe.
#
#   ruby protocol_era_stdio_server.rb MODE [TRANSCRIPT]
#
# MODE is one of:
#   modern            answer server/discover with a DiscoverResult
#   legacy            reject server/discover, then run the initialize handshake
#   legacy-ping-first like legacy, but send a `ping` request before answering
#                     anything and refuse to process further input until the
#                     response arrives (a legacy server MAY ping at startup;
#                     the receiver MUST respond promptly)
#   silent-probe      never answer server/discover; run the handshake instead
#   future-only       advertise a protocol version no client speaks, and keep
#                     running after stdin closes so a leaked process is visible
#
# TRANSCRIPT, when given, receives one line per event: `pid <n>` at startup and
# the method name of every JSON-RPC message received.
require 'json'

MODE = ARGV[0] || 'modern'
TRANSCRIPT = ARGV[1]
# How long future-only lingers after stdin closes; the client is expected to
# terminate it long before this elapses.
LINGER_SECONDS = 10

$stdout.sync = true

# @param line [String] transcript entry
# @return [void]
def record(line)
  File.write(TRANSCRIPT, "#{line}\n", mode: 'a') if TRANSCRIPT
end

# @param msg [Hash] JSON-RPC message to write to stdout
# @return [void]
def emit(msg)
  $stdout.puts(JSON.generate(msg))
end

# @param id [Object] request id
# @param result [Hash] JSON-RPC result
# @return [void]
def respond(id, result)
  emit({ 'jsonrpc' => '2.0', 'id' => id, 'result' => result })
end

# @param id [Object] request id
# @param message [String] error message
# @param code [Integer] JSON-RPC error code
# @return [void]
def respond_error(id, message, code = -32_601)
  emit({ 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => code, 'message' => message } })
end

# @param versions [Array<String>] the versions to advertise
# @return [Hash] a DiscoverResult
def discover_result(versions)
  { 'resultType' => 'complete', 'supportedVersions' => versions,
    'capabilities' => { 'tools' => {} },
    '_meta' => { 'io.modelcontextprotocol/serverInfo' => { 'name' => 'era-fixture', 'version' => '1.0' } } }
end

# @return [Hash] a 2025-11-25 initialize result
def initialize_result
  { 'protocolVersion' => '2025-11-25', 'capabilities' => { 'tools' => {} },
    'serverInfo' => { 'name' => 'era-fixture', 'version' => '1.0' } }
end

# @return [Array<Hash>] the single tool this fixture exposes
def tools
  [{ 'name' => 'echo', 'description' => 'echo', 'inputSchema' => { 'type' => 'object' } }]
end

# Answer the requests every mode shares.
# @param msg [Hash] the request
# @return [void]
def handle_common(msg)
  case msg['method']
  when 'initialize' then respond(msg['id'], initialize_result)
  when 'tools/list' then respond(msg['id'], { 'tools' => tools })
  when 'tools/call' then respond(msg['id'], { 'content' => [{ 'type' => 'text', 'text' => 'ok' }] })
  else respond_error(msg['id'], "Method not found: #{msg['method']}")
  end
end

# @param msg [Hash] the request
# @return [void]
def handle_request(msg)
  case MODE
  when 'modern'
    return respond(msg['id'], discover_result(['2026-07-28'])) if msg['method'] == 'server/discover'
  when 'future-only'
    return respond(msg['id'], discover_result(['2099-01-01'])) if msg['method'] == 'server/discover'
  when 'silent-probe'
    # Deliberately no answer: the client must time the probe out and fall back.
    return if msg['method'] == 'server/discover'
  end

  handle_common(msg)
end

# @param line [String] a raw stdin line
# @return [Hash, nil] the parsed message, or nil when it is not JSON
def parse(line)
  JSON.parse(line)
rescue JSON::ParserError
  nil
end

# Emit a startup ping and refuse to process anything else until the client
# answers it. A client that treats its own not-yet-confirmed protocol version
# as the server's era drops the request and deadlocks here.
# @param buffered [Array<String>] lines read while waiting, appended in place
# @return [Boolean] whether the pong arrived
def ping_answered?(buffered)
  emit({ 'jsonrpc' => '2.0', 'id' => 'srv-ping', 'method' => 'ping' })
  while (line = $stdin.gets)
    msg = parse(line)
    next unless msg

    record(msg['method'] || "response:#{msg['id']}")
    return true if msg['id'] == 'srv-ping' && msg.key?('result')

    buffered << msg
  end
  false
end

record("pid #{Process.pid}")

pending = []
if MODE == 'legacy-ping-first'
  first = $stdin.gets
  exit 0 if first.nil?

  msg = parse(first)
  if msg
    record(msg['method'] || "response:#{msg['id']}")
    pending << msg
  end
  exit 0 unless ping_answered?(pending)
end

pending.each { |msg| handle_request(msg) if msg['id'] }

while (line = $stdin.gets)
  msg = parse(line)
  next unless msg

  record(msg['method'] || "response:#{msg['id']}")
  handle_request(msg) if msg['id']
end

# A process that survives its closed stdin makes a leak after a failed probe
# observable: a client that abandons the handles without cleaning up leaves
# this running.
sleep LINGER_SECONDS if MODE == 'future-only'
