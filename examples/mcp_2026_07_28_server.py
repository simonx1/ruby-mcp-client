#!/usr/bin/env python3
"""
MCP 2026-07-28 reference server (Streamable HTTP, modern era).

The other example servers in this directory speak the handshake-based
protocol: a client sends `initialize`, gets a session id back and carries it
on every later request. The 2026-07-28 revision removes all of that. There is
no handshake, no session and no server-to-client request channel; a client
announces itself on each request in `_meta`, and anything the server needs
back it asks for through the *result* rather than by calling the client.

This server exists so the Ruby examples have something that actually answers
that way. It implements, one endpoint each:

  server/discover        the probe that identifies the era, with capabilities
                         and a cache hint
  tools/list             tools carrying JSON Schema 2020-12, an outputSchema
                         and an x-mcp-header annotation, with a cache hint
  tools/call             echo, structured output, header-derived parameters,
                         a multi round-trip (input_required) tool and a
                         task-augmented one
  resources/list         a resource list with a cache hint
  resources/read         a read result with a per-URI ttlMs
  prompts/list           a prompt list with a cache hint
  subscriptions/listen   a long-lived SSE notification stream
  tasks/get              polling for the task-augmented tool

Every request is checked for `io.modelcontextprotocol/protocolVersion` in
`_meta`, and the typed 2026-07-28 errors are reachable on demand — see the
`fail_with` tool argument.

Run it:

    pip install flask
    python3 examples/mcp_2026_07_28_server.py      # http://localhost:8933/mcp

Then point any of the 2026 examples at it:

    ruby examples/mcp_2026_07_28_features.rb
    ruby examples/subscriptions_listen_example.rb
    ruby examples/multi_round_trip_example.rb

This is a teaching server, not a production one: state lives in memory, and
the "authorization" it does is a string comparison. It binds to localhost.
"""

import base64
import binascii
import json
import threading
import time
import uuid
from datetime import datetime, timezone

from urllib.parse import urlparse

from flask import Flask, Response, request

app = Flask(__name__)

PROTOCOL_VERSION = "2026-07-28"

# _meta keys the revision reserves. A modern client sends the first three on
# every request; the server echoes its own identity back in serverInfo.
META_VERSION = "io.modelcontextprotocol/protocolVersion"
META_CLIENT_INFO = "io.modelcontextprotocol/clientInfo"
META_CLIENT_CAPS = "io.modelcontextprotocol/clientCapabilities"
META_SERVER_INFO = "io.modelcontextprotocol/serverInfo"
META_SUBSCRIPTION_ID = "io.modelcontextprotocol/subscriptionId"
META_CLIENT_CAPS_EXTENSIONS = "extensions"

# Tasks are negotiated per request: the server offers the extension in
# discovery, and each request that wants task behaviour declares it back.
TASKS_EXTENSION = "io.modelcontextprotocol/tasks"

# JSON-RPC codes the 2026-07-28 revision adds.
HEADER_MISMATCH = -32020
MISSING_CAPABILITY = -32021
UNSUPPORTED_VERSION = -32022

SERVER_INFO = {"name": "mcp-2026-07-28-example", "version": "1.0.0"}

# ---------------------------------------------------------------------------
# In-memory state
# ---------------------------------------------------------------------------

tasks = {}
tasks_lock = threading.Lock()

# requestState -> what the client has already answered, for the multi
# round-trip tool. The state is opaque to the client and echoed verbatim.
pending_rounds = {}
rounds_lock = threading.Lock()


def now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


# ---------------------------------------------------------------------------
# Tool definitions
# ---------------------------------------------------------------------------

