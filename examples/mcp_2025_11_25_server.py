#!/usr/bin/env python3
"""
MCP 2025-11-25 Feature Demo Server

A Python MCP server demonstrating ALL new MCP 2025-11-25 features:
- Audio content (base64 audio in tool results)
- Resource annotations with lastModified field
- Tool annotations (readOnlyHint, destructiveHint, idempotentHint, openWorldHint)
- Completion with context parameter
- ResourceLink in tool results
- Task management (tasks/create, tasks/get, tasks/cancel)

Transport: stdio (JSON-RPC over stdin/stdout)
No external dependencies required (Python 3.7+ stdlib only).

Usage:
  python examples/mcp_2025_11_25_server.py
  # Or spawned by Ruby client via stdio transport
"""

import json
import sys
import base64
import struct
import time
import threading
import uuid
import math


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def send_response(response):
    """Write a JSON-RPC response to stdout."""
    data = json.dumps(response)
    sys.stdout.write(data + "\n")
    sys.stdout.flush()


def send_notification(method, params=None):
    """Send a JSON-RPC notification (no id) to stdout."""
    notification = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        notification["params"] = params
    send_response(notification)


def make_result(request_id, result):
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def make_error(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


# ---------------------------------------------------------------------------
# Audio helpers — generate a tiny valid WAV (sine wave beep)
# ---------------------------------------------------------------------------

def generate_wav_beep(duration_ms=200, frequency=440, sample_rate=8000):
    """Generate a minimal WAV file (mono, 8-bit PCM) as bytes."""
    num_samples = int(sample_rate * duration_ms / 1000)
    samples = bytearray(num_samples)
    for i in range(num_samples):
        t = i / sample_rate
        # 8-bit unsigned PCM: center is 128
        value = int(128 + 64 * math.sin(2 * math.pi * frequency * t))
        samples[i] = max(0, min(255, value))

    # Build WAV header
    data_size = num_samples
    bits_per_sample = 8
    num_channels = 1
    byte_rate = sample_rate * num_channels * bits_per_sample // 8
    block_align = num_channels * bits_per_sample // 8

    header = bytearray()
    header += b'RIFF'
    header += struct.pack('<I', 36 + data_size)
    header += b'WAVE'
    header += b'fmt '
    header += struct.pack('<I', 16)                   # Subchunk1Size
    header += struct.pack('<H', 1)                    # AudioFormat (PCM)
    header += struct.pack('<H', num_channels)
    header += struct.pack('<I', sample_rate)
    header += struct.pack('<I', byte_rate)
    header += struct.pack('<H', block_align)
    header += struct.pack('<H', bits_per_sample)
    header += b'data'
    header += struct.pack('<I', data_size)

    return bytes(header) + bytes(samples)


# ---------------------------------------------------------------------------
# Task management (in-memory)
# ---------------------------------------------------------------------------

tasks = {}          # id -> task dict
tasks_lock = threading.Lock()


def create_task_record(task_id, method, params, progress_token=None):
    task = {
        "id": task_id,
        "state": "pending",
        "method": method,
        "params": params,
        "progressToken": progress_token,
        "progress": None,
        "total": None,
        "message": "Task created",
        "result": None,
    }
    with tasks_lock:
        tasks[task_id] = task
    return task


def task_to_response(task):
    """Return the public-facing task fields."""
    result = {"id": task["id"], "state": task["state"]}
    if task.get("progressToken"):
        result["progressToken"] = task["progressToken"]
    if task.get("progress") is not None:
        result["progress"] = task["progress"]
    if task.get("total") is not None:
        result["total"] = task["total"]
    if task.get("message"):
        result["message"] = task["message"]
    if task.get("result") is not None:
        result["result"] = task["result"]
    return result


def run_task_in_background(task_id):
    """Simulate long-running work for a task."""
    # Brief delay so the create response is sent while task is still "pending"
    time.sleep(0.1)
    with tasks_lock:
        task = tasks.get(task_id)
        if not task:
            return
        task["state"] = "running"
        task["total"] = 5
        task["progress"] = 0
        task["message"] = "Starting work..."

    for step in range(1, 6):
        time.sleep(0.3)
        with tasks_lock:
            task = tasks.get(task_id)
            if not task or task["state"] == "cancelled":
                return
            task["progress"] = step
            task["message"] = f"Step {step} of 5"

        # Send progress notification if we have a token
        if task.get("progressToken"):
            send_notification("notifications/progress", {
                "progressToken": task["progressToken"],
                "progress": step,
                "total": 5,
            })

    with tasks_lock:
        task = tasks.get(task_id)
        if task and task["state"] != "cancelled":
            task["state"] = "completed"
            task["message"] = "All steps done"
            task["result"] = {"summary": "Background task finished successfully"}


# ---------------------------------------------------------------------------
# Completion data — supports context parameter
# ---------------------------------------------------------------------------

CITY_DATABASE = {
    "US": ["New York", "Los Angeles", "Chicago", "Houston", "Phoenix"],
    "UK": ["London", "Manchester", "Birmingham", "Leeds", "Glasgow"],
    "JP": ["Tokyo", "Osaka", "Kyoto", "Yokohama", "Nagoya"],
    "FR": ["Paris", "Lyon", "Marseille", "Toulouse", "Nice"],
}


# ---------------------------------------------------------------------------
# Request handlers
# ---------------------------------------------------------------------------

def handle_initialize(request_id, _params):
    return make_result(request_id, {
        "protocolVersion": "2025-11-25",
        "capabilities": {
            "tools": {},
            "resources": {"listChanged": True},
            "completions": {},
            "tasks": {},
        },
        "serverInfo": {
            "name": "MCP 2025-11-25 Feature Demo",
            "version": "1.0.0",
        },
    })


def handle_tools_list(request_id, _params):
    tools = [
        {
            "name": "get_audio",
            "description": "Returns a short audio beep as base64-encoded WAV data",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "frequency": {
                        "type": "number",
                        "description": "Tone frequency in Hz (default: 440)",
                    },
                },
            },
            "annotations": {
                "title": "Get Audio Beep",
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            },
        },
        {
            "name": "get_resource_link",
            "description": "Returns a ResourceLink pointing to a server resource",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "resource_name": {
                        "type": "string",
                        "description": "Name of the resource to link (readme or config)",
                    },
                },
                "required": ["resource_name"],
            },
            "annotations": {
                "title": "Get Resource Link",
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            },
        },
        {
            "name": "delete_item",
            "description": "Simulates deleting an item (demonstrates destructive tool annotation)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "item_id": {
                        "type": "string",
                        "description": "ID of the item to delete",
                    },
                },
                "required": ["item_id"],
            },
            "annotations": {
                "title": "Delete Item",
                "readOnlyHint": False,
                "destructiveHint": True,
                "idempotentHint": True,
                "openWorldHint": False,
            },
        },
        {
            "name": "send_email",
            "description": "Simulates sending an email (demonstrates open-world, non-idempotent tool)",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": {"type": "string", "description": "Recipient email"},
                    "subject": {"type": "string", "description": "Email subject"},
                },
                "required": ["to", "subject"],
            },
            "annotations": {
                "title": "Send Email",
                "readOnlyHint": False,
                "destructiveHint": False,
                "idempotentHint": False,
                "openWorldHint": True,
            },
        },
        {
            "name": "lookup_city",
            "description": "Look up cities — use with completion/complete to test context param",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "country_code": {
                        "type": "string",
                        "description": "Country code (US, UK, JP, FR)",
                    },
                    "city": {
                        "type": "string",
                        "description": "City name",
                    },
                },
                "required": ["country_code", "city"],
            },
            "annotations": {
                "title": "Lookup City",
                "readOnlyHint": True,
                "destructiveHint": False,
                "idempotentHint": True,
                "openWorldHint": False,
            },
        },
    ]
    return make_result(request_id, {"tools": tools})


