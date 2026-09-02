# Changelog

## Unreleased — MCP 2026-07-28

Groundwork for the 2026-07-28 protocol revision (stateless, per-request
metadata). Each feature lands in its own PR; this section accumulates them.

### JSON Schema handling

- **Round 12.** A `$id` resource the anchor index could not reach (beyond
  the depth bound) counts as truncation and a reference from a schema the
  index does not know is unresolvable, never resolved against the document
  root; a branch of `not` / `oneOf` / `if` is undecided only while an
  unevaluated assertion that applies to the instance remains — annotations
  (`format`, `contentSchema`) and assertions of another instance type
  decide nothing, so a branch settled by its evaluated keywords is a full
  verdict (`ANNOTATION_KEYWORDS`, `UNSUPPORTED_ASSERTIONS_BY_TYPE`).
- **Definite verdicts (round 13).** A branch that fails on an evaluated
  assertion leaves no uncertainty behind, `anyOf` passes as soon as any
  branch definitely passes (whatever the order of an undecided one), and
  `oneOf` fails as soon as two branches definitely pass; uncertainty only
  counts where it could still change the outcome.

- **Dialects.** `MCPClient::SchemaValidator` treats a schema without
  `$schema` as JSON Schema 2020-12, accepts 2020-12, 2019-09 and draft-07
  (`SUPPORTED_DIALECTS`), and reports any other declared dialect as an
  error ("dialect ... is not supported") instead of validating permissively.
  `SchemaValidator.check_schema` reports why a schema is unusable; an
  unusable `outputSchema` is a structured-content violation (warning or
  `ValidationError` in `:strict` mode) and an unusable `inputSchema` is
  logged once per tool.
- **`$ref`.** References inside the schema document (`#`, `#/$defs/...`,
  `#/definitions/...`, any JSON pointer, with `~0`/`~1` and percent
  escapes) are resolved, recursively, with a hop limit. A `$ref` to a
  network URI, another document, a `urn:` or `file:` is never dereferenced
  and makes the schema unusable rather than permissive; an unresolvable
  local `$ref` is an error too.
