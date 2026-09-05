# Changelog

## Unreleased — MCP 2026-07-28

Groundwork for the 2026-07-28 protocol revision (stateless, per-request
metadata). Each feature lands in its own PR; this section accumulates them.

### Stateless protocol on stdio (server/discover, per-request `_meta`)

- **No handshake for modern servers.** On stdio the client now probes with
  `server/discover` first (basic/transports/stdio "Backward Compatibility").
  A `DiscoverResult` makes the server *modern*: the client picks the newest
  mutually supported version from `supportedVersions`, records the server's
  capabilities, instructions and `_meta` `serverInfo`, and never sends
  `initialize`. An `UnsupportedProtocolVersionError` also identifies a modern
  server — the probe is retried with an advertised version and the client
  never falls back. Any other error, or a timeout, means a *legacy* server and
  the `initialize` handshake runs as before. The era is cached for the life
  of the process. The probe *declares* a protocol version without
  establishing one: until it is answered `protocol_era` stays `nil`, and a
  server-initiated request (a legacy server MAY `ping` during initialization,
  and may answer nothing until the response arrives) is still handled. The
  exception is `protocol: :modern`, which has already ruled out the legacy
  fallback that accommodation exists for: it never runs a host callback for a
  server request and never writes a JSON-RPC response, probe in flight or not.
- **A failed negotiation releases the transport.** If discovery or the
  handshake fails, the subprocess is shut down and its pipes and reader
  threads are closed before the error is raised, so a retry cannot strand the
  previous process behind overwritten handles.
- **An unexpected exit is recoverable.** If the subprocess behind a completed
  handshake exits, the reader thread retires the transport instead of leaving
  the session writing to a dead process's pipes: the next request closes the
  stale handles and negotiates again against a fresh subprocess
  (basic/transports/stdio "Unexpected Termination": clients SHOULD restart a
  server that terminated unexpectedly). The request that was in flight still
  fails — the server may already have executed it, so it is never replayed.
- **Per-request metadata.** Every request to a modern server carries
  `io.modelcontextprotocol/protocolVersion`, `clientInfo` and
  `clientCapabilities` in `_meta` (with `extensions` once declared via
  `declare_extension`, whose identifiers follow the `_meta` key grammar with
  a mandatory prefix — the name after the slash may be empty, so
  `com.example/` is valid). Host-supplied `_meta` keys (`progressToken`,
  OpenTelemetry `traceparent`/`tracestate`/`baggage`, vendor keys) are
  preserved. The reserved protocol keys are transport-owned and are stripped
  from both `request_meta` and per-call `_meta`, so
  `server.send_client_info = false` really suppresses the client identity:
  a caller cannot reinstate it by passing its own
  `io.modelcontextprotocol/clientInfo`. Legacy traffic is byte-for-byte
  unchanged. `Client.new(request_meta:)` (a Hash or a callable evaluated per
  request) merges default metadata into every request on every transport.
- **Inline version retry.** A modern server answering any request with
  `UnsupportedProtocolVersionError` makes the client switch to a mutually
  supported version from `data.supported` and re-send once (new id).
- **Removed methods mapped.** Against a modern server `ping` maps to
  `server/discover` (answered from the probe on a fresh connection),
  `log_level=` stores the level and sends it as
  `_meta["io.modelcontextprotocol/logLevel"]` on subsequent requests instead
  of calling `logging/setLevel`, and `notifications/roots/list_changed` is
  no longer sent (the modern `roots` capability has no `listChanged`).
- **Configuration.** `MCPClient.stdio_config(protocol:, discover_timeout:)`
  and `ServerStdio.new(protocol:, discover_timeout:)`: `:auto` (default,
  dual-era), `:modern` (fail instead of falling back), `:legacy` (skip the
  probe; the probe waits the full `read_timeout` by default so a slow-starting
  modern server is not misclassified). New readers: `protocol_version` (the
  version outgoing requests declare, which during the probe is only a
  proposal), `protocol_era` (`:modern`, `:legacy`, or `nil` while the era is
  unknown), `modern?`, `supported_versions`. Initialization is serialized, so
  concurrent first requests run the probe once.
- **Multi round-trip requests are not driven yet.** Modern requests declare
  no `roots`, `sampling` or `elicitation` capability until the multi
  round-trip pattern lands, so a compliant server has no input it may ask
  this client for (basic/patterns/mrtr: a server MUST NOT send an
  `inputRequests` the client has not declared support for). It may still
  answer `prompts/get`, `resources/read` or `tools/call` with an
  `input_required` result carrying only the opaque `requestState`, which a
  client MAY retry immediately. Either shape raises
  `MCPClient::Errors::InputRequiredError` (exposing `input_requests` and
  `request_state`) instead of being mistaken for the operation's result;
  echoing the state back on a retry is left to the multi round-trip PR.

### Protocol foundations

- **Version constants.** `MCPClient::LATEST_PROTOCOL_VERSION` (`2026-07-28`),
  `MODERN_PROTOCOL_VERSIONS` (per-request metadata revisions) and
  `LEGACY_PROTOCOL_VERSIONS` (initialize-handshake revisions).
  `SUPPORTED_PROTOCOL_VERSIONS` is now their union; `PROTOCOL_VERSION` stays
  `2025-11-25` because it is the version the legacy `initialize` request asks
  for, and a server answering `initialize` with a modern version is rejected.
- **Typed JSON-RPC errors.** `MCPClient::Errors::ServerError` now carries the
  JSON-RPC `code` and `data` (`ServerError.new(msg, code:, data:)`, fully
  backward compatible). `ServerError.from_jsonrpc(error)` builds the
  2026-07-28 spec-defined errors: `HeaderMismatchError` (-32020),
  `MissingRequiredClientCapabilityError` (-32021, `#required_capabilities`)
  and `UnsupportedProtocolVersionError` (-32022, `#supported`, `#requested`).
  `MCPClient::Errors::Codes` holds the code constants and the allocation
  policy helpers. All four transports raise these typed errors.
