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

    # Raised when a resource is not found
    class ResourceNotFound < MCPError; end

    # Raised when a server is not found
    class ServerNotFound < MCPError; end

    # Raised when there's an error calling a tool
    class ToolCallError < MCPError; end

    # Raised when there's an error getting a prompt
    class PromptGetError < MCPError; end

    # Raised when there's an error reading a resource
    class ResourceReadError < MCPError; end

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

    # Raised when multiple resources with the same URI exist across different servers
    class AmbiguousResourceURI < MCPError; end

    # Raised when transport type cannot be determined from target URL/command
    class TransportDetectionError < MCPError; end

    # Raised when a task is not found
    class TaskNotFound < MCPError; end

    # Raised when there's an error creating or managing a task
    class TaskError < MCPError; end
  end
end
