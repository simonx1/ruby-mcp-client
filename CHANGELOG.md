# Changelog

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