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
    # @param notifications [Hash] the SubscriptionFilter
    # @yield [method, params] notifications delivered on the subscription
    # @return [MCPClient::Subscription]
    # @raise [MCPClient::Errors::CapabilityError] on a legacy session
    def listen(notifications:, &listener)
      filter = MCPClient::Subscription.normalize_filter(notifications)
      ensure_session_ready
      unless modern?
        raise MCPClient::Errors::CapabilityError,
              'subscriptions/listen requires an MCP 2026-07-28 server; this server negotiated ' \
              "#{protocol_version || 'no version'} (use resources/subscribe and server notifications instead)"
      end

      subscription = MCPClient::Subscription.new(server: self, requested: filter, &listener)
      open_subscription(subscription)
      subscription
    end

    # The subscriptions this transport has opened, keyed by the String form
    # of their listen request id.
    # @return [Hash{String => MCPClient::Subscription}]
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

      subscriptions_mutex.synchronize { subscriptions[id.to_s] }
    end

    # @param subscription [MCPClient::Subscription]
    # @return [void]
    def register_subscription(subscription)
      subscriptions_mutex.synchronize { subscriptions[subscription.id.to_s] = subscription }
    end

    # @param subscription [MCPClient::Subscription]
    # @return [void]
    def unregister_subscription(subscription)
      subscriptions_mutex.synchronize { subscriptions.delete(subscription.id.to_s) }
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

    # Route an incoming notification: subscription bookkeeping
    # (acknowledgment, server-side teardown), then transport and host cache
    # invalidation, and only then delivery to the owning subscription's
    # listeners (so hosts see subscription-delivered notifications exactly
    # like request-scoped ones).
    #
    # The invalidations come first on purpose. A listener runs on the
    # subscription's own dispatcher thread, so queuing its delivery makes the
    # notification visible at once — and a listener that reacts to a
    # list_changed notification by calling a cached list method
    # (`client.list_tools`, say) would then read the very entry the
    # notification says is stale. Dropping the caches before the delivery is
    # queued makes "the caches are already invalid when a listener sees the
    # notification" a guarantee instead of a race the scheduler usually wins.
    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def route_notification(method, params)
      handle_subscription_control(method, params)
      invalidate_cache_for_notification(method) if respond_to?(:invalidate_cache_for_notification, true)
      @notification_callback&.call(method, params)
      deliver_subscription_notification(method, params) unless CONTROL_NOTIFICATIONS.include?(method)
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
      drop_unacknowledged_resource_subscriptions(subscription)
    end

    # @param params [Hash, nil] notification params
    # @return [void]
    def handle_server_cancellation(params)
      subscription = subscription_by_id(params.is_a?(Hash) ? params['requestId'] : nil)
      return unless subscription

      reason = params['reason'].is_a?(String) ? params['reason'] : nil
      @logger.info("Server cancelled subscription #{subscription.id}: " \
                   "#{sanitize_log_text(reason || 'no reason given')}")
      unregister_subscription(subscription)
      subscription.finish(gracefully: false, reason: reason)
    end

    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def deliver_subscription_notification(method, params)
      meta = params.is_a?(Hash) ? params['_meta'] : nil
      return unless meta.is_a?(Hash) && meta.key?(MCPClient::JsonRpcCommon::META_SUBSCRIPTION_ID)

      subscription = subscription_by_id(meta[MCPClient::JsonRpcCommon::META_SUBSCRIPTION_ID])
      if subscription
        subscription.deliver(method, params)
      else
        @logger.debug("Notification #{method} for an unknown or closed subscription ignored")
      end
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
    # result is one the client recognizes. Every other response goes through
    # {MCPClient::JsonRpcCommon#validate_result_type!}; skipping it here would
    # make a missing, scalar or unknown-resultType result indistinguishable
    # from a clean close.
    # @param subscription [MCPClient::Subscription]
    # @param result [Object] the response's result member
    # @return [void]
    def close_subscription_gracefully(subscription, result)
      validate_result_type!(result)
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
        existing = live_resource_subscription(uri)
        next existing if existing

        open_resource_subscription(uri)
      end
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
    # @return [MCPClient::Subscription, nil] its stream, while it is still open
    def live_resource_subscription(uri)
      existing = subscriptions_mutex.synchronize { resource_subscriptions[uri] }
      existing if existing && !existing.closed?
    end

    # @param uri [String] the resource URI
    # @return [MCPClient::Subscription] the acknowledged subscription
    def open_resource_subscription(uri)
      subscription = listen(notifications: { 'resourceSubscriptions' => [uri] })
      begin
        confirm_resource_subscription(subscription, uri)
      rescue StandardError
        # Nothing watches a stream the caller could not use.
        subscription.close
        raise
      end
      subscriptions_mutex.synchronize { resource_subscriptions[uri] = subscription }
      subscription
    end

    # Wait for the acknowledgment and check that it really covers the URI: a
    # server MAY acknowledge a subset of the filter it was sent.
    # @param subscription [MCPClient::Subscription]
    # @param uri [String] the resource URI
    # @return [void]
    # @raise [MCPClient::Errors::MCPError] if the URI is not being watched
    def confirm_resource_subscription(subscription, uri)
      case subscription.wait_until_settled(subscription_ack_timeout)
      when :active
        return unless subscription.unacknowledged_resource_uris.include?(uri)

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