TOOLS = [
    {
        "name": "echo",
        "description": "Echo a message back as text and as structured content.",
        "inputSchema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": {
                "message": {"type": "string", "description": "What to echo"},
                "fail_with": {
                    "type": "string",
                    "description": "Return a typed 2026-07-28 error instead: "
                    "header_mismatch, missing_capability or unsupported_version",
                },
            },
            "required": ["message"],
        },
        "outputSchema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": {
                "echoed": {"type": "string"},
                "length": {"type": "integer"},
            },
            "required": ["echoed", "length"],
        },
    },
    {
        # `x-mcp-header` moves a parameter out of the JSON body and into an
        # `Mcp-Param-{name}` request header. The client mirrors it there; this
        # server reads it from the header and rejects a call that arrives
        # without it, which is what drives the -32020 refresh-and-retry path.
        "name": "tenant_report",
        "description": "Report for one tenant; the tenant travels as a request header.",
        "inputSchema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": {
                "tenant": {
                    "type": "string",
                    "description": "Tenant id, sent as the Mcp-Param-Tenant header",
                    # The annotation names the header, so this argument
                    # travels as `Mcp-Param-Tenant` instead of in the body.
                    "x-mcp-header": "Tenant",
                },
                "section": {"type": "string"},
            },
            "required": ["tenant"],
        },
    },
    {
        "name": "create_ticket",
        "description": "Open a ticket; asks for the missing details mid-request.",
        "inputSchema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": {"summary": {"type": "string"}},
            "required": ["summary"],
        },
    },
    {
        "name": "slow_build",
        "description": "A long-running build, answered as a task.",
        "inputSchema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": {"target": {"type": "string"}},
        },
        "execution": {"taskSupport": "optional"},
    },
]

RESOURCES = [
    {
        "uri": "file:///reports/summary.txt",
        "name": "summary.txt",
        "mimeType": "text/plain",
        "description": "A short report that changes every few seconds.",
    }
]

PROMPTS = [
    {
        "name": "summarize",
        "description": "Summarize a report",
        "arguments": [{"name": "style", "description": "terse or verbose", "required": False}],
    }
]


# ---------------------------------------------------------------------------
# JSON-RPC plumbing
# ---------------------------------------------------------------------------


def error(request_id, code, message, data=None):
    body = {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}
    if data is not None:
        body["error"]["data"] = data
    return body


def result(request_id, payload):
    """Every result carries resultType; 2026-07-28 makes it the discriminator."""
    payload.setdefault("resultType", "complete")
    payload.setdefault("_meta", {})[META_SERVER_INFO] = SERVER_INFO
    return {"jsonrpc": "2.0", "id": request_id, "result": payload}


def request_meta(params):
    return (params or {}).get("_meta") or {}


def check_protocol_version(params):
    """Return an error tuple when the request does not declare a version we speak."""
    declared = request_meta(params).get(META_VERSION)
    if declared == PROTOCOL_VERSION:
        return None

    # The data is mandated: without `supported` and `requested` a client cannot
    # tell a real modern rejection from an intermediary emitting a bare -32022,
    # and has nothing to retry with.
    data = {"supported": [PROTOCOL_VERSION], "requested": declared}
    if declared is None:
        # A request with no version is a legacy client; this server has no
        # legacy mode, so say so in the terms the revision defines.
        return (UNSUPPORTED_VERSION, f"this server speaks {PROTOCOL_VERSION} only", data)
    return (UNSUPPORTED_VERSION, f"unsupported protocol version: {declared}", data)


# ---------------------------------------------------------------------------
# Method handlers
# ---------------------------------------------------------------------------


def handle_discover(request_id, params):
    """The probe that tells a client which era it is talking to.

    A modern answer names the revision and the capabilities; ttlMs and
    cacheScope let the client hold on to it instead of re-probing.
    """
    return result(
        request_id,
        {
            "supportedVersions": [PROTOCOL_VERSION],
            "capabilities": {
                "tools": {"listChanged": True},
                "resources": {"subscribe": True, "listChanged": True},
                "prompts": {"listChanged": True},
                # Tasks are an extension in this revision, and a client only
                # accepts a task result from a server that negotiated it here.
                # Without this the slow_build tool below is unreachable
                # through the documented `extensions:` API.
                "extensions": {TASKS_EXTENSION: {}},
            },
            "serverInfo": SERVER_INFO,
            "ttlMs": 60_000,
            "cacheScope": "public",
        },
    )


