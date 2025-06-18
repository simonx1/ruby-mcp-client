# ruby-mcp-client

This gem provides a Ruby client for the Model Context Protocol (MCP),
enabling integration with external tools and services via a standardized protocol.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ruby-mcp-client'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install ruby-mcp-client
```

## Overview

MCP enables AI assistants and other services to discover and invoke external tools
via different transport mechanisms:

- **Standard I/O**: Local processes implementing the MCP protocol
- **Server-Sent Events (SSE)**: Remote MCP servers over HTTP with streaming support
- **HTTP**: Remote MCP servers over HTTP request/response (without streaming)
- **Streamable HTTP**: Remote MCP servers that use HTTP POST with Server-Sent Event formatted responses

The core client resides in `MCPClient::Client` and provides helper methods for integrating
with popular AI services with built-in conversions:

- `to_openai_tools()` - Formats tools for OpenAI API
- `to_anthropic_tools()` - Formats tools for Anthropic Claude API
- `to_google_tools()` - Formats tools for Google Vertex AI API (automatically removes "$schema" keys not accepted by Vertex AI)

## Usage

### Basic Client Usage

```ruby
require 'mcp_client'

client = MCPClient.create_client(
  mcp_server_configs: [
    # Local stdio server
    MCPClient.stdio_config(
      command: 'npx -y @modelcontextprotocol/server-filesystem /home/user',
      name: 'filesystem' # Optional name for this server
    ),
    # Remote HTTP SSE server (with streaming support)
    MCPClient.sse_config(
      base_url: 'https://api.example.com/sse',
      headers: { 'Authorization' => 'Bearer YOUR_TOKEN' },
      name: 'sse_api',  # Optional name for this server
      read_timeout: 30, # Optional timeout in seconds (default: 30)
      ping: 10,         # Optional ping interval in seconds of inactivity (default: 10)
                        # Connection closes automatically after inactivity (2.5x ping interval)
      retries: 3,       # Optional number of retry attempts (default: 0)
      retry_backoff: 1, # Optional backoff delay in seconds (default: 1)
      # Native support for tool streaming via call_tool_streaming method
      logger: Logger.new($stdout, level: Logger::INFO) # Optional logger for this server
    ),
    # Remote HTTP server (request/response without streaming)
    MCPClient.http_config(
      base_url: 'https://api.example.com',
      endpoint: '/rpc', # Optional JSON-RPC endpoint path (default: '/rpc')
      headers: { 'Authorization' => 'Bearer YOUR_TOKEN' },
      name: 'http_api', # Optional name for this server
      read_timeout: 30, # Optional timeout in seconds (default: 30)
      retries: 3,       # Optional number of retry attempts (default: 3)
      retry_backoff: 1, # Optional backoff delay in seconds (default: 1)
      logger: Logger.new($stdout, level: Logger::INFO) # Optional logger for this server
    )
  ],
  # Optional logger for the client and all servers without explicit loggers
  logger: Logger.new($stdout, level: Logger::WARN)
)

# Or load server definitions from a JSON file
client = MCPClient.create_client(
  server_definition_file: 'path/to/server_definition.json',
  logger: Logger.new($stdout, level: Logger::WARN) # Optional logger for client and servers
)

# MCP server configuration JSON format can be:
# 1. A single server object: 
#    { "type": "sse", "url": "http://example.com/sse" }
#    { "type": "http", "url": "http://example.com", "endpoint": "/rpc" }
# 2. An array of server objects: 
#    [{ "type": "stdio", "command": "npx server" }, { "type": "sse", "url": "http://..." }, { "type": "http", "url": "http://..." }]
# 3. An object with "mcpServers" key containing named servers:
#    { "mcpServers": { "server1": { "type": "sse", "url": "http://..." }, "server2": { "type": "http", "url": "http://..." } } }
#    Note: When using this format, server1/server2 will be accessible by name

# List available tools
tools = client.list_tools

# Find a server by name
filesystem_server = client.find_server('filesystem')

# Find tools by name pattern (string or regex)
file_tools = client.find_tools('file')
first_tool = client.find_tool(/^file_/)

# Call a specific tool by name
result = client.call_tool('example_tool', { param1: 'value1', param2: 42 })

