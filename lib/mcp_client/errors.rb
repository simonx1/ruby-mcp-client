# frozen_string_literal: true

module MCPClient
  # Collection of error classes used by the MCP client
  module Errors
    # Base error class for all MCP-related errors
    class MCPError < StandardError; end

    # Raised when a tool is not found
    class ToolNotFound < MCPError; end

    # Raised when a prompt is not found
    class PromptNotFound < MCPError; end

    # Raised when a server is not found
    class ServerNotFound < MCPError; end

    # Raised when there's an error getting a prompt
    class PromptGetError < MCPError; end

    # Raised when there's an error calling a tool
    class ToolCallError < MCPError; end

    # Raised when there's a connection error with an MCP server
    class ConnectionError < MCPError; end

    # Raised when the MCP server returns an error response
    class ServerError < MCPError; end

    # Raised when there's an error in the MCP server transport
    class TransportError < MCPError; end

    # Raised when tool parameters fail validation against JSON schema
    class ValidationError < MCPError; end

    # Raised when multiple tools with the same name exist across different servers
    class AmbiguousToolName < MCPError; end

    # Raised when multiple prompts with the same name exist across different servers
    class AmbiguousPromptName < MCPError; end
  end
end
