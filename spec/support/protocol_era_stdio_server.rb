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
#   modern-one-shot   like modern, but exit as soon as one tools/list has
#                     been answered, so an unexpected termination after a
#                     successful handshake is observable
#   legacy            reject server/discover, then run the initialize handshake
#   legacy-one-shot   like legacy, but exit as soon as one tools/list has
#                     been answered, so a restart of a legacy process has to
#                     run the whole handshake again
#   legacy-broken-init reject server/discover AND initialize, so a failed
#                     legacy handshake against a real process is observable
#   legacy-ping-first like legacy, but send a `ping` request before answering
#                     anything and refuse to process further input until the
#                     response arrives (a legacy server MAY ping at startup;
#                     the receiver MUST respond promptly)
#   legacy-ping-immediate like legacy-ping-first, but the ping goes out at
#                     startup, before the first client message is read, so the
#                     ordering between the client's reader starting and its
#                     probe proposing a version is exercised
#   modern-mute-list  answer server/discover, then never answer tools/list, so
#                     a post-handshake timeout against a live process (and the
#                     cancellation it owes) is observable
#   modern-then-ping  the first process is modern and exits after one
#                     tools/list; its replacement is a 2025-11-25 server that
#                     pings immediately, so a client that judged the
#                     replacement by the dead process's era is observable
#   silent-probe      never answer server/discover; run the handshake instead
#   late-discover     answer server/discover only after a delay longer than
#                     the client's discover timeout, then behave like
#                     legacy-ping-first for the handshake the client fell
#                     back to (a late answer to a cancelled probe identifies
#                     nothing; the 2025-11-25 ping is still owed a response)
#   modern-exit-on-call like modern, but exit as soon as a tools/call arrives,
#                     without answering it, so a call in flight when the
#                     server terminates is observable
#   future-only       advertise a protocol version no client speaks, and keep
#                     running after stdin closes so a leaked process is visible
#
# TRANSCRIPT, when given, receives one line per event: `pid <n>` at startup and
# the method name of every JSON-RPC message received.
#
# Every request is checked against the era it was sent in before it is
# answered: a modern one MUST carry the required `_meta` fields, a 2025-11-25
# one MUST carry none of them. A client that stops putting them on the wire —
# or leaves them on a handshake it fell back to — is refused, so the wire
# itself is pinned rather than only the sequence of method names.
require 'json'

# Per-request protocol fields a modern request MUST carry (MCP 2026-07-28
# basic/index "Per-request protocol fields").
REQUIRED_MODERN_META = %w[
  io.modelcontextprotocol/protocolVersion
  io.modelcontextprotocol/clientCapabilities
].freeze

# Reserved prefix: none of these keys belong on a 2025-11-25 request.
MODERN_META_PREFIX = 'io.modelcontextprotocol/'
# The per-request fields that select the 2026-07-28 era: a 2025-11-25
# request carrying one of these would be read as a modern request.
LEGACY_PROHIBITED_META = %w[
  io.modelcontextprotocol/protocolVersion io.modelcontextprotocol/clientCapabilities
  io.modelcontextprotocol/clientInfo io.modelcontextprotocol/logLevel
].freeze

MODE = ARGV[0] || 'modern'
TRANSCRIPT = ARGV[1]
# How long future-only lingers after stdin closes; the client is expected to
# terminate it long before this elapses.
LINGER_SECONDS = 10
# How long late-discover holds the probe's answer; longer than any discover
# timeout the examples configure.
LATE_DISCOVER_DELAY = 0.6

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
    'capabilities' => { 'tools' => {} }, 'ttlMs' => 60_000, 'cacheScope' => 'public',
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

# server/discover is a modern request whatever the mode — it is how the era is
# probed. Everything else is modern only where the fixture speaks 2026-07-28;
# in the fallback modes the rest of the session is the 2025-11-25 handshake.
# @param msg [Hash] the request
# @return [Boolean]
def modern_request?(msg)
  return true if msg['method'] == 'server/discover'
  return true if MODE == 'modern-mute-list'
  # modern-then-ping speaks 2026-07-28 until it exits; its replacement is a
  # 2025-11-25 server, and the same mode name covers both.
  return !REPLACEMENT if MODE == 'modern-then-ping'

  %w[modern modern-one-shot modern-exit-on-call future-only].include?(MODE)
end

# @param msg [Hash] the request
# @return [String, nil] what is wrong with the request's `_meta`, nil when nothing is
def meta_violation(msg)
  params = msg['params']
  meta = params.is_a?(Hash) ? params['_meta'] : nil
  meta = {} unless meta.is_a?(Hash)
  if modern_request?(msg)
    missing = REQUIRED_MODERN_META.reject { |key| meta.key?(key) }
    return "modern request is missing required _meta: #{missing.join(', ')}" if missing.any?

    # Presence is not enough: the values are typed by the spec, and a
    # client that put `null` where a version or an object belongs has
    # stopped conforming just as surely as one that dropped the key.
    version = meta['io.modelcontextprotocol/protocolVersion']
    unless version.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      return 'modern request _meta protocolVersion is not a YYYY-MM-DD string'
    end
    unless meta['io.modelcontextprotocol/clientCapabilities'].is_a?(Hash)
      return 'modern request _meta clientCapabilities is not an object'
    end
  else
    # Only the era-selecting fields are prohibited: a 2025-11-25 request may
    # legitimately carry other io.modelcontextprotocol/ metadata (the tasks
    # extension's related-task, for one).
    leaked = meta.keys.select { |key| LEGACY_PROHIBITED_META.include?(key.to_s) }
    return "2025-11-25 request carried modern _meta: #{leaked.join(', ')}" if leaked.any?
  end

  nil
end

