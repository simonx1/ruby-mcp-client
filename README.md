# ruby-mcp-client

A Ruby client for the Model Context Protocol (MCP), enabling integration with external tools and services via a standardized protocol.

## Installation

```ruby
# Gemfile
gem 'ruby-mcp-client'
```

```bash
bundle install
# or
gem install ruby-mcp-client
```

## Overview

MCP enables AI assistants to discover and invoke external tools via different transport mechanisms:

- **stdio** - Local processes implementing the MCP protocol
- **SSE** - Server-Sent Events with streaming support
- **HTTP** - Simple request/response (non-streaming)
- **Streamable HTTP** - HTTP POST with SSE-formatted responses

Built-in API conversions: `to_openai_tools()`, `to_anthropic_tools()`, `to_google_tools()`

## MCP Protocol Support

Implements the **MCP 2025-11-25** specification. The client negotiates the
protocol version during `initialize` and disconnects if the server answers
with a revision it cannot speak (supported: `2025-11-25`, `2025-06-18`,
`2025-03-26`, `2024-11-05`):

- **Tools**: list, call, streaming, annotations (hint-style), structured outputs, title
- **Prompts**: list, get with parameters
- **Resources**: list, read, templates, subscriptions, pagination, ResourceLink content
- **Elicitation**: Server-initiated user interactions (stdio, SSE, Streamable HTTP)
- **Roots**: Filesystem scope boundaries with change notifications
- **Sampling**: Server-requested LLM completions with modelPreferences
- **Completion**: Autocomplete for prompts/resources with context
- **Logging**: Server log messages with level filtering
- **Tasks**: Task-augmented `tools/call` — create with a `ttl`, poll `tasks/get`, retrieve via `tasks/result`, plus `tasks/list` and `tasks/cancel`
- **Audio**: Audio content type support
- **Progress & Cancellation**: `progressToken` plumbing with per-call callbacks; automatic `notifications/cancelled` for abandoned requests
- **Metadata**: `icons`, `title` and `_meta` parsed on tools, prompts and resources
- **OAuth 2.1**: PKCE (S256 required), RFC 8414/9728 discovery, dynamic registration, Client ID Metadata Documents, scope step-up challenges