- **Composition.** `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`,
  `prefixItems` (2020-12) / tuple-form `items` (draft-07, 2019-09) and
  boolean schemas (root or nested) are evaluated (they are no longer
  reported as unsupported keywords); under draft-07 a `$ref` replaces its
  siblings. Resource bounds apply: nesting depth (`MAX_SCHEMA_DEPTH`),
  total subschemas (`MAX_SUBSCHEMAS`, boolean subschemas included), `$ref`
  chain length (`MAX_REF_DEPTH`, checked at preflight too), nodes visited
  (`MAX_NODE_VISITS`), errors produced (`MAX_ERRORS`) and the
  per-validation time budget; hitting a bound aborts the validation with
  a single error, never with a pass, even under `not` or `oneOf`. Values
  quoted in messages are clipped, and the client sanitizes and bounds the
  violation text it logs or raises. Errors inside `anyOf` / `oneOf` /
  `not` / `if` candidates are only a verdict and do not count toward the
  error bound; positional keywords follow the dialect (`prefixItems` in
  2020-12, where an `items` array is invalid; an `items` array in draft-07
  and 2019-09); a present but malformed `$schema` makes the schema
  unusable; an `outputSchema` of `false` is preserved by `Tool.from_json`.
  Plain-name fragments are scoped to their schema resource (a subschema
  whose `$id` is a URI starts a new resource; `#name` never crosses into or
  out of an embedded resource), a draft-07 `$id` is a plain name only when
  it is a pure fragment, keywords beside a draft-07 `$ref` contribute no
  anchors, `$defs` belongs to 2019-09 / 2020-12 and `definitions` to
  draft-07 (the other bag is unknown to the dialect and not walked, though
  JSON pointers into it still resolve and what a `$ref` reaches is
  preflighted), and the unsupported-keyword scan stops at the subschema
  bound and runs once per tool output schema. Pointer fragments are
  relative to the schema resource the `$ref` sits in (`#` and `#/$defs/x`
  inside an embedded resource are that resource's), the unsupported-keyword
  scan follows local `$ref`s (a target in a definition bag the dialect does
  not walk is scanned too), an `if` without `then` or `else` is not
  evaluated, and a document with more than `MAX_STRUCTURAL_OBJECTS` objects
  is rejected while it is being normalized rather than copied whole.
  The keyword grammar follows the dialect (`DIALECT_KEYWORDS`): a keyword
  the dialect does not define (`prefixItems` or `$dynamicRef` in draft-07,
  `dependencies` or `additionalItems` in 2020-12, ...) is ignored rather
  than shape-checked or reported, draft-07 `dependencies` accepts property
  name arrays, `exclusiveMinimum` / `exclusiveMaximum` are numbers in
  every supported dialect (draft-07 included; the draft-04 boolean form is
  a schema problem) and are applied independently of `minimum` /
  `maximum`, each validation error counts once toward `MAX_ERRORS`,
  percent-encoded plain-name fragments are decoded before the anchor
  lookup, a draft-07 `$ref` hides its sibling applicators at
  preflight too, plain-name fragments (`#name`) resolve to `$anchor` /
  `$dynamicAnchor` (2019-09, 2020-12) or `$id: "#name"` (draft-07), and an
  external `$recursiveRef` (2019-09) makes the schema unusable like an
  external `$dynamicRef`. `Tool#structured_output?` is true for any
  provided `outputSchema`, the empty schema `{}` included, so such a tool's
  successful result must carry `structuredContent`.
- **structuredContent.** Any JSON value is accepted, including `null`:
  presence is decided by the `structuredContent` key, and the value —
  object, array, scalar or null — is validated against the output schema.
  The `x-mcp-header` annotation is ignored by the validator.
- **Resources and anchors (round 9).** Plain-name anchors come only from
  schema positions the dialect walks: a definition bag the dialect does
  not define (`definitions` under 2020-12, `$defs` under draft-07) stays
  pointer-addressable but is never a source of names, and nothing beside a
  draft-07 `$ref` but its `definitions` is. An embedded resource root (a
  subschema whose `$id` is a URI) may declare its own `$schema`, which is
  the dialect for that resource at preflight, in the anchor index, in the
  keyword scan and during validation (a malformed or unsupported embedded
  `$schema` makes the schema unusable like at the root; a `$schema` that is
  not at a resource root is ignored). The structural bound counts array
  members too, so a wide array of boolean schemas is rejected before it is
  copied, and numeric bound errors clip the values they quote.
- **Reference chains and anchors (round 10).** A `$ref` chain is
  followed by where each hop lands, not by the text of its fragment, so a
  reference entering an embedded resource whose own `$ref` reuses the same
  fragment is not a cycle (a chain returning to a schema it reached still
  is); an `$anchor` / `$dynamicAnchor` (or draft-07 fragment `$id`)
  declared more than once within one schema resource makes the schema
  unusable instead of binding references to whichever declaration was met
  first. A resource (`$id` URI) reached through a definition bag the
  dialect does not walk names its own anchors (nothing outside it sees
  them); the structural bound counts object entries too, so a wide map of
  leaf values is rejected before it is copied, and the copy runs under the
  validation deadline.
- **Undecided branches and bounds (round 11).** A branch the validator
  can only partly evaluate (it carries an unsupported assertion such as
  `multipleOf`) is no verdict for `not`, `oneOf` or `if`: it is neither a
  match nor a mismatch, so `{"not": {"multipleOf": 2}}` never rejects a
  value (anyOf / allOf keep treating a partial pass as a pass, the
  permissive direction). A document nested deeper than
  `MAX_SCHEMA_DEPTH` schema levels can hold is rejected while it is
  copied instead of keeping the rest raw; the client keys its once-per
  schema checks by the schema object, never by hashing a peer document
  whole. Under draft-07 a URI `$id` beside a `$ref` is ignored with the
  other siblings (it starts no resource); an anchor index that stopped at
  its bound before reaching every object makes the schema unusable; a JSON
  Pointer token with `~` not followed by `0` or `1` is unresolvable (RFC
  6901).
- **Decided compositions and effective assertions (round 14).** `anyOf`,
  `oneOf` and `allOf` stop evaluating branches once the outcome is
  definite (any pass, two passes, the first failure), so a later branch
  can no longer abort a decided validation (`{"anyOf": [true, {"$ref":
  "#"}]}` accepts everything); an unevaluated assertion counts as
  uncertainty under `not` / `oneOf` / `if` only when it can still change
  the result (`minContains` / `maxContains` need `contains`,
  `additionalItems` a tuple `items`, and tautological values such as
  `additionalProperties: true`, `uniqueItems: false`, `minProperties: 0`
  or an empty dependency map decide nothing); a referenced target is
  bounded by its own lexical depth, not the referring location, a boolean
  target is not charged per reference, and boolean subschemas obey the
  depth bound.
- **Positions and assertions (round 15).** Lexical depths follow each
  resource's own dialect, so the bounds verdict cannot depend on key
  order; the unsupported-keyword scan reads a referenced target at its
  own lexical depth; a boolean a pointer reaches obeys the depth bound at
  its own position; a tautological `additionalItems` beside a tuple
  decides nothing; an input schema the validator cannot interpret asserts
  nothing (the call goes out without the `required` check).

### Authorization (RFC 9207 issuer validation, client registration)

- **Issuer validation.** `OAuthProvider#start_authorization_flow` records
  the selected authorization server's `issuer` with the PKCE record;
  `complete_authorization_flow(code, state, iss:)` (and
  `OAuthClient.complete_oauth_flow(..., iss:)`) validates the response's
  `iss` per RFC 9207 before the code reaches any token endpoint: a present
  `iss` must equal the recorded issuer byte for byte (no URL
  normalization), an absent one is rejected when the server advertises
  `authorization_response_iss_parameter_supported`, and a request without a
  recorded issuer fails closed. `OAuthProvider#authorization_error_message`
  applies the same check to error responses, and `BrowserOAuth` forwards
  the callback's `iss` and refuses to display a mismatching error.
  `ServerMetadata` parses `authorization_response_iss_parameter_supported`.
- **Dynamic Client Registration.** Registrations carry an
  `application_type` (`native` for loopback and custom-scheme redirect
  URIs, `web` otherwise; `application_type:` overrides), retry once with the
  other type when the server rejects the redirect URI for it, surface the
  server's `error` / `error_description`, and log that DCR is deprecated in
  favour of Client ID Metadata Documents.
- **Authorization server binding.** `ClientInfo` gained `issuer` and
  `registration_type` (`pre_registered`, `dynamic`, `cimd`); `Token` gained
  `issuer`. Credentials and tokens are bound to the issuer that produced
  them: the code is redeemed only at the authorization server recorded for
  the request (a server change mid-flow ends the flow), a token or refresh
  token is never presented to another authorization server, a dynamic
  registration is redone for a new authorization server (and the old token
  dropped through the optional `delete_token` storage method, see
  OAUTH.md), pre-registered credentials for another issuer raise a
  `ConnectionError` instead of being reused, credentials persisted before
  these fields existed are bound on first use (as `dynamic` when they carry
  `client_id_issued_at`, else `pre_registered`), and Client ID Metadata
  Document client ids stay portable. Authorization server metadata whose
  `issuer` is not the identifier it was fetched for is rejected (RFC 8414
  Section 3.3, byte for byte). Error responses are `state`-bound and their
  description is sanitized; `client_metadata[:application_type]` counts as
  the explicit application type. The `iss` advertisement of the request's
  authorization server is recorded with the PKCE record and decides how a
  response without `iss` is treated; credentials stored without a binding
  are bound to the authorization server they were stored under (a Client ID
  Metadata Document client is recognized by its client id); a token that
  records no issuer is never refreshed once the authorization server
  changed, and a 401 challenge naming another authorization server retires
  the stored token at once. A retired token that storage cannot delete is
  re-stored bound to its former issuer; a metadata document naming another
  issuer is skipped in favour of the next well-known candidate; a portable
  client id is reused only where the authorization server advertises
  `client_id_metadata_document_supported`; storage backends that persist
  plain hashes (like the `FileTokenStorage` example) are read back through
  `from_h`; and a freshly issued token is never mistaken for a retired one
  that happened to use the same bytes. A backend that refuses to forget a
  dynamic client no longer stops an authorization server switch; a token
  persisted before issuers were recorded is bound to the authorization
  server cached alongside it on first use; no token is presented while the
  authorization server is unknown (the next challenge discovers it, and the
  discovery is remembered in-process for backends that do not persist
  metadata); an error response that matches no stored state is rejected.
  Records persisted before issuers were recorded, with no cached
  authorization server to prove where they came from, are retired on
  discovery (a dynamic registration and its token) rather than bound to
  whatever discovery finds; pre-registered and portable credentials are the
  host's configuration and are bound on first use.
  `OAuthProvider#validate_authorization_response!(state, iss:)` checks a
  success callback before anything is shown, and `BrowserOAuth` answers a
  rejected callback with the error page instead of "successful"; loopback
  redirect URIs are recognized semantically (`127.0.0.0/8`, `::1` in any
  spelling, `localhost`) for the `application_type`. A retired dynamic
  registration is stamped as retired before it is deleted, so a backend
  that cannot delete never lets it be adopted for the server discovery
  finds; serialized `ClientInfo` records are read back through `from_h`
  like every other record. A persisted record without a
  `registration_type` counts as a dynamic registration (RFC 7591's
  `client_id_issued_at` is optional, so its absence proves nothing);
  credentials a host pre-registers should be stored with
  `registration_type: 'pre_registered'` so they survive an authorization
  server change as a reported mismatch instead of a re-registration. The
  client id an authorization request was made with is recorded with its
  PKCE record, and the code is redeemed only with those credentials: a
  record swapped in shared storage during the flow (another client id, or
  credentials bound to another authorization server) ends the flow
  instead of reaching the token endpoint. An unbound record swapped in
  meanwhile counts as changed credentials; the callback precheck
  (`validate_authorization_response!`) also fails when a challenge or
  cached metadata names another authorization server or the stored
  credentials changed, so the browser never sees a success page for a
  callback the flow rejects; in-process retirement markers are scoped by
  issuer, so another provider sharing the storage may store the same
  opaque bytes issued by a new authorization server. A PKCE record that
  names no client (persisted by an earlier version, or by a backend that
  dropped the field) fails closed like one without an issuer. A 401
  challenge retires the stored token only when its metadata would pass
  discovery's checks (the resource matches, the advertised authorization
  server is an acceptable URL) and is otherwise refused whole, like a
  challenge with an unacceptable metadata URL; the browser precheck also
  fails while a refused or still-unfetched challenge is outstanding;
  `Token#to_h` keeps every legacy key and adds `issuer` only when set;
  a retirement marker is lifted only once the replacement token was
  persisted. A successfully fetched challenge naming the same
  authorization server does not fail the callback precheck; a challenge
  advertising no authorization server is refused; a later validated
  challenge supersedes a refused one (the refused document is forgotten);
  peer-controlled metadata values are sanitized in refusals. An
  authorization server switch leaves records another provider already
  bound to the new server alone, and the redirect URI an authorization
  request was made with is recorded with its PKCE record and used for the
  code exchange. Accepting a new challenge metadata URL forgets the
  previous document and any refusal before the fetch, so a failed fetch
  leaves the flow waiting on the URL the current header named (the
  precheck fails and discovery retries it) instead of completing against
  stale state. A challenge naming the authorization server a stored token
  is already bound to (another provider sharing the storage finished the
  switch) retires nothing, and that token is presented at once: a
  validated pending challenge is the authoritative server for tokens, as
  it already is for discovery. A token inside its early-refresh window is
  presented when the refresh — or the discovery it needs — cannot run,
  provided it is still current after that discovery (one it retired is
  not); only an expired token whose refresh fails yields none; metadata
  bodies that are not JSON objects are a discovery failure. While a
  challenge's metadata URL is pending and unresolved no cached token is
  presented; the next access retries that URL first — before the token is
  read, so a record that retry retired is never written back — and judges
  the token by what the document names. Only a 401 challenge's refusal
  stays authoritative for later discovery: a peer URL refused during
  speculative well-known discovery is fetched again next time, so a
  document the operator fixes no longer leaves the provider failing for
  its lifetime. An authority-less URL (`https:foo`) is refused for want of
  a host before it can retire the stored token, and the code is redeemed
  with the redirect URI recorded for the authorization request (RFC 6749
  Section 4.1.3): a token endpoint whose error names another redirect URI
  is reported as a mismatch rather than retried with the peer's value
  (records made before the URI was recorded keep the legacy retry). A
  peer-advertised URL's host is now classified by parsing it as an address
  rather than by string prefixes, so IPv4-mapped and expanded IPv6
  spellings (`[::ffff:169.254.169.254]`, `[0:0:0:0:0:0:0:1]`) and the
  shorthand IPv4 forms resolvers accept (`127.1`, `0x7f.0.0.1`,
  `2130706433`) are refused like the dotted-quad ones. A refused challenge
  now withholds the cached token as well: while it stands, `access_token`
  and `apply_authorization` present nothing, just as discovery refuses the
  cached authorization server. A speculative protected-resource document
  whose authorization server is refused no longer supplies the scopes of
  the next request, and authorization server metadata persisted before
  `authorization_response_iss_parameter_supported` was recorded is
  rediscovered rather than read as "the server does not send `iss`". A
  peer-advertised host is classified by the name a resolver would look up,
  so a fully qualified spelling (`169.254.169.254.`, `127.0.0.1.`,
  `localhost.`) is refused like the undotted one; and the browser callback
  precheck (`validate_authorization_response!`) and
  `authorization_error_message` read an unrecorded `iss` advertisement the
  way the completion does — rediscovering the answer, and assuming the
  advertisement when it cannot be had — so a legacy in-flight callback
  never shows a success page (or the peer's error text) for a response the
  token exchange then rejects. A peer-advertised host is percent-decoded
  before it is classified — `URI#hostname` does not decode, but the HTTP
  client dials the decoded name — so `169.254.169.254%2e`,
  `127%2e0%2e0%2e1`, `%31%32%37.0.0.1` and `localhost%2e` are refused like
  the plain spellings, and a host that is still not a hostname after
  decoding is refused outright. A redirect URI's host is read the same way
  for the registered `application_type`, so a shorthand or fully qualified
  loopback callback (`http://127.1/cb`, `http://127.0.0.1./cb`) registers
  as `native` instead of as a `web` client whose plain-HTTP redirect URI
  the authorization server may reject. The local-development exception for
  peer-advertised URLs is now loopback-only: it applies when the
  *configured* server URL is loopback AND the advertised target is
  loopback too, so a server on a private network (`10.0.0.5`,
  `app.internal`, `printer.local`) no longer turns off the HTTPS
  requirement or the local-address refusal, and not even a loopback server
  can send the client to `169.254.169.254` or another private address. One
  definition of loopback now serves the SSRF classifier, the registered
  `application_type` and the plain-HTTP exception for configured and
  discovered endpoints: RFC 6761 `*.localhost` names count as loopback
  (`http://app.localhost:3000/cb` registers as `native`), and an HTTP
  authorization or token endpoint on a loopback spelling (`http://127.1`,
  `http://localhost.`, `http://[::ffff:127.0.0.1]`) is accepted like
  `http://127.0.0.1`. A host is case-folded after its percent escapes are
  decoded, so `%4Cocalhost` ("Localhost") classifies as loopback rather
  than as an unknown public name. When that rediscovery of an unrecorded
  `iss` advertisement returns a *different* authorization server, the
  callback precheck and `authorization_error_message` now reject the
  response as "the authorization server changed during the flow" — the
  same refusal `complete_authorization_flow` makes — instead of reading it
  as "the server advertises `iss`", so a legacy in-flight callback carrying
  the recorded issuer no longer shows a success page for a flow the
  completion refuses; a rediscovery that cannot be made is still unknown
  rather than a change. An endpoint discovered in authorization server
  metadata is now classified exactly like a peer-advertised URL, so the
  plain-HTTP exception applies only to a local stack (a loopback endpoint
  and a loopback configured server) and a discovered endpoint may not name
  a loopback, private or link-local address: metadata from a public
  authorization server can no longer collect the authorization code at
  `http://app.localhost:3000/steal` or at an internal address. A protected
  resource document rejected as not this resource's — or naming no
  authorization server — no longer supplies the scopes of a later flow, as
  a refused authorization server URL already did not. And a token record a
  storage backend left behind for a deleted token (a backend without
  `delete_token` is asked to store `nil`, and one that persists hashes
  writes `nil.to_h`) is no token: it is never presented as a bare
  `Bearer ` bound to the current authorization server. The
  `FileTokenStorage` example and the storage documentation remove the
  record for a `nil` token instead of serializing it. A `200` from the
  token endpoint that carries no `access_token` (or an empty one) is now a
  protocol error rather than a credential, as RFC 6749 Section 5.1
  requires: the code exchange raises a `ConnectionError` instead of storing
  an empty token and reporting success, and a refresh fails — keeping the
  still-valid token it was about to replace — instead of overwriting it
  with bytes that would go out as a bare `Bearer `; `access_token` and
  `apply_authorization` apply the same check to whatever they are about to
  present. `authorization_error_message` now makes the checks the success
  path makes before it displays anything, so the `error_description` of
  authorization server A is withheld once an outstanding, refused or
  server-changing 401 challenge — or shared storage — moved the flow to B,
  instead of being shown for a callback the completion rejects. And a
  stored client record without a `client_id` (what a hash-persisting
  backend reads back after the `set_client_info(server_url, nil)` fallback
  deleted an issuer-less dynamic client) is no client at all: a new dynamic
  registration is made instead of an authorization request with an empty
  `client_id`. Those checks now read the response's type as well as its
  presence: a token response carries a credential only when it is a JSON
  object whose `access_token` is a non-empty string, so `200 []` and
  `200 null` are a failed refresh (keeping the still-valid token) or a
  failed exchange instead of a `TypeError`, and `{"access_token": ["x"]}`
  no longer overwrites the stored token and goes out as
  `Authorization: Bearer ["x"]`. A registration response is held to the
  same standard (RFC 7591 Section 3.2.1): a `201` whose `client_id` is
  missing, empty or not a string fails the registration outright, so the
  flow ends before the browser is opened rather than after the user has
  already visited an authorization endpoint with no usable `client_id`.
  Finally, the in-process state a provider accumulates for one MCP server —
  the discovered-metadata fallback for backends that do not persist
  metadata, the memoized `supported_scopes`, the adopted, pending or
  refused 401 challenge and its scope, and the "authorization server
  changed" flag — is forgotten when the public `server_url=` setter
  retargets the provider, so a provider reused for another server
  discovers it instead of sending its authorization, registration and
  token requests to the previous server's endpoints. Retirement markers
  are kept: they name the issuer the bytes were retired for, not the
  resource URL, and stay true when two MCP servers share one
  authorization server. That type-strictness now covers every field of both
  responses, not only the credential each carries: a token response is read
  against the types RFC 6749 Section 5.1 gives its fields (`token_type` and
  `access_token` non-empty strings, `expires_in` an integer,
  `refresh_token` and `scope` strings) and a registration response against
  the types RFC 7591 Section 3.2.1 and Section 2 give theirs
  (`client_secret`, `token_endpoint_auth_method`, `scope`, `client_name`,
  `client_uri`, `logo_uri`, `tos_uri`, `policy_uri` and `application_type`
  strings, `client_id_issued_at` and `client_secret_expires_at` integers,
  `redirect_uris`, `grant_types`, `response_types` and `contacts` arrays of
  strings). A field of any other type fails the whole response the way a
  missing `access_token` does — a `ConnectionError` on the code exchange
  and on registration, a warning that keeps the still-valid token on a
  refresh — instead of a `NoMethodError` capitalizing
  `token_type: ["Bearer"]` into a header, a `TypeError` adding
  `expires_in: "3600"` to a `Time` after the still-valid token was already
  gone, or a `NoMethodError` asking a `redirect_uris` string for its
  `first` inside `register_client`. A `null` field still reads as an absent
  one, and `redirect_uris` the server echoes back empty (or omits) still
  falls back to the requested redirect URI. A stored client record whose
  `client_id` is not a non-empty string is likewise no client — the same
  test the stored token's bytes get — so a hash-persisting backend that
  reads one back registers a new client before the browser opens instead of
  starting a flow the callback then rejects. In the same reading of RFC 7591
  Section 3.2.1, a `client_secret_expires_at` of `0` means a secret that does
  not expire, so a client registered with one is no longer treated as having
  expired at the epoch and re-registered on every flow. A field of the right
  JSON type is still not a usable credential, and the read path is now as
  strict as the wire path: `access_token` and `token_type` must carry bytes an
  HTTP header can hold, so a `200` whose token contains CR/LF (or any control
  byte) is refused instead of being stored and turned into a two-line
  `Authorization` value, and a record storage reads back whose `token_type` is
  empty, of another type or control-bearing presents no token at all instead
  of crashing `String#capitalize`. A `refresh_token` is a credential too — `""`
  is refused like a missing one rather than persisted over the refresh token
  the client already holds — and a registration response's `redirect_uris`
  must be usable redirect URIs (absolute and parseable), so `[""]` is a
  reported registration failure instead of a browser opened at
  `…&redirect_uri=&…`. An `authorization_response_iss_parameter_supported`
  that is not a JSON boolean (`"true"`, `1`, `{}`) is no answer at all and now
  fails closed — it is read as "advertised", so a callback without `iss` is
  refused — where before it counted as "not advertised"; a PKCE record
  carrying such a value defers to the authorization server's own metadata.
  Finally, every peer-supplied string that reaches a log line or an exception
  message — which `BrowserOAuth` renders on its error page — goes through one
  sanitizer (`MCPClient::Auth::PeerText`): a failed token exchange quotes a
  printable, bounded body instead of the raw one, and a body that is not JSON
  is described by position and size (`malformed JSON, at line 1 column 1,
  26 byte body`) rather than by the token the parser choked on. Those helpers
  live on the OAuth classes themselves, so a rescue path can no longer raise
  `NoMethodError` over a helper only the JSON-RPC transports have — which is
  what a non-JSON `200` on a token refresh did, out of the very request the
  still-valid token should have served. Those helpers are now total: nothing
  a peer sends can raise out of them. Bytes that are not valid UTF-8 — a
  `400` body, an `error_description=%FF` a callback carries through
  `CGI.unescape`, or the undecodable fragment a `JSON::ParserError` message
  quotes — used to raise `ArgumentError` out of `String#gsub`, `String#strip`
  and the regexp match, so the sanitizer that exists to make peer bytes safe
  was the one thing those bytes could crash; they are replaced before
  anything looks at them, and the flow reports a `ConnectionError` (and the
  browser flow finishes) as it does for any other bad response. The type
  checks now cover the two metadata documents as well as the two response
  bodies: a protected resource document is read against RFC 9728 Section 2
  (`resource` a string, `authorization_servers` and `scopes_supported` arrays
  of strings) and an authorization server document against RFC 8414
  Section 2 (the endpoints strings, `scopes_supported`,
  `response_types_supported`, `grant_types_supported` and
  `code_challenge_methods_supported` arrays of strings), so a
  `scopes_supported` of `"mcp:read"` is a refused document rather than a
  `NoMethodError` out of `start_authorization_flow` — and a
  `code_challenge_methods_supported` of `"S256 …"` is no longer read as PKCE
  support because a String answers `include?("S256")`. The two boolean
  advertisements keep their fail-closed reading. A cached record a
  hash-persisting backend reads back is held to the same standard where it
  is used: PKCE support requires an array, and a `scopes_supported` that is
  not one contributes no scopes instead of crashing `join`. Client
  authentication now follows the method the authorization server registered:
  RFC 7591 Section 2 makes `client_secret_basic` the default when a
  registration response names none, so a registration that issues a secret
  is recorded as a confidential client instead of as `none` (a combination
  that authenticates nowhere), and the credentials go out in an
  `Authorization: Basic` header — form-urlencoded before they are base64'd,
  per RFC 6749 Section 2.3.1 — for `client_secret_basic`, in the body for
  `client_secret_post`, and not at all for a public client or for a method
  this client cannot present (which is logged). An authorization endpoint's
  own query string is retained when the authorization parameters are
  appended (RFC 6749 Section 3.1), so an endpoint of
  `https://as.example/authorize?tenant=acme` no longer loses its tenant. A
  persisted token record's expiry is validated before it is used in
  arithmetic: an `expires_in` that is not a number and an `expires_at` that
  is not a readable instant no longer raise a `TypeError` out of
  `access_token`, and — since an expiry that cannot be read is not "no
  expiry" — such a record reads as expired (through a storage round trip
  too), so it is refreshed or re-authorized rather than presented forever.
  No log line carries a credential at any level: the `Authorization` header
  is no longer logged even truncated, and the browser callback logs only the
  request path, never the query string that carries `code=`. And a
  registered `redirect_uris` must name a URI a callback could actually
  arrive on — an http(s) URL with a host, or an RFC 8252 Section 7.1
  private-use scheme with a path, and no fragment (RFC 6749 Section 3.1.2) —
  so `javascript:alert(1)`, `data:text/html,…` and a bare `http:` are a
  reported registration failure instead of a browser opened at them.
  Peer bytes are now made decodable where they are *parsed*, not only where
  they are printed: a total sanitizer only helps the text that reaches it,
  and `String#gsub`, `String#match`, `Regexp#match?`, `String#split` and
  `String#strip` all raise `ArgumentError` on bytes that are not valid
  UTF-8. So the `unauthorized_client` body matched for a `redirect_uri`
  mismatch, the `WWW-Authenticate` header masked and matched for its
  `Bearer` challenge segment (in `OAuthProvider` and in the HTTP transports
  alike) and the callback query string `CGI.unescape` hands back are scrubbed
  before a pattern is run over them, without the truncation and
  control-stripping a message needs but a parser cannot have. A token
  endpoint `400` whose `error_description` is not UTF-8 now raises the
  `ConnectionError` it always should have, a `401`/`403` challenge with an
  undecodable parameter is still classified rather than crashing the code
  reading it, and a callback of `?code=%FF&state=%FE` finishes the browser
  flow. Metadata documents must now carry what their RFCs make REQUIRED, not
  merely avoid fields of the wrong type: an authorization server document
  without `issuer`, `authorization_endpoint` or `token_endpoint` (RFC 8414
  Section 2) and a protected resource document without `resource` (RFC 9728
  Section 2) are refused at discovery, cached nowhere and used for no scope
  resolution — previously such a document was accepted and the flow failed
  with a `URI::InvalidURIError` out of `start_authorization_flow` or
  `complete_authorization_flow`, after a dynamic client registration had
  already created a client at the authorization server. And a token record
  that carries an `expires_at` is answered by that `expires_at` alone:
  `expires_in` is the lifetime a token had when it was *issued* (RFC 6749
  Section 5.1) and a record read back from storage was not issued now, so it
  no longer stands in for a stored expiry that cannot be read.
  `Token.from_h(expires_in: 3600, expires_at: 'not a time')` — the shape
  `to_h` persists, with the one field this client depends on mangled — reads
  as expired and is refreshed, where before it came back with an hour of
  fresh lifetime. A refresh is now re-checked when its *response* arrives, not
  only when it is sent: a token refreshed at authorization server A that comes
  back after protected-resource metadata (or a `401` challenge) moved the
  resource to B is discarded — it is neither written over B's token in storage
  (which also resurrected a token the challenge had just retired) nor handed to
  the caller, who used to receive it and present `Authorization: Bearer` with
  A's bytes. Registration state became per authorization server, as SEP-2352
  requires: credentials are kept under the MCP server URL — the registration in
  use, where every storage backend and every record written by an earlier
  version already has them — *and* under a key of the issuing authorization
  server, `OAuthProvider#client_registration_key(issuer)`, so two authorization
  servers behind one MCP server no longer share one slot. Configuring the
  second no longer replaces the first, and returning to the first finds its
  registration instead of raising "these credentials belong to another
  authorization server"; a dynamic registration discarded on an authorization
  server change is kept under its own server's key, since it is still valid
  there, and reused if that server comes back. Storage keys stay opaque strings
  and nothing is migrated or moved, so a backend that treats the key as a
  string needs no change and a downgrade still finds every record. `token_type`
  must now name a type this client can present (RFC 6749 §7.1: "the client MUST
  NOT use an access token if it does not understand the token type"): a `DPoP`
  or `mac` token fails the code exchange, fails a refresh (keeping the
  still-valid token) and presents nothing when a storage backend reads one
  back, instead of going out as a bearer credential without the proof its type
  requires — and spelled `Dpop` by `String#capitalize` at that. The comparison
  is case-insensitive, and a response that names NO type is refused too: RFC
  6749 §5.1 makes `token_type` REQUIRED and defines no default — "Bearer" is
  one value it may carry (RFC 6750), not what its absence means — and §7.1
  forbids using a token whose type the client does not understand, which a
  client that was told no type does not. `200 {"access_token":"x"}` used to
  become `Authorization: Bearer x`; it is now a failed code exchange and a
  failed refresh that keeps the still-valid token. And a browser callback may
  carry each parameter only
  once (RFC 6749 §3.1): the parsed parameters are a Hash, where the last value
  of a repeated name silently won, so `?iss=attacker&iss=recorded` passed every
  check this client makes while a reader that takes the first value saw another
  authorization server; a callback repeating any parameter is now refused.
  An authorization request is now ONE record, as the specification asks: the
  `state`, the PKCE verifier, the expected issuer, the client id and the
  redirect URI are written together, and the callback's `state` is checked
  against the record the other checks read. Keeping the state in a slot of its
  own let two flows sharing a storage backend interleave their writes — A
  writes its PKCE, B writes PKCE and state, A writes its state — until A's
  state sat beside B's verifier, issuer and client, and A's authorization code
  was POSTed to B's token endpoint. The code exchange is re-checked when its
  response arrives, exactly as a refresh is: a response that comes back after
  the authorization server changed no longer stores its token over the new
  server's, and the cleanup that follows deletes only the records of the
  request that just ended, leaving a flow another provider started meanwhile
  waiting on the records it is waiting on. A refresh now presents the
  credentials an authorization request would be made with: a client secret
  rotated in the slot a host writes to — the MCP server URL — is used, where
  before an older copy under the authorization server's own key answered
  first and an authorization server that had revoked it replied
  `invalid_client`. Credentials pre-registered with the authorization server in
  use come ahead of a Client ID Metadata Document id, which is portable and so
  answered for every server, including one the host had given credentials of
  its own. A storage backend that cannot persist the registration a flow needs
  now raises: the write was best-effort for both the essential resource slot
  and the optional per-issuer copy, so a failure produced an authorization URL
  the user followed and a callback that answered "Missing PKCE or client info"
  after consent. Re-authorizing after an `insufficient_scope` challenge asks
  for the union of the scopes already requested and the ones the challenge
  names (MCP 2026-07-28 step-up flow, step 2), instead of the challenge's
  scopes alone — which traded the permissions every other operation depended on
  for the one being retried. And every redirect URI must be `localhost` or use
  HTTPS, as the MCP security considerations require: `http://app.example.com/callback`
  is refused where it is configured and where a registration response registers
  it, while plain HTTP on the loopback interface and RFC 8252 §7.1 private-use
  schemes (`com.example.app:/cb`, `com.example.app://cb`) are unaffected.

### Tasks extension (`io.modelcontextprotocol/tasks`)

- **A cleanup no longer restarts the lifetime counters (round 39).**
  `Client#cleanup` dropped everything the task registry held, the per-session
  counter that numbers task lifetimes included. Ending a connection is not
  ending a session — a 2026-07-28 HTTP transport is sessionless and its tasks
  outlive a cleanup — so the next creation in that session was numbered from
  zero again: a task handle retained across the cleanup named the task that
  replaced its own, and `cancel_task` through it cancelled the replacement.
  Meanwhile, before any replacement existed, `get_task` through that handle
  raised `TaskReplacedError` for a task still running on the server. What an
  id names is no longer bookkeeping that a cleanup forgets: the lifetimes and
  their counters stay (a session that really ends still takes its own with it,
  and the prune still bounds the ids of tasks nothing tracks), while the
  answered keys, pending answers and in-flight holds are dropped as before.
- **A task-delivered result is validated against the tool that produced it
  (round 39).** `call_tool_as_task` handed back a remote handle without the
  definition its creating `tools/call` went out under, and `get_task_result`
  then returned whatever the task delivered: with `validate_structured_content:
  :strict`, a `structuredContent` its tool's `outputSchema` forbids came back
  unchecked, where the same call through `call_tool` raised `ValidationError`.
  The handle a creation returns now carries that definition — the one the
  request was answered under, which a mid-call HeaderMismatch refresh may have
  replaced — and `get_task_result` validates against it, on the legacy
  `tasks/result` path too. A task named by a bare id identifies no tool and is
  returned unvalidated, as before.
- **A finished legacy task leaves nothing on the books (round 39).** A
  successful `tasks/result`, and a `tasks/cancel` answered with a terminal
  task, left the task's bookkeeping registered as live. Since the prune exempts
  ids whose bookkeeping is live, a host that submitted tasks and read their
  results — never calling `get_task` — grew both registries without bound and
  scanned an ever longer lifetime map on every creation. Both paths now release
  the task's bookkeeping the way a terminal poll does; an acknowledgement that
  still reports the task working leaves it alone.
- **An expired task is a missing task on `tasks/update` and `tasks/cancel`
  (round 39).** A 2026-07-28 server answering `{"code":-32602,"message":"Task
  has expired"}` produced a generic `TaskError`, and the task's bookkeeping
  survived, although the legacy matcher has always read an expiry as the task
  being gone. The modern matcher now agrees, so the documented `TaskNotFound`
  is raised and the bookkeeping is released. A `-32602` that rejects the
  supplied `inputResponses` is still the request's failure, not the task's.
- **The polling pace a server asks for is kept (round 39).** Every
  `pollIntervalMs` was capped at one hour, so a task paced at two hours was
  polled twice as often as its server asked — the opposite of what the polling
  SHOULD is for. The bound is now a day: it still catches an interval the clock
  cannot represent (or one that is merely absurd) without shortening a pace a
  server can plausibly mean.
- **A pre-write refusal keeps its type through the transports (round 39).** The
  guard that holds a task request to the lifetime it is about is checked
  immediately before the wire; a creation landing between the request path's
  own check and that one made the transports raise `TaskReplacedError` from
  inside their broad rescues, which turned it into a `TransportError` (stdio)
  or a `ToolCallError` (HTTP, SSE). A definite "this was not sent" then reached
  `update_task` as an ambiguous transport failure, which keeps the answers
  pending for a task that no longer exists. The three transports now re-raise
  it unchanged, as they already do for a session that ended under the request.
- **The lifetime cap forgets tasks that ended, never one that is running
  (verification round).** A creation recorded the id's lifetime but no
  bookkeeping for the task it started, and the prune exempts only ids whose
  bookkeeping is live — so a handle retained across 4096 further creations (an
  ordinary batch submission, the legacy `call_tool_as_task` included) was
  crowded out, and `get_task`, `update_task` and `cancel_task` through it
  raised `TaskReplacedError` although the server had neither expired nor
  replaced the task. A creation now records the task's own bookkeeping, so what
  the cap bounds is the ids of tasks this client no longer tracks — a terminal
  poll, a cancellation, a TTL expiry or a `TaskNotFound` makes an id prunable,
  and nothing else does.
- **On a 2026-07-28 server the error code decides whether a task is missing
  (verification round).** The legacy message heuristic ran first, so a
  `tasks/get` answered `{"code":-32603,"message":"Upstream credential
  expired"}` raised `TaskNotFound` and deleted the task's bookkeeping with it —
  losing the pending payload and answered keys of an unconfirmed
  `tasks/update`, so a resumed wait could neither retransmit nor avoid
  prompting the host again. A modern error that carries a JSON-RPC code is now
  read by the code: -32602 is the revision's missing-task answer, and every
  other code is a failed request that takes nothing of the task with it. Legacy
  servers, and errors with no code at all, keep the message heuristic.
- **Both new call paths validate against the definition the call went out
  under (verification round).** Neither `call_tool_as_task` on a modern server
  nor a task chunk of `call_tool_streaming` opened the slot that holds the
  definition a `tools/call` request carried, so the transport's record died
  with its own call and the re-resolve listed again — validating the result
  against a definition newer than the call's own (a list bounded by `ttlMs: 0`,
  or one whose TTL ran out during the call, re-fetches on every access). Both
  now wrap the call and its re-resolve exactly as `call_tool` does.
