#!/usr/bin/env ruby
# frozen_string_literal: true

# OAuth Example for Ruby MCP Client
# This example demonstrates how to use OAuth 2.1 authentication with MCP servers

require 'bundler/setup'
require_relative '../lib/mcp_client'
require 'logger'

# Create an MCPClient client (stdio stub for demo)
logger = Logger.new($stdout)
logger.level = Logger::DEBUG

# Example 1: Create an OAuth-enabled HTTP server
puts 'Creating OAuth-enabled HTTP server...'

server = MCPClient::OAuthClient.create_streamable_http_server(
  server_url: 'https://mcp.zapier.com/api/v1/connect?token=<ZAPIER_MCP_TOKEN>',
  logger:
)

# Example 2: Check if server has valid token
if MCPClient::OAuthClient.valid_token?(server)
  puts '✓ Server already has a valid OAuth token'
else
  puts '⚠ Server needs OAuth authorization'

  # Start OAuth authorization flow
  auth_url = MCPClient::OAuthClient.start_oauth_flow(server)
  puts "Please visit this URL to authorize: #{auth_url}"

  # In a real application, you would:
  # 1. Open the auth_url in a browser or redirect the user
  # 2. Handle the callback to extract the authorization code and state
  # 3. Complete the flow with the authorization code

  puts 'After authorization, you would call:'
  puts 'token = MCPClient::OAuthClient.complete_oauth_flow(server, authorization_code, state)'
  # require 'byebug'
  # byebug
end

# Example 3: Create OAuth-enabled Streamable HTTP server
puts "\nCreating OAuth-enabled Streamable HTTP server..."

MCPClient::OAuthClient.create_streamable_http_server(
  server_url: 'https://streaming.example.com/mcp',
  redirect_uri: 'http://localhost:8080/callback',
  scope: 'stream:read stream:write',
  name: 'example-streaming-server'
)

# Example 4: Using with MCP Client
puts "\nUsing OAuth servers with MCP Client..."

# Create a client with OAuth-enabled servers
MCPClient::Client.new(
  mcp_server_configs: [], # Empty configs since we're adding servers manually
  logger: Logger.new($stdout, level: Logger::INFO)
)

# Add OAuth servers to client
# Note: In practice, you'd typically create servers through configurations
# This manual approach is for demonstration

# Example 5: Manual OAuth flow (for educational purposes)
puts "\nManual OAuth flow example:"

# Create OAuth provider directly
oauth_provider = MCPClient::Auth::OAuthProvider.new(
  server_url: 'https://api.example.com/mcp',
  redirect_uri: 'http://localhost:8080/callback',
  scope: 'mcp:read mcp:write'
)

# Check current token status
current_token = oauth_provider.access_token
if current_token
  puts 'Current token status:'
  puts "  Access token: #{current_token.access_token[0..10]}..."
  puts "  Expires: #{current_token.expires_at}"
  puts "  Expired: #{current_token.expired?}"
  puts "  Expires soon: #{current_token.expires_soon?}"
else
  puts 'No current token available'
end

# Example 6: Token storage
puts "\nToken storage example:"

# Create custom storage (in practice, you might use a database or file)
class FileTokenStorage
  def initialize(filename)
    @filename = filename
    @data = load_data
  end

  def get_token(server_url)
    token_data = @data.dig('tokens', server_url)
    token_data ? MCPClient::Auth::Token.from_h(token_data) : nil
  end

  def set_token(server_url, token)
    @data['tokens'] ||= {}
    @data['tokens'][server_url] = token.to_h
    save_data
  end

  def get_client_info(server_url)
    client_data = @data.dig('clients', server_url)
    client_data ? MCPClient::Auth::ClientInfo.from_h(client_data) : nil
  end

  def set_client_info(server_url, client_info)
    @data['clients'] ||= {}
    @data['clients'][server_url] = client_info.to_h
    save_data
  end

  # Implement other required methods...
  def get_server_metadata(server_url) = @data.dig('server_metadata', server_url)
  def set_server_metadata(server_url, metadata) = (@data['server_metadata'] ||= {})[server_url] = metadata.to_h
  def get_pkce(server_url) = @data.dig('pkce', server_url)
  def set_pkce(server_url, pkce) = (@data['pkce'] ||= {})[server_url] = pkce
  def delete_pkce(server_url) = @data['pkce']&.delete(server_url)
  def get_state(server_url) = @data.dig('state', server_url)
  def set_state(server_url, state) = (@data['state'] ||= {})[server_url] = state
  def delete_state(server_url) = @data['state']&.delete(server_url)

  private

  def load_data
    File.exist?(@filename) ? JSON.parse(File.read(@filename)) : {}
  rescue JSON::ParserError
    {}
  end

  def save_data
    File.write(@filename, JSON.pretty_generate(@data))
  end
end

# Create server with custom storage
storage = FileTokenStorage.new('oauth_tokens.json')
MCPClient::OAuthClient.create_http_server(
  server_url: 'https://api.example.com/mcp',
  storage: storage
)

puts 'Created server with persistent token storage'

# Example 7: Error handling
puts "\nOAuth error handling:"

begin
  # This would normally trigger OAuth flow if not authorized
  # server.connect
  puts 'Connection attempt would trigger OAuth flow if needed'
rescue MCPClient::Errors::ConnectionError => e
  if e.message.include?('OAuth authorization required')
    puts 'OAuth authorization required - starting flow...'
    # Handle OAuth flow
  else
    puts "Connection error: #{e.message}"
  end
end

puts "\nOAuth implementation complete!"
puts 'See the OAuth specification for full details on the authorization flow.'