# Call a tool on a specific server by name
result = client.call_tool('example_tool', { param1: 'value1' }, server: 'filesystem')
# You can also call a tool on a server directly
result = filesystem_server.call_tool('example_tool', { param1: 'value1' })

# Call multiple tools in batch
results = client.call_tools([
  { name: 'tool1', parameters: { key1: 'value1' } },
  { name: 'tool2', parameters: { key2: 'value2' }, server: 'filesystem' } # Specify server for a specific tool
])

# Stream results (supported by the SSE transport)
# Returns an Enumerator that yields results as they become available
client.call_tool_streaming('streaming_tool', { param: 'value' }, server: 'api').each do |chunk|
  # Process each chunk as it arrives
  puts chunk
end

# Format tools for specific AI services
openai_tools = client.to_openai_tools
anthropic_tools = client.to_anthropic_tools
google_tools = client.to_google_tools

# Register for server notifications
client.on_notification do |server, method, params|
  puts "Server notification: #{server.class}[#{server.name}] - #{method} - #{params}"
  # Handle specific notifications based on method name
  # 'notifications/tools/list_changed' is handled automatically by the client
end

# Send custom JSON-RPC requests or notifications
client.send_rpc('custom_method', params: { key: 'value' }, server: :sse) # Uses specific server by type
client.send_rpc('custom_method', params: { key: 'value' }, server: 'filesystem') # Uses specific server by name
result = client.send_rpc('another_method', params: { data: 123 }) # Uses first available server
client.send_notification('status_update', params: { status: 'ready' })

# Check server connectivity 
client.ping # Basic connectivity check (zero-parameter heartbeat call)
client.ping(server_index: 1) # Ping a specific server by index

# Clear cached tools to force fresh fetch on next list
client.clear_cache
# Clean up connections
client.cleanup
```

### HTTP Transport Example

The HTTP transport provides simple request/response communication with MCP servers:

```ruby
require 'mcp_client'
require 'logger'

# Optional logger for debugging
logger = Logger.new($stdout)
logger.level = Logger::INFO

# Create an MCP client that connects to an HTTP MCP server
http_client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.http_config(
      base_url: 'https://api.example.com',
      endpoint: '/mcp',     # JSON-RPC endpoint path
      headers: {
        'Authorization' => 'Bearer YOUR_API_TOKEN',
        'X-Custom-Header' => 'custom-value'
      },
      read_timeout: 30,     # Timeout in seconds for HTTP requests
      retries: 3,           # Number of retry attempts on transient errors
      retry_backoff: 1,     # Base delay in seconds for exponential backoff
      logger: logger        # Optional logger for debugging HTTP requests
    )
  ]
)

# List available tools
tools = http_client.list_tools

# Call a tool
result = http_client.call_tool('analyze_data', { 
  dataset: 'sales_2024',
  metrics: ['revenue', 'conversion_rate']
})

# HTTP transport also supports streaming (though implemented as single response)
# This provides API compatibility with SSE transport
http_client.call_tool_streaming('process_batch', { batch_id: 123 }).each do |result|
  puts "Processing result: #{result}"
end

# Send custom JSON-RPC requests
custom_result = http_client.send_rpc('custom_method', params: { key: 'value' })

# Send notifications (fire-and-forget)
http_client.send_notification('status_update', params: { status: 'processing' })

# Test connectivity
ping_result = http_client.ping
puts "Server is responsive: #{ping_result.inspect}"

# Clean up
http_client.cleanup
```

### Streamable HTTP Transport Example

The Streamable HTTP transport is designed for servers that use HTTP POST requests but return Server-Sent Event formatted responses. This is commonly used by services like Zapier's MCP implementation:

```ruby
require 'mcp_client'
require 'logger'

# Optional logger for debugging
logger = Logger.new($stdout)
logger.level = Logger::INFO

# Create an MCP client that connects to a Streamable HTTP MCP server
streamable_client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.streamable_http_config(
      base_url: 'https://mcp.zapier.com/api/mcp/s/YOUR_SESSION_ID/mcp',
      headers: {
        'Authorization' => 'Bearer YOUR_ZAPIER_TOKEN'
      },
      read_timeout: 60,     # Timeout in seconds for HTTP requests
      retries: 3,           # Number of retry attempts on transient errors
      retry_backoff: 2,     # Base delay in seconds for exponential backoff
      logger: logger        # Optional logger for debugging requests
    )
  ]
)