def handle_tools_call(request_id, params):
    tool_name = params.get("name")
    args = params.get("arguments", {})

    if tool_name == "get_audio":
        frequency = args.get("frequency", 440)
        wav_bytes = generate_wav_beep(duration_ms=200, frequency=int(frequency))
        audio_b64 = base64.b64encode(wav_bytes).decode("utf-8")
        return make_result(request_id, {
            "content": [
                {
                    "type": "audio",
                    "data": audio_b64,
                    "mimeType": "audio/wav",
                },
                {
                    "type": "text",
                    "text": f"Generated {len(wav_bytes)} byte WAV beep at {frequency} Hz",
                },
            ],
        })

    elif tool_name == "get_resource_link":
        resource_name = args.get("resource_name", "readme")
        if resource_name == "config":
            return make_result(request_id, {
                "content": [
                    {
                        "type": "resource_link",
                        "uri": "file:///demo/config.json",
                        "name": "config.json",
                        "description": "Server configuration file",
                        "mimeType": "application/json",
                    },
                    {
                        "type": "text",
                        "text": "Here is a link to the configuration resource",
                    },
                ],
            })
        else:
            return make_result(request_id, {
                "content": [
                    {
                        "type": "resource_link",
                        "uri": "file:///demo/README.md",
                        "name": "README.md",
                        "description": "Project documentation",
                        "mimeType": "text/markdown",
                    },
                    {
                        "type": "text",
                        "text": "Here is a link to the README resource",
                    },
                ],
            })

    elif tool_name == "delete_item":
        item_id = args.get("item_id", "unknown")
        return make_result(request_id, {
            "content": [
                {"type": "text", "text": f"Item '{item_id}' deleted successfully"},
            ],
        })

    elif tool_name == "send_email":
        to = args.get("to", "nobody")
        subject = args.get("subject", "(no subject)")
        return make_result(request_id, {
            "content": [
                {"type": "text", "text": f"Email sent to {to}: {subject}"},
            ],
        })

    elif tool_name == "lookup_city":
        country = args.get("country_code", "US")
        city = args.get("city", "")
        cities = CITY_DATABASE.get(country, [])
        if city in cities:
            return make_result(request_id, {
                "content": [
                    {"type": "text", "text": f"Found {city} in {country}"},
                ],
            })
        else:
            return make_result(request_id, {
                "content": [
                    {"type": "text", "text": f"City '{city}' not found in {country}. Known: {', '.join(cities)}"},
                ],
            })

    else:
        return make_error(request_id, -32601, f"Unknown tool: {tool_name}")


