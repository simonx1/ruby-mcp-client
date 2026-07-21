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

    # Raised when a request requires a server capability that was not
    # negotiated during initialization (MCP lifecycle: "Only use capabilities
    # that were successfully negotiated")
    class CapabilityError < MCPError; end

    # Raised for an HTTP 403 with a WWW-Authenticate insufficient_scope
    # challenge (MCP 2025-11-25 / SEP-835). Exposes the challenge parameters
    # so hosts can run a step-up authorization flow with the required scopes.
    class InsufficientScopeError < ConnectionError
      # @return [String, nil] the scopes required by the server's challenge
      attr_reader :scope
      # @return [String, nil] the challenge's human-readable error description
      attr_reader :error_description

      # @param message [String] error message
      # @param scope [String, nil] scopes from the challenge's scope parameter
      # @param error_description [String, nil] challenge error_description
      def initialize(message, scope: nil, error_description: nil)
        super(message)
        @scope = scope
        @error_description = error_description
      end
    end

    # Raised when the MCP server returns an error response
    class ServerError < MCPError; end

    # Raised for a server-side failure that is plausibly transient and safe to
    # retry — chiefly HTTP 5xx responses, where the request likely did not
    # complete at the application layer. It is a subclass of ServerError so that
    # existing `rescue MCPClient::Errors::ServerError` handlers keep catching it,
    # while the retry logic can single it out. Application-level failures
    # (JSON-RPC error responses, HTTP 4xx) use plain ServerError and are NOT
    # retried, since the server already processed/rejected the request.
    class TransientServerError < ServerError; end

    # Raised when there's an error in the MCP server transport
    class TransportError < MCPError; end

    # Raised when tool parameters fail validation against the tool's input
    # schema, or (in strict mode) when a tool result's structuredContent fails
    # validation against the tool's output schema
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
