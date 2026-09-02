# Changelog

## Unreleased — MCP 2026-07-28

Groundwork for the 2026-07-28 protocol revision (stateless, per-request
metadata). Each feature lands in its own PR; this section accumulates them.

### Cacheable results (`ttlMs` / `cacheScope`)

- **Round 13.** An uncacheable `resources/read` (a multi round-trip retry,
  no `ttlMs`, `ttlMs` 0, stale on arrival) is not stored and drops the
  per-URI slot only when it still holds the entry that read set out to
  replace — another context's private entry, or one a later fetch
  installed meanwhile, stays. The freshness probe carries the routing
  headers a real modern POST carries (`MCP-Protocol-Version`,
  `Mcp-Method`, `Mcp-Name`), so host middleware that authenticates by them
  answers as for the request. Cached tools, prompts and resources lists
  are handed out as copies (`MCPClient::DeepCopy`, mixed into `Tool`,
  `Prompt`, `Resource` and `ResourceTemplate`): a caller cannot change the
  cache or the `x-mcp-header` derivation through what it received.

- **Freshness hints honoured.** `server/discover`, `tools/list`,
  `prompts/list`, `resources/list`, `resources/templates/list` and
  `resources/read` results carry `ttlMs` and `cacheScope`
  (`MCPClient::CachedResult`). Cached lists are served only while fresh
  (`now < received + ttlMs`; `0` means re-fetch on every access, a negative
  or malformed value counts as `0`) and re-fetched on access once stale —
  never in the background. An auto-paginated list is as fresh as its
  shortest-lived page. Legacy servers (no `ttlMs`) keep the previous
  cache-until-notification heuristic. `MCPClient::Client`'s own caches
  consult every server's freshness before serving.
- **Reads.** `resources/read` results that carry a `ttlMs` are cached per
  URI while fresh (never the result of a multi round-trip retry; a read
  without `ttlMs` — every legacy server — is not cached), and dropped on
  `notifications/resources/updated` for that URI or on
  `notifications/resources/list_changed`; list caches (tools, prompts,
  resources and resource templates) are marked stale by their
  `list_changed` notification regardless of TTL.
- **Authorization context.** An entry cached with `cacheScope: "private"`
  is bound to the `Authorization` the request that produced it went out
  with, and is served (or offered as a stale fallback) only while the
  transport would send the same credentials (on HTTP+SSE, the credentials
  of the JSON-RPC POST that fetched it); a cached list is served only from
  the entry that carries its hint, never from a copy left over from an
  earlier request, and a re-fetch that fails before it applies its own
  credentials has no private stale fallback; every cached result is
  forgotten on `cleanup` / reconnect. A `resources/read` result that is not
  an object is rejected, and a read's TTL runs from its receipt. On a 2026-07-28 server a list or page
  without `ttlMs` counts as immediately stale, as the spec asks; legacy
  servers keep the cache-until-notification heuristic.
- **Stale on failure.** When a re-fetch fails transiently (5xx, connection
  or transport error) the stale list is served with a warning, as the spec
  allows — the stale copy is the entry captured before the re-fetch, judged
  by that entry's own authorization context. A fetched list attaches only to
  the entry its own fetch recorded (a later fetch wins), each request returns
  its own list rather than a re-read of the transport's copy, and an
  `Authorization` header added by Faraday middleware (`faraday_config`) is
  part of the cache context: the header a request actually went out with is
  recorded after it was sent, and the freshness probe runs the middleware
  stack without sending anything; a request that fails before any response
  under such middleware has the context recorded right before the adapter
  sent it (a request that never got that far has no private stale
  fallback), and the freshness probe runs only the request phase of the
  middleware, so a host `raise_error` does not blind it. Raw list pages
  are never handed from one fetch to another, and HTTP+SSE dates resource
  and template lists from receipt. `server.cache_info(:tools | :prompts |
  :resources | :templates | :discover)` and `cache_info(:read, uri)` expose
  `ttl_ms`, `cache_scope`, `received_at` and `fresh`.