def handle_resources_list(request_id, _params):
    resources = [
        {
            "uri": "file:///demo/README.md",
            "name": "README.md",
            "title": "Project Documentation",
            "description": "Demo README with lastModified annotation",
            "mimeType": "text/markdown",
            "size": 1024,
            "annotations": {
                "audience": ["user", "assistant"],
                "priority": 1.0,
                "lastModified": "2025-11-25T10:30:00Z",
            },
        },
        {
            "uri": "file:///demo/config.json",
            "name": "config.json",
            "title": "Configuration",
            "description": "Demo config with lastModified annotation",
            "mimeType": "application/json",
            "size": 512,
            "annotations": {
                "audience": ["assistant"],
                "priority": 0.8,
                "lastModified": "2025-11-20T08:00:00Z",
            },
        },
        {
            "uri": "file:///demo/audio_sample.wav",
            "name": "audio_sample.wav",
            "title": "Audio Sample",
            "description": "A short audio sample resource",
            "mimeType": "audio/wav",
            "size": 2048,
            "annotations": {
                "audience": ["user"],
                "priority": 0.5,
                "lastModified": "2025-11-22T14:15:00Z",
            },
        },
    ]
    return make_result(request_id, {"resources": resources})


def handle_resources_read(request_id, params):
    uri = params.get("uri", "")

    if uri == "file:///demo/README.md":
        return make_result(request_id, {
            "contents": [{
                "uri": uri,
                "mimeType": "text/markdown",
                "text": "# MCP 2025-11-25 Demo\n\nThis server demonstrates new MCP features.\n",
            }],
        })
    elif uri == "file:///demo/config.json":
        return make_result(request_id, {
            "contents": [{
                "uri": uri,
                "mimeType": "application/json",
                "text": json.dumps({"version": "1.0", "features": ["audio", "resource_link", "tasks"]}),
            }],
        })
    elif uri == "file:///demo/audio_sample.wav":
        wav = generate_wav_beep(100, 880)
        return make_result(request_id, {
            "contents": [{
                "uri": uri,
                "mimeType": "audio/wav",
                "blob": base64.b64encode(wav).decode("utf-8"),
            }],
        })
    else:
        return make_error(request_id, -32602, f"Resource not found: {uri}")