def handle_tools_list(request_id, params):
    return result(request_id, {"tools": TOOLS, "ttlMs": 30_000, "cacheScope": "public"})


def handle_resources_list(request_id, params):
    return result(request_id, {"resources": RESOURCES, "ttlMs": 30_000, "cacheScope": "public"})


def handle_prompts_list(request_id, params):
    return result(request_id, {"prompts": PROMPTS, "ttlMs": 30_000, "cacheScope": "public"})


def handle_resources_read(request_id, params):
    uri = (params or {}).get("uri")
    if uri != RESOURCES[0]["uri"]:
        return error(request_id, -32602, f"unknown resource: {uri}")
    return result(
        request_id,
        {
            "contents": [
                {
                    "uri": uri,
                    "mimeType": "text/plain",
                    "text": f"report generated at {now_iso()}",
                }
            ],
            # Per-URI freshness: the client serves this read from its cache
            # until the ttl elapses, then fetches again.
            "ttlMs": 5_000,
            "cacheScope": "public",
        },
    )


def handle_prompts_get(request_id, params):
    style = ((params or {}).get("arguments") or {}).get("style", "terse")
    return result(
        request_id,
        {
            "description": f"A {style} summary prompt",
            "messages": [
                {
                    "role": "user",
                    "content": {"type": "text", "text": f"Summarize the report, {style}ly."},
                }
            ],
        },
    )


def echo_tool(request_id, arguments):
    fail_with = arguments.get("fail_with")
    if fail_with == "header_mismatch":
        return error(request_id, HEADER_MISMATCH, "header does not match the tool definition")
    if fail_with == "missing_capability":
        # -32021 carries the capabilities the server needed. The shape is
        # mandated: without it the client cannot tell a real modern rejection
        # from an intermediary emitting a bare -32021, and treats it as an
        # ordinary tool failure.
        return error(
            request_id,
            MISSING_CAPABILITY,
            "this tool needs a capability you did not declare",
            {"requiredCapabilities": {"elicitation": {"form": {}}}},
        )
    if fail_with == "unsupported_version":
        # -32022 names what the server does speak, and what it was asked for,
        # so the client can retry on a mutually supported version.
        return error(
            request_id,
            UNSUPPORTED_VERSION,
            "unsupported protocol version",
            {"supported": [PROTOCOL_VERSION], "requested": "2099-01-01"},
        )

    message = arguments.get("message", "")
    return result(
        request_id,
        {
            "content": [{"type": "text", "text": message}],
            # 2026-07-28 widened structuredContent to any JSON value; this
            # one matches the tool's outputSchema, so the client validates it.
            "structuredContent": {"echoed": message, "length": len(message)},
            "isError": False,
        },
    )


def tenant_report_tool(request_id, arguments):
    """The tenant arrives as a header, not in the arguments."""
    # Decoded, not raw: a value a header cannot carry arrives Base64-wrapped,
    # and the tool wants the value the caller actually sent.
    header_tenant = request.headers.get("Mcp-Param-Tenant")
    if header_tenant:
        decoded = decode_header_value(header_tenant)
        header_tenant = None if decoded is MALFORMED_SENTINEL else decoded
    if not header_tenant:
        # What a server says when the header it needs did not arrive. The
        # client refreshes tools/list once and retries.
        return error(request_id, HEADER_MISMATCH, "Mcp-Param-Tenant header is required for this tool")

    section = arguments.get("section", "overview")
    return result(
        request_id,
        {
            "content": [
                {
                    "type": "text",
                    "text": f"{section} report for tenant {header_tenant}",
                }
            ],
            "isError": False,
            # Bound to the credentials this request went out with: the client
            # keeps it out of any other authorization context's cache.
            "cacheScope": "private",
            "ttlMs": 10_000,
        },
    )


