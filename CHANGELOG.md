# Changelog

## 0.9.0 (2025-11-05)

### MCP Protocol Update
- **Updated to MCP 2025-06-18**: Latest protocol specification
  - Protocol version constant updated from `2025-03-26` to `2025-06-18`
  - All documentation and code comments updated to reference 2025-06-18
  - Maintains full backward compatibility with previous versions

### New Features

#### Elicitation (Server-initiated User Interactions)
- **Full Elicitation Support**: Servers can now request structured user input during tool execution
  - Implemented across all transports: stdio, SSE, and Streamable HTTP
  - Bidirectional JSON-RPC communication for interactive workflows
  - Support for all three response actions: `accept`, `decline`, `cancel`
  - Callback-based API with `elicitation_handler` parameter
  - Automatic decline when no handler registered
  - Thread-safe response delivery for HTTP-based transports
  - Proper handling of `elicitation/create` requests
  - Responses sent as JSON-RPC requests (method: `elicitation/response`)
  - Content field only included when present (not empty hash for decline/cancel)

#### Elicitation Examples
- **stdio Transport Example** (`examples/elicitation/`)
  - `elicitation_server.py` - Python MCP server with elicitation tools
  - `test_elicitation.rb` - Interactive Ruby client with user input
  - Tools: `create_document`, `send_notification`

- **Streamable HTTP Transport Example** (`examples/elicitation/`)
  - `elicitation_streamable_server.py` - Python server supporting both SSE and Streamable HTTP
  - `test_elicitation_streamable.rb` - Full-featured client with multi-step workflows
  - Tools: `create_document`, `delete_files`, `deploy_application`

- **SSE Transport Example** (`examples/elicitation/`)
  - `test_elicitation_sse_simple.rb` - Minimal SSE example with auto-response
  - Uses traditional SSE transport (GET /sse for stream, POST /sse for RPC)
  - Perfect for testing and CI/CD