- **Review round 11.** The freshness probe models its request on a real
  JSON-RPC POST (endpoint, body of the last method sent) so path- or
  body-aware host middleware answers as it would for the request, and it
  gives up rather than guess (no private entry is served) when host
  middleware overrides `call` and cannot be run without sending; the
  read-cache epoch is taken once the session exists, so the first read on
  a fresh connection is cached; a fetch that completes after its entry was
  invalidated never overwrites the newer entry installed meanwhile; the
  per-URI read cache keeps only results that are fresh on arrival, drops
  expired ones as new ones are stored and holds at most `MAX_CACHED_READS`
  (oldest evicted first). The freshness probe models the request of the
  operation whose cache is checked (`tools/list`, `resources/read` with its
  URI, ...) rather than the last request sent, so middleware that picks
  credentials by method or body answers for that request; a result stays
  bound to the credentials of its own request even when its SSE-framed
  response dispatched a notification whose callback sent another request
  on the same thread; an old fetch spanning two contexts never replaces
  the entry a newer fetch installed after an invalidation.

### Subscriptions (`subscriptions/listen`)

- **Long-lived notification streams.** `server.listen(notifications:)` and
  `Client#listen(notifications:, server:)` open a `subscriptions/listen`
  request with a `SubscriptionFilter` (`tools_list_changed`,
  `prompts_list_changed`, `resources_list_changed`, `resource_subscriptions`,
  `task_ids`; snake_case or camelCase) and return an `MCPClient::Subscription`.
  The request itself is meant to outlive every other one the client sends — its
  response is the server's *closing* of the stream — so the deadline the
  lifecycle asks for is on the **acknowledgment** instead: a listen the server
  has not acknowledged within `ack_timeout` (default: the transport's read
  timeout) is cancelled and the handle closed carrying a
  `RequestTimeoutError`, rather than staying `:pending` for the life of the
  process with nothing to tell the host why. Pass `ack_timeout: false` to wait
  for ever, or a number of seconds to bound it per request; an acknowledged
  subscription runs for as long as the server keeps it either way.
  The server's `notifications/subscriptions/acknowledged` records the subset
  it honours (`acknowledged`, `unsupported`); notifications tagged with
  `io.modelcontextprotocol/subscriptionId` are demultiplexed to the
  subscription's listeners and still flow through the client's regular
  notification handling (cache invalidation, `on_notification`). A response
  to the listen request is the server's graceful closure, a server
  `notifications/cancelled` for the listen id a teardown; `close` cancels —
  by closing the SSE response stream on Streamable HTTP (no
  `notifications/cancelled`, and the reader is never killed mid-delivery) or
  by sending `notifications/cancelled` on stdio. Listener callbacks run on
  the subscription's own dispatcher thread, in arrival order, never on the
  transport's reader: a listener may issue requests of its own (re-reading
  the resource that changed, say) without blocking the stdio reader that
  would have to deliver its response. That queue is filled by the peer, so it
  is bounded in both dimensions the peer controls: the number of queued
  notifications (`Subscription::MAX_PENDING_NOTIFICATIONS`) and the bytes
  they retain (`Subscription::MAX_PENDING_NOTIFICATION_BYTES`). A count on
  its own is not a memory bound — a Streamable HTTP listen event may approach
  32 MiB and a stdio line has no inbound limit at all, so a thousand of them
  behind one slow listener is tens of gigabytes. Overflow starts at whichever
  ceiling the arriving notification would breach, and rests on two rules that
  are the same rule seen from each end: **every queued notification is charged
  exactly what it retains**, and **every eviction gives up an entry whose
  removal relieves the pressure that caused it** — the byte budget considers
  only the entries charged against it, the count ceiling considers them all,
  and the slot the oversized payload occupies only its own occupant. So
  overflow always makes progress and no signal is ever spent on pressure that
  discarding it cannot relieve. (Earlier revisions decided the two by rules
  that disagreed — a payload exempt from the charge but not from eviction —
  and the queue could give up the only notice of a resource and still be over
  budget.) What a notification retains includes its method name, and the
  charge counts it: serializing the params alone let a peer tag `{}` with a
  multi-megabyte method name for two bytes apiece and put
  `MAX_PENDING_NOTIFICATIONS` of them behind a slow listener without ever
  reaching the byte ceiling. *Which* of the candidates goes is chosen by
  **identity** — the notification's method with the `uri` or `taskId` it
  names — rather than by
  arrival order: the oldest candidate about the same thing as the arriving
  one, or failing that the oldest of whichever thing has the most queued. One
  stream can carry a mixed filter, and dropping the oldest entry would throw
  away the only queued update for a quiet resource to keep newer ones for a
  busy one, with nothing left to tell the listener to re-read it — the loss
  the ceiling exists to prevent. Every MCP notification is a "look again"
  signal about state the host re-reads for itself, so a later notice of the
  same thing still carries what the dropped one said; the only notice of
  another thing does not. A notification larger than the whole byte budget is
  not charged against it and is held in a slot of its own, of which there is
  only ever one: the peer can hold one such payload behind a stalled listener,
  never a queueful of them, while nothing is lost merely for being large and
  the oversized payload can neither be displaced by ordinary traffic nor
  displace it — the retained total stays within the budget plus one peer-sized
  payload. Blocking the reader instead would restore the deadlock the
  dispatcher exists to prevent, and dropping the newest would leave the host
  acting on a stale view for good.
  Drops are counted in `dropped_notifications` and named once in the log,
  with `pending_notifications` and `pending_notification_bytes` reporting the
  current depth. A closing response the client cannot recognize (an unknown
  `resultType`, a missing result, a scalar) fails the subscription with an
  `InvalidResultError` rather than ending it gracefully, the way every other
  response is checked — and so does one that is recognized but is not a
  completion: `input_required` is valid on `tools/call`, `resources/read` and
  `prompts/get` alone, and means the request has *not* finished, so reporting
  one as a graceful closure told the host the server had finished with a
  stream it had not. On stdio a `notifications/cancelled` never precedes the
  listen request it names: a `close` racing the write of a listen leaves that
  id for the writer to cancel once it is actually on the wire, since "the
  cancelled request MUST have been previously issued". The requested filter is copied and frozen when the
  subscription is created: the listen request is built from it on a background
  thread after `listen` returns, and again on every reconnect, so a caller that
  kept the array it passed could otherwise change what goes out. `unsupported`
  reads the acknowledgment's *values*, not its keys — a `resourceSubscriptions`
  echoed with none of the requested URIs, or a flag acknowledged as `false`, is
  a field the server declined while naming it. What the server granted is
  stored as a frozen copy, arrays and strings included: the notification it
  arrives in is handed on to `on_notification` and to the subscription's
  listeners, and host code editing it in place used to rewrite the
  subscription's own record of the watch — adding a URI the acknowledgment had
  left out was enough to make a waiting `subscribe_resource` report success.