- **Only a well-formed error identifies a modern server.**
  `#modern_protocol_error?` (which suppresses the legacy `initialize`
  fallback, and lets the error propagate through the public wrappers) is true
  only for an error carrying the wire shape its schema mandates: the JSON-RPC
  `message` string, plus `requiredCapabilities` as an object for -32021 and
  `supported: string[]` with `requested: string` for -32022. Those are the
  schema's types and nothing more — an empty `supported` list still marks a
  modern server that named no version this client can retry with, which is a
  failed negotiation rather than evidence of a legacy peer. An error object
  with no JSON-RPC `message` at all is malformed at the JSON-RPC level and
  does not even earn a typed class — it stays a plain `ServerError` with its
  `code` and `data` preserved. A legacy endpoint or intermediary emitting a
  bare -3202x code therefore cannot suppress the fallback.
- **`resultType`.** Every result is checked: an absent field is treated as
  `"complete"` (earlier-protocol servers, and modern ones that omit it), and
  any unrecognized value raises `MCPClient::Errors::InvalidResultError` (a
  `ServerError`, so it is answered rather than re-sent), as the spec
  requires. `"input_required"` passes through for the multi round-trip
  handling that follows, but only on a modern session: the pattern exists
  only in 2026-07-28, so a handshake-era server claiming an unfinished result
  is malformed. Operations that project a field out of the result
  (`read_resource`) never flatten an unfinished one into an empty success —
  they raise, with the whole result on the error's `data` so a host can drive
  the round trip itself.
- **Typed errors from HTTP error bodies.** 2026-07-28 servers carry their
  protocol errors in the body of an HTTP 400 (and an unknown method as a 404
  with -32601). The HTTP, Streamable HTTP and SSE transports now parse a
  JSON-RPC error out of a 4xx body and raise the typed error (with the HTTP
  status prefixed to the message, and the code, data and HTTP status
  preserved), so a dual-era client can tell a modern rejection from a legacy
  one. 5xx responses stay `TransientServerError`. The body is read whether it
  arrives raw or already decoded by host-configured response middleware
  (`faraday_config` with `conn.response :json`, with or without
  `conn.response :raise_error`); a raw body is size-bounded and incrementally
  gunzipped before it is parsed.
- **Resource not found.** A `resources/read` error with the legacy `-32002`
  code — or `-32602` from a modern (2026-07-28) server — now raises
  `MCPClient::Errors::ResourceNotFound` on every transport instead of a
  generic `ResourceReadError`. On a legacy session `-32602` stays the
  generic Invalid params it always was. `protocol_version` / `modern?` are
  now readable on every transport.

## 2.1.0 — Hostile-Server Hardening (2026-08-04)