# List available tools (server responds with SSE-formatted JSON)
tools = streamable_client.list_tools
puts "Found #{tools.size} tools:"
tools.each { |tool| puts "- #{tool.name}: #{tool.description}" }

# Call a tool (response will be in SSE format)
result = streamable_client.call_tool('google_calendar_find_event', {
  instructions: 'Find today\'s meetings',
  calendarid: 'primary'
})

# The client automatically parses SSE responses like:
# event: message
# data: {"jsonrpc":"2.0","id":1,"result":{"content":[...]}}

puts "Tool result: #{result.inspect}"

# Clean up
streamable_client.cleanup
```

### Server-Sent Events (SSE) Example

The SSE transport provides robust connection handling for remote MCP servers:

```ruby
require 'mcp_client'
require 'logger'

# Optional logger for debugging
logger = Logger.new($stdout)
logger.level = Logger::INFO

# Create an MCP client that connects to a Playwright MCP server via SSE
# First run: npx @playwright/mcp@latest --port 8931
sse_client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.sse_config(
      base_url: 'http://localhost:8931/sse',
      read_timeout: 30,  # Timeout in seconds for request fulfillment
      ping: 10,          # Send ping after 10 seconds of inactivity
                         # Connection closes automatically after inactivity (2.5x ping interval)
      retries: 2,        # Number of retry attempts on transient errors
      logger: logger     # Optional logger for debugging connection issues
    )
  ]
)

# List available tools
tools = sse_client.list_tools

# Launch a browser
result = sse_client.call_tool('browser_install', {})
result = sse_client.call_tool('browser_navigate', { url: 'about:blank' })
# No browser ID needed with these tool names

# Create a new page
page_result = sse_client.call_tool('browser_tab_new', {})
# No page ID needed with these tool names

# Navigate to a website
sse_client.call_tool('browser_navigate', { url: 'https://example.com' })

# Get page title
title_result = sse_client.call_tool('browser_snapshot', {})
puts "Page snapshot: #{title_result}"

# Take a screenshot
screenshot_result = sse_client.call_tool('browser_take_screenshot', {})

# Ping the server to verify connectivity
ping_result = sse_client.ping
puts "Ping successful: #{ping_result.inspect}"

# Clean up
sse_client.cleanup
```

See `examples/mcp_sse_server_example.rb` for the full Playwright SSE example.

### Integration Examples

The repository includes examples for integrating with popular AI APIs:

#### OpenAI Integration

Ruby-MCP-Client works with both official and community OpenAI gems:

```ruby
# Using the openai/openai-ruby gem (official)
require 'mcp_client'
require 'openai'

# Create MCP client
mcp_client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.stdio_config(
      command: %W[npx -y @modelcontextprotocol/server-filesystem #{Dir.pwd}]
    )
  ]
)

# Convert tools to OpenAI format
tools = mcp_client.to_openai_tools

# Use with OpenAI client
client = OpenAI::Client.new(api_key: ENV['OPENAI_API_KEY'])
response = client.chat.completions.create(
  model: 'gpt-4',
  messages: [
    { role: 'user', content: 'List files in current directory' }
  ],
  tools: tools
)

# Process tool calls and results
# See examples directory for complete implementation
```

```ruby
# Using the alexrudall/ruby-openai gem (community)
require 'mcp_client'
require 'openai'

# Create MCP client
mcp_client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.stdio_config(command: 'npx @playwright/mcp@latest')
  ]
)

# Convert tools to OpenAI format
tools = mcp_client.to_openai_tools

# Use with Ruby-OpenAI client
client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
# See examples directory for complete implementation
```

#### Anthropic Integration

```ruby
require 'mcp_client'
require 'anthropic'

# Create MCP client
mcp_client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.stdio_config(
      command: %W[npx -y @modelcontextprotocol/server-filesystem #{Dir.pwd}]
    )
  ]
)

# Convert tools to Anthropic format
claude_tools = mcp_client.to_anthropic_tools