def create_ticket_tool(request_id, arguments, params):
    """Multi round-trip: the server asks, the client answers, the client retries.

    First call comes back as input_required with the questions and an opaque
    requestState. The client fulfils each question with the handlers it
    already has and re-sends the same request with inputResponses plus that
    state echoed back; this handler then sees the answers and completes.
    """
    responses = (params or {}).get("inputResponses")
    state = (params or {}).get("requestState")

    if responses and state:
        # requestState is opaque to the client but not unchecked here: it is
        # this server's own handle on the round it started. A state it never
        # issued is a forged continuation, not a resumption.
        with rounds_lock:
            round_record = pending_rounds.pop(state, None)
        if round_record is None:
            return error(request_id, -32602, "unknown requestState")

        reporter = responses.get("reporter") or {}
        # The host's answer carries an action. "accept" is the only one that
        # means go ahead; a decline or a cancel must not open a ticket.
        action = reporter.get("action")
        if action != "accept":
            return result(
                request_id,
                {"content": [{"type": "text", "text": f"no ticket opened ({action or 'no answer'})"}],
                 "isError": False},
            )

        content = reporter.get("content")
        name = content.get("name", "unknown") if isinstance(content, dict) else "unknown"
        summary = round_record.get("summary", arguments.get("summary", ""))
        ticket_id = f"TICKET-{uuid.uuid4().hex[:6].upper()}"
        return result(
            request_id,
            {
                "content": [
                    {"type": "text", "text": f"{ticket_id} opened for {name}: {summary}"}
                ],
                "isError": False,
            },
        )

    # Only ask for something the client said it can answer. A server that asks
    # a client with no elicitation capability has nowhere to go, so it says so
    # in the terms the revision defines instead of stalling the call.
    # A client may declare only elicitation.url, which cannot answer the form
    # request this tool sends. An empty elicitation object is the older,
    # mode-less declaration and is taken as form-capable.
    caps = request_meta(params).get(META_CLIENT_CAPS) or {}
    elicitation = caps.get("elicitation")
    form_capable = isinstance(elicitation, dict) and (not elicitation or "form" in elicitation)
    if not form_capable:
        return error(request_id, MISSING_CAPABILITY,
                     "create_ticket needs to ask the host for the reporter",
                     {"requiredCapabilities": {"elicitation": {"form": {}}}})

    state = uuid.uuid4().hex
    with rounds_lock:
        pending_rounds[state] = {"summary": arguments.get("summary", "")}
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {
            "resultType": "input_required",
            "requestState": state,
            "inputRequests": {
                "reporter": {
                    "method": "elicitation/create",
                    "params": {
                        "mode": "form",
                        "message": "Who is reporting this ticket?",
                        "requestedSchema": {
                            "type": "object",
                            "properties": {"name": {"type": "string"}},
                            "required": ["name"],
                        },
                    },
                }
            },
        },
    }


def run_task(task_id):
    time.sleep(1.5)
    with tasks_lock:
        task = tasks.get(task_id)
        if not task or task["status"] == "cancelled":
            return
        task["status"] = "completed"
        task["lastUpdatedAt"] = now_iso()
        task["result"] = {
            "content": [{"type": "text", "text": f"built {task['target']}"}],
            "isError": False,
        }


def client_declared_tasks(params):
    """Whether THIS request's client capabilities declare the tasks extension."""
    caps = request_meta(params).get(META_CLIENT_CAPS) or {}
    extensions = caps.get(META_CLIENT_CAPS_EXTENSIONS) or {}
    return TASKS_EXTENSION in extensions


