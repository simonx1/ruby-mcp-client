#!/usr/bin/env python3
"""
MCP Server demonstrating Elicitation via Streamable HTTP Transport (MCP 2025-06-18)

This server provides tools that use elicitation to request user input during
execution over HTTP with SSE-formatted responses.

Usage:
    # Install dependencies
    pip install flask

    # Run server
    python elicitation_streamable_server.py

    # Server runs on http://localhost:8000/mcp

Requirements:
    pip install flask
"""

import json
import threading
import uuid
from datetime import datetime
from flask import Flask, request, Response, jsonify
from queue import Queue, Empty
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Store active sessions
sessions = {}


class Session:
    def __init__(self, session_id):
        self.session_id = session_id
        self.created_at = datetime.now()
        self.last_activity = datetime.now()
        self.event_queue = Queue()
        self.active = True
        self.elicitation_responses = {}  # Store elicitation responses by elicitation_id
        self.elicitation_events = {}  # Store threading events for elicitation waits


def generate_session_id():
    """Generate a unique session ID"""
    return str(uuid.uuid4())


def generate_elicitation_id():
    """Generate a unique elicitation ID"""
    return str(uuid.uuid4())


def format_sse_event(event_type, data, event_id=None):
    """Format data as an SSE event"""
    lines = []
    if event_id:
        lines.append(f"id: {event_id}")
    lines.append(f"event: {event_type}")
    lines.append(f"data: {json.dumps(data)}")
    lines.append("")  # Empty line to end the event
    return "\n".join(lines) + "\n"


def get_tools_list():
    """Return the list of available tools"""
    return {
        "tools": [
            {
                "name": "create_document",
                "description": "Create a document interactively via elicitation. Asks for title, author, and content.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "format": {
                            "type": "string",
                            "description": "Document format",
                            "enum": ["markdown", "html", "text"],
                            "default": "text"
                        }
                    }
                }
            },
            {
                "name": "delete_files",
                "description": "Delete files with confirmation. Uses elicitation to confirm destructive operation.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "paths": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "File paths to delete"
                        }
                    },
                    "required": ["paths"]
                }
            },
            {
                "name": "deploy_application",
                "description": "Deploy application with multi-step confirmation.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "environment": {
                            "type": "string",
                            "enum": ["development", "staging", "production"],
                            "description": "Deployment environment"
                        }
                    },
                    "required": ["environment"]
                }
            }
        ]
    }


def request_elicitation(session, message, schema):
    """Request elicitation from the client and wait for response"""
    elicitation_id = generate_elicitation_id()

    # Create an event to wait for the response
    response_event = threading.Event()
    session.elicitation_events[elicitation_id] = response_event

    # Send elicitation request to client
    # Note: Must include "id" field for JSON-RPC request
    elicitation_request = {
        "jsonrpc": "2.0",
        "id": elicitation_id,  # Include id so it's treated as a request, not notification
        "method": "elicitation/create",
        "params": {
            "elicitationId": elicitation_id,
            "message": message,
            "schema": schema
        }
    }

    session.event_queue.put(format_sse_event("message", elicitation_request))
    logger.info(
        f"Sent elicitation request {elicitation_id} to session {
            session.session_id}")

    # Wait for response (with timeout)
    timeout = 120  # 2 minutes for user to respond
    if response_event.wait(timeout):
        # Response received
        response = session.elicitation_responses.get(elicitation_id)

        # Clean up
        del session.elicitation_events[elicitation_id]
        if elicitation_id in session.elicitation_responses:
            del session.elicitation_responses[elicitation_id]

        return response
    else:
        # Timeout
        logger.warning(f"Elicitation {elicitation_id} timed out")
        del session.elicitation_events[elicitation_id]
        return {"action": "cancel"}