Transports treat the server as untrusted input — see
[Treating the Server as Untrusted](#treating-the-server-as-untrusted) for the
limits applied to peer-controlled data.

## Quick Connect API (Recommended)

The simplest way to connect to an MCP server:

```ruby
require 'mcp_client'

# Auto-detect transport from URL
client = MCPClient.connect('http://localhost:8000/sse')      # SSE
client = MCPClient.connect('http://localhost:8931/mcp')      # Streamable HTTP
client = MCPClient.connect('npx -y @modelcontextprotocol/server-filesystem /home')  # stdio

# With options
client = MCPClient.connect('http://api.example.com/mcp',
  headers: { 'Authorization' => 'Bearer TOKEN' },
  read_timeout: 60,
  retries: 3,
  logger: Logger.new($stdout)
)

# Multiple servers
client = MCPClient.connect(['http://server1/mcp', 'http://server2/sse'])

# Force specific transport
client = MCPClient.connect('http://custom.com/api', transport: :streamable_http)

# Use the client
tools = client.list_tools
result = client.call_tool('example_tool', { param: 'value' })
client.cleanup
```

**Configured headers:** `headers:` values are sent on every request, with one
reserved namespace. On a modern (MCP 2026-07-28) HTTP session the client owns
`Mcp-Param-*`: those headers are derived from a `tools/call`'s own arguments
(the tool's `x-mcp-header` annotations), so any header of that name given in
`headers:` is dropped from modern requests rather than standing in for an
argument the call did not carry. Legacy sessions, where the namespace has no
protocol meaning, send it unchanged.

**Transport Detection:**

| URL Pattern | Transport |
|-------------|-----------|
| Ends with `/sse` | SSE |
| Ends with `/mcp` | Streamable HTTP |
| `stdio://command` or Array | stdio |
| `npx`, `node`, `python`, etc. | stdio |
| Other HTTP URLs | Auto-detect (Streamable HTTP → SSE → HTTP) |

## Working with Tools, Prompts & Resources

```ruby
# Tools
tools = client.list_tools
result = client.call_tool('tool_name', { param: 'value' })
result = client.call_tool('tool_name', { param: 'value' }, server: 'server_name')

# Batch tool calls
results = client.call_tools([
  { name: 'tool1', parameters: { key: 'value' } },
  { name: 'tool2', parameters: { key: 'value' }, server: 'specific_server' }
])

# Streaming (SSE/Streamable HTTP)
client.call_tool_streaming('tool', { param: 'value' }).each do |chunk|
  puts chunk
end

# Prompts
prompts = client.list_prompts
result = client.get_prompt('greeting', { name: 'Alice' })

# Pagination: list_tools and list_prompts automatically follow the server's
# nextCursor and return the COMPLETE set across all pages (with a per-call
# safety bound and an identical-cursor loop guard). No manual cursor handling
# is required.

# Resources
result = client.list_resources
contents = client.read_resource('file:///example.txt')
contents.each do |content|
  puts content.text if content.text?
  data = Base64.decode64(content.blob) if content.binary?
end

# Resource update subscriptions (per server)
server = client.servers.first
server.subscribe_resource('file:///example.txt')
server.unsubscribe_resource('file:///example.txt')
```

`subscribe_resource` answers `true` only once the server has confirmed the
subscription, and raises otherwise — the server's own error, or
`MCPClient::Errors::ResourceReadError` (including when the confirmation does
not arrive within the transport's `read_timeout`). On a 2025-11-25 server the
confirmation is the `resources/subscribe` response; on a 2026-07-28 one it is
the `subscriptions/listen` acknowledgment naming that URI, which the call
waits for. Updates then arrive as `notifications/resources/updated` through
`on_notification`. Every later acknowledgment of that stream is rechecked too:
a stream re-opened after a dropped HTTP connection or a stdio restart is a new
listen request the server may acknowledge more narrowly, so one that comes back
without the URI closes the subscription instead of leaving the resource
reported as watched while nothing watches it.

On a 2026-07-28 server a host can also open a stream of its own with
`server.listen(notifications: { tools_list_changed: true }) { |method, params| … }`
and end it with `subscription.close`. The block runs on the subscription's own
dispatcher thread, never on the transport's reader, so a listener may issue
requests of its own; the notifications waiting for it are bounded both in
number (`MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS`) and in the bytes
they retain (`MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES`) — a
count alone is not a memory bound when the peer chooses how big each payload
is. A listener that cannot keep up with the server loses **repeats**, not
signals: whichever ceiling the arriving notification would breach, the queue
gives up the oldest notification about the same thing as it (same method and
same `uri`/`taskId`), or failing that the oldest of whichever thing has the
most queued, so a stream watching several resources or tasks never loses the
only queued update for a quiet one to make room for a busy one. Every MCP
notification is a "look again" signal about state the host re-reads for itself,
so a later notice of the same thing carries what the dropped one said, while
the only notice of another thing carries what nothing else would. A single
notification larger than the whole byte budget is still delivered, alone.
`pending_notifications` / `pending_notification_bytes` /
`dropped_notifications` report how far behind a listener fell. Caches are
dropped *before* a notification reaches the listeners, so a listener reacting
to a `list_changed` notification by calling `list_tools` (or the prompt or
resource equivalents) always re-fetches rather than reading the entry the
notification just invalidated. `active?` answers false while a dropped stream
waits to re-open, and a closing response the client cannot recognize (an unknown
`resultType`, a missing or scalar result) fails the subscription instead of
closing it gracefully. On Streamable HTTP closing the SSE response stream *is*
the cancellation, including against a connection that is still opening its
socket: once `close` (or the transport's `cleanup`) returns, either the listen
request was never sent — that session refuses to send one for a closed
subscription, however long its connect takes — or its response stream has been
closed. On stdio a server process that exits on its own is restarted at once
while subscriptions are open, since a host that is only waiting for
notifications never makes the request that would otherwise restart it, and the
subscriptions are re-sent on the new process; if it cannot be restarted, or if
the restarted process stays up for less than
`MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL` — counted from the
moment it became ready, so a server whose handshake alone takes longer than
that and which then exits is not respawned for ever — they end with that error
rather than waiting for ever.

## MCP 2025-11-25 Features

### Tool Annotations

```ruby
tool = client.find_tool('delete_user')

# Hint-style annotations (MCP 2025-11-25)
# Defaults follow the MCP ToolAnnotations schema: when a hint is absent the
# client assumes the less-safe value, so an un-annotated tool is treated as
# writable, potentially destructive, and open-world.
tool.read_only_hint?      # Defaults to false; tool may modify its environment
tool.destructive_hint?    # Defaults to true; tool may perform destructive updates
tool.idempotent_hint?     # Defaults to false; repeated calls may have additional effects
tool.open_world_hint?     # Defaults to true; tool may interact with external entities

# Legacy annotations
tool.read_only?              # Safe to execute?
tool.destructive?            # Warning: destructive operation
tool.requires_confirmation?  # Needs user confirmation
```

### Structured Outputs

```ruby
tool = client.find_tool('get_weather')
tool.structured_output?  # Has output schema?
tool.output_schema       # JSON Schema for output

result = client.call_tool('get_weather', { location: 'SF' })
data = result['structuredContent']  # Type-safe structured data

# Per MCP 2025-11-25, clients SHOULD validate structured results against the
# tool's output schema, and a tool that declares an outputSchema must return
# structuredContent in successful results. call_tool checks both automatically
# for the common JSON Schema keywords (type, properties, required, items, enum,
# numeric/string bounds). The full 2020-12 vocabulary ($ref/$dynamicRef/$defs,
# allOf/anyOf/oneOf/not, if/then/else, additionalProperties, patternProperties,
# propertyNames, prefixItems, contains/minContains/maxContains, uniqueItems,
# multipleOf, format, dependentRequired/dependentSchemas, minProperties/
# maxProperties, unevaluated*) is NOT evaluated: when a schema uses any of
# those keywords, call_tool logs a "validation is partial" warning naming them
# (in both modes), since data may pass this check that a full validator would
# reject. By default a violation (mismatch, or missing structuredContent on a
# successful result) logs a warning; opt in to strict mode to raise instead:
client = MCPClient::Client.new(
  mcp_server_configs: [...],
  validate_structured_content: :strict # raises MCPClient::Errors::ValidationError on violation
)
# Task-delivered results (get_task_result) are not validated yet.
```

A result is checked against the tool definition the request that produced it
went out under. That matters on a modern HTTP session, where a `HeaderMismatch`
rejection makes the client refresh `tools/list` and retry with recomputed
`Mcp-Param-*` headers: the retry is answered under the refreshed definition, so
that is the one it is validated against. A `tools/list_changed` that merely
arrives while the call is in flight never changes the definition the result is
checked against — the server never saw the replacement.

### Roots

```ruby
# Set filesystem scope boundaries
client.roots = [
  { uri: 'file:///home/user/project', name: 'Project' },
  { uri: 'file:///var/log', name: 'Logs' }
]

# Access current roots
client.roots
```

### Sampling (Server-requested LLM completions)

```ruby
# Configure handler when creating client
client = MCPClient.connect('http://server/mcp',
  sampling_handler: ->(messages, model_prefs, system_prompt, max_tokens) {
    # Process server's LLM request
    {
      'model' => 'gpt-4',
      'stopReason' => 'endTurn',
      'role' => 'assistant',
      'content' => { 'type' => 'text', 'text' => 'Response here' }
    }
  }
)
```

Sampling tool calling (SEP-1577) is opt-in: pass `sampling_supports_tools: true`
to declare the `sampling.tools` capability. The handler then receives the full
request params (including `tools`/`toolChoice`) as an optional fifth argument;
without the opt-in, tool-enabled sampling requests are rejected with `-32602`
as the spec requires. On a 2026-07-28 server, where sampling arrives as an
input request inside a multi round-trip answer and `inputResponses` has no
per-request error channel, the same rejection fails the whole round trip with
`MCPClient::Errors::InputRequiredError` and the handler is never invoked:

```ruby
client = MCPClient::Client.new(
  mcp_server_configs: [...],
  sampling_supports_tools: true,
  sampling_handler: ->(messages, prefs, system_prompt, max_tokens, params = nil) {
    tools = params && params['tools'] # ToolUseContent may be returned in content
    # ...
  }
)
```

### Progress Tracking

Attach a per-call progress callback — the client generates a unique
`progressToken`, places it in the request `_meta`, and routes matching
`notifications/progress` to your block while the request is active (stale
tokens after completion are dropped):

```ruby
client.call_tool('long_running', args, progress: ->(progress, total, message) {
  puts "#{message}: #{progress}/#{total}"
})
```

A request-level `_meta` (e.g. a hand-picked `progressToken`) can also be passed
inside the arguments under the `'_meta'` key on every transport — it is hoisted
to the JSON-RPC params level on the wire, never sent as a tool argument.

### Timeouts and Cancellation

Timeouts are configurable per request in addition to the per-server
`read_timeout`. A timed-out request raises
`MCPClient::Errors::RequestTimeoutError` (a `TransportError` subclass), is
**never** silently re-sent by the retry layer, and a best-effort
`notifications/cancelled` is sent for the abandoned request (never for
`initialize`, and task-augmented calls use `tasks/cancel` instead):

```ruby
client.send_rpc('tools/call', params: { name: 'slow', arguments: {} }, timeout: 300)
server.rpc_request('tools/list', {}, timeout: 5)
```

### Client Identity and Server Instructions

Hosts can present their own `Implementation` info (sent as `clientInfo` during
initialize; `name` and `version` required — `title`, `description`,
`websiteUrl`, `icons` optional), and read the server's `instructions` hint
after connecting:

```ruby
client = MCPClient::Client.new(
  mcp_server_configs: [...],
  client_info: { 'name' => 'my-ide', 'version' => '2.0.0', 'description' => 'An MCP-powered IDE' }
)
client.servers.first.connect
puts client.servers.first.instructions # e.g. "Use the search tool before answering."
```

### Capability Gating

Optional server features (`logging/setLevel`, `resources/subscribe`,
`completion/complete`, `tasks/list`, `tasks/cancel`) are only sent to servers
that negotiated the corresponding capability; otherwise
`MCPClient::Errors::CapabilityError` is raised (the lifecycle forbids using
capabilities that were not negotiated). `Client#log_level=` skips
non-logging servers instead of failing. Declared *client* capabilities are
derived from what the host actually registered (handlers, roots), never
hardcoded — and they gate the client's own traffic too:
`notifications/roots/list_changed` goes only to a session that declared
`roots` (never to a 2026-07-28 server, which removed the notification, and
never to plain HTTP on a legacy session, which has no server-request channel
to serve roots on).

### Completion (Autocomplete)

```ruby
result = client.complete(
  ref: { type: 'ref/prompt', name: 'greeting' },
  argument: { name: 'name', value: 'A' }
)
# => { 'values' => ['Alice', 'Alex'], 'total' => 100, 'hasMore' => true }
```

### Logging

```ruby
# Set log level
client.log_level = 'debug'  # debug/info/notice/warning/error/critical

# Handle log notifications
client.on_notification do |server, method, params|
  if method == 'notifications/message'
    puts "[#{params['level']}] #{params['logger']}: #{params['data']}"
  end
end
```

### Tasks (Long-running, task-augmented tools)

A task-capable server (one advertising `tasks.requests.tools.call`) can run a tool
whose `execution.taskSupport` is `optional` or `required` as a background task:
the call returns immediately with a task handle, and the result is fetched later.
Try it locally: `python3 examples/echo_server_streamable.py &` then
`./examples/tasks_example.rb` runs the full lifecycle against a task-capable
demo server.

```ruby
tool = client.find_tool('long_job')
tool.supports_task?   # execution.taskSupport is optional/required?

# Create the task (returns immediately); ttl is the requested lifetime in ms
task = client.call_tool_as_task('long_job', { input: 'data' }, ttl: 60_000)

# Poll until the task reaches a terminal (or input-required) status,
# honoring the server's suggested poll interval
until task.terminal? || task.input_required?
  sleep((task.poll_interval || 1000) / 1000.0)
  task = client.get_task(task)          # tasks/get, routed to the task's own server
end

# Retrieve the underlying result (e.g. a CallToolResult) via tasks/result
result = client.get_task_result(task)

# List and cancel tasks
page = client.list_tasks               # { tasks: [...], next_cursor: ... }
client.cancel_task(task)               # tasks/cancel
```

Task IDs are only unique within the server that issued them, so pass the `Task`
returned by `call_tool_as_task` — it carries its own server. A bare task ID also
works when the client has a single server; with several servers configured it
raises `ArgumentError` rather than guessing, so name the server explicitly:

```ruby
client.get_task('task-123', server: 'my-server')

# React to server-pushed status updates
client.on_notification do |server, method, params|
  puts "Task #{params['taskId']} -> #{params['status']}" if method == 'notifications/tasks/status'
end
```

### Elicitation (Server-initiated user interactions)

```ruby
client = MCPClient::Client.new(
  mcp_server_configs: [MCPClient.stdio_config(command: 'python server.py')],
  elicitation_handler: ->(message, schema) {
    puts "Server asks: #{message}"
    # Return: { 'action' => 'accept', 'content' => { 'field' => 'value' } }
    # Or: { 'action' => 'decline' } or { 'action' => 'cancel' }
  }
)
```

In URL mode the handler's second argument is
`{ 'mode' => 'url', 'url' => ..., 'elicitationId' => ... }` and its answer is
consent, not data: only an explicit `action` of `accept`, `decline` or `cancel`
(or a literal `true` for accept) counts — anything else is answered `cancel`.
`content` is dropped, since it is form-mode only, while a handler-supplied
`_meta` is passed through.

## Advanced Configuration

For more control, use `create_client` with explicit configs:

```ruby
client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.stdio_config(command: 'npx server', name: 'local'),
    MCPClient.sse_config(
      base_url: 'https://api.example.com/sse',
      headers: { 'Authorization' => 'Bearer TOKEN' },
      read_timeout: 30, ping: 10, retries: 3
    ),
    MCPClient.http_config(
      base_url: 'https://api.example.com',
      endpoint: '/rpc',
      headers: { 'Authorization' => 'Bearer TOKEN' }
    ),
    MCPClient.streamable_http_config(
      base_url: 'https://api.example.com/mcp',
      read_timeout: 60, retries: 3
    )
  ],
  logger: Logger.new($stdout)
)

# Or load from JSON file
client = MCPClient.create_client(server_definition_file: 'servers.json')
```

### Retries

The `retries:` option controls automatic retry with exponential backoff. Only
failures where the request most likely did **not** complete at the server are
retried: transport/network errors and HTTP **5xx** responses. Application-level
failures — a JSON-RPC error response or an HTTP **4xx** — are **never** retried,
because the server already processed or rejected the request. Retryable server
failures raise `MCPClient::Errors::TransientServerError`, a subclass of
`MCPClient::Errors::ServerError`, so existing `rescue ServerError` handlers are
unaffected.

**`tools/call` is never retried automatically.** Even a "transient" failure can
arrive *after* the server executed the request, and JSON-RPC has no idempotency
key that would make a replay safe — so a retry could run a side effect twice.
Retry a tool call explicitly if your application knows it is safe to repeat, and
treat the raised error as *outcome unknown* rather than *not executed*:

```ruby
begin
  client.call_tool('send_invoice', { customer: 'acme' })
rescue MCPClient::Errors::TransportError => e
  # The server may or may not have sent the invoice. Check before retrying.
end
```

The same reasoning excludes `RequestTimeoutError` and `ResponseTooLargeError`
from retries, and applies to session recovery: if a `tools/call` comes back with
an expired-session 404, the client starts a fresh session but does **not** re-send
the call — it raises so you can decide. Idempotent requests are re-sent against
the new session as before.

**One exception: a broken response stream on a modern (MCP 2026-07-28)
Streamable HTTP connection.** That revision removed SSE resumability and requires
that a broken response stream loses the in-flight request, which clients **MUST**
re-issue as a new request with a new request ID — with no exception for
`tools/call`. It can require that safely because closing the response stream *is*
the cancellation signal: the server **MUST** treat the break as a cancellation of
that request, stop work as soon as practical, and send nothing further for it. So
when a modern response stream ends without the result, the client sends the call
again once with a fresh request id; if that stream breaks too, it raises
`MCPClient::Errors::ResponseStreamClosedError` rather than trying again. Every
other ambiguous failure is unchanged and still never re-sent, because in none of
those cases was the server told to stop.

### Response Size Limits (Streamable HTTP)

A gzip-encoded response is decompressed incrementally and abandoned once it
expands past `max_decompressed_body_bytes` (default **64 MiB**), so a small
highly-compressed body cannot exhaust memory. Exceeding it raises
`MCPClient::Errors::ResponseTooLargeError`.

Raise the limit if you legitimately exchange very large payloads — base64
resource blobs or audio — so that whether a response is accepted does not depend
on the server's choice to compress it:

```ruby
MCPClient.streamable_http_config(
  base_url: 'https://api.example.com/mcp',
  max_decompressed_body_bytes: 256 * 1024 * 1024
)
```

### Faraday Customization

```ruby
MCPClient.http_config(base_url: 'https://internal.company.com') do |faraday|
  faraday.ssl.cert_store = custom_cert_store
  faraday.ssl.verify = true
end
```

Response middleware you add here is respected on the error path: if a
`conn.response :json` middleware (with or without `conn.response :raise_error`)
has already decoded an HTTP 4xx body, the JSON-RPC error it carries is still
recognized, so a protocol rejection keeps its `code`, `data` and typed error
class instead of degrading to a bare `ServerError`.

### Server Definition JSON

```json
{
  "mcpServers": {
    "filesystem": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home"]
    },
    "api": {
      "type": "streamable_http",
      "url": "https://api.example.com/mcp",
      "headers": { "Authorization": "Bearer TOKEN" }
    }
  }
}
```

## AI Integration Examples

### OpenAI

```ruby
require 'mcp_client'
require 'openai'

mcp = MCPClient.connect('npx -y @modelcontextprotocol/server-filesystem .')
tools = mcp.to_openai_tools

client = OpenAI::Client.new(api_key: ENV['OPENAI_API_KEY'])
response = client.chat.completions.create(
  model: 'gpt-4',
  messages: [{ role: 'user', content: 'List files' }],
  tools: tools
)
```

### Anthropic

```ruby
require 'mcp_client'
require 'anthropic'

mcp = MCPClient.connect('npx -y @modelcontextprotocol/server-filesystem .')
tools = mcp.to_anthropic_tools

client = Anthropic::Client.new(access_token: ENV['ANTHROPIC_API_KEY'])
# Use tools with Claude API
```

### RubyLLM

```ruby
require 'mcp_client'
require 'ruby_llm'

RubyLLM.configure { |c| c.openai_api_key = ENV['OPENAI_API_KEY'] }
mcp = MCPClient.connect('http://localhost:8931/mcp')  # Playwright MCP

# Wrap each MCP tool as a RubyLLM tool
tools = mcp.list_tools.map do |t|
  tool_name = t.name
  Class.new(RubyLLM::Tool) do
    description t.description
    params t.schema
    define_method(:name) { tool_name }
    define_method(:execute) { |**args| mcp.call_tool(tool_name, args) }
  end.new
end

chat = RubyLLM.chat(model: 'gpt-4o-mini')
tools.each { |tool| chat.with_tool(tool) }
response = chat.ask('Navigate to google.com and tell me the page title')
```

See `examples/` for complete implementations:
- `ruby_openai_mcp.rb`, `openai_ruby_mcp.rb` - OpenAI integration
- `ruby_anthropic_mcp.rb` - Anthropic integration
- `gemini_ai_mcp.rb` - Google Vertex AI integration
- `ruby_llm_mcp.rb` - RubyLLM integration (OpenAI provider)

## Running the Examples

The `examples/run_all_examples.sh` harness runs every example that can run on the current machine — self-contained stdio servers, the Python/Flask/FastMCP echo and elicitation servers, `npx`-based MCP servers, and (optionally) the paid LLM integrations. It starts and tears down each server automatically and prints a `PASS`/`FAIL`/`SKIP` summary. `tasks_example.rb` is always skipped (it needs a task-capable remote server); `oauth_browser_auth.rb` is interactive and only runs when you opt in with `RUN_OAUTH=1`.

### Prerequisites

Run `bundle install` first. The script preflight-checks the following and prints a warning (it does **not** abort) for anything missing; affected examples are then skipped or fail:

- `ruby`, `bundle`, `curl`, `lsof` - on `PATH`
- `python3` (or `$PYTHON`) plus a separate `python` binary - on `PATH`
- Python packages `flask`, `fastmcp`, `mcp` - importable by `$PYTHON`
- `npx` (Node) - needed by the `npx`-based example (`json_input`) and by every LLM example, which spawn `npx` filesystem/Playwright servers

### Usage

```bash
examples/run_all_examples.sh                       # run everything runnable on this machine
RUN_AI=0 examples/run_all_examples.sh              # skip the paid-LLM examples
RUN_NPX=0 examples/run_all_examples.sh             # skip the npx-based example (json_input)
LOG_DIR=/path examples/run_all_examples.sh         # write logs to a chosen dir
PYTHON=python3.12 TIMEOUT=180 examples/run_all_examples.sh  # override interpreter and per-example timeout
```

### Environment Knobs

| Variable | Default | Effect |
|----------|---------|--------|
| `RUN_AI` | `1` | Set to `0` to skip the LLM integrations, which make **real, paid** API calls. |
| `RUN_NPX` | `1` | Set to `0` (or leave `npx` off `PATH`) to skip the `npx`-based example (`json_input`). The LLM examples spawn `npx` servers too, but are gated by `RUN_AI` and their API keys instead. |
| `PYTHON` | `python3` | Interpreter used to launch the Python/Flask/FastMCP servers and run the import preflight checks. |
| `TIMEOUT` | `120` | Per-example wall-clock timeout in seconds; a timeout is reported as a `FAIL`. |
| `LOG_DIR` | fresh `mktemp` dir | Directory for per-example and per-server logs; the path is printed after preflight and in the summary. |

### Secrets and API Keys

Real secrets live in `examples/secrets.env`, which is **gitignored** and sourced automatically (every `KEY=value` line is exported) when present. Copy the tracked template to get started:

```bash
cp examples/secrets.env.example examples/secrets.env
# then set ZAPIER_MCP_TOKEN=... to enable the Zapier streamable-HTTP example
```

Set `ZAPIER_MCP_TOKEN` (from the Zapier MCP setup page, "Option 1: Authorization header") to run `streamable_http_example.rb` and `oauth_example.rb` against Zapier; override `ZAPIER_MCP_URL` if your connect URL differs. To run the interactive `oauth_browser_auth.rb`, set `MCP_SERVER_URL` (e.g. an ngrok tunnel to your OAuth-protected MCP server) in `secrets.env` and pass `RUN_OAUTH=1`. The LLM examples each need their own credentials in the environment and are skipped without them:

- `ruby_anthropic_mcp.rb` - `ANTHROPIC_API_KEY` (+ `npx`)
- `openai_ruby_mcp.rb` - `OPENAI_API_KEY` (+ `npx`)
- `ruby_openai_mcp.rb`, `ruby_llm_mcp.rb` - `OPENAI_API_KEY` (+ `npx`, plus a Playwright MCP server on `:8931`)
- `gemini_ai_mcp.rb` - a Vertex service-account JSON at `VERTEX_CREDENTIALS_FILE` (default `examples/google-credentials.json`, + `npx`)

### How Pass/Fail Is Judged

Most examples print their own success/failure marks but exit `0` regardless, so the harness combines the exit code with a scan of the output rather than trusting the exit status alone. An example `FAIL`s when it exits nonzero, times out (exit `124`), prints a hard-error signature (a Ruby/Python traceback, `Connection refused`, `uninitialized constant`, and similar), prints a `❌` mark, or is missing its expected success marker; otherwise it `PASS`es. (The `❌` check is suppressed with `IGNORE_XMARK=1` for the interactive elicitation demos, where `❌` can be legitimate "declined" output.) The script exits `0` only if zero examples failed — `SKIP`s do not affect the exit status.

For deeper, per-topic walkthroughs see [`examples/README.md`](examples/README.md), [`examples/README_ECHO_SERVER.md`](examples/README_ECHO_SERVER.md), [`examples/STREAMABLE_HTTP_TESTING.md`](examples/STREAMABLE_HTTP_TESTING.md), and [`examples/elicitation/README.md`](examples/elicitation/README.md).

## OAuth 2.1 Authentication

```ruby
require 'mcp_client'
require 'mcp_client/auth/browser_oauth'

oauth = MCPClient::Auth::OAuthProvider.new(
  server_url: 'https://api.example.com/mcp',
  redirect_uri: 'http://localhost:8080/callback',
  scope: 'mcp:read mcp:write'
)

browser_oauth = MCPClient::Auth::BrowserOAuth.new(oauth)
token = browser_oauth.authenticate  # Opens browser, handles callback

client = MCPClient::Client.new(
  mcp_server_configs: [{
    type: 'streamable_http',
    base_url: 'https://api.example.com/mcp',
    oauth_provider: oauth
  }]
)
```

Features: PKCE, server discovery (`.well-known`), dynamic registration, token refresh.

See [OAUTH.md](OAUTH.md) for full documentation.

### OAuth Extras (2025-11-25)

- **Client ID Metadata Documents (SEP-991)** — pass
  `client_id_metadata_url: 'https://myapp.example/oauth-client.json'` (an HTTPS
  URL with a path, which doubles as the `client_id`); when the authorization
  server advertises `client_id_metadata_document_supported`, dynamic client
  registration is skipped entirely.
- **Scope challenges (SEP-835)** — an HTTP 403 `insufficient_scope` challenge
  raises `MCPClient::Errors::InsufficientScopeError` (a `ConnectionError`
  subclass) exposing `#scope` and `#error_description`; the challenged scopes
  are treated as authoritative for the next authorization flow.
- **PKCE** — authorization refuses to proceed when the authorization server
  does not advertise `code_challenge_methods_supported` including `S256`.

## Server Notifications

```ruby
client.on_notification do |server, method, params|
  case method
  when 'notifications/tools/list_changed'
    client.clear_cache  # Auto-handled
  when 'notifications/message'
    puts "Log: #{params['data']}"
  when 'notifications/roots/list_changed'
    puts "Roots changed"
  end
end
```

## Session Management

Both HTTP and Streamable HTTP transports automatically handle session-based servers:

- **Session capture**: Extracts `Mcp-Session-Id` from initialize response
- **Session persistence**: Includes session header in subsequent requests
- **Session termination**: Sends DELETE request during cleanup
- **Resumability** (Streamable HTTP, SEP-1699): tracks SSE event IDs and, when a
  response stream is interrupted, resumes via GET with `Last-Event-ID` so the
  server can replay missed messages — honoring the server's `retry:` directive

No configuration required - works automatically.

## Server Compatibility

Works with any MCP-compatible server:

- [@modelcontextprotocol/server-filesystem](https://www.npmjs.com/package/@modelcontextprotocol/server-filesystem)
- [@playwright/mcp](https://www.npmjs.com/package/@playwright/mcp)
- [FastMCP](https://github.com/jlowin/fastmcp)
- Custom servers implementing MCP protocol

### FastMCP Example

```bash
# Start server
python examples/echo_server_streamable.py
```

```ruby
# Connect and use
client = MCPClient.connect('http://localhost:8931/mcp')
tools = client.list_tools
result = client.call_tool('echo', { message: 'Hello!' })
```

## Treating the Server as Untrusted

A connected MCP server controls everything it sends you, and the transports are
written on that assumption. You do not need to configure any of this — it is the
default behaviour — but it is worth knowing what the client will refuse:

| Peer-controlled input | What the client does |
|---|---|
| Compressed response bodies (**Streamable HTTP only** — the only transport that requests gzip) | Decompressed incrementally, abandoned past `max_decompressed_body_bytes` (64 MiB default) |
| SSE streams | Per-connection buffer cap; events scanned incrementally, so an unterminated event costs bounded memory *and* CPU |
| `retry:` directives | Honored, but floored so `retry: 0` cannot drive a reconnect loop |
| SSE event IDs | Bounded length, printable ASCII only (they are echoed in `Last-Event-ID`) |
| Legacy SSE `endpoint` events | Must stay on the connection's origin; off-origin redirects are refused, so configured credential headers never reach another host |
| OAuth discovery URLs from a peer | Must be HTTPS, and rejected when the host is a *literal* loopback/private/link-local address (unless the configured server is itself local); a refused challenge fails closed. Hostnames are not resolved, so a public name pointing at a private address is not caught — see the note below |
| Unsolicited JSON-RPC responses | Discarded — only IDs with an outstanding request are accepted |
| Server-initiated requests | Replies are bounded by a concurrency budget rather than spawning unbounded threads |
| Schema `pattern` values | Matched under a whole-operation time budget; a timeout fails validation rather than silently passing |
| Log messages (`notifications/message`) | Control characters escaped and length-capped, so a server cannot forge log lines |

**Known limit:** the OAuth check is textual. A peer can still advertise a public
hostname whose DNS record points inside your network; catching that needs
resolution-time filtering in the HTTP layer, which this gem does not do. If you
run in an environment where that matters, restrict egress at the network layer.

Two related defaults worth calling out because they affect *your* data rather
than the peer's:

- **Payloads are never written to logs.** At DEBUG the client logs a method/id
  summary and a byte count, not request params, response bodies or raw SSE
  chunks. Server configurations are logged with credential-bearing keys redacted.
- **Host exceptions are not reflected to the server.** A raising elicitation,
  sampling or roots handler yields a constant JSON-RPC error message; the detail
  stays in your local log.

## Requirements

- Ruby >= 3.3.0
- Runtime dependencies: `faraday` (~> 2.0) with `faraday-follow_redirects` and
  `faraday-retry`, plus `base64` — all pulled in automatically by the gem

Development uses Ruby 4.0.6 (see `.ruby-version`). CI runs the suite on 4.0.6
plus the supported floor, 3.3.

## License

Available as open source under the [MIT License](LICENSE).

## Contributing

Bug reports and pull requests welcome at https://github.com/simonx1/ruby-mcp-client.