- **Routing order: bookkeeping, cache invalidation, delivery, host callback.**
  A listener runs on the subscription's dispatcher thread, so queuing its
  delivery makes the notification visible at once: a listener reacting to
  `notifications/tools/list_changed` (or the prompts/resources equivalents)
  by calling a cached list method could run before the transport and client
  caches that notification invalidates had been dropped, and read the very
  entry it says is stale. Routing drops both caches first and delivers
  afterwards, making that a guarantee rather than a race the scheduler
  usually happens to win. The client's own caches get there through a hook of
  their own — `ServerBase#on_cache_invalidation`, run at the invalidation step
  — rather than riding on the host callback: while they did, moving that
  callback to the end (below) moved the client's `tool_cache`, `prompt_cache`
  and `resource_cache` with it, and the guarantee held only for the
  transport's caches. Only the invalidation moved forward; everything else the
  client does with a notification (logging, progress callbacks, task status)
  is host code or leads to it and stays behind the delivery. Paths that fan a
  notification out without routing a subscription announce the hook too — the
  legacy SSE parser, and the synthetic `tools/list_changed` a `Mcp-Param-*`
  header-mismatch refresh emits — so no transport is left invalidating on only
  one of the two. A transport that emits no such hook — a host-supplied adapter
  written against the older interface, which fans notifications out through
  `on_notification` alone — keeps the invalidation on `on_notification`, ahead
  of everything else there. Which of the two it is is decided per
  notification, by whether the hook actually ran for it: asking whether the
  transport *has* the hook answered yes for every `ServerBase` subclass, so
  such an adapter silently stopped invalidating anything at all. The host's `on_notification` callback now runs
  **last**, after the delivery has been queued, because it is the only step
  that can block: it is host code driven by the peer and it runs on whatever
  thread is routing — on stdio the process's sole stdout reader — so a
  callback that issues a synchronous request of its own waits there for a
  response only that reader can deliver. Running it ahead of the delivery put
  the queueing back behind exactly that, reinstating for the host callback the
  block that moving the listeners off the reader had removed; the queueing
  itself costs nothing to move ahead of it, since the routing thread hands the
  notification to the dispatcher rather than to the listeners. Being last, the
  callback can prevent nothing. An exception escaping it used to take the
  notification down with it — the subscription's listeners never saw something
  the host's own handler had already been told about — and, on stdio, the
  transport's reader thread with it; it is now logged. Nor can the callback
  stop or redirect a delivery by editing the payload it is given: it is handed
  the very hash the delivery was routed by, and by the time it can touch it
  the subscription has been resolved and the entry queued.