def create_document_tool(session, tool_args):
    """Create a document interactively via elicitation"""
    format_type = tool_args.get('format', 'text')

    # Step 1: Request document details (title and author)
    details_schema = {
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": "The document title",
                "minLength": 1
            },
            "author": {
                "type": "string",
                "description": "The document author",
                "default": "Anonymous"
            }
        },
        "required": ["title"]
    }

    details_result = request_elicitation(
        session,
        "Please provide document details:",
        details_schema
    )

    if details_result.get('action') == 'decline':
        return "User declined to provide document details. Operation cancelled."
    elif details_result.get('action') == 'cancel':
        return "User cancelled the operation."

    title = details_result.get('content', {}).get('title', 'Untitled')
    author = details_result.get('content', {}).get('author', 'Anonymous')

    # Step 2: Request document content
    content_schema = {
        "type": "object",
        "properties": {
            "content": {
                "type": "string",
                "description": "The document content",
                "minLength": 1
            }
        },
        "required": ["content"]
    }

    content_result = request_elicitation(
        session,
        f"Please provide content for document '{title}' by {author}:",
        content_schema
    )

    if content_result.get('action') == 'decline':
        return f"User declined to provide content. Document '{
            title}' not created."
    elif content_result.get('action') == 'cancel':
        return "User cancelled the operation."

    content = content_result.get('content', {}).get('content', '')

    # Format the document
    if format_type == 'markdown':
        document = f"# {title}\n\nBy: {author}\n\n{content}"
    elif format_type == 'html':
        document = f"<html><head><title>{title}</title></head><body><h1>{
            title}</h1><p>By: {author}</p><p>{content}</p></body></html>"
    else:
        document = f"{title}\n\nBy: {author}\n\n{content}"

    return f"Document created successfully!\n\nFormat: {
        format_type}\n\n{document}"


def delete_files_tool(session, tool_args):
    """Delete files with confirmation"""
    file_pattern = tool_args.get('file_pattern', '*.tmp')

    # Simulate finding files
    files_found = ["temp1.tmp", "temp2.tmp", "cache.tmp"]

    # Request confirmation
    confirmation_schema = {
        "type": "object",
        "properties": {
            "confirm": {
                "type": "boolean",
                "description": "Confirm the operation"
            },
            "reason": {
                "type": "string",
                "description": "Optional reason for declining",
                "default": ""
            }
        },
        "required": ["confirm"]
    }

    confirmation_result = request_elicitation(
        session,
        f"⚠️  WARNING: Delete Files\n\nPattern: {file_pattern}\nFiles to delete: {
            len(files_found)}\n- {
            ', '.join(files_found)}\n\nThis operation cannot be undone. Do you want to proceed?",
        confirmation_schema)

    if confirmation_result.get('action') == 'decline':
        return "❌ User declined. No files were deleted."
    elif confirmation_result.get('action') == 'cancel':
        return "⊗ Operation cancelled. No files were deleted."

    if not confirmation_result.get('content', {}).get('confirm', False):
        reason = confirmation_result.get(
            'content', {}).get(
            'reason', 'No reason provided')
        return f"❌ Deletion not confirmed. Reason: {
            reason}\nNo files were deleted."

    # Simulate deletion
    return f"✅ Successfully deleted {
        len(files_found)} files:\n- " + "\n- ".join(files_found)


def deploy_application_tool(session, tool_args):
    """Deploy application with multi-step confirmation"""
    environment = tool_args.get('environment', 'development')
    version = tool_args.get('version', 'v1.0.0')

    # Step 1: Initial confirmation
    deploy_schema = {
        "type": "object",
        "properties": {
            "confirm": {
                "type": "boolean",
                "description": "Confirm deployment"
            }
        },
        "required": ["confirm"]
    }

    initial_confirmation = request_elicitation(
        session,
        f"🚀 Deploy Application\n\nEnvironment: {environment}\nVersion: {version}\n\n"
        f"Do you want to proceed with deployment?",
        deploy_schema
    )

    if initial_confirmation.get('action') != 'accept' or not initial_confirmation.get(
        'content',
        {}).get(
        'confirm',
            False):
        return "❌ Deployment cancelled at initial confirmation."

    # Step 2: Production-specific confirmation
    if environment == 'production':
        prod_confirmation = request_elicitation(session, f"⚠️  PRODUCTION DEPLOYMENT\n\nYou are deploying version {
            version} to PRODUCTION.\n\nThis will affect live users. Please confirm again:", deploy_schema)

        if prod_confirmation.get('action') != 'accept' or not prod_confirmation.get(
                'content',
                {}).get(
                'confirm',
                False):
            return "❌ Production deployment cancelled at final confirmation."

    # Simulate deployment
    return f"✅ Successfully deployed version {version} to {
        environment}!\n\nDeployment completed at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}"