# @param msg [Hash] the request
# @return [void]
def handle_request(msg)
  # silent-probe never answers the probe, not even to complain about it.
  return if MODE == 'silent-probe' && msg['method'] == 'server/discover'

  if (violation = meta_violation(msg))
    warn("era-fixture: #{msg['method']} #{violation}")
    return respond_error(msg['id'], violation, -32_602)
  end

  handle_common(msg) unless answered_by_mode?(msg)
end

# The answers a mode gives that differ from the common ones.
# @param msg [Hash] the request
# @return [Boolean] whether the mode answered the request itself
def answered_by_mode?(msg)
  case MODE
  when 'modern', 'modern-one-shot', 'modern-exit-on-call', 'future-only' then answered_by_modern_mode?(msg)
  when 'modern-mute-list' then answered_by_modern_mute_list?(msg)
  when 'legacy-one-shot', 'legacy-broken-init', 'late-discover' then answered_by_legacy_mode?(msg)
  when 'modern-then-ping' then answered_by_modern_then_ping?(msg)
  else false
  end
end

# @param msg [Hash] the request
# @return [Boolean] whether the mode answered the request itself
def answered_by_modern_mode?(msg)
  if msg['method'] == 'server/discover'
    respond(msg['id'], discover_result([MODE == 'future-only' ? '2099-01-01' : '2026-07-28']))
    return true
  end

  case MODE
  when 'modern-one-shot'
    return false unless msg['method'] == 'tools/list'

    respond(msg['id'], { 'tools' => tools })
    # Terminate unexpectedly, with the pipes still open on the client side:
    # the client is expected to notice and restart the server rather than
    # keep writing to a dead process.
    exit 0
  when 'modern-exit-on-call'
    # Terminate with the call unanswered: the client must fail it promptly
    # and not replay it on the replacement process.
    exit 0 if msg['method'] == 'tools/call'
  end
  false
end

# modern-mute-list: a live, negotiated modern server that simply never answers
# tools/list, so the client's own request timeout is what ends the wait.
# @param msg [Hash] the request
# @return [Boolean] whether the mode answered the request itself
def answered_by_modern_mute_list?(msg)
  if msg['method'] == 'server/discover'
    respond(msg['id'], discover_result(['2026-07-28']))
    return true
  end

  msg['method'] == 'tools/list'
end

# modern-then-ping: modern until it has served one tools/list, then gone.
# The replacement answers as a 2025-11-25 server (its startup ping is emitted
# before it reads anything, see the REPLACEMENT branch below).
# @param msg [Hash] the request
# @return [Boolean] whether the mode answered the request itself
def answered_by_modern_then_ping?(msg)
  return false if REPLACEMENT

  if msg['method'] == 'server/discover'
    respond(msg['id'], discover_result(['2026-07-28']))
    return true
  end
  return false unless msg['method'] == 'tools/list'

  respond(msg['id'], { 'tools' => tools })
  exit 0
end

# @param msg [Hash] the request
# @return [Boolean] whether the mode answered the request itself
def answered_by_legacy_mode?(msg)
  case MODE
  when 'legacy-one-shot'
    return false unless msg['method'] == 'tools/list'

    respond(msg['id'], { 'tools' => tools })
    exit 0
  when 'legacy-broken-init'
    return false unless msg['method'] == 'initialize'

    respond_error(msg['id'], 'initialize refused', -32_602)
  when 'late-discover'
    return answered_late_discover?(msg)
  end
  true
end

# late-discover: the probe is answered after the client gave up on it, and
# the handshake it fell back to is pinged first.
# @param msg [Hash] the request
# @return [Boolean] whether the request was answered here
def answered_late_discover?(msg)
  case msg['method']
  when 'server/discover'
    sleep LATE_DISCOVER_DELAY
    respond(msg['id'], discover_result(['2026-07-28']))
  when 'initialize'
    answer_initialize_after_ping(msg)
  else
    return false
  end
  true
end

# Ping before answering initialize and wait for the pong (a 2025-11-25
# server MAY ping at startup; the receiver MUST respond promptly), then
# answer the handshake and whatever arrived while waiting.
# @param msg [Hash] the initialize request
# @return [void]
def answer_initialize_after_ping(msg)
  buffered = []
  exit 0 unless ping_answered?(buffered)

  respond(msg['id'], initialize_result)
  buffered.each { |queued| handle_request(queued) if queued['id'] }
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
  # Noted beside the transcript — not in it, which is the record of messages
  # RECEIVED — so a test can hold the client's negotiation until the ping is
  # really on the wire instead of racing it.
  File.write("#{TRANSCRIPT}.events", "ping-sent\n", mode: 'a') if TRANSCRIPT
  while (line = $stdin.gets)
    msg = parse(line)
    next unless msg

    record(msg['method'] || "response:#{msg['id']}")
    return true if msg['id'] == 'srv-ping' && msg.key?('result')

    buffered << msg
  end
  false
end

# Whether an earlier process of this fixture already ran, read before this
# one announces itself: modern-then-ping is the first process's mode and its
# replacement's mode at once, and only the transcript tells them apart.
REPLACEMENT = !TRANSCRIPT.nil? && File.exist?(TRANSCRIPT) &&
              File.read(TRANSCRIPT).lines.any? { |line| line.start_with?('pid ') }

record("pid #{Process.pid}")

pending = []
# The ping goes out before a single byte is read: the client's reader is
# started before its probe proposes a version, and nothing it negotiated with
# a previous process may answer for this one.
if MODE == 'legacy-ping-immediate' || (MODE == 'modern-then-ping' && REPLACEMENT)
  exit 0 unless ping_answered?(pending)
elsif MODE == 'legacy-ping-first'
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