- **An input round that fails part way keeps the answers already given
  (verification round).** `fulfil_input_requests` answered the requests in
  order and threw the whole map away when one failed, and the wait then gave
  every key back — so a retry put a request the host (and possibly a person)
  had already answered to it a second time. The answers produced before the
  failure now travel with the `InputRequiredError`
  (`#answered_so_far`); the wait records them, leaves them pending for the next
  `tasks/update`, and hands back only the keys nobody answered.
- **A streaming `tools/call` is pinned while it is enumerated, not only while
  it is built (round 38).** Every built-in transport answers
  `call_tool_streaming` with a lazy `Enumerator`: round 37's pin only wrapped
  its construction and was gone by the time `each` reached the transport's
  `call_tool`, so a session that ended before the host consumed the stream ran
  the (possibly non-idempotent) tool in the replacement session while the task
  it answered with carried the sampled epoch — and `wait_for_task` then refused
  the very task that had run. The call now goes out under a pin taken inside
  the enumeration, in the thread that consumes it.
- **A task request is bound to the lifetime it is about, at the wire (round
  38).** `check_handle_lifetime!` was a preflight: a `CreateTaskResult` a
  concurrent call recorded after the check left the caller already past the
  guard, so `get_task` handed back the replacement's answer stamped with the
  old lifetime, `update_task` queued its answers in the replacement's state and
  sent them for it, and `cancel_task` cancelled the replacement. Every task
  request now carries a lifetime pin: the transport refuses to write it once
  the id names another task (checked where the session pin is, immediately
  before the wire), the answer is re-checked before it is acted on, and
  `update_task` resolves the bookkeeping its answers belong to in the same
  locked step as the check. The refusal is a `TaskReplacedError`, a new
  subclass of `TaskError`. On the read path a terminal or
  `TaskNotFound` answer now forgets only the bookkeeping of the lifetime it
  asked about: a bare-id `tasks/get`, and a detailed terminal handle that names
  no lifetime, no longer delete the keys of a task that took the id over since.