@app.route('/mcp', methods=['POST'], strict_slashes=False)
def handle_rpc():
    """Handle JSON-RPC requests with SSE-formatted responses"""
    try:
        # Get request data
        request_data = request.get_json()
        logger.debug(f"Received request: {request_data}")

        # Get session ID from headers
        session_id = request.headers.get('Mcp-Session-Id')

        method = request_data.get('method')
        params = request_data.get('params', {})
        request_id = request_data.get('id')

        # Handle different methods
        if method == 'initialize':
            # Create new session
            session_id = generate_session_id()
            session = Session(session_id)
            sessions[session_id] = session

            response_data = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {
                        "tools": {},
                        "elicitation": {}  # Advertise elicitation support
                    },
                    "serverInfo": {
                        "name": "elicitation-streamable-demo",
                        "version": "1.0.0"
                    }
                }
            }

            # Return SSE formatted response with session header
            response = Response(
                format_sse_event("message", response_data),
                content_type='text/event-stream',
                headers={
                    'Mcp-Session-Id': session_id,
                    'Cache-Control': 'no-cache'
                }
            )
            logger.info(f"Created session: {session_id}")
            return response

        elif method == 'notifications/initialized':
            # Client acknowledged initialization
            logger.info(f"Session {session_id} initialized")
            return Response(
                "", status=202, headers={
                    'Mcp-Session-Id': session_id})

        elif method == 'tools/list':
            response_data = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "tools": [
                        {
                            "name": "create_document",
                            "description": ("Create a document interactively via elicitation. "
                                            "Asks for title, author, and content."),
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "format": {
                                        "type": "string",
                                        "description": "Document format",
                                        "enum": ["markdown", "html", "text"],
                                        "default": "text"
                                    }
                                }
                            }
                        },
                        {
                            "name": "delete_files",
                            "description": ("Delete files with confirmation. "
                                            "Uses elicitation to confirm destructive operation."),
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "file_pattern": {
                                        "type": "string",
                                        "description": "File pattern to match"
                                    }
                                },
                                "required": ["file_pattern"]
                            }
                        },
                        {
                            "name": "deploy_application",
                            "description": "Deploy application with multi-step confirmation.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "environment": {
                                        "type": "string",
                                        "description": "Deployment environment"
                                    },
                                    "version": {
                                        "type": "string",
                                        "description": "Version to deploy"
                                    }
                                },
                                "required": ["environment", "version"]
                            }
                        }
                    ]
                }
            }
            return Response(
                format_sse_event("message", response_data),
                content_type='text/event-stream',
                headers={'Cache-Control': 'no-cache'}
            )

        elif method == 'tools/call':
            tool_name = params.get('name')
            tool_args = params.get('arguments', {})

            if not session_id or session_id not in sessions:
                response_data = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32603,
                        "message": "Session not found"
                    }
                }
                return Response(
                    format_sse_event("message", response_data),
                    content_type='text/event-stream',
                    headers={'Cache-Control': 'no-cache'}
                )

            session = sessions[session_id]

            # Execute tool in a separate thread to allow async elicitation
            result_container = {}

            def execute_tool():
                try:
                    if tool_name == 'create_document':
                        result_container['result'] = create_document_tool(
                            session, tool_args)
                    elif tool_name == 'delete_files':
                        result_container['result'] = delete_files_tool(
                            session, tool_args)
                    elif tool_name == 'deploy_application':
                        result_container['result'] = deploy_application_tool(
                            session, tool_args)
                    else:
                        result_container['error'] = f"Unknown tool: {
                            tool_name}"
                except Exception as e:
                    logger.error(f"Error executing tool {tool_name}: {e}")
                    result_container['error'] = str(e)

            # Execute tool in background thread
            tool_thread = threading.Thread(target=execute_tool)
            tool_thread.start()
            tool_thread.join(timeout=180)  # 3 minute max for tool execution

            if 'result' in result_container:
                response_data = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "content": [
                            {
                                "type": "text",
                                "text": result_container['result']
                            }
                        ]
                    }
                }
            else:
                response_data = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32603,
                        "message": result_container.get(
                            'error',
                            'Tool execution failed')}}

            return Response(
                format_sse_event("message", response_data),
                content_type='text/event-stream',
                headers={'Cache-Control': 'no-cache'}
            )

        elif method == 'elicitation/response':
            # Handle elicitation response from client
            elicitation_id = params.get('elicitationId')
            action = params.get('action')
            content = params.get('content', {})

            if session_id and session_id in sessions:
                session = sessions[session_id]

                # Store the response
                session.elicitation_responses[elicitation_id] = {
                    'action': action,
                    'content': content
                }

                # Signal that response is ready
                if elicitation_id in session.elicitation_events:
                    session.elicitation_events[elicitation_id].set()

                logger.info(f"Received elicitation response for {
                            elicitation_id}: {action}")

                # Return empty success response
                return Response(
                    "", status=202, headers={
                        'Mcp-Session-Id': session_id})
            else:
                return Response("Session not found", status=404)

        else:
            # Unknown method
            response_data = {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {
                    "code": -32601,
                    "message": f"Method not found: {method}"
                }
            }
            return Response(
                format_sse_event("message", response_data),
                content_type='text/event-stream',
                headers={'Cache-Control': 'no-cache'}
            )

    except Exception as e:
        logger.error(f"Error handling request: {e}", exc_info=True)
        return Response(
            json.dumps({
                "jsonrpc": "2.0",
                "id": request_data.get('id') if 'request_data' in locals() else None,
                "error": {
                    "code": -32603,
                    "message": f"Internal error: {str(e)}"
                }
            }),
            status=500,
            content_type='application/json'
        )