def slow_build_tool(request_id, arguments, params):
    # taskSupport is "optional", so this tool owes an ordinary result to a
    # client that did not ask for task behaviour. Answering such a client with
    # resultType "task" would leave work running that it may not accept and
    # cannot collect: it rejects the unrecognized result type outright.
    if not client_declared_tasks(params):
        time.sleep(0.2)
        return result(
            request_id,
            {
                "content": [{"type": "text", "text": f"built {arguments.get('target', 'default')}"}],
                "isError": False,
            },
        )

    task_id = f"task-{uuid.uuid4().hex[:8]}"
    created = now_iso()
    with tasks_lock:
        tasks[task_id] = {
            "taskId": task_id,
            "status": "working",
            "createdAt": created,
            "lastUpdatedAt": created,
            "target": arguments.get("target", "default"),
            "result": None,
        }
    threading.Thread(target=run_task, args=(task_id,), daemon=True).start()
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {
            "resultType": "task",
            "taskId": task_id,
            "status": "working",
            "createdAt": created,
            "lastUpdatedAt": created,
            "ttlMs": 60_000,
            "pollIntervalMs": 200,
        },
    }


def handle_tasks_get(request_id, params):
    if not client_declared_tasks(params):
        return error(request_id, MISSING_CAPABILITY, "tasks/get needs the tasks extension",
                     {"requiredCapabilities": {"extensions": {TASKS_EXTENSION: {}}}})

    task_id = (params or {}).get("taskId")
    with tasks_lock:
        task = tasks.get(task_id)
        if not task:
            return error(request_id, -32602, f"unknown task: {task_id}")
        payload = {
            "taskId": task["taskId"],
            "status": task["status"],
            "createdAt": task["createdAt"],
            "lastUpdatedAt": task["lastUpdatedAt"],
            "ttlMs": 60_000,
            "pollIntervalMs": 200,
        }
        if task["status"] == "completed" and task["result"]:
            # A completed DetailedTask carries the tool's result as a nested
            # `result` object, not merged into the task itself.
            payload["result"] = task["result"]
    return result(request_id, payload)


def handle_tools_call(request_id, params):
    name = (params or {}).get("name")
    arguments = (params or {}).get("arguments") or {}

    if name == "echo":
        return echo_tool(request_id, arguments)
    if name == "tenant_report":
        return tenant_report_tool(request_id, arguments)
    if name == "create_ticket":
        return create_ticket_tool(request_id, arguments, params)
    if name == "slow_build":
        return slow_build_tool(request_id, arguments, params)
    return error(request_id, -32602, f"unknown tool: {name}")


# ---------------------------------------------------------------------------
# subscriptions/listen — one long-lived SSE stream per request
# ---------------------------------------------------------------------------


def sse(payload):
    return f"event: message\ndata: {json.dumps(payload)}\n\n"


def listen_stream(request_id, params):
    """Acknowledge what we will watch, send notifications, then end the request.

    The subscription's identity is the listen request's id, carried on every
    notification in `_meta`. Ending it is a normal response to that request;
    the client also ends it by closing the stream.
    """
    wanted = (params or {}).get("notifications") or {}
    acknowledged = {}
    unsupported = {}
    for key, value in wanted.items():
        if key not in ("toolsListChanged", "resourcesListChanged", "promptsListChanged"):
            unsupported[key] = value
        elif value:
            acknowledged[key] = value
        # A flag the client sent as false is not a subscription: it is neither
        # acknowledged nor unsupported, and nothing is delivered for it.

    yield sse(
        {
            "jsonrpc": "2.0",
            "method": "notifications/subscriptions/acknowledged",
            "params": {
                "_meta": {META_SUBSCRIPTION_ID: request_id},
                "notifications": acknowledged,
                "unsupported": unsupported,
            },
        }
    )

    for index in range(3):
        time.sleep(0.6)
        if acknowledged.get("toolsListChanged"):
            yield sse(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/tools/list_changed",
                    "params": {"_meta": {META_SUBSCRIPTION_ID: request_id}, "round": index + 1},
                }
            )

    yield sse(
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": {"resultType": "complete", "_meta": {META_SUBSCRIPTION_ID: request_id}},
        }
    )


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Security boundary
#
# A local MCP server is reachable from any page the user's browser loads, so
# the transport spec makes two checks mandatory rather than optional. Both are
# here because this file is what someone copies when writing their own server.
# ---------------------------------------------------------------------------