# Use with Anthropic client
client = Anthropic::Client.new(access_token: ENV['ANTHROPIC_API_KEY'])
# See examples directory for complete implementation
```

Complete examples can be found in the `examples/` directory:
- `ruby_openai_mcp.rb` - Integration with alexrudall/ruby-openai gem
- `openai_ruby_mcp.rb` - Integration with official openai/openai-ruby gem
- `ruby_anthropic_mcp.rb` - Integration with alexrudall/ruby-anthropic gem
- `gemini_ai_mcp.rb` - Integration with Google Vertex AI and Gemini models
- `mcp_sse_server_example.rb` - SSE transport with Playwright MCP

## MCP Server Compatibility

This client works with any MCP-compatible server, including:

- [@modelcontextprotocol/server-filesystem](https://www.npmjs.com/package/@modelcontextprotocol/server-filesystem) - File system access
- [@playwright/mcp](https://www.npmjs.com/package/@playwright/mcp) - Browser automation
- Custom servers implementing the MCP protocol

### Server Definition Files

You can define MCP server configurations in JSON files for easier management:

```json
{
  "mcpServers": {
    "playwright": {
      "type": "sse",
      "url": "http://localhost:8931/sse",
      "headers": {
        "Authorization": "Bearer TOKEN"
      }
    },
    "api_server": {
      "type": "http",
      "url": "https://api.example.com",
      "endpoint": "/mcp",
      "headers": {
        "Authorization": "Bearer API_TOKEN",
        "X-Custom-Header": "value"
      }
    },
    "filesystem": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/dir"],
      "env": {
        "DEBUG": "true"
      }
    }
  }
}
```

A simpler example used in the Playwright demo (found in `examples/sample_server_definition.json`):

```json
{
  "mcpServers": {
    "playwright": {
      "url": "http://localhost:8931/sse",
      "headers": {},
      "comment": "Local Playwright MCP Server running on port 8931"
    }
  }
}
```

Load this configuration with:

```ruby
client = MCPClient.create_client(server_definition_file: 'path/to/definition.json')
```

The JSON format supports:
1. A single server object: `{ "type": "sse", "url": "..." }` or `{ "type": "http", "url": "..." }`
2. An array of server objects: `[{ "type": "stdio", ... }, { "type": "sse", ... }, { "type": "http", ... }]`
3. An object with named servers under `mcpServers` key (as shown above)

Special configuration options:
- `comment` and `description` are reserved keys that are ignored during parsing and can be used for documentation
- Server type can be inferred from the presence of either `command` (for stdio) or `url` (for SSE/HTTP)
- For HTTP servers, `endpoint` specifies the JSON-RPC endpoint path (defaults to '/rpc' if not specified)
- All string values in arrays (like `args`) are automatically converted to strings

## Session-Based MCP Protocol Support

Both HTTP and Streamable HTTP transports now support session-based MCP servers that require session continuity:

### Session Management Features

- **Automatic Session Management**: Captures session IDs from `initialize` response headers
- **Session Header Injection**: Automatically includes `Mcp-Session-Id` header in subsequent requests
- **Session Termination**: Sends HTTP DELETE requests to properly terminate sessions during cleanup
- **Session Validation**: Validates session ID format for security (8-128 alphanumeric characters with hyphens/underscores)
- **Backward Compatibility**: Works with both session-based and stateless MCP servers
- **Session Cleanup**: Properly cleans up session state during connection teardown

### Resumability and Redelivery (Streamable HTTP)

The Streamable HTTP transport provides additional resumability features for reliable message delivery:

- **Event ID Tracking**: Automatically tracks event IDs from SSE responses
- **Last-Event-ID Header**: Includes `Last-Event-ID` header in requests for resuming from disconnection points
- **Message Replay**: Enables servers to replay missed messages from the last received event
- **Connection Recovery**: Maintains message continuity even with unstable network connections

### Security Features

Both transports implement security best practices:

- **URL Validation**: Validates server URLs to ensure only HTTP/HTTPS protocols are used
- **Session ID Validation**: Enforces secure session ID formats to prevent malicious injection
- **Security Warnings**: Logs warnings for potentially insecure configurations (e.g., 0.0.0.0 binding)
- **Header Sanitization**: Properly handles and validates all session-related headers

### Usage

The session support is transparent to the user - no additional configuration is required. The client will automatically detect and handle session-based servers by:

1. **Session Initialization**: Capturing the `Mcp-Session-Id` header from the `initialize` response
2. **Session Persistence**: Including this header in all subsequent requests (except `initialize`)
3. **Session Termination**: Sending HTTP DELETE request with session ID during cleanup
4. **Resumability** (Streamable HTTP): Tracking event IDs and including `Last-Event-ID` for message replay
5. **Security Validation**: Validating session IDs and server URLs for security
6. **Logging**: Comprehensive logging of session activity for debugging purposes

Example of automatic session termination:

```ruby
# Session is automatically terminated when client is cleaned up
client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.http_config(base_url: 'https://api.example.com/mcp')
  ]
)

