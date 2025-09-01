#!/usr/bin/env python3
"""
Enhanced MCP Echo Server with Streamable HTTP Transport (MCP 2025-03-26)

This server demonstrates the full capabilities of the Streamable HTTP transport:
- SSE event streaming for notifications
- Ping/pong keepalive mechanism
- Server-to-client notifications
- Progress notifications during tool execution
- Session management with MCP-Session-Id headers

To run this server:
1. Install dependencies: pip install flask flask-sse-no-deps
2. Run the server: python echo_server_streamable.py
3. The server will start on http://localhost:8931/mcp

The server provides:
- Echo tool with progress notifications
- Long-running task simulation
- Periodic server notifications
- Ping/pong keepalive every 10 seconds
"""

import json
import time
import threading
import uuid
from datetime import datetime
from flask import Flask, request, Response, jsonify
from queue import Queue
import logging

# Configure logging
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Store active sessions
sessions = {}

# SSE event queues for each session
event_queues = {}

class Session:
    def __init__(self, session_id):
        self.session_id = session_id
        self.created_at = datetime.now()
        self.last_activity = datetime.now()
        self.ping_count = 0
        self.event_queue = Queue()
        self.ping_thread = None
        self.notification_thread = None
        self.active = True

def generate_session_id():
    """Generate a cryptographically secure session ID"""
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

def send_ping(session):
    """Send periodic ping requests to keep connection alive"""
    ping_interval = 10  # seconds
    while session.active:
        time.sleep(ping_interval)
        if session.active:
            ping_data = {
                "jsonrpc": "2.0",
                "method": "ping",
                "id": session.ping_count
            }
            session.event_queue.put(format_sse_event("message", ping_data))
            logger.debug(f"Sent ping {session.ping_count} to session {session.session_id}")
            session.ping_count += 1

def send_notifications(session):
    """Send periodic server notifications"""
    notification_interval = 30  # seconds
    notification_count = 0
    while session.active:
        time.sleep(notification_interval)
        if session.active:
            notification_data = {
                "jsonrpc": "2.0",
                "method": "notification/server_status",
                "params": {
                    "timestamp": datetime.now().isoformat(),
                    "session_uptime": (datetime.now() - session.created_at).total_seconds(),
                    "notification_count": notification_count,
                    "message": f"Server is healthy. Session active for {int((datetime.now() - session.created_at).total_seconds())} seconds"
                }
            }
            session.event_queue.put(format_sse_event("message", notification_data))
            logger.debug(f"Sent notification to session {session.session_id}")
            notification_count += 1

