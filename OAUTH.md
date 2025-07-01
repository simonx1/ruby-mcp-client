# OAuth 2.1 Support for Ruby MCP Client

This implementation provides OAuth 2.1 authentication support for the Ruby MCP Client, following the [MCP Authorization specification](https://spec.modelcontextprotocol.io/specification/protocol/authorization/).

## Features

- **OAuth 2.1 compliance** with security best practices
- **PKCE (Proof Key for Code Exchange)** for secure authorization
- **Automatic server discovery** via `.well-known` endpoints
- **Dynamic client registration** when supported by servers
- **Token refresh** and automatic token management
- **Resource parameter implementation** (RFC 8707) for proper token audience binding
- **Pluggable storage** for tokens and client credentials

## Quick Start

### Basic Usage

```ruby
require 'mcp_client'

# Create an OAuth-enabled HTTP server
server = MCPClient::OAuthClient.create_http_server(
  server_url: 'https://api.example.com/mcp',
  redirect_uri: 'http://localhost:8080/callback',
  scope: 'mcp:read mcp:write'
)

# Check if authorization is needed
unless MCPClient::OAuthClient.valid_token?(server)
  # Start OAuth flow
  auth_url = MCPClient::OAuthClient.start_oauth_flow(server)
  puts "Please visit: #{auth_url}"

  # After user authorization, complete the flow
  # token = MCPClient::OAuthClient.complete_oauth_flow(server, code, state)
end

# Use the server normally
server.connect
tools = server.list_tools
```

### Manual OAuth Provider

```ruby
# Create OAuth provider directly for more control
oauth_provider = MCPClient::Auth::OAuthProvider.new(
  server_url: 'https://api.example.com/mcp',
  redirect_uri: 'http://localhost:8080/callback',
  scope: 'mcp:read mcp:write'
)

# Start authorization flow
auth_url = oauth_provider.start_authorization_flow

# Complete flow after user authorization
token = oauth_provider.complete_authorization_flow(code, state)
```

## OAuth Flow Steps

The implementation follows the standard OAuth 2.1 authorization code flow with PKCE:

1. **Server Discovery**: Discover authorization server via `.well-known/oauth-protected-resource`
   - Uses the origin (scheme + host + port) of the MCP server URL for discovery
   - Example: `https://api.example.com/mcp/path?query=123` → `https://api.example.com/.well-known/oauth-protected-resource`
2. **Client Registration**: Automatically register OAuth client if dynamic registration is supported
3. **Authorization**: Redirect user to authorization server with PKCE parameters
4. **Token Exchange**: Exchange authorization code for access token using PKCE verifier
5. **Token Usage**: Include access token in MCP requests via `Authorization` header
6. **Token Refresh**: Automatically refresh tokens when they expire

## Configuration Options

### Server Creation Options

```ruby
server = MCPClient::OAuthClient.create_http_server(
  server_url: 'https://api.example.com/mcp',    # MCP server URL (required)
  redirect_uri: 'http://localhost:8080/callback', # OAuth redirect URI
  scope: 'mcp:read mcp:write',                  # OAuth scope
  endpoint: '/rpc',                             # JSON-RPC endpoint
  headers: {},                                  # Additional HTTP headers
  read_timeout: 30,                             # Request timeout
  retries: 3,                                   # Retry attempts
  retry_backoff: 1,                             # Retry backoff
  name: 'my-server',                            # Server name
  logger: Logger.new($stdout),                  # Logger instance
  storage: custom_storage                       # Custom storage backend
)
```

### OAuth Provider Options

```ruby
oauth_provider = MCPClient::Auth::OAuthProvider.new(
  server_url: 'https://api.example.com/mcp',    # MCP server URL (required)
  redirect_uri: 'http://localhost:8080/callback', # OAuth redirect URI
  scope: 'mcp:read mcp:write',                  # OAuth scope
  logger: Logger.new($stdout),                  # Logger instance
  storage: custom_storage                       # Custom storage backend
)
```

## Storage Backends

By default, the OAuth provider uses in-memory storage. For production use, implement a custom storage backend:

```ruby
class DatabaseTokenStorage
  def get_token(server_url)
    # Return MCPClient::Auth::Token or nil
  end

  def set_token(server_url, token)
    # Store token
  end

  def get_client_info(server_url)
    # Return MCPClient::Auth::ClientInfo or nil
  end

  def set_client_info(server_url, client_info)
    # Store client info
  end

  # Implement other required methods:
  # get_server_metadata, set_server_metadata
  # get_pkce, set_pkce, delete_pkce
  # get_state, set_state, delete_state
end

# Use custom storage
storage = DatabaseTokenStorage.new
server = MCPClient::OAuthClient.create_http_server(
  server_url: 'https://api.example.com/mcp',
  storage: storage
)
```

## Data Models

### Token

```ruby
token = MCPClient::Auth::Token.new(
  access_token: 'abc123',
  token_type: 'Bearer',
  expires_in: 3600,
  scope: 'mcp:read mcp:write',
  refresh_token: 'refresh123'
)

# Check token status
token.expired?      # Boolean
token.expires_soon? # Boolean (within 5 minutes)
token.to_header     # "Bearer abc123"
```

### Client Metadata

```ruby
metadata = MCPClient::Auth::ClientMetadata.new(
  redirect_uris: ['http://localhost:8080/callback'],
  token_endpoint_auth_method: 'none',
  grant_types: ['authorization_code', 'refresh_token'],
  response_types: ['code'],
  scope: 'mcp:read mcp:write'
)
```

### Server Metadata

```ruby
metadata = MCPClient::Auth::ServerMetadata.new(
  issuer: 'https://auth.example.com',
  authorization_endpoint: 'https://auth.example.com/authorize',
  token_endpoint: 'https://auth.example.com/token',
  registration_endpoint: 'https://auth.example.com/register'
)
```

## Error Handling

OAuth-related errors are raised as `MCPClient::Errors::ConnectionError`:

```ruby
begin
  server.connect
rescue MCPClient::Errors::ConnectionError => e
  if e.message.include?('OAuth authorization required')
    # Start OAuth flow
    auth_url = MCPClient::OAuthClient.start_oauth_flow(server)
    # Handle authorization...
  else
    # Handle other connection errors
    puts "Connection failed: #{e.message}"
  end
end
```

## Security Considerations

This implementation follows OAuth 2.1 security best practices:

- **PKCE is mandatory** for all authorization code flows
- **State parameter** is used to prevent CSRF attacks
- **Resource parameter** (RFC 8707) ensures token audience binding
- **Token validation** ensures tokens are used only with intended servers
- **Secure token storage** guidelines should be followed
- **HTTPS is required** for all OAuth endpoints

## Examples

See `examples/oauth_example.rb` for a complete working example.

## Testing

Run OAuth-related tests:

```bash
bundle exec rspec spec/lib/mcp_client/auth_spec.rb
bundle exec rspec spec/lib/mcp_client/auth/oauth_provider_spec.rb
bundle exec rspec spec/lib/mcp_client/oauth_client_spec.rb
```

## Compliance

This implementation conforms to:

- [OAuth 2.1 (IETF Draft)](https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/)
- [OAuth 2.0 Authorization Server Metadata (RFC 8414)](https://tools.ietf.org/html/rfc8414)
- [OAuth 2.0 Dynamic Client Registration (RFC 7591)](https://tools.ietf.org/html/rfc7591)
- [OAuth 2.0 Protected Resource Metadata (RFC 9728)](https://tools.ietf.org/html/rfc9728)
- [Resource Indicators for OAuth 2.0 (RFC 8707)](https://tools.ietf.org/html/rfc8707)
- [MCP Authorization Specification](https://spec.modelcontextprotocol.io/specification/protocol/authorization/)