#### Browser-based OAuth flow
- Added support for browser-based OAuth authentication flow (#50)

#### Streamable HTTP Gzip Support
- Added gzip compression support for streamable HTTP transport (by @purposemc) (#46)

### Implementation Details

#### Core Changes
- `lib/mcp_client/version.rb` - Updated PROTOCOL_VERSION to '2025-06-18'
- `lib/mcp_client/client.rb` - Added elicitation handler registration and propagation
- `lib/mcp_client/server_streamable_http.rb` - Added elicitation support for Streamable HTTP
  - `on_elicitation_request` - Register callback
  - `handle_elicitation_create` - Process elicitation requests
  - `send_elicitation_response` - Send responses via HTTP POST
  - `post_jsonrpc_response` - Thread-safe response delivery
- `lib/mcp_client/server_sse.rb` - Added elicitation support for SSE
  - Queue-based response delivery
  - Proper handling of JSON-RPC requests vs responses
- `lib/mcp_client/server_stdio.rb` - Added elicitation support for stdio
  - Bidirectional JSON-RPC over stdin/stdout
- `lib/mcp_client/json_rpc_common.rb` - Enhanced message type detection
- `lib/mcp_client/server_http.rb` - Base class updates

#### Bug Fixes
- Fixed elicitation ID extraction to correctly use JSON-RPC request ID
- Fixed elicitation response format to only include content when present
- Fixed response delivery mechanism for HTTP-based transports

### Documentation
- Updated main README with MCP 2025-06-18 as primary version
- Consolidated feature list under "MCP 2025-06-18 (Latest)"

### Dependencies
- Updated faraday from 2.13.4 to 2.14.0
- Updated faraday-follow_redirects from 0.3.0 to 0.4.0
- Various dev dependency updates

### Developer Experience
- Enhanced CI configuration and workflows

## 0.8.1 (2025-09-17)

### Breaking Changes
- **Resources API**: Updated resources implementation to fully comply with MCP specification
  - `list_resources` now returns `{ 'resources' => [...], 'nextCursor' => ... }` hash format on both client and server levels
  - `read_resource` now returns array of `ResourceContent` objects instead of hash with 'contents' key

### New Features
- **Full MCP Resources Specification Compliance**:
  - Added `ResourceContent` class for structured content handling with `text?` and `binary?` methods
  - Added `ResourceTemplate` class for URI templates following RFC 6570
  - Implemented cursor-based pagination for `list_resources` and `list_resource_templates`
  - Added `subscribe_resource` and `unsubscribe_resource` methods for real-time updates
  - Added support for resource annotations (audience, priority, lastModified)
  - Binary content properly handled with base64 encoding/decoding
  - All transport types (stdio, SSE, HTTP, streamable_http) now have consistent resource support

### Improvements
- **Code Quality**: Refactored `Client#read_resource` to reduce cyclomatic complexity
  - Extracted helper methods: `find_resource_on_server`, `find_resource_across_servers`, `execute_resource_read`
  - Improved code maintainability and readability
- **ServerHTTP**: Added complete resource methods that were previously missing
- **ServerHTTP**: Added prompts support (`list_prompts` and `get_prompt`)
- **Examples**: Updated echo_server_client.rb to use new ResourceContent API
- **Examples**: Enhanced echo_server_streamable.py with full resource features

## 0.8.0 (2025-09-16)

### New Features
- **MCP Prompts and Resources Support**: Added full support for MCP prompts and resources (#31)
  - Implemented `list_prompts` and `get_prompt` methods for prompt management
  - Implemented `list_resources` and `read_resource` methods for resource access
  - Added support for both text and blob resource types

### Bug Fixes
- **Tool Caching**: Fixed issue with caching tools that have the same name from different servers (#342ff55)
  - Tools are now properly disambiguated by server when cached
  - Improved tool resolution to prevent conflicts between servers

### Dependencies
- Updated openai from `9e5d91e` to `003ab1d` (dev dependency) (#30)
- Updated rubocop from 1.77.0 to 1.80.2 (dev dependency) (#28)
- Updated gemini-ai from 4.2.0 to 4.3.0 (dev dependency) (#25)

### Developer Experience
- Updated examples with improved error handling
- Enhanced CI workflow configuration

## 0.7.3 (2025-09-01)

### Bug Fixes
- **Streaming JSON Parsing**: Fixed streaming JSON parsing improvements for better handling of partial data chunks
- **SSE Connection**: Enhanced server-sent events connection reliability for real-time notifications

### Dependencies
- Updated faraday from 2.13.1 to 2.13.4
- Updated ruby-openai from 8.1.0 to 8.3.0 (dev dependency)
- Updated openai gem to latest version (dev dependency)
- Updated rdoc from 6.14.1 to 6.14.2 (dev dependency)

### Developer Experience
- Improved CI configuration and permissions
- Enhanced examples with better cleanup and error handling
- Fixed Rubocop style violations

## 0.7.2 (2025-07-14)

### Bug Fixes
- **JSON-RPC Parameter Handling**: Fixed SSE transport compatibility with Playwright MCP servers by reverting JSON-RPC parameter handling to not send `null` for empty parameters
- **Logger Formatter Preservation**: Fixed issue where custom logger formatters were being overridden in server implementations

### Transport Improvements
- **HTTP Redirect Support**: Added automatic redirect following (up to 3 hops) for both SSE and HTTP transports via faraday-follow_redirects gem

### Examples and Testing
- **FastMCP Integration**: Added complete FastMCP echo server example demonstrating Ruby-Python MCP interoperability
- **Comprehensive Logger Tests**: Added 29 new test cases covering logger functionality across all server types

### Developer Experience
- **Protocol Version Consistency**: Updated all examples and configurations to use MCP protocol version 2025-03-26
- **Enhanced Documentation**: Improved example scripts with better error handling and user guidance

## 0.7.1 (2025-06-20)

### OAuth 2.1 Authentication Framework
- Added comprehensive OAuth 2.1 support with PKCE for secure authentication
- Implemented automatic authorization server discovery via `.well-known` endpoints
- Added dynamic client registration when supported by servers
- Implemented token refresh and automatic token management
- Added pluggable storage backends for tokens and client credentials
- Created `MCPClient::OAuthClient` utility class for easy OAuth-enabled server creation
- Added runtime configuration support via getter/setter methods in `OAuthProvider`
- Included complete OAuth examples and documentation

### HTTP Transport Improvements
- Refactored HTTP transport layer using template method pattern for better code organization
- Eliminated code duplication across HTTP and Streamable HTTP transports
- Improved OAuth integration across all HTTP-based transports
- Enhanced error handling and authentication workflows
- Added proper session management and validation

### MCP 2025-03-26 Protocol Support
- Updated protocol version support to 2025-03-26
- Enhanced Streamable HTTP transport with improved SSE handling
- Added session ID capture and management for stateful servers

### Documentation and Examples
- Added comprehensive OAuth documentation (OAUTH.md)
- Updated README with OAuth usage examples and 2025 protocol features
- Enhanced oauth_example.rb with practical implementation patterns
- Improved code documentation and API clarity

## 0.6.2 (2025-05-20)

- Fixed reconnect attempts not being reset after successful ping
- Added test verification for nested array $schema removal
- Improved integration tests with Ruby-based test server instead of Node.js dependencies

## 0.6.1 (2025-05-18)

- Improved connection handling with automatic reconnection before RPC calls
- Extracted common JSON-RPC functionality into a shared module for better maintainability
- Enhanced error handling in SSE and stdio transports
- Improved stdio command handling for better security (Array format to avoid shell injection)
- Refactored server factory methods for improved parameter handling
- Streamlined server creation with intelligent command and arguments handling
- Unified error handling across transports

## 0.6.0 (2025-05-16)

- Server names are now properly retained after configuration parsing
- Added `find_server` method to retrieve servers by name
- Added server association in each tool for better traceability
- Added tool call disambiguation by specifying server name
- Added handling for ambiguous tool names with clear error messages
- Improved logger propagation from Client to all Server instances
- Fixed ping errors in SSE connection by adding proper connection state validation
- Improved connection state handling to prevent ping attempts on closed connections
- Enhanced error handling for unknown notification types
- Simplified code structure with a dedicated connection_active? helper method
- Reduced parameter passing complexity for better code maintainability
- Enhanced thread safety with more consistent connection state handling
- Added logger parameter to stdio_config and sse_config factory methods

## 0.5.3 (2025-05-13)

- Added `to_google_tools` method for Google Vertex AI API integration (by @IMhide)
- Added Google Vertex Gemini example with full integration demonstration
- Enhanced SSE connection management with automatic ping and inactivity tracking
- Improved connection reliability with automatic reconnection on idle connections
- Expanded README.md with updated documentation for SSE features

## 0.5.2 (2025-05-09)

- Improved authentication error handling in SSE connections
- Better error messages for authentication failures
- Code refactoring to improve maintainability and reduce complexity

## 0.5.1 (2025-04-26)

- Support for server definition files in JSON format

## 0.5.0 (2025-04-25)

- Enhanced SSE implementation and added Faraday HTTP support
- Updates for the HTTP client and endpoints
- Updates session handling
- Remove parameters from ping
- Code improvements

## 0.4.1 (2025-04-24)

- Server ping functionality
- Fix SSE connection handling and add graceful fallbacks

## 0.4.0 (2025-04-23)

- Added full "initialize" hand-shake support to the SSE transport
  - Added an @initialized flag and ensure_initialized helper
  - Hooked into list_tools and call_tool for JSON-RPC "initialize" to be sent once
  - Implemented perform_initialize to send the RPC, capture server info and capabilities
  - Exposed server_info and capabilities readers on ServerSSE

- Added JSON-RPC notifications dispatcher
  - ServerBase#on_notification to register blocks for incoming JSON-RPC notifications
  - ServerStdio and ServerSSE now detect notification messages and invoke callbacks
  - Client#on_notification to register client-level listeners
  - Automatic tool cache invalidation on "notifications/tools/list_changed"

- Added generic JSON-RPC methods to both transports
  - ServerBase: abstract rpc_request/rpc_notify
  - ServerStdio: rpc_request for blocking request/response, rpc_notify for notifications
  - ServerSSE: rpc_request via HTTP POST, rpc_notify to SSE messages endpoint
  - Client: send_rpc and send_notification methods for client-side JSON-RPC dispatch

- Added timeout & retry configurability with improved logging
  - Per-call timeouts & retries for both transports
  - Tagged, leveled logging across all components
  - Consistent retry and logging functionality

## 0.3.0 (2025-04-23)

- Removed HTTP server implementation
- Code cleanup

## 0.2.0 (2025-04-23)

- Client schema validation
- Client streaming API fallback/delegation
- ServerHTTP initialization
- Added list_tools, call_tool with streaming fallback
- HTTP error handling
- Support for calling multiple functions in batch
- Implement find_tool
- Tool cache control
- Added ability to filter tools by name in to_openai_tools and to_anthropic_tools

## 0.1.0 (2025-04-23)

Initial release of ruby-mcp-client:

- Support for SSE (Server-Sent Events) transport
  - Robust connection handling with configurable timeouts
  - Thread-safe implementation
  - Error handling and resilience
  - JSON-RPC over SSE support
- Standard I/O transport support
- Converters for popular LLM APIs:
  - OpenAI tools format
  - Anthropic Claude tools format
- Examples for integration with:
  - Official OpenAI Ruby gem
  - Community OpenAI Ruby gem
  - Anthropic Ruby gem