- **Transports.** On Streamable HTTP (and plain HTTP) the listen POST runs
  on its own thread; a stream that ends without the closing response is
  re-opened with a new id (backoff 1 s → 30 s, which a cancellation
  interrupts) while the host still wants it, and stops reporting `active?`
  for as long as it is between streams — no server-side subscription exists
  then. Closing the response stream is the cancellation, and it is reliable
  at every point of the race now: the stream's HTTP session is handed over
  before its socket is opened, under the same lock the cancellation takes, so
  a `close` either stops the request before it goes out or finds the session
  it has to close — and a session still opening its socket, which cannot be
  closed at all, refuses to send for a closed subscription however long its
  connect takes, while the cancellation keeps coming back for it and leaves
  its thread registered for a later `cleanup` to close. Once `close` or
  `cleanup` returns, either no listen request went out or the stream is
  closed.
  A listen POST answered with a 5xx is a dropped stream rather than a
  rejection: the status was already classified `TransientServerError`, but
  the call site finished the subscription and returned "closed", which the
  re-open loop does not retry — so a brief 500 or 503 killed a long-lived
  subscription for good while a connection failure or a read timeout on the
  same request re-opened it. It now takes the same backoff, through the
  `raise_error` middleware path as well. A 4xx, and an authorization
  challenge, still end the subscription.
  A listen answer is framed by its `Content-Type`: the single JSON object a
  server MAY answer with instead of a stream is no longer run through the SSE
  parser, which used to swallow a compact body followed by a blank line and
  turn a clean close into a dropped stream and a typed rejection into a
  generic one. Transport shutdown closes every stream cooperatively —
  including one caught between two listen ids, which belonged to neither
  registry and would re-open onto a transport that was already gone — and no
  longer kills the reader threads or waits for them under the transport lock
  they need themselves. On stdio, subscriptions share the channel and are
  correlated by subscription id; when the process is
  re-established (after `cleanup` or an unexpected exit) every open
  subscription is re-sent with a new id. A process that exits on its own is
  re-established straight away while subscriptions are open, rather than on
  the next request: a subscription is a standing request the host does not
  repeat, so a host that is only waiting for notifications would otherwise
  leave every one of them `:reconnecting` for ever. An exit *during* the
  initialization that established the process counts as one: the reader used
  to skip the handling outright while `@initialized` was still false, which is
  exactly what a replacement that answers the discovery probe and then dies
  leaves behind — initialization went on to mark the dead connection
  initialized and re-send the open subscriptions to it, the failed writes were
  deferred back onto the "wait for the next process" queue, and with that
  reader already gone there was no one left to establish one. The reader now
  waits out an initialization still in flight and then handles the exit; the
  lock it waits on is that initialization finishing, and it can deliver no
  further responses by then, so whatever the initializing thread is waiting
  for is already bounded by its own timeout. A restart that fails, or
  a process that exits again less than `SUBSCRIPTION_RESTART_MIN_INTERVAL`
  after the subscriptions were re-sent to it (a crash loop), closes those
  subscriptions with the error instead, so the host learns from
  `closed?`/`error` rather than waiting on a stream that is not coming back.
  Only an exit counts against that bound. Every teardown stamps the moment the
  process ended, but a `cleanup` the host asked for is not the server
  crashing: a host that closes the transport and reconnects — which a
  `cleanup`/request cycle does, and so does re-authenticating or
  re-configuring a server — did so within the interval and had the very
  subscriptions the reconnect exists to carry across closed for a crash that
  never happened.
  The record of the process that carried them answers that one question and
  is spent by asking it: it used to outlive the loop it described, so a
  subscription opened directly on the replacement — a process that then ran
  healthily for hours — was closed as another crash loop the moment that
  process exited. A session that is handed nothing asks nothing and spends
  nothing, since the subscriptions are still open on the session it replaced.
  That interval runs from the moment the process *received* them — not from
  the moment the restart was attempted, or a server whose start-up alone
  outlasts the interval (an `npx -y …` command fetching its package, say)
  would be credited with its whole handshake, read as healthy every time and
  respawned for ever; and it is stamped before the re-sent requests go out,
  since the process can exit while they are still going to it. Both moments
  are recorded on the record of that process itself, and the question is asked
  in the one place the subscriptions are handed over, so the bound no longer
  depends on which thread re-established the process: a host request that
  raced the reader's restart used to leave the transport's "restarting" flag
  and readiness stamp unwritten, and every later exit then read a
  crash-looping server as a healthy one. A restarted process that negotiates a
  pre-2026-07-28 version cannot carry the subscriptions either: they end with
  a `CapabilityError` instead of staying `:reconnecting` for ever with the
  host never told. A listen write that fails only *after* a restart has
  re-opened the same subscription under a new id no longer tears that healthy
  stream down — the failure cleanup names the id the write went out with —
  and one that fails on a subscription a session is being handed leaves it for
  the next process rather than closing a stream the restart was in the middle
  of re-sending. That question is asked of the subscription, not of its
  state: taking the new listen id has already moved it from `:reconnecting`
  to `:pending` by the time an EPIPE (or a nil stdin) raises, so the guard
  keyed on the state never fired on the hand-over itself — the one case the
  spec says MUST be re-sent. A superseded failure is reported to the caller
  when the stream that replaced it has itself failed, instead of handing back
  a closed handle with no exception.
  The subscriptions waiting for a process live on one queue behind one lock
  and appear on it at most once, by identity. Two paths write to it — a
  `cleanup` moving the open subscriptions across, and a hand-over whose listen
  write failed putting one back — and the second lands inside the window the
  first leaves between taking the registry snapshot and writing it.
  Concurrent `concat`/`<<` on a bare Array is undefined in MRI: the same
  window could lose the entry, stranding a stream the spec says MUST be
  re-sent with no session to re-send it and no `cleanup` to find it again, or
  duplicate it and send two listen requests for one subscription. Scanning
  that Array with `equal?` while another thread grew it did not make the
  append safe.
  A cancellation now names what is actually outstanding: `close` sends
  `notifications/cancelled` for every listen request the client wrote for that
  subscription on the live process, not only the id the subscription happens
  to be on — a second listen for it left the server serving the first stream
  with the client no longer able to refer to it — while ids written to a
  process that has since been torn down are forgotten rather than cancelled on
  the process that replaced it. That accounting now holds for a write that
  lands late, too: a listen request goes to the pipe it was recorded against
  rather than to whichever process is current when the write finally happens.
  Reading the live stdin at the write instead let a listen still pending when
  the process exited be written to the *replacement*, whose teardown had
  already forgotten that id — so the server served a second stream the client
  could no longer name, and `close` cancelled only the restart's own listen.
  The mirror image on Streamable HTTP is refused rather than deferred: a
  `listen` paused between readying the connection and sending the request used
  to register and POST after a `cleanup` had closed the (then empty)
  registries, leaving a live stream on a disconnected transport that no later
  `cleanup` could find — `cleanup` returns at once on a transport that is
  already disconnected. The stream is claimed under the very lock the close
  takes, so a `cleanup` either finds it or stops it, and a `listen` it stops
  raises `ConnectionError` instead of returning a handle to a stream that was
  never opened.
  Taking a new id is atomic with closure on both, so a `close` racing with a
  re-open either stops it or cancels the id that went out — never leaving
  the server holding a stream the client can no longer cancel. Events are
  read with SSE line endings (CR, LF or CRLF, in any mix). Legacy sessions
  refuse `listen` with a `CapabilityError`.