- **Task lifetimes stay distinguishable after a prune (round 38).** The
  lifetime of an id was a per-id count starting at 0, so evicting an id an
  outstanding handle still named (the map keeps 4096 ids) let a later creation
  under that id start at 0 again and the stale handle pass the guard, free to
  update or cancel the replacement. Lifetimes are now numbers of a
  monotonic per-session counter — one counter per session, so the map costs
  what it did — never reused and never restarted; a handle whose lifetime the
  prune forgot is refused rather than sent on a guess. Establishing a lifetime
  and reading it back is a single locked step as well: two concurrent creations
  of one id used to stamp both handles with the later of the two.
- **A lifetime is established for every creation, and every handle names the
  one it belongs to (round 37).** Round 36 gave each `CreateTaskResult` its own
  lifetime, but only recorded one when the id was already on the books: two
  creations under the same id with no wait in between — or one made after a
  terminal poll, a TTL expiry or a `TaskNotFound` had dropped the id's
  bookkeeping — left both handles naming the same lifetime, so the older one
  could still `update_task`, `cancel_task` or `wait_for_task` the task that
  replaced it. Every observed creation now moves the id's generation, on the
  legacy `call_tool_as_task` path as well, and `get_task` propagates the
  lifetime of the handle it was asked about instead of dropping it — a
  refreshed handle used to pass the replacement guard unchecked and operate on
  whatever the id named later. A detailed terminal handle waited on again after
  its id was reused no longer deletes the live task's bookkeeping, and a
  `tasks/cancel` the server answers with an unknown task forgets the keys of
  the session it was pinned to rather than those of a session that replaced it
  under the request. The lifetime counters, which by design outlive the tasks
  they belong to, are bounded: the ids created longest ago are dropped once
  more than 4096 are tracked, never one whose bookkeeping is still live.
- **A task-producing `tools/call` is written into the session it was sampled
  for (round 37).** `call_tool`, `call_tool_as_task` and `call_tool_streaming`
  now pin the creating call to the epoch they sampled for it, as every other
  task request already was. A transport that reconnects inside the request
  (a stdio child that exited, an HTTP 404 recovery) could otherwise run the
  tool in the replacement session while the returned task was stamped with the
  sampled one, and the wait would then refuse a task whose possibly
  non-idempotent tool had already run — inviting a duplicate retry.
- **The task bookkeeping cleanups are bounded (round 37).** A `tasks/update`
  that the server definitely rejected now gives back only the keys whose
  pending value it still owns: a newer answer for the same key, queued while
  the older update was on the wire, keeps its pending payload and its
  answered/submitted markers, so a later poll no longer puts the same input
  request to the host again. A task request through a custom transport that
  implements only the documented two-argument `rpc_request(method, params)` is
  bounded on the wall clock instead of silently losing its computed timeout, so
  a hung `tasks/get` can no longer block a wait that has no caller deadline for
  the task's whole lifetime; the session pin is applied inside that bound.
  Answers whose task another waiter already saw terminal or missing are
  discarded rather than delivered, and a malformed `pollIntervalMs` (a string,
  a negative integer) is now an `InvalidResultError` instead of silently
  becoming the default polling interval.
