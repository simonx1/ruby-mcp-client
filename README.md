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
- **SSE** *(deprecated)* - Server-Sent Events with streaming support; the HTTP+SSE transport is deprecated and new integrations should use **Streamable HTTP** instead (see [Deprecated features](#deprecated-features))
- **HTTP** - Simple request/response (non-streaming)
- **Streamable HTTP** - HTTP POST with SSE-formatted responses

Built-in API conversions: `to_openai_tools()`, `to_anthropic_tools()`, `to_google_tools()`

## MCP Protocol Support

Implements the **MCP 2026-07-28** specification and stays compatible with
every earlier revision (`2025-11-25`, `2025-06-18`, `2025-03-26`,
`2024-11-05`). The client is dual-era: it probes each server with
`server/discover` and talks the stateless 2026-07-28 protocol (per-request
`_meta`, no `initialize`, no sessions) to servers that answer it, and runs
the classic `initialize` handshake with everyone else — disconnecting if a
server answers with a revision it cannot speak. See
[MCP 2026-07-28 Features](#mcp-2026-07-28-features) for the new
capabilities and [Deprecated features](#deprecated-features) for what the
revision retires.

- **Tools**: list, call, streaming, annotations (hint-style), structured outputs validated against `outputSchema` (JSON Schema 2020-12 / 2019-09 / draft-07), title, `x-mcp-header` parameters
- **Prompts**: list, get with parameters
- **Resources**: list, read, templates, subscriptions, pagination, ResourceLink content
- **Elicitation**: Server-initiated user interactions (stdio, SSE, Streamable HTTP) and multi round-trip `input_required` results
- **Roots** *(deprecated in 2026-07-28)*: Filesystem scope boundaries with change notifications
- **Sampling** *(deprecated in 2026-07-28)*: Server-requested LLM completions with modelPreferences
- **Completion**: Autocomplete for prompts/resources with context
- **Logging** *(deprecated in 2026-07-28)*: Server log messages with level filtering
- **Tasks**: Task-augmented `tools/call` on 2025-11-25 servers and the `io.modelcontextprotocol/tasks` extension on 2026-07-28 servers
- **Subscriptions**: `subscriptions/listen` notification streams (2026-07-28)
- **Caching**: `ttlMs` / `cacheScope` freshness hints on lists, reads and discovery (2026-07-28)
- **Audio**: Audio content type support
- **Progress & Cancellation**: `progressToken` plumbing with per-call callbacks; automatic `notifications/cancelled` for abandoned requests
- **Metadata**: `icons`, `title` and `_meta` parsed on tools, prompts and resources
- **OAuth 2.1**: PKCE (S256 required), RFC 8414/9728 discovery, RFC 9207 issuer validation, Client ID Metadata Documents, dynamic registration *(deprecated)*, scope step-up challenges

Transports treat the server as untrusted input — see
[Treating the Server as Untrusted](#treating-the-server-as-untrusted) for the
limits applied to peer-controlled data.

## Quick Connect API (Recommended)

The simplest way to connect to an MCP server:

```ruby
require 'mcp_client'

# Auto-detect transport from URL
client = MCPClient.connect('http://localhost:8931/mcp')      # Streamable HTTP
client = MCPClient.connect('npx -y @modelcontextprotocol/server-filesystem /home')  # stdio
client = MCPClient.connect('http://localhost:8000/sse')      # SSE (HTTP+SSE: deprecated, use Streamable HTTP)

# With options
client = MCPClient.connect('http://api.example.com/mcp',
  headers: { 'Authorization' => 'Bearer TOKEN' },
  read_timeout: 60,
  retries: 3,
  logger: Logger.new($stdout)
)

# Multiple servers
client = MCPClient.connect(['http://server1/mcp', 'http://server2/mcp'])

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
| Ends with `/sse` | SSE — HTTP+SSE is *deprecated*, prefer Streamable HTTP ([Deprecated features](#deprecated-features)) |
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
reported as watched while nothing watches it — including one that arrives in
the window between the acknowledgment `subscribe_resource` waited for and the
URI being mapped to the stream, which is checked once more with the mapping in
place before the call answers. A stream already mapped to the URI is reused
only while the server is honouring that URI on it *now*: one that has dropped
is waited for — through the HTTP re-open backoff or the stdio handshake, and
on past the replacement request until the server answers it — rather than
reported as a watch on the strength of what the stream that is gone had been
granted, because no server-side subscription exists between listen attempts
and the request that replaces one is a new listen the server holds no state
for and may reject or acknowledge without the URI. Only a stream the server is
actively honouring counts as a live watch, and one that does not become
one — its replacement is refused, or nothing answers within the
acknowledgment timeout — is closed as well as unmapped, so it cannot come back
and deliver the same updates beside the stream that replaces it, and
`unsubscribe_resource` is never left looking for a subscription the mapping no
longer names. The subscriber waiting on its own
listen request is a different matter and still gets its answer: a connection
that drops the moment the acknowledgment arrives does not unanswer it, so the
call does not wait out its acknowledgment timeout for a grant it already
has — while a replacement request that has actually gone out is unanswered
until the server answers *it*.

On a 2026-07-28 server a host can also open a stream of its own with
`server.listen(notifications: { tools_list_changed: true }) { |method, params| … }`
and end it with `subscription.close`. A listen the server never acknowledges is
given up on rather than left pending for ever: `ack_timeout:` bounds the wait
for the acknowledgment (the transport's read timeout by default, `false` to
wait for ever), and one that expires cancels the request and closes the handle
with a `RequestTimeoutError`. The stream itself is not bounded — once
acknowledged it runs for as long as the server keeps it. The block runs on the
subscription's own dispatcher thread, never on the transport's reader, so a
listener may issue requests of its own; the notifications waiting for it are bounded both in
number (`MCPClient::Subscription::MAX_PENDING_NOTIFICATIONS`) and in the bytes
they retain (`MCPClient::Subscription::MAX_PENDING_NOTIFICATION_BYTES`) — a
count alone is not a memory bound when the peer chooses how big each payload
is. Everything a queued notification retains is charged, its method name as
well as its params: a peer tagging `{}` params with a multi-megabyte method
name would otherwise pay two bytes apiece and put a thousand of them behind a
slow listener without touching the byte ceiling. A listener that cannot keep
up with the server loses **repeats**, not signals: whichever ceiling the
arriving notification would breach, the queue gives up the oldest notification
about the same thing as it (same method and
same `uri`/`taskId`), or failing that the oldest of whichever thing has the
most queued, so a stream watching several resources or tasks never loses the
only queued update for a quiet one to make room for a busy one. Every MCP
notification is a "look again" signal about state the host re-reads for itself,
so a later notice of the same thing carries what the dropped one said, while
the only notice of another thing carries what nothing else would. Two rules hold
this together: every queued notification is charged exactly what it retains,
and every eviction gives up an entry whose removal relieves the pressure that
caused it — the byte budget considers only the entries charged against it, the
count ceiling considers them all — so overflow always makes progress and no
signal is spent on pressure that discarding it cannot relieve. A notification
larger than the whole byte budget is not charged against it: it is held in a
slot of its own, and there is only ever one such slot, so it is neither lost
for being large nor able to displace anything else, and what the queue retains
stays within the budget plus one peer-sized payload.
`pending_notifications` / `pending_notification_bytes` /
`dropped_notifications` report how far behind a listener fell. An incoming
notification is routed in a fixed order: subscription bookkeeping (an
acknowledgment, a server-side teardown) first, then the transport and client
cache invalidation, then the delivery to the subscription's listeners, and the
host's `on_notification` listeners **last**. Caches are therefore dropped
*before* a notification reaches the listeners, so a listener reacting to a
`list_changed` notification by calling `list_tools` (or the prompt or resource
equivalents) always re-fetches rather than reading the entry the notification
just invalidated. That holds for the client's caches as well as the
transport's: the client drops its `tool_cache` / `prompt_cache` /
`resource_cache` on the transport's `on_cache_invalidation` hook, which runs at
the invalidation step, rather than on the host callback that runs after the
delivery. A custom transport that emits no such hook — one written against the
older interface, which only calls the notification callback — still has those
caches dropped, on the callback and ahead of everything else there. Everything else the client does with a notification (logging,
progress callbacks, task status) stays behind the delivery, because it is host
code or leads to it. Transports that carry no subscription stream announce the
same hook before their notification callback — the legacy SSE parser, and the
synthetic `tools/list_changed` a `Mcp-Param-*` header-mismatch refresh emits —
so nothing that invalidates a cache is announced on only one of the two.
The host callback comes last because it is the only step
that can block: it is host code and it runs on whatever thread is routing — on
stdio the server process's sole reader — so a callback that issues a
synchronous request of its own would otherwise hold up the delivery while
waiting for a response only that reader can deliver. Queueing the delivery is
all the routing thread does (the listeners themselves run on the
subscription's dispatcher thread), so nothing host-supplied runs ahead of the
callback either way. Being last, the callback can prevent nothing: one that
raises is logged and stops neither the invalidation nor the delivery, and one
that edits the payload it is handed can neither drop nor redirect it — the
subscription a notification belongs to is resolved, and the delivery queued,
before the callback sees it. The requested
filter is copied and frozen when the subscription is created, so a caller that
keeps and mutates the array it passed cannot change the request that goes out
(Streamable HTTP builds it on the stream's own thread) or what a reconnect asks
for. `unsupported` names the requested fields the acknowledgment did not really
grant, read from its values rather than its keys: a `resourceSubscriptions`
echoed with none of the requested URIs, or a flag acknowledged as `false`,
counts as unsupported. `acknowledged` is a frozen copy of what the server
granted, arrays and strings included: the notification it arrives in is handed
to `on_notification` and to the subscription's listeners, and host code editing
it in place must not be able to rewrite the subscription's own record of the
watch. `active?` answers false while a dropped stream
waits to re-open, and a closing response the client cannot recognize (an unknown
`resultType`, a missing or scalar result) fails the subscription instead of
closing it gracefully — as does one that is recognized but says the request has
not finished (`input_required`, which is valid on `tools/call`,
`resources/read` and `prompts/get` alone). On Streamable HTTP closing the SSE response stream *is*
the cancellation, including against a connection that is still opening its
socket: once `close` (or the transport's `cleanup`) returns, either the listen
request was never sent — that session refuses to send one for a closed
subscription, however long its connect takes — or its response stream has been
closed. A listen POST the server answers with a 5xx is treated as a dropped
stream and re-opened on the usual backoff, the way a connection failure or a
read timeout on the very same request is: a brief 500 or 503 no longer ends a
long-lived subscription for good. Only a 4xx, or an authorization challenge,
is the server refusing this subscription, and those still end it.
On stdio a server process that exits on its own is restarted at once
while subscriptions are open, since a host that is only waiting for
notifications never makes the request that would otherwise restart it, and the
subscriptions are re-sent on the new process. An exit *during* the
initialization that established the process counts too: a replacement that
answers the discovery probe and then dies is noticed by its own reader, which
waits out the initialization still in flight and then restarts — otherwise
nothing noticed, the dead connection was marked initialized, the re-sent
listens failed into the "wait for the next process" path, and no reader was
left to establish one. If the process cannot be restarted, or if
the process they were last re-sent to died less than
`MCPClient::ServerStdio::SUBSCRIPTION_RESTART_MIN_INTERVAL` after receiving
them, they end with that error rather than waiting for ever. Only an exit
counts against that bound, never a teardown the client asked for: a host that
calls `cleanup` and reconnects — which every `cleanup`/request cycle does —
tears the process down whenever it likes, and reading that as a crash closed
the very subscriptions the reconnect exists to carry across. The record of
that process answers only that one question, and asking it spends it: a
subscription opened directly on the replacement, after a refusal had already
closed the ones the corpse carried, is judged on its own process's uptime
rather than refused for a crash it had no part in. That interval runs
from the moment that process received them, not from the moment a restart was
attempted, so a server whose start-up alone takes longer is not credited with
its own handshake and respawned for ever; both moments are recorded on the
record of the process itself, and the question is asked in the one place the
subscriptions are handed over, so the bound holds however a host request and
the reader's own restart interleave — whichever of them re-establishes the
process. A restarted process that negotiates a pre-2026-07-28 version cannot
carry them either, and ends them with a `CapabilityError` rather than leaving
them `:reconnecting`. A listen write that fails after the process is gone
leaves the subscription for the next process to be re-sent to instead of
closing it — including when it fails on the hand-over itself, where taking the
new listen id has already moved the subscription off `:reconnecting` and the
stream being torn down would have been the very one the restart was
re-establishing. One that fails after a newer stream replaced it raises only
if that newer stream has itself failed. The subscriptions waiting for a
process live on a single queue behind one lock, and a handle is on it at most
once: a `cleanup` moving the open subscriptions onto it overlaps a failed
hand-over putting one back, and two threads appending to a bare Array can lose
an entry — stranding a stream the spec requires to be re-sent — or duplicate
it and send two listen requests for one subscription. `close` cancels what is
actually outstanding: `notifications/cancelled` names every listen request the
client wrote for that subscription on the live process, not only the id it
happens to be on, while ids written to a process that has since gone are
forgotten rather than cancelled on the one that replaced it. That accounting
holds because a listen request is written to the pipe it was recorded against
rather than to whichever process is current when the write finally happens: a
write still pending when the process exits goes to the process it was opening
on (failing into the paths above once its pipe is closed), never to the
replacement, which would otherwise be serving a second stream whose id the
teardown had already forgotten. On Streamable HTTP the mirror image is
refused rather than deferred — a `listen` whose connection is closed while it
is being opened raises `ConnectionError` instead of POSTing onto a transport
the host has closed, which no later `cleanup` would find.

## MCP 2026-07-28 Features

The 2026-07-28 revision makes the protocol stateless: there is no
`initialize` handshake, no session and no server-to-client request channel.
Every request carries its own metadata, and anything the server needs from
the client is asked for through the result itself. The client detects which
era a server speaks and adapts; existing code keeps working unchanged.

### Discovery and per-request metadata

```ruby
client = MCPClient.connect('http://localhost:8931/mcp')
server = client.servers.first
server.modern?            # => true for a 2026-07-28 server
server.protocol_version   # => "2026-07-28"
server.protocol_era       # => :modern or :legacy
```

A modern server is recognised by its answer to `server/discover`; every
request then carries `io.modelcontextprotocol/protocolVersion`,
`io.modelcontextprotocol/clientInfo` and
`io.modelcontextprotocol/clientCapabilities` in `_meta`, and on HTTP the
`MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers. Host-supplied
metadata (a Hash or a callable evaluated per request) is merged into every
request with `MCPClient::Client.new(request_meta: ...)`. Force an era with
`protocol: :modern` / `protocol: :legacy` (default `:auto`) and tune the
probe with `discover_timeout:` on `MCPClient.connect`, `stdio_config`,
`http_config` and `streamable_http_config` (or the server constructors).
`ping` maps to `server/discover` and `log_level=` to the per-request log
level on modern servers.

> `log_level=` is deprecated in MCP 2026-07-28 (SEP-2577). On a modern
> server it writes `_meta["io.modelcontextprotocol/logLevel"]`, part of the
> Logging utility the revision marks Deprecated as a whole: new
> implementations SHOULD NOT adopt it. See
> [Deprecated features](#deprecated-features).

Typed errors
carry the JSON-RPC code: `MCPClient::Errors::HeaderMismatchError`
(-32020), `MissingRequiredClientCapabilityError` (-32021) and
`UnsupportedProtocolVersionError` (-32022).

### Multi round-trip requests

On a modern server `tools/call`, `resources/read` and `prompts/get` may
answer `resultType: "input_required"`. The client fulfils each request in
`inputRequests` with the handlers it already has — the elicitation handler,
the sampling handler and the configured roots — and re-sends the original
request with `inputResponses` and the server's opaque `requestState`. More
than 10 rounds, a request the client cannot honour or a malformed
`inputRequests` raise `MCPClient::Errors::InputRequiredError` (exposing
`input_requests` and `request_state`).

### Custom headers from tool parameters

Tool parameters annotated with `x-mcp-header` are mirrored into
`Mcp-Param-{name}` request headers on `tools/call` (Streamable HTTP and
plain HTTP). A `-32020` HeaderMismatch rejection triggers one `tools/list`
refresh and a retry; tools with invalid annotations are excluded from the
list with a warning. `MCPClient::HeaderParams` exposes the validation.

### Subscriptions (`subscriptions/listen`)

```ruby
subscription = client.listen(notifications: { tools_list_changed: true,
                                              resource_subscriptions: ['file:///etc/hosts'] }) do |method, params|
  puts "#{method}: #{params.inspect}"
end
subscription.acknowledged   # what the server agreed to watch
subscription.unsupported    # what it did not
subscription.close
```

Each subscription is one long-lived `subscriptions/listen` request; on
Streamable HTTP it runs on its own stream and is re-opened with backoff when
the stream drops, on stdio it is re-sent when the process restarts.
`subscribe_resource` / `unsubscribe_resource` map onto listen streams on
modern servers.

### Cacheable results

`server/discover`, the `*/list` requests and `resources/read` carry
`ttlMs` and `cacheScope`. Lists are served while fresh and re-fetched on
access once stale (a stale list is served with a warning when the re-fetch
fails transiently); `resources/read` results with a `ttlMs` are cached per
URI. Entries with `cacheScope: "private"` are bound to the credentials the
request went out with and never shared across authorization contexts.
`server.cache_info(:tools)` / `cache_info(:read, uri)` expose `ttl_ms`,
`cache_scope`, `received_at` and `fresh`.

### Tasks extension (`io.modelcontextprotocol/tasks`)

```ruby
client = MCPClient::Client.new(mcp_server_configs: [...],
                               extensions: ['io.modelcontextprotocol/tasks'])

result = client.call_tool('long_running', {})   # polls tasks/get transparently

task = client.call_tool_as_task('long_running', {})
task = client.wait_for_task(task, timeout: 120)  # answers input_required via tasks/update
task.result if task.completed?
client.cancel_task(task)
```

Task-augmented calls are opt-in through `extensions:`; a server that
answers `tools/call` with a task is polled at its `pollIntervalMs` until the
task is terminal or its `ttlMs` elapses, and `input_required` tasks are
answered with the elicitation / sampling / roots handlers. `tasks/list` and
`tasks/result` do not exist on 2026-07-28 servers; the legacy task API keeps
working on 2025-11-25 servers.

### Authorization

`OAuthProvider` records the authorization server's `issuer` with each
authorization request and validates the callback's `iss` per RFC 9207
(`complete_authorization_flow(code, state, iss:)`); client credentials and
tokens are bound to the issuer that produced them, so a server that
switches authorization servers never sees another server's token. Dynamic
Client Registration carries `application_type` and is deprecated in favour
of Client ID Metadata Documents (`client_id_metadata_url:`). See
[OAUTH.md](OAUTH.md).

### Deprecated features

The 2026-07-28 [deprecated features registry](https://modelcontextprotocol.io/specification/2026-07-28/deprecated)
lists these as Deprecated under the feature lifecycle policy: they keep
working during their deprecation window, but new integrations should not
adopt them. The earliest removal is the registry's own, and it names a
*revision*, not a date: what the features 2026-07-28 deprecates wait for is
the first revision released on or after 2027-07-28, which may itself land
well after that date — do not plan around 2027-07-28 as a removal date. The
`includeContext` values follow Sampling, and only the HTTP+SSE transport has
a clock of its own. The earliest removal is when a feature becomes
*eligible* for removal; the actual removal is a Core Maintainer decision
taken during release preparation. The client logs one notice per feature per
process on first use, naming the earliest removal and the suggested
migration:

| Feature | Deprecated since | Earliest removal | Migration |
|---------|------------------|------------------|-----------|
| Roots (`roots:`, `Client#roots=`, or answering a `roots/list` request with a non-empty list) | 2026-07-28 (SEP-2577) | the first revision released on or after 2027-07-28 | Pass directories or files through tool parameters, resource URIs or server configuration |
| Sampling (`sampling_handler:` on `Client.new` or `MCPClient.connect`) | 2026-07-28 (SEP-2577) | the first revision released on or after 2027-07-28 | Integrate directly with the LLM provider API |
| Logging (`log_level=` on the client or a server, `notifications/message`) | 2026-07-28 (SEP-2577) | the first revision released on or after 2027-07-28 | Log to stderr (stdio) or use OpenTelemetry |
| HTTP+SSE transport (`MCPClient::ServerSSE`, warned once it is connected) | 2025-03-26 (reclassified by SEP-2596) | three months after SEP-2596 reaches Final | Migrate the server to Streamable HTTP |
| `includeContext` `"thisServer"` / `"allServers"` in sampling requests | 2025-11-25 (reclassified by SEP-2596) | follows Sampling (SEP-2577) | Servers omit the field or send `"none"` |
| OAuth Dynamic Client Registration | 2026-07-28 (PR #2858) | the first revision released on or after 2027-07-28 | Client ID Metadata Documents or pre-registered credentials |

A client that never adopted Roots is never warned about them. It registers a
`roots/list` handler on every server unconditionally, so that a later
`client.roots = [...]` is served without reconnecting, and until a root is set
it answers `roots/list` with an empty list — an empty answer exposes nothing
deprecated, so it raises no notice. The notice fires when the host configures
`roots:`, calls `Client#roots=`, or serves an answer that actually carries a
root (including from a transport driven directly, without a `Client`).

`MCPClient::Deprecations::REGISTRY` lists them, each with its
`earliest_removal`; set
`MCPClient::Deprecations.enabled = false` (before constructing clients) to
silence the notices. Notices go to the logger the client or server was
given; without one they go to the default `$stdout` logger like every other
warning.

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
# structuredContent in successful results. call_tool checks both automatically,
# against the JSON Schema vocabulary this client evaluates: type, enum/const,
# properties/required, patternProperties, additionalProperties, propertyNames,
# minProperties/maxProperties, dependentRequired/dependentSchemas (draft-07
# dependencies), items/prefixItems/additionalItems, minItems/maxItems,
# uniqueItems, contains with minContains/maxContains, string bounds and
# pattern (ECMAScript anchoring), numeric bounds and multipleOf,
# allOf/anyOf/oneOf/not, if/then/else, and $ref/$defs/definitions inside the
# document. What is NOT evaluated is what needs annotations collected across a
# whole composition (unevaluatedItems, unevaluatedProperties) or a dynamic
# scope ($dynamicRef, $recursiveRef), plus the two keywords that only annotate
# (format, contentSchema). When a schema uses one of those, call_tool logs a
# "validation is partial" warning naming them (in both modes), since data may
# pass this check that a full validator would reject. By default a violation
# (mismatch, or missing structuredContent on a successful result) logs a
# warning; opt in to strict mode to raise instead:
client = MCPClient::Client.new(
  mcp_server_configs: [...],
  validate_structured_content: :strict # raises MCPClient::Errors::ValidationError on violation
)
# A task-delivered result (get_task_result) is validated the same way when the
# task is named with the Task handle call_tool_as_task returned: the handle
# carries the definition its creating call went out under. A bare task ID
# identifies no tool, so a result fetched by ID is not validated.
```

A result is checked against the tool definition the request that produced it
went out under. That matters on a modern HTTP session, where a `HeaderMismatch`
rejection makes the client refresh `tools/list` and retry with recomputed
`Mcp-Param-*` headers: the retry is answered under the refreshed definition, so
that is the one it is validated against. A `tools/list_changed` that merely
arrives while the call is in flight never changes the definition the result is
checked against — the server never saw the replacement.

#### JSON Schema dialects and references

The built-in validator reads JSON Schema 2020-12 (the MCP default), 2019-09
and draft-07. Per MCP 2026-07-28 an unsupported dialect must be reported as
an error, so a tool whose `inputSchema` declares one this client does not
implement is refused before the request is sent:

```ruby
# inputSchema: {"$schema": "urn:unknown-dialect", ...}
client.call_tool('t', {})
# => raises MCPClient::Errors::ValidationError:
#    "...input schema declares the JSON Schema dialect \"urn:unknown-dialect\":
#     that dialect is not supported (supported: ...)"
```

The same applies to an `outputSchema`: an unsupported dialect there raises a
`ValidationError` in both modes, since the client cannot read the schema at
all — unlike a structured-content mismatch, which the
`validate_structured_content` mode decides. The definition checked is the one
the answered request actually went out under, so a `HeaderMismatch` retry
under a refreshed schema is covered too. A schema that is merely unusable for
another reason (a `$ref` that would need a network fetch, a document past the
resource bounds, a malformed keyword value) is warned about, and for an input
schema the call still goes out, since the server owns argument validation.

Two schema resources may not answer to one URI: a document whose `$id`s (or
whose `$anchor` names within one resource) collide is unusable, since which
declaration a reference lands on would otherwise depend on the order the
document was read in.

References are resolved inside the document only — nothing is ever fetched —
but a document that bundles the resources it uses is resolved in full: a
`$ref` naming an embedded `$id` (`"urn:example:s"`, a relative URI against the
base an enclosing `$id` established, or the empty reference `""`) resolves to
that resource, and only a reference to a resource the document does not carry
is reported as external. Under 2020-12 and 2019-09 `definitions` behaves as
the `$defs` it was renamed from, as the meta-schema of both dialects retains
it.

### Roots

> Deprecated in MCP 2026-07-28 (SEP-2577); see [Deprecated features](#deprecated-features).

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

> Deprecated in MCP 2026-07-28 (SEP-2577); see [Deprecated features](#deprecated-features).

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

> Deprecated in MCP 2026-07-28 (SEP-2577); see [Deprecated features](#deprecated-features).

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

Features: PKCE, server discovery (`.well-known`), RFC 9207 issuer validation, Client ID Metadata Documents, dynamic registration (deprecated fallback), token refresh.

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

### Authorization server binding (2026-07-28)

- **Registration state is per authorization server (SEP-2352)** — credentials
  are stored under the MCP server URL (the registration in use) *and* under
  `provider.client_registration_key(issuer)`, so two authorization servers
  behind one MCP server each keep their own registration instead of replacing
  one another. Seed pre-registered credentials for a specific authorization
  server with `storage.set_client_info(provider.client_registration_key(issuer), creds)`.
- **Pre-registered credentials outrank a portable client id** — when an
  authorization server has credentials of its own under
  `client_registration_key(issuer)`, they are used ahead of a Client ID
  Metadata Document id, which answers for every server.
- **A registration a flow needs must reach storage** — a backend that cannot
  persist the credentials in use raises instead of returning an authorization
  URL whose callback would then report "Missing PKCE or client info". The
  per-authorization-server copy stays best-effort.
- **A refresh presents the credentials in the slot a host writes to** — a
  secret rotated under the MCP server URL is used, not the older copy kept
  under the authorization server's own key. Authorization and refresh pick the
  same record.
- **A refresh and a code exchange are both re-checked when the response
  arrives** — a token from an authorization server that stopped being this
  resource's while the request was in flight is discarded rather than stored
  over the current server's token or presented, and a code exchange that
  arrives late no longer deletes the pending authorization request another
  flow started meanwhile.
- **One per-request record** — the `state`, the PKCE verifier, the expected
  issuer, the client id and the redirect URI of an authorization request are
  written together, and the callback's `state` is checked against the record
  the other checks read. Two flows sharing one storage backend can no longer
  interleave their writes until one flow's state names the other flow's
  request.
- **Scopes accumulate across step-ups** — re-authorizing after an
  `insufficient_scope` challenge asks for the union of the scopes already
  requested and the ones the challenge names, so getting `files:write` does
  not give up `files:read`.
- **Only a token type the client understands is presented** — `token_type` is
  REQUIRED (RFC 6749 §5.1) and must be `Bearer` (§7.1). A `DPoP` or `mac`
  token is refused where it is issued and where it is read back, and so is a
  response that names no type at all: §5.1 defines no default, and §7.1
  forbids using a token whose type the client does not understand.
- **Every redirect URI is `localhost` or HTTPS** — MCP 2026-07-28
  "Communication Security". `http://app.example.com/callback` is refused when
  it is configured and when a registration response registers it; plain HTTP
  on the loopback interface and RFC 8252 private-use schemes
  (`com.example.app:/cb`) are unaffected.
- **A callback parameter may appear once** — RFC 6749 §3.1: `BrowserOAuth`
  refuses a callback that repeats `iss`, `state`, `code` or any other
  parameter instead of silently taking the last value.

## Cacheable Results (MCP 2026-07-28)

A 2026-07-28 server may bound a result with `ttlMs` (how long the client MAY
consider it fresh, counted from receipt) and `cacheScope` (`"public"` or
`"private"`). The transports honour both for `tools/list`, `prompts/list`,
`resources/list`, `resources/templates/list`, `server/discover` and
`resources/read`; `cache_info(:tools)` — or `cache_info(:read, uri)` — reports
what was recorded. An absent `ttlMs` means 0 on a 2026-07-28 server, a missing
or unrecognized `cacheScope` is treated as `"private"`, and a `resources/read`
result is kept only when the server gave it a positive `ttlMs`.

A cached result is served only to a request that would carry the same things
the request that produced it did:

- **the same authorization.** A `"private"` entry is bound to the
  `Authorization` its own request actually went out with — what the adapter
  sent, not what the response phase later left in the request environment — so
  a rotated token, a revoked one, or an anonymous request never reads it.
- **the same effective parameters.** The `_meta` a request carries (your
  `request_meta` and its `baggage`, the client identity and capabilities) is
  part of what a result is bound to, whatever its scope: `"public"` permits
  sharing across callers, not across parameters a server may vary its answer
  by.

Anything the transport cannot read off its own configuration makes those
unknowable, and reuse is then turned off rather than guessed at. Middleware of
your own installed through `faraday_config` is such a case — anything with a
request hook, and any handler carrying a callback of yours: it may set an
`Authorization` or rewrite the request body, and no inspection can tell whether
it does. Framework middleware the transport can read (Faraday's own retry,
JSON, url-encoded, multipart, logger, follow-redirects, and `:authorization`
configured with literal values) keeps caching on; an `:authorization` handed a
proc keeps public entries but not private ones, since the credential it vends
may differ from request to request.

Two rules follow the protocol rather than the cache:

- a `resources/templates/list` a server put **no** hint on is fetched again on
  every call, as it was before results were cached at all; only a positive
  `ttlMs` lets a template list be answered without a request;
- a cursor the server rejects (`-32602`) ends the page sequence it belonged to.
  The pages cached for that list are dropped, an automatically paginated list
  restarts once from the first page, and an explicit `list_resources(cursor:)`
  or `list_resource_templates(cursor:)` raises — after the first page cached
  under the dead cursor has been discarded, so the next call really re-fetches.

A re-fetch that fails for a transient reason may serve the stale copy ("Clients
MAY serve stale responses if errors occur during re-fetching"); an
authorization failure never does, so it reaches your auth flow instead.

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
| OAuth discovery URLs from a peer | Must be HTTPS, and rejected when the host is a *literal* loopback/private/link-local address. The only exception is a local stack: a configured server URL on the loopback interface (`localhost`, `*.localhost`, 127.0.0.0/8, `::1`) may be sent to a plain-HTTP *loopback* URL — never to a link-local or otherwise private one. A refused challenge fails closed. Hostnames are not resolved, so a public name pointing at a private address is not caught — see the note below |
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
  stays in your local log. When a server asks for several inputs at once (MCP
  2026-07-28 multi round-trip requests) and one of them fails, the answers your
  handler already produced are kept rather than thrown away: a task's poll loop
  sends them with its next `tasks/update` and never puts an answered request to
  your handler a second time.

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
