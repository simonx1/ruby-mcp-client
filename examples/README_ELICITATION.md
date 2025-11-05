# MCP Elicitation Examples

This directory contains examples demonstrating **MCP Elicitation** (MCP 2025-06-18) - server-initiated user interactions during tool execution.

## What is Elicitation?

Elicitation enables MCP servers to request structured information from users during tool execution. This allows servers to:
- Ask for additional context at runtime
- Confirm sensitive operations before executing
- Gather user input interactively
- Create multi-step workflows with user feedback

## Transport Support

| Transport | Support | Files |
|-----------|---------|-------|
| **stdio** | ✅ Full | `elicitation_server.py`, `test_elicitation.rb` |
| **Streamable HTTP** | ✅ Full | `elicitation_streamable_server.py`, `test_elicitation_streamable.rb` |
| **SSE** | ✅ Full | (Works with any SSE server supporting elicitation) |
| **HTTP** | ❌ Not supported | (Unidirectional request-response only) |

## Examples

### 1. stdio Transport Example

**Most Common**: Local process communication via stdin/stdout

#### Server: `elicitation_server.py`
```bash
# Install dependencies
pip install mcp

# Run server
python examples/elicitation_server.py
```

#### Client: `test_elicitation.rb`
```bash
# Run client (launches server automatically)
ruby examples/test_elicitation.rb
```

**Features:**
- ✅ Full bidirectional JSON-RPC over stdin/stdout
- ✅ Automatic process management
- ✅ No network configuration needed
- ✅ Best for local development and testing

**Tools Provided:**
1. `create_document` - Asks for title and content via elicitation
2. `sensitive_operation` - Requires user confirmation

---

### 2. Streamable HTTP Transport Example

**For Remote Servers**: HTTP with SSE-formatted responses

#### Server: `elicitation_streamable_server.py`
```bash
# Install dependencies
pip install mcp starlette uvicorn sse-starlette

# Run server
python examples/elicitation_streamable_server.py

# Server runs on http://localhost:8000
```

#### Client: `test_elicitation_streamable.rb`
```bash
# Make sure server is running first, then:
ruby examples/test_elicitation_streamable.rb

# Or specify custom server URL:
export MCP_SERVER_URL='http://localhost:8000'
export MCP_SERVER_ENDPOINT='/mcp'
ruby examples/test_elicitation_streamable.rb
```

**Features:**
- ✅ Server requests via SSE-formatted HTTP responses
- ✅ Client responses via HTTP POST
- ✅ Session management via `Mcp-Session-Id` header
- ✅ Works with remote servers
- ✅ Supports authentication headers

**Tools Provided:**
1. `create_document` - Multi-step: asks for title/author, then content
2. `delete_files` - Confirmation with optional decline reason
3. `deploy_application` - Multi-step: initial confirmation + production check

---

## How Elicitation Works

### Request Flow

```
┌──────────┐                           ┌──────────┐
│  Server  │                           │  Client  │
└──────────┘                           └──────────┘
     │                                       │
     │  1. Tool execution starts             │
     │                                       │
     │  2. Server sends elicitation/create   │
     │────────────────────────────────────>  │
     │     (via SSE or stdin)                │
     │                                       │
     │                              3. Present UI
     │                              4. User provides input
     │                                       │
     │  5. Client sends response             │
     │  <────────────────────────────────────│
     │     (via HTTP POST or stdout)         │
     │                                       │
     │  6. Server validates & continues      │
     │                                       │
```

### Response Actions

Clients can respond with three actions:

1. **accept** - User provided data
   ```ruby
   {
     'action' => 'accept',
     'content' => {
       'field_name' => 'user_value'
     }
   }
   ```

2. **decline** - User refused to provide data
   ```ruby
   { 'action' => 'decline' }
   ```

3. **cancel** - User cancelled the operation
   ```ruby
   { 'action' => 'cancel' }
   ```

---

## Client Implementation

### Ruby Client with Elicitation Handler