- **Every `CreateTaskResult` starts an isolated task lifetime, and closing a
  sessionless connection ends none (round 36).** A task id is unique within a
  session, so a server that answers with an id whose previous task is still on
  the client's books has ended that task and started another. The per-task
  bookkeeping is now stamped with a per-creation lifetime: the new task gets an
  answered set, an in-flight registry entry and a pending update of its own, so
  an input key a handler of the previous task is still presenting no longer
  suppresses the same key on the new one, and that handler's answer is
  discarded instead of being delivered to the new task through `tasks/update`.
  A wait whose task id was handed out again ends with a `TaskError` rather than
  reporting the new task's outcome, and a `Task` handle built from a
  `CreateTaskResult` names the task that creation started — `wait_for_task`,
  `get_task`, `get_task_result`, `update_task` and `cancel_task` refuse a
  handle whose task was replaced, as they already refuse one whose session
  ended. Conversely, an MCP 2026-07-28 HTTP transport has no session at all (no
  `initialize` handshake, no `Mcp-Session-Id`): its `cleanup` closes a
  connection, it does not reset a task namespace, so it no longer moves the
  session epoch. A task on such a server lives for its own `ttlMs` in the
  server's id namespace and survives a reconnect together with its answered
  keys and its undelivered `tasks/update` — previously every reconnect (and
  `ensure_connected` performs one after any transient failure) discarded that
  bookkeeping, so a handler could be asked to answer the same input request
  twice, an unconfirmed answer was never retransmitted, and the task's own
  handles were refused for a session that never existed. A session a handshake
  *did* open still ends with the connection, and round 35's other epoch moves
  (`terminate_session`, a changed session id, the 404 recovery, a restarted
  stdio process, an ended SSE stream) are unchanged.
- **Every path that replaces an HTTP session moves the session epoch (round
  35).** The 404 recovery already did (round 32), but it is not the only way
  a session is replaced without a `cleanup`: `terminate_session` — the
  host's own DELETE, and the one `cleanup` sends — now ends the epoch too,
  whatever the server answers, and so does a handshake that lands a
  different session id on a live one. Anything keyed by the session that
  ended (task ids, answered and pending input keys) therefore dies with it
  instead of colouring an id the next session reuses: a task handle from
  a terminated session is refused rather than sent into its successor.
- **A task handle carries the session its request was sent in (round 33).**
  A `Task` is now stamped with the session epoch the request that produced
  it was pinned to, instead of sampling the server when the object happens
  to be built: a session that ends between the answer and the handle (a
  stdio child exiting, a concurrent 404 recovery) no longer stamps the
  handle with the *successor* session, where the reused task id names an
  unrelated task, and a wait accepts a terminal payload only when it is
  stamped with the very session it polled. Task requests that name their
  task with a bare id are pinned to the session live at the call, so an
  HTTP 404 recovery cannot replay `tasks/get` / `tasks/result` /
  `tasks/cancel` into the replacement session; a session that ends under
  such a request is reported as a `TaskError` (the documented failure) by
  `get_task`, and `update_task` now reports answers the pin dropped instead
  of returning `true` for a delivery that never went out. On the HTTP
  transports the captured session id is now attached to the request
  unconditionally, so a concurrent recovery clearing `@session_id` can no
  longer send an in-flight pinned request with no session header at all,
  and a 404 moves the session epoch the moment it ends the session rather
  than after the replacement handshake succeeded — a handshake that fails
  leaves the transport uninitialized instead of leaving requests treating
  the dead session as current. A `tools/call` answered with a task is
  validated against the tool definition in force when the call was made:
  an unrelated `tools/list_changed` refresh landing during a wait that may
  take minutes no longer changes the schema the result is checked against.
- **An HTTP session restart moves the epoch, and a wait ends with its
  session (round 32).** The automatic recovery from an expired HTTP session
  (a 404 answering a request that carried an `Mcp-Session-Id`, which the
  client answers with a fresh `initialize`) now ends the session it
  replaces: the session epoch moves, so the task bookkeeping keyed by it —
  answered keys, pending answers, in-flight holds, rounds — dies with the
  old session instead of colouring a reused task id in the new one, and a
  wait notices the move exactly as it does for a cleanup or a restarted
  stdio process. A request pinned to the ended session is no longer resent
  into its replacement (the 404 recovery resent it without re-checking the
  pin), and every transport now checks the pin in the same critical section
  that picks the session the request goes out on — the HTTP session id, the
  stdio pipe, the SSE endpoint — so a cleanup or reconnect completing after
  the check cannot put the request on the replacement session's wire. A
  wait no longer follows a restart into the new session at all: a
  terminal payload that came back from a poll pinned to the wait's own
  session *is* the task's outcome even when the session ends right after,
  and short of that the wait fails (`TaskError`) rather than polling an id
  the replacement session may have reused for an unrelated task —
  `wait_for_task` and `get_task` refuse a task handle whose session has
  ended (as `update_task` and `cancel_task` already did), and so does the
  legacy `tasks/result`, which is now pinned to the handle's session too. A
  session that moves while the wait sleeps between polls ends it there
  rather than being silently joined. A `tasks/update` the session guard
  drops now gives its keys back in the state the answers were built in,
  never in the replacement session's.
- **Polls are pinned to their session, terminal results never cross it
  (round 31).** `tasks/get` is now pinned to the session the wait joined,
  like `tasks/update`: a reconnect inside `rpc_request` makes the transport
  refuse the poll (counted as a lost poll) instead of asking the
  replacement session about a reused task id. Every observation is checked
  against the session again before it is acted on, terminal ones included,
  so another lifetime's `result` — or `error` — can never become the
  outcome of `call_tool` / `wait_for_task`; the input requests of an
  observation are re-checked once more after the pending update is
  retransmitted, so a session that ended under that round trip cannot put a
  dead task's elicitation to the host. Bookkeeping is forgotten only in the
  session it belongs to (a terminal poll, and a terminal task handle kept
  across a restart, no longer wipe the replacement session's answered
  keys), and an explicit `update_task` / `cancel_task` for a task handle is
  pinned to the handle's session and refused when that session has ended.
- **An ended session's observation is discarded, the epoch holds at the
  send (round 30).** A `tasks/get` answer that came back after the server
  session ended is no longer acted on: the wait joins the replacement
  session and polls it again instead of presenting the dead session's
  `inputRequests` to the host, enforcing its TTL backstop (which also
  forgot the new session's bookkeeping) or pacing the next poll by its
  `pollIntervalMs`; a task handle a host kept across a restart no longer
  seeds a wait with the TTL and pace of a task that no longer exists. The
  session a `tasks/update` belongs to is now enforced at the wire: the
  request is pinned to it, so a reconnect inside `rpc_request`'s own
  `ensure_initialized` / `ensure_connected` makes the transport drop the
  payload instead of writing an ended session's answers into the next one,
  and a failure to establish the session is no longer swallowed. Answers
  queued behind an update that hangs are recorded as pending before the
  task's update lock is taken (so a wait that gives up while queued leaves
  them retransmittable) and a confirmed delivery clears only the keys it
  carried; a handler's keys, its in-flight hold and its input round are
  reserved in the state the wait captured; and the session epoch is read
  under the registry lock everywhere.
- **The epoch guard reaches the wire (round 29).** A `tasks/update`
  establishes the transport's session *before* it compares the session
  epoch, so a reconnect inside `rpc_request` (`ensure_initialized`) can no
  longer slip an ended session's `inputResponses` into the next one; a
  rejected update releases its keys — and forgets a task the server reports
  gone — in the state it was built from rather than in whatever the current
  epoch resolves to, so keys the new session already answered stay answered;
  a wait refreshes its session before enforcing a TTL deadline, dropping the
  previous session's backstop (and its last observation) instead of ending
  the wait on a task that no longer exists; and a `tasks/get` or
  `tasks/update` abandoned on the caller's wall clock keeps the bookkeeping
  consistent — the answers stay pending and the task's update lock is
  replaced, so a retry of `wait_for_task(timeout:)` retransmits them without
  asking the host again, while the abandoned call's late completion touches
  only the state it captured and never a reused task id's.
- **Answers stay in their session, waits stay bounded (round 28).** The
  session epoch an input handler answered in is carried through the whole
  update path and compared again under the per-task update lock, so a
  restart between the check and the send drops the payload instead of
  answering an unrelated task in the new session; `wait_for_task(timeout:)`
  now bounds the complete poll/update RPC by wall clock (the call runs on
  its own thread joined with the remaining budget), so a transport that
  implements only `rpc_request(method, params)` — or one whose retry
  backoff outruns its per-attempt timeout — can no longer block a wait past
  its deadline; a TTL extension whose `ttlMs` is valid but too large for the
  clock lifts the previous backstop like an explicit `ttlMs: null`, while an
  observation that carries no `ttlMs` at all keeps the last one.
- **In-flight holds per task (round 26).** The keys a running input handler
  presents are in flight from the moment it starts (not only once it is
  abandoned) and each watcher touches only the registry entry it owns, so
  another task's finishing handler can never drop a live reservation and a
  TTL retry never asks the host twice for one key; a `tasks/update` binds
  its answered keys and its pending payload to the same session state; a
  synchronous answer to `call_tool_as_task` on a 2026-07-28 server is
  validated against the tool's `outputSchema` like `call_tool`; an
  overflowing `ttlMs` means no backstop rather than a raw exception.
- **Synchronous answers and overflow (round 27).** A synchronous answer to
  `call_tool_as_task` on a 2026-07-28 server is validated against the tool
  definition a mid-call HeaderMismatch refresh replaced, exactly like
  `call_tool`; `Task#ttl_elapsed?` treats an overflowing `ttlMs` as no
  backstop instead of raising, like `ttl_remaining`.
- **In-flight holds survive forgets (round 23).** The keys an abandoned
  input handler is still presenting stay reserved apart from the task's
  bookkeeping, so the TTL backstop, a gone task or a terminal lookup
  cannot let a retry present them again while the host is answering; a
  round whose delivery the deadline forbade (or whose handler failed) is
  refunded; an explicit missing-task message (`unknown task`, `not
  found`) makes `TaskNotFound` even when it mentions params; every task
  payload needs a string `taskId`; `tasks/update` goes out without a
  `timeout:` keyword when no bound applies, so transports implementing
  only `rpc_request(method, params)` keep working. A `tasks/update` or `tasks/cancel` that reports the task gone forgets its bookkeeping like a `tasks/get` that does.
- **Holds across sessions (round 25).** The watcher of an abandoned input
  handler releases exactly the hold it took (the in-flight set of the
  session the handler started in), never one a later session's retry
  placed under the same task id and key after a restart — the hold's set
  is fixed when the handler starts, so a handler that times out after a
  restart holds keys in its own session, not the new one; a read of the
  registry allocates nothing and emptied entries are dropped; a fresh
  CreateTaskResult is a new task lifetime (earlier bookkeeping under that
  id is forgotten); tasks/get and tasks/update go through a transport that
  implements only `rpc_request(method, params)` (the timeout keyword is
  sent only to transports that accept it).
- **Abandoned handlers (round 22).** A handler round that outlived the
  wait spends no input round (retries of a timed-out wait cannot exhaust
  the per-task budget on one outstanding request), and the keys an
  abandoned handler still presents stay reserved until it finishes, so a
  retry polls instead of asking the host again. A `-32602` on
  `tasks/update` or `tasks/cancel` is `TaskNotFound` only on an explicit
  indication; a terminal-task or invalid-response rejection stays a
  `TaskError`. A nested result whose `resultType` is present but not
  `"complete"` is invalid.

- **Task shape (round 16).** A task timestamp (`createdAt`,
  `lastUpdatedAt`) that is not an ISO 8601 timestamp is an
  `InvalidResultError` — in a `tasks/get` result and in a
  `CreateTaskResult` — so it can never lift the TTL backstop, which only an
  explicit `ttlMs` null does; `Client#get_task` also requires the payload a
  status implies (`completed` ⇒ an object `result`, `failed` ⇒ a JSON-RPC
  error object, `input_required` ⇒ an `inputRequests` object).
- **The validated task is the handle (round 18).** A 2026-07-28
  `CreateTaskResult` builds the task handle from the flat Task it was
  validated as; an extra `task` property (the legacy 2025 wrapper) never
  replaces it, and a task object that is not an object or names an
  unknown status is an `InvalidResultError` (`Task.from_json`), never a
  `NoMethodError` or `ArgumentError`.
