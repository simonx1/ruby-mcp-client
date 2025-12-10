# ruby-mcp-client

A Ruby client for the Model Context Protocol (MCP), enabling integration with external tools and services via a standardized protocol.

## Installation

```ruby
# Gemfile
gem 'ruby-mcp-client'
```

```bash
bundle install
# or
gem install ruby-mcp-client
```

## Overview

MCP enables AI assistants to discover and invoke external tools via different transport mechanisms:

- **stdio** - Local processes implementing the MCP protocol
- **SSE** - Server-Sent Events with streaming support
- **HTTP** - Simple request/response (non-streaming)
- **Streamable HTTP** - HTTP POST with SSE-formatted responses

Built-in API conversions: `to_openai_tools()`, `to_anthropic_tools()`, `to_google_tools()`

## MCP Protocol Support

Implements **MCP 2025-06-18** specification:

- **Tools**: list, call, streaming, annotations, structured outputs
- **Prompts**: list, get with parameters
- **Resources**: list, read, templates, subscriptions, pagination
- **Elicitation**: Server-initiated user interactions (stdio, SSE, Streamable HTTP)
- **Roots**: Filesystem scope boundaries with change notifications
- **Sampling**: Server-requested LLM completions
- **Completion**: Autocomplete for prompts/resources
- **Logging**: Server log messages with level filtering
- **OAuth 2.1**: PKCE, server discovery, dynamic registration

## Quick Connect API (Recommended)

The simplest way to connect to an MCP server:

```ruby
require 'mcp_client'

# Auto-detect transport from URL
client = MCPClient.connect('http://localhost:8000/sse')      # SSE
client = MCPClient.connect('http://localhost:8931/mcp')      # Streamable HTTP
client = MCPClient.connect('npx -y @modelcontextprotocol/server-filesystem /home')  # stdio

# With options
client = MCPClient.connect('http://api.example.com/mcp',
  headers: { 'Authorization' => 'Bearer TOKEN' },
  read_timeout: 60,
  retries: 3,
  logger: Logger.new($stdout)
)

# Multiple servers
client = MCPClient.connect(['http://server1/mcp', 'http://server2/sse'])

# Force specific transport
client = MCPClient.connect('http://custom.com/api', transport: :streamable_http)

# Use the client
tools = client.list_tools
result = client.call_tool('example_tool', { param: 'value' })
client.cleanup
```

**Transport Detection:**

| URL Pattern | Transport |
|-------------|-----------|
| Ends with `/sse` | SSE |
| Ends with `/mcp` | Streamable HTTP |
| `stdio://command` or Array | stdio |
| `npx`, `node`, `python`, etc. | stdio |
| Other HTTP URLs | Auto-detect (Streamable HTTP → SSE → HTTP) |

## Working with Tools, Prompts & Resources

```ruby
# Tools
tools = client.list_tools
result = client.call_tool('tool_name', { param: 'value' })
result = client.call_tool('tool_name', { param: 'value' }, server: 'server_name')

# Batch tool calls
results = client.call_tools([
  { name: 'tool1', parameters: { key: 'value' } },
  { name: 'tool2', parameters: { key: 'value' }, server: 'specific_server' }
])

# Streaming (SSE/Streamable HTTP)
client.call_tool_streaming('tool', { param: 'value' }).each do |chunk|
  puts chunk
end

# Prompts
prompts = client.list_prompts
result = client.get_prompt('greeting', { name: 'Alice' })

# Resources
result = client.list_resources
contents = client.read_resource('file:///example.txt')
contents.each do |content|
  puts content.text if content.text?
  data = Base64.decode64(content.blob) if content.binary?
end
```

## MCP 2025-06-18 Features

### Tool Annotations

```ruby
tool = client.find_tool('delete_user')
tool.read_only?              # Safe to execute?
tool.destructive?            # Warning: destructive operation
tool.requires_confirmation?  # Needs user confirmation
```

### Structured Outputs

```ruby
tool = client.find_tool('get_weather')
tool.structured_output?  # Has output schema?
tool.output_schema       # JSON Schema for output

result = client.call_tool('get_weather', { location: 'SF' })
data = result['structuredContent']  # Type-safe structured data
```

### Roots

```ruby
# Set filesystem scope boundaries
client.set_roots([
  { uri: 'file:///home/user/project', name: 'Project' },
  { uri: 'file:///var/log', name: 'Logs' }
])

# Access current roots
client.roots
```

### Sampling (Server-requested LLM completions)

```ruby
# Configure handler when creating client
client = MCPClient.connect('http://server/mcp',
  sampling_handler: ->(messages, model_prefs, system_prompt, max_tokens) {
    # Process server's LLM request
    {
      'model' => 'gpt-4',
      'stopReason' => 'endTurn',
      'role' => 'assistant',
      'content' => { 'type' => 'text', 'text' => 'Response here' }
    }
  }
)
```

### Completion (Autocomplete)

```ruby
result = client.complete(
  ref: { type: 'ref/prompt', name: 'greeting' },
  argument: { name: 'name', value: 'A' }
)
# => { 'values' => ['Alice', 'Alex'], 'total' => 100, 'hasMore' => true }
```

### Logging

```ruby
# Set log level
client.set_log_level('debug')  # debug/info/notice/warning/error/critical

# Handle log notifications
client.on_notification do |server, method, params|
  if method == 'notifications/message'
    puts "[#{params['level']}] #{params['logger']}: #{params['data']}"
  end
end
```

