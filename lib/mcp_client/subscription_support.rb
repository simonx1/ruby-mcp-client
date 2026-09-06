# frozen_string_literal: true

require_relative 'subscription'

module MCPClient
  # subscriptions/listen support shared by every transport (MCP 2026-07-28
  # basic/patterns/subscriptions): opening subscriptions, the registry keyed
  # by listen request id, routing of tagged notifications, acknowledgment,
  # graceful and abrupt closure, and the resources/subscribe mapping.
  # Transports provide ensure_session_ready, open_subscription and
  # cancel_subscription.
  module SubscriptionSupport
    # Seconds to wait for a resource subscription acknowledgment on a
    # transport without its own read timeout.
    DEFAULT_ACK_TIMEOUT = 30

    # Open a long-lived notification stream. Modern servers only: the legacy
    # transports keep resources/subscribe and the HTTP GET stream.
    #
    # The request itself is meant to outlive every other one this client
    # sends — its response is the server's *closing* of the stream — so the
    # deadline the lifecycle asks for ("implementations SHOULD establish
    # timeouts for all sent requests", basic/patterns/cancellation "Timeouts")
    # is on the acknowledgment rather than on the response: a server MUST
    # acknowledge a listen before it sends anything on it, so a listen that
    # has not been acknowledged is a request nothing is happening on. One that
    # expires is cancelled the way that section requires, and the handle is
    # closed carrying the timeout, instead of staying `:pending` for the life
    # of the process with nothing to tell the host why.
    # @param notifications [Hash] the SubscriptionFilter
    # @param ack_timeout [Numeric, false, nil] seconds to wait for the
    #   acknowledgment; nil takes the transport's own ({#subscription_ack_timeout},
    #   i.e. its read timeout), false waits for ever
    # @yield [method, params] notifications delivered on the subscription
    # @return [MCPClient::Subscription]
    # @raise [MCPClient::Errors::CapabilityError] on a legacy session
    def listen(notifications:, ack_timeout: nil, &listener)
      filter = MCPClient::Subscription.normalize_filter(notifications)
      ensure_modern_listen!
      open_listen(filter, ack_timeout: ack_timeout, &listener)
    end

    # @return [void]
    # @raise [MCPClient::Errors::CapabilityError] on a legacy session
    def ensure_modern_listen!
      # A transport with no listen stream of its own (the deprecated SSE
      # transport, a host adapter written against the older interface) cannot
      # serve one however the session was negotiated.
      unless respond_to?(:open_subscription, true)
        raise MCPClient::Errors::CapabilityError,
              "#{self.class.name} does not support subscriptions/listen (an MCP 2026-07-28 stdio or " \
              'Streamable HTTP transport is required)'
      end

      ensure_session_ready
      return if modern?

      raise MCPClient::Errors::CapabilityError,
            'subscriptions/listen requires an MCP 2026-07-28 server; this server negotiated ' \
            "#{protocol_version || 'no version'} (use resources/subscribe and server notifications instead)"
    end

    # Open a listen stream for a normalized filter.
    #
    # The deadline on the *first* request and the deadline on the requests a
    # reconnect or a restart re-issues are two settings, because one caller
    # wants them apart: `subscribe_resource` waits for the first
    # acknowledgment itself and reports its absence as its own failure, so
    # it wants no watchdog racing that wait — but the re-issued requests are
    # ones nobody is waiting on, and those it wants bounded like any other
    # (see {#open_resource_subscription}).
    # @param filter [Hash] the normalized SubscriptionFilter
    # @param ack_timeout [Numeric, false, nil] see {#listen}; kept on the
    #   handle for every re-issued request
    # @param initial_deadline [Boolean] whether to arm the deadline on the
    #   first request too
    # @yield [method, params] notifications delivered on the subscription
    # @return [MCPClient::Subscription]
    def open_listen(filter, ack_timeout:, initial_deadline: true, &listener)
      subscription = MCPClient::Subscription.new(server: self, requested: filter, ack_timeout: ack_timeout, &listener)
      open_subscription(subscription)
      await_acknowledgment_deadline(subscription, ack_timeout) if initial_deadline
      subscription
    end

    # Put the same deadline on a listen request a transport has just
    # re-issued: an HTTP stream re-opened after a drop, or a stdio
    # subscription re-sent to the process that replaced the one it was on.
    #
    # Each of those is a new JSON-RPC request, for which the server holds no
    # subscription state and which it has to acknowledge afresh, so the
    # "implementations SHOULD establish timeouts for all sent requests"
    # (basic/patterns/cancellation "Timeouts") that bounded the first bounds it
    # too. It used to bound only the first: the watchdog `listen` started
    # retires at the first acknowledgment, and a replacement the server
    # accepted and then never acknowledged left the handle `:pending` with
    # nothing to tell the host why — indefinitely on stdio, and for as long as
    # the peer kept sending SSE comments on Streamable HTTP.
    #
    # Watchdogs do not pile up behind a stream that keeps dropping: each one
    # is bound to the request it was armed for, and retires as soon as the
    # subscription has moved on to a newer one.
    # @param subscription [MCPClient::Subscription]
    # @return [Thread, nil] the watchdog, for tests; nil when there is none
    def rearm_acknowledgment_deadline(subscription)
      await_acknowledgment_deadline(subscription, subscription.ack_timeout)
    end

    # Arrange for an unacknowledged listen to be given up on.
    #
    # Started only once the request is on its way, so nothing is cancelled
    # before it exists; it waits on the subscription's own settling signal, so
    # an acknowledgment (or any other end) retires it at once rather than
    # leaving a thread asleep for the whole deadline. Every re-issued request
    # gets one too ({#rearm_acknowledgment_deadline}).
    #
    # The deadline is the *request's*, not the handle's: the id it is set on
    # is taken here, and only that request is expired by it
    # ({MCPClient::Subscription#expire_unanswered}). Waiting on the mutable
    # handle instead expired whatever request it was on by the time the wait
    # returned — a first request's timer closed the replacement a restart had
    # issued since, naming the replacement and a deadline it had not missed.
    # @param subscription [MCPClient::Subscription]
    # @param ack_timeout [Numeric, false, nil] see {#listen}
    # @return [Thread, nil] the watchdog, for tests; nil when there is none
    def await_acknowledgment_deadline(subscription, ack_timeout)
      timeout = ack_timeout.nil? ? subscription_ack_timeout : ack_timeout
      return nil unless timeout.is_a?(Numeric) && timeout.positive?

      request_id = subscription.id
      Thread.new do
        Thread.current.name = 'MCP-listen-ack'
        Thread.current.report_on_exception = false
        next if subscription.wait_until_settled(timeout)

        expire_unacknowledged_subscription(subscription, request_id, timeout)
      end
    end

    # End a listen the server never acknowledged, and tell the server so —
    # unless the subscription has moved on from that request, or the server
    # answered it in the instant between the wait and this: the verdict and
    # the closure are one step on the subscription, and whoever is waiting
    # for the handle to settle is woken once the server has been told.
    # @param subscription [MCPClient::Subscription]
    # @param request_id [Integer, String] the listen id the deadline was set on
    # @param timeout [Numeric] the deadline it missed
    # @return [void]
    def expire_unacknowledged_subscription(subscription, request_id, timeout)
      error = MCPClient::Errors::RequestTimeoutError.new(
        "subscriptions/listen #{request_id} was not acknowledged within #{timeout}s"
      )
      subscription.expire_unanswered(request_id, error) do
        @logger.warn("subscriptions/listen #{request_id} was not acknowledged within #{timeout}s; cancelling it")
        # The handle is already closed, so this is the cancellation alone: the
        # notifications/cancelled on stdio, the closed response stream on HTTP.
        cancel_subscription(subscription)
      rescue StandardError => e
        @logger.debug("Cancelling an unacknowledged subscription raised #{e.class}: #{e.message}")
      end
    end

    # The subscriptions this transport has opened, keyed by the String form
    # of their listen request id.
    # Keyed by the JSON-RPC id the listen went out with, exactly as it was
    # sent. A JSON-RPC id of another type is another request's id — the
    # cancellation path has always compared them exactly, and the
    # acknowledgment and delivery paths do too — so a peer that tags a
    # message with "9" does not reach the subscription listening on 9.
    # @return [Hash{Integer, String => MCPClient::Subscription}]
    def subscriptions
      @subscriptions ||= {}
    end

    # @return [Mutex] guards the subscription registry
    def subscriptions_mutex
      @subscriptions_mutex ||= Mutex.new
    end

    # @param id [Integer, String, nil] a JSON-RPC id
    # @return [MCPClient::Subscription, nil]
    def subscription_by_id(id)
      return nil if id.nil?

      subscriptions_mutex.synchronize { subscriptions[id] }
    end

    # @param subscription [MCPClient::Subscription]
    # @return [void]
    def register_subscription(subscription)
      subscriptions_mutex.synchronize { subscriptions[subscription.id] = subscription }
    end

    # @param subscription [MCPClient::Subscription]
    # @return [void]
    def unregister_subscription(subscription)
      subscriptions_mutex.synchronize { subscriptions.delete(subscription.id) }
    end

    # Drop the registration a particular listen id made, and only that one: a
    # subscription re-opened under a newer id (by a reconnect, or by a stdio
    # restart racing a blocked write) is registered under that newer id, and
    # the older attempt must not delete it.
    # @param subscription [MCPClient::Subscription]
    # @param id [Integer, String] the listen id it was registered under
    # @return [void]
    def unregister_subscription_id(subscription, id)
      subscriptions_mutex.synchronize do
        subscriptions.delete(id) if subscriptions[id].equal?(subscription)
      end
    end

    # The subscription a notification belongs to, from its
    # io.modelcontextprotocol/subscriptionId.
    # @param params [Hash, nil] notification params
    # @return [MCPClient::Subscription, nil]
    def subscription_for_notification(params)
      meta = params.is_a?(Hash) ? params['_meta'] : nil
      return nil unless meta.is_a?(Hash) && meta.key?(MCPClient::JsonRpcCommon::META_SUBSCRIPTION_ID)

      subscription_by_id(meta[MCPClient::JsonRpcCommon::META_SUBSCRIPTION_ID])
    end

    # Notifications that are subscription bookkeeping rather than something a
    # subscription's listeners are watching for.
    CONTROL_NOTIFICATIONS = %w[notifications/subscriptions/acknowledged notifications/cancelled].freeze

    # Route an incoming notification, in this order:
    # subscription bookkeeping (acknowledgment, server-side teardown), then
    # transport and host cache invalidation, then the delivery to the owning
    # subscription's listeners, and last the host's `on_notification` callback
    # (so hosts still see subscription-delivered notifications exactly like
    # request-scoped ones).
    #
    # The invalidations come first on purpose, the transport's and the host's
    # alike. A listener runs on the subscription's own dispatcher thread, so
    # queuing its delivery makes the notification visible at once — and a
    # listener that reacts to a list_changed notification by calling a cached
    # list method (`client.list_tools`, say) would then read the very entry the
    # notification says is stale. Dropping the caches before the delivery is
    # queued makes "the caches are already invalid when a listener sees the
    # notification" a guarantee instead of a race the scheduler usually wins.
    # That is why the host's invalidation has a hook of its own
    # ({MCPClient::ServerBase#on_cache_invalidation}) rather than riding on the
    # host callback below: while it did, the guarantee held only for the
    # transport's own caches and the host's were dropped after the delivery.
    #
    # The host callback comes last, because it is the only step that can
    # block. It is host code driven by the peer and it runs on whatever thread
    # is routing — on stdio the process's sole stdout reader — so a callback
    # that issues a synchronous request of its own waits there for a response
    # only that reader can deliver. Round 3 moved the subscription's listeners
    # off that thread for exactly this reason; running the callback ahead of
    # them put the queueing back behind it, and a host handler that blocked
    # stalled a delivery the dispatcher would otherwise have made at once.
    # Queueing costs nothing to move: {#deliver_subscription_notification}
    # hands the notification to the dispatcher rather than to the listeners,
    # so nothing host-supplied runs before the callback either way.
    #
    # Being last, the callback can prevent nothing. An exception escaping it
    # used to take the notification down with it — the subscription's
    # listeners never saw something the host's own handler had already been
    # told about — and, on stdio, the transport's reader thread with it; it is
    # now logged and routing is over anyway. Nor can it drop or redirect a
    # delivery by editing the payload it is handed: that is the very hash the
    # delivery was routed by, and by the time the callback can touch it the
    # subscription has already been resolved *and* the entry queued, so
    # deleting or rewriting `_meta` changes nothing about where it went.
    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def route_notification(method, params)
      handle_subscription_control(method, params)
      invalidate_cache_for_notification(method) if respond_to?(:invalidate_cache_for_notification, true)
      # The host's caches go with the transport's, on their own hook rather
      # than on the host callback below: that callback is deliberately last —
      # it is the step that may block — and a client whose invalidation rode on
      # it dropped its entries only after the delivery had been queued, so a
      # listener could read the very list the notification says is stale. Only
      # the invalidation is moved ahead; everything else the host does with a
      # notification is still behind the delivery.
      notify_cache_invalidation(method, params)
      deliver_subscription_notification(subscription_delivery_target(method, params), method, params)
      notify_host(method, params)
    end

    # Hand a notification to the host's callback, surviving whatever it does
    # with it (see {#route_notification}).
    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def notify_host(method, params)
      @notification_callback&.call(method, params)
    rescue StandardError => e
      @logger.warn("Notification callback error for #{sanitize_log_text(method)}: #{sanitize_log_text(e.message)}")
    end

    # Subscription bookkeeping carried by a notification: the server's
    # acknowledgment of a listen request, and its teardown of one.
    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def handle_subscription_control(method, params)
      case method
      when 'notifications/subscriptions/acknowledged'
        handle_subscription_acknowledgment(params)
      when 'notifications/cancelled'
        # Servers MUST send notifications/cancelled only to tear down a
        # subscriptions/listen stream (basic/patterns/cancellation).
        handle_server_cancellation(params)
      end
    end

    # Record what the server agreed to honour, and recheck the resource
    # subscriptions this stream carries against it.
    # @param params [Hash, nil] notification params
    # @return [void]
    def handle_subscription_acknowledgment(params)
      subscription = subscription_for_notification(params)
      return @logger.debug('Acknowledgment for an unknown subscription ignored') unless subscription

      subscription.acknowledge(params['notifications'])
      report_declined_subscription_types(subscription)
      drop_unacknowledged_resource_subscriptions(subscription)
    end

    # "The client SHOULD check the acknowledged filter against what it
    # requested and handle any unsupported types gracefully"
    # (basic/patterns/subscriptions). Gracefully, for the notification types
    # of a plain `listen`, is: the stream stays up for what was granted,
    # {MCPClient::Subscription#unsupported} names the rest, and the host is
    # told — a host that opted in to prompt-list changes and was granted
    # tool-list changes alone would otherwise keep waiting for notifications
    # that are never coming, with the handle `:active` and nothing said. The
    # resource URIs are held to more than a log line
    # ({#drop_unacknowledged_resource_subscriptions}): a watch the server
    # declined is one nothing is watching.
    # @param subscription [MCPClient::Subscription] the acknowledged stream
    # @return [void]
    def report_declined_subscription_types(subscription)
      declined = subscription.unsupported
      return if declined.empty?

      @logger.warn("Server acknowledged subscription #{subscription.id} without #{declined.join(', ')}; " \
                   'no notifications of those types will arrive on it')
    end

    # @param params [Hash, nil] notification params
    # @return [void]
    def handle_server_cancellation(params)
      return unless params.is_a?(Hash)

      # "Malformed notifications MAY be ignored": a reason that is not a
      # string is one, and so is a request id of another type than the one
      # this client issued — the registry is keyed by the id's text, so the
      # type is checked on the subscription found (basic/patterns/cancellation
      # "Error handling"). Neither may end a stream the server still serves.
      reason = params['reason']
      return unless reason.nil? || reason.is_a?(String)

      subscription = subscription_by_id(params['requestId'])
      return unless subscription && subscription.id == params['requestId']

      @logger.info("Server cancelled subscription #{subscription.id}: " \
                   "#{sanitize_log_text(reason || 'no reason given')}")
      unregister_subscription(subscription)
      subscription.finish(gracefully: false, reason: reason)
    end

    # The subscription a notification is delivered to, resolved from the
    # payload before the host's callback is given the chance to edit it (see
    # {#route_notification}).
    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [MCPClient::Subscription, nil]
    def subscription_delivery_target(method, params)
      return nil if CONTROL_NOTIFICATIONS.include?(method)

      meta = params.is_a?(Hash) ? params['_meta'] : nil
      return nil unless meta.is_a?(Hash) && meta.key?(MCPClient::JsonRpcCommon::META_SUBSCRIPTION_ID)

      subscription = subscription_by_id(meta[MCPClient::JsonRpcCommon::META_SUBSCRIPTION_ID])
      @logger.debug("Notification #{sanitize_log_text(method)} for an unknown subscription ignored") unless subscription
      subscription
    end

    # @param subscription [MCPClient::Subscription, nil] the stream it belongs
    #   to, resolved from the payload the peer sent
    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def deliver_subscription_notification(subscription, method, params)
      subscription&.deliver(method, params)
    end

    # Handle a JSON-RPC response addressed to a listen request: a result is
    # the server's graceful closure, an error a failed subscription.
    # @param message [Hash] a JSON-RPC response
    # @return [MCPClient::Subscription, nil] the subscription it ended, if any
    def handle_subscription_response(message)
      subscription = subscription_by_id(message['id'])
      return nil unless subscription

      unregister_subscription(subscription)
      if message['error']
        error = MCPClient::Errors::ServerError.from_jsonrpc(message['error'])
        @logger.warn("subscriptions/listen #{subscription.id} failed: #{sanitize_log_text(error.message)}")
        subscription.finish(gracefully: false, error: error)
      else
        close_subscription_gracefully(subscription, message['result'])
      end
      subscription
    end

    # End a subscription on the server's closing response — but only when the
    # result is one the client recognizes, and only when it is a *completion*.
    # Every other response goes through
    # {MCPClient::JsonRpcCommon#validate_result_type!}; skipping it here would
    # make a missing, scalar or unknown-resultType result indistinguishable
    # from a clean close.
    #
    # Recognized is not enough on its own. `input_required` is a resultType
    # this client accepts — on tools/call, resources/read and prompts/get,
    # the three requests a server may answer with one
    # (basic/patterns/mrtr "Supported Requests"). subscriptions/listen is not
    # among them, and the whole meaning of `input_required` is that the
    # request has *not* completed, so reporting one as a graceful closure told
    # the host the server had finished with a stream it had not.
    # @param subscription [MCPClient::Subscription]
    # @param result [Object] the response's result member
    # @return [void]
    def close_subscription_gracefully(subscription, result)
      validate_result_type!(result)
      type = MCPClient::JsonRpcCommon.result_type(result)
      unless type == 'complete'
        raise MCPClient::Errors::InvalidResultError,
              "Invalid result: resultType #{type.inspect} does not close a subscription; " \
              "input_required is only valid for #{MCPClient::JsonRpcCommon::MRTR_METHODS.join(', ')}, " \
              'not subscriptions/listen'
      end

      @logger.debug("Server closed subscription #{subscription.id} gracefully")
      subscription.finish(gracefully: true)
    rescue MCPClient::Errors::InvalidResultError => e
      @logger.warn("subscriptions/listen #{subscription.id} closed with an invalid result: #{e.message}")
      subscription.finish(gracefully: false, error: e)
    end

    # Open resource-update subscriptions the modern way: one listen stream
    # per URI (resources/subscribe was replaced by
    # subscriptions/listen.resourceSubscriptions). Blocks until the server
    # acknowledges the stream, so the caller learns about a rejection the way
    # it did from resources/subscribe.
    # @param uri [String] the resource URI
    # @return [MCPClient::Subscription] the acknowledged subscription
    # @raise [MCPClient::Errors::MCPError] if the server refused the stream,
    #   ended it before acknowledging, or acknowledged it without the URI
    def subscribe_resource_via_listen(uri)
      existing = live_resource_subscription(uri)
      return existing if existing

      # One stream per URI: two threads subscribing to the same resource must
      # not open two, or the second registration would hide the first and
      # unsubscribe_resource would close only one of them.
      resource_subscription_mutex(uri).synchronize do
        existing = settled_resource_subscription(uri)
        next existing if existing

        open_resource_subscription(uri)
      end
    end

    # The stream already mapped to this URI, once the server's word on it
    # stands — or nil when there is none to reuse.
    #
    # A mapped stream is not a watch merely for being open, and it is not one
    # merely for having been granted the URI once. After an HTTP connection
    # drops or a stdio process restarts, the request that replaces it is a new
    # listen the server holds no state for: it may be rejected, or
    # acknowledged without this URI, and until it is answered nothing has been
    # granted. Reporting success from that state — which used to happen for
    # every handle that was not closed, and then for every handle whose old
    # acknowledgment was still on record, so for the whole of an HTTP backoff
    # or a stdio handshake — tells the subscriber about a watch nobody has
    # made yet. So this asks whether the server is watching the URI *now*
    # ({MCPClient::Subscription#await_live_resource_watch}), waiting out a
    # stream that is between listen attempts rather than reading what the last
    # one was granted, and a stream that comes back without the URI — or does
    # not come back at all — stops being this URI's stream and is closed with
    # it (see {#discard_mapped_resource_subscription}).
    # @param uri [String] the resource URI
    # @return [MCPClient::Subscription, nil]
    def settled_resource_subscription(uri)
      mapped = subscriptions_mutex.synchronize { resource_subscriptions[uri] }
      return nil unless mapped
      return mapped if mapped.watching_resource?(uri)
      return mapped if mapped.await_live_resource_watch(uri, subscription_ack_timeout) == :watching

      discard_mapped_resource_subscription(mapped, uri)
      nil
    end

    # Give up on a stream that is mapped to a URI the server is not honouring
    # on it — because it answered without the URI, ended, or never answered at
    # all within the acknowledgment timeout.
    #
    # Dropping the mapping is not enough. A stream that is merely
    # :reconnecting is still reconnectable, so {#subscribe_resource_via_listen}
    # would open a replacement beside it and the discarded one could come back
    # and deliver the same updates a second time — while
    # {#unsubscribe_resource_via_listen}, which looks for the stream through
    # the very mapping that was just dropped, could no longer find or cancel
    # it. Closing it is also what the caller is entitled to: on stdio it sends
    # the `notifications/cancelled` the spec requires of a client that stops
    # reading a stream, and on Streamable HTTP it closes the response stream.
    #
    # The mapping is dropped first, and the stream is closed only once no
    # other URI still names it: a stream that is a live watch for a second
    # resource is not this URI's to end.
    # @param subscription [MCPClient::Subscription] the discarded stream
    # @param uri [String] the resource URI it was mapped to
    # @return [void]
    def discard_mapped_resource_subscription(subscription, uri)
      unmap_resource_subscription(subscription, uri)
      still_mapped = subscriptions_mutex.synchronize do
        resource_subscriptions.any? { |_mapped_uri, sub| sub.equal?(subscription) }
      end
      return if still_mapped

      subscription.close
    end

    # Close the streams whose mapped URI the server's latest acknowledgment
    # left out.
    #
    # Every acknowledgment is checked, not just the first: a stream re-opened
    # after an HTTP drop or a stdio restart is a new listen request, the
    # server holds no subscription state across it, and it MAY acknowledge a
    # smaller subset the second time. {#confirm_resource_subscription} only
    # guards the acknowledgment the subscriber waited for, so without this a
    # narrowed re-acknowledgment left `resource_subscriptions` mapping a URI
    # to a stream that no longer carried it, and
    # {#live_resource_subscription} kept reporting success for a resource
    # nothing was watching.
    # @param subscription [MCPClient::Subscription] the acknowledged stream
    # @return [void]
    def drop_unacknowledged_resource_subscriptions(subscription)
      missing = subscription.unacknowledged_resource_uris
      return if missing.empty?

      mapped = subscriptions_mutex.synchronize do
        resource_subscriptions.select { |uri, sub| sub.equal?(subscription) && missing.include?(uri) }.keys
      end
      return if mapped.empty?

      @logger.warn("Server re-acknowledged subscription #{subscription.id} without " \
                   "#{mapped.map { |uri| sanitize_log_text(uri) }.join(', ')}; closing it so the resource " \
                   'subscription no longer reports a watch the server is not honouring')
      # Closing drops the mapping itself (the transport's cancel_subscription
      # clears every URI pointing at this stream), so a later subscribe_resource
      # opens a fresh stream and raises if that one is refused too.
      subscription.close
    end

    # @param uri [String] the resource URI
    # @return [MCPClient::Subscription, nil] its stream, while the server is
    #   currently honouring it for that URI — see
    #   {MCPClient::Subscription#watching_resource?}
    def live_resource_subscription(uri)
      existing = subscriptions_mutex.synchronize { resource_subscriptions[uri] }
      existing if existing&.watching_resource?(uri)
    end

    # @param uri [String] the resource URI
    # @return [MCPClient::Subscription] the acknowledged subscription
    def open_resource_subscription(uri)
      # No watchdog on the first request: this caller waits for the
      # acknowledgment itself, on the same timeout, and reports a stream that
      # never arrives as its own failure rather than through a handle
      # something else closed.
      #
      # The requests a restart or a reconnect re-issues are another matter.
      # Nobody waits on those — the host is waiting for updates — so a
      # replacement the server accepted and then never acknowledged was, with
      # `ack_timeout: false`, pending for ever: the mapped stream was only
      # discarded the next time the URI was asked about, and a host that never
      # asked again was never told. Those requests are bounded by the
      # transport's own timeout, like any other listen's.
      ensure_modern_listen!
      subscription = open_listen(MCPClient::Subscription.normalize_filter('resourceSubscriptions' => [uri]),
                                 ack_timeout: subscription_ack_timeout, initial_deadline: false)
      begin
        confirm_resource_subscription(subscription, uri)
        subscriptions_mutex.synchronize { resource_subscriptions[uri] = subscription }
        recheck_mapped_resource_subscription(subscription, uri)
      rescue StandardError
        # Nothing watches a stream the caller could not use.
        unmap_resource_subscription(subscription, uri)
        subscription.close
        raise
      end
      subscription
    end

    # Check the acknowledgment that stands *now that the URI is mapped*.
    #
    # {#drop_unacknowledged_resource_subscriptions} can only see a stream
    # through the mapping, and the mapping is written after the acknowledgment
    # the subscriber waited for. A stream that dropped and was re-opened in
    # between is acknowledged afresh and MAY be granted more narrowly, so
    # without this second look a re-acknowledgment that landed in that window
    # was stored as a live watch nothing was honouring.
    # @param subscription [MCPClient::Subscription]
    # @param uri [String] the resource URI
    # @return [void]
    # @raise [MCPClient::Errors::MCPError] if the URI is no longer being watched
    def recheck_mapped_resource_subscription(subscription, uri)
      require_resource_watch(subscription, uri)
    end

    # Drop a URI's mapping, but only while it still names this stream.
    # @param subscription [MCPClient::Subscription]
    # @param uri [String] the resource URI
    # @return [void]
    def unmap_resource_subscription(subscription, uri)
      subscriptions_mutex.synchronize do
        resource_subscriptions.delete(uri) if resource_subscriptions[uri].equal?(subscription)
      end
    end

    # Wait for the acknowledgment and check that it really covers the URI: a
    # server MAY acknowledge a subset of the filter it was sent.
    # @param subscription [MCPClient::Subscription]
    # @param uri [String] the resource URI
    # @return [void]
    # @raise [MCPClient::Errors::MCPError] if the URI is not being watched
    def confirm_resource_subscription(subscription, uri)
      require_resource_watch(subscription, uri)
    end

    # Wait for the server's word on this URI to stand, and demand that it
    # watch it.
    #
    # The word that stands is the acknowledgment of the listen request the
    # stream is currently on. A re-open clears it — the server holds no
    # subscription state across one and has to grant the filter again — so a
    # replacement in flight is waited for rather than read as an answer.
    # Reading it as one is what used to report a watch nobody had made: a
    # subscription with no acknowledgment has no unacknowledged URIs either,
    # so "the URI is not missing from the acknowledgment" passed for
    # "the server is watching it".
    # @param subscription [MCPClient::Subscription]
    # @param uri [String] the resource URI
    # @return [void]
    # @raise [MCPClient::Errors::MCPError] if the URI is not being watched
    def require_resource_watch(subscription, uri)
      case subscription.await_resource_watch(uri, subscription_ack_timeout)
      when :watching
        nil
      when :not_watching
        raise MCPClient::Errors::ResourceReadError,
              "the server acknowledged the subscription without '#{uri}'"
      when :closed
        raise subscription.error if subscription.error

        raise MCPClient::Errors::ResourceReadError, "the server closed the subscription for '#{uri}'"
      else
        raise MCPClient::Errors::ResourceReadError,
              "timed out after #{subscription_ack_timeout}s waiting for the server to acknowledge '#{uri}'"
      end
    end

    # @return [Numeric] seconds allowed for a resource subscription acknowledgment
    def subscription_ack_timeout
      timeout = defined?(@read_timeout) ? @read_timeout : nil
      timeout.is_a?(Numeric) && timeout.positive? ? timeout : DEFAULT_ACK_TIMEOUT
    end

    # The lock that serializes opening the stream for one URI. Kept for the
    # life of the transport: it is one Mutex per URI the host subscribed to.
    # @param uri [String] the resource URI
    # @return [Mutex]
    def resource_subscription_mutex(uri)
      subscriptions_mutex.synchronize { resource_subscription_mutexes[uri] ||= Mutex.new }
    end

    # @return [Hash{String => Mutex}]
    def resource_subscription_mutexes
      @resource_subscription_mutexes ||= {}
    end

    # @param uri [String] the resource URI
    # @return [MCPClient::Subscription, nil] the subscription that was closed, if any
    def unsubscribe_resource_via_listen(uri)
      # Behind the same per-URI lock as subscribing, so an unsubscribe cannot
      # slip between a subscribe's acknowledgment and its registration and
      # leave the stream running.
      resource_subscription_mutex(uri).synchronize do
        subscription = subscriptions_mutex.synchronize { resource_subscriptions.delete(uri) }
        subscription&.close
        subscription
      end
    end

    # @return [Hash{String => MCPClient::Subscription}] listen streams opened by subscribe_resource
    def resource_subscriptions
      @resource_subscriptions ||= {}
    end
  end
end