# Only a loopback page may talk to a loopback server. A request with no Origin
# is not from a browser (curl, a native host) and is allowed.
ALLOWED_ORIGIN_HOSTS = {"localhost", "127.0.0.1", "[::1]", "::1"}


def origin_allowed(origin):
    if not origin:
        return True
    try:
        parsed = urlparse(origin)
    except ValueError:
        return False
    return parsed.hostname in ALLOWED_ORIGIN_HOSTS or parsed.netloc.split(":")[0] in ALLOWED_ORIGIN_HOSTS


BASE64_START = "=?base64?"
BASE64_END = "?="


# A sentinel-shaped value that does not decode is not a plain value: a client
# must itself encode any literal that looks like the sentinel, precisely so the
# two cannot be confused. Returning it unchanged would let "=?base64?!!!!?=" in
# the header match the same literal in the body.
MALFORMED_SENTINEL = object()


def decode_header_value(value):
    """Undo the Base64 sentinel a client uses for values a header cannot carry."""
    if value.startswith(BASE64_START) and value.endswith(BASE64_END):
        encoded = value[len(BASE64_START):-len(BASE64_END)]
        try:
            return base64.b64decode(encoded, validate=True).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError, ValueError):
            return MALFORMED_SENTINEL
    return value


def header_annotated_properties(schema, prefix=()):
    """Every (path, header name) an inputSchema annotates with x-mcp-header."""
    found = []
    for name, prop in (schema.get("properties") or {}).items():
        if not isinstance(prop, dict):
            continue
        header = prop.get("x-mcp-header")
        if isinstance(header, str):
            found.append((prefix + (name,), header))
        if prop.get("type") == "object":
            found.extend(header_annotated_properties(prop, prefix + (name,)))
    return found


def argument_at(arguments, path):
    value = arguments
    for step in path:
        if not isinstance(value, dict) or step not in value:
            return None
        value = value[step]
    return value


# Which request field mirrors into Mcp-Name, per the Streamable HTTP standard
# request headers (the tasks extension adds the taskId routes).
NAME_HEADER_SOURCES = {
    "tools/call": "name",
    "prompts/get": "name",
    "resources/read": "uri",
    "tasks/get": "taskId",
    "tasks/update": "taskId",
    "tasks/cancel": "taskId",
    "tasks/result": "taskId",
}


def standard_header_problem(method, params):
    """The standard mirrors must agree with the body, on every request.

    An intermediary routes on Mcp-Method, Mcp-Name and MCP-Protocol-Version
    without parsing the body. If the server executes a body that disagrees
    with them, the routing decision and the work done part company — the same
    disagreement the mirrored parameter headers are checked for, and the same
    -32020 answer.
    """
    sent_method = request.headers.get("Mcp-Method")
    if sent_method is None:
        return "Mcp-Method is required"
    if sent_method != method:
        return f"Mcp-Method {sent_method!r} does not match the request method {method!r}"

    sent_version = request.headers.get("MCP-Protocol-Version")
    declared = request_meta(params).get(META_VERSION)
    if sent_version is None:
        return "MCP-Protocol-Version is required"
    if declared is not None and sent_version != declared:
        return "MCP-Protocol-Version does not match the version in _meta"

    key = NAME_HEADER_SOURCES.get(method)
    sent_name = request.headers.get("Mcp-Name")
    if key is None:
        if sent_name is not None:
            return f"Mcp-Name was sent for {method}, which has no name to mirror"
        return None

    expected = (params or {}).get(key)
    if expected is None:
        return "Mcp-Name was sent for an absent parameter" if sent_name is not None else None
    if sent_name is None:
        return f"Mcp-Name is required for {method}"

    decoded = decode_header_value(sent_name)
    if decoded is MALFORMED_SENTINEL:
        return "Mcp-Name is not a valid encoded value"
    if decoded != (expected if isinstance(expected, str) else str(expected)):
        return f"Mcp-Name does not match the {key} parameter"
    return None