@app.route('/mcp', methods=['GET'], strict_slashes=False)
def handle_events():
    """Handle SSE events connection"""
    session_id = request.headers.get('Mcp-Session-Id')

    if not session_id or session_id not in sessions:
        return Response("Session not found", status=404)

    session = sessions[session_id]
    logger.info(f"Events connection established for session: {session_id}")

    def generate_events():
        try:
            while session.active:
                # Check for events in the queue
                try:
                    event = session.event_queue.get(timeout=30)
                    yield event
                except Empty:
                    # Send keepalive comment if no events
                    yield ": keepalive\n\n"
        except GeneratorExit:
            logger.info(f"Events connection closed for session: {session_id}")

    return Response(
        generate_events(),
        content_type='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no',
            'Connection': 'keep-alive'
        }
    )


@app.route('/mcp', methods=['DELETE'], strict_slashes=False)
def handle_session_termination():
    """Handle session termination"""
    session_id = request.headers.get('Mcp-Session-Id')

    if session_id in sessions:
        session = sessions[session_id]
        session.active = False
        del sessions[session_id]
        logger.info(f"Terminated session: {session_id}")
        return Response("", status=200)

    return Response("Session not found", status=404)

# Traditional SSE Transport Endpoints
# GET /sse - SSE stream for server-to-client events
# POST /sse - JSON-RPC endpoint for client-to-server requests