@app.route('/mcp', methods=['POST'])
def handle_rpc():
    """Handle JSON-RPC requests with optional SSE responses"""
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
                    "protocolVersion": "2025-03-26",
                    "capabilities": {
                        "tools": {},
                        "notifications": {
                            "server": ["notification/server_status", "notification/progress"]
                        }
                    },
                    "serverInfo": {
                        "name": "Enhanced Echo Server",
                        "version": "2.0.0"
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
            if session_id and session_id in sessions:
                session = sessions[session_id]
                # Start ping thread
                session.ping_thread = threading.Thread(target=send_ping, args=(session,))
                session.ping_thread.daemon = True
                session.ping_thread.start()
                # Start notification thread
                session.notification_thread = threading.Thread(target=send_notifications, args=(session,))
                session.notification_thread.daemon = True
                session.notification_thread.start()
                logger.info(f"Started background threads for session: {session_id}")
            return Response("", status=202, headers={'Mcp-Session-Id': session_id})
            
        elif method == 'tools/list':
            response_data = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "tools": [
                        {
                            "name": "echo",
                            "description": "Echo back the provided message",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "message": {"type": "string", "description": "The message to echo"}
                                },
                                "required": ["message"]
                            }
                        },
                        {
                            "name": "long_task",
                            "description": "Simulate a long-running task with progress notifications",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "duration": {"type": "number", "description": "Task duration in seconds"},
                                    "steps": {"type": "number", "description": "Number of progress steps"}
                                },
                                "required": ["duration"]
                            }
                        },
                        {
                            "name": "trigger_notification",
                            "description": "Trigger a server notification",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "message": {"type": "string", "description": "Notification message"}
                                }
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
            
            if tool_name == 'echo':
                message = tool_args.get('message', '')
                response_data = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "content": [
                            {
                                "type": "text",
                                "text": f"Echo: {message}"
                            }
                        ]
                    }
                }
                
            elif tool_name == 'long_task':
                duration = tool_args.get('duration', 5)
                steps = tool_args.get('steps', 5)
                
                # Send progress notifications
                if session_id in sessions:
                    session = sessions[session_id]
                    
                    def send_progress():
                        for i in range(steps):
                            time.sleep(duration / steps)
                            progress_notification = {
                                "jsonrpc": "2.0",
                                "method": "notification/progress",
                                "params": {
                                    "progress": (i + 1) * 100 // steps,
                                    "message": f"Step {i + 1} of {steps} completed"
                                }
                            }
                            session.event_queue.put(format_sse_event("message", progress_notification))
                    
                    # Start progress in background
                    threading.Thread(target=send_progress, daemon=True).start()
                
                response_data = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "content": [
                            {
                                "type": "text",
                                "text": f"Long task completed after {duration} seconds with {steps} progress updates"
                            }
                        ]
                    }
                }
                
            elif tool_name == 'trigger_notification':
                message = tool_args.get('message', 'Manual notification triggered')
                
                # Send notification immediately
                if session_id in sessions:
                    session = sessions[session_id]
                    notification = {
                        "jsonrpc": "2.0",
                        "method": "notification/manual",
                        "params": {
                            "timestamp": datetime.now().isoformat(),
                            "message": message
                        }
                    }
                    session.event_queue.put(format_sse_event("message", notification))
                
                response_data = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "content": [
                            {
                                "type": "text",
                                "text": f"Notification sent: {message}"
                            }
                        ]
                    }
                }
                
            else:
                response_data = {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "error": {
                        "code": -32601,
                        "message": f"Unknown tool: {tool_name}"
                    }
                }
            
            return Response(
                format_sse_event("message", response_data),
                content_type='text/event-stream',
                headers={'Cache-Control': 'no-cache'}
            )
            
        # Handle pong responses
        elif 'result' in request_data and request_data.get('result') == {}:
            # This is a pong response
            logger.debug(f"Received pong response for ping {request_data.get('id')} from session {session_id}")
            if session_id in sessions:
                sessions[session_id].last_activity = datetime.now()
            return Response("", status=200)
            
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
        logger.error(f"Error handling request: {e}")
        return jsonify({
            "jsonrpc": "2.0",
            "id": request_data.get('id') if 'request_data' in locals() else None,
            "error": {
                "code": -32603,
                "message": f"Internal error: {str(e)}"
            }
        }), 500

@app.route('/mcp', methods=['GET'])
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
                if not session.event_queue.empty():
                    event = session.event_queue.get()
                    yield event
                else:
                    # Send keepalive comment every 30 seconds if no events
                    yield ": keepalive\n\n"
                    time.sleep(1)
        except GeneratorExit:
            logger.info(f"Events connection closed for session: {session_id}")
            session.active = False
    
    return Response(
        generate_events(),
        content_type='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'X-Accel-Buffering': 'no',  # Disable Nginx buffering
            'Connection': 'keep-alive'
        }
    )

@app.route('/mcp', methods=['DELETE'])
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

def cleanup_inactive_sessions():
    """Clean up inactive sessions periodically"""
    while True:
        time.sleep(60)  # Check every minute
        now = datetime.now()
        inactive_sessions = []
        
        for session_id, session in sessions.items():
            # Remove sessions inactive for more than 5 minutes
            if (now - session.last_activity).total_seconds() > 300:
                inactive_sessions.append(session_id)
        
        for session_id in inactive_sessions:
            session = sessions[session_id]
            session.active = False
            del sessions[session_id]
            logger.info(f"Cleaned up inactive session: {session_id}")

if __name__ == "__main__":
    print("🚀 Enhanced MCP Echo Server with Streamable HTTP Transport")
    print("=" * 60)
    print("Server starting on: http://localhost:8931/mcp")
    print("\nFeatures:")
    print("✅ SSE event streaming")
    print("✅ Ping/pong keepalive (every 10 seconds)")
    print("✅ Server notifications (every 30 seconds)")
    print("✅ Progress notifications")
    print("✅ Session management")
    print("\nAvailable tools:")
    print("  - echo: Echo back a message")
    print("  - long_task: Simulate long-running task with progress")
    print("  - trigger_notification: Trigger a server notification")
    print("\nPress Ctrl+C to stop the server")
    print("-" * 60)
    
    # Start cleanup thread
    cleanup_thread = threading.Thread(target=cleanup_inactive_sessions)
    cleanup_thread.daemon = True
    cleanup_thread.start()
    
    # Run the Flask app
    app.run(host='0.0.0.0', port=8931, debug=False, threaded=True)