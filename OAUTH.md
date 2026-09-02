# OAuth 2.1 Support for Ruby MCP Client

This implementation provides OAuth 2.1 authentication support for the Ruby MCP Client, following the [MCP Authorization specification](https://spec.modelcontextprotocol.io/specification/protocol/authorization/).

## Features

- **OAuth 2.1 compliance** with security best practices
- **PKCE (Proof Key for Code Exchange)** for secure authorization
- **Automatic server discovery** via `.well-known` endpoints
- **Dynamic client registration** when supported by servers
- **Token refresh** and automatic token management
- **Per-authorization-server credentials** (MCP 2026-07-28): store pre-registered credentials with `registration_type: 'pre_registered'`; a stored record without a type counts as a dynamic registration and is redone for a new authorization server
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

1. **Server Discovery**: Protected Resource Metadata is authoritative (RFC 9728). On a `401` the client
   parses the `resource_metadata` parameter from the `WWW-Authenticate` header (a legacy `resource`
   parameter is accepted as a fallback); otherwise it probes the `.well-known` URLs in priority order.
   - **Protected Resource Metadata (RFC 9728 §3.1)** is path-aware: the well-known segment is inserted
     between host and path, then a root fallback is tried.
     - Example: `https://api.example.com/mcp` →
       `https://api.example.com/.well-known/oauth-protected-resource/mcp`, then
       `https://api.example.com/.well-known/oauth-protected-resource`
   - **Authorization Server Metadata (RFC 8414 §3.1 + OpenID Connect Discovery)**: for an issuer with a
     path, the well-known segment is *inserted* (not appended); both `oauth-authorization-server` and
     `openid-configuration` forms are tried in priority order.
   - The discovered protected-resource `resource` is validated against the server host (confused-deputy
     protection), and every authorization-server endpoint must use HTTPS (plain HTTP is allowed on the
     loopback interface — `localhost`, a `*.localhost` name, or any spelling of 127.0.0.0/8 or
     `::1` — for local development).
2. **Client Registration**: Automatically register OAuth client if dynamic registration is supported
   - A registration response names a client only when it is a JSON object whose `client_id` is a
     non-empty string (RFC 7591 Section 3.2.1). A `201` without one registered nothing, so it raises a
     `ConnectionError` and the flow ends *before* the browser is opened, rather than sending the user
     to the authorization endpoint with an empty `client_id`.
   - Every other field is read against the type RFC 7591 gives it: `client_secret`,
     `token_endpoint_auth_method`, `scope`, `client_name`, `client_uri`, `logo_uri`, `tos_uri`,
     `policy_uri` and `application_type` are strings, `client_id_issued_at` and
     `client_secret_expires_at` are integers, and `redirect_uris`, `grant_types`, `response_types`
     and `contacts` are arrays of strings. A field of any other type fails the registration with the
     same `ConnectionError` — `{"client_id": "c", "redirect_uris": "http://localhost:1/cb"}` is a
     reported registration failure, not a `NoMethodError` — and a `redirect_uris` the server omits or
     echoes back empty falls back to the redirect URI the registration asked for.
3. **Authorization**: Redirect user to authorization server with PKCE parameters
4. **Token Exchange**: Exchange authorization code for access token using PKCE verifier
   - A token response carries a credential only when it is a JSON object whose `access_token` is a
     non-empty string (RFC 6749 Section 5.1). Anything else — `200 {}`, `200 []`, `200 null`,
     `{"access_token": ["x"]}` — is a protocol error, not a credential: the exchange raises a
     `ConnectionError` and nothing is stored.
   - Every other field is read against the type RFC 6749 Section 5.1 gives it: `token_type` is a
     non-empty string, `expires_in` an integer, and `refresh_token` and `scope` strings. A field of
     any other type fails the exchange with the same `ConnectionError`, so `token_type: ["Bearer"]`
     never reaches the `Authorization` header and `expires_in: "3600"` never reaches a `Time`. A
     `null` field reads as an absent one (`token_type` still defaults to `Bearer`).
5. **Token Usage**: Include access token in MCP requests via `Authorization` header
6. **Token Refresh**: Automatically refresh tokens when they expire
   - A refresh response that carries no such `access_token`, or whose fields have the wrong JSON
     types, is a failed refresh: the still-valid token stays in storage and keeps being presented
     rather than being replaced by a bare `Bearer `, by the `to_s` of whatever JSON arrived, or by a
     `TypeError` raised out of the request path.

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

`server_url=` retargets an existing provider at another MCP server. Everything the provider learned
about the previous server in this process — the discovered authorization server metadata it keeps as a
fallback for storage backends that do not persist it, the memoized `supported_scopes`, and any adopted,
pending or refused `401` challenge — is forgotten, so the new server is discovered from scratch rather
than answered with the previous server's endpoints. Retirement markers for tokens are keyed by the
issuer they were retired for, not by the server URL, so they survive the change: bytes retired at an
authorization server stay retired for every MCP server behind it.

## Storage Backends

By default, the OAuth provider uses in-memory storage. For production use, implement a custom storage backend:

```ruby
class DatabaseTokenStorage
  def get_token(server_url)
    # Return MCPClient::Auth::Token or nil
  end

  def set_token(server_url, token)
    # Store token. A nil token means "forget it": remove the record rather
    # than serializing nil (a hash-persisting backend would otherwise store
    # an empty hash, which reads back as a token without bytes).
  end

  def get_client_info(server_url)
    # Return MCPClient::Auth::ClientInfo or nil
  end

  def set_client_info(server_url, client_info)
    # Store client info. A nil client_info means "forget it": remove the
    # record rather than serializing nil, for the same reason as set_token
    # (a record whose client_id is not a non-empty string reads back as no
    # client at all, and the next flow registers a new one).
  end

  # Implement other required methods:
  # get_server_metadata, set_server_metadata
  # get_pkce, set_pkce, delete_pkce
  # get_state, set_state, delete_state

  # Optional (MCP 2026-07-28): called when the authorization server behind
  # a resource changes, since a token from the previous one must not be
  # reused. Without it, set_token(server_url, nil) is attempted; a backend
  # that accepts neither is logged and the token is ignored instead.
  def delete_token(server_url)
    # Remove the stored token
  end

  # Optional (MCP 2026-07-28): called when a dynamic registration made with
  # the previous authorization server is discarded. Without it,
  # set_client_info(server_url, nil) is attempted.
  def delete_client_info(server_url)
    # Remove the stored client registration
  end
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
  registration_endpoint: 'https://auth.example.com/register',
  code_challenge_methods_supported: ['S256'] # advertised PKCE methods (RFC 8414)
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

- **PKCE is mandatory** for all authorization code flows. The client uses `S256` and **verifies the
  authorization server's `code_challenge_methods_supported`**: it refuses to proceed if the server
  explicitly advertises methods without `S256`, and warns (but proceeds) if the field is omitted.
- **State parameter** is used to prevent CSRF attacks
- **Resource parameter** (RFC 8707) ensures token audience binding — sent in both the authorization
  and token requests as the canonical server URI
- **Confused-deputy protection**: the protected-resource metadata `resource` is validated against the
  server host before its advertised authorization server is trusted
- **HTTPS is enforced** on all discovered authorization-server endpoints (authorization, token, and
  registration), with a loopback exception (`localhost`, `*.localhost`, 127.0.0.0/8, `::1`, in
  any spelling) for local development
- **Secure token storage** guidelines should be followed

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