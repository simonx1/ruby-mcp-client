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

Implements **MCP 2025-11-25** specification:

- **Tools**: list, call, streaming, annotations (hint-style), structured outputs, title
- **Prompts**: list, get with parameters
- **Resources**: list, read, templates, subscriptions, pagination, ResourceLink content
- **Elicitation**: Server-initiated user interactions (stdio, SSE, Streamable HTTP)
- **Roots**: Filesystem scope boundaries with change notifications
- **Sampling**: Server-requested LLM completions with modelPreferences
- **Completion**: Autocomplete for prompts/resources with context
- **Logging**: Server log messages with level filtering
- **Tasks**: Task-augmented `tools/call` — create with a `ttl`, poll `tasks/get`, retrieve via `tasks/result`, plus `tasks/list` and `tasks/cancel`
- **Audio**: Audio content type support
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

# Pagination: list_tools and list_prompts automatically follow the server's
# nextCursor and return the COMPLETE set across all pages (with a per-call
# safety bound and an identical-cursor loop guard). No manual cursor handling
# is required.

# Resources
result = client.list_resources
contents = client.read_resource('file:///example.txt')
contents.each do |content|
  puts content.text if content.text?
  data = Base64.decode64(content.blob) if content.binary?
end
```

## MCP 2025-11-25 Features

### Tool Annotations

```ruby
tool = client.find_tool('delete_user')

# Hint-style annotations (MCP 2025-11-25)
# Defaults follow the MCP ToolAnnotations schema: when a hint is absent the
# client assumes the less-safe value, so an un-annotated tool is treated as
# writable, potentially destructive, and open-world.
tool.read_only_hint?      # Defaults to false; tool may modify its environment
tool.destructive_hint?    # Defaults to true; tool may perform destructive updates
tool.idempotent_hint?     # Defaults to false; repeated calls may have additional effects
tool.open_world_hint?     # Defaults to true; tool may interact with external entities

# Legacy annotations
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
client.roots = [
  { uri: 'file:///home/user/project', name: 'Project' },
  { uri: 'file:///var/log', name: 'Logs' }
]

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
client.log_level = 'debug'  # debug/info/notice/warning/error/critical

# Handle log notifications
client.on_notification do |server, method, params|
  if method == 'notifications/message'
    puts "[#{params['level']}] #{params['logger']}: #{params['data']}"
  end
end
```

### Tasks (Long-running, task-augmented tools)

A task-capable server (one advertising `tasks.requests.tools.call`) can run a tool
whose `execution.taskSupport` is `optional` or `required` as a background task:
the call returns immediately with a task handle, and the result is fetched later.

```ruby
tool = client.find_tool('long_job')
tool.supports_task?   # execution.taskSupport is optional/required?

# Create the task (returns immediately); ttl is the requested lifetime in ms
task = client.call_tool_as_task('long_job', { input: 'data' }, ttl: 60_000)

# Poll until the task reaches a terminal (or input-required) status,
# honoring the server's suggested poll interval
until task.terminal? || task.input_required?
  sleep((task.poll_interval || 1000) / 1000.0)
  task = client.get_task(task.task_id)   # tasks/get
end

# Retrieve the underlying result (e.g. a CallToolResult) via tasks/result
result = client.get_task_result(task.task_id)

# List and cancel tasks
page = client.list_tasks               # { tasks: [...], next_cursor: ... }
client.cancel_task(task.task_id)       # tasks/cancel

# React to server-pushed status updates
client.on_notification do |server, method, params|
  puts "Task #{params['taskId']} -> #{params['status']}" if method == 'notifications/tasks/status'
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

### Retries

The `retries:` option controls automatic retry with exponential backoff. Only
failures where the request most likely did **not** complete at the server are
retried: transport/network errors and HTTP **5xx** responses. Application-level
failures — a JSON-RPC error response or an HTTP **4xx** — are **never** retried,
because the server already processed or rejected the request and re-sending
would risk re-executing a non-idempotent `tools/call`. Retryable server failures
raise `MCPClient::Errors::TransientServerError`, a subclass of
`MCPClient::Errors::ServerError`, so existing `rescue ServerError` handlers are
unaffected.

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

### RubyLLM

```ruby
require 'mcp_client'
require 'ruby_llm'

RubyLLM.configure { |c| c.openai_api_key = ENV['OPENAI_API_KEY'] }
mcp = MCPClient.connect('http://localhost:8931/mcp')  # Playwright MCP

# Wrap each MCP tool as a RubyLLM tool
tools = mcp.list_tools.map do |t|
  tool_name = t.name
  Class.new(RubyLLM::Tool) do
    description t.description
    params t.schema
    define_method(:name) { tool_name }
    define_method(:execute) { |**args| mcp.call_tool(tool_name, args) }
  end.new
end

chat = RubyLLM.chat(model: 'gpt-4o-mini')
tools.each { |tool| chat.with_tool(tool) }
response = chat.ask('Navigate to google.com and tell me the page title')
```