- **Bounded probes and null payloads (round 19).** The caller's `timeout:`
  bounds the capability probe (initialization, discovery) that
  `wait_for_task` may need before its first poll: a spent budget sends
  nothing, and a probe outliving the remaining budget ends the wait with
  the timed-out `TaskError` (the transports take no per-call handshake
  budget, so the probe runs on its own thread and is abandoned). A null or
  non-object task payload (`Task.from_json(nil)`, a `notifications/tasks`
  without params) is an `InvalidResultError`, never an empty working task.
- **Waits and lookups (round 17).** The caller's `timeout:` bounds the
  whole `wait_for_task`, capability probe (initialization, discovery)
  included; a task request never outlives the transport's configured
  `read_timeout` (`ServerBase#read_timeout`); `get_task` forgets a task's
  bookkeeping when it returns a terminal task or reports it gone; a
  completed task's nested result must be a complete result (a
  `resultType` other than `"complete"` is an `InvalidResultError`); a
  `CreateTaskResult` must carry the whole Task shape (status, parseable
  timestamps, a `ttlMs` key).
- **Retransmissions and sessions (round 14).** A retransmitted
  `tasks/update` carries only what is still pending once the task's update
  lock is held, so an answer a concurrent, confirmed update superseded is
  never sent again (an explicit answer is newer than a pending one for the
  same key and wins); the bookkeeping of a previous server session is
  dropped when the session ends, and `Client#cleanup` forgets every task.
  A wait that outlives a server restart follows the new session (a reused
  task id or input key is a new request and is answered again), and the
  session epoch never runs backwards: a request that read it before the
  restart gets the current session's state and can neither delete it nor
  bring the ended session back. A modern `tasks/get` result must carry
  every field the Task shape requires (`status`, `createdAt`,
  `lastUpdatedAt`, and `ttlMs` — null for unlimited, but present) and a
  failed task's `error` must be a JSON-RPC error object (integer `code`,
  string `message`); anything else is an `InvalidResultError` rather than
  a wait driven on made-up state.
- **Handlers, sessions and probes (round 20).** An input handler runs
  within what is left of the wait (with a deadline it runs on its own
  thread and the wait ends with the timed-out `TaskError` when it
  outlives the budget; the handler thread is abandoned and its answer
  dropped) and the deadline is enforced before anything is delivered;
  answers produced while the server session restarted are discarded and
  the task is polled again rather than delivered to a possibly reused
  task id; one capability probe runs per server at a time, so a wait that
  timed out on the handshake leaves it to finish and the next wait joins
  it instead of tearing the session down; a completed task's result with
  an explicit `resultType: null` is invalid; a streamed task result is
  validated against the tool a mid-stream refresh replaced; a
  `notifications/tasks` whose params are not a DetailedTask is a logged
  parse failure.

- **Opt-in extension.** `MCPClient::Client.new(extensions:
  ['io.modelcontextprotocol/tasks'])` (or a `identifier => settings` Hash)
  declares extensions in every request's `clientCapabilities`;
  `Client#tasks_extension?` reports it. Transports accept `resultType
  "task"` only once the extension is declared, only from a 2026-07-28
  server, and only for `tools/call` — anywhere else it is an
  `InvalidResultError`.
- **Transparent tasks.** When a server answers `tools/call` with a
  `CreateTaskResult`, `Client#call_tool` (and `call_tool_streaming`) polls
  `tasks/get` at the server's `pollIntervalMs` (honoured as given, with a
  50 ms floor, and clamped to what is left of the caller's timeout and of
  the task's TTL), answers `input_required` states through `tasks/update`
  with the registered elicitation / sampling / roots handlers (each
  `inputRequests` key answered once across polls), and returns the final
  result — or raises the failed task's JSON-RPC error (`ServerError` with
  its code) / `TaskError` for a cancelled task. A creation result that
  already claims a terminal or `input_required` status is confirmed by
  `tasks/get`, since only a DetailedTask carries the result, error or
  input requests. The `createdAt + ttlMs` backstop ends the wait with a
  `TaskError`.
- **Task lifecycle API.** `call_tool_as_task` returns the `MCPClient::Task`
  handle (a locally completed task when the server answered
  synchronously); `get_task` returns the DetailedTask (`input_requests`,
  `result`, `error`); `wait_for_task(task, timeout:)` waits for a terminal
  task; `update_task(task, input_responses)` sends `tasks/update`;
  `cancel_task` sends `tasks/cancel` (an acknowledgement — cancellation is
  eventually consistent); `get_task_result` waits and returns the result.
  `list_tasks` raises on a 2026-07-28 server (`tasks/list` was removed).
  `MCPClient::Task` gained `ttl_ms`, `poll_interval_ms`, `completed?`,
  `failed?`, `cancelled?`, `remote?` and `ttl_elapsed?`.
- **Gates and errors.** Task requests require both the client declaration
  and the server's `capabilities.extensions` entry (`CapabilityError`
  otherwise, including for `listen(notifications: { task_ids: [...] })`);
  `-32602` on `tasks/get`, `tasks/update` and `tasks/cancel` maps to
  `TaskNotFound`, `-32021` propagates as
  `MissingRequiredClientCapabilityError`, and a failed creation is a
  `TaskError`. Task notifications (`notifications/tasks`) reach the
  client's notification listeners. On Streamable HTTP, `tasks/get`,
  `tasks/update` and `tasks/cancel` carry `Mcp-Name: <taskId>`.
- **Waiting semantics.** The caller's timeout and the task's TTL backstop
  are tracked separately, so a later, longer `ttlMs` extends the wait and
  the TTL of the created task bounds polls that never come back; a poll
  that returns after the deadline ends the wait; a `tasks/update` the
  server rejected gives its keys back (the request is presented again),
  while one whose acknowledgement was lost is retransmitted first. Task
  results resolved on the streaming path are validated like `call_tool`'s.
  `MCPClient.connect(..., extensions: [...])` forwards the option, and
  `require 'mcp_client/client'` loads on its own. A `tasks/update` whose
  outcome is ambiguous (timeout, transport failure, 5xx, untyped server
  error) is not the end of the wait: the payload stays pending and goes out
  again with the next poll, so `call_tool` survives a lost acknowledgement;
  only a JSON-RPC rejection gives the keys back, and a confirmed update
  (including one sent through `update_task`) drops any pending payload.
  `tasks/update` requests are bounded like polls, the caller's deadline is
  enforced before a late terminal task is accepted and before any new
  handler round, a later observation with `ttlMs` null lifts the TTL
  backstop, a timed-out first poll is paced by the created task's
  `pollIntervalMs`, a completed task's `result` must be an object, the
  input-round limit is applied atomically with the key reservation, and
  `list_tasks` errors are sanitized.
- **Per-server handles.** A `tasks/update` carries every response still
  pending from an earlier delivery that could not be confirmed, so no answer
  is left behind once a later update lands; a handle from another server
  neither seeds a wait on the server named explicitly (no TTL, no pace) nor
  colours the acknowledgement of a cancel there; symbol-keyed camelCase
  task fields (`ttlMs:`, `pollIntervalMs:`) count as the modern shape.
- **Local handles and the standalone entry point.** `get_task_result` on a
  handle the server completed synchronously returns its result without
  selecting or probing a server; an answer lost twice is still carried by
  the update that answers the next key; `mcp_client/client/task_support`
  requires the task model and the JSON-RPC common module, so
  `require 'mcp_client/client'` drives a wait and answers
  `tasks_extension?` on its own.
- **Session-scoped bookkeeping.** Updates to one task are serialized, so a
  concurrent update that read an empty pending slot can never confirm and
  wipe an answer another delivery had just left pending. Task bookkeeping
  (answered keys, pending answers, input rounds) is keyed by the
  transport's `session_epoch` (bumped by every `cleanup`, including a
  restarted stdio process) and dropped once the task is gone
  (`TaskNotFound`) or past its TTL, so a reused task id never inherits
  it. A poll that times out before the server ever said a pace waits the
  default interval, not the busy-loop floor.

- **Rejections, notifications and bounds (round 21).** A `tasks/update`
  rejection about the supplied `inputResponses` is a `TaskError`, never a
  `TaskNotFound` (the task still exists); the legacy
  `notifications/tasks/status` keeps its flat 2025 shape while
  `notifications/tasks` requires a DetailedTask; an input handler is bounded
  by the task's TTL as well as the caller's timeout, and the whole deadline
  is enforced before delivery; a wait reads the server's session epoch and
  the answered set it points at in one step; `mcp_client/task` requires the
  error definitions it raises.
- **Bounded pace (round 28).** A `pollIntervalMs` the clock cannot
  represent, or that is merely enormous, is bounded to
  `MAX_TASK_POLL_INTERVAL` (one hour) rather than handed to `sleep`, and
  still clamped to what is left of the caller's timeout and the TTL.

### Cacheable results (`ttlMs` / `cacheScope`)

- **A result is bound to its own exchange, not to a request the response phase
  nested inside it (round 35).** The credentials and the receipt time of an
  HTTP exchange were both taken after `send_http_request` returned — after
  every Faraday `on_complete` had run. A host response middleware that sent a
  request of its own on that thread left *its* Authorization behind, and
  Alice's `resources/read` was filed under Bob's context and handed to him
  without a wire read; a middleware that merely took its time made a `ttlMs`
  start counting from the end of its own work, so a result whose TTL had run
  out long ago still read as fresh. The innermost middleware on the connection
  now stamps both facts into the environment of the request it is handing to
  the adapter, and the exchange reads them back from there.
- **An invalid cursor discards the pages cached under it on every transport
  (round 35).** Only the explicit-page listings dropped their cache when the
  server rejected a cursor with `-32602`; an auto-paginated `tools/list` or
  `prompts/list` restarted from the first page but left the previous sequence
  in the cache, so a restart that then failed transiently served that sequence
  back. Stdio did not restart at all — the same rejection surfaced as a
  `ToolCallError` where the HTTP transports recovered. Both now behave alike: a
  rejected cursor drops the entry the list is cached under, and every transport
  restarts once from the first page.

- **A private entry is bound to the credentials its request was sent with, not
  to what the response phase left behind (verification round).** The
  Authorization was recorded before the adapter sent the request and then read
  back out of `response.env.request_headers` afterwards — a mutable structure
  the response phase may rewrite. A host `on_complete` that deletes
  `Authorization` for redaction, or a redirect handler that strips it, filed an
  authenticated result under the anonymous context: Alice's `resources/read`
  was then handed to the next request that carried no token at all, without
  another wire read. What the recorder saw immediately before transmission is
  now what binds the entry, and the environment answers only for a connection
  that recorded nothing of its own. The context of the outer request is
  restored after its response is parsed by putting that record back, rather
  than by re-deriving it from an environment a nested request may have touched.
- **A result is never reused across parameters host middleware may have
  rewritten (verification round).** The parameters fingerprint describes the
  request the transport built, before Faraday middleware can change its body.
  Unknown request middleware already blocked *private* reuse through the
  authorization check, but a `"public"` entry bypassed it: middleware writing a
  changing locale into `params._meta` had an English read answer a French one,
  with only the English request reaching the server. A stack the transport
  cannot read off its own configuration now makes the effective parameters
  opaque, and an opaque fingerprint matches nothing — `"public"` permits
  sharing across callers, not across result-affecting parameters. What such
  middleware was *configured* with does not matter here, so Faraday's own
  `:authorization` middleware keeps caching on however its credential rotates:
  it changes a header, never the body.
