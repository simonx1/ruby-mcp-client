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

    # Route an incoming notification: subscription bookkeeping
    # (acknowledgment, server-side teardown), delivery to the owning
    # subscription's listeners, transport cache invalidation, and finally the
    # general notification callback (so hosts see subscription-delivered
    # notifications exactly like request-scoped ones).
    # @param method [String] notification method
    # @param params [Hash, nil] notification params
    # @return [void]
    def route_notification(method, params)
      case method
      when 'notifications/subscriptions/acknowledged'
        subscription = subscription_for_notification(params)
        if subscription
          subscription.acknowledge(params['notifications'])
        else
          @logger.debug('Acknowledgment for an unknown subscription ignored')
        end
      when 'notifications/cancelled'
        # Servers MUST send notifications/cancelled only to tear down a
        # subscriptions/listen stream (basic/patterns/cancellation).
        subscription = subscription_by_id(params.is_a?(Hash) ? params['requestId'] : nil)
        if subscription
          reason = params['reason'].is_a?(String) ? params['reason'] : nil
          @logger.info("Server cancelled subscription #{subscription.id}: " \
                       "#{sanitize_log_text(reason || 'no reason given')}")
          unregister_subscription(subscription)
          subscription.finish(gracefully: false, reason: reason)
        end
      else
        deliver_subscription_notification(method, params)
      end
      invalidate_cache_for_notification(method) if respond_to?(:invalidate_cache_for_notification, true)
      @notification_callback&.call(method, params)
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
        @logger.debug("Server closed subscription #{subscription.id} gracefully")
        subscription.finish(gracefully: true)
      end
      subscription
    end

    # Open resource-update subscriptions the modern way: one listen stream
    # per URI (resources/subscribe was replaced by
    # subscriptions/listen.resourceSubscriptions).
    # @param uri [String] the resource URI
    # @return [MCPClient::Subscription]
    def subscribe_resource_via_listen(uri)
      resource_subscriptions[uri] ||= listen(notifications: { 'resourceSubscriptions' => [uri] })
    end

    # @param uri [String] the resource URI
    # @return [MCPClient::Subscription, nil] the subscription that was closed, if any
    def unsubscribe_resource_via_listen(uri)
      subscription = resource_subscriptions.delete(uri)
      subscription&.close
      subscription
    end

    # @return [Hash{String => MCPClient::Subscription}] listen streams opened by subscribe_resource
    def resource_subscriptions
      @resource_subscriptions ||= {}
    end
  end
end