- **`subscribe_resource`/`unsubscribe_resource`** map onto one listen stream
  per URI (`resourceSubscriptions`) on modern servers, still gated on the
  `resources.subscribe` capability; legacy servers keep
  `resources/subscribe`. The mapping lives in shared code but each transport
  decides its own era (`modern?`, not the configured `protocol` mode), so
  the gate is pinned per transport: on stdio, and on both HTTP transports.
  `subscribe_resource` still answers `true`, but only once the server has
  acknowledged the stream *for that URI*: a rejected `subscriptions/listen`,
  a stream the server closes before acknowledging, an acknowledgment that
  omits the URI, or no answer within the transport's `read_timeout` raises
  (the server's own error, otherwise `ResourceReadError`) instead of
  reporting a subscription that was never established. Every *later*
  acknowledgment of that stream is rechecked against the URIs it is mapped
  to as well: a stream re-opened after a dropped HTTP connection or a stdio
  restart is a new listen request the server holds no state for and MAY
  acknowledge more narrowly, so one that comes back without the URI closes
  the subscription and drops the mapping instead of leaving
  `live_resource_subscription` reporting a watch nothing is honouring; a
  later `subscribe_resource` then opens a fresh stream and raises if that
  one is refused too. That recheck reads the URI-to-stream mapping, which is
  written only after the acknowledgment the subscriber waited for, so the
  acknowledgment that stands is checked once more with the mapping in
  place — a narrowing that landed in the window between the two used to be
  stored as a live watch. Both checks now wait for the acknowledgment of the
  listen request the stream is *currently* on, and a stream is reused only
  while the server's word on that URI stands: one whose replacement request
  was in flight — after an HTTP connection dropped, or the stdio process it
  was on restarted — counted as live merely for not being closed, so
  `subscribe_resource` answered `true` before that request had been
  acknowledged, or rejected. A subscription with no acknowledgment has no
  unacknowledged URIs either, which is how the recheck read one as a watch.
  A mapped stream that is given up on is closed, not merely unmapped: one
  that never became a live watch — its replacement was refused, or nothing
  answered within the acknowledgment timeout — was left reconnectable with
  nothing pointing at it, so it could come back and deliver the same updates
  beside the stream `subscribe_resource` opened to replace it, and
  `unsubscribe_resource`, which looks for a stream through the mapping that
  had just been dropped, could no longer find or cancel it.
  Reuse now asks whether the server is honouring the URI on that stream
  *now*, not what the stream that dropped had been granted: the last
  acknowledgment stays on record until the replacement takes a new id after
  the backoff, and reading it as the current grant reported a watch for the
  whole of an HTTP re-open backoff or a stdio handshake, on a stream the
  server no longer held and whose replacement might reject the URI. The
  subscriber waiting on its own listen request still gets its answer — a
  connection that drops the instant the acknowledgment lands does not unanswer
  it, or the call would wait out its acknowledgment timeout for a grant it
  already had — and "nothing re-sent yet" is told from "re-sent and not yet
  acknowledged" by a flag written at the acknowledgment and at the taking of
  each new listen id, rather than by which of them a reconnect reaches first.
  Opening and closing the stream for one URI is serialized, so concurrent
  subscribers share a single stream that `unsubscribe_resource` really
  closes.

### Multi round-trip requests (InputRequiredResult)

- **Server-to-client interactions on modern servers.** `tools/call`,
  `resources/read` and `prompts/get` may now be answered with
  `resultType: "input_required"`. The client fulfils every entry of
  `inputRequests` through the handlers it already has — `elicitation/create`
  via the elicitation handler, `sampling/createMessage` via the sampling
  handler, `roots/list` from the client's roots — and retries the original
  request as a new request (new id, same params) carrying `inputResponses`
  keyed like the requests and the opaque `requestState` echoed verbatim
  (omitted when the server sent none). A result without `inputRequests` is
  retried after a short pause (see below); the round trip never leaks into
  other requests, and every attempt is rebuilt from the caller's own params,
  so a continuation field the server stops sending is dropped.
- **Capabilities.** Modern requests once again declare `elicitation`
  (`form` and `url`), `roots` (without `listChanged`) and `sampling` (with
  `tools` when opted in) when the corresponding handler is registered. Only
  declared capabilities are used: a `sampling/createMessage` input request
  carrying `tools` or `toolChoice` fails the round trip (the sampler is never
  invoked) unless the host opted into `sampling.tools`, and
  `notifications/roots/list_changed` is sent only to a session that declared
  `roots` — registering the plain HTTP handlers, which serve the modern round
  trips, does not make a legacy plain HTTP session a recipient.
- **URL-mode elicitation answers keep `_meta`.** An ElicitResult carries
  `_meta` in every mode; a URL-mode answer now passes the handler's `_meta`
  through (on both the round-trip and the legacy server-request path) while
  `content`, which is form-mode only, is still stripped.
- **Recovery keeps the round trip.** Transport-level recovery of an attempt
  (retries, version renegotiation, the HeaderMismatch refresh, a re-issued
  stream) re-sends the attempt's own `inputResponses`/`requestState`. An
  answer that carries only `requestState` (an out-of-band interaction still
  in progress) is retried with a growing pause (0.5 s doubling to 5 s) rather
  than in a tight loop. The plain HTTP transport now accepts the elicitation,
  roots and sampling handlers so `MCPClient::Client` can serve round trips on
  it too.
- **Limits and errors.** More than 10 consecutive `input_required` answers,
  an input request this client cannot honour (unknown method, no handler,
  handler error) or a malformed `inputRequests` raise
  `MCPClient::Errors::InputRequiredError` (exposing `input_requests` and
  `request_state`) without a retry; `input_required` on any other method is
  an `InvalidResultError`. `server/discover` is not one of the three methods
  that may be answered with `input_required` either: such an answer is
  refused before any protocol version or capability it carries is applied or
  cached, so a probe can never adopt a version out of an unfinished result
  and hand that result back as the first heartbeat.

### Custom headers from tool parameters (`x-mcp-header`)

- **`Mcp-Param-{name}` headers.** On a modern Streamable HTTP (or plain HTTP)
  session, arguments of tool parameters annotated with `x-mcp-header` are
  mirrored into request headers on `tools/call`: strings as-is (Base64
  sentinel when not header-safe), integers in decimal, booleans lowercase;
  absent or null arguments produce no header. The tool list is fetched on
  demand when a tool is called before `tools/list`. An argument that cannot
  be mirrored (a float, an object, an integer outside the IEEE754 safe
  range) fails the call locally with `ValidationError`.
- **The `Mcp-Param-*` namespace is client-owned on a modern session.** It is
  derived from the call's arguments and from nothing else, so a header of
  that name supplied in `headers:` is dropped from modern requests (matching
  HTTP's case-insensitive field names, whatever spelling was configured)
  before the computed ones are attached. Previously a configured
  `Mcp-Param-Region` survived a call that omitted `region`, standing for an
  argument the spec requires to produce no header — which no `tools/list`
  refresh could correct. Legacy sessions, where the namespace has no
  protocol meaning, keep sending it.
- **Invalid annotations reject the tool.** A definition whose `x-mcp-header`
  is empty, not an HTTP field-name token, not case-insensitively unique, on a
  non-primitive property, or not statically reachable through `properties`
  keys alone (inside `items`, composition/conditional keywords, `$defs`, a
  `$ref` target or at the root) is excluded from `tools/list` with a warning
  naming the tool. `MCPClient::HeaderParams` exposes the validation and
  extraction (`validate_schema`, `annotations`, `headers_for`).
- **HeaderMismatch recovery.** A `-32020` rejection of `tools/call` triggers
  one `tools/list` refresh and a single retry with recomputed headers; the
  refresh is announced upward as a `tools/list_changed` notification so the
  client-level cache picks up the new definition, and a refresh that fails
  keeps the original rejection. It composes with the modern re-issue of a
  request whose response stream broke, in either order: a HeaderMismatch
  retry whose stream closes is re-issued, and a re-issue rejected for its
  headers still refreshes `tools/list`. Each recovery is spent once, so a
  call is sent at most three times. Transport list caches now follow
  `list_changed` notifications, and a refresh cannot be overwritten by a
  stale concurrent fetch.
- **A result is validated against the definition its call went out under.**
  The transport records the definition each `tools/call` request derived its
  `Mcp-Param-*` headers from (`MCPClient::CalledToolDefinition`), and
  `call_tool` checks `structuredContent` against that one — the retry's
  refreshed definition after a HeaderMismatch, and otherwise the definition
  in force when the request was sent. A `tools/list_changed` that merely
  races the call (on the response stream, or from another thread) no longer
  moves the schema: previously it made the client re-list and validate
  against a definition the server never used, which both invented
  `ValidationError`s in `:strict` mode and let a looser replacement pass a
  result the answering definition forbade. A call that host code nests inside
  another — from a notification listener, or a handler for a server-initiated
  request — records into a slot of its own.
- Mirroring is a MUST: a call whose tool definition cannot be fetched fails
  rather than going out without headers. Instance data inside a schema
  (`default`, `examples`, `enum`, `const`) is never treated as an annotation.
- stdio ignores the annotation entirely, as the spec allows.

### Streamable HTTP modern mode (no sessions, request metadata headers)

- **Era detection over HTTP** (Streamable HTTP "Backward Compatibility").
  Both HTTP transports POST `server/discover` first. A `DiscoverResult`, or a
  recognized modern JSON-RPC error in a 400 body (`UnsupportedProtocolVersion`
  is retried with an advertised version; `HeaderMismatch` and
  `MissingRequiredClientCapability` are surfaced), marks the server modern. A
  404 carrying -32601 is a modern server without discovery support
  (tolerated, capabilities unknown). Any other 4xx — or a 2xx that is not a
  `DiscoverResult` — is a legacy server: the `initialize` handshake runs as
  before. **Both verdicts are cached** for the transport, so a server once
  found modern never gets `initialize` on a later connection, however a later
  probe fails. `protocol:` and `discover_timeout:` are accepted by
  `http_config`, `streamable_http_config`, the factory and `MCPClient.connect`.
- **Only a genuine rejection settles the era.** A probe whose exchange never
  completed says nothing about the server: 401/403, 5xx (including a 5xx
  surfaced as an exception by user-configured `raise_error` middleware, which
  now raises `TransientServerError` like the default response path), timeouts,
  an oversized body and a broken response stream all propagate instead of
  recording a (cached, permanent) legacy verdict. The probe itself goes
  through the modern re-issue path: a `server/discover` whose response stream
  dies is re-sent once with a new request id before the failure is reported.
- **A modern verdict survives the transport detector.** A modern-but-
  incompatible server now raises `MCPClient::Errors::ModernServerError` (a
  `ConnectionError` subclass), which `MCPClient.connect` re-raises for an
  ambiguous URL instead of falling through to the legacy SSE and HTTP+POST
  transports. `MCPClient.connect(url, protocol: :modern)` likewise no longer
  falls back to those legacy-only transports. This covers a server whose
  `DiscoverResult` (or well-formed `-32022` list) advertises no version this
  client speaks: discovery settled the era even though it settled no version,
  so the era is cached and a later connection never sends `initialize`.
- **Request metadata headers.** Every modern POST carries
  `MCP-Protocol-Version` (equal to the body's `_meta`), `Mcp-Method` and, for
  `tools/call`, `prompts/get` and `resources/read`, `Mcp-Name` (also for the
  tasks extension's `taskId`). Values that are not header-safe use the
  `=?base64?…?=` sentinel encoding (`encode_header_value`).
- **No protocol-level session.** Modern connections send no
  `Mcp-Session-Id`, open no GET event stream, send no DELETE, and never use
  `Last-Event-ID`. Closing the stream is the cancellation signal (no
  `notifications/cancelled` on timeout). Server-initiated JSON-RPC requests on
  a response stream are dropped with a warning; SSE comment keep-alives are
  ignored. `ping` maps to `server/discover` and `log_level=` to the
  per-request `_meta` level.
- **A broken response stream is re-issued, `tools/call` included** (changelog
  major change 9: "A broken response stream loses the in-flight request;
  clients **MUST** re-issue it as a new request with a new request ID"). The
  rule has no per-method exception, and this revision makes the broken stream
  itself the cancellation signal the server MUST act on — it "**MUST NOT** send
  any further messages" for the cancelled request — so the replacement request
  is what the protocol expects rather than a blind replay. Exactly one
  re-issue is made, for every method: `with_retry` never retries a
  `ResponseStreamClosedError`, so a second broken stream surfaces as that
  error instead of looping (previously an idempotent method could multiply
  the replacement by the retry budget). The other no-replay guarantees are
  unchanged — a 5xx, a timeout, an oversized body or an expired session
  during `tools/call` is never re-sent, because in none of those cases was
  the server told to stop.

  All three ways a stream can be lost take that one path: a break between SSE
  events, a break inside an event's JSON, and **a socket that dies mid-body**.
  The last is what a broken stream actually looks like on the wire — Faraday
  raises rather than handing back a truncated body — and it previously
  surfaced as a plain `ConnectionError` with no replacement request. A socket
  failure that proves the request never reached the server (connection
  refused, DNS, unreachable network), and a notification (which has no
  response to lose), still raise `ConnectionError`.
- **Plain HTTP + SSE response streams.** `ServerHTTP` now advertises and
  parses `text/event-stream` responses. On a **legacy** stream the server may
  still send requests, so a `ping` is answered with an empty result and any
  other server-initiated method with JSON-RPC `-32601` rather than dropped in
  silence; on a **modern** stream they are dropped, as 2026-07-28 requires. A
  stream that carries only a response to a *different* request is treated as
  a lost stream on a modern server (both HTTP transports) instead of
  completing the call with someone else's result; the lenient
  single-response fallback remains for legacy servers, which echo ids loosely.
- **Reconnection is serialized.** `ensure_connected` now holds the transport
  monitor across its "is the connection up?" check and the
  cleanup/reconnect that follows, so a caller that observed a dead connection
  can no longer tear down the connection another caller established in the
  meantime (which terminated its session and re-ran the era probe).

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