See `examples/` for complete implementations:
- `ruby_openai_mcp.rb`, `openai_ruby_mcp.rb` - OpenAI integration
- `ruby_anthropic_mcp.rb` - Anthropic integration
- `gemini_ai_mcp.rb` - Google Vertex AI integration
- `ruby_llm_mcp.rb` - RubyLLM integration (OpenAI provider)

## Running the Examples

The `examples/run_all_examples.sh` harness runs every example that can run on the current machine — self-contained stdio servers, the Python/Flask/FastMCP echo and elicitation servers, `npx`-based MCP servers, and (optionally) the paid LLM integrations. It starts and tears down each server automatically and prints a `PASS`/`FAIL`/`SKIP` summary. A few examples that need a real remote service or interactive input (`tasks_example.rb`, `oauth_browser_auth.rb`, `oauth_example.rb`) are always skipped.

### Prerequisites

Run `bundle install` first. The script preflight-checks the following and prints a warning (it does **not** abort) for anything missing; affected examples are then skipped or fail:

- `ruby`, `bundle`, `curl`, `lsof` - on `PATH`
- `python3` (or `$PYTHON`) plus a separate `python` binary - on `PATH`
- Python packages `flask`, `fastmcp`, `mcp` - importable by `$PYTHON`
- `npx` (Node) - needed by the `npx`-based example (`json_input`) and by every LLM example, which spawn `npx` filesystem/Playwright servers

### Usage

```bash
examples/run_all_examples.sh                       # run everything runnable on this machine
RUN_AI=0 examples/run_all_examples.sh              # skip the paid-LLM examples
RUN_NPX=0 examples/run_all_examples.sh             # skip the npx-based example (json_input)
LOG_DIR=/path examples/run_all_examples.sh         # write logs to a chosen dir
PYTHON=python3.12 TIMEOUT=180 examples/run_all_examples.sh  # override interpreter and per-example timeout
```

### Environment Knobs

| Variable | Default | Effect |
|----------|---------|--------|
| `RUN_AI` | `1` | Set to `0` to skip the LLM integrations, which make **real, paid** API calls. |
| `RUN_NPX` | `1` | Set to `0` (or leave `npx` off `PATH`) to skip the `npx`-based example (`json_input`). The LLM examples spawn `npx` servers too, but are gated by `RUN_AI` and their API keys instead. |
| `PYTHON` | `python3` | Interpreter used to launch the Python/Flask/FastMCP servers and run the import preflight checks. |
| `TIMEOUT` | `120` | Per-example wall-clock timeout in seconds; a timeout is reported as a `FAIL`. |
| `LOG_DIR` | fresh `mktemp` dir | Directory for per-example and per-server logs; the path is printed after preflight and in the summary. |

### Secrets and API Keys

Real secrets live in `examples/secrets.env`, which is **gitignored** and sourced automatically (every `KEY=value` line is exported) when present. Copy the tracked template to get started:

```bash
cp examples/secrets.env.example examples/secrets.env
# then set ZAPIER_MCP_TOKEN=... to enable the Zapier streamable-HTTP example
```

Set `ZAPIER_MCP_TOKEN` (from the Zapier MCP setup page, "Option 1: Authorization header") to run `streamable_http_example.rb` against Zapier; override `ZAPIER_MCP_URL` if your connect URL differs. The LLM examples each need their own credentials in the environment and are skipped without them:

- `ruby_anthropic_mcp.rb` - `ANTHROPIC_API_KEY` (+ `npx`)
- `openai_ruby_mcp.rb` - `OPENAI_API_KEY` (+ `npx`)
- `ruby_openai_mcp.rb`, `ruby_llm_mcp.rb` - `OPENAI_API_KEY` (+ `npx`, plus a Playwright MCP server on `:8931`)
- `gemini_ai_mcp.rb` - a Vertex service-account JSON at `VERTEX_CREDENTIALS_FILE` (default `examples/google-credentials.json`, + `npx`)

### How Pass/Fail Is Judged

Most examples print their own success/failure marks but exit `0` regardless, so the harness combines the exit code with a scan of the output rather than trusting the exit status alone. An example `FAIL`s when it exits nonzero, times out (exit `124`), prints a hard-error signature (a Ruby/Python traceback, `Connection refused`, `uninitialized constant`, and similar), prints a `❌` mark, or is missing its expected success marker; otherwise it `PASS`es. (The `❌` check is suppressed with `IGNORE_XMARK=1` for the interactive elicitation demos, where `❌` can be legitimate "declined" output.) The script exits `0` only if zero examples failed — `SKIP`s do not affect the exit status.

For deeper, per-topic walkthroughs see [`examples/README.md`](examples/README.md), [`examples/README_ECHO_SERVER.md`](examples/README_ECHO_SERVER.md), [`examples/STREAMABLE_HTTP_TESTING.md`](examples/STREAMABLE_HTTP_TESTING.md), and [`examples/elicitation/README.md`](examples/elicitation/README.md).

## OAuth 2.1 Authentication

```ruby
require 'mcp_client'
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
