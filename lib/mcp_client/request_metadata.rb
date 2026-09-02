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

    # The evaluation of the host's `request_meta` that one operation reserves
    # for the request it leads to: the JSON-RPC method of that request, the
    # evaluation once it has been made, whether the operation has begun
    # talking to the server, and whether the request it was held for has
    # already spent it.
    #
    # A reservation is claimed by that one request and by nothing else.
    # Everything else a transport sends while it is open -- a reconnect's
    # handshake, the `subscriptions/listen` a reconnect re-opens, the
    # `notifications/cancelled` for an abandoned request, a nested request a
    # notification listener issues -- reads the host afresh and leaves the
    # reservation for the request that holds it.
    HeldRequestMeta = Struct.new(:request_method, :evaluated, :value, :dispatched, :spent)

    # Reserve the evaluation of the host's `request_meta` for the request
    # `method` this operation leads to, for the operation's dynamic extent
    # and no longer: however it ends -- a value returned, a reconnect that
    # raised, a caller that swallowed the error -- the reservation goes with
    # it, so no later request on this thread can carry it.
    # @param method [String] the JSON-RPC method of the request the operation sends
    # @yield the operation
    # @return [Object] the block's value
    def holding_request_meta(method)
      open_request_meta_hold(method)
      begin
        yield
      ensure
        close_request_meta_hold
      end
    end

    # Open a hold scope without a block, for a caller whose operation spans
    # several transports (a client listing across its servers). Every opener
    # closes it from an `ensure`.
    # @param method [String] the JSON-RPC method of the request the operation sends
    # @return [void]
    def open_request_meta_hold(method)
      stack = (Thread.current[held_request_meta_key] ||= [])
      top = stack.last
      # The same operation continuing -- a client asking its transport to run
      # the very list it just weighed -- shares the reservation, so the
      # request goes out with the evaluation the decision was made on. An
      # operation that begins once this one is already talking to the server
      # is a nested one (a listener called from a response's notification
      # dispatch): it reserves its own and leaves this one untouched.
      shared = top && top.request_method == method && !top.dispatched && !top.spent
      stack.push(shared ? top : HeldRequestMeta.new(method, false, nil, false, false))
      nil
    end

    # Close the innermost hold scope.
    # @return [void]
    def close_request_meta_hold
      stack = Thread.current[held_request_meta_key]
      return nil unless stack.is_a?(Array)

      stack.pop
      Thread.current[held_request_meta_key] = nil if stack.empty?
      nil
    end

    # @return [MCPClient::RequestMetadata::HeldRequestMeta, nil] the
    #   reservation of the innermost operation open on this thread
    def held_request_meta
      stack = Thread.current[held_request_meta_key]
      stack.last if stack.is_a?(Array)
    end

    # @return [MCPClient::RequestMetadata::HeldRequestMeta, nil] that
    #   reservation while the request it was made for may still claim it
    def claimable_request_meta_hold
      held = held_request_meta
      held unless held.nil? || held.spent
    end

    # Note that the operation holding a reservation has begun talking to the
    # server, so an operation that begins from here on is a nested one.
    # @return [void]
    def mark_request_meta_dispatched
      held = held_request_meta
      held.dispatched = true if held
      nil
    end

    # @return [String] the fingerprint of the effective parameters the next
    #   request on this transport would carry. Reading it evaluates the
    #   host's request_meta, and the open operation holds that evaluation for
    #   the request the decision leads to instead of spending it on the
    #   decision alone. Outside any operation nothing is held at all: an
    #   evaluation that no request is waiting for is never kept.
    def current_params_fingerprint
      params_fingerprint_of(with_request_meta({}, claim: :model))
    end

    # Drop a held evaluation of the host's request_meta: the decision that
    # took it leads to no request of its own, so the next one evaluates
    # afresh rather than sending metadata read some time ago. The scope drops
    # it too when the operation ends; this is for a decision that settles
    # before that.
    # @return [void]
    def release_held_request_meta
      held = held_request_meta
      return nil unless held

      held.evaluated = false
      held.value = nil
      nil
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
