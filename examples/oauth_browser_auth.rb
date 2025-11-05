#!/usr/bin/env ruby
# frozen_string_literal: true

# Example: OAuth Browser-Based Authentication Flow
#
# This example demonstrates how to use browser-based OAuth authentication
# with the MCP client. It will:
# 1. Start a local HTTP server to handle the OAuth callback
# 2. Open your browser to the authorization page
# 3. Wait for you to authorize
# 4. Automatically capture the authorization code
# 5. Complete the OAuth flow and obtain an access token
# 6. Use the token to make authenticated requests to the MCP server

require 'bundler/setup'
require_relative '../lib/mcp_client'
require_relative '../lib/mcp_client/auth/browser_oauth'
require 'logger'

# Configuration
SERVER_URL = ENV['MCP_SERVER_URL'] || 'http://localhost:3000/mcp'
OAUTH_SCOPE = ENV.fetch('OAUTH_SCOPE', nil) # Optional OAuth scope
CALLBACK_PORT = (ENV['CALLBACK_PORT'] || 8080).to_i

# Create logger
logger = Logger.new($stdout)
logger.level = Logger::INFO

puts '=' * 80
puts 'MCP Client - Browser-Based OAuth Authentication Example'
puts '=' * 80
puts
puts "Server URL: #{SERVER_URL}"
puts "OAuth Scope: #{OAUTH_SCOPE || '(default)'}"
puts "Callback Port: #{CALLBACK_PORT}"
puts

# Step 1: Create OAuth provider
puts 'Step 1: Setting up OAuth provider...'

# Create a fresh storage instance (clears any cached credentials)
storage = MCPClient::Auth::OAuthProvider::MemoryStorage.new

oauth_provider = MCPClient::Auth::OAuthProvider.new(
  server_url: SERVER_URL,
  redirect_uri: "http://localhost:#{CALLBACK_PORT}/callback",
  scope: OAUTH_SCOPE,
  logger: logger,
  storage: storage
)

# Step 2: Create browser OAuth helper
puts 'Step 2: Creating browser OAuth helper...'
browser_oauth = MCPClient::Auth::BrowserOAuth.new(
  oauth_provider,
  callback_port: CALLBACK_PORT,
  callback_path: '/callback',
  logger: logger
)

# Step 3: Perform authentication
puts 'Step 3: Starting browser-based authentication...'
puts

begin
  # This will open the browser and wait for authorization
  token = browser_oauth.authenticate(
    timeout: 300, # 5 minutes timeout
    auto_open_browser: true
  )

  puts
  puts '=' * 80
  puts 'Authentication Successful!'
  puts '=' * 80
  puts
  puts "Access Token: #{token.access_token[0..20]}..."
  puts "Token Type: #{token.token_type}"
  puts "Expires In: #{token.expires_in} seconds" if token.expires_in
  puts "Scope: #{token.scope}" if token.scope
  puts "Has Refresh Token: #{!token.refresh_token.nil?}"
  puts

  # Step 4: Create an authenticated MCP client
  puts 'Step 4: Creating authenticated MCP client...'

  # Create an OAuth-enabled Streamable HTTP server config
  # Note: Sentry MCP and other modern MCP servers use Streamable HTTP with SSE support
  server_config = {
    type: 'streamable_http',
    base_url: SERVER_URL,
    headers: {},
    oauth_provider: oauth_provider
  }

  # Create a client with the authenticated server
  client = MCPClient::Client.new(mcp_server_configs: [server_config], logger: logger)

  # Test the connection
  puts 'Testing connection to MCP server...'
  client.ping

  puts 'Successfully connected to MCP server!'
  puts

  # Step 5: List available tools
  puts 'Step 5: Listing available tools...'
  tools = client.list_tools

  if tools.empty?
    puts 'No tools available'
  else
    puts 'Available tools:'
    tools.each do |tool|
      puts "  - #{tool.name}: #{tool.description}"
    end
  end
  puts

  # Step 6: Demonstrate token refresh (if applicable)
  if token.expires_in && token.refresh_token
    puts 'Step 6: Token refresh is available'
    puts 'The access token will be automatically refreshed when it expires.'
    puts "Token expires at: #{token.expires_at}"
  end
  puts

  puts '=' * 80
  puts 'Example completed successfully!'
  puts '=' * 80
rescue Timeout::Error => e
  puts
  puts "ERROR: #{e.message}"
  puts 'You took too long to authorize. Please try again.'
  exit 1
rescue MCPClient::Errors::ConnectionError => e
  puts
  puts "ERROR: Connection failed - #{e.message}"
  puts
  puts 'Make sure:'
  puts "1. The MCP server is running at #{SERVER_URL}"
  puts '2. The server supports OAuth 2.1 authentication'
  puts '3. The server has dynamic client registration enabled'
  exit 1
rescue StandardError => e
  puts
  puts "ERROR: #{e.class} - #{e.message}"
  puts e.backtrace.first(5).join("\n")
  exit 1
ensure
  # Cleanup
  client&.cleanup
end