- **A cleanup gives the cache a generation no request in flight can match
  (verification round).** Generations were `base + per-key count + shared-read
  count`, and a cleanup bumped the base while clearing the other counts — so a
  key one invalidation had already bumped went from `0 + 1` to `1 + 0`,
  unchanged. A read that started before the cleanup and arrived after it
  therefore installed itself as fresh and answered the next read. The three
  counts are now compared side by side instead of added up.
- **A `tools/call` host code nests inside a call records into a slot of its own
  (verification round).** Only the `call_tool` wrapper opened a definition
  slot, so a raw `rpc_request('tools/call', ...)` a notification listener
  issued while the outer call's response was being parsed overwrote the
  definition that call went out under — and a host re-resolving the tool to
  validate the result checked it against a newer definition it was never
  answered under. The boundary a transport crosses to reach host code now opens
  a definition slot as well as dropping the `request_meta` reservation.
- **A cursor the server rejects takes the pages cached under it with it
  (verification round).** A `-32602` for a cursor left the first page of that
  sequence in the cache, so the next list handed the caller the same dead
  cursor to follow. The pages cached for the list are now dropped when a
  cursor-bearing page request is rejected; an automatically paginated list
  restarts once from the first page rather than failing a caller who only asked
  for a list, and an explicit `list_resources(cursor:)` /
  `list_resource_templates(cursor:)` still raises, with the stale first page
  gone.
- **An unhinted template list is fetched again (verification round).** The HTTP,
  Streamable HTTP and SSE transports served `resources/templates/list` through
  `fresh_list_value`, under which a legacy list with no hint stays fresh for the
  life of the connection — a compatibility regression, since template listing
  fetched every time before results were cached at all. They now use
  `hinted_list_value`, as stdio already did: only a list the server itself
  bounded with a positive `ttlMs` is answered without a request.
- **Client caches are dropped with the transport's.** A transport that
  carries the caching mixin invalidates before it delivers a notification
  to a subscription listener, and this client registers its own
  invalidation there (`on_cache_invalidation`) rather than in the host
  notification callback, which now runs after the delivery. A listener
  reacting to `notifications/tools/list_changed` therefore cannot read a
  stale client-level list.
- **A reservation is adopted only by the operation it was opened for (round
  34).** A `Client` listing opens a same-method reservation on every server
  up front, and the transports adopted one on the rule "entered before the
  operation dispatched, for the same method". A list a notification listener
  ran on a server the loop had not reached yet therefore adopted *that*
  server's reservation and spent the evaluation the freshness check had
  already weighed for it: the nested request went out carrying another
  request's tenant, baggage or one-time value, and the fetch the client then
  made for that server was sent under an evaluation nothing had weighed. A
  reservation is now handed to the one operation it was made for, by name
  and once (`offer_request_meta_hold`), immediately before that operation is
  invoked; an operation that merely uses the same method reserves its own.
- **Host code the transport calls back into starts an operation of its own
  (round 34).** The claim rule spent a reservation for any message whose
  method equalled it, and several public entry points open no reservation of
  their own — `rpc_request`, `Client#send_rpc`, `Client#call_tool_as_task`,
  the HTTP transports' `fetch_prompts_list` / `fetch_resources_list`. A raw
  `rpc_request('tools/list')` a notification listener issued from inside a
  reconnect's handshake therefore spent the evaluation the interrupted
  listing was holding, and that listing's own fetch went out under a
  different one; wrapping `call_tool` and `get_prompt`, which weigh no cache
  decision, had created a reservation a raw `tools/call` could spend the same
  way. Every notification listener and server-request handler now runs behind
  a boundary (`outside_request_meta_hold`): whatever it asks of the transport
  — a nested list, a raw `rpc_request`, whatever method it names — reads the
  host afresh and leaves the reservation to the request that holds it.
- **`clear_cache` reaches the transports (round 34).** `Client#clear_cache`
  erased only the client's aggregation maps, so a transport still holding a
  list the server had bounded with a positive `ttlMs` answered the next
  `list_tools`, `list_prompts` or `list_resources` from its own copy without
  sending anything — the documented promise of fresh data was not kept. It
  now drops the transport-level entry for each list kind too, as
  `cache: false` already did.
- **A held evaluation belongs to the request it was reserved for, and to no
  other (round 33).** A cache decision reads the host's `request_meta` once
  and reserves that evaluation for the request it leads to. The rule used to
  be "the next message spends it, unless it is one of three handshake
  methods", and each round found another message that was neither: the
  `subscriptions/listen` a stdio reconnect re-opens, the
  `notifications/cancelled` sent for a request that timed out, a request a
  notification listener issues from inside a response's synchronous
  dispatch. The reservation also survived its own operation: a list whose
  reconnect or initialization raised left the evaluation on the thread, and
  the next unrelated request on that worker went out carrying the aborted
  decision's tenant, baggage or nonce. The rule is now the other way round
  and enforced structurally, by `MCPClient::RequestMetaScope`: an operation
  reserves the evaluation for the JSON-RPC method of the request it sends,
  only that request claims it, everything else reads the host afresh, and
  the scope drops the reservation from an `ensure` however the operation
  ends. An operation that begins while another is already talking to the
  server — a nested call from a notification listener — reserves its own.
  The handshake allowlist and the "keep it isolated while the message is
  built" workaround are gone with it.
- **The client's listings hold their reservation for the listing only (round
  33).** `Client#list_tools`, `#list_prompts` and `#list_resources` read the
  parameters each server's fetch would carry before making it; when
  `server.list_tools` then failed during a reconnect, the rescue moved on to
  the next server (or the caller caught the error) with the evaluation still
  held. The three loops now run inside a scope that opens the reservation on
  every server and closes it on every exit.
- **A `tools/call` keeps the definition it went out under against nested
  calls (round 33).** The round-32 slot was a single per-thread,
  per-transport entry, so a notification listener that called another tool
  from inside the outer call's response dispatch overwrote it: the outer
  call was then validated against the nested definition, or listed again and
  validated against a newer one. Every call now records into a slot of its
  own, handed to the caller waiting for it when the call returns.
- **`cache: false` really re-lists (round 33).** When a modern server bounded
  a list with a positive `ttlMs`, the transport answered `list_tools` from
  its own copy without sending anything, so `Client#list_tools(cache: false)`
  returned a cached list instead of fetching fresh; prompts and resources
  behaved the same way. A forced refresh now drops the transport's entry for
  that kind first, so the request reaches the server.
- **A freshness check that aborts releases every server's held evaluation
  (round 32).** With several cached servers, a check reads each server's
  parameters in turn and each transport holds that evaluation for the fetch
  the check is deciding on. When a later server's probe raised — an OAuth
  refresh failing — no fetch followed for any of them, but the servers the
  loop had already passed kept holding theirs: a later request on the same
  worker thread went out carrying that decision's tenant, baggage or trace
  id. Round 30 released the evaluation of the server whose own lookup
  aborted; the client now releases every server's on an exceptional exit.
- **A post-call re-resolve reads the definition the call went out under
  (round 32).** A `tools/call` derives its `Mcp-Param-*` headers from the
  transport's tool list, re-fetching it when the list is stale (a server that
  sends `ttlMs: 0`, or a TTL that expires mid-call). The client then
  re-resolved the tool by listing again, which fetched once more and could
  answer with a newer definition than the request carried — validating the
  result against a schema the call was never made with. The transport now
  keeps the definition its request went out under and the client takes it
  from there instead of triggering another re-fetch.
- **`cleanup` forgets its thread state after terminating the session (round
  32).** `ServerHTTP` and `ServerStreamableHTTP` cleared their thread-local
  slots first and terminated the session afterwards; the DELETE that
  terminates it runs the authorization recorder on its own connection, which
  put the transport's Authorization fingerprint straight back on the thread.
  A long-lived worker that built and disposed transports therefore kept one
  fingerprint per transport after all. Both transports now drop the slots
  once termination is done, and do so even when cleanup exits early or
  raises.
- **A reconnect's handshake no longer spends the metadata a list holds
  (round 31).** A cache decision evaluates the host's `request_meta` once and
  holds that evaluation for the request it leads to. That request reconnects
  on its way out (`ensure_connected` cleans up and connects first), and the
  `server/discover`, `initialize` and `notifications/initialized` of the
  handshake used to consume the held evaluation, so the list itself then went
  out carrying a different one than the decision weighed — and a callable
  vending a one-time value had it spent on the handshake. The handshake now
  reads the host afresh, as any message of its own does, and leaves the held
  evaluation for the request it was held for.
- **HTTP+SSE keeps its Authorization slot like every other transport (round
  31).** `ServerSSE` wrote and read the per-transport authorization
  thread-local inline instead of through `request_authorization_key`, so
  `forget_transport_thread_state` did not know about it: a worker thread that
  created and discarded SSE transports kept one authorization entry per
  transport for its whole life, and an emptied slot read as an anonymous
  request rather than as nothing recorded. The slot, its key and its
  empty-slot semantics now live in one `MCPClient::RequestAuthorization`
  mixin shared by every HTTP transport, and the round-30 cleanup guarantee is
  covered on all four transports.
- **The probe reads the Authorization the connection carries (round 30).**
  A `faraday_config` block may set `conn.headers['Authorization']`, and every
  request Faraday builds on that connection starts from that table. The
  probe used to start from the transport's own headers alone, so it answered
  "anonymous" for requests that go out with a bearer — a private entry of one
  context could be matched against another. It now starts from the built
  connection's header table (reading it runs no middleware and no host code)
  with the transport's own headers laid over it, exactly as a real request
  does, and reports the unknown context if that table cannot be read.
- **A handler that carries a host callback is an unknown context (round
  30).** A middleware class being inert says nothing when the host handed it
  code to run: `Faraday::Response::Logger` takes a formatter whose `request`
  method receives the mutable env, `follow_redirects` takes a redirect
  callback, and a configuration block can define a singleton method on
  either. Any handler installed with a block, or with a proc, method, class
  or other callable among its arguments, now makes the context unknown. The
  "no request phase" test also requires that Faraday's own constructor build
  the instance: a middleware with a constructor of its own can give its
  instances an `on_request` hook that no class-level test would ever see.
- **A cache lookup that aborts releases the metadata it held (round 30).** A
  freshness check reads the parameters the next request would carry, which
  evaluates the host's `request_meta`, and holds that evaluation for the
  request the decision leads to. When the authorization probe raised (an
  OAuth refresh failing, say) no request was built and neither release path
  ran, so a later request on that thread sent the previous tenant's
  metadata. The held evaluation is now released when a lookup aborts.
- **`cleanup` drops every thread-local slot a transport owns (round 30).**
  It used to clear only the served-entry notes, leaving the per-object
  authorization, request-parameter, round-trip and recorded-entry slots on
  the thread: a long-lived worker that created and discarded transports
  accumulated entries for its whole life. An anonymous request is now noted
  with its own marker, so an emptied slot reads as "nothing recorded" rather
  than as an anonymous request that never happened. The metadata held for
  the *next* request is deliberately kept — `ensure_connected` cleans up
  before it reconnects, in the middle of the very request that holds it.
- **`follow_redirects` is framework middleware the probe steps over (round
  30).** The gem depends on `faraday-follow_redirects`, so the ordinary
  stack `faraday_config: ->(f) { f.response :follow_redirects }` with a
  static bearer never got a private cache hit. The middleware has no request
  phase and the only header it ever touches is the Authorization it
  *deletes* on a cross-host redirect, which can cost a hit but never leak
  one; `Faraday::Response::Json` joins the list for the same reason. A
  redirect callback still makes the context unknown.
