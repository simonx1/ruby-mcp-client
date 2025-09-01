# Streamable HTTP Transport Testing Guide

This directory contains enhanced test servers and clients for validating the Streamable HTTP transport implementation according to MCP specification 2025-03-26.

## Test Components

### 1. Enhanced Echo Server (`echo_server_streamable.py`)

A Python-based MCP server that fully implements the Streamable HTTP transport with:

- **SSE Event Streaming**: Server-sent events for real-time communication
- **Ping/Pong Keepalive**: Sends ping every 10 seconds, expects pong response
- **Server Notifications**: Periodic status updates every 30 seconds
- **Progress Notifications**: Real-time progress updates for long-running tasks
- **Session Management**: Proper session lifecycle with MCP-Session-Id headers
- **Multiple Tools**:
  - `echo`: Simple message echo
  - `long_task`: Simulates long-running task with progress updates
  - `trigger_notification`: Manually trigger a server notification

### 2. Comprehensive Test Client (`echo_server_streamable_client.rb`)

A Ruby client that tests all Streamable HTTP features:

- Establishes SSE connection
- Handles server notifications
- Tests long-running tasks with progress
- Verifies session persistence
- Monitors keepalive activity

### 3. Ping/Pong Test (`test_ping_pong.rb`)

A focused test for the ping/pong keepalive mechanism:

- Monitors ping/pong exchanges
- Verifies session stays active
- Shows keepalive timing

## Installation

### Server Requirements

```bash
# Install Python dependencies
pip install flask

# No additional dependencies needed - uses standard library
```

### Client Requirements

```bash
# Install Ruby dependencies
bundle install
```

## Running the Tests

### Step 1: Start the Enhanced Echo Server

```bash
python examples/echo_server_streamable.py
```

The server will start on `http://localhost:8931/mcp`

You should see:
```
🚀 Enhanced MCP Echo Server with Streamable HTTP Transport
============================================================
Server starting on: http://localhost:8931/mcp

Features:
✅ SSE event streaming
✅ Ping/pong keepalive (every 10 seconds)
✅ Server notifications (every 30 seconds)
✅ Progress notifications
✅ Session management
```

### Step 2: Run the Comprehensive Test

```bash
bundle exec ruby examples/echo_server_streamable_client.rb
```

This will test all features including:
- Basic tool calls
- Server notifications
- Progress tracking
- Session persistence
- Keepalive monitoring

### Step 3: Test Ping/Pong Specifically

To see detailed ping/pong activity:

```bash
DEBUG=1 bundle exec ruby examples/test_ping_pong.rb
```

## Expected Behavior

### Ping/Pong Keepalive

1. Server sends ping every 10 seconds with incrementing ID
2. Client automatically responds with pong
3. Session remains active indefinitely

Example log output:
```
DEBUG [MCPClient::ServerStreamableHTTP] Processing event chunk: "event: message\ndata: {\"method\":\"ping\",\"jsonrpc\":\"2.0\",\"id\":0}\n\n"
DEBUG [MCPClient::ServerStreamableHTTP] Sent pong response for ping ID: 0
```

### Server Notifications

The server sends periodic notifications:
```
📊 Server Status: Server is healthy. Session active for 30 seconds
```

### Progress Notifications

During long-running tasks:
```
⏳ Progress: 20% - Step 1 of 5 completed
⏳ Progress: 40% - Step 2 of 5 completed
⏳ Progress: 60% - Step 3 of 5 completed
⏳ Progress: 80% - Step 4 of 5 completed
⏳ Progress: 100% - Step 5 of 5 completed
```

## Debugging

### Enable Debug Logging

```bash
# For the Ruby client
DEBUG=1 bundle exec ruby examples/echo_server_streamable_client.rb

# For the Python server (shows all Flask activity)
FLASK_ENV=development python examples/echo_server_streamable.py
```

### Common Issues

1. **Connection Refused**
   - Ensure the server is running on port 8931
   - Check firewall settings

2. **No Ping/Pong Messages**
   - Enable DEBUG logging to see detailed activity
   - Verify the events connection is established

3. **Session Lost**
   - Check if ping/pong is working
   - Verify session ID is being sent in headers

## Protocol Compliance

This implementation follows the MCP 2025-03-26 specification:

- ✅ HTTP POST for RPC calls with SSE responses
- ✅ HTTP GET for events stream
- ✅ Session management via Mcp-Session-Id header
- ✅ Ping/pong keepalive mechanism
- ✅ Server-to-client notifications
- ✅ Progress notifications for long-running operations
- ✅ Proper error handling and cleanup

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  Ruby Client                     │
├─────────────────────────────────────────────────┤
│  ServerStreamableHTTP                           │
│  - Sends RPC requests (POST)                    │
│  - Maintains events connection (GET)            │
│  - Handles ping/pong automatically              │
│  - Processes server notifications               │
└─────────────────────────────────────────────────┘
                       ↕ HTTP
┌─────────────────────────────────────────────────┐
│              Python Echo Server                  │
├─────────────────────────────────────────────────┤
│  Flask Application                              │
│  - Handles RPC requests → SSE responses         │
│  - Maintains event streams per session          │
│  - Sends periodic pings                         │
│  - Broadcasts notifications                     │
└─────────────────────────────────────────────────┘
```

## Contributing

To add new test cases:

1. Add new tools to `echo_server_streamable.py`
2. Add corresponding tests to `echo_server_streamable_client.rb`
3. Ensure all features follow MCP 2025-03-26 specification
4. Update this documentation

## License

These test files are part of the ruby-mcp-client project and follow the same license.