@app.route('/sse', methods=['GET'], strict_slashes=False)
def handle_sse_stream():
    """Handle traditional SSE transport - GET for SSE stream"""
    # Create a new session for this SSE connection
    session_id = str(uuid.uuid4())
    session = Session(session_id)
    sessions[session_id] = session

    logger.info(f"SSE stream opened for session: {session_id}")

    def generate_sse_events():
        try:
            # Send endpoint as first event (just the path string)
            yield "event: endpoint\ndata: /sse\n\n"

            # Stream events from the queue (client will send initialize via
            # POST)
            while session.active:
                try:
                    event = session.event_queue.get(timeout=30)
                    yield event
                except Empty:
                    # Send keepalive comment
                    yield ": keepalive\n\n"
        except GeneratorExit:
            logger.info(f"SSE stream closed for session: {session_id}")
            session.active = False
            if session_id in sessions:
                del sessions[session_id]

    response = Response(
        generate_sse_events(),
        content_type='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no',
            'Connection': 'keep-alive',
            'Mcp-Session-Id': session_id  # Return session ID in header
        }
    )
    return response


@app.route('/sse', methods=['POST'], strict_slashes=False)
def handle_sse_rpc():
    """Handle traditional SSE transport - POST for JSON-RPC requests"""
    # For SSE transport, we can identify session by matching the connection
    # or use a header. Let's look for session ID in request body or create new
    # session

    try:
        data = request.get_json()

        # Get session ID from header (sent by SSE client after opening stream)
        session_id = request.headers.get('Mcp-Session-Id')

        if session_id and session_id in sessions:
            session = sessions[session_id]
            logger.debug(f"Using existing session: {session_id}")
        else:
            # Fallback: find first active session or create new one
            session = None
            if sessions:
                for sid, sess in sessions.items():
                    if sess.active:
                        session = sess
                        session_id = sid
                        logger.debug(f"Found active session: {session_id}")
                        break

            if not session:
                # Create new session if none exists
                session_id = str(uuid.uuid4())
                session = Session(session_id)
                sessions[session_id] = session
                logger.info(f"Created new session for SSE RPC: {session_id}")

        # Handle the JSON-RPC request or notification
        method = data.get('method')
        rpc_id = data.get('id')
        params = data.get('params', {})

        logger.info(f"SSE RPC {'notification' if rpc_id is None else 'request'}: {
                    method} (id: {rpc_id})")

        # Handle notifications (no response needed)
        if method and rpc_id is None:
            if method == 'notifications/initialized':
                logger.debug("Client initialized notification received")
            else:
                logger.debug(f"Received notification: {method}")
            return Response('', status=202)

        # Handle JSON-RPC responses (id but no method) - these are elicitation
        # responses
        if rpc_id and not method:
            # This is a response to an elicitation request
            result = data.get('result', {})
            elicitation_id = rpc_id  # The id is the elicitation ID

            # Store the response
            session.elicitation_responses[elicitation_id] = result

            # Trigger the event to unblock waiting tool
            if elicitation_id in session.elicitation_events:
                session.elicitation_events[elicitation_id].set()
                logger.info(f"Received elicitation response for {
                            elicitation_id}: {result.get('action')}")

            return Response('', status=202)

        # Route to appropriate handler and queue response to SSE stream
        if method == 'initialize':
            result = {
                'protocolVersion': '2025-06-18',
                'capabilities': {
                    'tools': {},
                    'elicitation': {}
                },
                'serverInfo': {
                    'name': 'elicitation-demo',
                    'version': '1.0.0'
                }
            }
            response = {
                'jsonrpc': '2.0',
                'id': rpc_id,
                'result': result
            }
            # Queue response to SSE stream
            sse_event = format_sse_event('message', response)
            session.event_queue.put(sse_event)

        elif method == 'tools/list':
            result = get_tools_list()
            response = {
                'jsonrpc': '2.0',
                'id': rpc_id,
                'result': result
            }
            # Queue response to SSE stream
            sse_event = format_sse_event('message', response)
            session.event_queue.put(sse_event)

        elif method == 'tools/call':
            tool_name = params.get('name')
            tool_args = params.get('arguments', {})

            # Execute tool in a separate thread to allow async elicitation
            result_container = {}

            def execute_tool():
                try:
                    if tool_name == 'create_document':
                        result_container['result'] = create_document_tool(
                            session, tool_args)
                    elif tool_name == 'delete_files':
                        result_container['result'] = delete_files_tool(
                            session, tool_args)
                    elif tool_name == 'deploy_application':
                        result_container['result'] = deploy_application_tool(
                            session, tool_args)
                    else:
                        result_container['error'] = f"Unknown tool: {
                            tool_name}"
                except Exception as e:
                    logger.error(f"Error executing tool {tool_name}: {e}")
                    result_container['error'] = str(e)

            # Execute tool in background thread
            tool_thread = threading.Thread(target=execute_tool)
            tool_thread.start()
            tool_thread.join(timeout=180)  # 3 minute max for tool execution

            if 'result' in result_container:
                response = {
                    'jsonrpc': '2.0',
                    'id': rpc_id,
                    'result': {
                        'content': [
                            {
                                'type': 'text',
                                'text': result_container['result']
                            }
                        ]
                    }
                }
            else:
                response = {
                    'jsonrpc': '2.0',
                    'id': rpc_id,
                    'error': {
                        'code': -32603,
                        'message': result_container.get(
                            'error',
                            'Tool execution failed')}}

            # Queue response to SSE stream
            sse_event = format_sse_event('message', response)
            session.event_queue.put(sse_event)

        elif method == 'elicitation/response':
            # Handle elicitation response
            elicitation_id = params.get('elicitationId')
            action = params.get('action')
            content = params.get('content', {})

            # Store the response
            session.elicitation_responses[elicitation_id] = {
                'action': action, 'content': content}

            # Trigger the event to unblock waiting tool
            if elicitation_id in session.elicitation_events:
                session.elicitation_events[elicitation_id].set()
                logger.info(
                    f"Received elicitation/response for {elicitation_id}: {action}")

            # No response needed - elicitation handler will continue
            return Response('', status=202)

        elif method == 'ping':
            response = {
                'jsonrpc': '2.0',
                'id': rpc_id,
                'result': {}
            }
            # Queue response to SSE stream
            sse_event = format_sse_event('message', response)
            session.event_queue.put(sse_event)

        else:
            response = {
                'jsonrpc': '2.0',
                'id': rpc_id,
                'error': {
                    'code': -32601,
                    'message': f'Method not found: {method}'
                }
            }
            # Queue response to SSE stream
            sse_event = format_sse_event('message', response)
            session.event_queue.put(sse_event)

        # Return 202 Accepted (response will be sent via SSE stream)
        return Response('', status=202)

    except Exception as e:
        logger.error(f"Error handling SSE RPC request: {e}")
        return jsonify({
            'jsonrpc': '2.0',
            'id': data.get('id') if 'data' in locals() else None,
            'error': {
                'code': -32603,
                'message': f'Internal error: {str(e)}'
            }
        }), 500


if __name__ == "__main__":
    print("🚀 Starting Elicitation MCP Server")
    print("=" * 60)
    print("Server endpoints:")
    print("  • Streamable HTTP: http://localhost:8000/mcp")
    print("  • Traditional SSE: http://localhost:8000/sse")
    print("\nTransport Support:")
    print("  • Streamable HTTP - Unified endpoint (GET/POST /mcp)")
    print("  • SSE - Separate endpoints (GET /sse for stream, POST /sse for RPC)")
    print("\nFeatures: Elicitation support enabled")
    print("\nAvailable tools:")
    print("  • create_document - Multi-step: asks for title/author, then content")
    print("  • delete_files - Confirmation with optional decline reason")
    print("  • deploy_application - Multi-step: initial + production confirmation")
    print("\nRuby client examples:")
    print("  ruby examples/elicitation/test_elicitation_streamable.rb  # Streamable HTTP")
    print("  ruby examples/elicitation/test_elicitation_sse_simple.rb  # SSE transport")
    print("\nPress Ctrl+C to stop the server")
    print("-" * 60)

    # Run the Flask app
    app.run(host='0.0.0.0', port=8000, debug=False, threaded=True)
