# frozen_string_literal: true

module MCPClient
  # Collection of error classes used by the MCP client
  module Errors
    # Base error class for all MCP-related errors
    class MCPError < StandardError
      # Whether this failure left the request/response exchange incomplete —
      # a broken response stream, a timeout, an HTTP 5xx, an oversized body.
      # Such a failure says nothing about which protocol era the server
      # implements, so the server/discover probe re-raises it instead of
      # recording a (cached, permanent) legacy verdict.
      # @return [Boolean]
      def era_inconclusive?
        false
      end
    end

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

    # Raised when a server/discover probe identified the peer as a modern
    # (2026-07-28+) MCP server that this client cannot complete a connection
    # with — an incompatible version list, or a modern protocol error the
    # client cannot correct. A subclass of ConnectionError so existing
    # rescues keep working, but the era is settled: MCPClient's transport
    # detector re-raises it instead of falling back to the legacy SSE or
    # HTTP+POST transports, which cannot do better against a modern server.
    class ModernServerError < ConnectionError; end

    # JSON-RPC error codes used by MCP (basic/index.mdx "Error Codes").
    #
    # MCP partitions the JSON-RPC server-error range: -32000..-32019 is
    # implementation-defined (legacy, no meaning may be assumed beyond
    # -32002), and -32020..-32099 is reserved for codes defined by the MCP
    # specification itself.
    module Codes
      # Standard JSON-RPC 2.0 codes
      PARSE_ERROR = -32_700
      INVALID_REQUEST = -32_600
      METHOD_NOT_FOUND = -32_601
      INVALID_PARAMS = -32_602
      INTERNAL_ERROR = -32_603

      # MCP 2026-07-28 spec-defined codes (reserved sub-range)
      HEADER_MISMATCH = -32_020
      MISSING_REQUIRED_CLIENT_CAPABILITY = -32_021
      UNSUPPORTED_PROTOCOL_VERSION = -32_022

      # Resource not found in protocol versions 2025-11-25 and earlier;
      # replaced by INVALID_PARAMS but still accepted from older servers.
      LEGACY_RESOURCE_NOT_FOUND = -32_002

      # Codes that identify a modern (2026-07-28+) server. Receiving one of
      # these means the peer speaks a per-request-metadata revision, so a
      # dual-era client must retry or correct the request rather than fall
      # back to the initialize handshake (basic/versioning.mdx).
      MODERN_ERROR_CODES = [HEADER_MISMATCH, MISSING_REQUIRED_CLIENT_CAPABILITY,
                            UNSUPPORTED_PROTOCOL_VERSION].freeze

      # Codes a resources/read error may carry to mean "resource not found"
      # on a modern (2026-07-28+) server. Legacy servers only ever used
      # -32002; for them -32602 is plain Invalid params.
      RESOURCE_NOT_FOUND_CODES = [INVALID_PARAMS, LEGACY_RESOURCE_NOT_FOUND].freeze

      # @param code [Integer, nil] a JSON-RPC error code
      # @return [Boolean] whether it is a recognized 2026-07-28 protocol error
      def self.modern_error_code?(code)
        MODERN_ERROR_CODES.include?(code)
      end

      # Whether a resources/read error code means the resource does not
      # exist. 2026-07-28 servers say -32602 (and clients SHOULD still accept
      # the earlier -32002); a legacy session only ever meant not-found by
      # -32002, so its -32602 stays a generic Invalid params.
      # @param code [Integer, nil] a JSON-RPC error code from resources/read
      # @param modern [Boolean] whether the session is a modern protocol revision
      # @return [Boolean] whether it means the resource does not exist
      def self.resource_not_found_code?(code, modern: true)
        return true if code == LEGACY_RESOURCE_NOT_FOUND

        modern && code == INVALID_PARAMS
      end
    end

    # Raised when the MCP server returns an error response. Carries the
    # JSON-RPC error `code` and `data` so callers can distinguish protocol
    # errors (e.g. -32602 resource not found) without parsing the message.
    class ServerError < MCPError
      # @return [Integer, nil] the JSON-RPC error code, if the response carried one
      attr_reader :code
      # @return [Object, nil] the JSON-RPC error data member, if any
      attr_reader :data
      # @return [Integer, nil] the HTTP status the error arrived with, when it
      #   was carried in an HTTP error response body
      attr_accessor :http_status

      # @param message [String, nil] error message
      # @param code [Integer, nil] JSON-RPC error code
      # @param data [Object, nil] JSON-RPC error data
      def initialize(message = nil, code: nil, data: nil)
        super(message)
        @code = code
        @data = data
      end

      # Build the most specific error for a JSON-RPC error object: the typed
      # 2026-07-28 errors for the spec-reserved codes, a plain ServerError
      # otherwise. The message is peer-supplied and passed through as-is.
      #
      # A JSON-RPC 2.0 error object MUST carry a string `message`. One that
      # does not is malformed at the JSON-RPC level, so it never earns a
      # typed class — and so can never identify a modern server (see
      # ModernProtocolError) — even though its code and data are still
      # preserved on the plain ServerError for the caller to inspect.
      # @param error [Hash, nil] the JSON-RPC `error` member ('code', 'message', 'data')
      # @return [MCPClient::Errors::ServerError]
      def self.from_jsonrpc(error)
        error = {} unless error.is_a?(Hash)
        message = error['message'] || error[:message]
        code = error['code'] || error[:code]
        code = nil unless code.is_a?(Integer)
        data = error.key?('data') ? error['data'] : error[:data]

        klass = wire_message?(message) ? error_class_for(code) : ServerError
        klass.new(message || 'Unknown server error', code: code, data: data)
      end

      # @param message [Object] the error object's `message` member
      # @return [Boolean] whether it is the string JSON-RPC requires
      def self.wire_message?(message)
        # JSON-RPC 2.0 types `message` as a String and says nothing about its
        # length, so an empty one is well-formed. Nothing is discriminated by
        # rejecting it either: a legacy endpoint misusing a reserved code
        # would carry prose, not "".
        message.is_a?(String)
      end

      # @param code [Integer, nil] a JSON-RPC error code
      # @return [Class] the error class that code maps to
      def self.error_class_for(code)
        case code
        when Codes::METHOD_NOT_FOUND then MethodNotFoundError
        when Codes::HEADER_MISMATCH then HeaderMismatchError
        when Codes::MISSING_REQUIRED_CLIENT_CAPABILITY then MissingRequiredClientCapabilityError
        when Codes::UNSUPPORTED_PROTOCOL_VERSION then UnsupportedProtocolVersionError
        else ServerError
        end
      end
      private_class_method :wire_message?, :error_class_for

      # Whether this is one of the 2026-07-28 spec-defined protocol errors,
      # carrying the wire shape its schema mandates. Only such a well-formed
      # error identifies a modern server: a legacy endpoint or intermediary
      # that happens to emit a bare -3202x code must not suppress the
      # fallback. A plain ServerError never does — including the one
      # from_jsonrpc builds for an error object with no string `message`.
      # @return [Boolean]
      def modern_protocol_error?
        false
      end

      # Whether the error identifies a modern server *on a Streamable HTTP
      # POST*. Beyond the transport-agnostic reserved codes, Streamable HTTP
      # backward compatibility names one more recognized modern error: an
      # unknown method answered with HTTP 404 and a JSON-RPC -32601 body.
      # That pairing is why this predicate is separate rather than a wider
      # code list — on stdio a bare -32601 is exactly what a legacy peer
      # answers a modern probe with, so folding it into #modern_protocol_error?
      # would suppress the initialize fallback that must happen there.
      #
      # The JSON-RPC 2.0 envelope is already required upstream: only
      # #jsonrpc_error_from_http_response sets http_status, and it assigns a
      # code solely from a body that carried `"jsonrpc": "2.0"` and an error
      # object. An error that never arrived over HTTP has no status and is
      # therefore never recognized here. The 404 rule itself lives on
      # MethodNotFoundError, which from_jsonrpc assigns only to a -32601 whose
      # error object is well-formed (a string `message`): a 404 page dressed
      # up as `{"error": {"code": -32601}}` is malformed at the JSON-RPC
      # level and identifies nobody, exactly like a bare -3202x.
      # @return [Boolean]
      def modern_http_protocol_error?
        modern_protocol_error?
      end

      # Whether the error is protocol-level (a modern spec error or an
      # invalid result) rather than an application-level failure. Public
      # transport methods let these propagate instead of wrapping them.
      # A 404 + -32601 is deliberately NOT one: it says the peer is modern,
      # but "method not found" is an ordinary application failure that the
      # calling wrapper should keep describing in its own terms.
      # @return [Boolean]
      def protocol_error?
        modern_protocol_error?
      end

      # Subclasses with a mandated data shape override this.
      # @return [Boolean]
      def well_formed?
        true
      end

      # Whether a server/discover probe answered with this error identifies a
      # modern server (a recognized modern error, or a malformed modern
      # result). Non-error transport failures never do.
      # @return [Boolean]
      def modern_protocol_error_for_probe?
        modern_protocol_error?
      end

      private

      # A member of the error's `data` object, accepting both key spellings:
      # JSON.parse yields String keys, but a host's response middleware may
      # symbolize them before the body reaches us.
      # @param name [String] the member name
      # @return [Object, nil] the member's value, or nil when data has none
      def data_member(name)
        return nil unless data.is_a?(Hash)

        data.key?(name) ? data[name] : data[name.to_sym]
      end
    end

    # Recognition shared by the three 2026-07-28 spec-defined errors. Only
    # ServerError.from_jsonrpc assigns these classes, and only to an error
    # object that is well-formed at the JSON-RPC level (it carries a string
    # `message`); #well_formed? adds the per-code data requirements from the
    # spec's schema.
    module ModernProtocolError
      # @return [Boolean] whether the error identifies a modern (2026-07-28+) server
      def modern_protocol_error?
        Codes.modern_error_code?(code) && well_formed?
      end
    end

    # -32601 Method not found. A class of its own so that the Streamable HTTP
    # backward-compatibility rule ("HTTP 404 with a JSON-RPC -32601 body is
    # a modern server") can require a well-formed JSON-RPC error object the
    # same way the reserved -3202x codes do: from_jsonrpc assigns this class
    # only when the error carries a string `message`.
    class MethodNotFoundError < ServerError
      # @return [Boolean] whether this arrived as an HTTP 404, the pairing
      #   Streamable HTTP names as a modern-server signal
      def modern_http_protocol_error?
        http_status == 404
      end
    end

    # -32020 HeaderMismatch (MCP 2026-07-28, Streamable HTTP): the HTTP
    # headers mirrored from the request body (Mcp-Method, Mcp-Name,
    # Mcp-Param-*, MCP-Protocol-Version) are missing, malformed, or do not
    # match the body. Its schema mandates no data.
    class HeaderMismatchError < ServerError
      include ModernProtocolError
    end

    # -32021 MissingRequiredClientCapability (MCP 2026-07-28): processing the
    # request needs a capability the client did not declare in its
    # per-request clientCapabilities.
    class MissingRequiredClientCapabilityError < ServerError
      include ModernProtocolError

      # @return [Hash] the capabilities the server requires (data.requiredCapabilities)
      def required_capabilities
        caps = data_member('requiredCapabilities')
        caps.is_a?(Hash) ? caps : {}
      end

      # The schema types this error's data as `requiredCapabilities:
      # ClientCapabilities` — an open object whose KNOWN members are typed:
      # `elicitation` and `sampling` are objects holding objects under the
      # names the schema gives them (form/url, context/tools) and nothing is
      # said about their other members; `experimental` and `extensions` map
      # names to objects; `roots` is an object with no typed member at all;
      # and a capability the schema does not name may be anything. A body
      # that breaks any of THAT is not ClientCapabilities, and must not claim
      # the signal that separates a well-formed modern rejection from a legacy
      # peer or an intermediary emitting a bare -32021 — but reading more
      # into the schema than it says turns schema-valid rejections into
      # "legacy" ones and strips their typed interface on the way to the
      # caller, so exactly the schema's constraints are checked, no more.
      # @return [Boolean] whether data.requiredCapabilities is ClientCapabilities-shaped
      def well_formed?
        caps = data_member('requiredCapabilities')
        caps.is_a?(Hash) && caps.all? { |name, value| capability_well_formed?(name, value) }
      end

      # Capabilities whose named members the schema types as objects.
      TYPED_CAPABILITY_MEMBERS = { 'elicitation' => %w[form url], 'sampling' => %w[context tools] }.freeze

      # Capabilities the schema types as maps from name to object.
      OBJECT_MAP_CAPABILITIES = %w[experimental extensions].freeze

      # Capabilities the schema types as objects with no typed member.
      OPEN_OBJECT_CAPABILITIES = %w[roots].freeze

      private

      # @param name [String, Symbol] the capability name
      # @param value [Object] its declared value
      # @return [Boolean] whether the value has the shape the schema gives that capability
      def capability_well_formed?(name, value)
        key = name.to_s
        members = TYPED_CAPABILITY_MEMBERS[key]
        return true unless members || OBJECT_MAP_CAPABILITIES.include?(key) || OPEN_OBJECT_CAPABILITIES.include?(key)
        return false unless value.is_a?(Hash)
        return value.each_value.all?(Hash) if OBJECT_MAP_CAPABILITIES.include?(key)

        (members || []).all? { |member| typed_member_ok?(value, member) }
      end

      # @param value [Hash] a capability object
      # @param member [String] a member the schema types as an object
      # @return [Boolean] whether the member, when present, is an object
      def typed_member_ok?(value, member)
        return true unless value.key?(member) || value.key?(member.to_sym)

        (value.key?(member) ? value[member] : value[member.to_sym]).is_a?(Hash)
      end
    end

    # -32022 UnsupportedProtocolVersion (MCP 2026-07-28): the server does not
    # implement the protocol version the request declared. `supported` lists
    # the versions it does implement so the client can retry with one.
    class UnsupportedProtocolVersionError < ServerError
      include ModernProtocolError

      # @return [Array<String>] protocol versions the server supports (data.supported)
      def supported
        list = data_member('supported')
        list.is_a?(Array) ? list.grep(String) : []
      end

      # The versions the server named, phrased for a message about the rejection.
      # @return [String] " (server supports: ...)" or "" when it named none
      def supported_suffix
        supported.empty? ? '' : " (server supports: #{supported.join(', ')})"
      end

      # @return [String, nil] the protocol version the request asked for (data.requested)
      def requested
        data_member('requested')
      end

      # The schema types this error's data as `supported: string[]` and
      # `requested: string`. Both members, with those types, are what a
      # modern server's rejection carries and what a legacy endpoint emitting
      # a bare -32022 does not — so they are the whole test. Their length is
      # not: an empty `supported` means the server named no version this
      # client can retry with, which is a failed negotiation with a modern
      # server, not evidence of a legacy one.
      # @return [Boolean] whether data carries the shape the schema requires
      def well_formed?
        list = data_member('supported')
        return false unless list.is_a?(Array) && list.all?(String)

        requested.is_a?(String)
      end
    end

    # Raised when a request returns an InputRequiredResult (resultType
    # "input_required", MCP 2026-07-28 multi round-trip requests) that this
    # client cannot fulfil — for example because it declared no capability
    # the server could have asked for. Exposes the server's input requests
    # and opaque request state so a host can drive the round trip itself.
    class InputRequiredError < ServerError
      # @return [Hash] the InputRequests map (key => request object)
      def input_requests
        requests = data.is_a?(Hash) ? (data['inputRequests'] || data[:inputRequests]) : nil
        requests.is_a?(Hash) ? requests : {}
      end

      # @return [String, nil] the opaque requestState to echo on a retry
      def request_state
        data.is_a?(Hash) ? (data['requestState'] || data[:requestState]) : nil
      end

      # @return [Boolean] always true: a protocol-level condition, never wrapped
      def protocol_error?
        true
      end
    end

    # Raised when a server result is malformed at the protocol level — e.g.
    # its `resultType` is a value this client does not recognize, which MCP
    # 2026-07-28 says MUST be considered invalid. A ServerError (not a
    # TransportError) so it is never retried: the server processed the
    # request and answered; re-sending would not produce a different shape.
    class InvalidResultError < ServerError
      # @return [Boolean] always true: an invalid result is a protocol-level failure
      def protocol_error?
        true
      end
    end

    # Raised for a server-side failure that is plausibly transient and safe to
    # retry — chiefly HTTP 5xx responses, where the request likely did not
    # complete at the application layer. It is a subclass of ServerError so that
    # existing `rescue MCPClient::Errors::ServerError` handlers keep catching it,
    # while the retry logic can single it out. Application-level failures
    # (JSON-RPC error responses, HTTP 4xx) use plain ServerError and are NOT
    # retried, since the server already processed/rejected the request.
    class TransientServerError < ServerError
      # @return [Boolean] a 5xx means the request did not complete: it
      #   identifies neither a modern nor a legacy server
      def era_inconclusive?
        true
      end
    end

    # Raised when there's an error in the MCP server transport
    class TransportError < MCPError
      # @return [Boolean] a transport failure never identifies a modern server
      def modern_protocol_error_for_probe?
        false
      end
    end

    # Raised when a request exceeded its timeout without receiving a
    # response. A subclass of TransportError so existing rescues keep
    # working, but deliberately excluded from automatic retries: the
    # request may still be executing server-side, so a blind re-send could
    # run a non-idempotent operation twice (MCP lifecycle: on timeout the
    # sender SHOULD cancel and stop waiting, not re-send).
    class RequestTimeoutError < TransportError
      # @return [Boolean] no answer arrived at all, so no era was learned
      def era_inconclusive?
        true
      end
    end

    # Raised on the modern (2026-07-28) Streamable HTTP transport when an SSE
    # response stream ends before delivering the JSON-RPC response. There is
    # no resumption: "a broken response stream loses the in-flight request;
    # clients MUST re-issue it as a new request with a new request ID". The
    # transport makes that one replacement request itself — for every method,
    # tools/call included, since the broken stream is also the cancellation
    # signal the server MUST act on — and raises this when it too is lost.
    class ResponseStreamClosedError < TransportError
      # @return [Boolean] the response was lost in transit, so the exchange
      #   revealed nothing about the server's protocol era
      def era_inconclusive?
        true
      end
    end

    # Raised when a response body exceeded the configured size limit (e.g. a
    # gzip payload that expands past the decompression ceiling). A subclass of
    # TransportError so existing rescues keep working, but deliberately
    # excluded from automatic retries: the server already received and
    # processed the request, so re-sending it could run a non-idempotent
    # operation again — and would decompress the oversized body each time.
    class ResponseTooLargeError < TransportError
      # @return [Boolean] the body was never decoded, so it was never read as
      #   a modern or a legacy answer
      def era_inconclusive?
        true
      end
    end

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