def param_header_problem(params):
    """The mirrored headers must agree with the arguments they were derived from.

    An intermediary routes on the header while the server executes the body, so
    a server that trusts one without checking the other lets the two disagree.
    The revision answers a disagreement with -32020.
    """
    name = (params or {}).get("name")
    tool = next((t for t in TOOLS if t["name"] == name), None)
    if not tool:
        return None

    arguments = (params or {}).get("arguments") or {}
    for path, header in header_annotated_properties(tool.get("inputSchema") or {}):
        sent = request.headers.get(f"Mcp-Param-{header}")
        expected = argument_at(arguments, path)
        if expected is None:
            if sent is not None:
                return f"Mcp-Param-{header} was sent for an argument that is absent"
            continue
        if sent is None:
            return f"Mcp-Param-{header} is required for this tool"
        decoded = decode_header_value(sent)
        if decoded is MALFORMED_SENTINEL:
            return f"Mcp-Param-{header} is not a valid encoded value"
        if decoded != (expected if isinstance(expected, str) else str(expected)):
            return f"Mcp-Param-{header} does not match the {'.'.join(path)} argument"
    return None


HANDLERS = {
    "server/discover": handle_discover,
    "tools/list": handle_tools_list,
    "tools/call": handle_tools_call,
    "resources/list": handle_resources_list,
    "resources/read": handle_resources_read,
    "prompts/list": handle_prompts_list,
    "prompts/get": handle_prompts_get,
    "tasks/get": handle_tasks_get,
}


@app.route("/mcp", methods=["POST"])
def handle_post():
    # The Origin check comes before anything is parsed: a page the user merely
    # visited must not reach a server bound to their loopback interface.
    if not origin_allowed(request.headers.get("Origin")):
        return Response("origin not allowed", status=403)

    body = request.get_json(silent=True) or {}
    request_id = body.get("id")
    method = body.get("method")
    params = body.get("params") or {}

    # Notifications carry no id and get no body back.
    if request_id is None:
        return Response("", status=202)

    version_problem = check_protocol_version(params)
    if version_problem:
        code, message, data = version_problem
        # A rejection the client can act on: it names what this server speaks,
        # and travels with the 4xx a protocol-level refusal owes.
        return json_response(error(request_id, code, message, data), status=400)

    # The standard mirrors are checked on every request; the parameter mirrors
    # only tools/call carries.
    problem = standard_header_problem(method, params)
    if problem is None and method == "tools/call":
        problem = param_header_problem(params)
    if problem:
        return json_response(error(request_id, HEADER_MISMATCH, problem), status=400)

    if method == "subscriptions/listen":
        return Response(
            listen_stream(request_id, params),
            mimetype="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    handler = HANDLERS.get(method)
    if not handler:
        # Streamable HTTP backward compatibility: an unknown method answered
        # with 404 and a JSON-RPC -32601 is how a client tells a modern server
        # from a legacy endpoint that never heard of the method.
        return json_response(error(request_id, -32601, f"method not found: {method}"), status=404)
    return json_response(handler(request_id, params))


def json_response(payload, status=200):
    return Response(json.dumps(payload), mimetype="application/json", status=status)


@app.route("/mcp", methods=["GET"])
def handle_get():
    """A modern server has no server-to-client channel, so there is no GET stream.

    405 is the honest answer, and it is what the client expects: it opens no
    GET at all once it has identified the server as modern.
    """
    return Response("the 2026-07-28 revision has no GET event stream", status=405)


if __name__ == "__main__":
    print(f"MCP {PROTOCOL_VERSION} example server on http://localhost:8933/mcp")
    app.run(host="127.0.0.1", port=8933, threaded=True)
