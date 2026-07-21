# frozen_string_literal: true

module MCPClient
  # Current version of the MCP client gem
  VERSION = '1.1.0'

  # MCP protocol version (date-based) - unified across all transports
  PROTOCOL_VERSION = '2025-11-25'

  # Protocol revisions this client can speak, newest first. Used during
  # version negotiation: if the server answers initialize with a version
  # outside this set, the client must disconnect (MCP lifecycle).
  SUPPORTED_PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze
end