### Elicitation (Server-initiated user interactions)

```ruby
client = MCPClient::Client.new(
  mcp_server_configs: [MCPClient.stdio_config(command: 'python server.py')],
  elicitation_handler: ->(message, schema) {
    puts "Server asks: #{message}"
    # Return: { 'action' => 'accept', 'content' => { 'field' => 'value' } }
    # Or: { 'action' => 'decline' } or { 'action' => 'cancel' }
  }
)
```

## Advanced Configuration

For more control, use `create_client` with explicit configs:

```ruby
client = MCPClient.create_client(
  mcp_server_configs: [
    MCPClient.stdio_config(command: 'npx server', name: 'local'),
    MCPClient.sse_config(
      base_url: 'https://api.example.com/sse',
      headers: { 'Authorization' => 'Bearer TOKEN' },
      read_timeout: 30, ping: 10, retries: 3
    ),
    MCPClient.http_config(
      base_url: 'https://api.example.com',
      endpoint: '/rpc',
      headers: { 'Authorization' => 'Bearer TOKEN' }
    ),
    MCPClient.streamable_http_config(
      base_url: 'https://api.example.com/mcp',
      read_timeout: 60, retries: 3
    )
  ],
  logger: Logger.new($stdout)
)

# Or load from JSON file
client = MCPClient.create_client(server_definition_file: 'servers.json')
```

### Faraday Customization

```ruby
MCPClient.http_config(base_url: 'https://internal.company.com') do |faraday|
  faraday.ssl.cert_store = custom_cert_store
  faraday.ssl.verify = true
end
```

### Server Definition JSON

```json
{
  "mcpServers": {
    "filesystem": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home"]
    },
    "api": {
      "type": "streamable_http",
      "url": "https://api.example.com/mcp",
      "headers": { "Authorization": "Bearer TOKEN" }
    }
  }
}
```

## AI Integration Examples

### OpenAI

```ruby
require 'mcp_client'
require 'openai'

mcp = MCPClient.connect('npx -y @modelcontextprotocol/server-filesystem .')
tools = mcp.to_openai_tools

client = OpenAI::Client.new(api_key: ENV['OPENAI_API_KEY'])
response = client.chat.completions.create(
  model: 'gpt-4',
  messages: [{ role: 'user', content: 'List files' }],
  tools: tools
)
```

### Anthropic

```ruby
require 'mcp_client'
require 'anthropic'

mcp = MCPClient.connect('npx -y @modelcontextprotocol/server-filesystem .')
tools = mcp.to_anthropic_tools

client = Anthropic::Client.new(access_token: ENV['ANTHROPIC_API_KEY'])
# Use tools with Claude API
```

See `examples/` for complete implementations:
- `ruby_openai_mcp.rb`, `openai_ruby_mcp.rb` - OpenAI integration
- `ruby_anthropic_mcp.rb` - Anthropic integration
- `gemini_ai_mcp.rb` - Google Vertex AI integration

## OAuth 2.1 Authentication

```ruby
require 'mcp_client/auth/browser_oauth'

oauth = MCPClient::Auth::OAuthProvider.new(
  server_url: 'https://api.example.com/mcp',
  redirect_uri: 'http://localhost:8080/callback',
  scope: 'mcp:read mcp:write'
)

browser_oauth = MCPClient::Auth::BrowserOAuth.new(oauth)
token = browser_oauth.authenticate  # Opens browser, handles callback

client = MCPClient::Client.new(
  mcp_server_configs: [{
    type: 'streamable_http',
    base_url: 'https://api.example.com/mcp',
    oauth_provider: oauth
  }]
)
```

Features: PKCE, server discovery (`.well-known`), dynamic registration, token refresh.

See [OAUTH.md](OAUTH.md) for full documentation.

## Server Notifications

```ruby
client.on_notification do |server, method, params|
  case method
  when 'notifications/tools/list_changed'
    client.clear_cache  # Auto-handled
  when 'notifications/message'
    puts "Log: #{params['data']}"
  when 'notifications/roots/list_changed'
    puts "Roots changed"
  end
end
```

## Session Management

Both HTTP and Streamable HTTP transports automatically handle session-based servers:

- **Session capture**: Extracts `Mcp-Session-Id` from initialize response
- **Session persistence**: Includes session header in subsequent requests
- **Session termination**: Sends DELETE request during cleanup
- **Resumability** (Streamable HTTP): Tracks event IDs for message replay

No configuration required - works automatically.

## Server Compatibility

Works with any MCP-compatible server:

- [@modelcontextprotocol/server-filesystem](https://www.npmjs.com/package/@modelcontextprotocol/server-filesystem)
- [@playwright/mcp](https://www.npmjs.com/package/@playwright/mcp)
- [FastMCP](https://github.com/jlowin/fastmcp)
- Custom servers implementing MCP protocol

### FastMCP Example

```bash
# Start server
python examples/echo_server_streamable.py
```

```ruby
# Connect and use
client = MCPClient.connect('http://localhost:8931/mcp')
tools = client.list_tools
result = client.call_tool('echo', { message: 'Hello!' })
```

## Requirements

- Ruby >= 3.2.0
- No runtime dependencies

## License

Available as open source under the [MIT License](LICENSE).

## Contributing

Bug reports and pull requests welcome at https://github.com/simonx1/ruby-mcp-client.