A security pass over every transport, driven by an external scan of the 2.0.0
codebase (50 findings: 12 medium, 38 low) and a second, adversarial review of
each fix (PRs #188–#211). Every finding was reproduced before it was fixed and
re-verified afterwards — including three bugs found by reviewing the release
notes themselves against the code (#209, #210, #211).

The theme: **a remote MCP server is untrusted input.** 2.0.0 was correct against
a cooperative server but assumed good faith in places where a hostile — or merely
compromised — peer controls the data. Nothing here changes the wire protocol, and
the ordinary client API is unchanged; what changes is what the client accepts,
retries, logs and reflects back.

### Breaking Changes

- **`tools/call` is never retried automatically** (#196). A "transient" failure
  (HTTP 5xx, dropped connection) can arrive *after* the server executed the
  request, so replaying it risks a duplicate side effect, and JSON-RPC has no
  idempotency key to make that safe. `NON_IDEMPOTENT_METHODS` is excluded from
  `with_retry` on all four transports. Idempotent methods (`tools/list`,
  `resources/read`, `ping`, …) retry exactly as before. Hosts that relied on
  tool calls being retried must now retry explicitly and decide for themselves
  whether re-execution is acceptable.

  This also covers **session-expiry recovery** on the HTTP transports (#209).
  A 404 carrying an expired `Mcp-Session-Id` still starts a fresh session, but
  the original request is only re-sent when it is idempotent; a `tools/call`
  instead raises `ConnectionError` saying the request was not resent because it
  may already have executed. Without this, session recovery was a second,
  independent path around the guarantee — and it applied even with
  `retries: 0`.
- **Task operations refuse to guess a server** (#199). Task IDs are unique only
  within the server that issued them, so `get_task`/`get_task_result`/
  `cancel_task` no longer default to the first configured server. Pass the
  `MCPClient::Task` returned by `call_tool_as_task` (it carries its own server),
  or name the server explicitly. A bare ID still works with a single configured
  server; with several it raises `ArgumentError` rather than acting on the wrong
  one.
- **Peer-facing error messages are constant** (#198). Host callback exceptions
  are no longer interpolated into JSON-RPC error responses on any transport —
  a handler raising with a file path or connection string used to send it to the
  server. Peers receive `'Internal error'` / `'Sampling error'` /
  `'Elicitation handler error'`; the detail stays in the local log. Error
  **codes** are unchanged.
- **Logs no longer contain payloads** (#198, #210, #211). Request params,
  response bodies and raw SSE chunks are replaced by a method/id summary and a
  byte count, so enabling DEBUG no longer records `tools/call` arguments, tool
  results or elicitation content. The *error* paths are covered too, and they
  were the leakier ones: a non-object JSON payload used to be logged with
  `#inspect` at **WARN** (which the default logger emits, so it leaked with
  DEBUG off), and `JSON::ParserError#message` quotes the offending token, so
  malformed peer JSON echoed into logs and into the `Invalid JSON response from
  server` exception on every transport. Parse failures now report position and
  size only. Server configs are logged with credential-bearing keys redacted,
  and peer-supplied log messages are control-character escaped and capped (a
  server could otherwise forge log lines).
- **Cross-origin traffic is refused on the legacy SSE transport** (#189). An
  `endpoint` control event that changes scheme/host/port fails the handshake, and
  redirects that leave the connection origin are refused — `faraday-follow_redirects`
  strips only `Authorization`, so a custom API-key header and the request body
  would otherwise reach the new origin.
- **Peer-advertised OAuth discovery URLs must be HTTPS and non-local** (#190).
  The `resource_metadata` URL from a 401 challenge and the `authorization_servers`
  origin from Protected Resource Metadata are validated before any fetch. The
  plain-HTTP loopback exception now applies only when the *configured* server is
  itself local, so a remote server can no longer point discovery at a *literal*
  loopback or private address. A refused challenge fails closed instead of
  falling back to cached metadata. The check is textual: hostnames are not
  resolved, so a public name whose DNS record points inside your network is not
  caught — restrict egress at the network layer if that matters to you.
- **Oversized and malformed peer data is rejected** rather than absorbed:
  gzip bodies that expand past the limit (#188 — Streamable HTTP, the only
  transport that requests gzip), SSE events that never terminate (#191, #192),
  event IDs that are unbounded or illegal in an HTTP header (#200).

### New Features

- **`max_decompressed_body_bytes`** on the Streamable HTTP transport (#188).
  Bounds how far a gzip response may expand (default 64 MiB) so a small
  "gzip bomb" cannot exhaust memory. Configurable because the ceiling would
  otherwise make a large legitimate response depend on whether the server chose
  to compress it.
- **`MCPClient::Errors::ResponseTooLargeError`** (#188), a `TransportError`
  subclass that is deliberately excluded from retries: the server already ran the
  request, so re-sending risks a duplicate side effect.
- **Ruby 4.0.6 is the development default** (#204, #205), with a dedicated CI
  suite. 3.2 and 3.3 remain tested and `required_ruby_version` is unchanged at
  `>= 3.2.0`. A tracked `.ruby-version` replaces the gitignored `.tool-versions`,
  and `BUNDLED WITH` moves to a bundler that supports Ruby 4.

### Bug Fixes

- Server-supplied schema `pattern` values are matched under a **whole-operation**
  time budget (#197). A per-match limit was not a bound, because the peer also
  chooses how many strings are matched; a timeout now fails validation rather than
  silently accepting a value whose constraint was never evaluated.
- Server-initiated replies (pongs, roots/sampling/elicitation, error responses)
  no longer spawn unbounded threads (#194); the budget is released correctly when
  thread creation fails, and saturation warnings are rate-limited so the fix does
  not become its own log-flood vector.
- Unsolicited SSE responses are discarded instead of accumulating in the pending
  map, and `cleanup` no longer drops a result whose request is still pending —
  which would have reported a timeout for a tool the server had already run (#195).
- SSE buffers are appended and scanned incrementally (#191, #192). Capping the
  size bounded memory but left an O(N²) copy/rescan path: an unterminated event
  in 16 KiB chunks took 11.2s before, 0.018s now.
- Server `retry:` directives are floored so `retry: 0` cannot drive a tight
  reconnect loop (#193, #200), while the first resumption GET still goes out
  immediately when no directive was given.
- A JSON-parseable scalar or array arriving on the GET events stream no longer
  raises inside message dispatch; it is skipped with a typed warning, matching
  the POST response path (#210).

### Examples & Tooling

- Filesystem examples run against a disposable sandbox directory instead of the
  checkout, npm servers are version-pinned, and credential-looking variables are
  stripped from child processes (#201, #206). `streamable_http_example.rb` no
  longer invokes an arbitrary server-advertised tool — name one with
  `MCP_EXAMPLE_TOOL`. The OAuth storage demo writes its token file atomically
  at `0600`.
- The bundled example servers enforce session ownership for task operations and
  reject session-less POSTs, and the filesystem test fixture resolves symlinks
  and compares path components instead of string prefixes (#202).
- GitHub Actions are pinned to commit SHAs (#203).

### Migration notes

- If you relied on `tools/call` being retried, retry explicitly. Treat the raised
  error as "outcome unknown" — the server may already have executed the call.
  This includes the session-expiry path: a tool call interrupted by an expired
  session now raises instead of being transparently re-sent against the new one.
- In multi-server clients, replace `client.get_task(id)` with
  `client.get_task(task)` (the handle from `call_tool_as_task`) or add
  `server:`. Single-server clients need no change.
- If you parsed detail out of JSON-RPC error messages a peer sent you, or out of
  this client's DEBUG logs, those strings are now constant/summarized. Codes and
  local logs still carry the detail.
- A server that advertises a cross-origin SSE `endpoint`, a plain-HTTP or loopback
  OAuth discovery URL, or redirects RPC POSTs off-origin will now be rejected. If
  you develop against a local stack, point the *configured* server URL at
  localhost and the loopback exception still applies.
- Set `max_decompressed_body_bytes:` if you legitimately exchange responses that
  expand beyond 64 MiB.
- Development now expects Ruby 4.0.6 (`.ruby-version`); the gem still supports
  3.2+. Run `bundle install` after upgrading — `BUNDLED WITH` changed.

## 2.0.0 — MCP 2025-11-25 Conformance (2026-07-21)

Full compliance pass against the **MCP 2025-11-25** specification: every transport,
utility and auth flow was audited against the spec and brought into conformance
(PRs #158–#185). The wire behavior and several error semantics changed as a result,
so this is a major release. See **Migration notes** below.

### Breaking Changes

- **Elicitation error semantics and wire format** (#158, #159). Elicitation replies
  are now proper JSON-RPC *responses* (the previous Streamable HTTP implementation
  invented an `elicitation/response` request that no spec defines). Hosts get spec
  error codes instead of fabricated user answers: no handler configured → `-32601`
  (was an automatic `'decline'`); handler raised → `-32603` (was `'decline'`);
  undeclared mode → `-32602` (mode is checked before the handler); non-object or
  scalar `content` → `-32603` instead of being transmitted. `content` is omitted for
  `decline`/`cancel` and for out-of-band (`url`) accepts, per the `ElicitResult` schema.
- **Sampling error semantics** (#177). No handler → `-32601`, handler exception →
  `-32603` (both were the user-rejection code `-1`); tool-enabled sampling requests
  (`tools`/`toolChoice`, SEP-1577) are rejected with `-32602` unless the host opts in
  via `sampling_supports_tools: true`.
- **Declared client capabilities are derived from registered handlers** (#160).
  stdio and SSE no longer unconditionally declare `sampling`/`elicitation`; every
  transport declares exactly what the host wired up before `connect` (elicitation
  modes `form`+`url`, `roots.listChanged`, `sampling`). Compliant servers will stop
  sending requests your host never handled — previously they were answered with
  fabricated declines.
- **Protocol version negotiation is enforced** (#161). If the server's `initialize`
  result carries an unsupported or missing `protocolVersion` (supported: `2025-11-25`,
  `2025-06-18`, `2025-03-26`, `2024-11-05`), the client disconnects and raises
  `MCPClient::Errors::ConnectionError`. Non-object initialize results also fail the
  connection (#161, #172).
- **Server capability gating** (#173). `subscribe_resource`, `unsubscribe_resource`,
  `complete`, `list_tasks` and `cancel_task` raise the new
  `MCPClient::Errors::CapabilityError` when the server did not negotiate the
  corresponding capability (the lifecycle forbids using un-negotiated capabilities).
  `Client#log_level=` now *skips* servers without the `logging` capability instead of
  raising on the first one — its return value only covers logging-capable servers.
- **Timeouts no longer re-send** (#178). A request that exceeds its timeout raises the
  new `MCPClient::Errors::RequestTimeoutError` (a `TransportError` subclass — existing
  rescues keep working) and is excluded from automatic retries, because the server may
  still be executing it; a best-effort `notifications/cancelled` is sent instead
  (never for `initialize`; task-augmented calls use `tasks/cancel`). Previously
  timed-out requests were retried up to `retries` times, risking double execution.
- **Roots are validated** (#169). `MCPClient::Root` (and `Client.new(roots:)`) raises
  `ArgumentError` for non-`file://` URIs, `..` traversal segments (checked after
  percent-decoding), and non-Hash `_meta`.
- **PKCE is mandatory** (#165). The OAuth flow refuses to proceed (raises
  `ConnectionError`) when the authorization server does not advertise
  `code_challenge_methods_supported` including `S256`, instead of silently continuing
  without PKCE.
- **OAuth challenge parsing is Bearer-scoped** (#163). `WWW-Authenticate` parameters
  are read from the Bearer challenge's own segment only (quoted-string aware), a 403
  with `error="insufficient_scope"` raises the new
  `MCPClient::Errors::InsufficientScopeError` (a `ConnectionError` subclass exposing
  `#scope`/`#error_description`), challenge-advertised scopes take priority for the
  next authorization, and a challenge-advertised `resource_metadata` URL is
  authoritative (no silent fallback to well-known paths).
- **`_meta` moved out of tool arguments** (#179). Request-level `_meta` supplied in
  `call_tool`/`get_prompt` arguments (as `:_meta` or `'_meta'`) is hoisted to the
  JSON-RPC `params` level on the wire on every transport, instead of being serialized
  as a tool argument (where it could fail the tool's input schema).
- **Streamable HTTP resumability follows SEP-1699** (#168, #181). `Last-Event-ID` is
  no longer sent on POST requests; interrupted response streams are resumed via GET
  with the per-stream cursor, honoring the server's `retry:` directive.
- **Legacy SSE fixes change failure modes** (#172). Server JSON-RPC *error* responses
  now surface immediately as `MCPClient::Errors::ServerError` (previously the request
  hung until the read timeout); an endpoint URL that cannot be resolved fails
  `connect` with `ConnectionError`; the negotiated `MCP-Protocol-Version` header is
  sent on subsequent HTTP requests.
- **Session handling** (#162). Session IDs are validated against the spec charset
  (any visible ASCII, 1–4096 chars — JWTs and base64 IDs now accepted; the previous
  `[A-Za-z0-9_-]{8,128}` rule rejected them), and an HTTP 404 on a session-bearing
  request transparently re-initializes and re-sends once (Streamable HTTP session
  expiry recovery).
- **`taskSupport: "required"` without a task-capable server is a plain call** (#174).
  Per tasks tool-level negotiation, when the server lacks `tasks.requests.tools.call`
  the tool's `execution.taskSupport` is disregarded entirely — previously the client
  raised `ToolCallError`.
- **stdio shutdown and encoding** (#171). `cleanup` closes stdin and gives the server
  a grace period to exit before SIGTERM/SIGKILL (previously immediate); pipes are
  pinned to UTF-8 so multibyte content cannot corrupt framing on non-UTF-8 locales.

### New Features

- **Streamable HTTP POST SSE streams** (#158): server requests and notifications
  interleaved on a POST response stream are dispatched (elicitation/sampling/roots/
  ping work mid-call), instead of the first event being taken as "the response".
- **Resumability** (#168, #181): GET-based resumption with `Last-Event-ID`, per-stream
  cursors, and support for the SSE `retry:` directive (including `retry: 0`).
- **Progress tracking** (#179): `client.call_tool(name, args, progress: ->(progress, total, message) { ... })`
  auto-generates a `progressToken`, routes matching `notifications/progress` to the
  callback while the request is active, and drops stale tokens afterwards.
- **Per-request timeouts** (#178): `Client#send_rpc(..., timeout:)` and
  `ServerBase#rpc_request(..., timeout:)` override the per-server `read_timeout`.
- **Client identity & server instructions** (#180): `Client.new(client_info: {...})`
  sends a host-provided `Implementation` as `clientInfo`; `server.instructions`
  exposes the server's `initialize` instructions hint.
- **Sampling tool calling, SEP-1577** (#177): `sampling_supports_tools: true` declares
  `sampling.tools` and forwards `tools`/`toolChoice` to the handler (optional fifth
  handler argument receives the full request params).
- **Structured content validation** (#176): tool results with `structuredContent` are
  validated against the tool's `outputSchema` — `validate_structured_content: :warn`
  (default) logs mismatches, `:strict` raises `ValidationError`; unsupported schema
  keywords are surfaced transparently.
- **OAuth**: Client ID Metadata Documents, SEP-991 (#175) via
  `client_id_metadata_url:` (skips dynamic registration when the AS supports CIMD);
  scope step-up via `InsufficientScopeError` (#163); authorization applied to every
  HTTP request including SSE GETs and pong/response POSTs (#167).
- **Model metadata** (#170): `icons`, `title` and `_meta` parsed and exposed on
  `Tool`, `Prompt`, `Resource` and `ResourceTemplate`.
- **Capability introspection** (#173): `ServerBase#capability?('tasks', 'list')` and
  `require_capability!` are public API.
- **Tasks related-task metadata** (#174): `io.modelcontextprotocol/related-task`
  `_meta` is echoed on responses to server requests issued within a task context.
- **New error classes**: `CapabilityError`, `RequestTimeoutError`,
  `InsufficientScopeError`.

### Bug Fixes

- Streamable HTTP: server requests arriving on a POST SSE stream are answered instead
  of being mistaken for the call's response; lone responses with mismatched IDs are
  tracked per stream (#158).
- Elicitation over Streamable HTTP uses real JSON-RPC responses, so compliant servers
  (e.g. FastMCP) receive answers they understand (#159).
- Legacy SSE: JSON-RPC error responses are delivered to waiters; connection failures
  during endpoint resolution surface through `wait_for_connection` (#172).
- OAuth: Bearer tokens embedded in quoted parameter values no longer confuse
  challenge parsing (quoted-string masking) (#163).
- stdio: tolerates non-object JSON lines on stdout without killing the reader (#171).
- Cancellation is suppressed for requests that must not be cancelled (`initialize`)
  and for task-augmented calls (#178).

### Examples & Tooling

- The Streamable HTTP echo server implements the full tasks feature (capability,
  `background_work` tool, `tasks/get|result|list|cancel`, status notifications), and
  `tasks_example.rb` runs the complete lifecycle against it locally (#184, #185).
- The elicitation demo server accepts standard JSON-RPC `ElicitResult` responses
  (previously it only understood the pre-2.0 invented method) (#182).
- The two OpenAI examples pin their intended gem (`openai` vs `ruby-openai` both
  provide `lib/openai.rb`) onto the load path explicitly (#182).
- The Anthropic example surfaces API error bodies (e.g. billing errors) and rejects
  an empty `ANTHROPIC_API_KEY` (#183).
- README documents all new public APIs (#182) and the supported protocol revisions.

### Migration notes

Upgrading a **host application**:

- If you rescued elicitation/sampling failures by inspecting fabricated `'decline'`
  results or the `-1` error code, switch to the JSON-RPC codes above.
- Wrap `subscribe_resource`/`complete`/`list_tasks`/`cancel_task` calls in
  `rescue MCPClient::Errors::CapabilityError` (or check `server.capability?` first)
  if you talk to servers that do not negotiate those capabilities.
- If you relied on timed-out requests being retried, retry explicitly — and treat
  `RequestTimeoutError` as "outcome unknown", not "not executed".
- Audit `roots:` values: only `file://` URIs without traversal segments are accepted.
- If a server you depend on omits `protocolVersion` or answers with an unknown
  revision, it will no longer connect — fix the server or pin an older gem.
- Exact-class checks (`instance_of?`) on `TransportError`/`ConnectionError` will not
  match the new subclasses; `rescue` hierarchies are unaffected.
- `Client.new` gained keyword arguments only (`sampling_supports_tools:`,
  `client_info:`, `validate_structured_content:`); existing positional usage is
  unchanged.

Upgrading a **server implementation tested against this client**:

- Expect elicitation answers as JSON-RPC responses (id echoing your request), not
  `elicitation/response` requests.
- Expect request-level `_meta` in `params._meta`, not inside `params.arguments`.
- Expect `Last-Event-ID` on GET resumption requests only, `MCP-Protocol-Version` on
  legacy SSE POSTs, and `notifications/cancelled` after client-side timeouts.
- Declared client capabilities now reflect what the host registered — do not send
  elicitation/sampling requests unless the capability was declared.


## 1.1.0 (2026-07-04)

### Breaking Changes

- **Tasks API rewritten to conform to MCP 2025-11-25.** The previous implementation
  targeted a `tasks/create` method that does not exist in the specification.
  - Removed `Client#create_task`. To create a task, augment a `tools/call` via the new
    `Client#call_tool_as_task(name, arguments, ttl:)`, which returns a `MCPClient::Task`.
  - `MCPClient::Task` fields renamed and reduced to the spec set: `id`→`task_id`,
    `state`→`status`; added `status_message`, `created_at`, `last_updated_at`, `ttl`,
    `poll_interval`; removed `progress`, `total`, `message`, `result`, `progress_token`,
    and `progress_percentage`. Statuses are now `working`, `input_required`,
    `completed`, `failed`, `cancelled` (was `pending`/`running`/…).
  - `Client#get_task` and `Client#cancel_task` now send the `taskId` parameter (was `id`)
    and return a `Task` with the new field set.

### New Features

- `Client#call_tool_as_task` — create a task by augmenting `tools/call` (gated on the
  server's `tasks.requests.tools.call` capability and the tool's `execution.taskSupport`).
- `Client#get_task_result` (`tasks/result`) — retrieve the underlying task result.
- `Client#list_tasks` (`tasks/list`, paginated).
- Tool-level task negotiation: `Tool#task_support`, `#supports_task?`, `#task_required?`,
  `#task_optional?`, `#task_forbidden?` (parsed from `execution.taskSupport`).
- The client handles `notifications/tasks/status` server notifications. (It does not
  declare a client `tasks` capability: that marks a task *receiver* for
  sampling/elicitation, which is not implemented — the client is a task requestor for
  `tools/call` only.)
- **Automatic pagination**: `list_tools` and `list_prompts` now follow the server's
  `nextCursor` and return the complete set across all pages, with a per-call safety
  bound and an identical-cursor loop guard. No manual cursor handling is required (#148).

### Bug Fixes

- **Tool annotations**: corrected `readOnlyHint`/`destructiveHint` defaults to match the
  MCP 2025-11-25 `ToolAnnotations` schema — an un-annotated tool is treated as writable,
  potentially destructive, and open-world (#140).
- **Ping utility**: the stdio and SSE transports now respond to a server-initiated `ping`
  with an empty result (#141).
- **stdio deadlock**: drain the subprocess's stderr so a server that writes heavily to
  stderr can no longer block the pipe (#142).
- **MCP lifecycle**: HTTP and Streamable HTTP transports now send
  `notifications/initialized` after `initialize`, as the specification requires (#143).
- **stdio memory leak**: bound the pending-response map so responses to abandoned
  requests can no longer accumulate (#144).
- **Logger**: stop overwriting a caller-supplied logger's formatter (#145).
- **Ruby 3.4+**: declare `base64` as a runtime dependency to avoid a `LoadError` (#146).
- **Retry safety**: application-level `ServerError`s are no longer retried; only transport
  errors and transient HTTP 5xx responses (`TransientServerError`) are retried, so
  non-idempotent requests are not executed twice (#149).
- **SSE reconnection**: repaired the auto-reconnect path that could never fire because the
  monitor thread killed itself (#150).
- **OAuth discovery**: authorization-server and protected-resource metadata discovery now
  follows RFC 8414 and RFC 9728 (#151).

### Examples & Tooling

- Added `examples/run_all_examples.sh`, a pre-release harness that boots each example's
  server, runs every example, and reports PASS/FAIL/SKIP, plus an `examples/README.md`
  index. Fixed stale examples (removed the retired Playwright `browser_install` call,
  robust first-tool selection in `streamable_http_example.rb`, updated the Gemini model)
  and wired the Zapier/OAuth examples through a gitignored `examples/secrets.env` (#153).

### Documentation

- Fixed the README OAuth snippet `require` and corrected method names in the changelog (#147).

### Dependencies

- Bumped `faraday` to 2.14.3, plus routine development-dependency updates.

## 1.0.1 (2026-03-22)

### New Features

#### OAuth 2.1 Enhancements
- **Supported Scopes Discovery**: New `supported_scopes` method on `OAuthProvider` and `scope: :all` shorthand to request all server-advertised scopes (#109)
- **Extra Client Metadata in DCR**: Dynamic client registration now supports optional OIDC metadata fields (`client_name`, `client_uri`, `logo_uri`, `tos_uri`, `policy_uri`, `contacts`) (#110)
- **PKCE Serialization**: `PKCE#to_h` and `PKCE.from_h` methods for persisting and restoring PKCE state (#100)

#### RubyLLM Integration Example
- **New `examples/ruby_llm_mcp.rb`**: Demonstrates bridging MCP tools to RubyLLM using a minimal `Class.new(RubyLLM::Tool)` wrapper, with OpenAI as the LLM provider and Playwright MCP for browser automation. RubyLLM handles the tool call loop automatically.

## 1.0.0 (2026-02-15)

### MCP 2025-11-25 Protocol Support

Full implementation of the **MCP 2025-11-25** specification, upgrading from 2025-06-18.

#### New Protocol Features
- **Audio Content**: Support for audio content type in tool results and messages (#82)
- **Resource Annotations**: Added `lastModified` field to resource annotations (#83)
- **Enhanced Tool Annotations**: Hint-style annotation API (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) alongside legacy annotations (#84)
- **Enhanced Elicitation**: Improved server-initiated user interaction support for MCP 2025-11-25 (#85)
- **Enhanced Sampling**: Added `modelPreferences` support for server-requested LLM completions (#86)
- **Completion Context**: Completion requests now support context parameter for MCP 2025-11-25 (#87)
- **Structured Task Management**: Server-driven task tracking with `tasks/list`, `tasks/get`, progress notifications, and cancellation (#88)
- **ResourceLink Content Type**: New content type for linking to MCP resources from tool results (#89)
- **Tool Title**: Optional human-readable `title` field for tools, separate from the programmatic `name` (by @conr) (#72)

#### Protocol Compliance
- **`Mcp-Protocol-Version` Header**: All HTTP transports now send the negotiated protocol version header on post-initialization requests, as required by the MCP spec
- Protocol version captured from server `initialize` response and used in all subsequent requests

### Bug Fixes
- **Parameter Validation**: `validate_params!` now skips required parameters that have a `default` value in the schema, fixing compatibility with Playwright MCP and other Zod-based servers
- **Anthropic Tool Schema Cleaning**: `to_anthropic_tool` now strips `$schema` keys from tool schemas, preventing 400 errors from the Anthropic Messages API
- **Streamable HTTP Example**: Updated to use environment variables for server URL and Bearer token authentication instead of hardcoded credentials
- **Anthropic Example**: Fixed model name to use current `claude-sonnet-4-5-20250929`
- Fixed JSON parsing edge cases

## 0.9.1 (2025-12-10)

### New Features

#### Simplified API - `MCPClient.connect(url)`
- **New single entry point** that auto-detects transport based on URL patterns (#62)
  - `MCPClient.connect('http://localhost:8000/sse')` → SSE transport
  - `MCPClient.connect('http://localhost:8931/mcp')` → Streamable HTTP transport
  - `MCPClient.connect('npx -y @modelcontextprotocol/server-filesystem /home')` → stdio transport
  - Supports options: `headers`, `read_timeout`, `sampling_handler`, etc.
  - Multiple servers: `MCPClient.connect(['http://server1/mcp', 'http://server2/sse'])`

#### MCP 2025-06-18 Protocol Compliance (#62)
- **Roots Support**: Define filesystem scope boundaries
  - `client.roots = [{ uri: 'file:///path', name: 'Root' }]`
  - Sends `notifications/roots/list_changed` to servers
  - Handles `roots/list` requests from servers

- **Sampling Support**: Server-initiated LLM completions
  - `sampling_handler:` parameter for `MCPClient.connect()` and `Client.new`
  - Handles `sampling/createMessage` requests from servers
  - Supports variable arity handlers (1-4 args)

- **Completion Support**: Autocomplete suggestions
  - `client.complete(ref:, argument:)` method
  - Works with prompts (`ref/prompt`) and resources (`ref/resource`)
  - Returns completion values with pagination info

- **Logging Support**: Server log messages
  - `client.log_level = level`
  - Handles `notifications/message` from servers
  - Maps MCP levels to Ruby Logger levels

#### Faraday Connection Customization (by @conr) (#58)
- Added ability to customize Faraday HTTP connections
- Pass custom middleware, adapters, or configuration blocks

### Documentation
- Updated YARD documentation

## 0.9.0 (2025-11-05)

### MCP Protocol Update
- **Updated to MCP 2025-06-18**: Latest protocol specification
  - Protocol version constant updated from `2025-03-26` to `2025-06-18`
  - All documentation and code comments updated to reference 2025-06-18
  - Maintains full backward compatibility with previous versions

### New Features

#### Elicitation (Server-initiated User Interactions)
- **Full Elicitation Support**: Servers can now request structured user input during tool execution
  - Implemented across all transports: stdio, SSE, and Streamable HTTP
  - Bidirectional JSON-RPC communication for interactive workflows
  - Support for all three response actions: `accept`, `decline`, `cancel`
  - Callback-based API with `elicitation_handler` parameter
  - Automatic decline when no handler registered
  - Thread-safe response delivery for HTTP-based transports
  - Proper handling of `elicitation/create` requests
  - Responses sent as JSON-RPC requests (method: `elicitation/response`)
  - Content field only included when present (not empty hash for decline/cancel)

#### Elicitation Examples
- **stdio Transport Example** (`examples/elicitation/`)
  - `elicitation_server.py` - Python MCP server with elicitation tools
  - `test_elicitation.rb` - Interactive Ruby client with user input
  - Tools: `create_document`, `send_notification`

- **Streamable HTTP Transport Example** (`examples/elicitation/`)
  - `elicitation_streamable_server.py` - Python server supporting both SSE and Streamable HTTP
  - `test_elicitation_streamable.rb` - Full-featured client with multi-step workflows
  - Tools: `create_document`, `delete_files`, `deploy_application`

- **SSE Transport Example** (`examples/elicitation/`)
  - `test_elicitation_sse_simple.rb` - Minimal SSE example with auto-response
  - Uses traditional SSE transport (GET /sse for stream, POST /sse for RPC)
  - Perfect for testing and CI/CD

#### Browser-based OAuth flow
- Added support for browser-based OAuth authentication flow (#50)

#### Streamable HTTP Gzip Support
- Added gzip compression support for streamable HTTP transport (by @purposemc) (#46)

### Implementation Details

#### Core Changes
- `lib/mcp_client/version.rb` - Updated PROTOCOL_VERSION to '2025-06-18'
- `lib/mcp_client/client.rb` - Added elicitation handler registration and propagation
- `lib/mcp_client/server_streamable_http.rb` - Added elicitation support for Streamable HTTP
  - `on_elicitation_request` - Register callback
  - `handle_elicitation_create` - Process elicitation requests
  - `send_elicitation_response` - Send responses via HTTP POST
  - `post_jsonrpc_response` - Thread-safe response delivery
- `lib/mcp_client/server_sse.rb` - Added elicitation support for SSE
  - Queue-based response delivery
  - Proper handling of JSON-RPC requests vs responses
- `lib/mcp_client/server_stdio.rb` - Added elicitation support for stdio
  - Bidirectional JSON-RPC over stdin/stdout
- `lib/mcp_client/json_rpc_common.rb` - Enhanced message type detection
- `lib/mcp_client/server_http.rb` - Base class updates

#### Bug Fixes
- Fixed elicitation ID extraction to correctly use JSON-RPC request ID
- Fixed elicitation response format to only include content when present
- Fixed response delivery mechanism for HTTP-based transports

### Documentation
- Updated main README with MCP 2025-06-18 as primary version
- Consolidated feature list under "MCP 2025-06-18 (Latest)"

### Dependencies
- Updated faraday from 2.13.4 to 2.14.0
- Updated faraday-follow_redirects from 0.3.0 to 0.4.0
- Various dev dependency updates

### Developer Experience
- Enhanced CI configuration and workflows

## 0.8.1 (2025-09-17)

### Breaking Changes
- **Resources API**: Updated resources implementation to fully comply with MCP specification
  - `list_resources` now returns `{ 'resources' => [...], 'nextCursor' => ... }` hash format on both client and server levels
  - `read_resource` now returns array of `ResourceContent` objects instead of hash with 'contents' key

### New Features
- **Full MCP Resources Specification Compliance**:
  - Added `ResourceContent` class for structured content handling with `text?` and `binary?` methods
  - Added `ResourceTemplate` class for URI templates following RFC 6570
  - Implemented cursor-based pagination for `list_resources` and `list_resource_templates`
  - Added `subscribe_resource` and `unsubscribe_resource` methods for real-time updates
  - Added support for resource annotations (audience, priority, lastModified)
  - Binary content properly handled with base64 encoding/decoding
  - All transport types (stdio, SSE, HTTP, streamable_http) now have consistent resource support

### Improvements
- **Code Quality**: Refactored `Client#read_resource` to reduce cyclomatic complexity
  - Extracted helper methods: `find_resource_on_server`, `find_resource_across_servers`, `execute_resource_read`
  - Improved code maintainability and readability
- **ServerHTTP**: Added complete resource methods that were previously missing
- **ServerHTTP**: Added prompts support (`list_prompts` and `get_prompt`)
- **Examples**: Updated echo_server_client.rb to use new ResourceContent API
- **Examples**: Enhanced echo_server_streamable.py with full resource features

## 0.8.0 (2025-09-16)

### New Features
- **MCP Prompts and Resources Support**: Added full support for MCP prompts and resources (#31)
  - Implemented `list_prompts` and `get_prompt` methods for prompt management
  - Implemented `list_resources` and `read_resource` methods for resource access
  - Added support for both text and blob resource types

### Bug Fixes
- **Tool Caching**: Fixed issue with caching tools that have the same name from different servers (#342ff55)
  - Tools are now properly disambiguated by server when cached
  - Improved tool resolution to prevent conflicts between servers

### Dependencies
- Updated openai from `9e5d91e` to `003ab1d` (dev dependency) (#30)
- Updated rubocop from 1.77.0 to 1.80.2 (dev dependency) (#28)
- Updated gemini-ai from 4.2.0 to 4.3.0 (dev dependency) (#25)

### Developer Experience
- Updated examples with improved error handling
- Enhanced CI workflow configuration

## 0.7.3 (2025-09-01)

### Bug Fixes
- **Streaming JSON Parsing**: Fixed streaming JSON parsing improvements for better handling of partial data chunks
- **SSE Connection**: Enhanced server-sent events connection reliability for real-time notifications

### Dependencies
- Updated faraday from 2.13.1 to 2.13.4
- Updated ruby-openai from 8.1.0 to 8.3.0 (dev dependency)
- Updated openai gem to latest version (dev dependency)
- Updated rdoc from 6.14.1 to 6.14.2 (dev dependency)

### Developer Experience
- Improved CI configuration and permissions
- Enhanced examples with better cleanup and error handling
- Fixed Rubocop style violations

## 0.7.2 (2025-07-14)

### Bug Fixes
- **JSON-RPC Parameter Handling**: Fixed SSE transport compatibility with Playwright MCP servers by reverting JSON-RPC parameter handling to not send `null` for empty parameters
- **Logger Formatter Preservation**: Fixed issue where custom logger formatters were being overridden in server implementations

### Transport Improvements
- **HTTP Redirect Support**: Added automatic redirect following (up to 3 hops) for both SSE and HTTP transports via faraday-follow_redirects gem

### Examples and Testing
- **FastMCP Integration**: Added complete FastMCP echo server example demonstrating Ruby-Python MCP interoperability
- **Comprehensive Logger Tests**: Added 29 new test cases covering logger functionality across all server types

### Developer Experience
- **Protocol Version Consistency**: Updated all examples and configurations to use MCP protocol version 2025-03-26
- **Enhanced Documentation**: Improved example scripts with better error handling and user guidance

## 0.7.1 (2025-06-20)

### OAuth 2.1 Authentication Framework
- Added comprehensive OAuth 2.1 support with PKCE for secure authentication
- Implemented automatic authorization server discovery via `.well-known` endpoints
- Added dynamic client registration when supported by servers
- Implemented token refresh and automatic token management
- Added pluggable storage backends for tokens and client credentials
- Created `MCPClient::OAuthClient` utility class for easy OAuth-enabled server creation
- Added runtime configuration support via getter/setter methods in `OAuthProvider`
- Included complete OAuth examples and documentation

### HTTP Transport Improvements
- Refactored HTTP transport layer using template method pattern for better code organization
- Eliminated code duplication across HTTP and Streamable HTTP transports
- Improved OAuth integration across all HTTP-based transports
- Enhanced error handling and authentication workflows
- Added proper session management and validation

### MCP 2025-03-26 Protocol Support
- Updated protocol version support to 2025-03-26
- Enhanced Streamable HTTP transport with improved SSE handling
- Added session ID capture and management for stateful servers

### Documentation and Examples
- Added comprehensive OAuth documentation (OAUTH.md)
- Updated README with OAuth usage examples and 2025 protocol features
- Enhanced oauth_example.rb with practical implementation patterns
- Improved code documentation and API clarity

## 0.6.2 (2025-05-20)

- Fixed reconnect attempts not being reset after successful ping
- Added test verification for nested array $schema removal
- Improved integration tests with Ruby-based test server instead of Node.js dependencies

## 0.6.1 (2025-05-18)

- Improved connection handling with automatic reconnection before RPC calls
- Extracted common JSON-RPC functionality into a shared module for better maintainability
- Enhanced error handling in SSE and stdio transports
- Improved stdio command handling for better security (Array format to avoid shell injection)
- Refactored server factory methods for improved parameter handling
- Streamlined server creation with intelligent command and arguments handling
- Unified error handling across transports

## 0.6.0 (2025-05-16)

- Server names are now properly retained after configuration parsing
- Added `find_server` method to retrieve servers by name
- Added server association in each tool for better traceability
- Added tool call disambiguation by specifying server name
- Added handling for ambiguous tool names with clear error messages
- Improved logger propagation from Client to all Server instances
- Fixed ping errors in SSE connection by adding proper connection state validation
- Improved connection state handling to prevent ping attempts on closed connections
- Enhanced error handling for unknown notification types
- Simplified code structure with a dedicated connection_active? helper method
- Reduced parameter passing complexity for better code maintainability
- Enhanced thread safety with more consistent connection state handling
- Added logger parameter to stdio_config and sse_config factory methods

## 0.5.3 (2025-05-13)

- Added `to_google_tools` method for Google Vertex AI API integration (by @IMhide)
- Added Google Vertex Gemini example with full integration demonstration
- Enhanced SSE connection management with automatic ping and inactivity tracking
- Improved connection reliability with automatic reconnection on idle connections
- Expanded README.md with updated documentation for SSE features

## 0.5.2 (2025-05-09)

- Improved authentication error handling in SSE connections
- Better error messages for authentication failures
- Code refactoring to improve maintainability and reduce complexity

## 0.5.1 (2025-04-26)

- Support for server definition files in JSON format

## 0.5.0 (2025-04-25)

- Enhanced SSE implementation and added Faraday HTTP support
- Updates for the HTTP client and endpoints
- Updates session handling
- Remove parameters from ping
- Code improvements

## 0.4.1 (2025-04-24)

- Server ping functionality
- Fix SSE connection handling and add graceful fallbacks

## 0.4.0 (2025-04-23)

- Added full "initialize" hand-shake support to the SSE transport
  - Added an @initialized flag and ensure_initialized helper
  - Hooked into list_tools and call_tool for JSON-RPC "initialize" to be sent once
  - Implemented perform_initialize to send the RPC, capture server info and capabilities
  - Exposed server_info and capabilities readers on ServerSSE

- Added JSON-RPC notifications dispatcher
  - ServerBase#on_notification to register blocks for incoming JSON-RPC notifications
  - ServerStdio and ServerSSE now detect notification messages and invoke callbacks
  - Client#on_notification to register client-level listeners
  - Automatic tool cache invalidation on "notifications/tools/list_changed"

- Added generic JSON-RPC methods to both transports
  - ServerBase: abstract rpc_request/rpc_notify
  - ServerStdio: rpc_request for blocking request/response, rpc_notify for notifications
  - ServerSSE: rpc_request via HTTP POST, rpc_notify to SSE messages endpoint
  - Client: send_rpc and send_notification methods for client-side JSON-RPC dispatch

- Added timeout & retry configurability with improved logging
  - Per-call timeouts & retries for both transports
  - Tagged, leveled logging across all components
  - Consistent retry and logging functionality

## 0.3.0 (2025-04-23)

- Removed HTTP server implementation
- Code cleanup

## 0.2.0 (2025-04-23)

- Client schema validation
- Client streaming API fallback/delegation
- ServerHTTP initialization
- Added list_tools, call_tool with streaming fallback
- HTTP error handling
- Support for calling multiple functions in batch
- Implement find_tool
- Tool cache control
- Added ability to filter tools by name in to_openai_tools and to_anthropic_tools

## 0.1.0 (2025-04-23)

Initial release of ruby-mcp-client:

- Support for SSE (Server-Sent Events) transport
  - Robust connection handling with configurable timeouts
  - Thread-safe implementation
  - Error handling and resilience
  - JSON-RPC over SSE support
- Standard I/O transport support
- Converters for popular LLM APIs:
  - OpenAI tools format
  - Anthropic Claude tools format
- Examples for integration with:
  - Official OpenAI Ruby gem
  - Community OpenAI Ruby gem
  - Anthropic Ruby gem