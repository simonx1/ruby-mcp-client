# frozen_string_literal: true

module MCPClient
  # Current version of the MCP client gem
  VERSION = '2.1.0'

  # Latest MCP protocol revision this client implements (basic/versioning).
  # Modern revisions (2026-07-28 and later) carry the protocol version,
  # client identity and capabilities as per-request `_meta` fields instead
  # of negotiating them once in an `initialize` handshake.
  LATEST_PROTOCOL_VERSION = '2026-07-28'

  # Protocol revisions that use per-request metadata (no handshake), newest
  # first. Every request to a modern server declares one of these in
  # `_meta["io.modelcontextprotocol/protocolVersion"]`.
  MODERN_PROTOCOL_VERSIONS = %w[2026-07-28].freeze

  # Protocol revisions that establish a session with an `initialize`
  # handshake (2025-11-25 and earlier), newest first.
  LEGACY_PROTOCOL_VERSIONS = %w[2025-11-25 2025-06-18 2025-03-26 2024-11-05].freeze

  # Protocol version sent in the legacy `initialize` request: the newest
  # handshake-based revision. A legacy server may negotiate down to any
  # other LEGACY_PROTOCOL_VERSIONS entry.
  PROTOCOL_VERSION = '2025-11-25'

  # Every protocol version this client can speak, in preference order.
  SUPPORTED_PROTOCOL_VERSIONS = (MODERN_PROTOCOL_VERSIONS + LEGACY_PROTOCOL_VERSIONS).freeze
end