```ruby
require 'mcp_client'

# Define elicitation handler
elicitation_handler = lambda do |message, requested_schema|
  # Display message to user
  puts message

  # Show expected fields from schema
  requested_schema['properties'].each do |field, schema|
    puts "  #{field}: #{schema['type']}"
  end

  # Collect user input
  content = {}
  requested_schema['properties'].each do |field, schema|
    print "Enter #{field}: "
    content[field] = gets.chomp
  end

  # Return response
  {
    'action' => 'accept',
    'content' => content
  }
end

# Create client with handler
client = MCPClient::Client.new(
  mcp_server_configs: [
    # stdio transport
    MCPClient.stdio_config(
      command: 'python elicitation_server.py',
      name: 'my-server'
    ),

    # OR Streamable HTTP transport
    MCPClient.streamable_http_config(
      base_url: 'http://localhost:8000',
      endpoint: '/mcp',
      name: 'remote-server'
    ),

    # OR SSE transport
    MCPClient.sse_config(
      base_url: 'http://localhost:8000/sse',
      name: 'sse-server'
    )
  ],
  elicitation_handler: elicitation_handler
)

# Connect and use
client.connect_to_all_servers
result = client.call_tool('my-server', 'create_document', { format: 'markdown' })
```

---

## Server Implementation (Python)

### Simple Elicitation Example

```python
from mcp.server.fastmcp import FastMCP
from mcp.server.session import ServerSession
from mcp.server import Context
from pydantic import BaseModel, Field

mcp = FastMCP("my-server")

class UserInput(BaseModel):
    """Schema for user input."""
    name: str = Field(description="User's name")
    age: int = Field(description="User's age")

@mcp.tool()
async def greet_user(ctx: Context[ServerSession, None]) -> str:
    """Greet user with their name and age via elicitation."""

    # Request user information
    result = await ctx.elicit(
        message="Please provide your information:",
        schema=UserInput
    )

    # Handle response
    if result.action == "accept" and result.data:
        return f"Hello {result.data.name}, age {result.data.age}!"
    elif result.action == "decline":
        return "User declined to provide information."
    else:
        return "User cancelled."
```

---

## Schema Constraints

Elicitation schemas have specific constraints per MCP spec:

- ✅ **Flat objects only** - Only primitive types allowed
- ✅ **Primitive types**: string, number, integer, boolean
- ❌ **No nested objects**
- ❌ **No arrays**
- ✅ **Optional fields** - Use default values
- ✅ **Validation** - min/max, format, enum, etc.

### Good Schema Example
```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "User's name",
      "minLength": 1
    },
    "age": {
      "type": "integer",
      "description": "User's age",
      "minimum": 0,
      "maximum": 150
    },
    "email": {
      "type": "string",
      "format": "email",
      "description": "Email address"
    },
    "subscribe": {
      "type": "boolean",
      "description": "Subscribe to newsletter",
      "default": false
    }
  },
  "required": ["name", "age"]
}
```

---

## Troubleshooting

### stdio Transport Issues

**Problem**: Server process doesn't start
```bash
# Check Python and MCP installation
python --version
pip install mcp

# Test server directly
python examples/elicitation_server.py
# Should wait for JSON-RPC input on stdin
```

**Problem**: Client can't connect
```ruby
# Add debug logging
logger = Logger.new($stdout)
logger.level = Logger::DEBUG

client = MCPClient::Client.new(
  mcp_server_configs: [...],
  logger: logger
)
```

### Streamable HTTP Transport Issues

**Problem**: Connection refused
```bash
# Make sure server is running
curl http://localhost:8000/mcp
# Should return MCP response

# Check server logs
python examples/elicitation_streamable_server.py
```

**Problem**: Elicitation requests not received
```ruby
# Verify handler is registered
puts "Handler registered: #{client.instance_variable_get(:@elicitation_handler).present?}"

# Check server capabilities
puts client.servers.first.capabilities
# Should include 'elicitation' in client capabilities
```

**Problem**: Response not sent back
```bash
# Check HTTP POST is working
# Server logs should show "Sent JSON-RPC response"

# Verify session ID is captured
# Client should log "Captured session ID: xxx"
```

---

## Testing

Run the examples to verify elicitation works:

```bash
# Test stdio transport
ruby examples/test_elicitation.rb

# Test Streamable HTTP transport
# Terminal 1: Start server
python examples/elicitation_streamable_server.py

# Terminal 2: Run client
ruby examples/test_elicitation_streamable.rb
```

---

## Additional Resources

- **MCP Specification**: https://modelcontextprotocol.io/specification/2025-06-18/client/elicitation
- **Python MCP SDK**: https://github.com/modelcontextprotocol/python-sdk
- **Ruby MCP Client**: https://github.com/reemus-dev/ruby-mcp-client

---

## License

These examples are part of the ruby-mcp-client gem and are provided under the same license.