- **Host middleware is never run by the freshness probe (round 29).** Four
  rounds of reflection could not tell a middleware that vends a one-time
  credential apart from an inert one: the rotating state can sit in a
  constant, a global, a thread-local or the binding of a method, and none of
  those are left behind by building a copy. So the probe no longer runs any
  host code. It answers from what the transport itself knows — the
  configured headers plus the OAuth provider — and treats a `faraday_config`
  block as an unknown context (no private entry served) unless every
  middleware it installs is either framework middleware that sets no
  Authorization header, middleware with no request phase at all, or
  Faraday's own Authorization middleware installed with literal
  configuration. A statically configured bearer, with or without that
  middleware, still gets its private cache hit. The prediction machinery
  this replaces (`probe_stands_in_for?`, `probe_inert_middleware_class?`,
  the `RubyVM::InstructionSequence` inspection and the reachable-state walk)
  is gone; the rounds below describe the prediction rules it supersedes.
- **`baggage` is application context (round 29).** W3C `baggage` carries
  host-defined values such as a tenant, so it is no longer treated as a
  per-request identifier: a result cached under one `baggage` is never
  served to a request carrying another. `progressToken`, `traceparent` and
  `tracestate` stay neutral.
- **Metadata held for a request is released only when a value is served
  (round 29).** A freshness check that matched an entry but found it stale
  used to drop the `request_meta` evaluation it had made, so the request it
  then sent read the host's callable again and a rotating trace id or nonce
  was spent without ever going out. The evaluation is now released at the
  points where a cached value really is handed back.
- **An invalidated template list is dropped (round 29).**
  `resources/list_changed` and `cleanup` now clear the transport's
  `resources/templates/list` alongside the other lists, instead of keeping
  the old list alive for the life of the connection.

- **Only provably inert middleware is probed (round 28).** A middleware
  copy shares its class, and a `define_method` request hook keeps the
  binding it was defined in, so comparing two instances could never see a
  nonce vended by `self.class` or closed over by a block. The rule is now
  inverted for those: the probe runs a host request hook only when its class
  holds nothing of its own (no class-level instance variable, class variable
  or singleton method) and every method it defines was written with `def`;
  anything else reports the unknown context with the counter untouched.
  Faraday's own Authorization middleware and hooks that read a frozen holder
  keep predicting the next request as before. A stdio
  `resources/templates/list` now follows the server's hint like the other
  lists: a 2025-11-25 list with no `ttlMs` is asked for again rather than
  kept (an empty one included), while a positive `ttlMs` is still served
  without a second request. A client-level cache hit reads the host's
  `request_meta` once for the whole decision instead of twice, the note a
  transport leaves on the thread for the cache above it is taken rather than
  left behind (and dropped on cleanup), and an SSE response is dated from
  the arrival of the chunk that carried it, so a slow notification callback
  in the same chunk cannot stretch a `ttlMs` past what the server sent.

- **Middleware the probe may neither build nor stand in for, and lists
  taken under the lock (round 27).** Two middleware ivars that merely
  compare equal are a stand-in only while nothing mutable is reachable
  through both of them: Faraday rebuilds middleware as
  `klass.new(app, **kwargs)`, so a fresh options hash around the very same
  vendor now reports the unknown context instead of letting the probe spend
  a one-time credential (a callable credential, `-> { token }`, is such
  shared state too). A middleware copy is built only when every argument the
  handler carries can hand its constructor nothing to spend, so a
  constructor that consumes a nonce is never run; middleware with no
  request hook is neither built nor compared, since it cannot change what a
  request carries. The probe models the request with the metadata held for
  the decision rather than evaluating the host's `request_meta` again. A
  cached list is copied out under the cache lock and only while its entry is
  still the one the cache holds, so a `list_changed` notification landing
  during the lookup is never served past. Stdio serves a still-fresh hinted
  `tools` / `prompts` / `resources` list instead of re-listing on every call
  (an unhinted list is still left to the client's cache). And a re-fetch
  that replaced the tool definitions (an expired `ttlMs` during a
  `tools/call`) announces the change, so a result is validated against the
  definitions its call was answered under.

- **Unpredictable shared state, and empty legacy lists (round 26).** The
  freshness probe now treats shared state as predictable only where it can
  vend nothing but itself: a module or class a host middleware shares is no
  longer assumed safe (it keeps state of its own that freezing never
  reaches), and neither is a frozen wrapper — a `Data`, a custom object —
  built around a mutable member. Anything else reports the unknown context,
  so probing cannot spend a one-time credential. A logger, a lock and
  deeply frozen holders stay predictable. An empty client-level snapshot is
  a hit only where the servers bounded it themselves with a freshness hint;
  a 2025-11-25 server records none, so its empty list is asked for again
  instead of being kept for the life of the connection. A host
  `request_meta` callable is evaluated once for a cache decision and the
  request that decision leads to, instead of being spent again on the
  request (a callable vending a one-time value no longer sends metadata the
  decision never weighed). A cached `resources/read` is copied out under the
  cache lock and only while its entry is still the one the cache holds, so
  an invalidation landing during the lookup is never read past. And a
  fetch identity is remembered on the thread only for the lists that attach
  one and take it back out, so a discovery leaves nothing behind per
  transport in long-lived worker threads.

- **A probe that changes nothing, and empty snapshots (round 25).** The
  freshness probe starts from a detached copy of the header table even when
  the transport was configured with Faraday's own, so the `Authorization`
  an OAuth provider applies while probing never lands in the headers real
  requests are built from (a removed token cannot linger there). Host
  middleware (`faraday_config`) that shares mutable state with the live
  stack — a nonce or one-time token counter the fresh copy points at too —
  is no longer run by the probe: it reports the unknown context instead, so
  probing can neither spend a credential nor make the next request skip
  one. Middleware sharing only immutable state is still predicted. The
  client-level list caches track which servers have filled their slice, so
  a completed snapshot whose lists are all empty is served while it is
  fresh instead of re-issuing the list request on every call.

- **One Authorization, and unpredictable middleware (round 24).** The
  freshness probe resolves the `Authorization` a Faraday request would
  really carry: the header table is case-insensitive, so a provider's
  canonical write replaces a header configured under any other spelling
  instead of leaving an older token behind for the fingerprint to find.
  Host middleware (`faraday_config`) that keeps state of its own — a token
  rotated per request, anything learned from an earlier response — is no
  longer predicted from a fresh copy that has not seen those requests: the
  probe reports the unknown context instead, so no private entry is served
  for such a stack. Resource template lists are served from their fresh
  entry on stdio too, which has no client-level cache above it.

- **Generations, header spelling and arrival times (round 21).** Folding
  the per-URI invalidation generations past `MAX_READ_GENERATIONS` jumps
  the shared read generation past every count it absorbs, so no key's
  generation stands still or goes back and a read still in flight cannot
  be stored against a generation the fold left behind; the configured
  `Authorization` header is found whatever its spelling (`Authorization:`,
  `'AUTHORIZATION'`, a symbol), on every transport, so such a credential
  no longer makes every private entry look foreign; a queued stdio line or
  SSE event is dated from its arrival, before it is decoded.

- **Templates, receipt times and copies (round 23).** Resource template
  lists are cached like the other lists on every transport (served while
  fresh, copied, served stale on a failed re-fetch on HTTP); a direct
  (non-SSE) response is dated before it is parsed; resource contents are
  copied iteratively; the client-level list caches forget a server's tag
  with its slice (`clear_cache`, `list_changed`), so a partial refill
  never serves a snapshot that omits a live server, and the freshness of
  every slice's entry is re-read under the cache lock right before a copy
  is handed out.
- **Snapshots and stale fallbacks never outlive cleanup (round 22).** A
  client-level snapshot is served only while every slice still comes from
  the transport entry it was recorded against (re-checked under the cache
  lock right before the copy; a placeholder identifies nothing), and
  `Client#cleanup` clears the client caches; a stale list served on a
  failed re-fetch must still be the entry in the slot — an entry a cleanup
  replaced while the re-fetch was in flight is forgotten (its value is
  dropped too). `MCPClient::DeepCopy` copies iteratively, so a peer
  schema nested deeper than the Ruby stack allows cannot crash a client
  cache hit.
- **Cleanup placeholders and slice identity (round 19).** Clearing the
  cache installs a stale placeholder for every list kind, recorded or
  not, and a transport keeps a fetched list only when its hint was
  attached (or the list carried none), so cleanup racing a first fetch
  never leaves a hintless copy to serve — `ttlMs` 0 re-fetches on every
  access; a client-level slice is identified by the very transport entry
  it came from, never by "no entry" (a legacy list stays a hit only while
  the transport still holds no entry). `cache_info` hands out detached
  values (a caller mutating them cannot reach the entry's scope); the
  per-URI invalidation generations are bounded (`MAX_READ_GENERATIONS`,
  past which every read counts as invalidated, and the map is dropped
  when the whole cache is cleared); the client identity a request
  carries is part of the parameters a cached result is bound to, so
  `client_info=` / `send_client_info=` re-fetch; the client-level
  freshness check runs outside the cache lock and the copy is served only
  when nothing changed meanwhile, so a freshness callback that clears the
  client cache cannot deadlock.
- **Client slices, per-key invalidation, capabilities (round 18).** A
  client-level cache slice is tied to the very transport entry its list
  came from (identity and the parameters that entry is bound to), so a
  transport list refreshed on its own — rotated credentials, a concurrent
  fetch, a re-fetch after the TTL elapsed — replaces that entry and the
  slice with it; invalidation generations are kept per cache key
  (`cache_epoch(key)`), so a resource updated while `tools/list` is in
  flight no longer discards the tools hint; the client capabilities a
  request advertises (`declare_extension`, newly registered handlers) are
  part of the parameters a cached result is bound to; a re-fetch that
  never built its request matches no stale entry, public ones included.
- **Client caches and queued responses (round 17).** The client-level
  tool, prompt and resource caches are tagged with the parameters of the
  list they hold — read before the fetch, never the leftover of whatever
  request ran last on the thread — so a transport hit under another
  tenant cannot mislabel the slice; prompts are cached as copies like
  tools and resources; the client maps and their tags live under one lock,
  so a freshness check and the copy it approves are one snapshot and a
  `list_changed` clear waits for it; an outer request's credentials and
  parameters are restored even when parsing its response raises, so a
  failed re-fetch is judged by its own context; a response queued by the
  stdio reader or the SSE stream is dated from its arrival, not from when
  the waiter woke.

- **Client caches and receipt times (round 16).** `MCPClient::Client`'s
  own tool, prompt and resource caches are bound to the effective
  parameters each server's slice was filled under, so a later transport
  fetch (or a callback) under other `request_meta` never makes them a
  false hit, and they hand out copies. A result's TTL runs from the moment
  its response was received — transports note that time before the
  notifications the response carried are dispatched — not from the end of
  those callbacks.

- **Pages with differing parameters (round 15).** A paginated list whose
  pages went out under differing effective parameters (the host's
  `request_meta` changed between pages, e.g. from a notification callback)
  is never served from the cache: like pages fetched under differing
  credentials, it leaves a stale placeholder that no request's parameters
  match (`CachedResult::MIXED_PARAMS`), on every transport including stdio.

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
- **Effective parameters (round 14).** A cached list or read is bound to
  the effective request parameters its request went out with — the host's
  `request_meta` (vendor keys such as a tenant) without the reserved
  protocol fields and the per-request identifiers (`progressToken`,
  `traceparent`, `tracestate`) — and is served, fresh or as a
  stale fallback, only to a request that would carry the same
  (`CachedResult#params_fingerprint`); a result's binding survives a
  nested request made by a notification callback.

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
  loopback (`localhost`, a `*.localhost` name, or any spelling of 127.0.0.0/8
  or `::1`) and the exception still applies — but only to loopback discovery
  URLs. A configured server URL that is merely private (`10.0.0.5`,
  `app.internal`, `printer.local`) gets no exception at all: its discovery URLs
  must be HTTPS and must not name a loopback or private address.
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