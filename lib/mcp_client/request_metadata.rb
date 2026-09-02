# frozen_string_literal: true

require 'digest'
require 'json'

module MCPClient
  # The metadata a request carries and the fingerprint a cached result is
  # bound to (MCP 2026-07-28 basic/index "_meta", server/utilities/caching):
  # the reserved protocol keys, the effective parameters of the request this
  # thread last built, and the evaluation of the host's `request_meta` that a
  # cache decision holds for the request it leads to.
  #
  # Each slot is named after the transport's `object_id`, so a worker thread
  # that builds and discards transports keeps nothing of theirs for its life.
  module RequestMetadata
    # `_meta` keys that identify one request rather than what it asks for
    # (the progress token and the W3C trace identifiers): a cached result
    # does not depend on them. `baggage` is deliberately not among them --
    # it carries application-defined context (a tenant, a locale), which a
    # server may well vary its result by, so a result cached under one
    # baggage is never served under another.
    CACHE_NEUTRAL_META_KEYS = %w[progressToken traceparent tracestate].freeze

    # Remember the effective parameters a request goes out with, so a result
    # cached from it is bound to them (MCP 2026-07-28 caching: a server may
    # vary a result by host metadata such as a vendor tenant key).
    # @param params [Hash, nil] the effective (wire) parameters
    # @return [void]
    def note_request_params(params)
      Thread.current[request_params_key] = params_fingerprint_of(params)
    end

    # @return [String, nil] the fingerprint of the effective parameters of
    #   the request this thread last built
    def request_params_fingerprint
      Thread.current[request_params_key]
    end

    # Marks an attempt that has not built its request yet: the parameters
    # of the previous request on this thread say nothing about it.
    UNRECORDED_PARAMS = :unrecorded

    # @return [void]
    def note_request_params_pending
      Thread.current[request_params_key] = UNRECORDED_PARAMS
    end

    # Marks metadata that is to be held once it is evaluated: the request a
    # cache decision leads to carries the very parameters the decision was
    # made on, and a host callable that vends a one-time value (a nonce) or
    # rotates is read once for the two of them.
    HELD_REQUEST_META_PENDING = :pending

    # @return [String] the fingerprint of the effective parameters the next
    #   request on this transport would carry. Reading it evaluates the
    #   host's request_meta, so the evaluation is held for the request this
    #   decision leads to instead of being spent on the decision alone.
    def current_params_fingerprint
      Thread.current[held_request_meta_key] ||= HELD_REQUEST_META_PENDING
      params_fingerprint_of(with_request_meta({}))
    end

    # Drop a held evaluation of the host's request_meta: the decision that
    # took it leads to no request of its own, so the next one evaluates
    # afresh rather than sending metadata read some time ago.
    # @return [void]
    def release_held_request_meta
      Thread.current[held_request_meta_key] = nil
    end

    # Build a message outside any held evaluation: it reads the host's
    # request_meta afresh (a callable that vends a one-time value is not
    # spent twice), and the evaluation held for another request is left
    # untouched — still held, and still for that request.
    # @yield builds the message's effective parameters
    # @return [Object] the block's value
    def without_held_request_meta
      held = Thread.current[held_request_meta_key]
      Thread.current[held_request_meta_key] = nil
      yield
    ensure
      Thread.current[held_request_meta_key] = held
    end

    # @return [Symbol] this transport's thread-local key for held metadata
    def held_request_meta_key
      :"mcp_client_held_request_meta_#{object_id}"
    end

    # A stable fingerprint of the metadata that shapes a result: the
    # effective `_meta` without the protocol version, the log level and the
    # per-request identifiers. The client identity and capabilities stay
    # in: a server may vary a result by who asks and by the extensions and
    # features a request advertises, and those change when the host sets
    # client_info, drops it, declares an extension or registers a handler.
    # @param params [Hash, nil] effective parameters
    # @return [String]
    def params_fingerprint_of(params)
      meta = params.is_a?(Hash) ? (params['_meta'] || params[:_meta]) : nil
      meta = meta.is_a?(Hash) ? meta.transform_keys(&:to_s) : {}
      meta = meta.except(META_PROTOCOL_VERSION, META_LOG_LEVEL, *CACHE_NEUTRAL_META_KEYS)
      Digest::SHA256.hexdigest(JSON.generate(deep_sort_keys(meta)))
    end

    # @return [Symbol] this transport's thread-local key for the request parameters
    def request_params_key
      :"mcp_client_request_params_#{object_id}"
    end

    # @param value [Object]
    # @return [Object] the value with every nested Hash sorted by key
    def deep_sort_keys(value)
      case value
      when Hash then value.map { |k, v| [k.to_s, deep_sort_keys(v)] }.sort_by(&:first).to_h
      when Array then value.map { |v| deep_sort_keys(v) }
      else value
      end
    end

    # Reserved `_meta` keys (MCP 2026-07-28 basic/index "_meta").
    META_PROTOCOL_VERSION = 'io.modelcontextprotocol/protocolVersion'
    META_CLIENT_INFO = 'io.modelcontextprotocol/clientInfo'
    META_CLIENT_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities'
    META_LOG_LEVEL = 'io.modelcontextprotocol/logLevel'
    META_SERVER_INFO = 'io.modelcontextprotocol/serverInfo'
    META_SUBSCRIPTION_ID = 'io.modelcontextprotocol/subscriptionId'

    # Per-request protocol fields the client owns. A host-supplied `_meta`
    # may carry anything else (progressToken, trace context, vendor keys),
    # but these are always set from the transport's own state so the body
    # can never disagree with what the transport negotiated (on HTTP the
    # MCP-Protocol-Version header must match the body).
    PROTECTED_META_KEYS = [META_PROTOCOL_VERSION, META_CLIENT_INFO, META_CLIENT_CAPABILITIES].freeze
  end
end