# Use the client...
tools = client.list_tools

# Session automatically terminated with HTTP DELETE request
client.cleanup
```

This enables compatibility with MCP servers that maintain state between requests and require session identification.

## Key Features

### Client Features

- **Multiple transports** - Support for stdio, SSE, HTTP, and Streamable HTTP transports
- **Multiple servers** - Connect to multiple MCP servers simultaneously
- **Named servers** - Associate names with servers and find/reference them by name
- **Server lookup** - Find servers by name using `find_server`
- **Tool association** - Each tool knows which server it belongs to
- **Tool discovery** - Find tools by name or pattern
- **Server disambiguation** - Specify which server to use when tools with same name exist in multiple servers
- **Atomic tool calls** - Simple API for invoking tools with parameters
- **Batch support** - Call multiple tools in a single operation
- **API conversions** - Built-in format conversion for OpenAI, Anthropic, and Google Vertex AI APIs
- **Thread safety** - Synchronized access for thread-safe operation
- **Server notifications** - Support for JSON-RPC notifications
- **Custom RPC methods** - Send any custom JSON-RPC method
- **Consistent error handling** - Rich error types for better exception handling
- **JSON configuration** - Support for server definition files in JSON format with name retention

### Server-Sent Events (SSE) Implementation

The SSE client implementation provides these key features:

- **Robust connection handling**: Properly manages HTTP/HTTPS connections with configurable timeouts and retries
- **Advanced connection management**:
  - **Inactivity tracking**: Monitors connection activity to detect idle connections
  - **Automatic ping**: Sends ping requests after a configurable period of inactivity (default: 10 seconds)
  - **Automatic disconnection**: Closes idle connections after inactivity (2.5× ping interval)
  - **MCP compliant**: Any server communication resets the inactivity timer per specification
- **Intelligent reconnection**:
  - **Ping failure detection**: Tracks consecutive ping failures (when server isn't responding)
  - **Automatic reconnection**: Attempts to reconnect after 3 consecutive ping failures
  - **Exponential backoff**: Uses increasing delays between reconnection attempts
  - **Smart retry limits**: Caps reconnection attempts (default: 5) to avoid infinite loops
  - **Connection state monitoring**: Properly detects and handles closed connections to prevent errors
  - **Failure transparency**: Handles reconnection in the background without disrupting client code
- **Thread safety**: All operations are thread-safe using monitors and synchronized access
- **Reliable error handling**: Comprehensive error handling for network issues, timeouts, and malformed responses
- **JSON-RPC over SSE**: Full implementation of JSON-RPC 2.0 over SSE transport with initialize handshake
- **Streaming support**: Native streaming for real-time updates via the `call_tool_streaming` method, which returns an Enumerator for processing results as they arrive
- **Notification support**: Built-in handling for JSON-RPC notifications with automatic tool cache invalidation and custom notification callback support
- **Custom RPC methods**: Send any custom JSON-RPC method or notification through `send_rpc` and `send_notification`
- **Configurable retries**: All RPC requests support configurable retries with exponential backoff
- **Consistent logging**: Tagged, leveled logging across all components for better debugging
- **Graceful fallbacks**: Automatic fallback to synchronous HTTP when SSE connection fails
- **URL normalization**: Consistent URL handling that respects user-provided formats
- **Server connectivity check**: Built-in `ping` method to test server connectivity and health

### HTTP Transport Implementation

The HTTP transport provides a simpler, stateless communication mechanism for MCP servers:

- **Request/Response Model**: Standard HTTP request/response cycle for each JSON-RPC call
- **JSON-Only Responses**: Accepts only `application/json` responses (no SSE support)
- **Session Support**: Automatic session header (`Mcp-Session-Id`) capture and injection for session-based MCP servers
- **Session Termination**: Proper session cleanup with HTTP DELETE requests during connection teardown
- **Session Validation**: Security validation of session IDs to prevent malicious injection
- **Stateless & Stateful**: Supports both stateless servers and session-based servers that require state continuity
- **HTTP Headers Support**: Full support for custom headers including authorization, API keys, and other metadata
- **Reliable Error Handling**: Comprehensive HTTP status code handling with appropriate error mapping
- **Configurable Retries**: Exponential backoff retry logic for transient network failures
- **Connection Pooling**: Uses Faraday's connection pooling for efficient HTTP connections
- **Timeout Management**: Configurable timeouts for both connection establishment and request completion
- **JSON-RPC over HTTP**: Full JSON-RPC 2.0 implementation over HTTP POST requests
- **MCP Protocol Compliance**: Supports all standard MCP methods (initialize, tools/list, tools/call)
- **Custom RPC Methods**: Send any custom JSON-RPC method or notification
- **Thread Safety**: All operations are thread-safe for concurrent usage
- **Streaming API Compatibility**: Provides `call_tool_streaming` method for API compatibility (returns single response)
- **Graceful Degradation**: Simple fallback behavior when complex features aren't needed

### Streamable HTTP Transport Implementation

The Streamable HTTP transport bridges HTTP and Server-Sent Events, designed for servers that use HTTP POST but return SSE-formatted responses:

- **Hybrid Communication**: HTTP POST requests with Server-Sent Event formatted responses
- **SSE Response Parsing**: Automatically parses `event:` and `data:` lines from SSE responses
- **Session Support**: Automatic session header (`Mcp-Session-Id`) capture and injection for session-based MCP servers
- **Session Termination**: Proper session cleanup with HTTP DELETE requests during connection teardown
- **Resumability**: Event ID tracking and `Last-Event-ID` header support for message replay after disconnections
- **Session Validation**: Security validation of session IDs to prevent malicious injection
- **HTTP Semantics**: Maintains standard HTTP request/response model for client compatibility
- **Streaming Format Support**: Handles complex SSE responses with multiple fields (event, id, retry, etc.)
- **Error Handling**: Comprehensive error handling for both HTTP and SSE parsing failures
- **Headers Optimization**: Includes SSE-compatible headers (`Accept: text/event-stream, application/json`, `Cache-Control: no-cache`)
- **JSON-RPC Compliance**: Full JSON-RPC 2.0 support over the hybrid HTTP/SSE transport
- **Retry Logic**: Exponential backoff for both connection and parsing failures
- **Thread Safety**: All operations are thread-safe for concurrent usage
- **Malformed Response Handling**: Graceful handling of invalid SSE format or missing data lines

## Requirements

- Ruby >= 3.2.0
- No runtime dependencies

## Implementing an MCP Server

To implement a compatible MCP server you must:

- Listen on your chosen transport (JSON-RPC stdio, HTTP SSE, HTTP, or Streamable HTTP)
- Respond to `list_tools` requests with a JSON list of tools
- Respond to `call_tool` requests by executing the specified tool
- Return results (or errors) in JSON format
- Optionally send JSON-RPC notifications for events like tool updates

### JSON-RPC Notifications

The client supports JSON-RPC notifications from the server:

- Default notification handler for `notifications/tools/list_changed` to automatically clear the tool cache
- Custom notification handling via the `on_notification` method
- Callbacks receive the server instance, method name, and parameters
- Multiple notification listeners can be registered

## Tool Schema

Each tool is defined by a name, description, and a JSON Schema for its parameters:

```json
{
  "name": "example_tool",
  "description": "Does something useful",
  "schema": {
    "type": "object",
    "properties": {
      "param1": { "type": "string" },
      "param2": { "type": "number" }
    },
    "required": ["param1"]
  }
}
```

## License

This gem is available as open source under the [MIT License](LICENSE).

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/simonx1/ruby-mcp-client.