def handle_completion(request_id, params):
    ref = params.get("ref", {})
    argument = params.get("argument", {})
    context = params.get("context", {})

    ref_type = ref.get("type", "")
    arg_name = argument.get("name", "")
    arg_value = argument.get("value", "")

    completions = []

    # Context-aware completion for the lookup_city tool
    if ref_type == "ref/prompt" or ref_type == "ref/resource":
        # Generic completions
        if arg_name == "country_code":
            all_codes = list(CITY_DATABASE.keys())
            completions = [c for c in all_codes if c.lower().startswith(arg_value.lower())]
        elif arg_name == "city":
            # Use context to narrow down cities by previously-resolved country_code
            context_args = context.get("arguments", {})
            country = context_args.get("country_code", "")
            if country and country in CITY_DATABASE:
                cities = CITY_DATABASE[country]
            else:
                # No context — return all cities
                cities = []
                for city_list in CITY_DATABASE.values():
                    cities.extend(city_list)
            completions = [c for c in cities if c.lower().startswith(arg_value.lower())]

    return make_result(request_id, {
        "completion": {
            "values": completions[:10],
            "total": len(completions),
            "hasMore": len(completions) > 10,
        },
    })


def handle_tasks_create(request_id, params):
    task_id = str(uuid.uuid4())
    method = params.get("method", "unknown")
    task_params = params.get("params", {})
    progress_token = params.get("progressToken")

    task = create_task_record(task_id, method, task_params, progress_token)
    # Snapshot response while still in "pending" state
    response = make_result(request_id, task_to_response(task))

    # Start background work (will transition to "running" after a brief delay)
    thread = threading.Thread(target=run_task_in_background, args=(task_id,), daemon=True)
    thread.start()

    return response


def handle_tasks_get(request_id, params):
    task_id = params.get("id", "")
    with tasks_lock:
        task = tasks.get(task_id)
    if not task:
        return make_error(request_id, -32602, f"Task not found: {task_id}")
    return make_result(request_id, task_to_response(task))


def handle_tasks_cancel(request_id, params):
    task_id = params.get("id", "")
    with tasks_lock:
        task = tasks.get(task_id)
        if not task:
            return make_error(request_id, -32602, f"Task not found: {task_id}")
        if task["state"] in ("completed", "failed", "cancelled"):
            return make_error(request_id, -32602,
                              f"Cannot cancel task in state '{task['state']}'")
        task["state"] = "cancelled"
        task["message"] = "Cancelled by client"
    return make_result(request_id, task_to_response(task))


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

HANDLERS = {
    "initialize": handle_initialize,
    "notifications/initialized": lambda _id, _p: None,  # no response needed
    "tools/list": handle_tools_list,
    "tools/call": handle_tools_call,
    "resources/list": handle_resources_list,
    "resources/read": handle_resources_read,
    "completion/complete": handle_completion,
    "tasks/create": handle_tasks_create,
    "tasks/get": handle_tasks_get,
    "tasks/cancel": handle_tasks_cancel,
    "ping": lambda rid, _p: make_result(rid, {}),
}


def main():
    log = lambda msg: sys.stderr.write(f"[server] {msg}\n")  # noqa: E731
    log("MCP 2025-11-25 Feature Demo Server starting (stdio)")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            log(f"Invalid JSON: {line}")
            continue

        method = request.get("method")
        request_id = request.get("id")
        params = request.get("params", {})

        handler = HANDLERS.get(method)

        if handler is None:
            if request_id is not None:
                send_response(make_error(request_id, -32601, f"Method not found: {method}"))
            continue

        response = handler(request_id, params)

        # Notifications (no id) return None — don't send anything back
        if response is not None:
            send_response(response)

    log("Server shutting down")


if __name__ == "__main__":
    main()
