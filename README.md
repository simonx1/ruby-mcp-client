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

The core client resides in `MCPClient::Client` and provides helper methods for integrating
with popular AI services with built-in conversions:

- `to_openai_tools()` - Formats tools for OpenAI API
- `to_anthropic_tools()` - Formats tools for Anthropic Claude API

## Usage

### Basic Client Usage

```ruby
require 'mcp_client'

client = MCPClient.create_client(
  mcp_server_configs: [
    # Local stdio server
    MCPClient.stdio_config(command: 'npx -y @modelcontextprotocol/server-filesystem /home/user'),
    # Remote HTTP SSE server (with streaming support)
    MCPClient.sse_config(
      base_url: 'https://api.example.com/sse',
      headers: { 'Authorization' => 'Bearer YOUR_TOKEN' },
      read_timeout: 30, # Optional timeout in seconds (default: 30)
      ping: 10,         # Optional ping interval in seconds of inactivity (default: 10)
                        # Connection closes automatically after inactivity (2.5x ping interval)
      retries: 3,       # Optional number of retry attempts (default: 0)
      retry_backoff: 1  # Optional backoff delay in seconds (default: 1)
      # Native support for tool streaming via call_tool_streaming method
)  ]
)

# Or load server definitions from a JSON file
client = MCPClient.create_client(
  server_definition_file: 'path/to/server_definition.json'
)

# MCP server configuration JSON format can be:
# 1. A single server object: 
#    { "type": "sse", "url": "http://example.com/sse" }
# 2. An array of server objects: 
#    [{ "type": "stdio", "command": "npx server" }, { "type": "sse", "url": "http://..." }]
# 3. An object with "mcpServers" key containing named servers:
#    { "mcpServers": { "server1": { "type": "sse", "url": "http://..." } } }

# List available tools
tools = client.list_tools

# Find tools by name pattern (string or regex)
file_tools = client.find_tools('file')
first_tool = client.find_tool(/^file_/)

# Call a specific tool by name
result = client.call_tool('example_tool', { param1: 'value1', param2: 42 })

# Call multiple tools in batch
results = client.call_tools([
  { name: 'tool1', parameters: { key1: 'value1' } },
  { name: 'tool2', parameters: { key2: 'value2' } }
])

# Stream results (supported by the SSE transport)
# Returns an Enumerator that yields results as they become available
client.call_tool_streaming('streaming_tool', { param: 'value' }).each do |chunk|
  # Process each chunk as it arrives
  puts chunk
end

# Format tools for specific AI services
openai_tools = client.to_openai_tools
anthropic_tools = client.to_anthropic_tools

# Register for server notifications
client.on_notification do |server, method, params|
  puts "Server notification: #{server.class} - #{method} - #{params}"
  # Handle specific notifications based on method name
  # 'notifications/tools/list_changed' is handled automatically by the client
end

# Send custom JSON-RPC requests or notifications
client.send_rpc('custom_method', params: { key: 'value' }, server: :sse) # Uses specific server
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
      retries: 2         # Number of retry attempts on transient errors
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
1. A single server object: `{ "type": "sse", "url": "..." }`
2. An array of server objects: `[{ "type": "stdio", ... }, { "type": "sse", ... }]`
3. An object with named servers under `mcpServers` key (as shown above)

Special configuration options:
- `comment` and `description` are reserved keys that are ignored during parsing and can be used for documentation
- Server type can be inferred from the presence of either `command` (for stdio) or `url` (for SSE)
- All string values in arrays (like `args`) are automatically converted to strings

## Key Features

### Client Features

- **Multiple transports** - Support for both stdio and SSE transports
- **Multiple servers** - Connect to multiple MCP servers simultaneously
- **Tool discovery** - Find tools by name or pattern
- **Atomic tool calls** - Simple API for invoking tools with parameters
- **Batch support** - Call multiple tools in a single operation
- **API conversions** - Built-in format conversion for OpenAI and Anthropic APIs
- **Thread safety** - Synchronized access for thread-safe operation
- **Server notifications** - Support for JSON-RPC notifications
- **Custom RPC methods** - Send any custom JSON-RPC method
- **Consistent error handling** - Rich error types for better exception handling
- **JSON configuration** - Support for server definition files in JSON format

### Server-Sent Events (SSE) Implementation

The SSE client implementation provides these key features:

- **Robust connection handling**: Properly manages HTTP/HTTPS connections with configurable timeouts and retries
- **Advanced connection management**:
  - **Inactivity tracking**: Monitors connection activity to detect idle connections
  - **Automatic ping**: Sends ping requests after a configurable period of inactivity (default: 10 seconds)
  - **Automatic disconnection**: Closes idle connections after inactivity (2.5× ping interval)
  - **MCP compliant**: Any server communication resets the inactivity timer per specification
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

## Requirements

- Ruby >= 3.2.0
- No runtime dependencies

## Implementing an MCP Server

To implement a compatible MCP server you must:

- Listen on your chosen transport (JSON-RPC stdio, or HTTP SSE)
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