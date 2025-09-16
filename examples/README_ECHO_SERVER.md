# FastMCP Echo Server Example

This directory contains a complete example of using the Ruby MCP client with a FastMCP server.

## Overview

The example includes:
- `echo_server.py`: A Python FastMCP server with multiple tools
- `echo_server_client.rb`: A Ruby client that connects to the server and demonstrates tool usage
- `echo_server_streamable.py`: Enhanced server with streamable HTTP transport, tools, prompts, and resources
- `echo_server_streamable_client.rb`: Client demonstrating streamable HTTP transport with tools, prompts, and resources

## Quick Start

### 1. Install Dependencies

**For the Python server:**
```bash
pip install fastmcp
```

**For the Ruby client:**
```bash
# Make sure you're in the ruby-mcp-client directory
bundle install
```

### 2. Start the Server

**For FastMCP server (basic tools only):**
```bash
# From the ruby-mcp-client directory
python examples/echo_server.py
```

**For Streamable HTTP server (tools + prompts + resources):**
```bash
# From the ruby-mcp-client directory
python examples/echo_server_streamable.py
```

You should see output like:
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
✅ Tools support
✅ Prompts support
✅ Resources support

Available tools:
  - echo: Echo back a message
  - long_task: Simulate long-running task with progress
  - trigger_notification: Trigger a server notification

Available prompts:
  - greeting: Generate personalized greetings
  - code_review: Generate code review comments
  - documentation: Generate documentation

Available resources:
  - file:///sample/README.md: Sample README file
  - file:///sample/config.json: Configuration data
  - file:///sample/data.txt: Sample text data
  - file:///sample/image.png: Sample binary image

Press Ctrl+C to stop the server
```

### 3. Run the Client

In another terminal:

**For FastMCP server:**
```bash
# From the ruby-mcp-client directory (not the examples directory)
bundle exec ruby examples/echo_server_client.rb
```

**For Streamable HTTP server (recommended):**
```bash
# From the ruby-mcp-client directory (not the examples directory)
bundle exec ruby examples/echo_server_streamable_client.rb
```

### 4. Streamable HTTP Transport Features

The streamable HTTP transport (`echo_server_streamable.py`) provides:

- **Full MCP 2025-03-26 Protocol Support**
- **Server-Sent Events (SSE)** for real-time streaming
- **Session Management** with automatic keepalive
- **Progress Notifications** for long-running tasks
- **Server Notifications** for status updates
- **Prompts Support** for dynamic content generation
- **Resources Support** for file and data access

This is the most comprehensive example and demonstrates all features of the MCP protocol.

## Available Tools

Both servers (`echo_server.py` and `echo_server_streamable.py`) provide these tools:

| Tool | Description | Parameters |
|------|-------------|------------|
| `echo` | Echo back the provided message | `message: str` |
| `reverse` | Reverse the provided text | `text: str` |
| `uppercase` | Convert text to uppercase | `text: str` |
| `count_words` | Count words and characters in text | `text: str` |

**Additional tool for streamable HTTP server:**
| Tool | Description | Parameters |
|------|-------------|------------|
| `long_task` | Simulate long-running task with progress | `duration: int`, `steps: int` |
| `trigger_notification` | Trigger a server notification | `message: str` |

## Enhanced Features

Both servers now support the full MCP 2025-03-26 protocol:

### Available Prompts
| Prompt | Description | Parameters |
|--------|-------------|------------|
| `greeting` | Generate a personalized greeting | `name: str` |
| `code_review` | Generate code review comments | `code: str`, `language: str` (optional) |
| `documentation` | Generate documentation for a topic | `topic: str`, `audience: str` (optional) |

### Available Resources
| Resource | Description | Content Type |
|----------|-------------|--------------|
| `file:///sample/README.md` | Sample project README | text/markdown |
| `file:///sample/config.json` | Sample configuration file | application/json |
| `file:///sample/data.txt` | Sample data with annotations | text/plain |
| `file:///sample/image.png` | Sample binary resource | image/png (base64) |

## Example Output

### FastMCP Server Output

When you run the basic FastMCP client (`echo_server_client.rb`), you'll see output like:

```
🚀 Enhanced Ruby MCP Client - Tools, Prompts & Resources
============================================================
📡 Connecting to FastMCP Echo Server at http://127.0.0.1:8000/sse
✅ Connected successfully!

📋 Fetching available tools...
Found 4 tools:
  1. echo: Echo back the provided message
     Parameters: message
  2. reverse: Reverse the provided text
     Parameters: text
  3. uppercase: Convert text to uppercase
     Parameters: text
  4. count_words: Count words in the provided text
     Parameters: text

🛠️  Demonstrating tool usage:
------------------------------

1. Testing echo tool:
   Input: Hello from Ruby MCP Client!
   Output: Hello from Ruby MCP Client!

🎨 Working with Prompts
=========================

📋 Fetching available prompts...
Found 3 prompts:
  1. greeting: Generate a personalized greeting message
     Arguments: name
  2. code_review: Generate code review comments
     Arguments: code, language
  3. documentation: Generate documentation for a topic
     Arguments: topic, audience

1. Testing greeting prompt:
   Name: FastMCP User
   Generated greeting:
   Hello FastMCP User! Welcome to the Enhanced FastMCP Echo Server...

📚 Working with Resources
==========================

📋 Fetching available resources...
Found 4 resources:
  1. sample_readme (file:///sample/README.md)
     MIME Type: text/plain
     Description: Sample project README file

1. Reading sample_readme:
   URI: file:///sample/README.md
   Content (text/plain): # Sample Project README...

✨ All features tested successfully!
```

### Streamable HTTP Server Output

When you run the streamable HTTP client (`echo_server_streamable_client.rb`), you'll see output like:

```
🚀 Ruby MCP Client - Streamable HTTP Transport Test
============================================================
📡 Connecting to Enhanced Echo Server at http://localhost:8931/mcp
Transport: Streamable HTTP (MCP 2025-03-26)

✅ Connected successfully!
Session established with Streamable HTTP transport

📋 Fetching available tools...
Found 3 tools:
  1. echo: Echo back the provided message
  2. long_task: Simulate a long-running task with progress notifications
  3. trigger_notification: Trigger a server notification

========================================
Test 1: Basic Echo Tool
----------------------------------------
Calling echo with: Hello from Streamable HTTP Transport!
Response: Echo: Hello from Streamable HTTP Transport!

========================================
Test 7: Prompts Support
----------------------------------------
Testing prompts functionality...

📋 Fetching available prompts...
Found 3 prompts:
  1. greeting: Generate a personalized greeting message
     Arguments: name
  2. code_review: Generate code review comments
     Arguments: code, language
  3. documentation: Generate documentation for a topic
     Arguments: topic, audience

🎨 Testing prompts:

1. Testing greeting prompt:
   Generated greeting:
   Hello Streamable HTTP Tester! Welcome to the Enhanced MCP Echo Server...

========================================
Test 8: Resources Support
----------------------------------------
Testing resources functionality...

📋 Fetching available resources...
Found 4 resources:
  1. Sample README (file:///sample/README.md)
     MIME Type: text/markdown
     Description: A sample README file demonstrating markdown content
  2. Sample Configuration (file:///sample/config.json)
     MIME Type: application/json
     Description: A sample JSON configuration file
  3. Sample Data (file:///sample/data.txt)
     MIME Type: text/plain
     Description: Plain text data with annotations
  4. Sample Image (file:///sample/image.png)
     MIME Type: image/png
     Description: A sample binary image resource

✨ All tests completed successfully!

Summary:
  ✅ Streamable HTTP connection established
  ✅ SSE event streaming working
  ✅ Tools called successfully
  ✅ Progress notifications received
  ✅ Server notifications handled
  ✅ Ping/pong keepalive active
  ✅ Session persistence verified
  ✅ Prompts functionality tested
  ✅ Resources functionality tested
```

## Troubleshooting

### Server Not Starting
- Make sure you have `fastmcp` installed: `pip install fastmcp`
- Check that port 8000 is available
- Try running with `python3 echo_server.py` if `python` doesn't work

### Client Connection Issues
- Ensure the server is running before starting the client
- Check that the server is accessible at `http://127.0.0.1:8000/sse/`
- Make sure you're using `bundle exec` when running the client
- If you get "cannot load such file -- faraday/follow_redirects", run `bundle install`
- Look for any error messages in the server output

### Tool Call Errors
- Verify the tool names and parameters match what the server expects
- Check the server logs for any error messages
- Ensure the JSON-RPC protocol is working correctly

## Customization

You can modify the example to:
- Add more tools to the server
- Change the server port or endpoints
- Test different parameter types
- Implement error handling scenarios
- Test with different transport types (HTTP vs SSE)

## Learn More

- [FastMCP Documentation](https://github.com/jlowin/fastmcp)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [Ruby MCP Client Documentation](../README.md)